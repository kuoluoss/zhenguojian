package core

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"

	"duanjuapp/native/core/sign6"
)

// 红果播放「组合矩阵 + 成功组合记忆」（0.7.18）。
//
// 背景：2026-10 至今红果在同一个播放接口上反复横跳——
//   10-22 要六头签名；10-27 改成只认注册身份、不要签名；
//   11-02 又要求「注册身份 + 六头签名」，并给出备用域名。
// 只押一条路就注定"刚修完两天又坏"。这里把可变维度列成候选：
//
//	模式：signed-registered（注册身份 + 签名，11-02 起的主路）
//	      unsigned-registered（注册身份，不要签名，10-27 的路）
//	      signed-synthetic（合成身份 + 签名，10-22 的路）
//	域名：主域 / 备用域
//
// 按「上次成功」的顺序依次尝试，成功后记住（写入 dataDir 下的小文件，
// 重启仍生效），下次直接先走这条。任何一条成功即返回，全部失败才报错。

// hongguoPlaybackPreference 记住上一次成功的组合。
type hongguoPlaybackPreference struct {
	Mode string `json:"mode"`
	Host string `json:"host"`
}

const (
	hongguoPlaybackModeSignedRegistered   = "signed-registered"
	hongguoPlaybackModeUnsignedRegistered = "unsigned-registered"
	hongguoPlaybackModeSignedSynthetic    = "signed-synthetic"
	// 0.7.19：与目录 / 详情完全同构的请求构造（hongguoAppRequest）。
	hongguoPlaybackModeAppRequest = "app-request"
	// 0.7.19：video_tab GET + 真实 551 Argus/Ladon 签名（当前主路径）。
	hongguoPlaybackModeVideoTab = "video-tab"
)

// hongguoPlaybackLastAppRequestErr 记录详情同构路径的失败原因（仅用于报错拼接）。
var hongguoPlaybackLastAppRequestErr error

// hongguoPlaybackModelViaAppRequest 用与详情接口完全一致的构造取 video_model。
//
// 这是 0.7.19 的主路径：目录与详情都靠 `hongguoAppRequest` 工作正常，
// 播放接口此前一直用另手拼的 query + 另一套 UA/头，是唯一的结构性差异。
func (downloader *Downloader) hongguoPlaybackModelViaAppRequest(ctx context.Context, videoID string) (map[string]any, error) {
	payload := map[string]any{
		"biz_param": map[string]any{
			"detail_page_version":       0,
			"device_level":              3,
			"disable_digg_stat":         false,
			"need_all_video_definition": true,
			"need_mp4_align":            false,
			"use_os_player":             false,
			"use_server_dns":            false,
			"video_platform":            1024,
		},
		"mixed_video_id_map": map[string]any{"1004": []string{videoID}},
	}
	extra := url.Values{
		"host_abi":                {"arm64-v8a"},
		"dragon_device_type":      {"phone"},
		"pv_player":               {"73532"},
		"compliance_status":       {"0"},
		"need_personal_recommend": {"1"},
		"player_so_load":          {"1"},
		"is_android_pad_screen":   {"0"},
	}
	result, err := downloader.hongguoAppRequest(ctx, http.MethodPost, "/novel/player/multi_video_model/v1/", extra, payload)
	if err != nil {
		return nil, err
	}
	entry := nestedMap(nestedMap(result, "data"), videoID)
	model := hongguoVideoModel(entry["video_model"])
	if len(model) == 0 {
		// 有些返回把 video_model 放在 data 之下但不以 videoID 为键。
		if fallback := hongguoVideoModel(nestedMap(result, "data")["video_model"]); len(fallback) > 0 {
			return fallback, nil
		}
		return nil, errors.New("红果 App 接口未返回该集播放信息")
	}
	return model, nil
}

var (
	hongguoPlaybackPrefMu     sync.Mutex
	hongguoPlaybackPref       hongguoPlaybackPreference
	hongguoPlaybackPrefLoaded bool
)

