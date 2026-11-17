package core

import (
	"bytes"
	"compress/gzip"
	"context"
	"crypto/aes"
	"crypto/cipher"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"
)

const (
	huangdouBaseURL     = "https://tideember.cc"
	huangdouVersion     = "2.0.0"
	huangdouDeviceType  = "web"
	huangdouPlatformKey = "7961beb44246e3012ce228d6b5ced05a"
)

type huangdouAPIClient struct {
	d         *Downloader
	host      string
	sessionID string
	deviceID  string
}

func newHuangdouAPIClient(d *Downloader) *huangdouAPIClient {
	id := randomHex(16)
	if id == "" {
		id = strconv.FormatInt(time.Now().UnixNano(), 16)
	}
	host := d.providerBaseURL(sourceHuangdou)
	d.providerMu.Lock()
	if preferred := d.providerHosts[sourceHuangdou]; preferred != "" {
		host = preferred
	}
	d.providerMu.Unlock()
	return &huangdouAPIClient{d: d, host: host, sessionID: id, deviceID: id}
}

func (d *Downloader) fetchHuangdouChapters(ctx context.Context, sourceID string) (string, []Chapter, error) {
	sourceID = strings.TrimPrefix(strings.TrimSpace(sourceID), "rp_")
	data, err := d.huangdouDetail(ctx, sourceID)
	if err != nil {
		return "", nil, err
	}
	title := firstNonEmpty(mapString(data, "name", "title", "t"), sourceID)
	episodes := huangdouList(data["episodes"])
	count := atoiDefault(firstNonEmpty(mapString(data, "episode_count"), mapString(data, "free_episodes")), len(episodes))
	if count <= 0 {
		count = len(episodes)
	}
	if count <= 0 || count > 10000 {
		return title, nil, fmt.Errorf("黄豆返回了无效集数: %d", count)
	}
	// 详情接口识别不出 VIP 时，探询播放接口确定 VIP 起始集。
	// 黄豆的 VIP 信息在播放接口才准确；只看详情会把试看集当成免费全集。
	probeStart := 0
	if !huangdouVIPKnown(data) {
		client := newHuangdouAPIClient(d)
		probeCtx, cancel := context.WithTimeout(ctx, huangdouVIPProbeTimeout)
		probeStart = huangdouProbeVIPStart(probeCtx, client, sourceID, count)
		cancel()
		// 结论要回写，否则 Drama 侧仍显示“VIP 状态待补齐”。
		// probeStart > 0 表示探询确实找到了 VIP 起始集。
		d.rememberHuangdouVIPProbe(sourceID, probeStart > 0)
	}
	chapterVIP := func(episode map[string]any, seq int) bool {
		if huangdouEpisodeVIP(data, episode, seq) {
			return true
		}
		return probeStart > 0 && seq >= probeStart
	}
	chapters := make([]Chapter, 0, count)
	if len(episodes) > 0 {
		for i, ep := range episodes {
			seq := atoiDefault(firstNonEmpty(mapString(ep, "seq"), mapString(ep, "episode"), mapString(ep, "ep")), i+1)
			if seq <= 0 {
				seq = i + 1
			}
			titleText := firstNonEmpty(mapString(ep, "name", "title"), fmt.Sprintf("第%d集", seq))
			chapters = append(chapters, Chapter{VIP: chapterVIP(ep, seq), ID: providerChapterID(sourceHuangdou, sourceID, strconv.Itoa(seq)), Source: sourceHuangdou, Title: titleText, CurrentEpisode: rawEpisode(seq)})
		}
	} else {
		for i := 1; i <= count; i++ {
			chapters = append(chapters, Chapter{VIP: chapterVIP(nil, i), ID: providerChapterID(sourceHuangdou, sourceID, strconv.Itoa(i)), Source: sourceHuangdou, Title: fmt.Sprintf("第%d集", i), CurrentEpisode: rawEpisode(i)})
		}
	}
	sortProviderChapters(chapters)
	return title, uniqueChapters(chapters), nil
}

