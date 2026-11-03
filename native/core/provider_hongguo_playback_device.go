package core

import (
	"bytes"
	"compress/gzip"
	"context"
	"crypto/aes"
	"crypto/cipher"
	"crypto/md5"
	"crypto/rand"
	"crypto/sha512"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"time"
)

// 红果播放取流：注册匿名设备身份 + 无签名请求（0.7.17）。
//
// 背景（2026-10-30 实测）：红果把播放接口单独改了规则——
// `POST /novel/player/multi_video_model/v1/` 不再接受签名请求：
// 带全套签名头 + 随机合成 device_id/iid 会被**软拦截**（HTTP 200 + 0 字节）；
// 改用平台注册的匿名设备身份、且**不带任何签名头**，才正常返回片源。
//
// 因此播放链路走本文件；列表/目录/详情仍用六头签名（`provider_hongguo_sign.go`）。
// 两条链路互不影响，任一侧规则再变都能单独回退。

const hongguoDeviceRegisterURL = "https://log5-applog-lf.fqnovel.com/service/2/device_register/" +
	"?tt_data=a&cronet_version=8d40f833_2026-03-03&ttnet_version=4.2.243.31-douyin&use_store_region_cookie=1"

const hongguoDeviceRegisterUA = "com.phoenix.read/73932 (Linux; U; Android 16; zh_CN; 25053RT47C; Build/BP2A.250605.031.A3)"

// ttEncrypt 固定盐（与客户端 SDK 一致）。
var hongguoDeviceKDFSalt, _ = hex.DecodeString(
	"4dd4c2e6b83162090e52b3c7a6733ba41cb2462b829ab58a196b39db57177524" +
		"f49baf7f08e8d68d26a72e37c1a95a2f1f05a51892aef2949732b62a38aadd58")

// 注册失败后的重试冷却：冷却期内复用失败结果，避免每个请求都去打上游。
const hongguoDeviceRetryCooldown = time.Minute

var (
	hongguoDeviceMu      sync.Mutex
	hongguoDeviceID      string
	hongguoDeviceInstall string
	hongguoDeviceFailed  time.Time
)

// hongguoPlaybackIdentity 取（必要时先注册）匿名播放设备身份。
func (downloader *Downloader) hongguoPlaybackIdentity(ctx context.Context) (string, string, error) {
	hongguoDeviceMu.Lock()
	defer hongguoDeviceMu.Unlock()
	if hongguoDeviceID != "" && hongguoDeviceInstall != "" {
		return hongguoDeviceID, hongguoDeviceInstall, nil
	}
	if !hongguoDeviceFailed.IsZero() && time.Since(hongguoDeviceFailed) < hongguoDeviceRetryCooldown {
		return "", "", errors.New("红果播放身份暂不可用，请稍后重试")
	}
	deviceID, installID, err := downloader.registerHongguoPlaybackDevice(ctx)
	if err != nil {
		hongguoDeviceFailed = time.Now()
		return "", "", err
	}
	hongguoDeviceID, hongguoDeviceInstall, hongguoDeviceFailed = deviceID, installID, time.Time{}
	return deviceID, installID, nil
}

// registerHongguoPlaybackDevice 调 device_register 注册匿名设备（ttEncrypt 加密请求体）。
func (downloader *Downloader) registerHongguoPlaybackDevice(ctx context.Context) (string, string, error) {
	now := time.Now().UnixMilli()
	body := hongguoDeviceRegisterBody(now)
	request, err := http.NewRequestWithContext(ctx, http.MethodPost, hongguoDeviceRegisterURL, bytes.NewReader(body))
	if err != nil {
		return "", "", err
	}
	request.Header.Set("User-Agent", hongguoDeviceRegisterUA)
	request.Header.Set("Accept", "application/json")
	request.Header.Set("Content-Type", "application/octet-stream;tt-data=a")
	request.Header.Set("log-encode-type", "gzip")
	request.Header.Set("x-ss-dp", "8662")
	request.Header.Set("x-ss-req-ticket", strconv.FormatInt(now, 10))
	request.Header.Set("x-vc-bdturing-sdk-version", "4.0.3.cn")
	request.Header.Set("lc", "101")
	request.Header.Set("sdk-version", "2")
	request.Header.Set("passport-sdk-version", "5051452")
	request.Header.Set("x-neptune", "-8|50:51:59:30:40:47:49:39")
	request.Header.Set("x-ss-stub", strings.ToUpper(fmt.Sprintf("%X", md5.Sum(body))))

	response, err := downloader.doPreparedCatalogRequest(request, 8*time.Second, nil)
	if err != nil {
		return "", "", fmt.Errorf("红果播放身份注册失败: %w", err)
	}
	defer response.Body.Close()
	content, err := io.ReadAll(io.LimitReader(response.Body, 1<<20))
	if err != nil {
		return "", "", fmt.Errorf("红果播放身份注册失败: %w", err)
	}
	if response.StatusCode != http.StatusOK {
		return "", "", fmt.Errorf("红果播放身份注册失败: HTTP %d", response.StatusCode)
	}
	var parsed map[string]any
	decoder := json.NewDecoder(bytes.NewReader(content))
	decoder.UseNumber()
	if err := decoder.Decode(&parsed); err != nil || parsed == nil {
		return "", "", errors.New("红果播放身份注册返回格式异常")
	}
	deviceID := hongguoRegisterID(parsed, "device_id")
	installID := hongguoRegisterID(parsed, "install_id")
	if deviceID == "" || installID == "" {
		return "", "", errors.New("红果播放身份注册未返回有效设备号")
	}
	return deviceID, installID, nil
}

