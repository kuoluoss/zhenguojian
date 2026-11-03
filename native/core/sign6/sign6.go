// Package sign6 是「红果 App 接口六个签名请求头」的纯 Go 实现。
//
// 逐行移植自 07-构建产物/_源探针临时/pure-sign.js（唯一权威源），
// 六个头：x-gorgon / x-khronos / x-ladon / x-argus / x-helios / x-medusa。
//
// 移植约定（与源文件的约定一一对应）：
//   - JS 的 `| 0`、`>>>`、`& 0xff`、`~` 一律用 uint32 承载：位型与 int32 完全
//     一致，且 uint32 上的 `>>` 就是 JS 的 `>>>`；需要 32 位回绕的地方靠
//     uint32 加法自然回绕，不额外取模。
//   - JS 的 BigInt（= Java long，64 位）用 uint64，需要截断处显式转换
//     （对应 BigInt.asUintN(64, x)）。
//   - JS 数组 / Buffer 的越界读返回 0（undefined 在位运算里等价 0）、越界写静默
//     忽略，这里用 srcB / setByte / aesSrc / aesPut 复刻。
//   - 本包只做纯计算：不发网络请求，不读写文件，只依赖 Go 标准库。
package sign6

import (
	"crypto/md5"
	"crypto/rand"
	"encoding/base64"
	"encoding/binary"
	"encoding/hex"
	"math"
	"math/bits"
	"strconv"
	"strings"
	"time"
)

// ==================== 基础工具 ====================

func mustUnhex(s string) []byte {
	b, err := hex.DecodeString(s)
	if err != nil {
		panic("sign6: 非法十六进制常量: " + err.Error())
	}
	return b
}

func mustBase64(s string) []byte {
	b, err := base64.StdEncoding.DecodeString(s)
	if err != nil {
		panic("sign6: 非法 base64 常量: " + err.Error())
	}
	return b
}

// srcB 复刻 JS 的 b[i] 读语义：越界返回 0。
func srcB(b []byte, i int) uint32 {
	if i >= 0 && i < len(b) {
		return uint32(b[i])
	}
	return 0
}

// setByte 复刻 JS 的 b[i] = v 写语义：越界静默忽略。
func setByte(b []byte, i int, v byte) {
	if i >= 0 && i < len(b) {
		b[i] = v
	}
}

func concat(parts ...[]byte) []byte {
	n := 0
	for _, p := range parts {
		n += len(p)
	}
	out := make([]byte, 0, n)
	for _, p := range parts {
		out = append(out, p...)
	}
	return out
}

// xorBytes 对应 JS 的 xorBytes(a, b)：以 a 的长度为准，b 循环取用。
func xorBytes(a, b []byte) []byte {
	out := make([]byte, len(a))
	copy(out, a)
	for i := 0; i < len(out); i++ {
		out[i] ^= b[i%len(b)]
	}
	return out
}

func rotl(x uint32, n int) uint32 { return bits.RotateLeft32(x, n&31) }

func ror(x uint32, n int) uint32 { return bits.RotateLeft32(x, -(n & 31)) }

// rotl8：8 位循环左移（移 4 位）。
func rotl8(x uint32) uint32 { return ((x << 4) | (x >> 4)) & 255 }

// rotl8_3：8 位循环左移 3 位（xmxor 专用）。
func rotl8_3(x uint32) uint32 { return ((x << 3) | (x >> 5)) & 255 }

// reverseBits 反转一个字节的 8 个位。
func reverseBits(value uint32) uint32 {
	r := uint32(0)
	for i := 0; i < 8; i++ {
		r = (r << 1) | ((value >> uint(i)) & 1)
	}
	return r
}

func readLe32(b []byte, off int) uint32 {
	return srcB(b, off) | srcB(b, off+1)<<8 | srcB(b, off+2)<<16 | srcB(b, off+3)<<24
}

func readBe32(b []byte, off int) uint32 {
	return srcB(b, off)<<24 | srcB(b, off+1)<<16 | srcB(b, off+2)<<8 | srcB(b, off+3)
}

func putLe32(b []byte, off int, v uint32) {
	setByte(b, off, byte(v))
	setByte(b, off+1, byte(v>>8))
	setByte(b, off+2, byte(v>>16))
	setByte(b, off+3, byte(v>>24))
}

func putBe32(b []byte, off int, v uint32) {
	setByte(b, off, byte(v>>24))
	setByte(b, off+1, byte(v>>16))
	setByte(b, off+2, byte(v>>8))
	setByte(b, off+3, byte(v))
}

func le32(v uint32) []byte {
	b := make([]byte, 4)
	putLe32(b, 0, v)
	return b
}

func be32(v uint32) []byte {
	b := make([]byte, 4)
	putBe32(b, 0, v)
	return b
}

// readU64Le 读 64 位小端无符号（对应 Java readU64Le，无符号位型）。
func readU64Le(b []byte, off int) uint64 {
	var v uint64
	for i := 7; i >= 0; i-- {
		v = (v << 8) | uint64(srcB(b, off+i))
	}
	return v
}

func putU64Be(b []byte, off int, v uint64) {
	for i := 0; i < 8; i++ {
		setByte(b, off+i, byte((v>>uint(56-8*i))&0xff))
	}
}

func putU64Le(b []byte, off int, v uint64) {
	for i := 0; i < 8; i++ {
		setByte(b, off+i, byte((v>>uint(8*i))&0xff))
	}
}

// rotr64：64 位循环右移（对应 Java Long.rotateRight）。
func rotr64(x uint64, n int) uint64 { return bits.RotateLeft64(x, -(n & 63)) }

func md5Of(data []byte) []byte {
	s := md5.Sum(data)
	out := make([]byte, 16)
	copy(out, s[:])
	return out
}

// ==================== SM3（JS 侧用 Node/OpenSSL 内置 sm3） ====================
//
// Go 标准库没有 SM3，这里按 GB/T 32905 实现，语义等价于
// crypto.createHash('sm3').update(data).digest()。

var sm3IV = [8]uint32{
	0x7380166f, 0x4914b2b9, 0x172442d7, 0xda8a0600,
	0xa96f30bc, 0x163138aa, 0xe38dee4d, 0xb0fb0e4e,
}

func sm3P0(x uint32) uint32 { return x ^ bits.RotateLeft32(x, 9) ^ bits.RotateLeft32(x, 17) }

func sm3P1(x uint32) uint32 { return x ^ bits.RotateLeft32(x, 15) ^ bits.RotateLeft32(x, 23) }

