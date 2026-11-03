import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

import 'models.dart';
import 'background_downloads.dart';
import 'local_store.dart';
import 'app_build.dart';
import 'source_status.dart';
import 'ranking_models.dart';
import 'cover_decoder.dart';
import 'catalog_updates.dart';
import 'download_collections.dart';
import 'resource_settings.dart';

typedef _NativeRequest = Pointer<Utf8> Function(Pointer<Utf8>);
typedef _DartRequest = Pointer<Utf8> Function(Pointer<Utf8>);
typedef _NativeFree = Void Function(Pointer<Utf8>);
typedef _DartFree = void Function(Pointer<Utf8>);

String _nativeRequest(String body) {
  final DynamicLibrary library;
  if (Platform.isAndroid) {
    library = DynamicLibrary.open('libduanju_core.so');
  } else if (Platform.isWindows) {
    library = DynamicLibrary.open(
      path.join(path.dirname(Platform.resolvedExecutable), 'duanju_core.dll'),
    );
  } else if (Platform.isIOS) {
    library = DynamicLibrary.process();
  } else {
    throw UnsupportedError('当前首版支持 Android 手机和 Windows 电脑');
  }
  final request = library.lookupFunction<_NativeRequest, _DartRequest>(
    'DuanjuRequest',
  );
  final free = library.lookupFunction<_NativeFree, _DartFree>('DuanjuFree');
  final input = body.toNativeUtf8();
  Pointer<Utf8> output = nullptr;
  try {
    output = request(input);
    if (output == nullptr) {
      throw StateError('本地核心没有返回结果');
    }
    return output.toDartString();
  } finally {
    malloc.free(input);
    if (output != nullptr) {
      free(output);
    }
  }
}

class AppFailure implements Exception {
  AppFailure(this.message, {this.code = ''});
  final String message;
  final String code;
  @override
  String toString() => message;
}

/// 详情缓存条目：记录内容与写入时间，用于判断是否过期。
///
/// 同时保留原始 JSON（`raw`），以便落盘到本地持久化缓存，
/// 下次冷启动也能直接命中，不必重新抓取整页 HTML。
class _DetailCacheEntry {
  _DetailCacheEntry(this.detail, {this.raw}) : storedAt = DateTime.now();

  /// 从本地磁盘缓存恢复（raw 为当时保存的原始响应体）。
  _DetailCacheEntry.fromDisk(this.detail, DateTime storedTime, this.raw)
    : storedAt = storedTime;

  final DramaDetail detail;
  final DateTime storedAt;
  final Map<String, dynamic>? raw;

  Map<String, dynamic> toDiskJson() => {
    'storedAt': storedAt.millisecondsSinceEpoch,
    'raw': raw ?? const <String, dynamic>{},
  };
}

abstract class AppRepository {
  Future<Map<String, dynamic>> lan(
    String command,
    Map<String, dynamic> payload,
  ) async => throw AppFailure('当前环境不支持设备互联');
  Future<PlaybackPlan?> prepareHandoff(
    Drama drama,
    Episode episode, {
    int quality = 0,
  }) => preload(drama, episode, quality: quality);
  Future<void> cancelHandoff() async {}
  Future<ResourceSettings> resourceSettings() async => const ResourceSettings();
  Future<ResourceSettings> saveResourceSettings(
    ResourceSettings settings,
  ) async => throw AppFailure('当前环境不支持资源设置');
  final catalogUpdates = CatalogUpdates();
  Future<void> cancelPreload() async {}
  Future<PlaybackPlan?> preload(
    Drama drama,
    Episode episode, {
    int quality = 0,
    bool online = false,
  }) async => null;
  Future<void> cancelCatalog() async {}
  Future<void> cancelSuggestions() async {}
  Future<void> cancelRecommendations() async {}

