package core

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"sync"
)

// 红果上游参数的外部化配置（0.7.18）。
//
// 目的：红果改"参数类"内容（UA、版本号、接口域名、允许的签名组合）时，
// 不必重新发版——App 启动时拉一份远程 JSON 下发到核心，缓存到 dataDir，
// 拉不到就用内置默认值。改"逻辑类"（签名算法/注册协议）仍需发版。
//
// 安全边界：只接受白名单字段与受限取值（域名必须是 fqnovel.com 子域，
// 组合只能是已知三种），避免远程配置被滥用成任意请求。

const upstreamConfigFileName = "upstream_config.json"

type upstreamConfig struct {
	PlaybackUA   string   `json:"hongguoPlaybackUA"`
	VersionCode  string   `json:"hongguoVersionCode"`
	VersionName  string   `json:"hongguoVersionName"`
	Hosts        []string `json:"hongguoHosts"`
	PlaybackModes []string `json:"hongguoPlaybackModes"`
}

func defaultUpstreamConfig() upstreamConfig {
	return upstreamConfig{
		PlaybackUA:    hongguoPlaybackUADefault,
		VersionCode:   "71332",
		VersionName:   "7.1.3.32",
		Hosts:         []string{"api5-normal-sinfonlineb.fqnovel.com", "api5-normal-hl.fqnovel.com"},
		PlaybackModes: []string{hongguoPlaybackModeSignedRegistered, hongguoPlaybackModeUnsignedRegistered, hongguoPlaybackModeSignedSynthetic},
	}
}

const hongguoPlaybackUADefault = "com.phoenix.read/71532 (Linux; U; Android 9; SM-N9860; Build/PQ3A.190705.10241111;tt-ok/3.12.13.20)"

var (
	upstreamConfigMu     sync.RWMutex
	upstreamConfigValue  = defaultUpstreamConfig()
	upstreamConfigLoaded bool
)

// upstreamConfigPath 配置文件路径（dataDir 为空时返回空）。
func upstreamConfigPath(dataDir string) string {
	if dataDir == "" {
		return ""
	}
	return filepath.Join(dataDir, upstreamConfigFileName)
}

// loadUpstreamConfig 首次使用时从磁盘读取缓存配置（失败保持默认）。
func loadUpstreamConfig(dataDir string) upstreamConfig {
	upstreamConfigMu.Lock()
	defer upstreamConfigMu.Unlock()
	if upstreamConfigLoaded {
		return upstreamConfigValue
	}
	upstreamConfigLoaded = true
	path := upstreamConfigPath(dataDir)
	if path == "" {
		return upstreamConfigValue
	}
	content, err := os.ReadFile(path)
	if err != nil {
		return upstreamConfigValue
	}
	if parsed, err := parseUpstreamConfig(content); err == nil {
		upstreamConfigValue = parsed
	}
	return upstreamConfigValue
}

// upstreamConfigSnapshot 读取当前生效配置（副本）。
func upstreamConfigSnapshot() upstreamConfig {
	upstreamConfigMu.RLock()
	defer upstreamConfigMu.RUnlock()
	config := upstreamConfigValue
	config.Hosts = append([]string(nil), config.Hosts...)
	config.PlaybackModes = append([]string(nil), config.PlaybackModes...)
	return config
}

// setUpstreamConfig 应用远程配置并持久化（校验不过则不写）。
func setUpstreamConfig(dataDir, text string) error {
	parsed, err := parseUpstreamConfig([]byte(text))
	if err != nil {
		return err
	}
	upstreamConfigMu.Lock()
	upstreamConfigValue = parsed
	upstreamConfigLoaded = true
	upstreamConfigMu.Unlock()
	if path := upstreamConfigPath(dataDir); path != "" {
		content, err := json.Marshal(parsed)
		if err == nil {
			_ = writeNativeCacheFile(path, content)
		}
	}
	return nil
}

// parseUpstreamConfig 解析并校验远程配置；缺失字段沿用默认值。
func parseUpstreamConfig(content []byte) (upstreamConfig, error) {
	var raw map[string]any
	if err := json.Unmarshal(content, &raw); err != nil {
		return upstreamConfig{}, err
	}
	config := defaultUpstreamConfig()
	if value, ok := raw["hongguoPlaybackUA"].(string); ok && strings.TrimSpace(value) != "" {
		if len(value) > 512 {
			return upstreamConfig{}, errors.New("播放 UA 过长")
		}
		config.PlaybackUA = strings.TrimSpace(value)
	}
	if value, ok := raw["hongguoVersionCode"].(string); ok && value != "" {
		if !numericString(value) {
			return upstreamConfig{}, errors.New("version_code 必须是数字")
		}
		config.VersionCode = value
	}
	if value, ok := raw["hongguoVersionName"].(string); ok && value != "" {
		if len(value) > 32 || strings.ContainsAny(value, "\r\n") {
			return upstreamConfig{}, errors.New("version_name 非法")
		}
		config.VersionName = value
	}
	if values, ok := raw["hongguoHosts"].([]any); ok && len(values) > 0 {
		hosts := make([]string, 0, len(values))
		for _, item := range values {
			host, _ := item.(string)
			host = strings.TrimSpace(host)
			if !strings.HasSuffix(strings.ToLower(host), "fqnovel.com") || len(host) > 128 || strings.ContainsAny(host, "/\r\n") {
				continue
			}
			hosts = append(hosts, host)
		}
		if len(hosts) == 0 {
			return upstreamConfig{}, errors.New("域名列表全部非法")
		}
		config.Hosts = hosts
	}
	if values, ok := raw["hongguoPlaybackModes"].([]any); ok && len(values) > 0 {
		modes := make([]string, 0, len(values))
		for _, item := range values {
			mode, _ := item.(string)
			if mode == hongguoPlaybackModeSignedRegistered || mode == hongguoPlaybackModeUnsignedRegistered || mode == hongguoPlaybackModeSignedSynthetic {
				modes = append(modes, mode)
			}
		}
		if len(modes) == 0 {
			return upstreamConfig{}, errors.New("播放组合列表全部非法")
		}
		config.PlaybackModes = modes
	}
	return config, nil
}

func numericString(value string) bool {
	if value == "" {
		return false
	}
	for index := 0; index < len(value); index++ {
		if value[index] < '0' || value[index] > '9' {
			return false
		}
	}
	return true
}