func sm3(data []byte) []byte {
	h := sm3IV
	msg := make([]byte, 0, len(data)+72)
	msg = append(msg, data...)
	msg = append(msg, 0x80)
	for len(msg)%64 != 56 {
		msg = append(msg, 0)
	}
	var lenBytes [8]byte
	binary.BigEndian.PutUint64(lenBytes[:], uint64(len(data))*8)
	msg = append(msg, lenBytes[:]...)

	var w [68]uint32
	var w1 [64]uint32
	for i := 0; i < len(msg); i += 64 {
		block := msg[i : i+64]
		for j := 0; j < 16; j++ {
			w[j] = binary.BigEndian.Uint32(block[j*4:])
		}
		for j := 16; j < 68; j++ {
			w[j] = sm3P1(w[j-16]^w[j-9]^bits.RotateLeft32(w[j-3], 15)) ^
				bits.RotateLeft32(w[j-13], 7) ^ w[j-6]
		}
		for j := 0; j < 64; j++ {
			w1[j] = w[j] ^ w[j+4]
		}
		a, b, c, d := h[0], h[1], h[2], h[3]
		e, f, g, hh := h[4], h[5], h[6], h[7]
		for j := 0; j < 64; j++ {
			var tj uint32
			if j < 16 {
				tj = 0x79cc4519
			} else {
				tj = 0x7a879d8a
			}
			ss1 := bits.RotateLeft32(bits.RotateLeft32(a, 12)+e+bits.RotateLeft32(tj, j), 7)
			ss2 := ss1 ^ bits.RotateLeft32(a, 12)
			var ff, gg uint32
			if j < 16 {
				ff = a ^ b ^ c
				gg = e ^ f ^ g
			} else {
				ff = (a & b) | (a & c) | (b & c)
				gg = (e & f) | (^e & g)
			}
			tt1 := ff + d + ss2 + w1[j]
			tt2 := gg + hh + ss1 + w[j]
			d = c
			c = bits.RotateLeft32(b, 9)
			b = a
			a = tt1
			hh = g
			g = bits.RotateLeft32(f, 19)
			f = e
			e = sm3P0(tt2)
		}
		h[0] ^= a
		h[1] ^= b
		h[2] ^= c
		h[3] ^= d
		h[4] ^= e
		h[5] ^= f
		h[6] ^= g
		h[7] ^= hh
	}
	out := make([]byte, 32)
	for i := 0; i < 8; i++ {
		binary.BigEndian.PutUint32(out[i*4:], h[i])
	}
	return out
}

// ==================== protobuf 手写编码 ====================

// varint 只服务非负值（负值一律走 sint 的 zigzag）。
func varint(value uint64) []byte {
	out := make([]byte, 0, 10)
	n := value
	for n > 127 {
		out = append(out, byte((n&127)|128))
		n >>= 7
	}
	out = append(out, byte(n))
	return out
}

func zigzag(value int64) uint64 {
	if value < 0 {
		return uint64(-value)*2 - 1
	}
	return uint64(value) * 2
}

// pfield 对应 JS 里的 [tag, value, type] 数组；typ 为空表示默认 "string"。
type pfield struct {
	tag int
	val interface{}
	typ string
}

// 单个 protobuf 字段。type: string / bytes / message / float / sint / int。
func protoField(tag int, value interface{}, typ string) []byte {
	if value == nil {
		return nil
	}
	switch typ {
	case "bytes", "message":
		body, _ := value.([]byte)
		head := concat(varint(uint64(tag)<<3|2), varint(uint64(len(body))))
		return concat(head, body)
	case "string":
		s, _ := value.(string)
		if s == "" {
			return nil
		}
		body := []byte(s)
		head := concat(varint(uint64(tag)<<3|2), varint(uint64(len(body))))
		return concat(head, body)
	case "float":
		f, _ := value.(float64)
		body := make([]byte, 4)
		binary.LittleEndian.PutUint32(body, math.Float32bits(float32(f)))
		return concat(varint(uint64(tag)<<3|5), body)
	default:
		var v int64
		switch x := value.(type) {
		case int64:
			v = x
		case int:
			v = int64(x)
		case uint32:
			v = int64(x)
		case uint64:
			v = int64(x)
		}
		head := varint(uint64(tag) << 3)
		if typ == "sint" {
			return concat(head, varint(zigzag(v)))
		}
		return concat(head, varint(uint64(v)))
	}
}

// proto 对应 JS 的 proto([[tag, value, type], ...])。
func proto(fields []pfield) []byte {
	parts := make([][]byte, 0, len(fields))
	for _, f := range fields {
		typ := f.typ
		if typ == "" {
			typ = "string"
		}
		parts = append(parts, protoField(f.tag, f.val, typ))
	}
	return concat(parts...)
}

func pStr(tag int, v string) pfield    { return pfield{tag: tag, val: v, typ: "string"} }
func pSint(tag int, v int64) pfield    { return pfield{tag: tag, val: v, typ: "sint"} }
func pBytes(tag int, v []byte) pfield  { return pfield{tag: tag, val: v, typ: "bytes"} }
func pMsg(tag int, v []byte) pfield    { return pfield{tag: tag, val: v, typ: "message"} }
func pFloat(tag int, v float64) pfield { return pfield{tag: tag, val: v, typ: "float"} }

// ==================== 常量（从 pure-sign.js 逐项抄录） ====================

