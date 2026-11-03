package core

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/url"
	"sort"
	"strconv"
	"strings"
	"time"
)

// resolveHongguoAppMedia 取某集的 App 直链（0.7.18 起走组合矩阵）。
//
// 红果在同一个播放接口上反复横跳（要签名 / 不要签名 / 要签名+注册身份），
// 只押一条路必然"刚修完又坏"。现在由 `provider_hongguo_playback_matrix.go`
// 按「上次成功优先」依次尝试「签名开关 × 身份来源 × 主备域名」，
// 这里只负责短缓存与选流。
func (downloader *Downloader) resolveHongguoAppMedia(ctx context.Context, videoID string) (providerMedia, error) {
	if !hongguoNumericID.MatchString(videoID) {
		return providerMedia{}, errors.New("红果视频 ID 无效")
	}
	// 同一集 10 分钟内重复打开不再请求上游（减少被判重/风控的机会）。
	if cached, hit := hongguoMediaCacheGet(videoID); hit {
		return cached, nil
	}
	model, modelErr := downloader.hongguoPlaybackModel(ctx, videoID)
	if modelErr == nil {
		if media, err := downloader.hongguoMediaFromModel(ctx, model); err == nil {
			hongguoMediaCachePut(videoID, media)
			return media, nil
		} else {
			modelErr = err
		}
	}
	hongguoMediaCacheDrop(videoID)
	return providerMedia{}, fmt.Errorf("红果取流失败：%w", modelErr)
}

// hongguoMediaFromModel 从 video_model 选流；只在必要时跟随 `fallback_api`。
func (downloader *Downloader) hongguoMediaFromModel(ctx context.Context, model map[string]any) (providerMedia, error) {
	if len(model) == 0 {
		return providerMedia{}, errors.New("红果未返回片源模型")
	}
	if media, err := selectHongguoAppMedia(model); err == nil {
		return media, nil
	} else if media, ok := downloader.hongguoFallbackMedia(ctx, model); ok {
		return media, nil
	} else {
		return providerMedia{}, err
	}
}

// hongguoSignedPlaybackModel 走六头签名路径取 video_model（0.7.16 及以前的方式，保留兜底）。
func (downloader *Downloader) hongguoSignedPlaybackModel(ctx context.Context, videoID string) (map[string]any, error) {
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
		return nil, errors.New("红果 App 未返回该集播放信息")
	}
	return model, nil
}

// hongguoVideoModel 把 `video_model`（可能是 JSON 字符串或对象）转成 map。
func hongguoVideoModel(value any) map[string]any {
	switch typed := value.(type) {
	case string:
		var parsed map[string]any
		decoder := json.NewDecoder(strings.NewReader(typed))
		decoder.UseNumber()
		if decoder.Decode(&parsed) != nil {
			return map[string]any{}
		}
		return parsed
	case map[string]any:
		return typed
	}
	return map[string]any{}
}

// hongguoFallbackMedia 跟随 `fallback_api` 二次取片源。
func (downloader *Downloader) hongguoFallbackMedia(ctx context.Context, model map[string]any) (providerMedia, bool) {
	address := hongguoFallbackAddress(model["fallback_api"])
	if address == "" {
		return providerMedia{}, false
	}
	parsed, err := url.Parse(address)
	if err != nil || parsed.Scheme != "https" || (!strings.HasSuffix(parsed.Hostname(), "fqnovel.com") && !strings.HasSuffix(parsed.Hostname(), "snssdk.com")) {
		return providerMedia{}, false
	}
	text, err := downloader.fetchProviderText(ctx, address, hongguoBaseURL+"/")
	if err != nil {
		return providerMedia{}, false
	}
	var outer map[string]any
	decoder := json.NewDecoder(strings.NewReader(text))
	decoder.UseNumber()
	if decoder.Decode(&outer) != nil {
		return providerMedia{}, false
	}
	info := nestedMap(outer, "video_info", "data")
	if len(info) == 0 {
		return providerMedia{}, false
	}
	if media, err := selectHongguoAppMedia(info); err == nil {
		return media, true
	}
	return providerMedia{}, false
}