  /// 首页视频流专用的目录读取。
  ///
  /// 与「发现」页的 `catalog` 使用彼此独立的读取通道，
  /// 避免两边互相取消对方的请求。
  Future<CatalogPage> feedCatalog(
    String source, {
    int page = 1,
    bool force = false,
  }) => catalog(source, page: page, force: force);
  Future<void> cancelFeedCatalog() async {}
  Future<Drama?> supplementMetadata(Drama drama) async => null;
  Future<CatalogPage> recommendations(
    String genre, {
    bool more = false,
    bool force = false,
  }) async => throw AppFailure('当前环境不支持红果推荐');
  Future<List<RankingBoard>> rankingBoards() async => const [];
  Future<RankingPage> rankings(
    String board, {
    int page = 1,
    bool force = false,
  }) async => throw AppFailure('当前环境不支持榜单');
  Future<List<CatalogCategory>> categories(
    String source, {
    bool force = false,
  }) async => const [CatalogCategory.all];
  bool get supportsSourceManagement => false;
  Future<SourceStatus> sourceStatus(String source) async =>
      SourceStatus.fromJson({'source': source});
  /// 下发红果上游参数（远程配置）。核心会校验并持久化。
  Future<void> applyUpstreamConfig(String text);

  Future<SourceStatus> startSourceJob(
    String source,
    String operation, {
    Drama? drama,
  }) async => throw AppFailure('当前环境不支持站源管理');
  Future<SourceStatus> cancelSourceJob(String source) async =>
      throw AppFailure('当前环境不支持站源管理');
  Future<List<String>> suggestions(String query) async => const [];
  Future<Map<String, dynamic>> storage() async => {};
  Future<String> downloadDirectory() async =>
      (await storage())['directory'] as String? ?? '';
  Future<void> moveDownloads(String directory) async =>
      throw AppFailure('当前环境不支持迁移');
  Future<int> workLease(String id, String command) async => 0;
  bool get supportsDownloads => false;
  Future<List<DownloadJob>> downloads() async => [];
  Future<int> enqueueDownloads(
    DramaDetail detail,
    List<Episode> episodes, {
    int quality = 0,
  }) async => throw AppFailure('当前环境不支持下载');
  Future<void> controlDownloads(String command, {String id = ''}) async {}
  Future<DownloadBatchResult> controlDownloadBatch(
    String command,
    List<String> ids, {
    Map<String, String> expectedVersions = const {},
  }) async {
    if (expectedVersions.isNotEmpty) throw AppFailure('当前环境不支持校验后清理原分集');
    final completed = <String>[], failures = <String, String>{};
    for (final id in ids.toSet()) {
      try {
        await controlDownloads(command, id: id);
        completed.add(id);
      } catch (error) {
        failures[id] = error.toString();
      }
    }
    return DownloadBatchResult(completed: completed, failures: failures);
  }

  Future<int> updateDownloadCollection(
    DramaDetail detail,
    List<Episode> episodes, {
    int quality = 0,
  }) => enqueueDownloads(detail, episodes, quality: quality);
  Future<PlaybackPlan?> localPlayback(Drama drama, Episode episode) async =>
      null;
  Future<PlaybackPlan> resolveOnline(
    Drama drama,
    Episode episode, {
    int quality = 0,
  }) => resolve(drama, episode, quality: quality);
  Future<void> initialize();
  Future<CatalogPage> catalog(
    String source, {
    int page = 1,
    String query = '',
    String category = '',
    bool force = false,
  });
  Future<CatalogPage> cached(String source, {String category = ''});
  Future<String> cover(Drama drama, {bool force = false});
  Future<DramaDetail> detail(Drama drama);
  Future<PlaybackPlan> resolve(Drama drama, Episode episode, {int quality = 0});
  Future<PlaybackPlan> fallback(PlaybackPlan current);
  Future<void> cancelPlayback();
  Future<void> release(String session);
}

class NativeRepository extends AppRepository {
  static final _coverDecoder = CoverDecoder();
  NativeRepository({this.background = false});
  final bool background;
  LocalStore? access;
  final _readOwner = DateTime.now().microsecondsSinceEpoch.toString();
  int _readSequence = 0;
  final _activeReads = <String, int>{};

  /// 详情（分集列表）内存缓存。
  /// 详情抓取 + 解析是首页与播放页的主要耗时点，缓存后重复进入可秒开。
  final _detailCache = <String, _DetailCacheEntry>{};

  /// 详情缓存有效期（内存）。
  /// 只要还在有效期内就直接命中内存，不发任何请求。
  static const _detailCacheTtl = Duration(minutes: 10);