var (
	// SBOX：1024 字节，按 khronos&3 选 256 字节一段。
	sbox = mustBase64("+n0Ia5xZs0sEXznQOEqRmQBnpiCf9U2Ccybu3xhmgzOAAxn72f6uqqmwUsYL83klTni0NqxdGieeiNu9PGPsSRXBMB/cuFbUbM3KCUPINaPvHvSW0vwOcnuUhNHqRVpiAj/TEoE0K91+5ijypUYTATsh9mE3KSoN7Yyvv51cuyR2D3XkU4nhmI2xmmVwT1RMWKtub4sjxAcRDLrPoKSO2AU9FLLadMPX577Wf95IFj6FkKFVt3dCIsmGUC4X+WQxLJvxbRxEaOPpqJOXyzJX6+Vxaq3AzMfF/WAdoi1Hp+JRaV56zgpBtpWP97mH4DoGEIq1+FvV8LyS/3wvwugbQOwb2r26mJEMsiuDQTRn+wrYdrVGBVlhI3WQhyrjUBVMrLF5667llUcEaPCGPVGLD8qO5LlO8hKCvA7V9+8oJc9bXelqVQLhM76T5/WtnT45JKji+hdX0HoNCDDWuKON/QeaxB5uImSX0h2wv0VmP2zd2yeApxHcpsVS+MC2yFwAc2B7oBkTqsk1SEvTpM2fmfMQREBUfin0Bh+iq6EvPPavhWI2IX9e3yAas7Tm/3KEj2UmlFp36kN4x0rMLBRrxuh0U/zUHM4xcAMYjJY4MonxOl/X+alpt2M3WMI7w3HLnpIBigtNiJu7T21v4P6lSd5WFgntnMEt7oF92XzRLkJbTcGmXepE/UVOG6E/0YnhfS+q26utWcuxzpooyeD2cDlK1/8w9d28VzsRjbLuALbmGlp8+d7EzS6Au7lMpZ+ECMZvQmzwJ+eLOpxR+2chdUExp8ogQyq3v9l68rX4jCwjg0+PYKAEEzcU4wHFY2ZcdIHfWL1okD3SszT0GZMyKdZJrg1L2AeerB4tC0C4crp2EHGo5FYdSP7lwkeR2ocmnR+Ia8CYviUJlzOjhRZef9xuVOn3qcjow3fQgivsAmKKkg4+sA8F8/GWeDiGNhg8JM8KtFPMYWWkx5TVFX5t73kiNRJqjlIGVXtGZFCV4gzt0xcDopuZ6xz8r9Rzafpf9ywev8jh8592gHFIqpStZPuJxmDDMrNN0uBE3V+oscdoIzTJbRJ/t+sVvqnReJOgDJKk10fjisJwqyZBmnmn2BSFj8BvVtCMEbkuPOKdzw7eA11GPs04Qw8zWtkaZWwiO/wwpojqN6K0jY5RnNZA7vn4hPSul+nKCkVnVwQvg1zVxcSCtqORmB9KrJaBbssbCQivGJVJfVTt+hYxOtq4ZvWl8f4QAQZ0zGPffCgl9s6yT4vlvIdpu4YhBwA25wtQWZsc6GJYGWHyvSdeuh3mmUI9DSq13Fsp8C1MU3tqc04/df9LoTUXVXI5INOw/e8C7Hd+5CvbkMEFnnrUUmskEw==")

	// BRANCH2_ORDERS：320 字节（20 组 × 16 字节消息编排表）。
	branch2Orders = mustUnhex("0f0704000908030a060b050d0e010c020f05080c0009020103070e060b0a0d04060500070c000a04080f010b0d09020e060b02050403080101070a000d0c090e0d070e0f0b0208030c0509010004060a0d0902060f0b0a040807000c0503010e0c090f07060f030e020d0405010b0a000c050a090e0802040407030f01060b000b0f0408020a0700090d06010e03050c0b060a0508020c03070f0e090d0001040906080f050800040a0b030d01020c0e090d0c0604070a03030f00080105020e01000d0f090a0b0e0402080703060c0501080a0c0f0905060b000304020e070d04080f000c0f0e0d0a01060207090503040205080d0b0a0606000e0f070c09030a08040f000b01060d0c0709030e05020a070b050f00020e0108030d0c0609040d070f08050f06040b0a0e0c090002030d0c020704010b0e0e08060f09050003")

	medusaSignKey = mustUnhex("8ebdfa3806ecc5cee79423e6029ed82540bc2218bb7eaef71cb691f7aa8aa2f5")
	medusaAESKey  = mustUnhex("f1593376766ea98d34f31b057a9d5be4")
	medusaAESIV   = mustUnhex("1fe109a4125283f418de9e051a969e12")
	medusaMagic16 = mustUnhex("f7e85ffad7d7dc3bd62ac87057cf6118")
	medusaMagic8  = mustUnhex("4001000000000000")

	// 进程级 nonce（18 随机字节的 base64url）与进程启动时刻（毫秒）。
	processNonce   string
	processStarted int64
)

// BRANCH2_SV：md5SumV3 的固定轮常量表（64 项，随 countV1 循环右移）。
var branch2SV = [64]uint32{

	0xa7aefe20, 0x7149f1d6, 0x47e4ca07, 0xe9b58f67, 0x93b924de, 0xc614d0f5, 0x38afe0ef, 0xb2bbad73,
	0xe24444c3, 0x9d3aec9b, 0xdf7b37e4, 0xd8b16d40, 0xf8ac31b8, 0x76b9a90b, 0x31d833ee, 0x953fce64,
	0x353595a4, 0x4609c13b, 0x36925008, 0x8c6d0925, 0x5df5c177, 0x1cfbf52b, 0x8a4fa7f0, 0x114ca35e,
	0x8193f984, 0x7a7a8733, 0x316ab4d5, 0x3c20cfc9, 0xa6d84453, 0x3a18500c, 0x798ec47a, 0x97a76b28,
	0x66c4ff96, 0x51716443, 0x0dd2fc3b, 0xb5696da7, 0xbbeb3ac5, 0x5c53d204, 0xd32608ce, 0x7279b9ec,
	0xf4188ecf, 0xf7d793db, 0x332cc491, 0xab76ae15, 0x9bebe727, 0x18a01384, 0x5be9f8a7, 0x5f90a754,
	0x39b663c0, 0x36673c83, 0x7c92f514, 0x9d7d94d7, 0xe2e8d9aa, 0x5f7e9ea9, 0x7abd4551, 0x569e05da,
	0x40a25632, 0x3df5a9a5, 0xbab37d80, 0x454286dc, 0x3f5d4e78, 0x03d7b75d, 0xb1fe4af7, 0xa5ab26a3,
}

func init() {
	b := make([]byte, 18)
	if _, err := rand.Read(b); err != nil {
		panic("sign6: 取随机数失败: " + err.Error())
	}
	processNonce = base64.RawURLEncoding.EncodeToString(b)
	processStarted = time.Now().UnixMilli()
}

// ==================== hashF13 家族 ====================

// getIv：按字节奇偶交替混合的 32 位状态机。
func getIv(iv uint32, data []byte) uint32 {
	value := iv
	for i := 0; i < len(data); i++ {
		d := uint32(data[i])
		if (i & 1) == 0 {
			value = (value >> 4) ^ value ^ (value << 6) ^ d
		} else {
			value = ^((value >> 7) ^ value ^ (d | (value << 12)))
		}
	}
	return value
}

// sumMd5：取前 12 字节的固定轮混淆，末位或 4 再异或 0x1000000。
func sumMd5(data []byte) uint32 {
	check := uint32(0x20220420)
	for i := 0; i < 12; i++ {
		var temp uint32
		if (i & 1) == 0 {
			temp = (check >> 3) ^ check
		} else {
			temp = (check >> 5) ^ check
		}
		if (i & 1) == 0 {
			check = srcB(data, i) ^ (check << 7)
		} else {
			check = srcB(data, i) | (check << 11)
			check = ^check
		}
		check = check ^ temp
	}
	return (check | 4) ^ 0x1000000
}

func md5V3Step(kind int, a, b, c, d, m uint32, shift int, constant uint32) uint32 {
	var f uint32
	switch kind {
	case 0:
		f = (b & c) | (^b & d)
	case 1:
		f = (b & d) | (c & ^d)
	case 2:
		f = b ^ c ^ d
	default:
		f = c ^ (b | ^d)
	}
	return b + rotl(a+f+m+constant, shift)
}