func (d *Downloader) resolveHuangdouPlayback(ctx context.Context, client *huangdouAPIClient, sourceID string, seq int) (providerMedia, error) {
	var decoded any
	if err := client.call(ctx, "/drama/play", map[string]any{"id": sourceID, "seq": strconv.Itoa(seq)}, &decoded); err != nil {
		return providerMedia{}, err
	}
	data := huangdouDataMap(decoded)
	media := firstNonEmpty(mapString(data, "m3u8"), mapString(data, "url"), mapString(data, "play_url"), mapString(data, "playUrl"))
	if huangdouPreviewOnly(data, media, client.host) {
		return providerMedia{}, &huangdouAPIError{code: "preview", message: "黄豆仅提供试看，未取得该集正片；不会把试看内容当作完整分集"}
	}
	if media == "" {
		media = fmt.Sprintf("%s/api/drama/hls/%s/%d/play.m3u8?line=free", client.host, url.PathEscape(sourceID), seq)
		playlist, err := huangdouGetText(ctx, d, media, client.host+"/home")
		if err != nil || !strings.HasPrefix(strings.TrimSpace(playlist), "#EXTM3U") {
			return providerMedia{}, errors.New("黄豆未提供有效的播放地址，备用播放列表也不可用")
		}
	}
	media = resolveProviderURL(client.host+"/", media)
	if !isProviderHTTPMediaURL(media) {
		return providerMedia{}, errors.New("黄豆播放地址不是 HTTP/HTTPS URL")
	}
	result := providerMedia{URL: media, Referer: client.host + "/home"}
	if rawKey := mapString(data, "hls_key"); rawKey != "" {
		key, err := hex.DecodeString(rawKey)
		if err != nil || len(key) != aes.BlockSize {
			return providerMedia{}, errors.New("黄豆返回了无效的 HLS 密钥")
		}
		result.HLSKey = key
	}
	if duration, err := strconv.ParseFloat(mapString(data, "duration"), 64); err == nil && duration > 0 {
		result.Duration = time.Duration(duration * float64(time.Second))
	}
	return result, nil
}

func (c *huangdouAPIClient) call(ctx context.Context, path string, data map[string]any, out *any) error {
	retries := c.d.cfg.Retries
	if retries < 1 {
		retries = 1
	}
	var lastErr error
	for attempt := 0; attempt < retries; attempt++ {
		if err := ctx.Err(); err != nil {
			return err
		}
		if attempt > 0 {
			select {
			case <-time.After(time.Duration(attempt) * time.Second):
			case <-ctx.Done():
				return ctx.Err()
			}
		}
		lastErr = c.callOnce(ctx, path, data, out)
		if lastErr == nil {
			return nil
		}
		var apiErr *huangdouAPIError
		if errors.As(lastErr, &apiErr) {
			return lastErr
		}
		if c.host == huangdouBaseURL && c.d.cfg.HuangdouURL == "" {
			c.host = "https://xqjurgek.top"
		}
	}
	return lastErr
}

type huangdouAPIError struct {
	code    string
	message string
}

func (failure *huangdouAPIError) Error() string {
	if failure.code != "preview" && isHuangdouAccessError(failure) {
		return failure.message + "（站点权限限制，已停止自动重试；切换代理不会解锁）"
	}
	return failure.message
}

func isHuangdouAccessError(err error) bool {
	var failure *huangdouAPIError
	if !errors.As(err, &failure) {
		return false
	}
	switch failure.code {
	case "813004", "813005", "813006", "813103", "preview":
		return true
	default:
		return false
	}
}

func huangdouPreviewOnly(data map[string]any, media, host string) bool {
	switch strings.ToLower(mapString(data, "is_preview", "isPreview")) {
	case "true", "1", "y":
		return true
	}
	if preview := mapString(data, "preview_m3u8", "preview_url"); preview != "" &&
		(media == "" || resolveProviderURL(host+"/", media) == resolveProviderURL(host+"/", preview)) {
		return true
	}
	parsed, err := url.Parse(media)
	if err != nil {
		return false
	}
	path := strings.ToLower(parsed.Path)
	return path == "preview.mp4" || path == "preview.m3u8" || strings.HasSuffix(path, "/preview.mp4") || strings.HasSuffix(path, "/preview.m3u8")
}