  /// 详情**磁盘**缓存有效期（跨启动）。
  /// 用户要求「不让每次打开都重新等加载」：冷启动后首次进入同一部剧
  /// 也能先用磁盘里的旧数据秒开，再后台静默刷新。
  static const _detailDiskTtl = Duration(hours: 6);

  /// 磁盘缓存目录，首次使用时解析。
  Directory? _detailCacheDir;

  /// 磁盘缓存是否已尝试加载（避免每次失败都重复读盘/建目录）。
  bool _detailDiskLoaded = false;

  @override
  Future<Map<String, dynamic>> lan(
    String command,
    Map<String, dynamic> payload,
  ) => _call({'action': 'lan', 'command': command, 'lan': payload});

  @override
  Future<PlaybackPlan?> prepareHandoff(
    Drama drama,
    Episode episode, {
    int quality = 0,
  }) async {
    final data = await _read('handoff', {
      'action': 'prepareHandoff',
      'drama': drama.toJson(),
      'chapter': episode.raw,
      'index': episode.number,
      'quality': quality,
      'force': access != null && !access!.canDownload,
    });
    return PlaybackPlan.fromJson(data);
  }

  @override
  Future<void> cancelHandoff() => _cancelReads('handoff');

  void _adminPermission() {
    if (access != null && (access!.locked || !access!.profile.admin)) {
      throw AppFailure('仅管理员可修改本机资源设置');
    }
  }

  @override
  Future<ResourceSettings> resourceSettings() async {
    _adminPermission();
    return ResourceSettings.fromJson(
      await _call({'action': 'resourceSettings'}),
    );
  }

  @override
  Future<ResourceSettings> saveResourceSettings(
    ResourceSettings settings,
  ) async {
    _adminPermission();
    return ResourceSettings.fromJson(
      await _call({
        'action': 'saveResourceSettings',
        'settings': settings.toJson(),
      }),
    );
  }

  Future<Map<String, dynamic>> _read(
    String scope,
    Map<String, dynamic> input,
  ) async {
    final sequence = ++_readSequence;
    _activeReads[scope] = sequence;
    try {
      return await _call({
        ...input,
        'session': '$_readOwner:$scope',
        'sequence': sequence,
      });
    } finally {
      if (_activeReads[scope] == sequence) _activeReads.remove(scope);
    }
  }

  Future<void> _cancelReads(String prefix) async {
    final reads = _activeReads.entries
        .where((entry) => entry.key.startsWith(prefix))
        .toList();
    await Future.wait(
      reads.map((entry) async {
        try {
          await _call({
            'action': 'cancelRead',
            'session': '$_readOwner:${entry.key}',
            'sequence': entry.value,
          });
        } catch (_) {}
      }),
    );
  }

  @override
  Future<void> cancelPreload() => _cancelReads('preload');

  @override
  Future<PlaybackPlan?> preload(
    Drama drama,
    Episode episode, {
    int quality = 0,
    bool online = false,
  }) async => PlaybackPlan.fromJson(
    await _read('preload', {
      'action': 'preload',
      'drama': drama.toJson(),
      'chapter': episode.raw,
      'index': episode.number,
      'quality': quality,
      'force': online || access?.canDownload == false,
    }),
  );

  @override
  Future<void> cancelCatalog() => _cancelReads('catalog-');
  @override
  Future<void> cancelSuggestions() => _cancelReads('suggestions');
  @override
  Future<void> cancelRecommendations() => _cancelReads('recommendations-');

  @override
  Future<CatalogPage> feedCatalog(
    String source, {
    int page = 1,
    bool force = false,
  }) async => CatalogPage.fromJson(
    await _read('feed-catalog-$source', {
      'action': 'catalog',
      'source': source,
      'page': page,
      'query': '',
      'category': '',
      'force': force,
    }),
  );

  @override
  Future<void> cancelFeedCatalog() => _cancelReads('feed-catalog-');

  @override
  Future<CatalogPage> recommendations(
    String genre, {
    bool more = false,
    bool force = false,
  }) async {
    _authorize('hongguo');
    return CatalogPage.fromJson(
      await _read('recommendations-$genre', {
        'action': 'recommendations',
        'category': genre,
        'command': more ? 'more' : '',
        'force': force,
      }),
    );
  }