// MD5 变体的每轮移位数表（kind 0..3）。
var md5V3Shifts = [4][16]int{
	{7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22},
	{5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20},
	{4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23},
	{6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21},
}

// MD5 变体：固定轮常量表 + 消息编排表驱动的 64 轮压缩。
func md5SumV3(message []byte, countV2 uint32, orders []byte, countV1 int) []byte {
	var sv [64]uint32
	for i := 0; i < len(sv); i++ {
		sv[i] = ror(branch2SV[i], countV1)
	}
	var start [4]uint32
	start[0] = ror(0x79e0f2fb, int(countV2))
	start[1] = ror(0xc8b52570, int(countV2))
	start[2] = ror(0xebc2f8cd, int(countV2))
	start[3] = ror(0x7c104d93, int(countV2))
	endCount := (countV2 + 6) & 255
	var end [4]uint32
	end[0] = ror(0x19be4866, int(endCount))
	end[1] = ror(0xe85986b4, int(endCount))
	end[2] = ror(0xe19b326e, int(endCount))
	end[3] = ror(0x71d1d7d4, int(endCount))

	var m [16]uint32
	for i := 0; i < 16; i++ {
		m[i] = readLe32(message, i*4)
	}
	a, b, c, d := start[0], start[1], start[2], start[3]

	for kind := 0; kind < 4; kind++ {
		shifts := md5V3Shifts[kind]
		offset := kind * 16
		for i := 0; i < 16; i++ {
			phase := i & 3
			mm := m[int(orders[offset+i])&0xff]
			cc := sv[offset+i]
			switch phase {
			case 0:
				a = md5V3Step(kind, a, b, c, d, mm, shifts[i], cc)
			case 1:
				d = md5V3Step(kind, d, a, b, c, mm, shifts[i], cc)
			case 2:
				c = md5V3Step(kind, c, d, a, b, mm, shifts[i], cc)
			default:
				b = md5V3Step(kind, b, c, d, a, mm, shifts[i], cc)
			}
		}
	}

	ret := make([]byte, 16)
	putLe32(ret, 0, (start[0]+a)^end[0])
	putLe32(ret, 4, (start[1]+b)^end[1])
	putLe32(ret, 8, (start[2]+c)^end[2])
	putLe32(ret, 12, (start[3]+d)^end[3])
	return concat(ret, le32(sumMd5(ret)))
}

// branch2F13 使用的 n1 表（索引 = 由 iv 派生的 0..4）。
var branch2N1 = [5]uint32{0x8980f29b, 0xeb549c7f, 0xb08726db, 0xd40cb5e6, 0xe8f559e4}

func branch2F13(iv uint32, querySm3, bodyMd5, tsBytes []byte, khronos int64) []byte {
	v := (iv & 13) * 86
	ivV0 := int(((v >> 15) & 255) + ((v >> 8) & 255))
	n1 := branch2N1[ivV0]
	countV1 := int(uint32(int32(int64(n1)+khronos+1)) & 255)
	countV2 := uint32(int32(int64(n1) + khronos))
	shift := int((countV2 + 5) & 7)
	seed := [8]uint32{0x84, 0x96, 0x77, 0x9d, 0xd4, 0x15, 0x0b, 0xf8}
	pad := make([]byte, 8)
	for i := 0; i < 8; i++ {
		pad[i] = byte(((seed[i] | (seed[i] << 8)) >> uint(shift)) & 255)
	}
	input := concat(querySm3, bodyMd5, tsBytes, pad, mustUnhex("a0010000"))
	from := ivV0 << 6
	to := (ivV0 + 1) << 6
	orders := branch2Orders[from:to]
	return md5SumV3(input, countV2, orders, countV1)
}

// hashF13 主分支（branch==0）使用的初值表。
var hashF13IV1 = [6]uint32{0xc4a78580, 0xb3c0fd39, 0xc58c5686, 0xc9aa3ba7, 0xf5a7adf2, 0x963c2ed1}

// hashF13 主分支（branch==0）使用的 64 项轮常量表。
var hashF13TT02 = [64]uint32{

	0xebb64faf, 0x07aadcc2, 0xcf3187bf, 0xe01138ff, 0x6d0bfcff, 0x5a30a3be, 0xb41ad638, 0x34180eb8,
	0xf233eb6f, 0xb1a584cc, 0xccc30dc7, 0x47d1db51, 0xd55653de, 0x70a84fa1, 0x57473c12, 0xf76f0288,
	0x2c077f0a, 0xda0dcad0, 0xfbb86f6c, 0xfdc4cf00, 0x688a020d, 0xe676c6a6, 0x8cd6338b, 0x1a3c8d0e,
	0xcce8b06b, 0x6ad0ed0b, 0xa0522717, 0xdc71ac83, 0x2285db71, 0xd5b4dda6, 0x736f8650, 0x6560306c,
	0x617ce2a6, 0xe423417e, 0x0a40e143, 0x544e4032, 0x88dffb2a, 0x716c1ae0, 0x4c467a88, 0x05b23bb3,
	0xe1d0b866, 0xbaa3dcb8, 0xae3374d3, 0xc3381a50, 0x1702f75b, 0xfe6da368, 0xf0b4cf48, 0x4e0ffbb8,
	0x72aad10d, 0x26c53a3d, 0xf2bce0f6, 0xb4557581, 0x4a257fdd, 0x8c3182a2, 0xab0b3b86, 0x3d5dfb14,
	0x4f103634, 0xd37b52d7, 0x444eff16, 0xeb0a33d1, 0x6ca86f6e, 0x0284ba7, 0x08387cfa, 0x5fb37586,
}

// hashF13 主分支（branch==0）的 8 个初值。
var hashF13InitRaw = [8]uint32{
	0x7aba4fc8, 0x67166507, 0x6403fa00, 0x340f512f,
	984304912, 3005047866, 2874125293, 2152413264,
}

// hashF13 主分支（branch==0）的轮数/索引表。
var hashF13Chosen = [6][11]int{

	{101, 5, 7, 6, 3, 2, 1, 0, 5, 4, 3},
	{96, 0, 6, 7, 5, 3, 2, 1, 5, 4, 4},
	{96, 7, 6, 2, 1, 4, 0, 5, 4, 3, 5},
	{99, 3, 6, 2, 4, 5, 1, 0, 0, 7, 6},
	{96, 0, 5, 6, 7, 3, 1, 2, 5, 4, 4},
	{100, 2, 0, 3, 5, 4, 6, 7, 2, 1, 5},
}

