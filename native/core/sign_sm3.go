package core

import (
	"crypto/md5"
	"encoding/hex"
	"math/bits"
)

// SM3 摘要（GB/T 32905），语义等价 Node 的 crypto.createHash('sm3')。
// Go 标准库没有 SM3，播放签名（x-argus 的 body/query 摘要）需要它。
// 实现与 `native/core/sign6` 内的私有版本等价，此处独立一份避免跨包依赖。

var hongguoSM3IV = [8]uint32{
	0x7380166f, 0x4914b2b9, 0x172442d7, 0xda8a0600,
	0xa96f30bc, 0x163138aa, 0xe38dee4d, 0xb0fb0e4e,
}

func hongguoSM3P0(x uint32) uint32 {
	return x ^ bits.RotateLeft32(x, 9) ^ bits.RotateLeft32(x, 17)
}

func hongguoSM3P1(x uint32) uint32 {
	return x ^ bits.RotateLeft32(x, 15) ^ bits.RotateLeft32(x, 23)
}

// sm3Sum 计算 SM3-256 摘要。
func sm3Sum(data []byte) []byte {
	length := len(data)
	// padding：0x80 后补 0，最后 8 字节是比特长度（大端）
	padded := append([]byte{}, data...)
	padded = append(padded, 0x80)
	for len(padded)%64 != 56 {
		padded = append(padded, 0x00)
	}
	bitLength := uint64(length) * 8
	for shift := 56; shift >= 0; shift -= 8 {
		padded = append(padded, byte(bitLength>>uint(shift)))
	}

	state := hongguoSM3IV
	var w [68]uint32
	var w1 [64]uint32
	for block := 0; block < len(padded); block += 64 {
		chunk := padded[block : block+64]
		for i := 0; i < 16; i++ {
			w[i] = uint32(chunk[i*4])<<24 | uint32(chunk[i*4+1])<<16 |
				uint32(chunk[i*4+2])<<8 | uint32(chunk[i*4+3])
		}
		for i := 16; i < 68; i++ {
			w[i] = hongguoSM3P1(w[i-16]^w[i-9]^bits.RotateLeft32(w[i-3], 15)) ^
				bits.RotateLeft32(w[i-13], 7) ^ w[i-6]
		}
		for i := 0; i < 64; i++ {
			w1[i] = w[i] ^ w[i+4]
		}
		a, b, c, d, e, f, g, h := state[0], state[1], state[2], state[3], state[4], state[5], state[6], state[7]
		for j := 0; j < 64; j++ {
			var t uint32
			if j < 16 {
				t = 0x79cc4519
			} else {
				t = 0x7a879d8a
			}
			ss1 := bits.RotateLeft32(bits.RotateLeft32(a, 12)+e+bits.RotateLeft32(t, j%32), 7)
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
			tt2 := gg + h + ss1 + w[j]
			d = c
			c = bits.RotateLeft32(b, 9)
			b = a
			a = tt1
			h = g
			g = bits.RotateLeft32(f, 19)
			f = e
			e = hongguoSM3P0(tt2)
		}
		state[0] ^= a
		state[1] ^= b
		state[2] ^= c
		state[3] ^= d
		state[4] ^= e
		state[5] ^= f
		state[6] ^= g
		state[7] ^= h
	}
	out := make([]byte, 32)
	for i := 0; i < 8; i++ {
		out[i*4] = byte(state[i] >> 24)
		out[i*4+1] = byte(state[i] >> 16)
		out[i*4+2] = byte(state[i] >> 8)
		out[i*4+3] = byte(state[i])
	}
	return out
}

// hongguoMD5Hex 返回小写十六进制 MD5。
func hongguoMD5Hex(data []byte) string {
	sum := md5.Sum(data)
	return hex.EncodeToString(sum[:])
}
