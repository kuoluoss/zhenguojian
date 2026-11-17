package core

import (
	"context"
	"errors"
	"fmt"
	"net/url"
	"regexp"
	"strconv"
	"strings"
	"time"
)

// 蓝果短剧（languo.ai）站源实现（0.7.19）。
//
// 站点结构（2026-11-11 实测）：
//   - 列表：`/duanju/`，分页 `/duanju/{n}/`（每页约 25 部）
//   - 排行：`/ranking/`，热门 `/duanju/hot/`
//   - 搜索：`/search/?q=关键词`
//   - 详情：`/video/{id}/`，分集 `/video/{id}/ep-{n}/`
//
// 页面是服务端渲染的 HTML，详情页内嵌 JSON：
//   `"epPlaySrcs":{"1":"https://...m3u8","2":"..."}`
// 播放地址是标准 HLS（m3u8 + AES-128，密钥在播放列表内），**无需 Referer**、
// 无需签名 —— 是目前各站源里取流最简单的一个。
//
// 注意：`auth_key` 有时效（实测约 1~2 小时），播放地址必须即时解析、不可长缓存。

const (
	sourceLanguo    = "languo"
	languoBaseURL   = "https://languo.ai"
	languoChannel   = "蓝果短剧"
)

var (
	languoVideoLinkPattern = regexp.MustCompile(`href="(/video/(\d+)/)"`)
	languoTitlePattern     = regexp.MustCompile(`<strong>([^<]{1,120})</strong>`)
	languoEpLinkPattern    = regexp.MustCompile(`/video/(\d+)/ep-(\d+)/`)
	languoPlaySrcPattern   = regexp.MustCompile(`"epPlaySrcs"\s*:\s*\{([^}]*)\}`)
	languoPlayEntryPattern = regexp.MustCompile(`"(\d{1,4})"\s*:\s*"(https:[^"]+\.m3u8[^"]*)"`)
	languoNextPagePattern  = regexp.MustCompile(`ll-pager__step`)
	languoTitleJSONPattern = regexp.MustCompile(`"title"\s*:\s*"([^"]{1,120})"`)
	languoDescPattern      = regexp.MustCompile(`"desc"\s*:\s*"([^"]{0,600})"`)
	languoCoverPattern     = regexp.MustCompile(`"cover"\s*:\s*"([^"]{0,300})"`)
	languoScorePattern     = regexp.MustCompile(`"score"\s*:\s*"([0-9.]{1,8})"`)
	languoTagsPattern      = regexp.MustCompile(`"tags"\s*:\s*"([^"]{0,200})"`)
	languoRemarkPattern    = regexp.MustCompile(`"episode"\s*:\s*"([^"]{0,40})"`)
	languoHTMLTitlePattern = regexp.MustCompile(`<title>([^<]{1,160})</title>`)
	languoDeclaredAll      = regexp.MustCompile(`全\s*(\d{1,4})\s*集`)
	languoDeclaredUpdate   = regexp.MustCompile(`更新至\s*(\d{1,4})\s*集`)
)

// languoGet 抓取页面（该站对标准 HTTP 客户端友好，无需特殊 TLS 指纹）。
//
// 超时单独放宽到 30 秒：languo.ai 走 Cloudflare，用户开 VPN/代理时
// 代理节点到 Cloudflare 常需 15~25 秒，默认 12 秒会误判超时（实测现象：
// 「Get https://languo.ai/duanju/: context deadline exceeded」）。
func (d *Downloader) languoGet(ctx context.Context, address string) (string, error) {
	return d.fetchProviderTextTimeout(ctx, address, address, languoBaseURL+"/", 30*time.Second)
}

// languoGetDirect 优先直连抓取（代理失败时的第二轮）。
//
// 需求：用户开了 VPN 也必须能用。若代理路径超时/报错，这里强制直连再试一次，
// 避免「一开 VPN，蓝果整源不可用」。
func (d *Downloader) languoGetDirect(ctx context.Context, address string) (string, error) {
	directCtx := context.WithValue(ctx, forceDirectKey{}, true)
	return d.fetchProviderTextTimeout(directCtx, address, address, languoBaseURL+"/", 30*time.Second)
}