// hongguoRegisterID 优先取 `*_str`，退回数字形式；只接受正整数形式的 ID。
func hongguoRegisterID(payload map[string]any, name string) string {
	for _, key := range []string{name + "_str", name} {
		switch value := payload[key].(type) {
		case string:
			if len(value) > 0 && hongguoNumericID.MatchString(value) && strings.ContainsAny(value, "123456789") {
				return value
			}
		case json.Number:
			if text := value.String(); hongguoNumericID.MatchString(text) && strings.ContainsAny(text, "123456789") {
				return text
			}
		}
	}
	return ""
}

// hongguoDeviceRegisterBody 构造 ttEncrypt 加密后的注册请求体。
//
// 结构：magic(6B) + random(32B) + AES-128-CBC( sha512(gzip) + gzip )
// 密钥：sha512( sha512(random) + KDF_SALT )，前 16 字节作 key、后 16 字节作 IV。
func hongguoDeviceRegisterBody(now int64) []byte {
	header := map[string]any{
		"display_name": "红果免费短剧", "update_version_code": 73932, "manifest_version_code": 73932,
		"app_version_minor": "7.3.9.32", "aid": 8662, "channel": "update_64", "package": "com.phoenix.read",
		"app_version": "7.3.9.32", "version_code": 73932, "sdk_version": "3.7.0-rc.34-fanqie-xiaoshuo",
		"sdk_target_version": 29, "git_hash": "3a88f4e", "os": "Android", "os_version": "16", "os_api": 36,
		"device_model": "25053RT47C", "device_brand": "Redmi", "device_manufacturer": "Redmi",
		"cpu_abi": "arm64-v8a", "release_build": "b5e187f", "density_dpi": 520, "display_density": "mdpi",
		"resolution": "1280x2772", "language": "zh", "timezone": 8, "access": "wifi", "not_request_sender": 0,
		"carrier": "CHINA MOBILE", "mcc_mnc": "46000", "rom": "eng.root.20231116.160340",
		"rom_version": "W528JS release-keys", "cdid": hongguoRandomUUID(),
		"sig_hash": "56a962410c494bbaf0b58dba20cae56f", "openudid": hongguoRandomHex(8),
		"clientudid": hongguoRandomUUID(), "ipv6_list": []any{}, "region": "CN", "tz_name": "Asia/Shanghai",
		"tz_offset": 28800, "sim_region": "cn", "sim_serial_number": []any{}, "oaid_may_support": false,
		"req_id": hongguoRandomUUID(), "device_platform": "android",
		"custom": map[string]any{
			"account_region_src": "fallback", "account_region": "cn", "host_bit": 64,
			"dragon_device_type": "phone",
		},
		"pre_installed_channel": "", "apk_first_install_time": now, "is_system_app": 0,
		"sdk_flavor": "china", "guest_mode": 0,
	}
	plain, _ := json.Marshal(map[string]any{
		"magic_tag": "ss_app_log",
		"header":    header,
		"_gen_time": now,
	})
	var compressed bytes.Buffer
	writer := gzip.NewWriter(&compressed)
	_, _ = writer.Write(plain)
	_ = writer.Close()

	random := make([]byte, 32)
	_, _ = rand.Read(random)
	inner := sha512.Sum512(random)
	outer := sha512.New()
	outer.Write(inner[:])
	outer.Write(hongguoDeviceKDFSalt)
	derived := outer.Sum(nil)

	digest := sha512.Sum512(compressed.Bytes())
	payload := append(digest[:], compressed.Bytes()...)
	block, err := aes.NewCipher(derived[:16])
	if err != nil {
		return nil
	}
	padding := 16 - len(payload)%16
	padded := append(append([]byte(nil), payload...), bytes.Repeat([]byte{byte(padding)}, padding)...)
	encrypted := make([]byte, len(padded))
	cipher.NewCBCEncrypter(block, derived[16:32]).CryptBlocks(encrypted, padded)

	magic, _ := hex.DecodeString("746305100000")
	return append(append(magic, random...), encrypted...)
}

func hongguoRandomHex(size int) string {
	buffer := make([]byte, size)
	_, _ = rand.Read(buffer)
	return hex.EncodeToString(buffer)
}

func hongguoRandomUUID() string {
	buffer := make([]byte, 16)
	_, _ = rand.Read(buffer)
	buffer[6] = (buffer[6] & 0x0f) | 0x40
	buffer[8] = (buffer[8] & 0x3f) | 0x80
	return fmt.Sprintf("%x-%x-%x-%x-%x", buffer[0:4], buffer[4:6], buffer[6:8], buffer[8:10], buffer[10:16])
}

// hongguoAppBaseURL 读取当前红果 App 接口基地址。
func (downloader *Downloader) hongguoAppBaseURL() string {
	client := downloader.hongguoClient()
	client.mu.Lock()
	defer client.mu.Unlock()
	return client.baseURL
}
