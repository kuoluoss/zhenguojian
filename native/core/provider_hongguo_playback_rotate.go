package core

import (
	"sync"
	"time"
)

// 红果播放请求的公共设施：候选域名、成功域名记忆、身份重置、query 编码（0.7.18）。
//
// 具体「签名开关 × 身份来源 × 域名」的组合与重试编排见
// `provider_hongguo_playback_matrix.go`；匿名设备注册见
// `provider_hongguo_playback_device.go`。

// hongguoPlaybackHostList 播放接口候选域名（可由远程配置下发）。
func hongguoPlaybackHostList() []string {
	config := upstreamConfigSnapshot()
	if len(config.Hosts) == 0 {
		return defaultUpstreamConfig().Hosts
	}
	return config.Hosts
}
// 上一次成功的域名（组合记忆的补充，供日志与排障用）。
var (
	hongguoPlaybackHostMu sync.Mutex
	hongguoPlaybackHost   = defaultUpstreamConfig().Hosts[0]
)

func hongguoPlaybackRememberHost(host string) {
	if host == "" {
		return
	}
	hongguoPlaybackHostMu.Lock()
	hongguoPlaybackHost = host
	hongguoPlaybackHostMu.Unlock()
}

func hongguoPlaybackLastHost() string {
	hongguoPlaybackHostMu.Lock()
	defer hongguoPlaybackHostMu.Unlock()
	return hongguoPlaybackHost
}

// resetHongguoPlaybackIdentity 丢弃缓存的匿名身份，下次请求会重新注册。
func resetHongguoPlaybackIdentity() {
	hongguoDeviceMu.Lock()
	hongguoDeviceID, hongguoDeviceInstall, hongguoDeviceFailed = "", "", time.Time{}
	hongguoDeviceMu.Unlock()
}

// urlQueryEscape 复刻上游的 query 编码：保留 A-Za-z0-9-_.~ 与 `*`，
// 其余（含 ! ' ( )）一律 %XX 大写。签名对 query 字节级敏感，不能直接用
// Go 的 url.Values.Encode（它会把 `*` 转成 %2A，与上游实现不一致）。
func urlQueryEscape(raw string) string {
	const hexDigits = "0123456789ABCDEF"
	out := make([]byte, 0, len(raw))
	for index := 0; index < len(raw); index++ {
		b := raw[index]
		if (b >= 'A' && b <= 'Z') || (b >= 'a' && b <= 'z') || (b >= '0' && b <= '9') ||
			b == '-' || b == '_' || b == '.' || b == '~' || b == '*' {
			out = append(out, b)
			continue
		}
		out = append(out, '%', hexDigits[b>>4], hexDigits[b&0x0f])
	}
	return string(out)
}