// hashF13：按 iv 低 4 位选分支（0 为主分支，1 不被服务端接受，2 为备用变体）。
func hashF13(querySm3, bodyMd5, tsBytes []byte, khronos int64) []byte {
	iv := getIv(getIv(getIv(0x20230928, querySm3), bodyMd5), tsBytes)
	low := iv & 15
	ivV0 := int((low * 171) >> 9)
	branch := int(low) - ivV0*3
	if branch == 2 {
		return branch2F13(iv, querySm3, bodyMd5, tsBytes, khronos)
	}
	if branch != 0 {
		return concat(querySm3[0:16], bodyMd5, le32(sumMd5(concat(querySm3, bodyMd5))))
	}

	ivV1 := hashF13IV1[ivV0]
	countV1 := int(uint32(int32(int64(ivV1)+khronos+1)) & 255)
	countV2 := uint32(int32(int64(ivV1) + khronos))
	tt := make([]uint32, len(hashF13TT02))
	for i := 0; i < len(tt); i++ {
		tt[i] = ror(hashF13TT02[i], countV1)
	}
	n0 := int((countV2 + 2) & 7)
	seed := [4]uint32{0xfa, 0x45, 0x61, 0xd7}
	pad := make([]byte, len(seed))
	for i := 0; i < len(seed); i++ {
		pad[i] = byte(((seed[i] | (seed[i] << 8)) >> uint(n0)) & 255)
	}
	data := concat(querySm3, bodyMd5, tsBytes, pad, mustUnhex("00000000000001a0"))

	di := make([]uint32, (len(data)/4)+112+16)
	diLen := 0
	for i := 0; i+3 < len(data); i += 4 {
		di[diLen] = readBe32(data, i)
		diLen++
	}
	di0 := di[0]
	for i := 0; i < 112; i++ {
		di1 := di[i+1]
		di14 := di[i+14]
		r1 := rotl(di1, 14) ^ rotl(di1, 25) ^ (di1 >> 3)
		r2 := rotl(di14, 13) ^ rotl(di14, 15) ^ (di14 >> 10)
		di[diLen] = di0 + di[i+9] + r1 + r2
		diLen++
		// di0 必须每轮前进一格（= 本轮 di1）：上游注释明确警告过，
		// 写成常量 di[0] 会让第 1 轮之后每一项都错，branch 0 的 hashF13 全错。
		di0 = di1
	}

	var init [8]uint32
	for i := 0; i < 8; i++ {
		init[i] = ror(hashF13InitRaw[i], int(countV2&31))
	}
	chosen := hashF13Chosen[ivV0]
	d := init
	for i := 0; i < chosen[0]; i++ {
		base := uint32(int32(int64(ivV1) + int64(i)))
		n0v := di[base&127]
		n1 := ((d[chosen[3]] ^ d[chosen[4]]) & d[chosen[1]]) ^ d[chosen[3]]
		n2 := rotl(d[chosen[1]], 26) ^ rotl(d[chosen[1]], 21) ^ rotl(d[chosen[1]], 7)
		n4 := n0v + n1 + n2 + tt[base&63] + d[chosen[5]]
		n5 := rotl(d[chosen[2]], 30) ^ rotl(d[chosen[2]], 19) ^ rotl(d[chosen[2]], 10)
		n6 := (d[chosen[2]] & d[chosen[6]]) | ((d[chosen[2]] | d[chosen[6]]) & d[chosen[7]])
		n7 := n5 + n6
		old := d[chosen[9]]
		// d.unshift(d.pop())：末元素移到队首（循环右移一格）。
		last := d[len(d)-1]
		for k := len(d) - 1; k >= 1; k-- {
			d[k] = d[k-1]
		}
		d[0] = last
		d[chosen[10]] = n7 + n4
		d[chosen[8]] = old + n4
	}

	ret := make([]byte, 32)
	for i := 0; i < 8; i++ {
		putBe32(ret, i*4, d[i]+init[i])
	}
	for i := 0; i < 16; i++ {
		ret[i] = ret[i] ^ ret[i+16]
	}
	return concat(ret[0:16], le32(sumMd5(ret[0:16])))
}

// ==================== x-gorgon ====================

// RC4 变体（KSA 只赋值不交换，PRGA 异或 s[(y+y)&255]）。
func rc4Gorgon(data, key []byte) []byte {
	var s [256]byte
	for i := 0; i < 256; i++ {
		s[i] = byte(i)
	}
	j := 0
	for i := 0; i < 256; i++ {
		j = (j + int(s[i]) + int(key[i%len(key)])) & 255
		s[i] = s[j]
	}
	out := make([]byte, len(data))
	i := 0
	j = 0
	for k := 0; k < len(data); k++ {
		i++
		x := int(s[i])
		j += x
		y := int(s[j&255])
		s[i] = byte(y)
		out[k] = data[k] ^ s[(y+y)&255]
	}
	return out
}

func xGorgon(query string, body []byte, timestamp int64, random uint32) string {
	q4 := md5Of([]byte(query))[0:4]
	var b4 []byte
	if len(body) > 0 {
		b4 = md5Of(body)[0:4]
	} else {
		b4 = make([]byte, 4)
	}
	sdk := le32(67503104)
	input := concat(q4, b4, make([]byte, 4), sdk, be32(uint32(timestamp)))
	key := []byte{0x4a, 0x40, 0x16, byte((random >> 8) & 255), 0x47, 0x6c, 0x01, byte(random & 255)}
	out := rc4Gorgon(input, key)
	for i := 0; i < len(out); i++ {
		value := rotl8(uint32(out[i]))
		var next uint32
		if i+1 < len(out) {
			next = uint32(out[i+1])
		} else {
			next = uint32(out[0])
		}
		out[i] = byte((^(reverseBits((next^value)&255) ^ 20)) & 255)
	}
	return hex.EncodeToString(concat(mustUnhex("8404"),
		[]byte{byte(random & 255), byte((random >> 8) & 255), 0x40, 0x01}, out))
}

// ==================== AesV3（medusa 内置的 AES 变体） ====================

// aesSrc：JS 语义，越界读返回 0。
func aesSrc(data []byte, idx int) uint32 {
	if idx < len(data) {
		return srcB(data, idx)
	}
	return 0
}

// aesPut：JS 语义，越界写静默忽略。
func aesPut(out []byte, idx int, value uint32) {
	if idx >= 0 && idx < len(out) {
		out[idx] = byte(value & 0xff)
	}
}

func aesMatrix(bytes []byte) [4][4]byte {
	var rows [4][4]byte
	for i := 0; i < 4; i++ {
		for j := 0; j < 4; j++ {
			rows[i][j] = byte(srcB(bytes, i*4+j))
		}
	}
	return rows
}

func aesFlat(rows *[4][4]byte) []byte {
	b := make([]byte, 16)
	for i := 0; i < 4; i++ {
		for j := 0; j < 4; j++ {
			b[i*4+j] = rows[i][j]
		}
	}
	return b
}

func aesXt(x uint32) uint32 {
	if (x & 128) != 0 {
		return ((x << 1) ^ 0x1b) & 255
	}
	return (x << 1) & 255
}

