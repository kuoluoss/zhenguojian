package core

import (
	"encoding/hex"
	"testing"
)

// TestHongguoPlaybackSignVectors 与 JS 原实现（hongguo-web playback-sign.js）逐字节对拍。
//
// 向量由固定参数生成：
//
//	query  = 下方常量
//	ts     = 1794411454
//	randField   = 1234567
//	ladonRandom = 01020304
//	aid    = 8662, license = 1611921764
func TestHongguoPlaybackSignVectors(t *testing.T) {
	const (
		query = "aid=8662&app_name=novelread&version_code=73932&version_name=7.3.9.32&device_platform=android&device_id=3524412720576332&iid=3524412720826188&video_id=7703595952870804505&video_id_type=0&ts=1794411454&_rticket=1794411454528"
		ts    = int64(1794411454)

		wantLadon = "AQIDBFgeCKBwBQdo5feREf/3yq7F8APHUjBLe2ja98bNrRn+"
		wantArgus = "8oHu8LnZm0OtJJIaSr1427D+yeH70h5aZTVjoSW7MfFi/hk1LhjTqsEEWYpwcHfK4/2kiCy2Z5CHa3AEhZ0k6OLyevLFwBOs9NIubEftPHTchp6P6anVZK2rhn3KffClOfs6z1vzit8PUEJkdn7nYx+D8smbRKwNhFTz0T09KaIlx0pZ/VbftTTFB+0KZv3svf+UWTItbXNmNHWk3LgNXBl9bG314N4jOOE7B9J88F/y5cluZyiZBpuOBT+z4ButxfL4Y28SbC7qxIGFo7TJq4h5"
	)

	ladonRandom, err := hex.DecodeString("01020304")
	if err != nil {
		t.Fatal(err)
	}
	gotLadon, err := hongguoLadonEncrypt(ts, hongguoLicenseID, 8662, ladonRandom)
	if err != nil {
		t.Fatalf("Ladon 计算失败: %v", err)
	}
	if gotLadon != wantLadon {
		t.Errorf("x-ladon 不匹配\n got=%s\nwant=%s", gotLadon, wantLadon)
	}

	gotArgus, err := hongguoArgusSign(query, "", ts, 8662, "3524412720576332", "", 1234567)
	if err != nil {
		t.Fatalf("Argus 计算失败: %v", err)
	}
	if gotArgus != wantArgus {
		t.Errorf("x-argus 不匹配\n got=%s\nwant=%s", gotArgus, wantArgus)
	}
}

// TestHongguoSM3 校验 SM3 实现对标准向量。
func TestHongguoSM3(t *testing.T) {
	got := hex.EncodeToString(sm3Sum([]byte("abc")))
	want := "66c7f0f462eeedd9d1f2d46bdc10e4e24167c4875cf2f7a2297da02b8f4ba8e0"
	if got != want {
		t.Fatalf("SM3(\"abc\") 不匹配\n got=%s\nwant=%s", got, want)
	}
}