func (c *huangdouAPIClient) callOnce(ctx context.Context, path string, data map[string]any, out *any) error {
	path = "/" + strings.TrimLeft(path, "/")
	rid := uuidLike()
	key, err := huangdouKey(rid)
	if err != nil {
		return err
	}
	iv := make([]byte, aes.BlockSize)
	if _, err := rand.Read(iv); err != nil {
		return err
	}
	plain, err := json.Marshal(map[string]any{"token": "", "deviceId": c.deviceID, "data": data})
	if err != nil {
		return err
	}
	var gz bytes.Buffer
	zw := gzip.NewWriter(&gz)
	if _, err := zw.Write(plain); err != nil {
		return err
	}
	if err := zw.Close(); err != nil {
		return err
	}
	cipherText, err := aesCBCEncrypt(gz.Bytes(), key, iv)
	if err != nil {
		return err
	}
	body := append(append([]byte{}, iv...), cipherText...)
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, strings.TrimRight(c.host, "/")+"/api"+path, bytes.NewReader(body))
	if err != nil {
		return err
	}
	req.Header.Set("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120 Safari/537.36")
	req.Header.Set("Accept", "*/*")
	req.Header.Set("Origin", c.host)
	req.Header.Set("Referer", c.host+"/home")
	req.Header.Set("Content-Type", "application/octet-stream")
	req.Header.Set("version", huangdouVersion)
	req.Header.Set("deviceType", huangdouDeviceType)
	req.Header.Set("requestId", rid)
	req.Header.Set("sessionId", c.sessionID)
	resp, body, err := func() (*http.Response, []byte, error) {
		timestamp := strconv.FormatInt(time.Now().Unix(), 10)
		signRaw := "Dart|" + c.sessionID + "|" + rid + "|" + timestamp + "|" + path
		signSum := sha256.Sum256([]byte(signRaw))
		req.Header.Set("time", timestamp)
		req.Header.Set("sign", hex.EncodeToString(signSum[:])+"-"+timestamp)
		return huangdouDo(c, req, 20*time.Second)
	}()
	if err != nil {
		return err
	}
	blob := body
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return fmt.Errorf("huangdou HTTP %d: %s", resp.StatusCode, truncate(string(blob), 200))
	}
	decoded, err := huangdouDecode(blob, key)
	if err != nil {
		return err
	}
	if envelope, ok := decoded.(map[string]any); ok {
		if status := mapString(envelope, "status"); status != "" && status != "y" {
			return &huangdouAPIError{code: mapString(envelope, "errorCode", "error_code", "code"), message: "黄豆接口拒绝请求: " + firstNonEmpty(mapString(envelope, "msg", "message", "error"), status)}
		}
	}
	c.d.providerMu.Lock()
	c.d.providerHosts[sourceHuangdou] = c.host
	c.d.providerMu.Unlock()
	if out != nil {
		*out = decoded
	}
	return nil
}

func huangdouKey(rid string) ([]byte, error) {
	clean := strings.ReplaceAll(rid, "-", "")
	b, err := hex.DecodeString(clean)
	if err != nil {
		return nil, err
	}
	mac := hmac.New(sha256.New, []byte(huangdouPlatformKey))
	_, _ = mac.Write(b)
	return mac.Sum(nil), nil
}

func huangdouDecode(blob, key []byte) (any, error) {
	if len(blob) > providerMaxBodyBytes {
		return nil, errors.New("黄豆响应过大")
	}
	if json.Valid(blob) {
		var direct any
		decoder := json.NewDecoder(bytes.NewReader(blob))
		decoder.UseNumber()
		if err := decoder.Decode(&direct); err != nil {
			return nil, err
		}
		return direct, nil
	}
	if len(blob) < aes.BlockSize*2 {
		return nil, fmt.Errorf("huangdou response too short")
	}
	plain, err := aesCBCDecrypt(blob[aes.BlockSize:], key, blob[:aes.BlockSize])
	if err != nil {
		return nil, err
	}
	if len(plain) >= 2 && plain[0] == 0x1f && plain[1] == 0x8b {
		zr, err := gzip.NewReader(bytes.NewReader(plain))
		if err != nil {
			return nil, err
		}
		plain, err = io.ReadAll(io.LimitReader(zr, providerMaxBodyBytes+1))
		_ = zr.Close()
		if err != nil {
			return nil, err
		}
		if len(plain) > providerMaxBodyBytes {
			return nil, errors.New("黄豆解压后响应过大")
		}
	}
	var decoded any
	if !json.Valid(plain) {
		return nil, errors.New("黄豆响应格式异常")
	}
	decoder := json.NewDecoder(bytes.NewReader(plain))
	decoder.UseNumber()
	if err := decoder.Decode(&decoded); err != nil {
		return nil, err
	}
	return decoded, nil
}

