package core

import (
	"context"
	"crypto/tls"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"sync"
	"time"
)

// 黄豆站点专用的 HTTPS 客户端（0.7.19）。
//
// 背景（2026-11-16 用户实测）：黄豆的两个域名都遇到 TLS 问题——
//   - `tideember.cc`：连接被重置（ECONNRESET）
//   - `xqjurgek.top`：证书已于 2026-11-06 过期
// 但用户在浏览器里「继续访问」后站点内容正常，说明站点本身还在服务，
// 只是证书失效。Go 的 HTTP 客户端默认严格校验证书，因此直接拒绝连接。
//
// 处理：只对「黄豆」这一个源跳过证书校验，其他源保持严格校验。
//
// 风险说明（必须保留）：跳过证书校验意味着无法验证服务器身份，理论上存在
// 中间人风险。该源只用于抓取公开短剧列表/详情/播放地址，不传输账号密码等
// 凭据，风险可控。若站点恢复有效证书，应移除本文件并在 requestAllowInsecureTLS
// 里关闭。
//
// 注意：这里不复用 Downloader 的主 client，因为主 client 带着代理路由、
// 限流与 TLS 指纹伪装，改它的配置会影响其他源。

var (
	huangdouInsecureOnce   sync.Once
	huangdouInsecureClient *http.Client
)

// huangdouHTTPClient 返回黄豆专用的宽松校验客户端（首次调用时创建）。
func huangdouHTTPClient() *http.Client {
	huangdouInsecureOnce.Do(func() {
		transport := &http.Transport{
			TLSClientConfig:       &tls.Config{InsecureSkipVerify: true},
			MaxIdleConnsPerHost:   4,
			IdleConnTimeout:       60 * time.Second,
			TLSHandshakeTimeout:   15 * time.Second,
			ResponseHeaderTimeout: 20 * time.Second,
			DialContext: (&net.Dialer{
				Timeout:   12 * time.Second,
				KeepAlive: 30 * time.Second,
			}).DialContext,
			Proxy: huangdouProxyFromEnvironment,
		}
		huangdouInsecureClient = &http.Client{
			Transport: transport,
			Timeout:   25 * time.Second,
			CheckRedirect: func(request *http.Request, via []*http.Request) error {
				if len(via) >= 5 {
					return fmt.Errorf("黄豆请求重定向次数过多")
				}
				return nil
			},
		}
	})
	return huangdouInsecureClient
}

// huangdouProxyFromEnvironment 跟随系统代理（用户开 VPN 时也能走代理）。
func huangdouProxyFromEnvironment(request *http.Request) (*url.URL, error) {
	return http.ProxyFromEnvironment(request)
}

// huangdouGetText 用宽松客户端抓取黄豆域的文本（如 m3u8 播放列表）。
//
// 播放列表地址同样在 xqjurgek.top 下，证书过期时会被严格校验拦截。
func huangdouGetText(ctx context.Context, d *Downloader, address, referer string) (string, error) {
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, address, nil)
	if err != nil {
		return "", err
	}
	request.Header.Set("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120 Safari/537.36")
	request.Header.Set("Accept", "*/*")
	if referer != "" {
		request.Header.Set("Referer", referer)
	}
	if d != nil && d.limiter != nil {
		release, err := d.limiter.acquire(ctx, request)
		if err != nil {
			return "", err
		}
		defer release()
	}
	response, body, err := huangdouDo(nil, request, 20*time.Second)
	if err != nil {
		return "", err
	}
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		return "", fmt.Errorf("黄豆播放列表 HTTP %d", response.StatusCode)
	}
	return string(body), nil
}

// huangdouDo 用宽松客户端发请求（黄豆专用）。
//
// 仍然走 Downloader 的限流器：绕过它会与其他请求抢上游配额。
func huangdouDo(c *huangdouAPIClient, request *http.Request, timeout time.Duration) (*http.Response, []byte, error) {
	if c != nil && c.d != nil && c.d.limiter != nil {
		release, err := c.d.limiter.acquire(request.Context(), request)
		if err != nil {
			return nil, nil, err
		}
		defer release()
	}
	if timeout > 0 {
		ctx, cancel := context.WithTimeout(request.Context(), timeout)
		defer cancel()
		request = request.WithContext(ctx)
	}
	response, err := huangdouHTTPClient().Do(request)
	if err != nil {
		return nil, nil, err
	}
	defer response.Body.Close()
	body, readErr := io.ReadAll(io.LimitReader(response.Body, providerMaxBodyBytes+1))
	if readErr != nil {
		return response, nil, readErr
	}
	if len(body) > providerMaxBodyBytes {
		return response, nil, fmt.Errorf("huangdou response exceeds %d bytes", providerMaxBodyBytes)
	}
	return response, body, nil
}
