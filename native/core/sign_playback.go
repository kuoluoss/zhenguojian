package core

import (
	"crypto/aes"
	"crypto/rand"
	"encoding/base64"
	"encoding/binary"
	"encoding/hex"
	"fmt"
	"math/bits"
	"net/url"
	"strings"
)

// 红果「真实播放签名」：551 Argus + Ladon（0.7.19）。
//
// 背景（2026-11-14 查证 + 实测）：
// 我们此前的 sign6 里，`x-argus` / `x-ladon` 只是 `le32/be32(khronos)` 的 base64 占位，
// **不是上游真正校验的签名**。红果收紧后，播放接口对这种占位签名一律回
// 「HTTP 200 + 0 字节」——表现和限流/熔断一模一样，换端点、换参数、换身份、
// 换出口都无效（这与我们 2026-11-11 起的全部实测现象完全吻合）。
//
// 算法来源：hongguo-web (sunnysky123) 的 `server/src/core/playback-sign.js`，
// 其上游为 hongguoTV (N3urda) 的 Argus.kt 与 fqapp 的 rust 实现。
// 涉及常量均为**客户端协议常量**（非账号凭据），来自公开实现。
//
// 两个签名：
//   x-argus : Simon(protobuf{aid, device_id, license, 时间, body 摘要, query 摘要})
//             → xmxor → 逆序 → AES-128-CBC → 前缀 f281 的 base64
//   x-ladon : md5(随机4字节 + aid) 生成 34 轮字表，对 "ts-license-aid" 分组变换

// ---- 协议常量（客户端公开协议，非凭据）----

// hongguoLicenseID 签名内固定的版权方标识。
const hongguoLicenseID = uint64(1611921764)

// hongguoSigKey Argus 的 Simon 轮密钥源（32 字节 = 4 个 u64 小端字）。
const hongguoSigKeyHex = "fc78e0a9657a0c748ce51559903ccf03510e51d3cff232d71343e88a321c5304"

// hongguoArgusAESKey / IV：Argus 最终 AES-128-CBC 的密钥与 IV。
const (
	hongguoArgusAESKeyHex = "d31e3718288a1027baab59f146a09a9c"
	hongguoArgusAESIVHex  = "ea180a0336ed352fcd24e4d50018ae54"
	hongguoArgusMagicHex  = "f2f7fcfff2f7fcff"
	hongguoArgusTailHex   = "eafb2cfe8568519154"
)

// hongguoSimonC 是 Simon 轮密钥扩展里的 62 位常量。
const hongguoSimonC uint64 = 0x3dc94c3a046d678b

// ---- 基础工具 ----

// pad16 PKCS#7 补齐到 16 字节整数倍。
func hongguoPad16(data []byte) []byte {
	padding := 16 - len(data)%16
	out := make([]byte, len(data)+padding)
	copy(out, data)
	for index := len(data); index < len(out); index++ {
		out[index] = byte(padding)
	}
	return out
}

// hongguoSM3Sum sm3 摘要（复用 sign6 的实现，语义等价 OpenSSL sm3）。
func hongguoSM3Sum(data []byte) []byte {
	return sm3Sum(data)
}

// ---- protobuf 极简编码 ----

type hongguoProtoBuf struct {
	parts []byte
}

func (p *hongguoProtoBuf) putVarint(tag int, value uint64) *hongguoProtoBuf {
	p.parts = append(p.parts, hongguoVarint(uint64(tag)<<3)...)
	p.parts = append(p.parts, hongguoVarint(value)...)
	return p
}

func (p *hongguoProtoBuf) putBytes(tag int, value []byte) *hongguoProtoBuf {
	p.parts = append(p.parts, hongguoVarint(uint64(tag)<<3|2)...)
	p.parts = append(p.parts, hongguoVarint(uint64(len(value)))...)
	p.parts = append(p.parts, value...)
	return p
}

func (p *hongguoProtoBuf) putUtf8(tag int, value string) *hongguoProtoBuf {
	return p.putBytes(tag, []byte(value))
}

func (p *hongguoProtoBuf) putProtobuf(tag int, value *hongguoProtoBuf) *hongguoProtoBuf {
	return p.putBytes(tag, value.parts)
}

func (p *hongguoProtoBuf) toBuf() []byte {
	return p.parts
}

// hongguoVarint protobuf varint（值按 u32 截断）。
func hongguoVarint(value uint64) []byte {
	n := uint64(uint32(value))
	var out []byte
	for n >= 0x80 {
		out = append(out, byte(n&0x7f)|0x80)
		n >>= 7
	}
	out = append(out, byte(n))
	return out
}

// ---- Simon 分组密码 ----

// hongguoSimonKeyExpansion 扩展为 72 个轮密钥。
func hongguoSimonKeyExpansion(key [4]uint64) [72]uint64 {
	var expanded [72]uint64
	copy(expanded[:4], key[:])
	for i := 4; i < 72; i++ {
		tmp := bits.RotateLeft64(expanded[i-1], -3) ^ expanded[i-3]
		tmp ^= bits.RotateLeft64(tmp, -1)
		bit := (hongguoSimonC >> uint((i-4)%62)) & 1
		expanded[i] = ^expanded[i-4] ^ tmp ^ bit ^ 3
	}
	return expanded
}