  @override
  Future<Drama?> supplementMetadata(Drama drama) async {
    if (!(drama.source == 'hongguo' && drama.onlineDate.isEmpty ||
        drama.source == 'huangdou' &&
            (drama.heat.isEmpty || drama.vipStatus == null))) {
      return null;
    }
    final result = await _read('metadata', {
      'action': 'metadata',
      'drama': drama.toJson(),
    });
    return Drama.fromJson(Map<String, dynamic>.from(result['drama'] as Map));
  }

  @override
  bool get supportsSourceManagement => true;

  @override
  Future<List<RankingBoard>> rankingBoards() async {
    final result = await _call({'action': 'rankingBoards'});
    return [
          for (final row in result['items'] as List? ?? [])
            RankingBoard.fromJson(Map<String, dynamic>.from(row as Map)),
        ]
        .where(
          (board) =>
              SourceSite.isAvailable(board.source) &&
              (access?.allowsSource(board.source) ?? true),
        )
        .toList();
  }

  @override
  Future<RankingPage> rankings(
    String board, {
    int page = 1,
    bool force = false,
  }) async => RankingPage.fromJson(
    await _call({
      'action': 'rankings',
      'board': board,
      'page': page,
      'force': force,
    }),
  );

  @override
  Future<SourceStatus> sourceStatus(String source) async =>
      SourceStatus.fromJson(
        await _call({'action': 'sourceStatus', 'source': source}),
      );

  @override
  Future<SourceStatus> startSourceJob(
    String source,
    String operation, {
    Drama? drama,
  }) async {
    _authorize(source);
    if (drama != null && drama.source != source) throw AppFailure('站源与剧集不匹配');
    final epoch = access?.profileEpoch;
    await BackgroundDownloads.ensureStarted();
    if (epoch != access?.profileEpoch) throw AppFailure('用户已切换，请重新操作');
    return SourceStatus.fromJson(
      await _call({
        'action': 'sourceJob',
        'source': source,
        'command': operation,
        if (drama != null) 'drama': drama.toJson(),
      }),
    );
  }

  @override
  Future<SourceStatus> cancelSourceJob(String source) async =>
      SourceStatus.fromJson(
        await _call({'action': 'cancelSourceJob', 'source': source}),
      );

  @override
  Future<void> applyUpstreamConfig(String text) async {
    await _call({'action': 'applyUpstreamConfig', 'text': text});
  }

  void _authorize(String source, {bool download = false}) {
    if (!SourceSite.isAvailable(source)) {
      throw AppFailure('当前版本不包含此站源');
    }
    if (access == null) return;
    if (access!.locked ||
        !access!.allowsSource(source) ||
        download && !access!.canDownload) {
      throw AppFailure('当前用户没有此操作权限');
    }
  }

  void _downloadPermission() {
    if (access != null && (access!.locked || !access!.canDownload)) {
      throw AppFailure('当前用户仅支持在线观看');
    }
  }

  @override
  Future<List<String>> suggestions(String query) async {
    _authorize('hongguo');
    final result = await _read('suggestions', {
      'action': 'suggestions',
      'query': query,
    });
    return (result['items'] as List? ?? []).whereType<String>().toList();
  }

  @override
  Future<String> downloadDirectory() async {
    _downloadPermission();
    return (await _call({'action': 'downloadDirectory'}))['directory']
            as String? ??
        '';
  }

  @override
  Future<Map<String, dynamic>> storage() async {
    _downloadPermission();
    return _call({'action': 'storage'});
  }

  @override
  Future<void> moveDownloads(String directory) async {
    _downloadPermission();
    if (access != null && !access!.profile.admin) {
      throw AppFailure('仅管理员可更改下载目录');
    }
    await BackgroundDownloads.ensureStarted();
    await workLease('storage', 'start');
    try {
      await _call({'action': 'moveDownloads', 'directory': directory});
    } finally {
      await workLease('storage', 'end');
    }
  }

