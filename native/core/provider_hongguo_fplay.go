package core

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"net/url"
	"strconv"
	"strings"
	"time"
)

// 红果官方取流通道 `vas-lf-x.snssdk.com/video/fplay/`（0.7.19）。
//
// 背景（2026-11-11，在 MuMu 真机环境实测）：
// 红果 7.4.3.32 的播放器在拿到 video_model 后，会把一份 `mFallbackApi`
// 写进本地播放缓存。该地址是**官方备用取流接口**，参数固定且不需要六头签名：
//
//	https://vas-lf-x.snssdk.com/video/fplay/1/{哈希}/{videoID}
//	  ?aid=8662&auth_policy=...&channel=novel_short_play&codec_type=4
//	  &device_id=...&device_platform=android&imp=false&logo_type=default
//	  &ptoken=novel_pugc&ssl=true&stream_type=normal
//	  &update_version_code=...&user_id=...&version_code=...&vps=6
//
// 相比我们原先用的第三方中转 `djapi.999888456.xyz`（已失效，TLS 直接断连），
// 这条是红果自己的域名，稳定性与可用性都更好。
//
// 注意：`{哈希}` 段是服务端按 videoID 计算的，客户端无法自行推导，
// 因此这里采用「先探测常见哈希位置」的策略——优先用 video_model 里
// 回传的 `fallback_api`，没有回传时才用本文件的构造逻辑兜底。

// hongguoFplayBase 官方备用取流入口（域名与路径来自 7.4.3.32 实测）。
const hongguoFplayBase = "https://vas-lf-x.snssdk.com/video/fplay/1/"

// hongguoFplayDefaultVersion 红果 7.4.3.32 的版本号（参数需与 App 一致）。
const hongguoFplayDefaultVersion = "74332"

// hongguoFplayAuthPolicy 固定鉴权策略（来自实测缓存，base64 of {"v":3,"uid":"0"}）。
const hongguoFplayAuthPolicy = "eyJ2IjozLCJ1aWQiOiIwIn0="

// resolveHongguoFplayMedia 用官方 fplay 通道取流。
//
// hash 无法自行推导，所以这里以「video_model 里回传的 fallback_api」为主；
// 该函数只在有 hash 时被调用，构造出的参数与 App 实际请求一致。
func (d *Downloader) resolveHongguoFplayMedia(ctx context.Context, hash, videoID, userID, deviceID string) (providerMedia, error) {
	hash = strings.TrimSpace(hash)
	videoID = strings.TrimSpace(videoID)
	if !validHongguoFplayHash(hash) || !hongguoNumericID.MatchString(videoID) {
		return providerMedia{}, errors.New("红果官方取流参数无效")
	}
	config := upstreamConfigSnapshot()
	versionCode := config.VersionCode
	if versionCode == "" {
		versionCode = hongguoFplayDefaultVersion
	}
	query := url.Values{
		"aid":                  {"8662"},
		"auth_policy":          {hongguoFplayAuthPolicy},
		"channel":              {"novel_short_play"},
		"codec_type":           {"4"},
		"device_platform":      {"android"},
		"encode_user_tag":      {"only_roi"},
		"imp":                  {"false"},
		"logo_type":            {"default"},
		"ptoken":               {"novel_pugc"},
		"sprite_image_version": {"1"},
		"ssl":                  {"true"},
		"stream_type":          {"normal"},
		"update_version_code":  {versionCode},
		"version_code":         {versionCode},
		"vps":                  {"6"},
	}
	if deviceID != "" && hongguoNumericID.MatchString(deviceID) {
		query.Set("device_id", deviceID)
	}
	if userID != "" && hongguoNumericID.MatchString(userID) {
		query.Set("user_id", userID)
	}
	target := hongguoFplayBase + url.PathEscape(hash) + "/" + url.PathEscape(videoID) + "?" + query.Encode()
	body, err := d.fetchProviderText(ctx, target, "https://novel.snssdk.com/")
	if err != nil {
		return providerMedia{}, fmt.Errorf("红果官方取流失败: %w", err)
	}
	return parseHongguoFplayResponse(body)
}

