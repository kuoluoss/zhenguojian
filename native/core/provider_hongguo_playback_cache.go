package core

import (
	"sync"
	"time"
)

// 红果播放地址短缓存（0.7.18）。
//
// 目的：红果的播放地址本身带有效期（约 30 分钟），同一集在短期内反复打开
// （切集来回、暂停后重开、连播回看）没必要每次都去取流。减少请求次数可以直接
// 降低被上游判重/风控的概率——这也是「少触发」最省事的一招。
//
// 取舍：TTL 取 10 分钟，明显短于上游 30 分钟的有效期，避免拿到将过期的地址；
// 命中缓存后若播放失败，App 侧的恢复逻辑会重新取流（`force`）。

const (
	hongguoMediaCacheTTL   = 10 * time.Minute
	hongguoMediaCacheLimit = 64
)

type hongguoMediaCacheEntry struct {
	media   providerMedia
	expires time.Time
}

var hongguoMediaCache = struct {
	mu    sync.Mutex
	items map[string]hongguoMediaCacheEntry
}{items: map[string]hongguoMediaCacheEntry{}}

func hongguoMediaCacheGet(videoID string) (providerMedia, bool) {
	hongguoMediaCache.mu.Lock()
	defer hongguoMediaCache.mu.Unlock()
	entry, found := hongguoMediaCache.items[videoID]
	if !found {
		return providerMedia{}, false
	}
	if time.Now().After(entry.expires) {
		delete(hongguoMediaCache.items, videoID)
		return providerMedia{}, false
	}
	return entry.media, true
}

func hongguoMediaCachePut(videoID string, media providerMedia) {
	if videoID == "" || media.URL == "" {
		return
	}
	hongguoMediaCache.mu.Lock()
	defer hongguoMediaCache.mu.Unlock()
	now := time.Now()
	for key, entry := range hongguoMediaCache.items {
		if now.After(entry.expires) {
			delete(hongguoMediaCache.items, key)
		}
	}
	if len(hongguoMediaCache.items) >= hongguoMediaCacheLimit {
		var oldestKey string
		var oldest time.Time
		for key, entry := range hongguoMediaCache.items {
			if oldestKey == "" || entry.expires.Before(oldest) {
				oldestKey, oldest = key, entry.expires
			}
		}
		delete(hongguoMediaCache.items, oldestKey)
	}
	hongguoMediaCache.items[videoID] = hongguoMediaCacheEntry{
		media:   media,
		expires: now.Add(hongguoMediaCacheTTL),
	}
}

// hongguoMediaCacheDrop 让缓存失效（取流失败后调用，避免下次拿同一份坏地址）。
func hongguoMediaCacheDrop(videoID string) {
	hongguoMediaCache.mu.Lock()
	delete(hongguoMediaCache.items, videoID)
	hongguoMediaCache.mu.Unlock()
}