  @override
  Future<int> workLease(String id, String command) async => intValue(
    (await _call({
      'action': 'workLease',
      'jobId': id,
      'command': command,
    }))['count'],
  );
  int _playbackSequence = DateTime.now().microsecondsSinceEpoch;

  Future<Map<String, dynamic>> _call(Map<String, dynamic> input) async {
    try {
      final action = input['action'] as String;
      final unrestricted =
          {
            'initialize',
            'release',
            'cancelPlayback',
            'cancelRead',
            'updateSystemProxy',
          }.contains(action) ||
          action == 'workLease' && input['command'] == 'end' ||
          action == 'lan' &&
              {
                'stop',
                'respond',
                'cancel',
                'disconnect',
              }.contains(input['command']);
      final epoch = access?.profileEpoch;
      if (!unrestricted && access?.locked == true) throw AppFailure('请先解锁当前用户');
      if (action == 'rankings') {
        _authorize(RankingBoard.sourceForID(input['board'] as String));
      }
      if (action == 'recommendations' ||
          action == 'cachedRecommendations' ||
          action == 'suggestions') {
        _authorize('hongguo');
      }
      if ({
        'catalog',
        'cached',
        'categories',
        'sourceStatus',
        'sourceJob',
        'cancelSourceJob',
      }.contains(action)) {
        _authorize(input['source'] as String);
      }
      if ({
        'cover',
        'prepareCover',
        'detail',
        'metadata',
        'resolve',
        'preload',
        'prepareHandoff',
        'enqueueDownloads',
        'localPlayback',
      }.contains(action)) {
        _authorize(
          (input['drama'] as Map)['source'] as String,
          download: action == 'enqueueDownloads' || action == 'localPlayback',
        );
      }
      if (!unrestricted &&
          {
            'downloads',
            'controlDownloads',
            'controlDownloadBatch',
            'storage',
            'downloadDirectory',
            'moveDownloads',
            'workLease',
          }.contains(action)) {
        _downloadPermission();
      }
      if (action == 'resolve' && access != null && !access!.canDownload) {
        input['force'] = true;
      }
      final body = jsonEncode(input);
      final encoded = await Isolate.run(() => _nativeRequest(body)).timeout(
        Duration(
          seconds: action == 'moveDownloads'
              ? 620
              : action == 'preload'
              ? 20
              : 70,
        ),
      );
      final response = jsonDecode(encoded) as Map<String, dynamic>;
      if (response['ok'] != true) {
        throw AppFailure(
          response['error'] as String? ?? '读取失败，请重试',
          code: response['code'] as String? ?? '',
        );
      }
      final data = response['data'];
      if (!unrestricted && epoch != access?.profileEpoch) {
        if (data is Map && data['session'] is String) {
          await release(data['session'] as String);
        }
        if (action == 'workLease' && input['command'] == 'start') {
          await workLease(input['jobId'] as String, 'end');
        }
        throw AppFailure('用户已切换，请重新操作');
      }
      return data is Map ? Map<String, dynamic>.from(data) : {};
    } on AppFailure {
      rethrow;
    } on TimeoutException {
      if (input['session'] is String &&
          input['sequence'] is int &&
          {
            'catalog',
            'categories',
            'suggestions',
            'recommendations',
            'metadata',
            'preload',
            'prepareHandoff',
          }.contains(input['action'])) {
        unawaited(
          _call({
            'action': 'cancelRead',
            'session': input['session'],
            'sequence': input['sequence'],
          }).catchError((Object _) => <String, dynamic>{}),
        );
      }
      throw AppFailure('站源响应超时，请重试');
    } catch (_) {
      throw AppFailure('本地核心加载失败，请使用完整安装包重新安装');
    }
  }

  @override
  Future<void> initialize() async {
    final directory = await getApplicationSupportDirectory();
    final build = await _call({
      'action': 'initialize',
      'directory': directory.path,
    });
    if (build['allSources'] != allSourcesEnabled) {
      throw AppFailure('应用与原生核心的站源版本不一致，请使用完整安装包重新安装');
    }
    if (!background) await BackgroundDownloads.prepare();
    if (!background) {
      SystemProxyMonitor.start((value) async {
        await _call({'action': 'updateSystemProxy', 'systemProxy': value});
      });
    }
  }