// languoFetch 先走常规路径，失败再强制直连。
//
// 两轮都失败时给出**可操作的提示**：蓝果站（languo.ai）在部分网络环境下
// 必须经代理/VPN 才可达（2026-11-15 实测：国内直连超时，走代理 200）。
// 直接抛原始网络错误会让用户以为是软件坏了。
func (d *Downloader) languoFetch(ctx context.Context, address string) (string, error) {
	body, err := d.languoGet(ctx, address)
	if err == nil {
		return body, nil
	}
	if ctxErr := ctx.Err(); ctxErr != nil {
		return "", ctxErr
	}
	body, directErr := d.languoGetDirect(ctx, address)
	if directErr == nil {
		return body, nil
	}
	return "", errors.New(languoNetworkHint(err, directErr))
}

// languoNetworkHint 归并两轮失败原因，生成面向用户的提示。
//
// 把技术性网络错误（context deadline exceeded / connection reset 等）
// 统一换成一句用户能照着操作的话。
func languoNetworkHint(first, second error) string {
	reason := second
	if reason == nil {
		reason = first
	}
	text := ""
	if reason != nil {
		text = strings.TrimSpace(fmt.Sprintf("%v", reason))
	}
	lower := strings.ToLower(text)
	networkIssue := text == "" ||
		strings.Contains(lower, "deadline exceeded") ||
		strings.Contains(lower, "timeout") ||
		strings.Contains(lower, "connection reset") ||
		strings.Contains(lower, "eof") ||
		strings.Contains(lower, "no such host") ||
		strings.Contains(lower, "network is unreachable") ||
		strings.Contains(lower, "tls handshake timeout")
	if networkIssue {
		return "蓝果站点在当前网络下不可访问。该站需要代理或 VPN 才能连接，请在开启代理后重试。"
	}
	return "蓝果站点访问失败：" + text
}

// ---- 列表 ----

// fetchLanguoCatalogPage 取列表页（page 从 1 开始）。
func (d *Downloader) fetchLanguoCatalogPage(ctx context.Context, page int, category string) ([]Drama, bool, error) {
	var address string
	switch {
	case category == "hot" || category == "热门":
		if page <= 1 {
			address = languoBaseURL + "/duanju/hot/"
		} else {
			address = fmt.Sprintf("%s/duanju/hot/%d/", languoBaseURL, page)
		}
	case category == "ranking" || category == "排行榜":
		address = languoBaseURL + "/ranking/"
	default:
		if page <= 1 {
			address = languoBaseURL + "/duanju/"
		} else {
			address = fmt.Sprintf("%s/duanju/%d/", languoBaseURL, page)
		}
	}
	body, err := d.languoFetch(ctx, address)
	if err != nil {
		return nil, false, err
	}
	items := parseLanguoCatalogCards(body, category)
	hasMore := languoNextPagePattern.MatchString(body) && len(items) > 0
	return items, hasMore, nil
}

// parseLanguoCatalogCards 从列表页 HTML 解析剧集卡片。
func parseLanguoCatalogCards(body, category string) []Drama {
	var out []Drama
	seen := map[string]bool{}
	for _, match := range languoVideoLinkPattern.FindAllStringSubmatchIndex(body, 300) {
		if len(match) < 6 {
			continue
		}
		id := body[match[4]:match[5]]
		if id == "" || seen[id] {
			continue
		}
		seen[id] = true
		end := match[1] + 900
		if end > len(body) {
			end = len(body)
		}
		window := body[match[1]:end]
		title := ""
		if found := languoTitlePattern.FindStringSubmatch(window); len(found) > 1 {
			title = strings.TrimSpace(languoUnescape(found[1]))
		}
		if title == "" {
			title = languoChannel + " " + id
		}
		out = append(out, Drama{
			ID:           providerDramaID(sourceLanguo, id),
			Source:       sourceLanguo,
			SourceID:     id,
			Title:        title,
			Name:         title,
			CategoryName: category,
			ChannelName:  languoChannel,
		})
	}
	return out
}