// validHongguoFplayHash 校验 hash 段：十六进制，长度 16~64。
func validHongguoFplayHash(value string) bool {
	if len(value) < 16 || len(value) > 64 {
		return false
	}
	for index := 0; index < len(value); index++ {
		ch := value[index]
		if (ch >= '0' && ch <= '9') || (ch >= 'a' && ch <= 'f') || (ch >= 'A' && ch <= 'F') {
			continue
		}
		return false
	}
	return true
}

// hongguoFplayResponse 官方取流响应（字段与 video_model 同构）。
type hongguoFplayResponse struct {
	Data struct {
		VideoInfo struct {
			VideoList json.RawMessage `json:"video_list"`
		} `json:"video_info"`
	} `json:"data"`
	VideoInfo struct {
		VideoList json.RawMessage `json:"video_list"`
	} `json:"video_info"`
}

// parseHongguoFplayResponse 解析 fplay 响应为 providerMedia。
func parseHongguoFplayResponse(body string) (providerMedia, error) {
	text := strings.TrimSpace(body)
	if text == "" {
		return providerMedia{}, errors.New("红果官方取流未返回数据")
	}
	var parsed map[string]any
	decoder := json.NewDecoder(strings.NewReader(text))
	decoder.UseNumber()
	if err := decoder.Decode(&parsed); err != nil || parsed == nil {
		return providerMedia{}, errors.New("红果官方取流返回格式异常")
	}
	if code := mapString(parsed, "code", "Code"); code != "" && code != "0" {
		return providerMedia{}, fmt.Errorf("红果官方取流暂不可用（%s）", truncate(code, 20))
	}
	for _, candidate := range []map[string]any{
		nestedMap(parsed, "data", "video_info"),
		nestedMap(parsed, "video_info"),
		nestedMap(parsed, "data"),
	} {
		if len(candidate) == 0 {
			continue
		}
		model := map[string]any{}
		switch typed := candidate["video_list"].(type) {
		case nil:
			// video_list 可能直接平铺在 candidate 上
			model = candidate
		case string:
			parsedModel := hongguoVideoModel(typed)
			if len(parsedModel) > 0 {
				model = parsedModel
			}
		case map[string]any, []any:
			model = candidate
		}
		if len(model) == 0 {
			continue
		}
		if media, err := selectHongguoAppMedia(model); err == nil {
			return media, nil
		}
	}
	return providerMedia{}, errors.New("红果官方取流未返回可用媒体")
}

// hongguoFallbackHash 从 video_model 的 fallback_api 中提取 hash 段。
//
// 形如 https://vas-lf-x.snssdk.com/video/fplay/1/{hash}/{vid}?...
func hongguoFallbackHash(value any) string {
	address := hongguoFallbackAddress(value)
	if address == "" {
		return ""
	}
	parsed, err := url.Parse(address)
	if err != nil {
		return ""
	}
	segments := strings.Split(strings.Trim(parsed.Path, "/"), "/")
	// 期望形态：video/fplay/1/{hash}/{vid}
	for index := 0; index+1 < len(segments); index++ {
		if segments[index] == "1" && validHongguoFplayHash(segments[index+1]) {
			return segments[index+1]
		}
	}
	return ""
}

// hongguoFplayMedia 在 App 取流失败后，用 video_model 内的 fallback hash 走官方通道。
func (d *Downloader) hongguoFplayMedia(ctx context.Context, model map[string]any, videoID string) (providerMedia, bool) {
	hash := hongguoFallbackHash(model["fallback_api"])
	if hash == "" {
		return providerMedia{}, false
	}
	media, err := d.resolveHongguoFplayMedia(ctx, hash, videoID, "", "")
	if err != nil {
		return providerMedia{}, false
	}
	return media, true
}

var _ = base64.StdEncoding
var _ = strconv.Itoa
var _ = time.Now