  @override
  Future<List<CatalogCategory>> categories(
    String source, {
    bool force = false,
  }) async {
    final result = await _read('categories-$source', {
      'action': 'categories',
      'source': source,
      'force': force,
    });
    return [
      for (final row in result['items'] as List? ?? const [])
        CatalogCategory.fromJson(Map<String, dynamic>.from(row as Map)),
    ];
  }

  @override
  Future<CatalogPage> catalog(
    String source, {
    int page = 1,
    String query = '',
    String category = '',
    bool force = false,
  }) async => CatalogPage.fromJson(
    await _read('catalog-$source', {
      'action': 'catalog',
      'source': source,
      'page': page,
      'query': query,
      'category': category,
      'force': force,
    }),
  );
  @override
  Future<CatalogPage> cached(String source, {String category = ''}) async =>
      CatalogPage.fromJson(
        await _call({
          'action': 'cached',
          'source': source,
          'category': category,
        }),
      );
  @override
  Future<String> cover(Drama drama, {bool force = false}) async {
    final epoch = access?.profileEpoch;
    final result = await _call({
      'action': 'cover',
      'drama': drama.toJson(),
      'force': force,
    });
    final file = result['path'] as String? ?? '';
    if (file.isEmpty) throw AppFailure('海报暂不可用');
    if (result['heic'] != true) return file;
    final converted = await _coverDecoder.convert(
      file,
      () => _call({'action': 'prepareCover', 'drama': drama.toJson()}),
      force: force,
    );
    _authorize(drama.source);
    if (epoch != access?.profileEpoch) throw AppFailure('用户已切换，请重新操作');
    return converted;
  }

  @override
  Future<DramaDetail> detail(Drama drama) async {
    // 详情（分集列表）在短时间内极少变化，但每次获取都要抓整页 HTML
    // 并解析（黄果页面很大，含热搜榜等无关区块），非常慢。
    // 缓存分三层，逐层兜底，目标是把"打开详情要等"降到接近无感：
    //   1. 内存缓存（10 分钟）：同一会话内反复进出秒开。
    //   2. 磁盘缓存（6 小时）：冷启动/切源回来也能立刻显示，同时后台刷新。
    //   3. 网络：真正去站源抓取，结果回写上面两层。
    final cacheKey = '${drama.source}|${drama.id}';
    final now = DateTime.now();
    final cachedEntry = _detailCache[cacheKey];
    if (cachedEntry != null &&
        now.difference(cachedEntry.storedAt) < _detailCacheTtl) {
      return cachedEntry.detail;
    }
    // 内存未命中 → 尝试磁盘缓存（仅首次调用时加载索引）。
    final diskEntry = await _readDetailFromDisk(cacheKey);
    if (diskEntry != null) {
      _detailCache[cacheKey] = diskEntry;
      if (now.difference(diskEntry.storedAt) < _detailDiskTtl) {
        return diskEntry.detail;
      }
    }
    try {
      final raw = await _call({'action': 'detail', 'drama': drama.toJson()});
      final detail = DramaDetail.fromJson(raw);
      _storeDetail(cacheKey, _DetailCacheEntry(detail, raw: raw));
      return detail;
    } catch (error) {
      // 网络失败时，磁盘里哪怕过期也比直接报错强（静默降级）。
      if (diskEntry != null) return diskEntry.detail;
      rethrow;
    }
  }

  /// 写入内存缓存 + 落盘。落盘失败不影响功能。
  void _storeDetail(String cacheKey, _DetailCacheEntry entry) {
    _detailCache[cacheKey] = entry;
    // 简单的容量控制，避免长时间使用后无限增长。
    if (_detailCache.length > 60) {
      final oldest = _detailCache.entries.reduce(
        (a, b) => a.value.storedAt.isBefore(b.value.storedAt) ? a : b,
      );
      _detailCache.remove(oldest.key);
    }
    unawaited(_writeDetailToDisk(cacheKey, entry));
  }