// ---- 详情 ----

// fetchLanguoDetail 取详情页，返回元数据与分集列表。
func (d *Downloader) fetchLanguoDetail(ctx context.Context, sourceID string) (Drama, []Chapter, error) {
	if !languoIDValid(sourceID) {
		return Drama{}, nil, errors.New("蓝果剧集 ID 无效")
	}
	address := languoBaseURL + "/video/" + url.PathEscape(sourceID) + "/"
	body, err := d.languoFetch(ctx, address)
	if err != nil {
		return Drama{}, nil, err
	}
	drama := parseLanguoDetailMeta(body, sourceID)
	chapters := parseLanguoChapters(body, sourceID)
	if len(chapters) == 0 {
		return drama, nil, errors.New("蓝果该剧未提供可播放剧集")
	}
	if drama.TotalEpisode == "" {
		drama.TotalEpisode = strconv.Itoa(len(chapters))
		drama.EpisodeCount = drama.TotalEpisode
	}
	return drama, chapters, nil
}

// parseLanguoDetailMeta 解析详情页元数据。
func parseLanguoDetailMeta(body, sourceID string) Drama {
	decoded := languoUnescape(body)
	title := ""
	if found := languoTitleJSONPattern.FindStringSubmatch(decoded); len(found) > 1 {
		title = strings.TrimSpace(found[1])
	}
	if title == "" {
		if found := languoHTMLTitlePattern.FindStringSubmatch(body); len(found) > 1 {
			title = strings.TrimSpace(strings.Split(found[1], "-")[0])
		}
	}
	desc := ""
	if found := languoDescPattern.FindStringSubmatch(decoded); len(found) > 1 {
		desc = strings.TrimSpace(found[1])
	}
	cover := ""
	if found := languoCoverPattern.FindStringSubmatch(decoded); len(found) > 1 {
		cover = strings.TrimSpace(found[1])
		if strings.HasPrefix(cover, "/") {
			cover = languoBaseURL + cover
		}
	}
	score := ""
	if found := languoScorePattern.FindStringSubmatch(decoded); len(found) > 1 {
		score = found[1]
	}
	remark := ""
	if found := languoRemarkPattern.FindStringSubmatch(decoded); len(found) > 1 {
		remark = strings.TrimSpace(found[1])
	}
	var tags []string
	if found := languoTagsPattern.FindStringSubmatch(decoded); len(found) > 1 {
		for _, tag := range strings.Split(found[1], ",") {
			if trimmed := strings.TrimSpace(tag); trimmed != "" {
				tags = append(tags, trimmed)
			}
		}
	}
	category := ""
	if len(tags) > 0 {
		category = tags[0]
	}
	return Drama{
		ID:           providerDramaID(sourceLanguo, sourceID),
		Source:       sourceLanguo,
		SourceID:     sourceID,
		Title:        title,
		Name:         title,
		Desc:         desc,
		Intro:        desc,
		Cover:        cover,
		CoverURL:     cover,
		Score:        score,
		CategoryName: category,
		ChannelName:  languoChannel,
		Remark:       remark,
		Tags:         tags,
	}
}

