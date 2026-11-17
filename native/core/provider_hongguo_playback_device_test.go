package core

import (
	"bytes"
	"encoding/json"
	"testing"
)

func TestHongguoDeviceRegisterBodyStructure(t *testing.T) {
	body := hongguoDeviceRegisterBody(1700000000000, "1a2b3c4d-5e6f-4788-9a0b-1c2d3e4f5a6b")
	magic := []byte{0x74, 0x63, 0x05, 0x10, 0x00, 0x00}
	if !bytes.HasPrefix(body, magic) {
		t.Fatalf("注册请求体缺少 ttEncrypt magic 前缀，实际前 6 字节: %x", body[:min(6, len(body))])
	}
	if len(body) <= len(magic)+32 {
		t.Fatalf("注册请求体过短: %d 字节", len(body))
	}
	if remainder := (len(body) - len(magic) - 32) % 16; remainder != 0 {
		t.Fatalf("密文长度不是 16 的整数倍（余 %d）", remainder)
	}
	if bytes.Equal(body[len(magic):len(magic)+32], make([]byte, 32)) {
		t.Fatal("随机段不应为全零")
	}
}

func TestHongguoRegisterID(t *testing.T) {
	preferred := map[string]any{
		"device_id_str": "123456789012345",
		"device_id":     json.Number("999"),
	}
	if got := hongguoRegisterID(preferred, "device_id"); got != "123456789012345" {
		t.Fatalf("应优先取 *_str，实际 %q", got)
	}
	numeric := map[string]any{"install_id": json.Number("7654321")}
	if got := hongguoRegisterID(numeric, "install_id"); got != "7654321" {
		t.Fatalf("应回退到数字形式，实际 %q", got)
	}
	if got := hongguoRegisterID(map[string]any{"iid": "0"}, "iid"); got != "" {
		t.Fatalf("全零 ID 应判为无效，实际 %q", got)
	}
	if got := hongguoRegisterID(map[string]any{}, "device_id"); got != "" {
		t.Fatalf("缺失字段应返回空，实际 %q", got)
	}
}