func (d *Downloader) hongguoPlaybackPrefPath() string {
	if d.cfg.dataDir == "" {
		return ""
	}
	return filepath.Join(d.cfg.dataDir, "hongguo_playback_pref.json")
}

func (d *Downloader) loadHongguoPlaybackPref() hongguoPlaybackPreference {
	hongguoPlaybackPrefMu.Lock()
	defer hongguoPlaybackPrefMu.Unlock()
	if hongguoPlaybackPrefLoaded {
		return hongguoPlaybackPref
	}
	hongguoPlaybackPrefLoaded = true
	path := d.hongguoPlaybackPrefPath()
	if path == "" {
		return hongguoPlaybackPref
	}
	content, err := os.ReadFile(path)
	if err != nil {
		return hongguoPlaybackPref
	}
	var pref hongguoPlaybackPreference
	if json.Unmarshal(content, &pref) == nil {
		hongguoPlaybackPref = pref
	}
	return hongguoPlaybackPref
}

func (d *Downloader) saveHongguoPlaybackPref(pref hongguoPlaybackPreference) {
	hongguoPlaybackPrefMu.Lock()
	changed := hongguoPlaybackPref != pref
	hongguoPlaybackPref = pref
	hongguoPlaybackPrefMu.Unlock()
	if !changed {
		return
	}
	path := d.hongguoPlaybackPrefPath()
	if path == "" {
		return
	}
	content, err := json.Marshal(pref)
	if err != nil {
		return
	}
	_ = writeNativeCacheFile(path, content)
}

// hongguoPlaybackCandidate 一条可尝试的播放组合。
type hongguoPlaybackCandidate struct {
	mode string
	host string
}

func (candidate hongguoPlaybackCandidate) label() string {
	if candidate.host == "" {
		return candidate.mode
	}
	return candidate.mode + "@" + candidate.host
}

// hongguoPlaybackCandidateOrder 生成候选顺序：上次成功的组合优先，其余按固定顺序补足。
func (downloader *Downloader) hongguoPlaybackCandidateOrder() []hongguoPlaybackCandidate {
	preferred := downloader.loadHongguoPlaybackPref()
	config := upstreamConfigSnapshot()
	hosts := config.Hosts
	if len(hosts) == 0 {
		hosts = defaultUpstreamConfig().Hosts
	}
	modes := config.PlaybackModes
	if len(modes) == 0 {
		modes = defaultUpstreamConfig().PlaybackModes
	}
	base := make([]hongguoPlaybackCandidate, 0, len(modes)*(len(hosts)+1))
	for _, mode := range modes {
		if mode == hongguoPlaybackModeSignedSynthetic {
			base = append(base, hongguoPlaybackCandidate{mode, ""})
			continue
		}
		for _, host := range hosts {
			base = append(base, hongguoPlaybackCandidate{mode, host})
		}
	}
	order := make([]hongguoPlaybackCandidate, 0, len(base))
	if preferred.Mode != "" {
		order = append(order, hongguoPlaybackCandidate{preferred.Mode, preferred.Host})
	}
	for _, candidate := range base {
		if candidate.mode == preferred.Mode && candidate.host == preferred.Host {
			continue
		}
		order = append(order, candidate)
	}
	return order
}