  /// 读取磁盘缓存的详情。读不到或格式异常都返回 null，绝不抛错。
  Future<_DetailCacheEntry?> _readDetailFromDisk(String cacheKey) async {
    try {
      final file = await _detailCacheFile();
      if (file == null || !await file.exists()) return null;
      final text = await file.readAsString();
      final decoded = jsonDecode(text);
      if (decoded is! Map) return null;
      final map = Map<String, dynamic>.from(decoded);
      final rows = map['entries'];
      if (rows is! Map) return null;
      final row = rows[cacheKey];
      if (row is! Map) return null;
      final rowMap = Map<String, dynamic>.from(row);
      final storedAt = rowMap['storedAt'];
      final raw = rowMap['raw'];
      if (storedAt is! int || raw is! Map) return null;
      final rawMap = Map<String, dynamic>.from(raw);
      final detail = DramaDetail.fromJson(rawMap);
      return _DetailCacheEntry.fromDisk(
        detail,
        DateTime.fromMillisecondsSinceEpoch(storedAt),
        rawMap,
      );
    } catch (_) {
      return null;
    }
  }

  /// 落盘整份缓存。为简单可靠，每次全量写入（条目数受 60 上限约束）。
  Future<void> _writeDetailToDisk(
    String cacheKey,
    _DetailCacheEntry entry,
  ) async {
    try {
      final file = await _detailCacheFile();
      if (file == null) return;
      // 先合并已有磁盘内容，避免把别部剧的记录覆盖掉。
      final merged = <String, dynamic>{};
      if (await file.exists()) {
        final decoded = jsonDecode(await file.readAsString());
        if (decoded is Map && decoded['entries'] is Map) {
          merged.addAll(Map<String, dynamic>.from(decoded['entries'] as Map));
        }
      }
      merged[cacheKey] = entry.toDiskJson();
      // 清理磁盘上过期条目，避免文件无限增长。
      final cutoff = DateTime.now().subtract(_detailDiskTtl);
      merged.removeWhere((_, value) {
        if (value is! Map) return true;
        final stored = value['storedAt'];
        if (stored is! int) return true;
        return DateTime.fromMillisecondsSinceEpoch(stored).isBefore(cutoff);
      });
      await file.writeAsString(jsonEncode({'entries': merged}));
    } catch (_) {
      // 落盘失败只是失去跨启动加速，不影响功能。
    }
  }

  /// 详情磁盘缓存文件路径。首次调用时创建目录。
  Future<File?> _detailCacheFile() async {
    try {
      var dir = _detailCacheDir;
      if (dir == null) {
        if (_detailDiskLoaded) return null;
        _detailDiskLoaded = true;
        final support = await getApplicationSupportDirectory();
        dir = Directory('${support.path}${Platform.pathSeparator}detail_cache');
        if (!await dir.exists()) await dir.create(recursive: true);
        _detailCacheDir = dir;
      }
      return File('${dir.path}${Platform.pathSeparator}details.json');
    } catch (_) {
      return null;
    }
  }

  @override
  Future<PlaybackPlan> resolve(
    Drama drama,
    Episode episode, {
    int quality = 0,
  }) async => PlaybackPlan.fromJson(
    await _call({
      'action': 'resolve',
      'drama': drama.toJson(),
      'chapter': episode.raw,
      'index': episode.number,
      'quality': quality,
      'sequence': ++_playbackSequence,
    }),
  );
  @override
  Future<PlaybackPlan> fallback(PlaybackPlan current) async =>
      PlaybackPlan.fromJson(
        await _call({
          'action': 'fallback',
          'session': current.session,
          'sequence': ++_playbackSequence,
        }),
      );
  @override
  Future<void> cancelPlayback() async {
    await _call({'action': 'cancelPlayback', 'sequence': ++_playbackSequence});
  }

  @override
  bool get supportsDownloads => access?.canDownload ?? true;

  @override
  Future<List<DownloadJob>> downloads() async {
    final result = await _call({'action': 'downloads'});
    return (result['jobs'] as List? ?? [])
        .whereType<Map>()
        .map((value) => DownloadJob.fromJson(Map<String, dynamic>.from(value)))
        .where(
          (job) =>
              SourceSite.isAvailable(job.drama.source) &&
              (access == null || access!.allowsSource(job.drama.source)),
        )
        .toList();
  }