func aesMix(rows *[4][4]byte) {
	for i := 0; i < 4; i++ {
		t := rows[0][i] ^ rows[1][i] ^ rows[2][i] ^ rows[3][i]
		u := rows[0][i]
		rows[0][i] ^= t ^ byte(aesXt(uint32(rows[0][i]^rows[1][i])))
		rows[1][i] ^= t ^ byte(aesXt(uint32(rows[1][i]^rows[2][i])))
		rows[2][i] ^= t ^ byte(aesXt(uint32(rows[2][i]^rows[3][i])))
		rows[3][i] ^= t ^ byte(aesXt(uint32(rows[3][i]^u)))
	}
}

// aesV3：S 盒按 khronos 选段、行/列换用查表、密钥扩展 12 组。
type aesV3 struct {
	wordSize int
	box      []byte
	con2     [4]int
	order    [16]int
	keys     [12][4]byte
}

func newAesV3(key []byte, khronos int64) *aesV3 {
	a := &aesV3{}
	a.wordSize = int(khronos & 3)
	a.box = sbox[a.wordSize*256 : (a.wordSize+1)*256]
	con2Table := [4][4]int{
		{1, 0, 2, 3},
		{2, 0, 3, 1},
		{0, 1, 3, 2},
		{1, 0, 2, 3},
	}
	orderTable := [4][16]int{
		{0, 9, 14, 11, 4, 13, 2, 7, 8, 1, 6, 15, 12, 5, 10, 3},
		{0, 9, 14, 15, 4, 13, 2, 7, 8, 1, 6, 3, 12, 5, 10, 11},
		{0, 9, 14, 7, 4, 13, 2, 11, 8, 1, 6, 3, 12, 5, 10, 15},
		{0, 9, 14, 11, 4, 13, 2, 7, 8, 1, 6, 15, 12, 5, 10, 3},
	}
	a.con2 = con2Table[a.wordSize]
	a.order = orderTable[a.wordSize]
	initTable := [4]uint32{0xca025ddc, 0x823dc546, 0xc9420583, 0xc298225f}
	init := initTable[a.wordSize]
	initial := make([]byte, 16)
	for i := 0; i < 4; i++ {
		putLe32(initial, i*4, init)
	}
	mk := xorBytes(initial, key)
	expanded := concat(mk, make([]byte, 32))
	rounds := 8
	for i := 4; i < 12; i++ {
		at := 4 * (i - 1)
		x0 := srcB(expanded, at)
		x1 := srcB(expanded, at+1)
		x2 := srcB(expanded, at+2)
		x3 := srcB(expanded, at+3)
		if (i & 3) == 0 {
			t := ((init >> uint(rounds&24)) ^ uint32(a.box[x1])) & 255
			x1 = uint32(a.box[x2])
			x2 = uint32(a.box[x3])
			x3 = uint32(a.box[x0])
			x0 = t
		}
		rounds += 2
		setByte(expanded, at+4, byte(x0^srcB(expanded, at-12)))
		setByte(expanded, at+5, byte(x1^srcB(expanded, at-11)))
		setByte(expanded, at+6, byte(x2^srcB(expanded, at-10)))
		setByte(expanded, at+7, byte(x3^srcB(expanded, at-9)))
	}
	for i := 0; i < 12; i++ {
		for j := 0; j < 4; j++ {
			a.keys[i][j] = byte(srcB(expanded, i*4+j))
		}
	}
	return a
}

func (a *aesV3) add(rows *[4][4]byte, key [4][4]byte) {
	for i := 0; i < 4; i++ {
		for j := 0; j < 4; j++ {
			rows[i][j] ^= key[i][j]
		}
	}
}

func (a *aesV3) addCon(rows *[4][4]byte, ks [4][4]byte) {
	for i := 0; i < 4; i++ {
		for j := 0; j < 4; j++ {
			rows[i][j] ^= ks[i][a.con2[j]]
		}
	}
}

func (a *aesV3) sub(rows *[4][4]byte) {
	for i := 0; i < 4; i++ {
		for j := 0; j < 4; j++ {
			rows[i][j] = a.box[rows[i][j]]
		}
	}
	old := *rows
	for i := 0; i < 4; i++ {
		rows[i] = old[a.con2[i]]
	}
}

func (a *aesV3) shift(rows *[4][4]byte) {
	b := aesFlat(rows)
	for i := 0; i < 16; i++ {
		rows[i/4][i%4] = b[a.order[i]]
	}
}

func (a *aesV3) shiftCon(rows *[4][4]byte) {
	old := *rows
	for i := 0; i < 4; i++ {
		for j := 0; j < 4; j++ {
			rows[i][j] = old[i][a.con2[j]]
		}
	}
}

func (a *aesV3) subKeys(from int) [4][4]byte {
	var out [4][4]byte
	for i := 0; i < 4; i++ {
		out[i] = a.keys[from+i]
	}
	return out
}

func (a *aesV3) block(value []byte) []byte {
	rows := aesMatrix(value)
	a.addCon(&rows, a.subKeys(0))
	for i := 1; i < 3; i++ {
		a.sub(&rows)
		a.shift(&rows)
		if i == 1 {
			a.shiftCon(&rows)
			aesMix(&rows)
		}
		a.addCon(&rows, a.subKeys(i*4))
	}
	a.add(&rows, a.subKeys(4))
	return aesFlat(&rows)
}

// encrypt：明文具化到 32 字节 -> CBC 两轮 -> 按 key 逐位回填源数据，末尾缀 key 末字节。
func (a *aesV3) encrypt(data, iv []byte) []byte {
	plaintext := make([]byte, 32)
	for i := 0; i < 31; i++ {
		at := i * 8
		n0 := (aesSrc(data, at) >> 4) & 2
		n1 := n0 | (aesSrc(data, at+1) & 64)
		n2 := n1 | ((aesSrc(data, at+2) >> 2) & 1)
		n3 := n2 | ((aesSrc(data, at+3) << 3) & 128)
		n4 := n3 | ((aesSrc(data, at+4) >> 1) & 4)
		n5 := n4 | ((aesSrc(data, at+5) << 3) & 16)
		n6 := n5 | ((aesSrc(data, at+6) << 5) & 32)
		plaintext[i] = byte(n6 | ((aesSrc(data, at+7) >> 4) & 8))
	}
	plaintext[31] = 1
	var blocks []byte
	previous := make([]byte, len(iv))
	copy(previous, iv)
	for i := 0; i < len(plaintext); i += 16 {
		value := a.block(xorBytes(plaintext[i:i+16], previous))
		blocks = append(blocks, value...)
		previous = value
	}
	key := blocks
	out := make([]byte, len(data))
	copy(out, data)
	for i := 0; i < 31; i++ {
		at := i * 8
		k := uint32(key[i])
		aesPut(out, at, (aesSrc(out, at)&0xdf)|((k<<4)&32))
		aesPut(out, at+1, (aesSrc(out, at+1)&0xbf)|(k&64))
		aesPut(out, at+2, (aesSrc(out, at+2)&0xfb)|((k<<2)&4))
		aesPut(out, at+3, (aesSrc(out, at+3)&0xef)|((k>>3)&16))
		aesPut(out, at+4, (aesSrc(out, at+4)&0xf7)|((k+k)&8))
		aesPut(out, at+5, (aesSrc(out, at+5)&0xfd)|((k>>3)&2))
		aesPut(out, at+6, (aesSrc(out, at+6)&0xfe)|((k>>5)&1))
		aesPut(out, at+7, (aesSrc(out, at+7)&0x7f)|((k<<4)&128))
	}
	return concat(key[len(key)-1:], out)
}