// hongguoPlaybackModel 按组合矩阵取某集的 video_model（含换身份、换域、退避）。
func (downloader *Downloader) hongguoPlaybackModel(ctx context.Context, videoID string) (map[string]any, error) {
	// 0.7.19 主路径：video_tab GET + 真实 551 Argus/Ladon 签名 + 每次 fresh 身份。
	//
	// 这是 2026-11-11 起播放全空的真正修复：旧 sign6 的 x-argus / x-ladon
	// 只是 le32/be32(khronos) 的时间戳占位，不是上游校验的真实签名；
	// 上游收紧后对这种占位一律回「HTTP 200 + 0 字节」，换端点/参数/身份/出口都无效。
	if model, err := downloader.hongguoVideoTabModel(ctx, videoID); err == nil {
		downloader.saveHongguoPlaybackPref(hongguoPlaybackPreference{Mode: hongguoPlaybackModeVideoTab})
		return model, nil
	} else {
		hongguoPlaybackLastAppRequestErr = err
	}
	// 次选：与详情同构的 POST 构造（保留作为兜底）
	if model, err := downloader.hongguoPlaybackModelViaAppRequest(ctx, videoID); err == nil {
		downloader.saveHongguoPlaybackPref(hongguoPlaybackPreference{Mode: hongguoPlaybackModeAppRequest})
		return model, nil
	} else {
		hongguoPlaybackLastAppRequestErr = err
	}
	candidates := downloader.hongguoPlaybackCandidateOrder()
	var lastErr error
	attempted := 0
	for index, candidate := range candidates {
		if ctx.Err() != nil {
			return nil, ctx.Err()
		}
		if attempted > 0 {
			select {
			case <-time.After(250 * time.Millisecond):
			case <-ctx.Done():
				return nil, ctx.Err()
			}
		}
		// 每试完两种组合换一次身份：被判重的身份继续用只会一直空。
		if attempted > 0 && attempted%2 == 0 {
			resetHongguoPlaybackIdentity()
		}
		attempted++
		model, err := downloader.hongguoPlaybackAttempt(ctx, candidate, videoID)
		if err == nil {
			downloader.saveHongguoPlaybackPref(hongguoPlaybackPreference{Mode: candidate.mode, Host: candidate.host})
			if candidate.host != "" {
				hongguoPlaybackRememberHost(candidate.host)
			}
			_ = index
			return model, nil
		}
		lastErr = err
	}
	if lastErr == nil {
		lastErr = errors.New("红果播放接口无可用组合")
	}
	return nil, fmt.Errorf("红果播放全部组合失败：%w", lastErr)
}

// hongguoPlaybackAttempt 尝试一条组合。
func (downloader *Downloader) hongguoPlaybackAttempt(ctx context.Context, candidate hongguoPlaybackCandidate, videoID string) (map[string]any, error) {
	if candidate.mode == hongguoPlaybackModeSignedSynthetic {
		return downloader.hongguoSignedPlaybackModel(ctx, videoID)
	}
	deviceID, installID, err := downloader.hongguoPlaybackIdentity(ctx)
	if err != nil {
		return nil, err
	}
	signed := candidate.mode == hongguoPlaybackModeSignedRegistered
	return downloader.hongguoPlaybackCall(ctx, candidate.host, deviceID, installID, videoID, signed)
}