func aesCBCEncrypt(plain, key, iv []byte) ([]byte, error) {
	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, err
	}
	padded := pkcs7Pad(plain, block.BlockSize())
	out := make([]byte, len(padded))
	cipher.NewCBCEncrypter(block, iv).CryptBlocks(out, padded)
	return out, nil
}

func aesCBCDecrypt(cipherText, key, iv []byte) ([]byte, error) {
	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, err
	}
	if len(cipherText)%block.BlockSize() != 0 {
		return nil, fmt.Errorf("huangdou ciphertext is not block aligned")
	}
	out := make([]byte, len(cipherText))
	cipher.NewCBCDecrypter(block, iv).CryptBlocks(out, cipherText)
	return pkcs7Unpad(out, block.BlockSize())
}

func huangdouDramaFromMap(item map[string]any) Drama {
	return huangdouDramaFromMapVIP(item, nil)
}

// huangdouDramaFromMapVIP 与 huangdouDramaFromMap 相同，但允许外部
// 用「播放接口探询」得到的 VIP 结论覆盖详情接口的判断。
//
// 黄豆的试看剧在详情接口里不带 VIP 标记（is_vip/pay_type 都为空），
// 只有探询后几集播放接口才能确定整部剧是否含 VIP 集。
// 若不回写，UI 会一直显示「VIP 状态待补齐」。
func huangdouDramaFromMapVIP(item map[string]any, vipOverride *bool) Drama {
	sourceID := strings.TrimPrefix(firstNonEmpty(mapString(item, "id"), mapString(item, "drama_id")), "rp_")
	if sourceID == "" {
		return Drama{}
	}
	title := firstNonEmpty(mapString(item, "name", "title", "t"), sourceID)
	cover := firstNonEmpty(mapString(item, "img_y", "img_x", "img", "cover", "pic"))
	remark := firstNonEmpty(mapString(item, "update_label"), mapString(item, "corner"))
	releaseStatus := releaseStatusFromRemark(remark)
	if remark == "" {
		if eps := mapString(item, "episode_count"); eps != "" {
			remark = "全" + eps + "集"
		}
	}
	category := firstNonEmpty(mapString(item, "category", "category_name", "categoryName"), "未分类")
	vip := huangdouVIPFlag(item)
	if vip == nil && vipOverride != nil {
		vip = vipOverride
	}
	return Drama{VIP: vip, ID: providerDramaID(sourceHuangdou, sourceID), Source: sourceHuangdou, SourceID: sourceID, Title: title, Name: title, Desc: firstNonEmpty(mapString(item, "description"), mapString(item, "summary")), Intro: firstNonEmpty(mapString(item, "description"), mapString(item, "summary")), Cover: cover, CoverURL: cover, CategoryName: category, ChannelName: "tideember.cc", Remark: remark, TotalEpisode: mapString(item, "episode_count"), EpisodeCount: mapString(item, "episode_count"), Tags: mapStringSlice(item, "tags"), ReleaseStatus: releaseStatus, Heat: mapString(item, "hot_rate"), Views: normalizeViews(mapString(item, "click")), OnlineDate: providerReleaseDate(mapString(item, "issue_date"))}
}

func huangdouDataMap(v any) map[string]any {
	m, _ := v.(map[string]any)
	if data, ok := m["data"].(map[string]any); ok {
		return data
	}
	return m
}

func huangdouList(v any) []map[string]any {
	switch x := v.(type) {
	case []any:
		out := make([]map[string]any, 0, len(x))
		for _, item := range x {
			if m, ok := item.(map[string]any); ok {
				out = append(out, m)
			}
		}
		return out
	case []map[string]any:
		return x
	case map[string]any:
		for _, key := range []string{"list", "items", "data"} {
			if list := huangdouList(x[key]); len(list) > 0 {
				return list
			}
		}
	}
	return nil
}

func atoiDefault(s string, fallback int) int {
	if n, err := strconv.Atoi(strings.TrimSpace(s)); err == nil {
		return n
	}
	return fallback
}

func randomHex(n int) string {
	b := make([]byte, n)
	if _, err := rand.Read(b); err != nil {
		return ""
	}
	return hex.EncodeToString(b)
}

func uuidLike() string {
	raw := randomHex(16)
	if len(raw) != 32 {
		return raw
	}
	return raw[:8] + "-" + raw[8:12] + "-" + raw[12:16] + "-" + raw[16:20] + "-" + raw[20:]
}