// hongguoFallbackAddress 解析 `fallback_api` 的多种形态。
func hongguoFallbackAddress(value any) string {
	switch typed := value.(type) {
	case string:
		var parsed map[string]any
		decoder := json.NewDecoder(strings.NewReader(typed))
		if decoder.Decode(&parsed) == nil {
			if address, ok := parsed["fallback_api"].(string); ok {
				return address
			}
		}
		return typed
	case []any:
		if len(typed) == 0 {
			return ""
		}
		address, _ := typed[0].(string)
		return address
	case map[string]any:
		address, _ := typed["fallback_api"].(string)
		return address
	}
	return ""
}

func selectHongguoAppMedia(model map[string]any) (providerMedia, error) {
	variants := anyList(model["video_list"])
	if rows, ok := model["video_list"].(map[string]any); ok && len(variants) == 0 {
		keys := make([]string, 0, len(rows))
		for key := range rows {
			keys = append(keys, key)
		}
		sort.Strings(keys)
		for _, key := range keys {
			variants = append(variants, rows[key])
		}
	}
	duration, _ := strconv.ParseFloat(mapString(model, "video_duration", "duration"), 64)
	var keyErr error
	type scoredMedia struct {
		media providerMedia
		score int
	}
	var choices []scoredMedia
	for _, row := range variants {
		variant, _ := row.(map[string]any)
		meta := nestedMap(variant, "video_meta")
		codec := strings.ToLower(mapString(meta, "codec_type"))
		if codec == "bytevc2" || strings.Contains(strings.ToLower(mapString(variant, "gear_des_key")), "bytevc2") {
			continue
		}
		addresses := hongguoMediaAddresses(variant)
		if len(addresses) == 0 {
			continue
		}
		media := providerMedia{Referer: "https://novel.snssdk.com/", Duration: time.Duration(duration * float64(time.Second))}
		encryption := nestedMap(variant, "encrypt_info")
		spade := mapString(encryption, "spade_a")
		if spade != "" || encryption["encrypt"] == true || mapString(encryption, "encryption_method") == "cenc-aes-ctr" {
			var err error
			media.CENCKey, err = hongguoContentKey(spade)
			if err != nil {
				keyErr = err
				continue
			}
		}
		height, _ := strconv.Atoi(mapString(meta, "vheight"))
		if definition, err := strconv.Atoi(hongguoQualityNumber.FindString(mapString(meta, "definition"))); err == nil && definition > 0 {
			height = definition
		} else if width, _ := strconv.Atoi(mapString(meta, "vwidth")); width > 0 && (height == 0 || width < height) {
			height = width
		}
		media.Quality = height
		quality := height * 10
		if codec == "h264" || codec == "avc1" {
			quality++
		}
		for _, address := range addresses {
			media.URL = address
			choices = append(choices, scoredMedia{media: media, score: quality})
		}
	}
	if len(choices) > 0 {
		sort.SliceStable(choices, func(i, j int) bool { return choices[i].score > choices[j].score })
		selected := choices[0].media
		for _, choice := range choices {
			selected.Variants = append(selected.Variants, choice.media)
		}
		return selected, nil
	}
	if keyErr != nil {
		return providerMedia{}, fmt.Errorf("红果 App 媒体密钥不可用: %w", keyErr)
	}
	return providerMedia{}, errors.New("红果 App 未返回兼容的媒体，已跳过不支持的编码")
}

func hongguoMediaAddresses(info map[string]any) []string {
	var addresses []string
	seen := map[string]bool{}
	var add func(any)
	add = func(value any) {
		switch value := value.(type) {
		case string:
			address := strings.TrimSpace(value)
			if len(address) > 8192 {
				return
			}
			if !isProviderHTTPMediaURL(address) {
				decoded, err := decodeHongguoBase64(address)
				if err != nil {
					return
				}
				address = strings.TrimSpace(string(decoded))
			}
			if isProviderHTTPMediaURL(address) && !seen[address] {
				seen[address] = true
				addresses = append(addresses, address)
			}
		case []any:
			for _, item := range value {
				add(item)
			}
		}
	}
	for _, key := range []string{"main_url", "backup_url", "backup_url_1", "backup_url_2", "backup_urls", "url_list"} {
		add(info[key])
	}
	return addresses
}