  @override
  Future<int> enqueueDownloads(
    DramaDetail detail,
    List<Episode> episodes, {
    int quality = 0,
  }) async {
    _authorize(detail.drama.source, download: true);
    final epoch = access?.profileEpoch;
    await BackgroundDownloads.ensureStarted();
    if (epoch != access?.profileEpoch) throw AppFailure('用户已切换，请重新操作');
    final result = await _call({
      'action': 'enqueueDownloads',
      'drama': detail.drama.toJson(),
      'quality': quality,
      'entries': episodes
          .map((episode) => {'chapter': episode.raw, 'index': episode.number})
          .toList(),
    });
    return intValue(result['added']);
  }

  @override
  Future<int> updateDownloadCollection(
    DramaDetail detail,
    List<Episode> episodes, {
    int quality = 0,
  }) async {
    _authorize(detail.drama.source, download: true);
    final epoch = access?.profileEpoch;
    await BackgroundDownloads.ensureStarted();
    if (epoch != access?.profileEpoch) throw AppFailure('用户已切换，请重新操作');
    final result = await _call({
      'action': 'enqueueDownloads',
      'force': true,
      'drama': detail.drama.toJson(),
      'quality': quality,
      'entries': episodes
          .map((episode) => {'chapter': episode.raw, 'index': episode.number})
          .toList(),
    });
    return intValue(result['added']);
  }

  @override
  Future<DownloadBatchResult> controlDownloadBatch(
    String command,
    List<String> ids, {
    Map<String, String> expectedVersions = const {},
  }) async {
    _downloadPermission();
    final epoch = access?.profileEpoch;
    if (ids.isEmpty || ids.length > 500) throw AppFailure('每批请选择 1 至 500 个任务');
    final visible = (await downloads()).map((job) => job.id).toSet();
    if (ids.any((id) => !visible.contains(id))) {
      throw AppFailure('部分任务已删除或当前用户无权操作，请刷新');
    }
    if (command == 'resume') await BackgroundDownloads.ensureStarted();
    if (epoch != access?.profileEpoch) throw AppFailure('用户已切换，请重新操作');
    return DownloadBatchResult.fromJson(
      await _call({
        'action': 'controlDownloadBatch',
        'command': command,
        'jobIds': ids,
        if (expectedVersions.isNotEmpty) 'expectedVersions': expectedVersions,
      }),
    );
  }

  @override
  Future<void> controlDownloads(String command, {String id = ''}) async {
    _downloadPermission();
    if (command == 'resume' || command == 'resumeAll') {
      await BackgroundDownloads.ensureStarted();
    }
    if (access != null && !access!.profile.admin) {
      final visible = await downloads();
      if (command == 'pauseAll' || command == 'resumeAll') {
        for (final job in visible.where(
          (job) => command == 'pauseAll' ? job.active : job.resumable,
        )) {
          await _call({
            'action': 'controlDownloads',
            'command': command == 'pauseAll' ? 'pause' : 'resume',
            'jobId': job.id,
          });
        }
        return;
      }
      if (!visible.any((job) => job.id == id)) {
        throw AppFailure('当前用户没有此下载任务权限');
      }
    }
    await _call({
      'action': 'controlDownloads',
      'command': command,
      'jobId': id,
    });
  }

  @override
  Future<PlaybackPlan?> localPlayback(Drama drama, Episode episode) async {
    final result = await _call({
      'action': 'localPlayback',
      'drama': drama.toJson(),
      'index': episode.number,
    });
    if ((result['url'] as String? ?? '').isEmpty) return null;
    return PlaybackPlan.fromJson(result);
  }

  @override
  Future<PlaybackPlan> resolveOnline(
    Drama drama,
    Episode episode, {
    int quality = 0,
  }) async => PlaybackPlan.fromJson(
    await _call({
      'action': 'resolve',
      'drama': drama.toJson(),
      'chapter': episode.raw,
      'index': episode.number,
      'quality': quality,
      'force': true,
      'sequence': ++_playbackSequence,
    }),
  );

  @override
  Future<void> release(String session) async {
    if (session.isEmpty) {
      return;
    }
    try {
      await _call({'action': 'release', 'session': session});
    } catch (_) {}
  }
}