// ==================== xmxor / keyHash / medusa / helios ====================

// xmxor：按 key 表逐字节混淆 + 三段尾部修正。
func xmxor(data, key []byte) []byte {
	encoded := make([]byte, len(data))
	for i := 0; i < len(data); i++ {
		at := (i * 4) & 28
		d0 := srcB(key, at)
		d1 := srcB(key, at+1)
		d2 := rotl8(srcB(data, i)) + d0
		d2 = (^d2) ^ d1
		d2 = rotl8_3(d2 & 0xff)
		d2 = (d2 + d1) & 255
		d2 = (d2 ^ d0) & 255
		encoded[len(data)-i-1] = byte((^d2) & 255)
	}
	n := len(encoded)
	last := encoded[n-1] ^ encoded[n-2]
	first := encoded[0]
	encoded[0] = byte(((^uint32(last)) + uint32(first)) & 255)
	encoded[1] = byte(((uint32(encoded[0]) ^ uint32(encoded[n-1]) ^ 254) + uint32(encoded[1])) & 255)
	encoded[2] = byte((uint32(encoded[2]) + (((uint32(last) - uint32(first)) ^ rotl8_3(uint32(encoded[1]))) ^ 2)) & 255)
	for i := 0; i < n-4; i++ {
		temp := rotl8_3(uint32(encoded[i+2])) ^ uint32(encoded[i+1]) ^ uint32(i+3)
		encoded[i+3] = byte(((^temp) + uint32(encoded[i+3])) & 255)
	}
	encoded[n-1] = encoded[n-1] ^ encoded[n-2]
	sum := uint32(0)
	for i := 0; i < n-1; i++ {
		sum += uint32(encoded[i+1])
	}
	encoded[0] = byte(((uint32(encoded[0]) ^ uint32(encoded[1])) + sum) & 255)
	return encoded
}

// keyHash：signKey || le32(random) || signKey 的 SM3，附一个由 random 派生的 4 字节种子。
func keyHash(signKey []byte, random int32) ([]byte, []byte) {
	r := uint32(random)
	hash := sm3(concat(signKey, le32(r), signKey))
	d1 := (r >> 16) & 255
	d2 := ((d1 << 11) | (r >> 24)) ^ (d1 >> 5) ^ d1
	d2 = ^d2
	return hash, le32(d2)
}

func randomBytes(n int) []byte {
	b := make([]byte, n)
	if _, err := rand.Read(b); err != nil {
		panic("sign6: 取随机数失败: " + err.Error())
	}
	return b
}

// rndInt 对应 Node crypto.randomInt(n)：返回 [0, n) 的整数。
// Node 用 2^32 拒绝采样保证均匀，这里照抄同一做法（不是简单取模）。
func rndInt(n uint32) uint32 {
	if n == 0 {
		return 0
	}
	limit := uint64(1) << 32
	excess := limit - limit%uint64(n)
	for {
		b := randomBytes(4)
		v := uint64(binary.BigEndian.Uint32(b))
		if v < excess {
			return uint32(v % uint64(n))
		}
	}
}

// rndInt32 对应 Node crypto.randomBytes(4).readInt32BE(0)：有符号 32 位。
func rndInt32() int32 {
	return int32(binary.BigEndian.Uint32(randomBytes(4)))
}

// deviceProto 设备信息 protobuf。字段 30-36 为固定设备值（不跟随 query 参数）。
func deviceProto(deviceID, version string) []byte {
	// version 在源实现中同样未被使用（保留形参以对齐签名）。
	_ = version
	return proto([]pfield{
		pSint(1, 1), pSint(2, 2), pStr(3, "8662"), pStr(4, deviceID),
		pStr(5, processNonce), pStr(6, "!noperm!"), pSint(7, -888888), pSint(8, -888888),
		pSint(9, 3), pSint(10, -888888), pStr(11, "!notset!"),
		pStr(12, "Asia/Shanghai,8"), pStr(13, "zh_CN"), pSint(14, 4),
		pFloat(16, 0), pFloat(17, 0), pFloat(18, 0), pFloat(19, 0),
		pFloat(20, 0), pFloat(21, 0), pStr(22, "16"), pSint(23, 41),
		pSint(24, 36), pSint(25, processStarted), pSint(26, processStarted),
		pSint(27, processStarted), pSint(28, processStarted), pSint(29, -1),
		pStr(30, "25053RT47C"), pStr(31, "Redmi"), pStr(32, "25053RT47C"), pStr(33, "25053RT47C"),
		pStr(34, "Xiaomi"), pStr(35, "Redmi"), pStr(36, "Redmi"), pSint(38, 31),
	})
}

