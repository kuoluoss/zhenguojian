package core

import (
	"compress/gzip"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"
)

// 红果播放请求（0.7.19 重写）：真实 551 Argus + Ladon 签名 + video_tab GET 首选。
//
// 与旧实现的差异（这是 2026-11-11 起播放全空的根因）：
//  1. 旧 `sign6` 的 x-argus / x-ladon 只是时间戳占位，上游收紧后一律 200+0 字节；
//  2. 首选端点是 GET `/reading/bookapi/video_tab/multi_video_model/v1/`，
//     业务参数放 query，无正文；空响应才退回 POST `multi_video_model/v1/`；
//  3. 播放身份一次性：每次取流重新注册匿名设备（复用会被判重）。

// hongguoVideoTabAPI video_tab 首选取址端点。
const hongguoVideoTabAPI = "https://api5-normal-sinfonlineb.fqnovel.com/reading/bookapi/video_tab/multi_video_model/v1/"

// hongguoVideoTabDevice video_tab 模式使用的客户端版本（与注册 body 一致）。
var hongguoVideoTabDevice = map[string]string{
	"aid":                   "8662",
	"app_name":              "novelread",
	"version_code":          "73932",
	"version_name":          "7.3.9.32",
	"manifest_version_code": "73932",
	"update_version_code":   "73932",
	"channel":               "update_64",
	"device_platform":       "android",
	"os":                    "android",
	"ssmix":                 "a",
	"device_type":           "25053RT47C",
	"device_brand":          "Redmi",
	"language":              "zh",
	"os_api":                "36",
	"os_version":            "16",
	"resolution":            "1280*2772",
	"dpi":                   "520",
	"ac":                      "wifi",
	"host_abi":                "arm64-v8a",
	"dragon_device_type":      "phone",
	"pv_player":               "73932",
	"compliance_status":       "0",
	"need_personal_recommend": "1",
	"player_so_load":          "1",
	"is_android_pad_screen":   "0",
}

// hongguoVideoTabUserAgent video_tab 请求的 UA：版本号必须与 query 的 version_code 一致，
// 与其它接口共用的 UA（73532）对不上会被上游判为参数非法。
func hongguoVideoTabUserAgent() string {
	return strings.Replace(hongguoAppUserAgent, "73532", hongguoVideoTabDevice["version_code"], 1)
}