// hongguoPlaybackCall 发一次播放请求（可选签名）。
func (downloader *Downloader) hongguoPlaybackCall(ctx context.Context, host, deviceID, installID, videoID string, signed bool) (map[string]any, error) {
	payload, err := json.Marshal(map[string]any{
		"biz_param": map[string]any{
			"detail_page_version":       0,
			"device_level":              3,
			"disable_digg_stat":         false,
			"need_all_video_definition": true,
			"need_mp4_align":            false,
			"use_os_player":             false,
			"use_server_dns":            false,
			"video_platform":            1024,
		},
		"mixed_video_id_map": map[string]any{"1004": []string{videoID}},
	})
	if err != nil {
		return nil, err
	}
	khronos := time.Now().Unix()
	ticketBase := time.Now().UnixMilli()
	api := "https://" + host + "/novel/player/multi_video_model/v1/"
	target := ""
	ticket := ticketBase
	if signed {
		// 上游实现：抖动 _rticket 直到 branchOf(query, body, ts) === 0，其它分支服务端不认。
		for offset := 0; offset < 128; offset++ {
			ticket = ticketBase + int64(offset)
			target = api + "?" + hongguoPlaybackQuery(deviceID, installID, khronos, ticket)
			if sign6.BranchOf(target, payload, khronos) == 0 {
				break
			}
		}
	} else {
		target = api + "?" + hongguoPlaybackQuery(deviceID, installID, khronos, ticket)
	}

	request, err := http.NewRequestWithContext(ctx, http.MethodPost, target, bytes.NewReader(payload))
	if err != nil {
		return nil, err
	}
	request.Header.Set("User-Agent", upstreamConfigSnapshot().PlaybackUA)
	request.Header.Set("Accept", "application/json; charset=utf-8,application/x-protobuf")
	request.Header.Set("Content-Type", "application/json; charset=UTF-8")
	request.Header.Set("x-ss-req-ticket", strconv.FormatInt(ticket, 10))
	request.Header.Set("sdk-version", "2")
	request.Header.Set("x-xs-from-web", "0")
	if signed {
		for key, value := range sign6.Sign(target, payload, khronos) {
			request.Header.Set(key, value)
		}
		request.Header.Set("x-tt-dt", "")
		request.Header.Set("x-tt-store-region", "cn")
		request.Header.Set("x-tt-store-region-src", "did")
	}

	response, err := downloader.doPreparedCatalogRequest(request, 15*time.Second, nil)
	if err != nil {
		return nil, err
	}
	defer response.Body.Close()
	content, err := io.ReadAll(io.LimitReader(response.Body, providerMaxBodyBytes+1))
	if err != nil {
		return nil, err
	}
	if response.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("红果播放接口 HTTP %d", response.StatusCode)
	}
	if len(content) == 0 {
		return nil, errors.New("红果播放接口未返回数据")
	}
	var parsed map[string]any
	decoder := json.NewDecoder(bytes.NewReader(content))
	decoder.UseNumber()
	if err := decoder.Decode(&parsed); err != nil || parsed == nil {
		return nil, errors.New("红果播放接口返回格式异常")
	}
	if code := mapString(parsed, "code", "Code"); code != "" && code != "0" {
		return nil, fmt.Errorf("红果播放接口暂不可用（%s）", truncate(code, 20))
	}
	entry := nestedMap(nestedMap(parsed, "data"), videoID)
	model := hongguoVideoModel(entry["video_model"])
	if len(model) == 0 {
		return nil, errors.New("红果播放接口未返回该集片源")
	}
	return model, nil
}

// hongguoPlaybackQuery 按上游顺序拼 query：设备字段 → device_id/iid → ts → _rticket。
func hongguoPlaybackQuery(deviceID, installID string, khronos, ticket int64) string {
	config := upstreamConfigSnapshot()
	versionCode := config.VersionCode
	if versionCode == "" {
		versionCode = defaultUpstreamConfig().VersionCode
	}
	versionName := config.VersionName
	if versionName == "" {
		versionName = defaultUpstreamConfig().VersionName
	}
	fields := [][2]string{
		{"ac", "wifi"}, {"channel", "update_64"}, {"aid", "8662"}, {"app_name", "novelread"},
		{"version_code", versionCode}, {"version_name", versionName}, {"device_platform", "android"},
		{"os", "android"}, {"ssmix", "a"}, {"device_type", "25053RT47C"}, {"device_brand", "Redmi"},
		{"language", "zh"}, {"os_api", "36"}, {"os_version", "16"}, {"manifest_version_code", versionCode},
		{"resolution", "1280*2772"}, {"dpi", "520"}, {"update_version_code", versionCode},
		{"host_abi", "arm64-v8a"}, {"dragon_device_type", "phone"}, {"pv_player", versionCode},
		{"compliance_status", "0"}, {"need_personal_recommend", "1"}, {"player_so_load", "1"},
		{"is_android_pad_screen", "0"},
		{"device_id", deviceID}, {"iid", installID},
		{"ts", strconv.FormatInt(khronos, 10)},
		{"_rticket", strconv.FormatInt(ticket, 10)},
	}
	// 0.7.19：支持用远程配置覆盖设备画像字段，
	// 便于「设备画像与注册身份不一致 → 播放空响应」时不必发版即可校准。
	overrides := upstreamConfigSnapshot().DeviceProfile
	for key, value := range overrides {
		for index := range fields {
			if fields[index][0] == key {
				fields[index][1] = value
			}
		}
	}
	parts := make([]string, 0, len(fields))
	for _, field := range fields {
		parts = append(parts, urlQueryEscape(field[0])+"="+urlQueryEscape(field[1]))
	}
	return strings.Join(parts, "&")
}