// hongguoSimonEncrypt 对一组 16 字节块加密。
func hongguoSimonEncrypt(left, right uint64, roundKeys *[72]uint64) (uint64, uint64) {
	x, y := left, right
	for _, roundKey := range roundKeys {
		previous := y
		y = x ^ (bits.RotateLeft64(y, 1) & bits.RotateLeft64(y, 8)) ^ bits.RotateLeft64(y, 2) ^ roundKey
		x = previous
	}
	return x, y
}

// ---- Argus ----

// hongguoArgusBodyHash body 摘要取 sm3(stub 字节) 前 6 字节；无正文用 16 零字节。
func hongguoArgusBodyHash(stubHex string) []byte {
	var data []byte
	if stubHex != "" {
		if decoded, err := hex.DecodeString(stubHex); err == nil {
			data = decoded
		}
	} else {
		data = make([]byte, 16)
	}
	sum := hongguoSM3Sum(data)
	return sum[:6]
}

// hongguoArgusQueryHash query 摘要取 sm3(query 原文) 前 6 字节。
func hongguoArgusQueryHash(query string) []byte {
	var data []byte
	if query != "" {
		data = []byte(query)
	} else {
		data = make([]byte, 16)
	}
	sum := hongguoSM3Sum(data)
	return sum[:6]
}

// hongguoArgusSign 生成 x-argus 头。
func hongguoArgusSign(query, stubHex string, ts int64, aid uint64, deviceID, installID string, randField int32) (string, error) {
	bean := &hongguoProtoBuf{}
	bean.putVarint(1, 1077940818).putVarint(2, 2).putVarint(3, uint64(uint32(randField)))
	aidValue := aid
	if aidValue == 0 {
		aidValue = 1967
	}
	licenseValue := hongguoLicenseID
	versionName := hongguoQueryParam(query, "version_name")
	bean.putUtf8(4, fmt.Sprintf("%d", aidValue)).
		putUtf8(5, deviceID).
		putUtf8(6, fmt.Sprintf("%d", licenseValue)).
		putUtf8(7, versionName).
		putUtf8(8, "v04.04.05-ov-android").
		putVarint(9, 134744640).
		putBytes(10, make([]byte, 8)).
		putVarint(11, 0).
		putVarint(12, uint64(ts)<<1).
		putBytes(13, hongguoArgusBodyHash(stubHex)).
		putBytes(14, hongguoArgusQueryHash(query))
	nested15 := &hongguoProtoBuf{}
	nested15.putVarint(1, 1).putVarint(2, 1).putVarint(3, 1).putVarint(7, 0xc792eccc)
	bean.putProtobuf(15, nested15)
	bean.putUtf8(16, installID).putUtf8(20, "none").putVarint(21, 738)
	nested23 := &hongguoProtoBuf{}
	nested23.putUtf8(1, "NX551J").putVarint(2, 8196).putVarint(4, 0x80e0d800)
	bean.putProtobuf(23, nested23)
	bean.putVarint(25, 2)

	protobuf := hongguoPad16(bean.toBuf())

	keyBytes, err := hex.DecodeString(hongguoSigKeyHex)
	if err != nil || len(keyBytes) != 32 {
		return "", fmt.Errorf("播放签名密钥无效")
	}
	var key [4]uint64
	for index := 0; index < 4; index++ {
		key[index] = binary.LittleEndian.Uint64(keyBytes[index*8:])
	}
	roundKeys := hongguoSimonKeyExpansion(key)

	// 逐 16 字节块加密
	blocks := make([]byte, 0, len(protobuf))
	for at := 0; at < len(protobuf); at += 16 {
		left := binary.LittleEndian.Uint64(protobuf[at:])
		right := binary.LittleEndian.Uint64(protobuf[at+8:])
		encLeft, encRight := hongguoSimonEncrypt(left, right, &roundKeys)
		var block [16]byte
		binary.LittleEndian.PutUint64(block[0:], encLeft)
		binary.LittleEndian.PutUint64(block[8:], encRight)
		blocks = append(blocks, block[:]...)
	}

	magic, _ := hex.DecodeString(hongguoArgusMagicHex)
	tail, _ := hex.DecodeString(hongguoArgusTailHex)
	framed := make([]byte, 0, len(magic)+len(blocks)+len(tail))
	framed = append(framed, magic...)
	framed = append(framed, blocks...)
	framed = append(framed, tail...)
	// xmxor：从第 8 字节起与 MAGIC8 循环异或
	for index := 8; index < len(framed); index++ {
		framed[index] ^= magic[index%8]
	}
	// 逆序
	for left, right := 0, len(framed)-1; left < right; left, right = left+1, right-1 {
		framed[left], framed[right] = framed[right], framed[left]
	}
	padded := hongguoPad16(append(framed, []byte("ao")...))

	aesKey, _ := hex.DecodeString(hongguoArgusAESKeyHex)
	aesIV, _ := hex.DecodeString(hongguoArgusAESIVHex)
	block, err := aes.NewCipher(aesKey)
	if err != nil {
		return "", err
	}
	encrypted := make([]byte, len(padded))
	// 手写 CBC（不做自动填充，padded 已是整数倍）
	previous := aesIV
	for at := 0; at < len(padded); at += 16 {
		chunk := make([]byte, 16)
		for index := 0; index < 16; index++ {
			chunk[index] = padded[at+index] ^ previous[index]
		}
		block.Encrypt(encrypted[at:at+16], chunk)
		previous = encrypted[at : at+16]
	}
	prefix, _ := hex.DecodeString("f281")
	return base64.StdEncoding.EncodeToString(append(prefix, encrypted...)), nil
}