// parseLanguoChapters 从详情页解析分集。
func parseLanguoChapters(body, sourceID string) []Chapter {
	decoded := languoUnescape(body)
	direct := map[int]string{}
	if found := languoPlaySrcPattern.FindStringSubmatch(decoded); len(found) > 1 {
		for _, entry := range languoPlayEntryPattern.FindAllStringSubmatch(found[1], 200) {
			if number, err := strconv.Atoi(entry[1]); err == nil && number > 0 {
				direct[number] = entry[2]
			}
		}
	}
	maxEpisode := 0
	for _, found := range languoEpLinkPattern.FindAllStringSubmatch(decoded, 300) {
		if found[1] != sourceID {
			continue
		}
		if number, err := strconv.Atoi(found[2]); err == nil && number > maxEpisode {
			maxEpisode = number
		}
	}
	if found := languoDeclaredAll.FindStringSubmatch(decoded); len(found) > 1 {
		if declared, err := strconv.Atoi(found[1]); err == nil && declared > maxEpisode {
			maxEpisode = declared
		}
	}
	if found := languoDeclaredUpdate.FindStringSubmatch(decoded); len(found) > 1 {
		if declared, err := strconv.Atoi(found[1]); err == nil && declared > maxEpisode {
			maxEpisode = declared
		}
	}
	if maxEpisode == 0 {
		maxEpisode = 1
	}
	chapters := make([]Chapter, 0, maxEpisode)
	for number := 1; number <= maxEpisode; number++ {
		pageURL := fmt.Sprintf("%s/video/%s/", languoBaseURL, url.PathEscape(sourceID))
		if number > 1 {
			pageURL = fmt.Sprintf("%s/video/%s/ep-%d/", languoBaseURL, url.PathEscape(sourceID), number)
		}
		chapters = append(chapters, Chapter{
			ID:             providerChapterID(sourceLanguo, sourceID, strconv.Itoa(number)),
			Source:         sourceLanguo,
			Title:          fmt.Sprintf("第%d集", number),
			VideoURL:       direct[number],
			PageURL:        pageURL,
			CurrentEpisode: rawEpisode(number),
		})
	}
	return chapters
}

// ---- 播放 ----

// resolveLanguoMedia 解析某集的播放地址（标准 HLS，密钥在 m3u8 内）。
func (d *Downloader) resolveLanguoMedia(ctx context.Context, sourceID, episode string) (providerMedia, error) {
	if !languoIDValid(sourceID) {
		return providerMedia{}, errors.New("蓝果剧集 ID 无效")
	}
	number, err := strconv.Atoi(episode)
	if err != nil || number < 1 {
		return providerMedia{}, errors.New("蓝果分集编号无效")
	}
	address := fmt.Sprintf("%s/video/%s/", languoBaseURL, url.PathEscape(sourceID))
	if number > 1 {
		address = fmt.Sprintf("%s/video/%s/ep-%d/", languoBaseURL, url.PathEscape(sourceID), number)
	}
	body, err := d.languoFetch(ctx, address)
	if err != nil {
		return providerMedia{}, err
	}
	decoded := languoUnescape(body)
	found := languoPlaySrcPattern.FindStringSubmatch(decoded)
	if len(found) < 2 {
		return providerMedia{}, errors.New("蓝果该集未提供播放地址")
	}
	entries := languoPlayEntryPattern.FindAllStringSubmatch(found[1], 200)
	want := strconv.Itoa(number)
	for _, entry := range entries {
		if entry[1] != want {
			continue
		}
		if mediaURL := entry[2]; isProviderHTTPMediaURL(mediaURL) {
			return providerMedia{URL: mediaURL, Referer: address}, nil
		}
	}
	// 兜底：该页任意一条可用 m3u8
	for _, entry := range entries {
		if mediaURL := entry[2]; isProviderHTTPMediaURL(mediaURL) {
			return providerMedia{URL: mediaURL, Referer: address}, nil
		}
	}
	return providerMedia{}, errors.New("蓝果该集播放地址不可用")
}

// ---- 工具 ----

// languoIDValid 蓝果剧集 ID 为纯数字。
func languoIDValid(id string) bool {
	if id == "" || len(id) > 20 {
		return false
	}
	for index := 0; index < len(id); index++ {
		if id[index] < '0' || id[index] > '9' {
			return false
		}
	}
	return true
}

// languoUnescape 还原与数据相关的 HTML 实体和 JSON 转义。
func languoUnescape(value string) string {
	replacer := strings.NewReplacer(
		"&#34;", `"`,
		"&#39;", "'",
		"&quot;", `"`,
		"&amp;", "&",
		"&lt;", "<",
		"&gt;", ">",
		`\u0026`, "&",
		`\/`, "/",
	)
	return replacer.Replace(value)
}
