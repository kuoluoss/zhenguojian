package sign6

import (
	"encoding/base64"
	"encoding/hex"
	"testing"
)

// Playback request used for regression: the exact URL/body/khronos captured from
// a working upstream request. Golden values below were produced by upstream
// pure-sign.js (E:/tmp-hgu/server/src/core/pure-sign.js), not by this package.
const (
	regURL = "https://api5-normal-sinfonlineb.fqnovel.com/novel/player/multi_video_model/v1/?ac=wifi&channel=update_64&aid=8662&app_name=novelread&version_code=71332&version_name=7.1.3.32&device_platform=android&os=android&ssmix=a&device_type=25053RT47C&device_brand=Redmi&language=zh&os_api=36&os_version=16&manifest_version_code=71332&resolution=1280*2772&dpi=520&update_version_code=71332&host_abi=arm64-v8a&dragon_device_type=phone&pv_player=71332&compliance_status=0&need_personal_recommend=1&player_so_load=1&is_android_pad_screen=0&device_id=1026319320098880&iid=1026319320102976&ts=1793681134&_rticket=1793681134056"
	regBody = `{"biz_param":{"detail_page_version":0,"device_level":3,"disable_digg_stat":false,"need_all_video_definition":true,"need_mp4_align":false,"use_os_player":false,"use_server_dns":false,"video_platform":1024},"mixed_video_id_map":{"1004":["7575846175115332632"]}}`
	regKhronos = int64(1793681134)

	// hashF13 branch 0 for (regURL query, regBody, regKhronos), upstream:
	// hashF13Hex(query, body, khronos) === "11b4f121299ee0b6b4dde648de6711428feda81a".
	// Guards the di0 "advance one slot per round" state step in hashF13.
	regHashF13 = "11b4f121299ee0b6b4dde648de6711428feda81a"
)

func TestRegressionHashF13Branch0(t *testing.T) {
	if b := BranchOf(regURL, []byte(regBody), regKhronos); b != 0 {
		t.Fatalf("BranchOf = %d, want 0 (this vector must exercise hashF13 branch 0)", b)
	}
	got := hex.EncodeToString(hashF13(
		sm3([]byte(queryOf(regURL))),
		md5Of([]byte(regBody)),
		le32(uint32(regKhronos)),
		regKhronos,
	))
	if got != regHashF13 {
		t.Fatalf("hashF13 = %s, want %s (upstream value)", got, regHashF13)
	}
}

func TestRegressionPlaybackHeaders(t *testing.T) {
	out := Sign(regURL, []byte(regBody), regKhronos)

	for _, k := range []string{"x-gorgon", "x-khronos", "x-ladon", "x-argus", "x-helios", "x-medusa"} {
		if out[k] == "" {
			t.Fatalf("header %q is empty", k)
		}
	}

	if out["x-khronos"] != "1793681134" {
		t.Fatalf("x-khronos = %q, want 1793681134", out["x-khronos"])
	}
	// Fixed by khronos: upstream samples for khronos=1793681134.
	if out["x-argus"] != "7mbpag==" {
		t.Fatalf("x-argus = %q, want 7mbpag==", out["x-argus"])
	}
	if out["x-ladon"] != "aulm7g==" {
		t.Fatalf("x-ladon = %q, want aulm7g==", out["x-ladon"])
	}

	// x-gorgon: hex string, "8404" magic + 24 bytes (26 bytes total => 52 hex chars).
	if len(out["x-gorgon"]) != 52 || out["x-gorgon"][:4] != "8404" {
		t.Fatalf("x-gorgon = %q, want 52 hex chars starting with 8404", out["x-gorgon"])
	}
	if _, err := hex.DecodeString(out["x-gorgon"]); err != nil {
		t.Fatalf("x-gorgon not hex: %v", err)
	}

	// x-helios: base64 of le32(random) + N*16 bytes.
	heliosBytes, err := base64.StdEncoding.DecodeString(out["x-helios"])
	if err != nil {
		t.Fatalf("x-helios base64: %v", err)
	}
	if n := len(heliosBytes) - 4; n <= 0 || n%16 != 0 {
		t.Fatalf("x-helios payload length = %d, want 4 + 16*k", len(heliosBytes))
	}

	// x-medusa: base64, 20-byte prefix (versionBytes ^ khronos, little endian)
	// + 4 random bytes + ciphertext. The ciphertext length varies with the random
	// varint fields, so assert the structure and a sane total length instead.
	medusaBytes, err := base64.StdEncoding.DecodeString(out["x-medusa"])
	if err != nil {
		t.Fatalf("x-medusa base64: %v", err)
	}
	if len(medusaBytes) < 700 || len(medusaBytes) > 800 {
		t.Fatalf("x-medusa decoded length = %d, want 700..800", len(medusaBytes))
	}
	versionBytes := mustUnhex("03000000f7e85ffad7d7dc3bd62ac87057cf6118")
	prefix := make([]byte, 20)
	kh := uint32(regKhronos)
	for i := 0; i < 20; i += 4 {
		putLe32(prefix, i, readLe32(versionBytes, i)^kh)
	}
	if got, want := hex.EncodeToString(medusaBytes[:20]), hex.EncodeToString(prefix); got != want {
		t.Fatalf("x-medusa prefix = %s, want %s", got, want)
	}
}