// ---- Ladon ----

// hongguoLadonEncrypt 生成 x-ladon 头。
// 参数顺序对齐 JS：ts、licenseId、aid、randomBytes。
func hongguoLadonEncrypt(ts int64, licenseID uint64, aid uint64, randomBytes []byte) (string, error) {
	if len(randomBytes) != 4 {
		return "", fmt.Errorf("Ladon 随机字节长度必须为 4")
	}
	aidText := fmt.Sprintf("%d", aid)
	digestInput := append(append([]byte{}, randomBytes...), []byte(aidText)...)
	digestHex := hongguoMD5Hex(digestInput)
	ascii := []byte(digestHex)

	var words [4]uint64
	for index := 0; index < 4; index++ {
		words[index] = binary.LittleEndian.Uint64(ascii[index*8:])
	}
	table := make([]uint64, 0, 40)
	table = append(table, words[0])
	queue := []uint64{words[2], words[3]}
	b0, b8 := words[0], words[1]
	for i := 0; i < 34; i++ {
		x8 := (bits.RotateLeft64(b8, -8) + b0) ^ uint64(i)
		queue = append(queue, x8)
		x8 ^= bits.RotateLeft64(b0, 3)
		table = append(table, x8)
		b0 = x8
		b8 = queue[0]
		queue = queue[1:]
	}

	input := hongguoPad16([]byte(fmt.Sprintf("%d-%d-%s", ts, licenseID, aidText)))
	out := make([]byte, len(input))
	for at := 0; at < len(input); at += 16 {
		a := binary.LittleEndian.Uint64(input[at:])
		b := binary.LittleEndian.Uint64(input[at+8:])
		for i := 0; i < 34; i++ {
			b = table[i] ^ (a + bits.RotateLeft64(b, -8))
			a = b ^ bits.RotateLeft64(a, 3)
		}
		binary.LittleEndian.PutUint64(out[at:], a)
		binary.LittleEndian.PutUint64(out[at+8:], b)
	}
	return base64.StdEncoding.EncodeToString(append(append([]byte{}, randomBytes...), out...)), nil
}

// ---- 对外入口 ----

// hongguoPlaybackSignHeaders 生成播放请求的签名头。
//
// query 必须是最终发出的 query 原文（不含 '?'，与发出去的字节完全一致）；
// body 为实际发送的请求体（GET 传 nil）。签名对字节级敏感。
func hongguoPlaybackSignHeaders(query string, body []byte, ts int64) (map[string]string, error) {
	aid := uint64(1967)
	if raw := hongguoQueryParam(query, "aid"); raw != "" {
		var parsed uint64
		if _, err := fmt.Sscanf(strings.TrimSpace(raw), "%d", &parsed); err == nil && parsed > 0 {
			aid = parsed
		}
	}
	stub := ""
	if len(body) > 0 {
		stub = hongguoMD5Hex(body)
	}
	randFieldBytes := make([]byte, 4)
	_, _ = rand.Read(randFieldBytes)
	randField := int32(binary.LittleEndian.Uint32(randFieldBytes))
	ladonRandom := make([]byte, 4)
	_, _ = rand.Read(ladonRandom)

	deviceID := hongguoQueryParam(query, "device_id")
	installID := ""

	argus, err := hongguoArgusSign(query, stub, ts, aid, deviceID, installID, randField)
	if err != nil {
		return nil, err
	}
	ladon, err := hongguoLadonEncrypt(ts, hongguoLicenseID, aid, ladonRandom)
	if err != nil {
		return nil, err
	}
	headers := map[string]string{
		"x-ss-req-ticket": fmt.Sprintf("%d", ts*1000),
		"x-khronos":       fmt.Sprintf("%d", ts),
		"x-ladon":         ladon,
		"x-argus":         argus,
	}
	if stub != "" {
		headers["x-ss-stub"] = stub
	}
	return headers, nil
}

// hongguoQueryParam 从 query 原文取参数值（解码失败时原样返回）。
func hongguoQueryParam(query, name string) string {
	if query == "" {
		return ""
	}
	for _, part := range strings.Split(query, "&") {
		at := strings.Index(part, "=")
		key := part
		value := ""
		if at >= 0 {
			key = part[:at]
			value = part[at+1:]
		}
		if decoded, err := url.QueryUnescape(key); err == nil {
			key = decoded
		}
		if key != name {
			continue
		}
		if decoded, err := url.QueryUnescape(value); err == nil {
			return decoded
		}
		return value
	}
	return ""
}