// buildMedusa 构造 x-medusa。
func buildMedusa(rawURL string, body []byte, khronos int64, deviceID, version string) string {
	var bodyMd5 []byte
	if len(body) > 0 {
		bodyMd5 = md5Of(body)
	} else {
		bodyMd5 = make([]byte, 16)
	}
	query := queryOf(rawURL)
	querySm3 := sm3([]byte(query))
	ts := le32(uint32(khronos))
	queryBodyTs := hashF13(querySm3, bodyMd5, ts, khronos)

	messageRand := randomBytes(4)
	messageRandU := readLe32(messageRand, 0)
	envLaunch := int64(100 + rndInt(21))
	envPid := int64(10001 + rndInt(2000))
	env := proto([]pfield{
		pSint(1, envLaunch), pSint(2, 146331399), pSint(3, 146331396),
		pSint(5, 7), pStr(6, "v04.06.04.03-bugfix"), pSint(7, envPid),
		pMsg(12, deviceProto(deviceID, version)),
		pMsg(13, proto([]pfield{
			pSint(1, time.Now().Unix()),
			pSint(2, -2), pSint(4, 200)})),
		pStr(14, version),
	})
	queryHash := sm3(concat([]byte(query), bodyMd5, []byte("none")))

	nested := proto([]pfield{
		pSint(1, 111), pSint(2, 10), pSint(3, 694367), pSint(5, 586952199)})
	message := proto([]pfield{
		pBytes(1, medusaMagic16), pSint(2, 3), pSint(3, int64(messageRandU)),
		pStr(4, "8662"), pStr(5, deviceID), pStr(6, "1588093228"), pStr(7, version),
		pStr(8, "v04.06.04-ml-android"), pSint(9, 67503104),
		pBytes(10, medusaMagic8), pSint(12, khronos),
		pBytes(13, queryBodyTs), pBytes(14, querySm3[0:6]),
		pMsg(15, nested), pStr(16, processNonce), pSint(17, khronos),
		pBytes(19, queryHash), pStr(20, "none"), pSint(21, 312),
		pMsg(23, env),
		pStr(24, `{"cmr":16777216,"cmr2":16777216,"un_h":1879194040,"vpn":0,"kd":0,"fkd":3672518972,"pd":-1872573247,"dyn":"","do":0,"tk":true}`),
	})

	random := rndInt32()
	hash, seed := keyHash(medusaSignKey, random)
	transformed := xmxor(message, hash)
	transformed = concat(medusaMagic8, transformed)
	// 整体逆序
	for i, j := 0, len(transformed)-1; i < j; i, j = i+1, j-1 {
		transformed[i], transformed[j] = transformed[j], transformed[i]
	}
	for i := 0; i < len(transformed); i++ {
		transformed[i] ^= seed[(^uint32(i))&3]
	}
	check := ((srcB(querySm3, 0) & 63) << 14) | 0x18000001 | ((srcB(queryBodyTs, 0) & 63) << 8)
	xmRand := rndInt32()
	packed := concat([]byte{0x35}, le32(uint32(xmRand)), le32(check), transformed,
		[]byte{byte(uint32(random) >> 16 & 255), byte(uint32(random) >> 24 & 255)})
	a := newAesV3(medusaAESKey, khronos)
	encrypted := a.encrypt(packed, medusaAESIV)
	versionBytes := mustUnhex("03000000f7e85ffad7d7dc3bd62ac87057cf6118")
	prefix := make([]byte, 20)
	kh := uint32(khronos)
	for i := 0; i < 20; i += 4 {
		putLe32(prefix, i, readLe32(versionBytes, i)^kh)
	}
	return base64.StdEncoding.EncodeToString(concat(prefix,
		[]byte{byte(uint32(random) & 255), byte(uint32(random) >> 8 & 255), 0, 1}, encrypted))
}

// helios：md5 ASCII 化 -> 64 位字表 -> 34 轮扩展 -> 分组类 Feistel。
func helios(khronos int64) string {
	return heliosWith(khronos, rndInt32())
}

// heliosWith 可注入 random 的 helios（默认重载用 rndInt32()）。
func heliosWith(khronos int64, random int32) string {
	digest := md5Of(concat(le32(uint32(random)), []byte("8662")))
	ascii := []byte(hex.EncodeToString(digest))
	var words [4]uint64
	for i := 0; i < 4; i++ {
		words[i] = readU64Le(ascii, i*8)
	}

	// JS: words.splice(0,2) 后每轮 push 一个、shift 一个，队列恒长 2。
	queue := []uint64{words[2], words[3]}
	b0 := words[0]
	b8 := words[1]
	var table [35]uint64
	table[0] = words[0]
	for i := 0; i < 34; i++ {
		x8 := rotr64(b8, 8) + b0
		x8 ^= uint64(i)
		queue = append(queue, x8)
		x8 ^= rotr64(b0, 61)
		table[i+1] = x8
		b0 = x8
		b8 = queue[0]
		queue = queue[1:]
	}
	text := strconv.FormatInt(khronos, 10) + "-1588093228-8662"
	tb := []byte(text)
	padLen := (len(tb) + 1 + 15) / 16 * 16
	pad := make([]byte, padLen)
	fill := byte((16 - (len(tb) % 16)) & 0xff)
	for i := range pad {
		pad[i] = fill
	}
	copy(pad, tb)

	all := le32(uint32(random))
	for at := 0; at < len(pad); at += 16 {
		a := readU64Le(pad, at)
		b := readU64Le(pad, at+8)
		for i := 0; i < 34; i++ {
			b = table[i] ^ (a + rotr64(b, 8))
			a = b ^ rotr64(a, 61)
		}
		block := make([]byte, 16)
		putU64Le(block, 0, a)
		putU64Le(block, 8, b)
		all = append(all, block...)
	}
	return base64.StdEncoding.EncodeToString(all)
}

// ==================== 分支判定与入口 ====================

func queryOf(rawURL string) string {
	i := strings.Index(rawURL, "?")
	if i < 0 {
		return ""
	}
	return rawURL[i+1:]
}

func paramOf(query, key, fallback string) string {
	for _, kv := range strings.Split(query, "&") {
		eq := strings.Index(kv, "=")
		if eq <= 0 {
			continue
		}
		if kv[:eq] == key {
			v := kv[eq+1:]
			if len(v) > 0 {
				return v
			}
		}
	}
	return fallback
}

// BranchOf 与 hashF13 相同的分支计算；返回 1 时服务端不认，调用方应抖动 _rticket 避开。
// 取值 0 / 2 走 hashF13 的两条实现分支，1 是服务端拒绝的分支。
func BranchOf(rawURL string, body []byte, khronos int64) int {
	var bodyMd5 []byte
	if len(body) > 0 {
		bodyMd5 = md5Of(body)
	} else {
		bodyMd5 = make([]byte, 16)
	}
	q := sm3([]byte(queryOf(rawURL)))
	iv := getIv(getIv(getIv(0x20230928, q), bodyMd5), le32(uint32(khronos)))
	low := iv & 15
	return int(low) - int((low*171)>>9)*3
}

// Sign 计算一组签名头。
//
// rawURL 必须是最终发出的完整 URL（含 query，签名对 query 字节级敏感）；
// body 为请求体字节，GET 传 nil；khronos 为秒级时间戳，<=0 时取当前时间。
func Sign(rawURL string, body []byte, khronos int64) map[string]string {
	ts := khronos
	if ts <= 0 {
		ts = time.Now().Unix()
	}
	gorgonRandom := rndInt(65536)
	query := queryOf(rawURL)
	out := make(map[string]string, 6)
	out["x-gorgon"] = xGorgon(query, body, ts, gorgonRandom)
	out["x-khronos"] = strconv.FormatInt(ts, 10)
	out["x-ladon"] = base64.StdEncoding.EncodeToString(be32(uint32(ts)))
	out["x-argus"] = base64.StdEncoding.EncodeToString(le32(uint32(ts)))
	out["x-helios"] = helios(ts)
	out["x-medusa"] = buildMedusa(rawURL, body, ts,
		paramOf(query, "device_id", "0"),
		paramOf(query, "version_name", "7.1.3.32"))
	return out
}