// hongguoVideoTabModel 走 video_tab GET 取某集的 video_model。
func (d *Downloader) hongguoVideoTabModel(ctx context.Context, videoID string) (map[string]any, error) {
	identity, err := d.hongguoFreshPlaybackIdentity(ctx)
	if err != nil {
		return nil, err
	}
	khronos := time.Now().Unix()
	ticket := time.Now().UnixMilli()

	// 业务参数（上游 6.7 形态：全字符串、含空的 from_video_id）
	values := [][2]string{
		{"video_id", videoID},
		{"video_id_type", "0"},
		{"device_level", "1"},
		{"need_all_video_definition", "1"},
		{"need_mp4_align", "0"},
		{"use_os_player", "0"},
		{"video_platform", "1024"},
		{"source", "0"},
		{"from_video_id", ""},
	}
	// 拼 query：设备字段 → device_id/iid/cdid → 业务参数 → ts/_rticket
	var parts []string
	appendPair := func(key, value string) {
		parts = append(parts, hongguoPyEncode(key)+"="+hongguoPyEncode(value))
	}
	for _, key := range []string{
		"aid", "app_name", "version_code", "version_name", "manifest_version_code",
		"update_version_code", "channel", "device_platform", "os", "ssmix",
		"device_type", "device_brand", "language", "os_api", "os_version",
		"resolution", "dpi", "ac", "host_abi", "dragon_device_type",
		"pv_player", "compliance_status", "need_personal_recommend",
		"player_so_load", "is_android_pad_screen",
	} {
		appendPair(key, hongguoVideoTabDevice[key])
	}
	appendPair("device_id", identity.deviceID)
	appendPair("iid", identity.installID)
	if identity.cdid != "" {
		appendPair("cdid", identity.cdid)
	}
	for _, pair := range values {
		appendPair(pair[0], pair[1])
	}
	appendPair("ts", strconv.FormatInt(khronos, 10))
	appendPair("_rticket", strconv.FormatInt(ticket, 10))
	query := strings.Join(parts, "&")

	signature, err := hongguoPlaybackSignHeaders(query, nil, khronos)
	if err != nil {
		return nil, err
	}
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, hongguoVideoTabAPI+"?"+query, nil)
	if err != nil {
		return nil, err
	}
	request.Header.Set("User-Agent", hongguoVideoTabUserAgent())
	request.Header.Set("Accept", "application/json; charset=utf-8,application/x-protobuf")
	request.Header.Set("sdk-version", "2")
	request.Header.Set("x-xs-from-web", "0")
	request.Header.Set("passport-sdk-version", "50561")
	request.Header.Set("x-ss-dp", "8662")
	for key, value := range signature {
		request.Header.Set(key, value)
	}
	request.Header.Set("x-tt-dt", "")
	request.Header.Set("x-tt-store-region", "cn")
	request.Header.Set("x-tt-store-region-src", "did")
	request.Header.Set("x-tt-request-tag", "t=0;n=0")

	response, err := d.doPreparedCatalogRequest(request, 15*time.Second, nil)
	if err != nil {
		return nil, err
	}
	defer response.Body.Close()
	content, readErr := io.ReadAll(io.LimitReader(response.Body, providerMaxBodyBytes+1))
	if readErr != nil {
		return nil, readErr
	}
	if response.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("红果播放接口 HTTP %d", response.StatusCode)
	}
	if len(content) == 0 {
		return nil, fmt.Errorf("红果播放接口未返回数据（HTTP 200 空响应）")
	}
	var parsed map[string]any
	decoder := json.NewDecoder(strings.NewReader(string(content)))
	decoder.UseNumber()
	if err := decoder.Decode(&parsed); err != nil || parsed == nil {
		return nil, fmt.Errorf("红果播放接口返回格式异常")
	}
	if code := mapString(parsed, "code", "Code"); code != "" && code != "0" {
		return nil, fmt.Errorf("红果播放接口暂不可用（%s）", truncate(code, 20))
	}
	// video_tab：data.video_model_data[vid].video_model；旧 POST：data[vid].video_model
	data := nestedMap(parsed, "data")
	entries := nestedMap(data, "video_model_data")
	if len(entries) == 0 {
		entries = data
	}
	entry := nestedMap(entries, videoID)
	model := hongguoVideoModel(entry["video_model"])
	if len(model) == 0 {
		return nil, fmt.Errorf("红果播放接口未返回该集片源")
	}
	return model, nil
}

// hongguoPlaybackIdentityInfo 播放身份三元组。
type hongguoPlaybackIdentityInfo struct {
	deviceID  string
	installID string
	cdid      string
}

// hongguoFreshPlaybackIdentity 每次取流注册全新匿名身份（复用会被上游判重）。
func (d *Downloader) hongguoFreshPlaybackIdentity(ctx context.Context) (hongguoPlaybackIdentityInfo, error) {
	resetHongguoPlaybackIdentity()
	deviceID, installID, err := d.hongguoPlaybackIdentity(ctx)
	if err != nil {
		return hongguoPlaybackIdentityInfo{}, err
	}
	return hongguoPlaybackIdentityInfo{deviceID: deviceID, installID: installID, cdid: hongguoPlaybackCDID()}, nil
}

// hongguoPyEncode 按 python urllib.parse.quote 的兜底规则编码：
// 只转 !'()，`*` 保持原样（签名对 query 字节级敏感，多编一个字符就对不上）。
func hongguoPyEncode(value string) string {
	encoded := url.QueryEscape(value)
	// Go 的 QueryEscape 会把空格编成 '+'，签名需要 %20
	encoded = strings.ReplaceAll(encoded, "+", "%20")
	// python quote 不编码 *，Go 会编码成 %2A → 还原
	encoded = strings.ReplaceAll(encoded, "%2A", "*")
	return encoded
}

var _ = gzip.NewWriter
