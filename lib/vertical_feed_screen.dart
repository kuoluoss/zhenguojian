import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import 'core_bridge.dart';
import 'detail_screen.dart';
import 'follow_state.dart';
import 'lan_controller.dart';
import 'lan_models.dart';
import 'lan_screen.dart';
import 'local_store.dart';
import 'models.dart';
import 'network_state.dart';
import 'playback_preferences.dart';
import 'playback_preloader.dart';
import 'playback_recovery.dart';
import 'player_interactions.dart';
import 'system_volume.dart';
import 'screen_brightness.dart';
import 'widgets.dart';

/// 全屏横屏分区手势的类型（0.7.2，`XQ-0105`）。
enum _FsGesture { none, seek, brightness, volume, episode }

/// 首页：竖滑视频流（短视频式沉浸浏览）。
///
/// 数据来源跟随首页当前站源：
/// - 红果 → 官方推荐流（真正的随机推荐）；
/// - 其他站源 → 目录列表 + 本地随机打乱；
/// - 全部站源 → 各源混合后再打乱。
///
/// 播放行为：
/// - 默认「连播下一部」：当前这一集播完自动滑到下一部剧；
/// - 点击底部「连播本剧」后改为自动播放本剧下一集；
/// - 再点一次即回到「连播下一部」。
///
/// 播放器能力：进度拖动、单击显隐控件、双击暂停、长按 3 倍速、
/// 倍速切换、清晰度切换、选集、跳详情。
class VerticalFeedScreen extends StatefulWidget {
  const VerticalFeedScreen({
    super.key,
    required this.repository,
    required this.store,
    this.embedded = false,
    this.active = true,
    this.sources = const [],
    this.hongguoGenres,
    this.playerFactory,
    this.videoBuilder,
    this.refreshSignal,
    this.onReady,
    this.singleDrama,
    this.initialEpisodeIndex = 0,
    this.initialPosition = 0,
    this.localOnly = false,
    this.mediaId,
    this.handoff,
  });

  final AppRepository repository;
  final LocalStore store;

  /// 局域网推送**接收播放**（0.6.4 从老播放器迁移）。
  ///
  /// 非空表示本页是被"另一台设备推送过来"的播放请求打开的，
  /// 需要按 [LanIncomingPlayback] 的握手协议回报状态：
  /// - `consumed`：接收端已接管（设置后发送端才认为落地）；
  /// - `stop`：发送端要求停止时调用（本端暂停并保存进度）；
  /// - `acknowledge(position)`：**真正开始播放后**回报，发送端据此判成功；
  /// - `fail(message)`：失败/取消时回报。
  ///
  /// 与老播放器（`player_screen.dart` 的 `handoff`）语义完全一致，
  /// 迁移时保持协议不变，避免两台设备版本不一致时握手失败。
  final LanIncomingPlayback? handoff;

  /// 测试用：替换视频渲染层。
  ///
  /// 非空时不再创建 `VideoController`（它会走原生 platform channel，
  /// 在测试环境里必然失败并污染用例结果），改用注入的组件，
  /// 与旧播放器 `player_screen.dart` 的 `videoBuilder` 同一做法。
  final Widget Function(Widget controls)? videoBuilder;

  /// 单剧模式（0.2.29 新增）：
  ///
  /// 非空时只播放这一部剧，不拉取首页推荐流。
  /// 用于「详情页点播放」「下载页点播放」——用户是从某部剧进来的，
  /// 期望的滑动语义是"上滑下一集 / 下滑上一集"（只在本剧内滑动），
  /// 而不是首页那种"上滑换一部剧"的无限流。
  final Drama? singleDrama;

  /// 单剧模式的起始集索引（详情页/下载页点的是第几集）。
  final int initialEpisodeIndex;

  /// 单剧模式的起始播放位置（秒），用于续播。
  final double initialPosition;

  /// 本地文件模式（0.2.29 新增）：
  ///
  /// true 时用 `repository.localPlayback` 取**已下载的本地文件**，
  /// 而不是 `repository.resolve` 拉在线流。供下载页使用。
  final bool localOnly;

  /// 本地媒体 ID（0.6.0 新增，迁移自老播放器）。
  ///
  /// 非空表示本次播放的是「本地媒体库」里的成品文件（下载页的合并视频等），
  /// 此时观看进度写入**独立存储** `store.saveMediaWatch`，
  /// 而不是普通观看记录 `store.saveWatch`。
  ///
  /// 为什么必须分开：老播放器（`player_screen.dart`）就是这么做的——
  /// 本地媒体的进度用 `mediaWatched` 单独读取，混进普通观看记录会污染「最近观看」。
  final String? mediaId;

  /// 嵌入首页标签页时为 true：不渲染自己的 Scaffold 与返回按钮。
  final bool embedded;

  /// 当前是否可见（切到其他标签时为 false，暂停播放但不销毁）。
  final bool active;

  /// 当前生效的站源集合（由首页传入，随站源切换变化）。
  final List<SourceSite> sources;

  /// 红果推荐流要取的分类（0.7.2，`XQ-0106`）。
  ///
  /// null 表示默认三类混合（真人剧 + 漫剧 + AI 剧）。
  /// 用户选「真人剧」时传 `['short_play']`；选「漫剧」时传
  /// `['comic_series', 'ai_series']`（漫剧含 AI 剧）。
  ///
  /// 这套分类**只有红果支持**，首页只在"单独选中红果"时才传非空值。
  final List<String>? hongguoGenres;

  /// 测试用：注入假播放器，避免依赖原生库。
  @visibleForTesting
  final Player Function()? playerFactory;

  /// 外部触发的"重新随机"信号（双击首页标签时自增）。
  final ValueNotifier<int>? refreshSignal;

  /// 首次拿到可播放视频后回调一次（用于关闭开屏页）。
  final VoidCallback? onReady;

  @override
  State<VerticalFeedScreen> createState() => _VerticalFeedScreenState();
}

class _VerticalFeedScreenState extends State<VerticalFeedScreen>
    with SingleTickerProviderStateMixin {
  /// 红果官方推荐流支持的分类（三类混合随机）。
  static const _hongguoGenres = ['short_play', 'comic_series', 'ai_series'];

  final _controller = PageController();
  final _focus = FocusNode(debugLabel: 'vertical-feed');
  final _random = math.Random();

  /// 本次会话是否手动点过播放（0.7.3，`XQ-0107`）。
  ///
  /// 放在父级是为了**跨页共享**：移动网络下第一页要用户点一下才播；
  /// 点过之后，后续切集/切部不再拦截（用户明确选"本次继续自动连播"）。
  final _manualPlayed = ValueNotifier<bool>(false);

  /// 本次会话是否已经"越过第一个视频"（0.7.12，`XQ-0119`）。
  ///
  /// 用户要求：移动网络下的"不自动播、不预载"**只限制启动后的第 1 个视频**；
  /// 一旦滑到第 2 个视频，就与"手动点过播放"同等对待，此后全部放开
  /// （双击首页刷新随机也不得重新拦截）。
  final _unlocked = ValueNotifier<bool>(false);

  /// 连播本剧切集滑动动画（0.7.14，`XQ-0123`）。
  ///
  /// 用户要求"和连播下一部一样的动画"：手指拖动时画面跟着走，松手滑够就翻过去。
  /// `PageView` 的页是"一部剧一页"，翻不了"同一部剧的下一集"，
  /// 所以这里自己实现一套位移：拖动跟手、松手回弹或滑出，滑出结束再切集。
  late final AnimationController _slideAnimation;
  final _slideOffset = ValueNotifier<double>(0);
  Animation<double>? _slideCurve;
  bool _slideStartedInGuard = false;

  /// 切集后"等新集就绪再复位位移"的兜底定时器（0.7.15，`XQ-0124`）。
  Timer? _episodeHoldTimer;

  /// 「因自动连播而进入」的目标页索引（0.7.4）。
  ///
  /// 播完自动跳下一部时设置；被跳到的页面据此**一开始就静默**（不弹控件）。
  /// 用户手动切页时置空。
  int? _autoEnterIndex;

  List<Drama> _items = [];
  final _seen = <String>{};
  bool _loading = true;
  bool _loadingMore = false;
  bool _hasMore = true;
  String? _error;
  int _index = 0;
  int _page = 1;
  int _generation = 0;
  bool _closed = false;

  /// 连播模式：true = 连播本剧下一集，false = 连播下一部（默认）。
  bool _autoNextEpisode = false;

  /// 全流共享的预载器（0.6.9）。
  ///
  /// **根因修复**：此前每个 `_FeedPage` 各建一个预载器，而"连播下一部"
  /// 预载的是**下一部剧**——结果存在本页预载器里，滑过去的是**另一个页面**，
  /// 取不到；且本页滑走时会 clear+release，等于**预载白做又被释放**。
  /// 实测：预载 `甲剧1` → 滑过去 → `release(甲剧1)` + `resolve(甲剧1)`，
  /// 用户感受就是"完全没有预加载、每次都要现加载"。
  /// 改为父级持有、传给所有页面后，预载结果可跨页复用。
  late final PlaybackPreloader _preloader;

  /// 当前页「切到下一集」的执行入口（由子页上报）。
  ///
  /// 注意：这里**不能**用 GlobalKey 去访问当前页 State。
  /// 同一个 Widget 树里 GlobalKey 只能存在一份，若随着"当前页"来回换 key，
  /// Flutter 会把上一个 State（含播放器实例）整体搬移到新位置，
  /// 导致"标题已换成新剧、视频却还是上一部"的严重错乱。
  Future<void> Function()? _pagePlayNextEpisode;

  /// 当前页「切到上一集」的执行入口（由子页上报）。
  Future<void> Function()? _pagePlayPrevEpisode;

  /// 是否已上报过就绪（只回调一次）。
  bool _reportedReady = false;

  /// 正在切换站源（用于在屏幕上给出"正在切换到 XX…"提示）。
  ///
  /// 0.2.27 新增（用户反馈"切换了源后有很大概率一直卡在为你挑选好剧位置卡很久"）：
  /// 切源属于一次全新的拉取，可能因镜像竞速耗时较久。
  /// 若界面只有"正在为你挑选短剧…"这一句，用户会以为"切了却没反应"。
  /// 因此记录本次切源的目标站源名与开始时间，在加载页展示带站源名和
  /// 已等待秒数的提示，明确告知"正在切换、没有卡死"。
  String? _switchingTo;
  DateTime? _switchStartedAt;
  Timer? _switchTicker;

  /// 切源提示的超时上限（0.2.27：用户确认 60 秒太短，改为 2 分钟）。
  ///
  /// 到达后停止"继续等待"的暗示，转为"可重试"的兜底提示，
  /// 避免用户无限等待一个实际上已经失败的请求。
  static const _switchTimeout = Duration(minutes: 2);

  /// 站源切换提示的刷新计时器（每秒刷新已等待秒数）。
  void _startSwitchTicker(String target) {
    _switchTicker?.cancel();
    _switchingTo = target;
    _switchStartedAt = DateTime.now();
    _switchTicker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_closed || !mounted) return;
      setState(() {});
    });
  }

  /// 结束切源提示。
  void _stopSwitchTicker() {
    _switchTicker?.cancel();
    _switchTicker = null;
    _switchingTo = null;
    _switchStartedAt = null;
  }

  /// 当前切源已等待的秒数（未在切源时为 0）。
  int get _switchElapsed => _switchStartedAt == null
      ? 0
      : DateTime.now().difference(_switchStartedAt!).inSeconds;

  /// 切源是否已超过兜底时间上限。
  bool get _switchTimedOut => _switchElapsed >= _switchTimeout.inSeconds;

  /// 首批视频到手后通知外部（关闭开屏页）。
  void _reportReady() {
    if (_reportedReady) return;
    _reportedReady = true;
    widget.onReady?.call();
  }

  /// 首页取流失败时，是否已临时借用「已授权但未选中」的站源兜底（0.7.18）。
  ///
  /// 目的：红果等单个源抽风时，首页不应整页空白——只要用户还有其他已授权源，
  /// 就自动改用全部可用源再取一次，保证首页始终有内容。
  bool _borrowAllSources = false;

  /// 当前生效的站源集合。
  List<SourceSite> get _sources {
    if (_borrowAllSources) {
      return widget.store.sources
          .where((source) => widget.store.allowsSource(source.id))
          .toList();
    }
    final list = widget.sources.isNotEmpty
        ? widget.sources
        : widget.store.sources;
    return list
        .where((source) => widget.store.allowsSource(source.id))
        .toList();
  }

  /// 取流失败/为空时尝试借用其他已授权源；返回 true 表示已触发重载。
  bool _tryBorrowSources() {
    if (_borrowAllSources || widget.singleDrama != null) return false;
    final current = _sources.map((source) => source.id).toSet();
    final all = widget.store.sources
        .where((source) => widget.store.allowsSource(source.id))
        .toList();
    if (all.length <= current.length) return false;
    _borrowAllSources = true;
    _error = null;
    unawaited(_load(force: true));
    return true;
  }

  String _signatureOf(List<SourceSite> sources) =>
      sources.map((source) => source.id).join(',');

  @override
  void initState() {
    super.initState();
    widget.refreshSignal?.addListener(_onRefreshSignal);
    // 全流共享预载器（0.6.9）：由本页创建、传给所有子页，并在 dispose 释放。
    _preloader = PlaybackPreloader(widget.repository);
    // 0.7.14（XQ-0123）：连播本剧的切集滑动动画驱动。
    _slideAnimation = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
    )..addListener(_onSlideTick);
    // 单剧模式（0.2.29）：详情页/下载页进入时只播指定的一部剧，
    // 直接构造单元素列表，跳过推荐流拉取。
    final single = widget.singleDrama;
    if (single != null) {
      _items = [single];
      _loading = false;
      _hasMore = false;
      // 单剧模式下默认「连播本剧」：
      // 这样上滑=下一集、下滑=上一集，符合用户"看这部剧"的直觉，
      // 不必先点「连播本剧」按钮。
      _autoNextEpisode = true;
    } else {
      _load();
    }
  }

  @override
  void didUpdateWidget(covariant VerticalFeedScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.refreshSignal != widget.refreshSignal) {
      oldWidget.refreshSignal?.removeListener(_onRefreshSignal);
      widget.refreshSignal?.addListener(_onRefreshSignal);
    }
    if (_signatureOf(oldWidget.sources) != _signatureOf(widget.sources)) {
      // 0.2.27：切源时带上目标站源名，让加载页显示"正在切换到 XX…"，
      // 避免用户产生"切了却没反应"的错觉（用户真机反馈第 5 条）。
      final names = widget.sources.isEmpty
          ? widget.store.sources
          : widget.sources;
      final label = names.length > 1
          ? '全部站源'
          : (names.isEmpty ? '' : names.first.name);
      _reset(switchTo: label.isEmpty ? null : label);
    }
    // 0.7.2（XQ-0106）：剧类筛选变化 → 换一批内容。
    final oldGenres = (oldWidget.hongguoGenres ?? const <String>[]).join(',');
    final newGenres = (widget.hongguoGenres ?? const <String>[]).join(',');
    if (oldGenres != newGenres) {
      _reset(force: true);
    }
  }

  /// 双击首页标签：换一批新的随机内容。
  void _onRefreshSignal() {
    if (_closed) return;
    _reset(force: true);
  }

  @override
  void dispose() {
    _closed = true;
    _generation++;
    _switchTicker?.cancel();
    widget.refreshSignal?.removeListener(_onRefreshSignal);
    unawaited(widget.repository.cancelRecommendations());
    unawaited(widget.repository.cancelFeedCatalog());
    // 预载器释放（0.6.9）：取消挂起请求并释放已预取的会话，避免会话泄漏。
    _preloader.dispose();
    _manualPlayed.dispose();
    _unlocked.dispose();
    _episodeHoldTimer?.cancel();
    _episodeHoldTimer = null;
    _slideAnimation.dispose();
    _slideOffset.dispose();
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  /// 站源切换后重新开始随机。
  ///
  /// [switchTo]：本次切源的目标站源名（用于给出"正在切换到 XX…"提示）。
  /// 双击首页标签换一批时不传，保持原有"正在为你挑选短剧…"文案。
  void _reset({bool force = false, String? switchTo}) {
    if (_closed) return;
    _generation++;
    if (_controller.hasClients) _controller.jumpToPage(0);
    setState(() {
      _items = [];
      _seen.clear();
      _index = 0;
      _page = 1;
      _hasMore = true;
      _error = null;
    });
    if (switchTo != null && switchTo.isNotEmpty) {
      _startSwitchTicker(switchTo);
    } else {
      _stopSwitchTicker();
    }
    _load(force: force);
  }

  Future<void> _load({bool more = false, bool force = false}) async {
    if (_closed) return;
    // 单剧模式（0.2.29）：不拉推荐流，列表固定为指定的一部剧。
    if (widget.singleDrama != null) return;
    if (more && (_loading || _loadingMore || !_hasMore)) return;
    final generation = ++_generation;
    final sources = _sources;
    setState(() {
      if (more) {
        _loadingMore = true;
      } else {
        _loading = true;
      }
      _error = null;
    });
    if (sources.isEmpty) {
      _stopSwitchTicker();
      if (mounted && generation == _generation) {
        setState(() {
          _loading = false;
          _loadingMore = false;
          _hasMore = false;
        });
      }
      return;
    }
    final page = more ? _page + 1 : 1;
    try {
      final batch = await _fetch(sources, page, more: more, force: force);
      if (_closed || generation != _generation) return;
      final known = more ? _seen : <String>{};
      final accepted = <String>{};
      final fresh = <Drama>[];
      for (final drama in batch.items) {
        if (drama.id.isEmpty || !known.add(drama.id)) continue;
        accepted.add(drama.id);
        fresh.add(drama);
      }
      setState(() {
        if (!more) _seen.clear();
        _seen.addAll(accepted);
        _items = more ? [..._items, ...fresh] : fresh;
        _page = page;
        _hasMore = batch.hasMore;
        _error = batch.warning.isEmpty ? null : batch.warning;
        _loading = false;
        _loadingMore = false;
      });
      _stopSwitchTicker();
      if (_items.isNotEmpty) {
        _reportReady();
      } else if (!more && _tryBorrowSources()) {
        // 所选源一条都没返回：先借用其他已授权源兜底，避免首页空白。
        return;
      }
    } catch (error) {
      if (_closed || generation != _generation) return;
      _stopSwitchTicker();
      if (!more && _tryBorrowSources()) {
        // 所选源全部失败：借用其他已授权源再试一次，不让首页整页空白。
        return;
      }
      setState(() {
        _loading = false;
        _loadingMore = false;
        _error = error.toString();
      });
    }
  }

  /// 过滤掉"已看完"的剧（0.6.5，用户要求）。
  ///
  /// 用户原话："**我认为已看过的不需要再出现在随机里了**"。
  ///
  /// 判定：追剧状态为 `watched`（已看）→ 不再进入随机流。
  /// 注意只排除**已看**，不排除"在看"——正在追的剧仍应能被刷到。
  ///
  /// **兜底**：若过滤后一条都不剩（例如新用户把刷到的都看完了），
  /// 则**退回未过滤的结果**。否则会出现"刷新之后一片空白"，
  /// 比偶尔刷到看过的剧更糟。
  List<Drama> _excludeWatched(List<Drama> items) {
    if (items.isEmpty) return items;
    final kept = items
        .where((drama) => widget.store.following(drama.id)?.status !=
            FollowStatus.watched)
        .toList();
    return kept.isEmpty ? items : kept;
  }

  /// 拉取一批剧集。
  ///
  /// 单源红果走官方推荐流（真随机）；其余情况读取目录分页，
  /// 多源交错合并后再本地打乱。
  ///
  /// 注意：多个站源**并行**请求。原先是 `for` 循环里逐个 await，
  /// 4 个源就要等 4 次往返，这是"其他源比红果慢很多"的主因。
  Future<_FeedBatch> _fetch(
    List<SourceSite> sources,
    int page, {
    required bool more,
    bool force = false,
  }) async {
    if (sources.length == 1 && sources.first.id == 'hongguo') {
      return _fetchHongguo(more: more, force: force);
    }
    final results = await Future.wait(
      sources.map((source) async {
        if (_closed) return null;
        try {
          return await widget.repository.feedCatalog(
            source.id,
            page: page,
            force: force,
          );
        } catch (error) {
          return _SourceFeedFailure('${source.name}：$error');
        }
      }),
    );
    final rows = <List<Drama>>[];
    final warnings = <String>[];
    var hasMore = false;
    for (final result in results) {
      if (result is _SourceFeedFailure) {
        warnings.add(result.message);
        continue;
      }
      if (result is! CatalogPage) continue;
      rows.add(
        result.items
            .where((drama) => widget.store.allowsSource(drama.source))
            .toList(),
      );
      if (result.hasMore) hasMore = true;
      if (result.warning.isNotEmpty) warnings.add(result.warning);
    }
    final merged = <Drama>[];
    final longest = rows.fold<int>(
      0,
      (best, row) => math.max(best, row.length),
    );
    for (var index = 0; index < longest; index++) {
      for (final row in rows) {
        if (index < row.length) merged.add(row[index]);
      }
    }
    merged.shuffle(_random);
    return _FeedBatch(
      _excludeWatched(merged),
      hasMore: hasMore,
      warning: warnings.isEmpty ? '' : warnings.join('；'),
    );
  }

  /// 红果：真人剧 / 漫剧 / AI 剧 三类混合后随机。
  ///
  /// 每次打开软件首次进入时强制拉新（游标归零），避免每次都是同一批；
  /// 三类**并行**请求后再交错打乱——原先是顺序请求，等于把延迟乘以 3。
  Future<_FeedBatch> _fetchHongguo({
    required bool more,
    bool force = false,
  }) async {
    final warnings = <String>[];
    var hasMore = false;
    final rows = <List<Drama>>[];
    final results = await Future.wait(
      (widget.hongguoGenres ?? _hongguoGenres).map((genre) async {
        if (_closed) return null;
        try {
          return await widget.repository.recommendations(
            genre,
            more: more,
            force: force || !more,
          );
        } catch (error) {
          // 单个分类失败不影响其它分类。
          return _SourceFeedFailure('$error');
        }
      }),
    );
    for (final result in results) {
      if (result is _SourceFeedFailure) {
        warnings.add(result.message);
        continue;
      }
      if (result is! CatalogPage) continue;
      rows.add(
        result.items
            .where((drama) => widget.store.allowsSource(drama.source))
            .toList(),
      );
      if (result.hasMore) hasMore = true;
      if (result.warning.isNotEmpty) warnings.add(result.warning);
    }
    final merged = <Drama>[];
    final longest = rows.fold<int>(
      0,
      (best, row) => math.max(best, row.length),
    );
    for (var index = 0; index < longest; index++) {
      for (final row in rows) {
        if (index < row.length) merged.add(row[index]);
      }
    }
    merged.shuffle(_random);
    return _FeedBatch(
      _excludeWatched(merged),
      hasMore: hasMore,
      warning: warnings.isEmpty ? '' : warnings.join('；'),
    );
  }

  void _onPageChanged(int index) {
    if (_closed) return;
    // 0.7.12（XQ-0119）：滑到第 2 个及以后的视频 → 本次会话解锁
    // （移动网络下不再拦自动播放与预载）。必须在 setState 之前置位，
    // 因为 `_index` 变化会立刻让新页成为当前页并开始 `_prepare`。
    if (index > 0 && !_unlocked.value) _unlocked.value = true;
    setState(() => _index = index);
    // 单剧模式（0.2.29）：只有一部剧，不存在"加载更多"。
    if (widget.singleDrama != null) return;
    // 接近末尾时自动加载下一批。
    if (_hasMore && !_loadingMore && index >= _items.length - 2) {
      unawaited(_load(more: true));
    }
  }

  /// 子页上报"能否切集"，并同时提供切集入口。
  ///
  /// [hasNext]：本页是否还有下一集；[playNext]：切到下一集的执行函数。
  /// [hasPrev]：本页是否还有上一集；[playPrev]：切到上一集的执行函数。
  ///
  /// 之所以用回调而不是 GlobalKey：GlobalKey 在同一 Widget 树中必须唯一，
  /// 若随"当前页"来回更换，Flutter 会搬移 State（含播放器）导致画面错乱。
  ///
  /// 0.2.26 变更：不再用上报结果决定 `PageView.physics` 与手势接管
  /// （那会导致首帧不一致的 bug，见 `_onVerticalDrag` 注释）。
  /// 因此这里只保存切集入口，**不需要 setState 重建**，
  /// 顺带消除了"每次上报都重建整棵竖滑树"的额外开销。
  void _onPageEpisodeStateChanged(
    bool hasNext, {
    Future<void> Function()? playNext,
    bool hasPrev = false,
    Future<void> Function()? playPrev,
  }) {
    if (_closed) return;
    _pagePlayNextEpisode = hasNext ? playNext : null;
    _pagePlayPrevEpisode = hasPrev ? playPrev : null;
  }

  /// 处理竖向拖拽结束时的滑动判定（仅在 PageView 被禁用滚动时生效）。
  ///
  /// 说明：当「连播本剧」开启且当前剧还有下一集时，PageView 会被设为
  /// `NeverScrollableScrollPhysics`，避免它抢占手势；此时由这里统一处理。
  ///
  /// 滑动语义（0.2.26 修正，用户确认方案 A）：
  /// - **向上滑 = 下一集**（符合短视频"往下看内容"的直觉：手指上推看后面的）。
  /// - **向下滑 = 上一集**。
  /// - 已到第一集/最后一集时，回落为"切上一部 / 下一部剧"。
  ///
  /// 0.2.27 新增（用户反馈第 4 条）：
  /// 在「连播本剧」模式下，若已到**第一集**仍继续下滑、或已到**最后一集**
  /// 仍继续上滑，会落到"切上一部 / 下一部剧"分支。此时当前剧已看尽，
  /// 再保持"连播本剧"毫无意义，因此**自动复位为「连播下一部」**并给出轻提示，
  /// 否则用户会以为模式没变、不知道为何不再连播本剧。
  ///
  /// 历史问题（0.2.25 真机反馈）：
  /// 1. 方向写反——原实现把 `velocity > 0`（向下滑）当成"下一集"。
  /// 2. 首帧未上报时误判——`_pageHasNextEpisode` 初始为 false，
  ///    第一页进入后若 episode 状态还没上报，`_currentPageCanPlayNext`
  ///    为 false 会走"切部"分支；而第二页上报后就变成"切集"，
  ///    因此表现为"第一部要下滑才切下集、第二部上滑却回上一部剧"。
  ///    修法：只要处于「连播本剧」模式，就一律由本方法接管并优先切集，
  ///    不再依赖"是否上报了下一集"来做分支（切集函数内部自身会判断边界）。
  /// 顶部禁滑区高度（0.6.7，用户要求）。
  ///
  /// 背景：从屏幕**最顶部**向下滑是系统手势（拉出通知栏 / 控制中心），
  /// 但播放器把"下滑"用作"切上一集"，两者冲突——用户想拉通知栏却切了集。
  ///
  /// 这里在顶部留出一段**不响应播放器滑动**的区域，
  /// 让系统手势正常生效（用户确认取 **60** 逻辑像素）。
  ///
  /// 注意：只是**不响应切集滑动**，单击显隐控件、双击播放/暂停仍照常，
  /// 否则顶部会出现"点了没反应"的死区。
  static const double _topGestureGuard = 60;

  /// 触点是否落在顶部禁滑区（0.6.7）。
  ///
  /// [localY] 用 `Listener` 的 `event.localPosition.dy`（相对手势层顶部）。
  /// 手势层是 `Positioned.fill`，因此其顶部即屏幕顶部（不含系统栏偏移）。
  bool _inTopGuard(Offset localPosition) =>
      localPosition.dy < _topGestureGuard;


  /// 真正执行"上下滑"的语义（0.7.14 从 `_onVerticalDrag` 拆出，供动画结束时调用）。
  ///
  /// [direction]：`1` = 上滑（下一集），`-1` = 下滑（上一集）。
  void _commitVerticalSwipe(int direction) {
    // 单剧模式（0.2.29，用户方案 C）：
    // 只在本剧内滑动。到边界（第一集/最后一集）时**不切剧**，
    // 只给一句提示，避免用户莫名其妙地跳到别的剧去。
    final single = widget.singleDrama != null;
    if (direction > 0) {
      // 向上滑 = 下一集。
      if (_autoNextEpisode) {
        final playNext = _pagePlayNextEpisode;
        if (playNext != null) {
          // 0.7.15（XQ-0124）：画面先停在屏幕外（纯黑），等新集就绪再复位；
          // 否则会在"换源完成前"闪一下上一集的最后一帧。
          _holdUntilEpisodeReady(playNext());
          return;
        }
        if (single) {
          _toast('已经是最后一集了');
          _slideOffset.value = 0;
          return;
        }
        // 已到最后一集：回落为切下一部剧，并复位连播模式（0.2.27）。
        _resetAutoNextAtBoundary('本剧已看完，已切换为连播下一部');
      }
      _slideOffset.value = 0;
      _jump(1);
    } else {
      // 向下滑 = 上一集。
      if (_autoNextEpisode) {
        final playPrev = _pagePlayPrevEpisode;
        if (playPrev != null) {
          _holdUntilEpisodeReady(playPrev());
          return;
        }
        if (single) {
          _toast('已经是第一集了');
          _slideOffset.value = 0;
          return;
        }
        // 已到第一集：回落为切上一部剧，并复位连播模式（0.2.27）。
        _resetAutoNextAtBoundary('已是第一集，已切换为连播下一部');
      }
      _slideOffset.value = 0;
      _jump(-1);
    }
  }

  void _onSlideTick() => _slideOffset.value = _slideCurve!.value;

  /// 开始跟手拖动（仅「连播本剧」模式注册）。
  void _onSlideStart(DragStartDetails details) {
    if (_closed || _slideAnimation.isAnimating) return;
    _slideStartedInGuard = _inTopGuard(details.localPosition);
    _slideOffset.value = 0;
  }

  /// 跟手移动：画面位移 = 手指位移，范围限制在一屏以内。
  void _onSlideUpdate(DragUpdateDetails details) {
    if (_closed || _slideStartedInGuard || _slideAnimation.isAnimating) return;
    final height = MediaQuery.sizeOf(context).height;
    _slideOffset.value = (_slideOffset.value + details.delta.dy).clamp(
      -height,
      height,
    );
  }

  /// 松手：滑够一半屏高或够快就继续滑出并切集，否则回弹。
  void _onSlideEnd(DragEndDetails details) {
    if (_closed) return;
    if (_slideStartedInGuard) {
      _slideStartedInGuard = false;
      _slideOffset.value = 0;
      return;
    }
    if (_slideAnimation.isAnimating) return;
    final height = MediaQuery.sizeOf(context).height;
    final offset = _slideOffset.value;
    final velocity = details.primaryVelocity ?? 0;
    final far = offset.abs() > height * 0.25;
    final fast = velocity.abs() > 600;
    // 方向优先看甩动速度，其次看拖到了哪一侧。
    final int direction;
    if (fast) {
      direction = velocity < 0 ? 1 : -1;
    } else if (far) {
      direction = offset < 0 ? 1 : -1;
    } else {
      direction = 0;
    }
    if (direction == 0) {
      _runSlide(end: 0, direction: 0);
    } else {
      _runSlide(end: direction > 0 ? -height : height, direction: direction);
    }
  }

  /// 跑一段位移动画：[end] 为目标位移，[direction] 非 0 时在动画结束后切集。
  ///
  /// 滑出结束时的画面已经全部在屏幕外（露出黑底），此时立刻切集并把
  /// 位移复位到 0，用户看不到"跳回去"，视觉上就是一页翻过去。
  void _runSlide({required double end, required int direction}) {
    _slideCurve = Tween<double>(begin: _slideOffset.value, end: end).animate(
      CurvedAnimation(parent: _slideAnimation, curve: Curves.easeOutCubic),
    );
    _slideAnimation.forward(from: 0).whenCompleteOrCancel(() {
      if (_closed || !mounted) return;
      if (direction == 0) {
        _slideOffset.value = 0;
        return;
      }
      // 0.7.15：滑出后**不立刻复位**——交给 `_commitVerticalSwipe` 里的
      // "等新集就绪再复位"，否则换源完成前会闪一下上一集的最后一帧。
      _commitVerticalSwipe(direction);
    });
  }

  /// 切集后让画面停在屏幕外（纯黑），等新集真正就绪再复位（0.7.15，`XQ-0124`）。
  ///
  /// 为什么要这样：切集第一步是保存进度（异步写盘），之后才换片源；
  /// 这期间播放器还在显示上一集的最后一帧。若动画一结束就复位，
  /// 用户就会看到"上一集最后画面闪一下"。
  ///
  /// 10 秒兜底：加载失败或卡住时也必须复位，否则错误提示会被挡在屏幕外。
  void _holdUntilEpisodeReady(Future<void> loading) {
    _episodeHoldTimer?.cancel();
    var released = false;
    void release() {
      if (released) return;
      released = true;
      _episodeHoldTimer?.cancel();
      _episodeHoldTimer = null;
      if (_closed || !mounted) return;
      _slideOffset.value = 0;
    }

    loading.whenComplete(release);
    _episodeHoldTimer = Timer(const Duration(seconds: 10), release);
  }

  /// 在连播本剧模式下因到达首/尾集而切部时，自动复位为「连播下一部」。
  ///
  /// 0.2.27 新增（用户反馈第 4 条，方案 A + 轻提示）：
  /// 只在"因边界切部"时调用，不会在正常切集时误触发。
  void _resetAutoNextAtBoundary(String message) {
    if (!_autoNextEpisode) return;
    setState(() => _autoNextEpisode = false);
    _toast(message);
  }

  /// 轻提示（底部 SnackBar）。
  void _toast(String message) {
    if (_closed || !mounted) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    messenger?.showSnackBar(
      SnackBar(
        content: Text(message),
        duration: const Duration(seconds: 2),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  /// 遥控器 / 键盘上下键切换。
  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.arrowDown ||
        key == LogicalKeyboardKey.mediaTrackNext) {
      _jump(1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowUp ||
        key == LogicalKeyboardKey.mediaTrackPrevious) {
      _jump(-1);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  bool _jump(int delta, {bool auto = false}) {
    if (_closed) return false;
    final target = _index + delta;
    if (target < 0) return false;
    if (target >= _items.length) {
      // 单剧模式（0.2.29）：只有一部剧，不拉取、不跳转。
      if (widget.singleDrama != null) return false;
      // 已到末尾：继续拉取下一批，拉不到就停在当前页。
      if (_hasMore && !_loadingMore && !_loading) {
        unawaited(_load(more: true));
      }
      return false;
    }
    // 0.7.4 修复（真机反馈"全屏连播下一部仍会弹控件"）：
    // 播完自动跳下一部时，标记"目标页是自动进来的"，新页面据此不弹控件
    // （与自动切集同一套静默逻辑）。用户手动切页时清掉标记。
    setState(() {
      _autoEnterIndex = auto ? target : null;
    });
    if (_controller.hasClients) {
      _controller.animateToPage(
        target,
        duration: const Duration(milliseconds: 260),
        curve: Curves.easeOutCubic,
      );
      return true;
    }
    return false;
  }

  /// 供子页竖滑调用：切换上一部/下一部（0.7.5，`XQ-0108`）。
  bool _jumpForSwipe(int delta) => _jump(delta);

  @override
  Widget build(BuildContext context) {
    final content = Focus(
      focusNode: _focus,
      autofocus: true,
      onKeyEvent: _onKey,
      child: ColoredBox(color: Colors.black, child: _body()),
    );
    if (widget.embedded) return content;
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Column(
          children: [
            _header(),
            Expanded(child: content),
          ],
        ),
      ),
    );
  }

  Widget _header() => Container(
    color: Colors.black,
    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
    child: Row(
      children: [
        IconButton(
          onPressed: () => Navigator.of(context).maybePop(),
          icon: const Icon(Icons.arrow_back_rounded, color: Colors.white),
          tooltip: '返回',
        ),
        // 单剧模式（0.6.2）：不再显示站源文字。
        //
        // 原先无条件显示 `_sourceLabel()`，而它读的是**首页当前勾选的站源集合**
        // （见 `_sources`），与"正在播哪部剧"无关：
        // 首页勾了多个源时，从详情页/下载页/本地媒体进入的单剧播放器
        // 会错误地显示「全部站源」。单剧模式本就不涉及选源，
        // 且本地媒体那条剧没有真实站源，故整行去掉，只保留返回按钮。
        if (widget.singleDrama == null) Expanded(child: _sourceLabel()),
      ],
    ),
  );

  Widget _sourceLabel() => Align(
    alignment: Alignment.centerLeft,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Text(
        _sources.isEmpty
            ? '暂无可用站源'
            : _sources.length > 1
            ? '全部站源'
            : _sources.first.name,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 16,
          fontWeight: FontWeight.w700,
        ),
      ),
    ),
  );

  Widget _body() {
    if (_sources.isEmpty) {
      return const Center(
        child: Text('暂无可用站源', style: TextStyle(color: Colors.white70)),
      );
    }
    if (_loading && _items.isEmpty) {
      // 首次拉流可能较慢（要经镜像域名抓取），给出明确文案而不是干转圈，
      // 让用户知道在加载、以及为什么慢。
      //
      // 0.2.27：切源时进一步显示"正在切换到「XX」站源…（已等待 N 秒）"，
      // 并给出 2 分钟兜底提示，避免用户以为卡死（真机反馈第 5 条）。
      final target = _switchingTo;
      if (target == null) {
        return const LoadingHint(message: '正在为你挑选短剧…', dark: true);
      }
      final seconds = _switchElapsed;
      if (_switchTimedOut) {
        return _SwitchHint(
          message: '切换到「$target」已等待 ${seconds}s，仍无响应',
          detail: '可下点下方按钮重试，或先切回其他站源',
          actionLabel: '重新加载',
          onAction: () => _reset(force: true, switchTo: target),
        );
      }
      return _SwitchHint(
        message: '正在切换到「$target」站源…',
        detail: '已等待 ${seconds}s，网络较慢时可能要等一会儿',
      );
    }
    if (_items.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              _error ?? '暂无视频',
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white70),
            ),
            const SizedBox(height: 12),
            OutlinedButton(onPressed: () => _load(), child: const Text('重试')),
          ],
        ),
      );
    }
    final pageView = PageView.builder(
      controller: _controller,
      scrollDirection: Axis.vertical,
      onPageChanged: _onPageChanged,
      // 「连播本剧」开启时禁用 PageView 自带翻页，改由外层手势统一处理
      // （向上滑 = 下一集，向下滑 = 上一集）。
      //
      // 注意：这里的条件必须与下面 `onVerticalDragEnd` 是否接管**完全一致**，
      // 否则会出现"禁用了自带翻页、却没人接管手势"的死锁——表现为滑不动。
      //
      // 0.2.26 修正：原先用 `_currentPageCanPlayNext`（依赖子页异步上报
      // "是否有下一集"）作为条件，导致首帧未上报时条件与手势接管不一致，
      // 出现"第一部要下滑才切下集、第二部上滑却回上一部剧"的错乱。
      // 改为只看 `_autoNextEpisode`，进入连播模式即稳定接管，不再随上报抖动。
      physics: _autoNextEpisode
          ? const NeverScrollableScrollPhysics()
          : const PageScrollPhysics(),
      itemCount: _items.length,
      itemBuilder: (context, index) {
        final drama = _items[index];
        final isCurrent = index == _index;
        return _FeedPage(
          // 统一使用值 key。
          // 注意：这里**不能**按"是否当前页"切换成 GlobalKey——
          // GlobalKey 在同一树中唯一，来回换 key 会让 Flutter 把上一个
          // State（含播放器）整体搬移过去，造成"标题变了视频没变"。
          key: ValueKey('feed-${drama.source}-${drama.id}'),
          drama: drama,
          repository: widget.repository,
          store: widget.store,
          preloader: _preloader,
          manualPlayed: _manualPlayed,
          unlocked: _unlocked,
          autoEnter: index == _autoEnterIndex,
          active: widget.active && isCurrent,
          autoNextEpisode: _autoNextEpisode,
          playerFactory: widget.playerFactory,
          videoBuilder: widget.videoBuilder,
          onToggleAutoNext: _toggleAutoNext,
          onFinished: () => _jump(1, auto: true),
          onSwitchDrama: _jumpForSwipe,
          onOpenDetail: () => _openDetail(drama),
          onEpisodeStateChanged: isCurrent ? _onPageEpisodeStateChanged : null,
          // 单剧模式（0.2.29）：起始集 / 本地文件模式 / 续播位置。
          // 只在单剧模式（第一页）生效；首页无限流保持原行为。
          initialEpisodeIndex: widget.singleDrama != null
              ? widget.initialEpisodeIndex
              : 0,
          initialPosition: widget.singleDrama != null
              ? widget.initialPosition
              : 0,
          localOnly: widget.singleDrama != null && widget.localOnly,
          mediaId: widget.singleDrama != null ? widget.mediaId : null,
          singleDrama: widget.singleDrama != null,
          // 预载（0.2.31）：把"下一部剧"传给当前页，供"连播下一部"模式预载。
          // 只在首页无限流、且当前页有下一部时有效（单剧模式无下一部）。
          nextDrama:
              widget.singleDrama == null &&
                  isCurrent &&
                  index + 1 < _items.length
              ? _items[index + 1]
              : null,
          autoNextDramaEnabled: widget.singleDrama == null && !_autoNextEpisode,
          // 局域网推送接收（0.6.4）：只交给**单剧模式的第一页**
          // （推送必然是一台设备推一部剧过来，不存在"下一部"），
          // 且只给当前页，避免多页同时回报握手。
          handoff: widget.singleDrama != null && index == 0 && isCurrent
              ? widget.handoff
              : null,
        );
      },
    );
    // 手势层**必须始终存在**，只切换是否接管滑动。
    //
    // 历史教训（对应问题 2、3）：这里曾经写成
    //   if (!_currentPageCanPlayNext) return pageView;
    //   return GestureDetector(child: pageView);
    // 即"需要接管时才套一层 GestureDetector"。
    // 后果是：点「连播本剧」后树的**层数发生变化**，Flutter 认为这是另一棵树，
    // 于是把 PageView 及其下所有 _FeedPage 的 State（含播放器）**全部销毁重建**——
    // 表现为"重新开始加载视频、加载不成功、无法上下滑动"，
    // 同时 PageView 位置归零，表现为"跳回列表第一部"。
    // 正确做法：树形结构恒定，只改 physics 与是否响应手势。
    return RawGestureDetector(
      behavior: HitTestBehavior.translucent,
      // 只有「连播本剧」模式才接管手势（与上面 physics 条件保持一致）。
      //
      // 0.7.14（XQ-0123）：改用「跟手拖动 + 松手回弹/滑出」，手感与连播下一部一致。
      // 用 `RawGestureDetector` 而非 `GestureDetector` 的 onVerticalDrag*，是为了能设
      // `dragStartBehavior: DragStartBehavior.down`：起手前那段位移也要计入，
      // 否则 `start` 行为会把它丢掉，出现"拖了很远却不切集"。
      gestures: _autoNextEpisode
          ? <Type, GestureRecognizerFactory>{
              VerticalDragGestureRecognizer:
                  GestureRecognizerFactoryWithHandlers<
                    VerticalDragGestureRecognizer
                  >(
                    () => VerticalDragGestureRecognizer(),
                    (instance) => instance
                      ..dragStartBehavior = DragStartBehavior.down
                      ..gestureSettings = const DeviceGestureSettings(
                        touchSlop: 12,
                      )
                      ..onStart = _onSlideStart
                      ..onUpdate = _onSlideUpdate
                      ..onEnd = _onSlideEnd,
                  ),
            }
          : const <Type, GestureRecognizerFactory>{},
      child: Stack(
        // 必须 `expand`：默认的 `loose` 会让非定位子项（`pageView`）
        // 拿到"最小 0"的约束，`PageView` 可能塌缩成 0 高度而整页空白。
        fit: StackFit.expand,
        children: [
          // 0.7.11 修复（真机反馈"横屏视频非全屏时左右滑仍会上下翻"）：
          // 提高 `PageView` 的翻页触摸阈值（默认 18 → 60），给方向判定留足缓冲。
          // 真实手指"左右滑"往往先有十几像素的竖直位移，默认阈值下纵向
          // 拖动识别器会**先**赢下竞技场，页面就开始跟手翻——
          // 页内的水平识别器（阈值 6）再赢也没用。抬高后水平手势总是先到，
          // 纯竖直滑动（位移远超 60）仍照常翻页。
          // 0.7.14（XQ-0123）：整页跟着手指上下位移，滑出后切集。
          // 用 `ValueListenableBuilder` 只重建这一层，避免每帧重建整页。
          ValueListenableBuilder<double>(
            valueListenable: _slideOffset,
            builder: (context, offset, child) => Transform.translate(
              offset: Offset(0, offset),
              child: child,
            ),
            child: MediaQuery(
              data: MediaQuery.of(context).copyWith(
                gestureSettings: const DeviceGestureSettings(touchSlop: 60),
              ),
              child: pageView,
            ),
          ),
          // 顶部禁滑条（0.6.7，用户要求）。
          //
          // 为什么需要它：`PageView` **不支持"只禁用局部区域"的滑动**，
          // 而非连播模式下翻页完全由 `PageView` 自己处理，
          // 外层 `onVerticalDragEnd` 拿不到这次滑动。
          // 因此在顶部盖一条**只吃竖向拖拽**的透明层：
          // - 竖向拖拽：本层赢下手势竞争 → `PageView` 不翻页；
          // - 单击 / 双击：本层不参与，`HitTestBehavior.translucent`
          //   让事件继续传给下方（单击显隐控件、双击暂停照常）；
          // - 顶部右上角的推送按钮、左上角集数标签同样不受影响。
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            height: _topGestureGuard,
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onVerticalDragStart: (_) {},
              onVerticalDragUpdate: (_) {},
              onVerticalDragEnd: (_) {},
              child: const SizedBox.expand(),
            ),
          ),
        ],
      ),
    );
  }

  /// 切换「连播本剧」开关。
  void _toggleAutoNext() {
    if (_closed) return;
    setState(() => _autoNextEpisode = !_autoNextEpisode);
  }

  Future<void> _openDetail(Drama drama) async {
    if (!mounted) return;
    // 0.6.5 修复（用户反馈"点进详情页后视频仍在播放，有声音，应该在后台放"）：
    // 进详情页前**必须暂停播放**。
    //
    // 首页 `home_screen.dart` 的 `_openDrama` 一直有 `_pauseCatalog()`，
    // 但本页（新播放器）的 `_openDetail` 从加进来起就**没有暂停**，
    // 于是从竖滑流点剧名进详情页时，视频继续播、声音继续出。
    //
    // 实现说明：播放器实例属于**当前子页**（`_FeedPageState`），
    // 外层拿不到；因此暂停动作由子页在点剧名时先做（见 `_FeedPage` 的
    // `onTap` 处理），这里只负责导航。
    //
    // 按用户确认：**返回后不自动恢复**（想继续看，点一下即可），
    // 与首页"进详情页即停"的行为保持一致。
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => DetailScreen(
          drama: drama,
          repository: widget.repository,
          store: widget.store,
        ),
      ),
    );
  }
}

/// 站源切换加载提示（0.2.27 新增）。
///
/// 与通用 `LoadingHint` 的区别：带上站源名、已等待秒数，
/// 并在超时后提供「重新加载」按钮，避免用户以为卡死。
class _SwitchHint extends StatelessWidget {
  const _SwitchHint({
    required this.message,
    required this.detail,
    this.actionLabel,
    this.onAction,
  });

  final String message;
  final String detail;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(
              width: 26,
              height: 26,
              child: CircularProgressIndicator(
                strokeWidth: 2.5,
                color: Colors.white70,
              ),
            ),
            const SizedBox(height: 16),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 15,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              detail,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white70, fontSize: 13),
            ),
            if (actionLabel != null && onAction != null) ...[
              const SizedBox(height: 16),
              OutlinedButton(onPressed: onAction, child: Text(actionLabel!)),
            ],
          ],
        ),
      ),
    );
  }
}

class _FeedBatch {
  const _FeedBatch(this.items, {this.hasMore = false, this.warning = ''});
  final List<Drama> items;
  final bool hasMore;
  final String warning;
}

/// 单个站源拉取失败的占位结果。
///
/// 并行请求时 `Future.wait` 只要有一个抛异常就会整体失败，
/// 因此把「失败」也当成一种正常返回值，让其他源的数据仍能显示。
class _SourceFeedFailure {
  const _SourceFeedFailure(this.message);
  final String message;
}

/// 子页向父级上报播放状态的签名。
///
/// [hasNext]：本页是否还有下一集（决定滑动是"切集"还是"翻下一部"）。
/// [playNext]：切到下一集的执行入口；没有下一集时为 null。
/// [hasPrev]：本页是否还有上一集（决定向上滑是"回上一集"还是"翻上一部"）。
/// [playPrev]：切到上一集的执行入口；没有上一集时为 null。
///
/// 之所以用回调而不是 GlobalKey：GlobalKey 在同一 Widget 树中必须唯一，
/// 若随"当前页"来回更换，Flutter 会搬移 State（含播放器）导致画面错乱。
typedef EpisodeStateReporter =
    void Function(
      bool hasNext, {
      Future<void> Function()? playNext,
      bool hasPrev,
      Future<void> Function()? playPrev,
    });

/// 单页：一个视频 + 播放控件 + 信息栏。
class _FeedPage extends StatefulWidget {
  const _FeedPage({
    super.key,
    required this.drama,
    required this.repository,
    required this.store,
    required this.preloader,
    required this.manualPlayed,
    required this.unlocked,
    this.autoEnter = false,
    required this.active,
    required this.autoNextEpisode,
    required this.onToggleAutoNext,
    required this.onFinished,
    this.onSwitchDrama,
    required this.onOpenDetail,
    this.playerFactory,
    this.onEpisodeStateChanged,
    this.videoBuilder,
    this.initialEpisodeIndex = 0,
    this.initialPosition = 0,
    this.localOnly = false,
    this.mediaId,
    this.singleDrama = false,
    this.nextDrama,
    this.autoNextDramaEnabled = false,
    this.handoff,
  });

  final Drama drama;

  /// 上报"本页还能否切到下一集"，并附上切集入口，用于父级决定滑动语义。
  final EpisodeStateReporter? onEpisodeStateChanged;
  final AppRepository repository;
  final LocalStore store;

  /// 全流共享的预载器（0.6.9）。
  ///
  /// **为什么必须共享**：此前每页各持一个预载器，而"连播下一部"预载的是
  /// **下一部剧**——结果存在本页自己的预载器里；滑到下一部时那是另一个
  /// 页面、用的是另一个空预载器，取不到；同时本页被滑走时又会 clear+release。
  /// 实测（探针）：预载 `甲剧1` 后滑过去，紧接着 `release(甲剧1)` 又
  /// `resolve(甲剧1)` —— 预载**白做还被释放**，用户感觉"完全没有预加载"。
  /// 改为由父级创建并传入后，预载结果可跨页复用。
  final PlaybackPreloader preloader;

  /// 本次会话是否手动点过播放（0.7.3，`XQ-0107`，由父级持有、跨页共享）。
  final ValueNotifier<bool> manualPlayed;

  /// 本次会话是否已越过第一个视频（0.7.12，`XQ-0119`，由父级持有）。
  final ValueNotifier<bool> unlocked;

  /// 本页是否由「自动连播」切进来（0.7.4）。
  ///
  /// true 时本页一开始就静默（不弹控件），直到用户操作或起播后恢复常态。
  final bool autoEnter;

  final bool active;

  /// true = 播完自动播本剧下一集；false = 播完跳到下一部。
  final bool autoNextEpisode;
  final VoidCallback onToggleAutoNext;

  /// 当前剧播完且不需要连播本剧时回调（由父级滑到下一部）。
  final VoidCallback onFinished;

  /// 竖滑切上一部/下一部（0.7.5，`XQ-0108`）。
  ///
  /// 未开「连播本剧」时，全屏上下滑应切**剧**而不是切集；
  /// 返回值表示是否真的切了（false = 已到边界，交给界面提示）。
  final bool Function(int delta)? onSwitchDrama;
  final VoidCallback onOpenDetail;

  /// 测试用：注入假播放器。
  final Player Function()? playerFactory;

  /// 测试用：替换视频渲染层（见 [VerticalFeedScreen.videoBuilder]）。
  final Widget Function(Widget controls)? videoBuilder;

  /// 单剧模式（0.2.29）：起始集索引。
  final int initialEpisodeIndex;

  /// 单剧模式（0.2.29）：起始播放位置（秒），用于续播。
  final double initialPosition;

  /// 单剧模式（0.2.29）：true 时播放已下载的本地文件。
  final bool localOnly;

  /// 本地媒体 ID（0.6.0）：非空时进度写入 `store.saveMediaWatch`。
  final String? mediaId;

  /// 单剧模式（0.2.29）：true 时隐藏"连播本剧"开关（只有一部剧，无意义）。
  final bool singleDrama;

  /// 预载（0.2.31）：下一部剧（由父级传入，仅首页无限流有值）。
  /// "连播下一部"模式下用它预载下一部的第 1 集。
  final Drama? nextDrama;

  /// 预载（0.2.31）：当前是否处于"连播下一部"模式。
  /// true 时预载 [nextDrama] 第 1 集，false 时预载本剧下一集。
  final bool autoNextDramaEnabled;

  /// 局域网推送**接收播放**（0.6.4 从老播放器迁移）。
  ///
  /// 非空表示本页是被"另一台设备推送过来"的播放请求打开的，
  /// 需要按 [LanIncomingPlayback] 的握手协议回报状态。
  /// 只有单剧模式的当前页会拿到它（见 `_body()` 的传参）。
  final LanIncomingPlayback? handoff;

  @override
  State<_FeedPage> createState() => _FeedPageState();
}

class _FeedPageState extends State<_FeedPage> with WidgetsBindingObserver {
  Player? _player;
  VideoController? _video;
  PlayerInteractions? _interactions;
  final _subscriptions = <StreamSubscription<dynamic>>[];
  DramaDetail? _detail;
  PlaybackPlan? _plan;
  String? _error;
  bool _loading = true;
  bool _ready = false;
  bool _panelOpen = false;
  bool _controlsVisible = true;

  /// 窗口亮度下限（0.7.8，`XQ-0114`）：避免滑到全黑看不见。
  static const double _minBrightness = .05;

  /// 当前窗口亮度比例（0.7.8）。窗口亮度**覆盖**系统亮度，
  /// 因此系统调暗时 App 内仍可调亮（上限是屏幕硬件最亮）。
  double _screenBrightnessRatio = .5;

  /// 「自动连播切到了下一集」进行中（0.7.2，`XQ-0104`）。
  ///
  /// 自动切集时**不弹整套控件**（用户：每集都弹进度条很碍事），
  /// 只保留中央的加载提示；任何用户操作都会立刻解除该状态、恢复常态。
  bool _autoAdvancing = false;

  int _generation = 0;
  int _episodeIndex = 0;
  int _quality = 0;
  double _speed = 1;
  double? _seekValue;
  Timer? _hideTimer;
  bool _closed = false;

  /// 当前剧是否已追剧（0.2.26 新增）。
  ///
  /// 与 `store.isFavorite` 同步；在 initState / didUpdateWidget / 点击后刷新。
  bool _followed = false;

  /// 局域网推送（0.6.4 从老播放器迁移）。
  ///
  /// `_lanIdentity`：本页在 LanController 中的身份标记，
  /// 用于 `attachPlayback` / `detachPlayback` 配对
  /// （`detachPlayback` 只认同一 identity，避免误清掉别的页面的注册）。
  Object _lanIdentity = Object();

  /// 是否仍由本页持有 handoff（用户一操作播放就置 false，
  /// 表示"接收端已接手"，此后不再代发送端停止）。
  bool _handoffOwned = true;

  /// 首次成功播放后的位置，用于判定"真的播起来了"再回报 acknowledge。
  double? _lanFirstPosition;

  /// 记录已回报失败，避免重复 `fail`（协议里 started 只能完成一次）。
  bool _handoffFailed = false;

  /// 预载器（0.2.31 新增，用户要求）。
  ///
  /// 复用旧播放器同一套 `PlaybackPreloader`（JC-0002：不重复造轮子）。
  /// 两种模式：
  /// - 「连播本剧」→ 预载本剧下一集；
  /// - 「连播下一部」→ 预载下一部剧的第 1 集（需父级传入 `nextDrama`）。
  /// 默认常开（用户 Q3：不加开关，不提供关闭入口）。
  ///
  /// 0.6.9：改为**父级创建并传入**（全流共享），不再本页自建。
  /// 本页只借用，**不负责 dispose**（生命周期归父级）。
  PlaybackPreloader get _preloader => widget.preloader;

  /// 观看记录保存定时器。
  ///
  /// 旧播放器（`player_screen.dart`）用 5 秒定时 + 暂停/退出时强制保存，
  /// 让首页竖滑流播放的剧也能进入「最近观看」。这里沿用同一策略，
  /// 保证两套播放器的观看记录行为一致。
  Timer? _saveTimer;

  /// 上一次已保存的进度指纹，用于去重，避免频繁写盘。
  String? _savedProgressKey;

  /// 观看记录保存失败提示（与旧播放器一致的容错）。
  String? _saveWarning;

  /// 播放健康检查（0.6.0，迁移自老播放器 `player_screen.dart`）。
  ///
  /// 老播放器每秒检测一次"是否卡住"（位置 20 秒不前进且处于播放中），
  /// 卡住则自动恢复（切备用线路 / 重新解析地址）。
  /// 新播放器此前**完全没有**这个能力，网络抖动时会一直黑屏等下去，
  /// 用户只能手动切集绕过。这里补齐同一套能力。
  final _health = PlaybackHealth();

  /// 健康检查定时器（每秒一次）。
  Timer? _healthTimer;

  /// 自动恢复尝试计数与"是否已刷新过地址"（与老播放器同一套策略）。
  final _recovery = PlaybackRecovery();

  /// 是否在等"第一帧真正开始播放"（0.6.9）。
  ///
  /// **根因修复（用户反馈"切下一集/下一部时很大概率黑屏、没有任何反应，
  /// 需要上下重新滑动一下才能正常播放"）**：
  ///
  /// 原先 `_prepare()` 在 `_openMedia()`（即 `player.open()`）**返回后**
  /// 立刻 `_loading = false`。但 `open()` 返回只代表"地址已交给播放器"，
  /// **不代表已经起播**——弱网下（尤其挂 VPN）服务端可能迟迟不给数据，
  /// 此时：加载提示已被撤掉、又没有任何错误 → **画面纯黑、无任何反馈**。
  ///
  /// 更糟的是健康检查要求 `playing == true` 才判定卡住，
  /// "从未起播"永远不满足条件 → **永远不会自动恢复**，
  /// 用户只能靠"再滑一次"手动绕过（与真机描述完全一致）。
  ///
  /// 现在：保留加载提示直到真正起播；超过阈值仍不起播则自动恢复一次。
  bool _awaitingFirstFrame = false;

  /// 上次竖向滑切集的时间（0.7.14，用于两入口去重）。
  DateTime _lastSwipeCommit = DateTime(2000);

  /// 本集是否已经"出过画面"（0.7.13，修复"连播后加载提示常显"）。
  ///
  /// 真机反馈：连播之后「正在加载视频…」一直挂着，直到控件一起隐藏，
  /// 但视频其实早就正常播放了。原因是 0.7.7 把提示条件里的 `!playing`
  /// 去掉了，只看 `width <= 0`——而部分流（尤其 m3u8）**始终不报宽高**，
  /// 于是条件恒真。这里改为"是否出过画面"的显式判定。
  bool _hasVideoFrame = false;

  /// 起播后位置流推进的轮次（用于兜底认定"画面已出"）。
  int _frameTicks = 0;

  /// 已等待"第一帧"的健康检查轮次（每秒 +1）。
  ///
  /// 用**轮次计数**而不是墙上时钟：既便于测试（可推进假时钟验证），
  /// 也不受设备休眠 / 系统时间被调整的影响。
  int _firstFrameTicks = 0;

  /// 迟迟不起播的容忍轮次（约 15 秒，超过即自动恢复一次）。
  static const _firstFrameTicksLimit = 15;

  /// 用户是否**主动暂停**（0.6.11 新增）。
  ///
  /// 存在原因：健康检查需要区分两种 `playing == false`：
  /// - **用户主动暂停** → 必须保持暂停，绝不能自动恢复；
  /// - **播放中断**（起播后卡住 / 缓冲耗尽 / 解码停顿）→ 应当自动恢复。
  ///
  /// 只有记录了这个标记，才能在"跑不动"的兜底里安全地区分两者。
  /// 置位：`_togglePlayback` 暂停时；清除：恢复播放、重新加载、切集时。
  bool _userPaused = false;

  /// 起播后又掉回停止态的连续轮次（0.6.11 新增，用于第三条兜底）。
  int _stalledTicks = 0;

  /// 起播后停住的容忍轮次（约 10 秒）。
  static const _stalledTicksLimit = 10;

  /// 加载态卡死的轮次（0.7.7，约 25 秒）——弱网下 `open()` 不返回时兜底。
  int _loadTicks = 0;
  static const _loadTicksLimit = 25;

  /// 报告在播但拿不到画面尺寸的连续轮次（0.7.7，约 12 秒）。
  int _noFrameTicks = 0;
  static const _noFrameTicksLimit = 12;

  /// 应用是否在前台。后台时不判定"卡住"，否则会被误判。
  bool _foreground = true;

  /// 横屏/全屏模式：用独立的全屏层铺满整个屏幕（含状态栏区域），
  /// 并隐藏竖滑流的所有非播放界面（AppBar、剧名、简介、底栏等）。
  /// 注意：这里不是"把系统屏幕转一下"，而是真正进入全屏观看。
  bool _landscape = false;

  /// 全屏层是否已作为**路由**打开（0.2.28 方案 D）。
  ///
  /// 0.2.27 及之前用 `Overlay.insert(OverlayEntry)` 实现全屏层，
  /// 但 `OverlayEntry` **不属于任何 Navigator 路由**，其中的 `PopScope`
  /// 收不到系统返回键事件 → 真机表现为"全屏按返回直接回桌面"（修复无效）。
  ///
  /// 0.2.28 改为 `Navigator.push` 一个透明全屏路由：
  /// 它位于 Navigator 路由栈中，`PopScope` 能正常拦截返回键，
  /// 实现"返回键 / 右上角按钮 / 手势"三种方式都能退出全屏。
  bool _fullscreenRouteOpen = false;

  /// 打开全屏路由所用的 Navigator 引用。
  ///
  /// 进入全屏时保存，便于 `dispose` 中安全关闭路由
  /// （dispose 阶段 `context` 已失效，不能再用 `Navigator.maybeOf(context)`）。
  NavigatorState? _fullscreenNavigator;

  /// 全屏层的重建入口（路由内内容通过它同步最新状态）。
  final _fullscreenRevision = ValueNotifier<int>(0);

  /// 竖屏主界面进度条的轻量重建入口（0.3.1）。
  ///
  /// 进度每秒变化多次，若整页 `setState` 会把整个手势层 + 按钮 + 选集网格
  /// 全部重建，代价很高。改用这个 `ValueNotifier` 只让进度条本身重建。
  final _tick = ValueNotifier<int>(0);

  /// 上次刷新全屏层的时间，用于节流（0.3.1）。
  DateTime _lastFullscreenRefresh = DateTime.fromMillisecondsSinceEpoch(0);

  /// 播放器操作串行队列（0.3.1 性能修复）。
  ///
  /// 与旧播放器 `player_screen.dart` 的 `_serialize` 语义一致：
  /// `player.open` / `setRate` / `setProperty` 等原生调用若并发执行，
  /// 会在 media_kit 内部互相打断（表现为卡顿、音画不同步、切集闪回）。
  /// 全部排进同一条 Future 链，保证同一时刻只有一个原生操作在跑。
  Future<void> _operations = Future<void>.value();

  /// 视频宽高比（宽/高）。0 表示尚未探测到。
  /// 只有横屏视频（宽>高）才显示「横屏」切换按钮，竖屏视频本身就不需要。
  double _aspectRatio = 0;

  /// 是否为横屏视频（16:9 之类）。宽高比未探到时按竖屏处理（不显示按钮）。
  bool get _wideVideo => _aspectRatio > 1.05;

  /// 首次打开时的续播位置（秒），用一次后清空（0.2.29）。
  ///
  /// 只有在单剧模式、且调用方传入了非零位置时才有值。
  /// 消费一次即置空，避免换集 / 重试时反复跳到同一位置。
  double _pendingStart = 0;

  /// 是否已套用过观看记录（0.6.6，只套用一次）。
  ///
  /// 见 [_applyHistoryOnce]：随机流刷到看过的剧时，从历史进度续播。
  bool _historyApplied = false;

  /// 滑走时记下的播放位置，滑回来重建播放器时据此续播（0.3.1）。
  ///
  /// 因为滑走的页面现在会**释放播放器**，重建时若不带上位置就会从头播。
  Duration _resumeFrom = Duration.zero;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final preferences = widget.store.playbackPreferences;
    _speed = preferences.speed;
    _quality = preferences.quality;
    // 单剧模式（0.2.29）：从指定集开始播放（详情页/下载页点的是第几集）。
    _episodeIndex = widget.initialEpisodeIndex;
    _pendingStart = widget.initialPosition;
    // 追剧按钮初始状态（0.2.26 新增）。
    _followed = widget.store.isFavorite(widget.drama.id);
    // 局域网推送（0.6.4）：接管 handoff，并挂上"发送端要求停止"的回调。
    //
    // `consumed` 必须在**开始加载前**就置位，否则发送端可能在本端
    // 还没接管时就把这次推送判为失败。
    final handoff = widget.handoff;
    if (handoff != null) {
      handoff.consumed = true;
      handoff.stop = () async {
        if (_handoffOwned && !_closed) await _stopForLan();
      };
      // 用户已切换 / 已被取消：直接回报失败，不进入加载。
      if (handoff.cancelled) {
        _failHandoff('接收用户已变更，推送已取消');
      }
    }
    // 0.7.4：自动连播切进来的页面一开始就静默（不弹控件）。
    _autoAdvancing = widget.autoEnter;
    // 0.7.6：提前读一次系统媒体音量，避免第一次调音量时起点是 0。
    unawaited(_syncSystemVolume());
    unawaited(_syncScreenBrightness());
    if (widget.active) _prepare();
  }

  /// 播放器操作串行队列（0.3.1）。
  ///
  /// 把操作挂到同一条 Future 链上，前一个失败也不影响后续执行
  /// （`catchError` 吞掉异常，与旧播放器 `player_screen.dart` 一致）。
  ///
  /// 0.3.5 修正：如果播放器已被释放，队列里还没执行的操作直接作废。
  /// 原因是"滑走页面即释放播放器"（0.3.1 性能修复）与"换集加载"会撞车：
  /// 已经排队的 `player.open()` 手里拿的是**已被释放的播放器**，
  /// 而 media_kit 对已释放实例调用 `open` 走的是 `assert`
  /// （release 包中断言被移除），于是既不报错也不播放，
  /// 真机表现为**全黑、无声、也没有加载提示**。
  Future<void> _serialize(Future<void> Function() operation) {
    final released = _playerReleased;
    Future<void> run() async {
      if (_closed || _playerReleased != released) return;
      await operation();
    }

    final next = _operations.catchError((Object _) {}).then((_) => run());
    _operations = next;
    return next;
  }

  /// 是否已进入"释放播放器"流程（页面被滑走或销毁）。
  ///
  /// 与 [_closed] 的区别：[_closed] 只在 `dispose` 时置位，
  /// 而本标记在 `didUpdateWidget` 被滑走时就置位，
  /// 用于阻止已滑走的页面继续加载、也就不会在已释放实例上操作。
  bool _playerReleased = false;

  /// 判断某次异步加载是否仍然有效：页面未销毁、播放器未被释放，
  /// 且捕获到的播放器实例仍是当前实例。
  ///
  /// ⚠️ 0.3.5 事故教训：**绝不要把"加载任务代次"（[_generation]）与播放器状态混在一起判断**。
  /// 0.3.5 首次实现里它和另一个"播放器代次"计数器做了相等比较，
  /// 两个计数器互不相关（首次加载 1 != 0），于是**每一次加载都被误判为过期**、
  /// 静默返回且不置 `_loading`，导致所有视频永久卡在"正在加载视频…"。
  bool _attemptAlive(Player player) =>
      !_closed && !_playerReleased && identical(_player, player);

  /// 给"曾被滑走"的页面一次自愈机会：重新创建播放器后再加载。
  ///
  /// 不做这一步的话，页面被滑走时放弃的加载会永久停住，
  /// 用户只能靠"切到别的集再切回来"绕过（0.3.5 前的真机现象）。
  Future<void> _resumeAfterRelease() async {
    if (_closed || !_playerReleased) return;
    _playerReleased = false;
    _ready = false;
    await _prepare(force: true);
  }

  /// 自动恢复（0.6.0，迁移自老播放器）。
  ///
  /// 触发条件：健康检查判定"播放中但位置长时间不前进"。
  /// 策略与老播放器一致（`PlaybackRecovery`）：
  /// 1. 有计划且有备用线路 → 切备用线路；
  /// 2. 否则首次 → 重新解析播放地址（刷新）；
  /// 3. 累计超过 3 次 → 停止，展示错误让用户手动重试。
  ///
  /// 恢复后从**当前进度**续播，不让用户回到片头。
  Future<void> _recover() async {
    final current = _plan;
    if (_closed ||
        _playerReleased ||
        !widget.active ||
        !_foreground ||
        current == null ||
        _error != null) {
      return;
    }
    final position = _player?.state.position ?? Duration.zero;
    // 本地文件没有备用线路可切，直接停止，避免无意义地反复重试。
    final action = current.local
        ? PlaybackRecoveryAction.stop
        : _recovery.next(current);
    if (action == PlaybackRecoveryAction.stop) {
      if (!mounted || _closed) return;
      setState(() {
        // 0.6.9：放弃恢复时必须撤掉"等待第一帧"，否则加载提示会盖住错误与重试按钮。
        _awaitingFirstFrame = false;
        _firstFrameTicks = 0;
        _error = current.local
            ? '本地视频播放中断，请返回重试。'
            : '播放已中断，请点击重试。';
      });
      _refreshFullscreen(immediate: true);
      return;
    }
    // 记录续播点，`_prepare` 会通过 `_takeStartPosition` 取用。
    _resumeFrom = position;
    _health.reset();
    final message = switch (action) {
      PlaybackRecoveryAction.alternative => '正在切换备用线路',
      PlaybackRecoveryAction.refresh => '正在重新获取播放地址',
      PlaybackRecoveryAction.stop => '',
    };
    if (mounted && !_closed && message.isNotEmpty) _toast(message);
    await _prepare(force: true);
  }

  /// 应用前后台切换（0.6.0）。
  ///
  /// 后台时不判定"卡住"（`_health.reset()`），否则回到前台会被误判为卡死并触发恢复。
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    _health.reset();
  }

  /// 取出并清空待续播位置（只在首次打开时返回非零值）。
  ///
  /// 首次加载时套用观看记录（0.6.6）。
  ///
  /// 背景（用户反馈"已看的不回退了，但**观看进度被重置**"）：
  /// 随机流此前**完全不读观看记录**——`initialPosition` 只在单剧模式由调用方传入，
  /// 首页随机流恒为 0。于是每次刷到看过的剧都从**第 1 集第 0 秒**开始播，
  /// 随后 `_saveProgress` 又把 0 写回记录 → **进度被清零**。
  ///
  /// 用户要求："刷到了就**直接从历史进度播放**"。
  ///
  /// 只套用一次（[_historyApplied]），且只用于"从随机流刷到"的场景：
  /// - 单剧模式：调用方已明确指定集号与位置，不覆盖；
  /// - 本地媒体：进度存在**独立的** `mediaWatched`，不走普通观看记录；
  /// - 已有显式续播点（`_pendingStart` / `_resumeFrom`）：优先用显式值。
  void _applyHistoryOnce(DramaDetail detail) {
    if (_historyApplied) return;
    _historyApplied = true;
    // 注意：本类的 `singleDrama` 是 **bool**（外层 `VerticalFeedScreen` 才是 `Drama?`）。
    // 曾误写 `widget.singleDrama != null` —— bool 恒不等于 null，
    // 于是本方法**被无条件跳过**、续播完全失效（且 analyze 不会报错）。
    if (widget.singleDrama || widget.mediaId != null) return;
    if (_pendingStart > 0 || _resumeFrom > Duration.zero) return;
    final watch = widget.store.watched(detail.drama.id);
    if (watch == null) return;
    _episodeIndex = resumeEpisodeIndex(
      detail.episodes,
      watch,
    ).clamp(0, detail.episodes.length - 1);
    // 位置只在"记录集号 == 落到的集号"、且**该集还没播完**时沿用。
    //
    // 两种情况不沿用（都从头播）：
    // 1. 集号对不上（如已看完落到最后一集）——避免打开就跳到该集结尾；
    // 2. **该集已播完**（`watch.finished`）——同理，若沿用结尾位置，
    //    一打开就等于"已播完"，会立刻触发 `completed` 而**闪跳下一部**。
    //    这条正是"已看完的剧被刷到"时最容易踩的坑（探针实测确认）。
    if (detail.episodes[_episodeIndex].number == watch.episode &&
        !watch.finished) {
      _pendingStart = watch.position;
    }
  }

  /// 优先取 [ _resumeFrom ]（滑走再滑回时记录的位置，0.3.1），
  /// 其次取 [ _pendingStart ]（单剧模式调用方传入的续播位置，0.2.29）。
  Duration? _takeStartPosition() {
    final resume = _resumeFrom;
    _resumeFrom = Duration.zero;
    if (resume > Duration.zero) return resume;
    final seconds = _pendingStart;
    _pendingStart = 0;
    if (seconds <= 0) return null;
    return Duration(milliseconds: (seconds * 1000).round());
  }

  /// 取本地已下载文件（0.2.29，下载页单剧模式）。
  ///
  /// 与旧播放器 `PlaybackLoader(localOnly: true)` 语义一致：
  /// 找不到本地文件时抛 `AppFailure`，由调用方展示错误与重试。
  Future<PlaybackPlan> _resolveLocal(DramaDetail detail, int index) async {
    final plan = await widget.repository.localPlayback(
      detail.drama,
      detail.episodes[index],
    );
    if (plan == null || !plan.local) {
      throw AppFailure('本地视频不可用，请重新下载。', code: 'local_media');
    }
    return plan;
  }

  /// 同步预载目标（0.2.31，用户要求：默认常开，两种模式）。
  ///
  /// 触发条件（与旧播放器一致的时机策略）：
  /// - 当前页可见、已就绪、正在播放且缓冲充足；
  /// - 播放位置达 25% 或距结束不足 2 分钟（0.6.9 提前，原为"过半或不足 45 秒"）。
  ///
  /// 预载目标：
  /// - 「连播本剧」→ 本剧下一集；
  /// - 「连播下一部」→ 下一部剧的第 1 集（需父级传入 `nextDrama`）。
  ///
  /// 不预载的情况：本地文件模式、单剧模式、加载中/出错、当前不在播放。
  void _syncPreload() {
    if (_closed) return;
    // 0.7.3（XQ-0107）：移动网络下不自动播放时也不预加载，避免后台跑流量。
    if (_autoPlayBlocked) {
      _preloader.pause();
      return;
    }
    // 本地文件不预载（无网络解析成本）。
    // 0.6.9：**不 clear** 共享预载器（它可能正持有别的页面要用的结果）。
    if (widget.localOnly) return;
    // 0.6.9：**非当前页不碰共享预载器**。
    //
    // 预载器现在由全流共享，本页预载的很可能正是**下一页要播的内容**。
    // 若这里对非当前页执行 `clear()`，就会把下一页马上要用的预载结果
    // 当场清掉（表现为"滑过去仍要现加载"）。因此非当前页直接返回，
    // 既不预载也不清理，交由当前页与预载器自身的身份校验去管理。
    if (!widget.active) return;
    final player = _player;
    final detail = _detail;
    if (player == null ||
        detail == null ||
        !_ready ||
        _loading ||
        _error != null) {
      // 0.6.9：这里**不能 clear**。
      //
      // 本页刚成为当前页、正处于 `_loading` 时，`_prepare()` 马上要调用
      // `_preloader.take()` 取走上一页预载好的结果；若此处先 clear，
      // 就会把马上要用的预载**当场清掉**（竞态），预载依然白做。
      // 过期结果由 `take()` / `prepare()` 的身份与有效期校验自行清理。
      return;
    }
    final state = player.state;
    if (!state.playing || state.buffering) {
      _preloader.pause();
      return;
    }
    final duration = state.duration.inMilliseconds;
    final position = state.position.inMilliseconds;
    // 0.7.13 调整（用户反馈"下一个视频还要等 10 多秒"）。
    //
    // 历史：0.5.0 要求"播放过半或距结束 45 秒"；0.6.9 提前到
    // "已看 25% 或距结束 2 分钟"。但用户实测仍然要等：
    //   - 单集 3 分钟以上的剧，25% 意味着要看到 45 秒后才开始预载；
    //   - 用户常常看到十几秒就滑走，等于**从未预载**。
    //
    // 现在改为**开播满 3 秒即预载**：短剧一集才几十秒，早一点准备才可能来得及。
    // 代价是每集多一次预取（原生侧上限 4MB），Wi-Fi 下可接受；
    // 移动网络下未点播时 `_autoPlayBlocked` 会拦在前面，不会偷跑流量。
    if (duration <= 0 || position < 3000) {
      return;
    }
    // 弱网保护（0.5.0，0.6.9 放宽阈值）。
    //
    // 背景：用户实测"开 VPN 就卡"。视频请求经系统代理绕道节点
    // （见 `native/core/proxy_system.go`），带宽与稳定性都不如直连。
    // 原阈值 30 秒过于保守：**用户长期挂 VPN 时缓冲余量经常不到 30 秒**，
    // 于是预载被永久暂停 —— 这正是"感觉完全没有预加载"的主因之一
    // （用户已确认"平时开着 VPN 用"）。
    //
    // 现在放宽到 8 秒：只在缓冲**真的快见底**时才让路给当前播放，
    // 正常挂 VPN 也能启动预载。
    final buffered = state.buffer.inMilliseconds;
    if (buffered > 0 && buffered < 8000) {
      _preloader.pause();
      return;
    }
    // 「连播本剧」优先：还有下一集就预载下一集。
    if (widget.autoNextEpisode || !widget.autoNextDramaEnabled) {
      if (_episodeIndex + 1 < detail.episodes.length) {
        _preloader.prepare(
          detail.drama,
          detail.episodes[_episodeIndex + 1],
          quality: _quality,
        );
        return;
      }
    }
    // 「连播下一部」：预载下一部剧的第 1 集。
    final next = widget.nextDrama;
    if (next != null) {
      unawaited(_preloadNextDrama(next));
      return;
    }
    _preloader.clear();
  }

  /// 预载下一部剧的第 1 集（需要先拿到其剧集列表）。
  Future<void> _preloadNextDrama(Drama next) async {
    try {
      final detail = await widget.repository.detail(next);
      // 0.6.9：取详情期间页面可能已被滑走。此时**不要**再写入共享预载器，
      // 否则会用旧页面的目标覆盖掉新页面正在准备的预载。
      if (_closed || !widget.active || detail.episodes.isEmpty) return;
      _preloader.prepare(
        detail.drama,
        detail.episodes.first,
        quality: _quality,
      );
    } catch (_) {
      // 预载失败不影响主流程（切过去时会重新解析）。
    }
  }

  /// 只为当前页创建播放器，避免同时持有多个实例。
  bool _ensurePlayer() {
    if (_player != null) return true;
    // 0.3.5：只有当页面**当前可见**、且没有处于"已释放等待重建"状态时才建。
    // `_playerReleased` 由 `_releasePlayer` 置位；页面重新可见时
    // `didUpdateWidget` 会先调用 `_resumeAfterRelease()` 把它清掉再加载，
    // 这样"滑走时放弃的加载"不会永久停住。
    if (!widget.active || _closed || _playerReleased) return false;
    final player =
        widget.playerFactory?.call() ??
        Player(
          configuration: const PlayerConfiguration(
            bufferSize: 32 * 1024 * 1024,
          ),
        );
    _player = player;
    // 测试环境注入视频层时不去创建 VideoController：
    // 它会调用原生 platform channel，在测试里必然失败并污染用例结果。
    _video = widget.videoBuilder == null ? VideoController(player) : null;
    final interactions = PlayerInteractions(
      player: player,
      available: () =>
          !_closed &&
          !_loading &&
          _error == null &&
          widget.active &&
          !_panelOpen,
      baseSpeed: () => _speed,
      onTogglePlayback: _togglePlayback,
      onFullscreen: () {},
      // 上下滑动切集（0.2.31，用户方案 B：只切集、不切剧）。
      //
      // 说明：这里原先返回空字符串，等于「上下滑切集」从未接通。
      // 竖滑主界面靠外层 PageView 切集，全屏是独立路由、不受 PageView 影响，
      // 因此全屏里上下滑必须由本回调承担（用户反馈第 1 条）。
      // [direction] 1 = 上滑（下一集），-1 = 下滑（上一集）。
      onEpisode: _swipeEpisode,
      onSeek: _seekTo,
    )..addListener(_interactionChanged);
    _interactions = interactions;
    // 观看记录：定时保存（5 秒一次，与旧播放器一致）。
    // 暂停、切集、切页、退出时另有强制保存，保证进度不丢。
    _saveTimer?.cancel();
    _saveTimer = Timer.periodic(
      const Duration(seconds: 5),
      (_) => unawaited(_saveProgress()),
    );
    // 健康检查（0.6.0）：每秒检测是否卡住，卡住则自动恢复。
    // 只在"播放中 + 前台 + 无错误"时判定，避免把暂停/缓冲误判为卡死。
    //
    // 0.6.9 补充：**"从未起播"也要能自愈**。
    // `open()` 返回只代表地址已交给播放器，弱网下可能长时间不起播；
    // 原判定要求 `playing == true`，这种情况永远不满足 → 永久黑屏无反应
    // （用户反馈"黑屏没有任何反应，要再滑一次"）。这里加一条兜底：
    // 已交给播放器超过 [_firstFrameTicksLimit] 秒仍未起播，则自动恢复一次。
    _healthTimer?.cancel();
    _healthTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_closed || _playerReleased || !widget.active || _error != null) {
        return;
      }
      // 0.7.4：移动网络下"按设计不自动播"不是故障，健康检查整体跳过，
      // 避免反复 `_recover()` 切换备用线路。
      if (_autoPlayBlocked) {
        _firstFrameTicks = 0;
        _stalledTicks = 0;
        return;
      }
      final current = _player;
      if (current == null) return;
      // 兜底一：地址已交出但迟迟不起播（弱网 / 服务端迟迟不给数据）。
      if (_awaitingFirstFrame &&
          _foreground &&
          !current.state.playing &&
          !current.state.completed) {
        _firstFrameTicks++;
        if (_firstFrameTicks >= _firstFrameTicksLimit) {
          // 重置计数：若这次恢复也没能起播，下一轮仍会再试
          // （总次数由 `_recovery` 限制，超过后会转为显示"点击重试"）。
          _firstFrameTicks = 0;
          unawaited(_recover());
          return;
        }
      } else {
        _firstFrameTicks = 0;
      }
      // 兜底二：已在播放但位置长时间不前进（原有逻辑）。
      //
      // 0.7.7 修复（真机反馈"流量+全屏自动切下一集纯黑、等很久不播"）：
      // `_loading` 卡死时（弱网下 `player.open()` 迟迟不返回）必须有自己的超时，
      // 否则既不恢复也不报错，用户只能一直看黑屏。
      if (_loading) {
        _loadTicks++;
        if (_loadTicks >= _loadTicksLimit && mounted && !_closed) {
          _loadTicks = 0;
          setState(() {
            _loading = false;
            _awaitingFirstFrame = false;
            _error = '网络较慢，加载超时，请点击重试';
          });
          _refreshFullscreen(immediate: true);
        }
        return;
      }
      _loadTicks = 0;
      if (_health.stalled(
        position: current.state.position,
        playing: current.state.playing,
        foreground: _foreground,
        now: DateTime.now(),
      )) {
        unawaited(_recover());
        return;
      }

      // 兜底四（0.7.7）：**报告在播但一直拿不到画面尺寸**（弱网首帧迟迟不来）。
      // 这种状态三条旧兜底都覆盖不到（playing=true 又没过 stalled 阈值），
      // 表现为纯黑屏长时间不恢复。
      if (_ready &&
          _error == null &&
          _foreground &&
          !current.state.completed &&
          current.state.playing &&
          !_hasVideoFrame) {
        _noFrameTicks++;
        if (_noFrameTicks >= _noFrameTicksLimit) {
          _noFrameTicks = 0;
          unawaited(_recover());
          return;
        }
      } else {
        _noFrameTicks = 0;
      }

      // 兜底三（0.6.11 新增，用户反馈"偶发下一个视频纯黑无文字、不播放"）：
      //
      // 覆盖前两条**都管不到**的盲区：
      //   `_awaitingFirstFrame == false`（已被"短暂起播"清掉）
      //   且 `playing == false`（随即卡住/缓冲耗尽）
      //   且 `_loading == false`、`_error == null`
      // → 兜底一要求 `_awaitingFirstFrame`、兜底二要求 `playing == true`，
      //   两条同时失效，页面**永久纯黑无文字**。
      //
      // 这正是"播放器短暂报告 playing=true（清掉等待标记）→ 立刻卡住"的产物：
      // 从状态上它既不是"从未起播"，也不是"正在播放却卡住"，
      // 而是第三条路——**起播过，又掉回停止态**。
      //
      // 判定条件必须排除 `_userPaused`，否则用户的暂停会被当成故障自动播回去
      // （那就是另一个已修问题 1 的翻版）。
      if (_ready &&
          !current.state.playing &&
          !current.state.completed &&
          _foreground &&
          !_userPaused) {
        _stalledTicks++;
        if (_stalledTicks >= _stalledTicksLimit) {
          _stalledTicks = 0;
          unawaited(_recover());
          return;
        }
      } else {
        _stalledTicks = 0;
      }
    });
    for (final stream in [
      player.stream.position,
      player.stream.duration,
      player.stream.buffer,
      player.stream.playing,
      player.stream.buffering,
    ]) {
      _subscriptions.add(
        stream.listen((_) {
          // 0.7.13：起播后若播放器一直不报画面尺寸（部分 m3u8 如此），
          // 就永远撤不掉「正在加载视频…」。这里用"起播状态下位置流持续推进"
          // 兜底认定画面已出（约 1 秒后），只在首次置位时重建一次。
          if (!_hasVideoFrame) {
            final playing = _player?.state.playing ?? false;
            if (playing) {
              _frameTicks++;
              if (_frameTicks >= 10) {
                _hasVideoFrame = true;
                if (mounted && !_closed) setState(() {});
                _refreshFullscreen(immediate: true);
              }
            } else {
              _frameTicks = 0;
            }
          }
          // 进度 tick 不再整体 setState（0.3.1 性能修复）。
          //
          // 这里每秒会触发多次，而真正需要跟着走的只有：
          // - 全屏层（独立 Overlay，走 revision 通知，见 _refreshFullscreen）；
          // - 竖屏主界面的进度条（走 _tick 轻量通知，只重建进度条本身）。
          // 此前无条件 `setState(() {})` 会重建整页（含手势层、选集按钮、
          // 选集网格等），是卡顿的直接来源之一。
          _refreshFullscreen();
          _tick.value++;
          // 预载（0.2.31）：位置/缓冲变化时评估是否需要提前准备下一集/下一部。
          _syncPreload();
          // 局域网推送（0.6.4）：**位置推进后**才回报握手。
          //
          // 这是握手的关键钩子：`acknowledge` 的判定要求
          // "位置不早于推送位置，且已推进 ≥0.15 秒"，
          // 因此必须在**位置流**上检查；只在 playing 流检查会永远不满足条件，
          // 发送端会一直等不到确认（老播放器同样挂在这里）。
          _acknowledgeHandoff();
        }),
      );
    }
    // 探测视频真实分辨率，决定是否提供「横屏」按钮。
    // 优先用 aspect（显示宽高比，最可靠），其次 dw/dh、w/h。
    // 注意：很多流在首帧前这些值都是 null，属于正常情况，
    // 不影响横屏按钮使用（按钮常显，未知比例时直接切换）。
    _subscriptions.add(
      player.stream.videoParams.listen((parameters) {
        _applyVideoParams(parameters);
      }),
    );
    _subscriptions.add(
      player.stream.playing.listen((playing) {
        // 0.6.3：播放状态变化必须让控件层重建。
        //
        // 中央播放图标、底部播放/暂停键都依赖 `playing`；此前这里只在
        // `playing == true` 时安排自动隐藏，**不触发重建**，因此从其它途径
        // 改变播放状态（自动连播、播放结束、健康检查恢复等）时图标会滞后。
        if (!_closed) _tick.value++;
        // 0.6.9：真正起播 → 结束"等待第一帧"，撤掉加载提示。
        if (playing && _awaitingFirstFrame) {
          _awaitingFirstFrame = false;
          _firstFrameTicks = 0;
          if (!_closed) setState(() {});
        }
        // 0.7.13：起播时若播放器已经报了宽高，直接认定"画面已出"，
        // 避免正常播放时「正在加载视频…」一直挂着。
        if (playing &&
            !_hasVideoFrame &&
            (_player?.state.width ?? 0) > 0) {
          _hasVideoFrame = true;
          if (mounted && !_closed) setState(() {});
          _refreshFullscreen(immediate: true);
        }
        // 局域网推送（0.6.4）：播放真正开始后回报发送端。
        if (playing && _autoAdvancing) {
          // 0.7.5：**不再在起播时清静默标记**。
          // 全屏要一直静默到用户操作；竖屏本就不看该标记（0.7.5 起非全屏保留控件）。
          // 这里只刷新一次，让全屏层读到 playing 状态。
          _refreshFullscreen(immediate: true);
        }
        if (playing) {
          _scheduleHide();
          _acknowledgeHandoff();
        }
      }),
    );
    _subscriptions.add(
      player.stream.completed.listen((completed) {
        if (!completed || _closed || _loading || _error != null) return;
        final detail = _detail;
        // 默认连播下一部；开启后连播本剧下一集，没有下一集再跳下一部。
        if (widget.autoNextEpisode &&
            detail != null &&
            _episodeIndex + 1 < detail.episodes.length) {
          unawaited(_playEpisode(_episodeIndex + 1, auto: true));
        } else {
          // 0.7.7（甲，真机反馈"全屏自动切换后纯黑"）：连播下一部会切到**新页面**，
          // 而全屏路由属于本页；不关掉它，全屏层就停在本页（随后释放播放器）→ 纯黑。
          if (_fullscreenRouteOpen) _exitFullscreen();
          widget.onFinished();
        }
      }),
    );
    return true;
  }

  /// 记录视频真实宽高比。
  ///
  /// 依次尝试：aspect（显示比例）→ dw/dh → w/h。
  /// 全部拿不到时保持 0（未知），此时横屏按钮仍然可用。
  void _applyVideoParams(VideoParams parameters) {
    if (!mounted || _closed) return;
    double ratio = parameters.aspect ?? 0;
    if (ratio <= 0) {
      final width = parameters.dw ?? parameters.w ?? 0;
      final height = parameters.dh ?? parameters.h ?? 0;
      if (width > 0 && height > 0) ratio = width / height;
    }
    if (ratio <= 0) return;
    if (ratio > 100 || ratio < 0.01) return; // 明显异常，忽略
    // 0.7.13：拿到有效画面比例 → 认定"画面已出"，立刻撤掉加载提示。
    if (!_hasVideoFrame) {
      _hasVideoFrame = true;
      if (mounted && !_closed) setState(() {});
    }
    if ((ratio - _aspectRatio).abs() < 0.01) return;
    setState(() => _aspectRatio = ratio);
    _refreshFullscreen();
  }

  /// 播放开始后主动读一次分辨率。
  ///
  /// `videoParams` 流在某些平台只在参数“变化”时推送一次，
  /// 可能早于本组件订阅，因此这里补一次主动读取。
  void _refreshAspectRatio() {
    final parameters = _player?.state.videoParams;
    if (parameters != null) _applyVideoParams(parameters);
  }

  @override
  void didUpdateWidget(covariant _FeedPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 0.7.4：目标页可能在"自动连播跳转"之前就被 PageView 预构建了，
    // 那时 `initState` 读到的 `autoEnter` 还是 false。这里补一次。
    if (widget.autoEnter && !oldWidget.autoEnter && !_ready) {
      _autoAdvancing = true;
    }
    if (widget.active && !oldWidget.active) {
      // 成为当前页：重新上报能否切下一集，避免沿用上一页的状态。
      _reportEpisodeState();
      if (_ready && _error == null) {
        _playerReleased = false;
        unawaited(_player?.play());
        // 0.7.5：非全屏（竖屏）连播保留控件显示；全屏靠 `_autoAdvancing` 静默。
        if (_autoAdvancing) {
          setState(() => _controlsVisible = true);
          _scheduleHide();
        } else {
          _showControls();
        }
      } else if (_playerReleased) {
        // 0.3.5：本页曾经被滑走并放弃了一次加载，这里重新建播放器接着加载，
        // 不需要用户"切到别的集再切回来"来绕过。
        unawaited(_resumeAfterRelease());
      } else {
        _prepare();
      }
    } else if (!widget.active && oldWidget.active) {
      // 0.7.7（甲）：被滑走时先退出全屏。
      //
      // 全屏路由由**本页**打开，而滑走后本页会释放播放器；
      // 若全屏路由还开着，它仍在渲染本页（已黑），新页面在下面播你看不到。
      if (_fullscreenRouteOpen) _exitFullscreen();
      // 被滑走：先把观看进度落盘，再**彻底释放播放器**（0.3.1 性能修复）。
      //
      // 为什么必须释放（用户反馈"播放卡顿，尤其开倍速后"）：
      // `PageView` 会保留已滑过的页面，而播放器此前只在 `dispose` 才释放，
      // 于是每滑过一个视频就多留一个原生解码器 + 网络缓冲。滑十几个后，
      // 内存与 CPU 被十几个播放器瓜分，表现为越来越卡（倍速时更明显）。
      unawaited(_saveProgress());
      _interactions?.cancel();
      // 0.6.9：**不再 clear 预载器**。
      //
      // 原先这里会 `_preloader.clear()`（本意是"避免和别的页面抢带宽"），
      // 但预载器改为全流共享后，本页预载的往往正是**下一页要播的那一集**
      // （「连播下一部」预载下一部第 1 集）。滑走时清掉它，
      // 等于把刚做好的准备**当场扔掉**，下一页只能重新解析
      // ——这正是用户反馈"感觉没有预加载、每次都要现加载"的直接原因。
      //
      // 现在改为**保留**：由新成为当前页的页面 `take()` 复用。
      // 若用户是往回滑（预载目标不是即将播放的），新当前页调用
      // `prepare()` 时身份不同，预载器内部会自行 `clear()` 掉过期结果，
      // 因此不会残留无效预载，也不会造成会话泄漏。
      // 先记下当前播放位置，回来时据此续播（否则会从第 0 秒重新开始）。
      _resumeFrom = _player?.state.position ?? Duration.zero;
      _releasePlayer();
    }
  }

  /// 释放当前播放器与相关资源（切页 / 销毁共用）。
  ///
  /// 释放后可再次通过 `_ensurePlayer()` 重建；[ _resumeFrom ] 已记录位置。
  ///
  /// 0.3.5：释放时置位 [_playerReleased] 并换掉操作队列，
  /// 让**已经排队但还没执行**的操作全部作废 —— 这是"黑屏卡住"的根因修复：
  /// 旧实现只 `dispose` 播放器，队列里的 `player.open()` 仍会执行，
  /// 而 media_kit 对已释放实例的操作在 release 包中静默失败。
  void _releasePlayer() {
    _playerReleased = true;
    // 丢弃旧队列：仍排队的操作会因 [_playerReleased] 已变而跳过。
    _operations = Future<void>.value();
    _saveTimer?.cancel();
    _saveTimer = null;
    // 取消所有播放器流订阅，避免释放后回调访问已失效对象。
    for (final subscription in _subscriptions) {
      subscription.cancel();
    }
    _subscriptions.clear();
    _interactions?.removeListener(_interactionChanged);
    _interactions?.dispose();
    _interactions = null;
    // 播放器已释放：健康检查定时器必须一并停掉，
    // 否则它会继续读取已释放实例的 state（0.6.0）。
    _healthTimer?.cancel();
    _healthTimer = null;
    _health.reset();
    final player = _player;
    _player = null;
    _video = null;
    // 重置就绪/加载态：下次 `_prepare()` 会重新走一遍。
    _ready = false;
    _plan = null;
    _loading = true;
    // 0.6.11 修复（用户反馈"偶发下一个视频黑屏不播放"）：
    //
    // `_releasePlayer()` 之前**没有清 `_awaitingFirstFrame` / `_firstFrameTicks`**。
    // 若本页在"等待首帧"期间被滑走（`_awaitingFirstFrame == true`），
    // 该标记会残留到下次回来。回来时 `_prepare()` 若因 `_ready` 等条件提前返回，
    // 就出现 `_loading == false`（被别处改掉）且 `_awaitingFirstFrame == true`
    // 且 `playing == false` 的中间态 —— 此时：
    //   - 加载提示条件 `_loading || (_awaitingFirstFrame && !playing)` 本应成立；
    //   - 但若 `_awaitingFirstFrame` 也被别处清掉，就**两者皆假** → **纯黑无文字**。
    // 因此释放播放器时必须把"等待首帧"这套状态**彻底归零**，
    // 让下次 `_prepare()` 从干净状态开始。
    _awaitingFirstFrame = false;
    _firstFrameTicks = 0;
    // 0.6.11：连同"用户暂停""停住计数"一起归零，避免残留到下次重建。
    _userPaused = false;
    _stalledTicks = 0;
    if (player != null) unawaited(player.dispose());
  }

  @override
  void dispose() {
    _closed = true;
    // 0.7.5：进度预览与亮度通知器释放（两者都由本页 State 持有）。
    _seekPreview.dispose();
    // 局域网推送（0.6.4）：注销本页的"正在播放"注册，并回报接收端已退出。
    LanController.current?.detachPlayback(_lanIdentity);
    if (!_handoffFailed) widget.handoff?.fail('接收端已退出播放');
    WidgetsBinding.instance.removeObserver(this);
    _healthTimer?.cancel();
    _healthTimer = null;
    // 退出前先把观看进度落盘（与旧播放器 dispose 行为一致）。
    unawaited(_saveProgress());
    _saveTimer?.cancel();
    _saveTimer = null;
    _generation++;
    _hideTimer?.cancel();
    // 必须先关闭全屏路由，否则其 builder 会在本 State 销毁后继续访问已释放字段。
    if (_fullscreenRouteOpen) {
      _fullscreenRouteOpen = false;
      // 不能在 dispose 里用 `Navigator.maybeOf(context)`（context 已失效），
      // 因此这里关闭时用进入全屏时保存的 navigator 引用。
      final navigator = _fullscreenNavigator;
      if (navigator != null && navigator.canPop()) {
        navigator.pop();
      }
    }
    _fullscreenNavigator = null;
    _fullscreenRevision.dispose();
    unawaited(ScreenBrightness.reset());
    _tick.dispose();
    // 若离开时还锁着横屏，必须恢复竖屏并显示系统栏，否则整个应用会一直横着。
    if (_landscape) {
      _landscape = false;
      unawaited(
        SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]),
      );
      unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge));
    }
    _releasePlayer();
    // 预载器（0.2.31）由**父级**持有并释放（0.6.9 改为全流共享），
    // 本页只借用，不负责 dispose。
    super.dispose();
  }

  void _interactionChanged() {
    if (!mounted) return;
    final boosting = _interactions?.boosting ?? false;
    if (boosting) {
      // 加速中：立刻把完整控件层收起来，只留中央的「3 倍速 · 松开恢复」提示。
      // 注意：中央提示本身是**独立层**（不受控件显隐影响），
      // 所以这里隐藏控件层不会连带把提示藏掉。
      _hideTimer?.cancel();
      if (_controlsVisible) {
        setState(() => _controlsVisible = false);
        _refreshFullscreen();
      }
      return;
    }
    // 松开加速后：**不再弹出整套控件**。
    //
    // 0.2.26 修正（用户反馈）：原先这里只要 feedback 非空就 `_showControls()`，
    // 导致"松手后所有控件都显示出来"（进度条、剧名、简介全部弹出）。
    // 用户期望：松手后只恢复正常倍速，控件保持原状（不主动弹出）。
    // 因此这里不再调用 `_showControls()`，只刷新一次全屏层（让倍速显示恢复）。
    _refreshFullscreen();
  }

  /// 本页是否还能切到下一集。
  ///
  /// 供父级在「连播本剧」模式下判断滑动语义：
  /// 还有下一集时，向下滑动应切集而非翻到下一部剧。
  bool get canPlayNextEpisode {
    if (_closed) return false;
    final detail = _detail;
    if (detail == null) return false;
    return _episodeIndex + 1 < detail.episodes.length;
  }

  /// 本页是否还能切到上一集。
  ///
  /// 供父级判断向上滑动的语义：还有上一集时应回到本剧上一集，
  /// 而不是直接跳到上一部剧（对应问题 3）。
  bool get canPlayPrevEpisode {
    if (_closed) return false;
    final detail = _detail;
    if (detail == null) return false;
    return _episodeIndex > 0;
  }

  /// 播放本剧下一集（供父级滑动调用）。
  Future<void> playNextEpisode() async {
    if (!canPlayNextEpisode) return;
    await _playEpisode(_episodeIndex + 1);
  }

  /// 播放本剧上一集（供父级向上滑动调用）。
  Future<void> playPrevEpisode() async {
    if (!canPlayPrevEpisode) return;
    await _playEpisode(_episodeIndex - 1);
  }

  /// 上下滑动切集（0.2.31，用户方案 B：只切集、不切剧）。
  ///
  /// [direction] 1 = 上滑（下一集），-1 = 下滑（上一集）。
  ///
  /// 语义（用户确认 Q1=B）：
  /// - 只在本剧内切集，**不切剧**；到边界只给提示。
  /// - 返回值是给 `PlayerInteractions` 的轻提示文案。
  String _swipeEpisode(int direction) {
    if (_closed || !widget.active) return '';
    // 0.7.14（XQ-0123）：竖直滑有两个入口（父级跟手滑动 + 播放器手势判定），
    // 一次上滑可能两边都响应 → 跳两集。这里做 400ms 去重，只认第一次。
    final now = DateTime.now();
    if (now.difference(_lastSwipeCommit) < const Duration(milliseconds: 400)) {
      return '';
    }
    _lastSwipeCommit = now;
    // 0.7.5（XQ-0108）：竖滑语义按"连播模式"走——
    // 单剧模式或已开「连播本剧」→ 剧内切集；否则 → 切上一部/下一部。
    final inSeries = widget.singleDrama || widget.autoNextEpisode;
    if (!inSeries) {
      final switchDrama = widget.onSwitchDrama;
      if (switchDrama == null) return '';
      final ok = switchDrama(direction);
      return ok
          ? (direction > 0 ? '下一部' : '上一部')
          : (direction > 0 ? '已经是最后一部了' : '已经是第一部了');
    }
    if (direction > 0) {
      if (canPlayNextEpisode) {
        unawaited(playNextEpisode());
        return '下一集';
      }
      return '已经是最后一集了';
    }
    if (canPlayPrevEpisode) {
      unawaited(playPrevEpisode());
      return '上一集';
    }
    return '已经是第一集了';
  }

  void _showControls() {
    _hideTimer?.cancel();
    // 用户主动操作 → 解除"自动连播静默"，恢复常态显隐。
    _autoAdvancing = false;
    if (!_controlsVisible && mounted) {
      setState(() => _controlsVisible = true);
      // 用户操作，跳过节流立即刷新（0.3.1）。
      _refreshFullscreen(immediate: true);
    }
    _scheduleHide();
  }

  void _scheduleHide() {
    _hideTimer?.cancel();
    if (_closed || _panelOpen) return;
    // 加速中不自动隐藏（松开后由 _interactionChanged 恢复显示与计时）。
    if (_interactions?.boosting ?? false) return;
    if (!(_player?.state.playing ?? false)) return;
    _hideTimer = Timer(const Duration(seconds: 4), () {
      if (!mounted || _closed || _panelOpen) return;
      if (_seekValue != null) return;
      if (!(_player?.state.playing ?? false)) return;
      if (_interactions?.boosting ?? false) return;
      setState(() => _controlsVisible = false);
      // 用户操作，跳过节流立即刷新（0.3.1）。
      _refreshFullscreen(immediate: true);
    });
  }

  void _tap() {
    if (_interactions?.suppressTap ?? false) return;
    // 用户点了画面 → 解除自动连播静默，这次点击要能看到效果。
    _autoAdvancing = false;
    setState(() => _controlsVisible = !_controlsVisible);
    _refreshFullscreen();
    _scheduleHide();
  }

  void _togglePlayback() {
    final player = _player;
    if (player == null || _closed || _loading || _error != null) return;
    _autoAdvancing = false;
    // 局域网推送（0.6.4）：用户操作了播放 → 接收端接手。
    _takeOverHandoff();
    _interactions?.cancel();
    final willPlay = !player.state.playing;
    if (willPlay) {
      // 0.7.3（XQ-0107）：用户主动点了播放 → 本次会话内不再拦截自动播放，
      // 并恢复预加载（移动网络下此前为了省流量暂停了预载）。
      widget.manualPlayed.value = true;
      _autoPlayBlocked = false;
    }
    // 0.6.4 修复（用户反馈"暂停时会多走一帧才停下来"）：
    // 原先统一用 `playOrPause()`，它内部走的是 mpv 的
    // `_command(['cycle','pause'])` —— **"切换"命令**，需要 mpv 先读当前状态再翻转，
    // 且是异步排队下发；命令到达前解码器可能又输出了一帧，表现为"多走一帧"。
    // 现在按**明确意图**分流：要暂停就 `pause()`、要恢复就 `play()`，
    // 二者内部是 `mpv_set_property('pause', …)` —— **直接设值**，
    // 不依赖"读状态再翻转"，语义更准确、少一步状态查询。
    // 顺带消除一个隐患：`cycle` 在状态不同步时可能"翻反"（该停却播），
    // 直接设值不会出现这种情况。
    unawaited(willPlay ? player.play() : player.pause());
    // 0.6.11 修复（用户反馈"双击暂停后出现正在加载视频提示，过一会儿自己播放"）：
    //
    // 根因：`_awaitingFirstFrame` 在 `_prepare()` 成功后置 true，本意是"等首帧"，
    // 只有 `playing == true` 才会清掉（见 playing 流监听）。
    // 若用户在首帧到达前就暂停，`playing` 一直是 false → 该标记**永远留着**
    // → 健康检查的"从未起播"兜底（`_awaitingFirstFrame && !playing`）成立
    // → 每秒计数，**15 秒后触发 `_recover()` 自动重播**。
    // 表现就是：暂停 → 加载提示重新出现 → 过一会儿自己开始播。
    //
    // 修法：**用户主动暂停 = 明确意图**，必须立即结束"等待首帧"状态，
    // 否则健康检查会把"用户暂停"误判成"从未起播"。
    if (!willPlay) {
      _awaitingFirstFrame = false;
      _firstFrameTicks = 0;
      // 0.6.11：记录"用户主动暂停"，供健康检查兜底三区分
      // "用户暂停" 与 "起播后卡住"——否则暂停会被当成故障自动播回去。
      _userPaused = true;
      _stalledTicks = 0;
      // 暂停时立刻落盘，避免用户暂停后直接退出导致进度丢失。
      unawaited(_saveProgress());
    } else {
      // 用户恢复播放：解除暂停标记，健康检查恢复正常兜底。
      _userPaused = false;
      _stalledTicks = 0;
    }
    // 0.6.3 修复（用户反馈"双击恢复后中央图标仍是暂停"）：
    // 原先这里不重建，中央播放图标与底部播放/暂停键要等下一次
    // 整页 setState（如自动隐藏计时器到期）才更新，表现为"视频在播、图标不变"。
    // 现在切换后立即刷新一次，图标与画面同步。
    _tick.value++;
    _refreshFullscreen(immediate: true);
    _showControls();
  }

  Future<void> _seekTo(Duration position) async {
    final player = _player;
    if (player == null || _closed) return;
    // 局域网推送（0.6.4）：用户调整了播放位置 → 接收端接手。
    _takeOverHandoff();
    await player.seek(position);
    _showControls();
  }

  // ───────────────────────── 局域网推送（0.6.4 从老播放器迁移） ─────────────────────────
  //
  // 迁移自 `player_screen.dart`，**协议与语义完全保持一致**，
  // 以便新旧版本混用（一台装新版、一台装旧版）时仍能正常握手。

  /// 注册"本机正在播什么"，供对方设备显示与"替换播放"判断。
  ///
  /// `identity` 每次换集/换源都会换新对象，`detachPlayback` 只认同一 identity，
  /// 因此不会误清掉别的页面的注册（与老播放器一致）。
  void _attachLanPlayback() {
    final detail = _detail;
    if (detail == null) return;
    final index = _episodeIndex.clamp(0, detail.episodes.length - 1);
    LanController.current?.attachPlayback(
      LanPlaybackHost(
        identity: _lanIdentity,
        title: '${detail.drama.title} · 第 ${detail.episodes[index].number} 集',
        stop: _stopForLan,
      ),
    );
  }

  /// 发送端要求停止（或"被替换播放"）时：暂停本机并保存进度。
  ///
  /// 与老播放器 `_stopForLan` 等价；这里只需暂停 + 落盘，
  /// 不退出页面（用户可继续手动播放）。
  Future<void> _stopForLan() async {
    final player = _player;
    if (_closed || player == null) return;
    _interactions?.cancel();
    _health.reset();
    await player.pause();
    await _saveProgress();
    if (mounted && !_closed) {
      _tick.value++;
      _refreshFullscreen(immediate: true);
      _showControls();
    }
  }

  /// 握手：播放**真正开始**后回报发送端。
  ///
  /// 判定条件与老播放器 `_acknowledgeHandoff` 一致——必须同时满足
  /// "正在播放、未缓冲、有画面尺寸、位置不早于推送位置"，
  /// 否则发送端会认为"没播起来"而反复重试。
  void _acknowledgeHandoff() {
    final handoff = widget.handoff;
    if (!_handoffOwned ||
        handoff == null ||
        _handoffFailed ||
        handoff.cancelled ||
        handoff.started.isCompleted ||
        _closed ||
        _loading ||
        _error != null) {
      return;
    }
    // 只认第一集（推送过来的那一集）；换集后不再回报，避免误判。
    if (_episodeIndex != widget.initialEpisodeIndex) return;
    final player = _player;
    if (player == null) return;
    final state = player.state;
    final position = state.position.inMilliseconds / 1000;
    final duration = state.duration.inMilliseconds / 1000;
    if (duration > 0 && handoff.position > duration + 2) {
      _failHandoff('续播位置超过接收端分集时长');
      return;
    }
    if (!state.playing ||
        state.buffering ||
        (state.width ?? 0) <= 0 ||
        position < handoff.position - .5 ||
        position > handoff.position + 20) {
      return;
    }
    _lanFirstPosition ??= position;
    if (position >= _lanFirstPosition! + .15) {
      handoff.acknowledge(position);
    }
  }

  /// 回报失败（只报一次；`started` 只能完成一次）。
  void _failHandoff(String message) {
    if (_handoffFailed) return;
    _handoffFailed = true;
    widget.handoff?.fail(message);
  }

  /// 用户操作了播放（切集/拖动/暂停等）→ 接收端接手，此后不再代发送端停止。
  void _takeOverHandoff() {
    if (!_handoffOwned) return;
    _handoffOwned = false;
    _failHandoff('接收端已操作播放');
  }

  /// 推送按钮（主动投屏到另一台设备）。
  ///
  /// 与老播放器 `_pushToDevice` 等价，限制也一样：
  /// - 未开启设备互联、或本地媒体（`mediaId` 非空）时不提供；
  /// - 面板打开期间不重复触发；
  /// - 对方接受后**暂停本机**（避免两台设备同时出声）。
  Future<void> _pushToDevice() async {
    final link = LanController.current;
    final detail = _detail;
    if (link == null ||
        detail == null ||
        _panelOpen ||
        _closed ||
        _loading ||
        _error != null ||
        widget.mediaId != null) {
      return;
    }
    final generation = _generation;
    final index = _episodeIndex.clamp(0, detail.episodes.length - 1);
    bool current() =>
        mounted && !_closed && generation == _generation && index == _episodeIndex;
    _interactions?.cancel();
    setState(() => _panelOpen = true);
    try {
      await showLanPush(
        context,
        link,
        snapshot: () => LanPlaybackIntent(
          drama: detail.drama,
          episodeID: detail.episodes[index].id,
          episode: detail.episodes[index].number,
          position: _currentPositionForPush(detail, index),
        ),
        stillCurrent: current,
        onAccepted: () async {
          if (!current()) throw StateError('本机播放内容已变更');
          await _stopForLan();
          if (!current()) throw StateError('本机播放内容已变更');
        },
      );
    } catch (error) {
      if (mounted && !_closed) _toast(error.toString());
    } finally {
      if (mounted && !_closed) setState(() => _panelOpen = false);
    }
  }

  /// 推送时上报的当前位置：未打开过或换集时回落到起始位置。
  double _currentPositionForPush(DramaDetail detail, int index) {
    final player = _player;
    if (player == null) return _pendingStart;
    if (_episodeIndex != index) return 0;
    final seconds = player.state.position.inMilliseconds / 1000;
    return seconds > 0 ? seconds : _pendingStart;
  }

  /// 保存观看记录，使竖滑流播放的剧也进入「最近观看」。
  ///
  /// 旧播放器（`player_screen.dart` 的 `_saveProgress`）是唯一的写入者，
  /// 因此竖滑流此前**完全不会**产生观看记录。这里复用同一套语义：
  /// - 只保存当前页、且已经解析出剧集信息的情况；
  /// - 位置小于 0.1 秒不保存（避免点开即存）；
  /// - 用 [position] + [duration] + 集号 组成指纹去重，避免频繁写盘；
  /// - 失败时给出提示，但不打断播放。
  Future<void> _saveProgress() async {
    if (_closed) return;
    final detail = _detail;
    final player = _player;
    if (detail == null || player == null) return;
    if (!widget.active) return;
    final index = _episodeIndex.clamp(0, detail.episodes.length - 1);
    final position = player.state.position.inMilliseconds / 1000;
    final duration = player.state.duration.inMilliseconds / 1000;
    if (position < .1) return;
    final key = '${detail.drama.id}:$index:$position:$duration';
    if (_savedProgressKey == key && _saveWarning == null) return;
    final epoch = widget.store.profileEpoch;
    final entry = WatchEntry(
      drama: widget.repository.catalogUpdates.current(detail.drama),
      episode: detail.episodes[index].number,
      position: position,
      duration: duration,
      updatedAt: DateTime.now(),
    );
    try {
      // 0.6.0：本地媒体（mediaId 非空）写入**独立**的本地媒体进度存储，
      // 与老播放器 `player_screen.dart` 的 `saveMediaWatch` 语义一致。
      // 混入普通观看记录会污染「最近观看」，因此必须分开。
      final mediaId = widget.mediaId;
      if (mediaId != null) {
        await widget.store.saveMediaWatch(mediaId, entry);
      } else {
        await widget.store.saveWatch(entry);
      }
      if (widget.store.profileEpoch != epoch) return;
      _savedProgressKey = key;
      if (mounted && !_closed && _saveWarning != null) {
        setState(() => _saveWarning = null);
      }
    } catch (_) {
      if (mounted && !_closed && _saveWarning == null) {
        setState(() => _saveWarning = '观看记录尚未保存，请检查存储空间后重试。');
      }
    }
  }

  /// 上报"本页还能否切到下一集"给父级，并附上切集入口。
  ///
  /// 只在当前页（active）时上报，避免预加载的非当前页覆盖状态。
  void _reportEpisodeState() {
    if (!widget.active) return;
    final hasNext = canPlayNextEpisode;
    final hasPrev = canPlayPrevEpisode;
    widget.onEpisodeStateChanged?.call(
      hasNext,
      playNext: hasNext ? playNextEpisode : null,
      hasPrev: hasPrev,
      playPrev: hasPrev ? playPrevEpisode : null,
    );
  }

  Future<void> _playEpisode(int index, {bool auto = false}) async {
    final detail = _detail;
    if (_closed || detail == null) return;
    if (index < 0 || index >= detail.episodes.length) return;
    // 0.7.2（XQ-0104）：auto = 自动连播切来的，本次换集不弹整套控件。
    // 任何手动换集（上下滑 / 选集 / 上一集按钮）都传默认 false，行为不变。
    _autoAdvancing = auto;
    // 换集前先把当前集的进度存下来，否则切走就丢。
    await _saveProgress();
    // 0.3.5：等待落盘期间页面可能已被滑走（播放器已释放）。
    // 此时若继续按老流程走，会在已释放的播放器上加载，最终黑屏；
    // 这里改为把状态复位，交给 `_resumeAfterRelease()`（滑回来时）重新加载。
    if (_closed || _playerReleased) return;
    // 局域网推送（0.6.4）：换集属于"接收端已操作播放"，
    // 此后不再代发送端停止；并换新 identity 重新注册本机播放内容
    // （`detachPlayback` 只认同一 identity，故先解绑旧的后再挂新的）。
    _takeOverHandoff();
    LanController.current?.detachPlayback(_lanIdentity);
    _lanIdentity = Object();
    _episodeIndex = index;
    _ready = false;
    // 预载（0.2.31）：换集时 `_prepare` 里会先 `take()` 取走目标集的预载结果，
    // 命中则直接复用；未命中则正常解析。此处无需额外 clear。
    await _prepare(force: true);
  }

  Future<void> _prepare({bool force = false}) async {
    if (_closed) return;
    if (!_ensurePlayer()) {
      // 0.3.5：拿不到播放器时不能静默退出，否则页面会停在"既不加载也不报错"。
      // 只有"页面已被滑走/销毁"属于正常停止，此时不动状态，等滑回来重试。
      if (!_closed && !_playerReleased && mounted) {
        setState(() {
          _loading = false;
          _error = '播放器未能启动，请返回上一集重试';
        });
      }
      return;
    }
    final player = _player;
    if (player == null) return;
    if (_ready && !force) return;
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _error = null;
      // 0.7.13：新一集重新判断"是否已出画面"。
      _hasVideoFrame = false;
      _frameTicks = 0;
    });
    // 0.7.7 修复（真机反馈"流量+全屏自动切下一集纯黑、等很久不播"）：
    // 全屏层是独立路由，只跟随 `_fullscreenRevision` 重建。此前进入加载时
    // 没有立即刷新它 → 全屏看不到「正在加载视频…」，弱网下 open 一卡就是**纯黑无文字**。
    _refreshFullscreen(immediate: true);
    try {
      final detail = _detail ?? await widget.repository.detail(widget.drama);
      // 0.3.5：除代次外还要确认播放器实例没被替换/释放
      // （滑走页面会释放播放器，此时继续加载就是在操作已释放的实例）。
      if (!_attemptAlive(player)) return;
      if (detail.episodes.isEmpty) {
        throw AppFailure('该剧暂无可用剧集');
      }
      // 0.6.6：首次加载时套用观看记录（随机流刷到看过的剧 → 从历史进度续播）。
      // **必须在下行 `index` 计算之前调用**：它会改写 `_episodeIndex`，
      // 而 `index` 是从 `_episodeIndex` 快照出来的，放后面就白改了。
      _applyHistoryOnce(detail);
      final index = _episodeIndex.clamp(0, detail.episodes.length - 1);
      final previous = _plan;
      // 预载命中（0.2.31）：若之前已提前解析好这一集，直接复用，省一次网络解析。
      // 匹配失败时返回 null，走正常解析路径。
      final prepared = widget.localOnly
          ? null
          : _preloader.take(
              detail.drama,
              detail.episodes[index],
              quality: _quality,
            );
      // 单剧模式的本地文件模式（0.2.29，下载页）：
      // 用 `localPlayback` 取已下载的本地文件，而不是拉在线流。
      // 两者返回的都是 `PlaybackPlan`，后续处理完全一致
      // （`plan.local` 为 true 时下面会走 file/crypto/data 协议白名单）。
      final plan =
          prepared ??
          (widget.localOnly
              ? await _resolveLocal(detail, index)
              : await widget.repository.resolve(
                  detail.drama,
                  detail.episodes[index],
                  quality: _quality,
                ));
      if (!_attemptAlive(player)) {
        // 页面已不可用：把刚解析出来的会话还回去，避免会话泄漏。
        unawaited(widget.repository.release(plan.session));
        return;
      }
      if (plan.url.isEmpty) {
        throw AppFailure(widget.localOnly ? '本地视频不可用，请重新下载。' : '站源未返回播放地址，请重试');
      }
      // 与现有播放器保持一致：设置协议白名单、解密密钥与重试参数。
      // 所有原生调用串行执行（0.3.1），避免并发打断导致卡顿。
      await _serialize(() async {
        final platform = player.platform;
        if (platform is NativePlayer) {
          await platform.setProperty(
            'demuxer-lavf-o',
            [
              'seg_max_retry=3',
              'strict=experimental',
              'allowed_extensions=ALL',
              plan.local
                  ? 'protocol_whitelist=[file,crypto,data]'
                  : 'protocol_whitelist=[http,https,tcp,tls,crypto,data,file]',
              if (plan.decryptionKey.isNotEmpty)
                'decryption_key=${plan.decryptionKey}',
            ].join(','),
          );
          await platform.setProperty('network-timeout', '20');
          // 弱网缓冲策略（0.5.0）。
          //
          // 背景：用户实测"开 VPN 就卡"，根因是视频请求全部绕道代理节点
          // （Go 原生核心会读系统代理，见 `native/core/proxy_system.go`），
          // 多一跳且节点质量不稳定 → 缓冲容易被抖动打空 → 表现为抽帧卡顿。
          // 这里做两件事，都不改变解码/渲染方式、也不影响音调：
          // 1. 关闭磁盘缓存，改用内存缓存：弱网下避免额外磁盘 IO 拖慢取流；
          // 2. 加大流层缓冲：对代理带来的抖动更有容忍度。
          // 属性不受支持时静默忽略，绝不影响播放。
          for (final entry in const {
            'cache-on-disk': 'no',
            'stream-buffer-size': '524288',
          }.entries) {
            try {
              await platform.setProperty(entry.key, entry.value);
            } catch (_) {
              // 忽略：仅属调优，失败不构成错误。
            }
          }
        }
      });
      if (!_attemptAlive(player)) return;
      _detail = detail;
      _plan = plan;
      _episodeIndex = index;
      // 详情就绪后上报，让父级知道本页还能否切下一集（决定滑动语义）。
      _reportEpisodeState();
      // 续播位置（0.2.29）：只有首次打开、且传入了非零位置时才生效；
      // 换集时 `_playEpisode` 会把 `_pendingStart` 清空，避免每集都跳。
      final start = _takeStartPosition();
      // 0.7.4 修复（真机反馈"全屏连播下一集仍会弹控件"）：
      // 0.7.4 修复：`open()` 可能在 await 返回前就报告 playing，
      // 因此在 open 之前快照本轮"是否自动连播"，避免被异步回调改掉。
      // 0.7.5：该快照现在只用于决定**竖屏**是否显示控件（全屏用 `_autoAdvancing`）。
      // 0.7.3（XQ-0107）：移动网络下不自动播放（除非开关开启或本次已手动播过）。
      _autoPlayBlocked = await _resolveAutoPlayBlocked();
      await _openMedia(
        player,
        plan,
        start,
        play: widget.active && !_autoPlayBlocked,
      );
      // 0.3.5：open 之后再次确认播放器仍然有效
      // （用户可能在加载中滑走页面，此时播放器已被释放）。
      if (!_attemptAlive(player)) return;
      await _interactions?.applySpeed();
      if (!_attemptAlive(player)) return;
      if (previous != null && previous.session != plan.session) {
        unawaited(widget.repository.release(previous.session));
      }
      setState(() {
        _loading = false;
        _ready = true;
        // 0.7.2（XQ-0104）：自动连播换集时保持控件收起。
        // 0.7.5：**竖屏保留控件显示**（非全屏连播也要能看到剧名/按钮）；
        // 全屏的静默由 `_autoAdvancing` 在控件条件里拦截，与这里无关。
        _controlsVisible = true;
        // 0.6.9：`open()` 返回 ≠ 已起播。这里开始"等待第一帧"，
        // 期间**保留加载提示**（避免纯黑无反应），并在健康检查里兜底自动恢复。
        // 注意：有错误时不能显示加载提示，否则会盖住"点击重试"。
        //
        // 0.7.4（真机反馈"移动网络不播放时一直显示正在加载、反复切备用线路"）：
        // 移动网络拦截自动播放时，播放器是"已就绪但按设计不播"，
        // **不能**进入"等待首帧"，否则健康检查三道兜底会把它当成故障，
        // 反复 `_recover()` 切备用线路。
        _awaitingFirstFrame = !_autoPlayBlocked && _error == null;
        _firstFrameTicks = 0;
        // 0.6.11：新内容开始加载 = 一次全新的播放，
        // 用户之前的暂停意图不再适用（否则新一集会"以为用户暂停"而不恢复）。
        // 0.7.4：但"移动网络下按设计不自动播"要当成**用户主动不播**，
        // 否则同样会被健康检查判为卡死。
        _userPaused = _autoPlayBlocked;
        _stalledTicks = 0;
      });
      // 加载成功：复位健康检查与恢复计数（0.6.0）。
      // 不复位的话，上一次的失败计数会累计，导致本次偶发卡顿直接判为"停止"。
      _health.reset();
      _recovery.reset();
      // 局域网推送（0.6.4）：内容就绪后重新注册"本机正在播什么"，
      // 并尝试回报握手（真正开始播放后才会 acknowledge）。
      _attachLanPlayback();
      _acknowledgeHandoff();
      // 就绪是重要状态切换，跳过节流立即刷新（0.3.1）。
      _refreshFullscreen(immediate: true);
      _scheduleHide();
      // 兜底：某些平台 videoParams 流不会补发，这里主动读一次分辨率。
      _refreshAspectRatio();
    } catch (error) {
      if (_closed || generation != _generation) return;
      // 0.7.2（XQ-0104）：自动连播失败时必须解除静默，否则控件会一直不出现，
      // 用户连"重试"以外的操作都摸不到。
      _autoAdvancing = false;
      setState(() {
        _loading = false;
        // 0.6.9：进入错误态后不再"等待第一帧"，否则加载提示会盖住"点击重试"。
        _awaitingFirstFrame = false;
        _firstFrameTicks = 0;
        _error = error is AppFailure ? error.message : error.toString();
      });
      _refreshFullscreen(immediate: true);
    }
  }

  /// 真正把媒体交给播放器（0.3.5 独立成方法，便于加"释放护栏"）。
  ///
  /// 关键点：`open()` 前**再确认一次**播放器实例仍然有效。
  /// 因为 `_serialize()` 是排队执行的，从入队到真正执行可能已经过了几百毫秒，
  /// 期间用户可能已经滑走页面、播放器已被释放；此时若继续调用
  /// `open()`，media_kit 在 release 包中断言被移除，会**静默什么都不做**，
  /// 页面就永久黑屏。
  /// 移动网络下是否禁止自动起播（0.7.3，`XQ-0107`）。
  ///
  /// 每次换集/换剧时按"当前网络类型 + 设置开关 + 是否手动播过"重新判定：
  /// - 开关开启 → 不拦（与 Wi-Fi 一致）；
  /// - 本次已手动播过 → 不拦；
  /// - 移动网络 → 拦截（只加载首帧，等用户点一下）；
  /// - 无法判断网络（桌面端 / 通道异常）→ 不拦，避免误伤。
  bool _autoPlayBlocked = false;

  /// 水平滑动时的进度预览（0.7.5，`XQ-0108`）。
  ///
  /// 拖动中只改这个值，让进度条跟手；松手才真正 `seek`。
  /// 单独用 `ValueNotifier` 是为了**只重建进度条**，不重建整层视频。
  final _seekPreview = ValueNotifier<double?>(null);

  /// 系统媒体音量缓存（0.7.5，`XQ-0109`）。
  int _systemVolumeIndex = 0;
  int _systemVolumeMax = 15;

  /// 水平滑动手势（全屏与竖屏共用，0.7.5）。
  int? _hPointer;
  double? _hOriginX;
  Duration _hStart = Duration.zero;
  Duration? _hTarget;

  Future<bool> _resolveAutoPlayBlocked() async {
    // 详情页/下载页的主动点播、本地文件播放：与流量无关，不拦。
    if (widget.singleDrama || widget.localOnly) return false;
    if (widget.store.autoPlayOnMobile) return false;
    if (widget.manualPlayed.value) return false;
    // 0.7.12（XQ-0119）：已滑过第一个视频 → 本次会话解除限制。
    if (widget.unlocked.value) return false;
    final kind = await NetworkState.current();
    return kind == NetworkKind.mobile;
  }

  Future<void> _openMedia(
    Player player,
    PlaybackPlan plan,
    Duration? start, {
    required bool play,
  }) {
    return _serialize(() async {
      if (!_attemptAlive(player)) return;
      await player.open(
        Media(plan.url, httpHeaders: plan.headers, start: start),
        play: play,
      );
    });
  }

  String get _qualityLabel {
    if (_plan?.local == true) return '本地原画';
    return _quality == 0 ? '自动' : '${_quality}P';
  }

  /// 剧名最大字数（**含省略号本身**）。
  ///
  /// 用户要求：加标点符号一共固定 12 字，超出的用省略号代替，
  /// 「…」也计入这 12 字内。因此超长时取前 11 个字形 + 1 个「…」。
  static const int _titleMaxChars = 12;

  /// 按用户规则裁剪剧名。
  ///
  /// 用 `characters` 按**字形**切分，而不是 `String.substring`：
  /// 后者按 UTF-16 码元切，遇到 emoji 或组合字符会切出乱码。
  String get _displayTitle {
    final title = widget.drama.title;
    final chars = title.characters;
    if (chars.length <= _titleMaxChars) return title;
    return '${chars.take(_titleMaxChars - 1)}…';
  }

  /// 是否显示左上角集数标签。
  ///
  /// 仅在剧集总数 > 1 时显示：单集剧、本地单文件显示"第1集"没有信息量。
  bool get _hasEpisodeBadge => (_detail?.episodes.length ?? 0) > 1;

  /// 是否提供推送按钮（0.6.4，从老播放器迁移）。
  ///
  /// 三个前置条件与老播放器一致：
  /// - 设备互联未开启（`LanController.current == null`）时不显示；
  /// - **本地媒体不推送**（`mediaId` 非空）——对方没有这个本地文件；
  /// - 内容未就绪或出错时不显示，避免点了没反应。
  bool get _canPush =>
      LanController.current != null &&
      widget.mediaId == null &&
      !_loading &&
      _error == null;

  /// 右上角推送按钮（投屏到另一台设备）。
  ///
  /// 复用 `LanPushButton`（与老播放器同一个组件），
  /// 因此连接状态图标、推送中的转圈、tooltip 文案完全一致。
  Widget _pushButton() => Align(
    alignment: Alignment.topRight,
    child: SafeArea(
      bottom: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(0, 6, 6, 0),
        child: LanPushButton(
          key: const ValueKey('feed-lan-push'),
          onPressed: _pushToDevice,
        ),
      ),
    ),
  );

  /// 剧名行（0.6.2）。
  ///
  /// - 剧名固定最多 12 字（含省略号）；
  /// - 右侧 `›` 箭头，**剧名 + 箭头整块可点** → 进入该剧详情页；
  /// - **单剧模式不显示箭头、剧名不可点**：从详情页进入时再点会叠一层详情页，
  ///   从本地媒体进入时那条剧是本地合成的，跳详情会去联网拉取，
  ///   与"本地媒体不联网"的既有约束冲突。
  /// - 宽度上限为屏宽的 70%，保证再长的剧名也不会把箭头挤出屏幕。
  Widget _titleBar() {
    final canOpenDetail = !widget.singleDrama;
    final row = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Flexible(
          child: Text(
            _displayTitle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 17,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
        if (canOpenDetail)
          const Padding(
            padding: EdgeInsets.only(left: 4),
            child: Icon(
              Icons.chevron_right_rounded,
              color: Colors.white70,
              size: 22,
            ),
          ),
      ],
    );
    if (!canOpenDetail) {
      // 单剧模式：保持纯文本，不引入任何点击行为。
      return Align(alignment: Alignment.centerLeft, child: row);
    }
    return Align(
      alignment: Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.sizeOf(context).width * .7,
        ),
        child: Semantics(
          button: true,
          label: '${widget.drama.title}，查看详情',
          child: InkWell(
            key: const ValueKey('feed-title-detail'),
            // 0.6.5：进详情页前**先暂停本页播放**（用户反馈"点进详情页后
            // 视频仍在播放，有声音"）。播放器实例在子页，因此暂停在这里做。
            onTap: () {
              unawaited(_pauseForDetail());
              widget.onOpenDetail();
            },
            borderRadius: BorderRadius.circular(6),
            child: row,
          ),
        ),
      ),
    );
  }

  /// 进详情页前暂停本页播放（0.6.5）。
  ///
  /// 与 [ _stopForLan ] 的区别：这里只暂停 + 落盘，**不刷新控件层**
  /// （本页马上要被详情页盖住，无需重建）；返回后**不自动恢复**，
  /// 由用户自行决定是否继续（与首页"进详情页即停"一致）。
  Future<void> _pauseForDetail() async {
    final player = _player;
    if (_closed || player == null) return;
    _interactions?.cancel();
    _health.reset();
    await player.pause();
    await _saveProgress();
  }

  /// 长按加速提示的文字（0.6.6，竖屏与全屏共用）。
  ///
  /// 用户要求"**字不透明无所谓，但背景的透明度尽量高一些**"，
  /// 也就是**背景要透、字要清楚**。做法是给文字加一圈**深色描边**：
  /// - 背景只用极淡的半透明黑（22%），几乎不挡画面；
  /// - 描边保证在亮画面（雪景、白墙）上也不糊；
  /// - 字本身纯白加粗，在任何底色上都有足够对比度。
  ///
  /// 用 `Stack` 叠两层同一文案（下层描边、上层填充）实现描边效果，
  /// 不引入额外依赖，也不依赖字体是否支持 `Paint.stroke`。
  Widget _boostHintText(String text) => Stack(
    alignment: Alignment.center,
    children: [
      Text(
        text,
        textAlign: TextAlign.center,
        style: TextStyle(
          fontSize: 15,
          fontWeight: FontWeight.w700,
          height: 1.3,
          foreground: Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 3.5
            ..color = const Color(0xCC000000),
        ),
      ),
      Text(
        text,
        textAlign: TextAlign.center,
        style: const TextStyle(
          fontSize: 15,
          fontWeight: FontWeight.w700,
          height: 1.3,
          color: Color(0xFFFFFFFF),
        ),
      ),
    ],
  );

  /// 左上角集数标签：显示当前第几集。
  ///
  /// 竖屏时放在控件层内，**跟随控件一起显隐**（用户要求）；
  /// 全屏时由调用方放在控件层之外，改为**常显**（0.7.2，`XQ-0103`）。
  /// [textKey] 用于区分两个位置（全屏与竖屏可能同时在树中）。
  Widget _episodeBadge({Key? textKey}) => Align(
    alignment: Alignment.topLeft,
    child: SafeArea(
      bottom: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 0, 0),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: Colors.black54,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            child: Text(
              '第${_episodeIndex + 1}集',
              key: textKey ?? const ValueKey('feed-episode-badge'),
              style: const TextStyle(
                color: Colors.white,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ),
      ),
    ),
  );

  /// 亮度不再用画面滤镜（0.7.8）：改调窗口亮度，滤镜层直接透传。
  Widget _applyBrightness(Widget child) => child;

  Future<void> _setSpeed(double value) async {
    if (_closed) return;
    setState(() => _speed = value);
    await _interactions?.applySpeed();
    await widget.store.setPlaybackPreferences(
      widget.store.playbackPreferences.copyWith(speed: value),
    );
  }

  Future<void> _setQuality(int value) async {
    if (_closed || value == _quality) return;
    _quality = value;
    await widget.store.setPlaybackPreferences(
      widget.store.playbackPreferences.copyWith(quality: value),
    );
    _ready = false;
    await _prepare(force: true);
  }

  /// 打开倍速 / 清晰度 / 选集弹窗。
  ///
  /// 0.2.28（方案 D）：全屏层已改为**真正的 Navigator 路由**，
  /// 不再是挂在 root Overlay 上的 `OverlayEntry`。
  /// 因此这里的层级问题自然消失——弹窗统一走 root Navigator，
  /// 会正确显示在全屏路由之上；且不再有"退出全屏后层级错乱"的风险。
  bool get _sheetUsesRootNavigator => true;

  Future<void> _openPanel(Future<void> Function() show) async {
    _hideTimer?.cancel();
    _interactions?.cancel();
    _autoAdvancing = false;
    setState(() {
      _panelOpen = true;
      _controlsVisible = true;
    });
    await show();
    if (mounted && !_closed) {
      setState(() => _panelOpen = false);
      _showControls();
    }
  }

  /// 弹窗统一深色底 + 白色文字。
  ///
  /// 用 `Theme` 强制覆盖，而不是只包 `DefaultTextStyle`：
  /// `showModalBottomSheet` 的 builder 挂在 `MaterialApp` 主题上，
  /// 浅色主题下 `ListTile` 的 textColor/iconColor/tileColor 会从主题解析，
  /// 只包 DefaultTextStyle 会被覆盖，导致深色底配深色字看不清。
  Widget _sheetShell({required String title, required Widget child, Key? key}) {
    const background = Color(0xFF191A20);
    const foreground = Colors.white;
    return Theme(
      data: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFFFF765F),
          surface: background,
          onSurface: foreground,
          onSurfaceVariant: Color(0xFFB9B6C2),
        ),
        // 覆盖 ListTile / 文本 / 图标 的所有颜色解析入口。
        listTileTheme: const ListTileThemeData(
          textColor: foreground,
          iconColor: foreground,
          titleTextStyle: TextStyle(
            color: foreground,
            fontSize: 15,
            fontWeight: FontWeight.w500,
          ),
          subtitleTextStyle: TextStyle(color: Color(0xFFB9B6C2), fontSize: 12),
          selectedColor: Color(0xFFFF765F),
        ),
        textTheme: const TextTheme(
          titleLarge: TextStyle(color: foreground),
          bodyLarge: TextStyle(color: foreground),
          bodyMedium: TextStyle(color: foreground),
        ),
        iconTheme: const IconThemeData(color: foreground),
        dividerTheme: const DividerThemeData(color: Color(0xFF3A3B44)),
        textButtonTheme: TextButtonThemeData(
          style: TextButton.styleFrom(foregroundColor: foreground),
        ),
      ),
      child: DefaultTextStyle.merge(
        style: const TextStyle(color: foreground),
        child: IconTheme(
          data: const IconThemeData(color: foreground),
          child: Material(
            key: key,
            color: background,
            child: SafeArea(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 18, 20, 8),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            title,
                            style: const TextStyle(
                              color: foreground,
                              fontSize: 17,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        IconButton(
                          tooltip: '关闭',
                          onPressed: () => Navigator.pop(context),
                          icon: const Icon(Icons.close_rounded),
                        ),
                      ],
                    ),
                  ),
                  const Divider(height: 1, color: Color(0xFF3A3B44)),
                  Flexible(child: child),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 选中项胶囊（chip）样式（0.2.31 菜单 UI 改版，用户方案 A）。
  ///
  /// 为什么用 chip 而不是 `ListTile`：
  /// - 倍速/清晰度项数少，竖列列表显得空旷、层次弱；
  /// - chip 能一眼看出"有哪些选项、当前选的是哪个"（选中项主题色填充）；
  /// - 横屏时可用 `Wrap` 自动折行铺满宽度，不再受"底部弹窗太扁"影响。
  Widget _optionChip({
    required String label,
    required bool selected,
    required VoidCallback onTap,
    Key? key,
  }) {
    const accent = Color(0xFFFF765F);
    return InkWell(
      key: key,
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 140),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(
          color: selected ? accent : const Color(0xFF26272F),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: selected ? accent : const Color(0xFF3A3B44),
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: selected ? Colors.white : const Color(0xFFB9B6C2),
            fontSize: 14,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
          ),
        ),
      ),
    );
  }

  /// 自适应列宽：横屏用更大最小宽度，一屏摆更多 chip。
  double get _optionMinWidth {
    final size = MediaQuery.sizeOf(context);
    return size.width > size.height ? 104 : 84;
  }

  /// 选项区：`Wrap` 自动折行，横竖屏均自适应（0.2.31）。
  Widget _optionWrap({required List<Widget> children, double spacing = 10}) =>
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 20),
        child: Wrap(spacing: spacing, runSpacing: spacing, children: children),
      );

  Future<void> _openSpeedMenu() => _openPanel(() async {
    final value = await showModalBottomSheet<double>(
      context: context,
      useRootNavigator: _sheetUsesRootNavigator,
      backgroundColor: const Color(0xFF191A20),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) => _sheetShell(
        title: '播放倍速',
        // 0.2.31 改版：竖列列表改为 chip 胶囊组，选中项主题色填充。
        child: SingleChildScrollView(
          child: _optionWrap(
            children: [
              for (final speed in playbackSpeeds)
                SizedBox(
                  width: _optionMinWidth,
                  child: _optionChip(
                    key: ValueKey('speed-${speed}x'),
                    label: '${speed}x',
                    selected: speed == _speed,
                    onTap: () => Navigator.pop(context, speed),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
    if (value != null && mounted) await _setSpeed(value);
  });

  Future<void> _openQualityMenu() => _openPanel(() async {
    final options = <int>[0, ...?_plan?.qualities];
    final value = await showModalBottomSheet<int>(
      context: context,
      useRootNavigator: _sheetUsesRootNavigator,
      backgroundColor: const Color(0xFF191A20),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) => _sheetShell(
        title: '清晰度',
        // 0.2.31 改版：竖列 → chip 胶囊组。
        child: SingleChildScrollView(
          child: _optionWrap(
            children: [
              for (final option in options)
                SizedBox(
                  width: _optionMinWidth,
                  child: _optionChip(
                    key: ValueKey('quality-$option'),
                    label: option == 0 ? '自动' : '${option}P',
                    selected: option == _quality,
                    onTap: () => Navigator.pop(context, option),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
    if (value != null && mounted) await _setQuality(value);
  });

  /// 加入 / 取消追剧（0.2.26 新增，用户要求）。
  ///
  /// 复用 `store.toggleFavorite`（与详情页、追剧页共用同一份数据），
  /// 不改写现有收藏逻辑（JC-0002）。
  Future<void> _toggleFollow() async {
    final drama = widget.drama;
    final epoch = widget.store.profileEpoch;
    final wasFollowed = _followed;
    // 先本地乐观更新，保证按钮即时响应。
    setState(() => _followed = !wasFollowed);
    _toast(wasFollowed ? '已取消追剧' : '已加入追剧');
    try {
      await widget.store.toggleFavorite(drama);
      if (!mounted) return;
      // 以 store 的真实状态为准（防止并发或未授权站源导致的不一致）。
      final actual = widget.store.isFavorite(drama.id);
      if (actual != _followed) setState(() => _followed = actual);
    } catch (_) {
      if (!mounted) return;
      // 失败时回滚，并给出提示（例如站源未授权）。
      setState(() => _followed = wasFollowed);
      _toast('操作失败，请稍后重试');
    }
    if (epoch != widget.store.profileEpoch) return;
    _refreshFullscreen();
  }

  Future<void> _openEpisodes() => _openPanel(() async {
    // 剧集信息可能尚未就绪（正在解析播放地址），此时给出明确提示而不是静默无反应。
    final detail = _detail;
    if (detail == null || detail.episodes.isEmpty) {
      _toast('剧集信息加载中，请稍候再试');
      return;
    }
    // 打开选集时自动定位到当前正在播放的那一集，
    // 否则长剧每次都要从第 1 集手动往下滚。
    final currentIndex = _episodeIndex.clamp(0, detail.episodes.length - 1);
    // 0.2.31 改版：从"标题列表"改为"数字网格"（每集一个方块，选中项高亮）。
    // 好处：一屏能看更多集、定位当前集更直观；横屏时列数更多、不浪费横向空间。
    final episodes = detail.episodes;
    final columns = _episodeGridColumns;
    // 让网格滚动到当前集附近（网格高度固定，先按行号估算偏移）。
    final gridController = ScrollController();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!gridController.hasClients) return;
      final row = currentIndex ~/ columns;
      const rowExtent = 76.0;
      final target = (row * rowExtent - rowExtent).clamp(
        0.0,
        gridController.position.maxScrollExtent,
      );
      gridController.jumpTo(target);
    });
    final value = await showModalBottomSheet<int>(
      context: context,
      useRootNavigator: _sheetUsesRootNavigator,
      backgroundColor: const Color(0xFF191A20),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) => _sheetShell(
        title: '选集 · 共 ${episodes.length} 集',
        child: SizedBox(
          height: MediaQuery.sizeOf(context).height * .6,
          child: GridView.builder(
            controller: gridController,
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 20),
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: columns,
              mainAxisSpacing: 10,
              crossAxisSpacing: 10,
              childAspectRatio: 1.5,
            ),
            itemCount: episodes.length,
            itemBuilder: (context, index) {
              final selected = index == _episodeIndex;
              const accent = Color(0xFFFF765F);
              return InkWell(
                key: ValueKey('episode-$index'),
                onTap: () => Navigator.pop(context, index),
                borderRadius: BorderRadius.circular(10),
                child: Container(
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: selected ? accent : const Color(0xFF26272F),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: selected ? accent : const Color(0xFF3A3B44),
                    ),
                  ),
                  child: Text(
                    // 方块内只显示集号，避免长标题把方块撑变形。
                    '${episodes[index].number}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: selected ? Colors.white : const Color(0xFFB9B6C2),
                      fontSize: 15,
                      fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
    gridController.dispose();
    if (value != null && mounted) await _playEpisode(value);
  });

  /// 选集网格列数：竖屏 4 列、横屏 8 列（横屏横向空间更大）。
  int get _episodeGridColumns {
    final size = MediaQuery.sizeOf(context);
    if (size.width > size.height) return 8;
    return size.width >= 400 ? 5 : 4;
  }

  void _toast(String message) {
    if (!mounted || _closed) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    messenger?.showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 2)),
    );
  }

  /// 切换横屏 / 竖屏。
  ///
  /// 注意：很多 m3u8 流在首帧前拿不到真实分辨率（videoParams 为空），
  /// 因此这里**不能**因为比例未知就拒绝执行——那样用户会觉得“点了没反应”。
  /// 比例为未知时直接按当前状态切换，拿到比例后再由监听器微调。
  Future<void> _toggleLandscape() async {
    if (_closed) return;
    final next = !_landscape;
    setState(() {
      _landscape = next;
      _controlsVisible = true;
    });
    _showControls();
    if (next) {
      _enterFullscreen();
    } else {
      _exitFullscreen();
    }
    final mobile =
        defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS;
    if (!mobile) return;
    try {
      // 横屏视频在全屏时切到横向；竖屏视频保持竖向，仅隐藏系统栏。
      final wide = _aspectRatio <= 0 || _wideVideo;
      await SystemChrome.setPreferredOrientations(
        next && wide
            ? [
                DeviceOrientation.landscapeLeft,
                DeviceOrientation.landscapeRight,
              ]
            : [DeviceOrientation.portraitUp],
      );
      // 全屏时隐藏状态栏与导航栏（沉浸式），退出时恢复。
      await SystemChrome.setEnabledSystemUIMode(
        next ? SystemUiMode.immersiveSticky : SystemUiMode.edgeToEdge,
      );
    } catch (_) {
      // 个别设备不支持锁定方向，忽略即可。
    }
  }

  /// 进入全屏：push 一个覆盖整个屏幕的全屏**路由**（0.2.28 方案 D）。
  ///
  /// 为什么用路由而不是 `Overlay.insert(OverlayEntry)`：
  /// - 竖滑流外面还套着首页的 AppBar 与 SafeArea，原地改布局无法盖住它们；
  /// - 但 `OverlayEntry` **不属于任何 Navigator 路由**，其中的 `PopScope`
  ///   收不到系统返回键事件 → 0.2.27 的返回键修复**无效**（真机仍回桌面）。
  /// - 改用 `Navigator.push` 一个透明全屏路由后，它位于路由栈中，
  ///   `PopScope` 能正常拦截返回键，实现"返回键 / 按钮 / 手势"都能退出全屏。
  void _enterFullscreen() {
    if (_fullscreenRouteOpen) return;
    final navigator = Navigator.maybeOf(context);
    if (navigator == null) return;
    _fullscreenRouteOpen = true;
    _fullscreenNavigator = navigator;
    navigator
        .push<void>(
          PageRouteBuilder<void>(
            opaque: false,
            barrierDismissible: false,
            barrierColor: Colors.black,
            transitionDuration: const Duration(milliseconds: 150),
            reverseTransitionDuration: const Duration(milliseconds: 150),
            pageBuilder: (_, _, _) => _buildFullscreenLayer(),
            transitionsBuilder: (_, animation, _, child) =>
                FadeTransition(opacity: animation, child: child),
          ),
        )
        .whenComplete(() {
          // 路由被任何方式关闭后统一复位（含返回键、手势返回）。
          _fullscreenNavigator = null;
          // 0.7.9 修复（真机反馈"退出全屏不恢复亮度，切视频才恢复"）：
          // 全屏路由可能被**返回键 / 手势**关闭，这条路不经过 `_exitFullscreen()`，
          // 之前只在 `_exitFullscreen()` 里恢复亮度 → 漏掉返回键路径。
          // 这里兜底：无论怎么关的，都恢复"跟随系统"。
          unawaited(ScreenBrightness.reset());
          if (!mounted || _closed) return;
          if (!_fullscreenRouteOpen) return;
          _fullscreenRouteOpen = false;
          if (_landscape) {
            // 返回键关闭时，状态位还没复位（因为没走 _toggleLandscape），
            // 这里统一收尾：恢复竖屏与系统栏。
            setState(() {
              _landscape = false;
              _controlsVisible = true;
            });
            unawaited(_restorePortraitSystemUi());
          }
        });
  }

  /// 退出全屏：关闭全屏路由。
  void _exitFullscreen() {
    if (!_fullscreenRouteOpen) return;
    _fullscreenRouteOpen = false;
    // 0.7.8：退出全屏即恢复窗口亮度为"跟随系统"，避免整个 App 一直停在调过的亮度。
    unawaited(ScreenBrightness.reset());
    final navigator = _fullscreenNavigator ?? Navigator.maybeOf(context);
    if (navigator != null && navigator.canPop()) navigator.pop();
  }

  /// 恢复竖屏方向与系统栏（退出全屏收尾）。
  Future<void> _restorePortraitSystemUi() async {
    final mobile =
        defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS;
    if (!mobile) return;
    try {
      await SystemChrome.setPreferredOrientations([
        DeviceOrientation.portraitUp,
      ]);
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    } catch (_) {
      // 个别设备不支持锁定方向，忽略即可。
    }
  }

  // ===== 全屏横屏分区手势（0.7.2，XQ-0105）=====
  //
  // 竖屏手势**完全不变**（任意位置上下滑切集）；这里只接管全屏横屏：
  // - 左右滑：调整进度（整屏宽度 = 90 秒，松手生效）；
  // - 左侧 1/3 上下滑：画面亮度；
  // - 右侧 1/3 上下滑：应用内音量；
  // - 中间 1/3 上下滑：上一集 / 下一集（沿用原有语义）。
  //
  // 长按 3 倍速、双击暂停、单击显隐仍由 `PlayerInteractions` 负责，
  // 因此这里仍然调用它的 pointerDown/Move/Up；只是**禁用它的上下滑切集**
  // （`swipeEnabled: false`），避免一次滑动被执行两遍。

  /// 整屏宽度对应的快进/快退秒数。
  static const double _fsSeekSecondsPerWidth = 90;

  int? _fsPointer;
  Offset? _fsOrigin;
  Offset? _fsLast;
  bool _fsMoved = false;
  bool _fsGuarded = false;
  Duration _fsDownAt = Duration.zero;

  /// 亮度手势起点（0.7.8，按当前窗口亮度固定）。
  double _fsStartBrightRatio = .5;

  /// 音量手势的起点比例（0.7.6）——按下时的系统音量，避免拖动中反复重算基准。
  double _fsStartSystemRatio = 0;
  Duration _fsStartPosition = Duration.zero;
  Duration? _fsSeekTarget;
  _FsGesture _fsGesture = _FsGesture.none;

  void _fsPointerDown(PointerDownEvent event, Size size) {
    _interactions?.pointerDown(event, swipeEnabled: false, height: size.height);
    if (event.buttons != kPrimaryButton) return;
    if (_fsPointer != null) return;
    _fsPointer = event.pointer;
    _fsOrigin = _fsLast = event.localPosition;
    _fsMoved = false;
    _fsGuarded =
        event.localPosition.dy < PlayerInteractions.topGestureGuard;
    _fsDownAt = event.timeStamp;
    _fsGesture = _FsGesture.none;
    _fsSeekTarget = null;
    _fsStartBrightRatio = _screenBrightnessRatio;
    unawaited(_syncScreenBrightness());
    final player = _player;
    _fsStartPosition = player?.state.position ?? Duration.zero;
    // 0.7.5（XQ-0108/0109）：清进度预览，并把系统媒体音量同步为起点
    // （用户要求"先同步系统音量，再在此基础上调整"）。
    // 0.7.6：起点比例用**当前缓存值**立即固定，避免拖动中反复重算基准。
    _fsStartSystemRatio = _systemVolumeMax <= 0
        ? 0.5
        : _systemVolumeIndex / _systemVolumeMax;
    _seekPreview.value = null;
    unawaited(_syncSystemVolume());
  }

  /// 读取系统媒体音量并缓存（0.7.5）。
  Future<void> _syncSystemVolume() async {
    final volume = await SystemVolume.read();
    if (volume == null || _closed) return;
    _systemVolumeIndex = volume.current;
    _systemVolumeMax = volume.max;
  }

  void _fsPointerMove(PointerMoveEvent event, Size size) {
    _interactions?.pointerMove(event);
    if (_fsPointer != event.pointer || _fsOrigin == null || _fsGuarded) return;
    _fsLast = event.localPosition;
    final delta = event.localPosition - _fsOrigin!;
    if (!_fsMoved) {
      if (delta.distance <= 12) return;
      _fsMoved = true;
    }
    if (_fsGesture == _FsGesture.none) {
      // 0.7.9 修复（真机反馈"竖屏的全屏还有左右亮度音量"）：
      // 之前用 `_landscape` 判断分区，但**竖屏视频**全屏时 `_toggleLandscape`
      // 锁的是 `portraitUp`（屏幕仍是竖的），`_landscape` 却为 true →
      // 竖屏全屏照样分区。这里改为按**实际屏幕宽高**判断：
      // 宽 > 高（真横屏）才分区；竖屏全屏只保留进度与上下滑切集/切部。
      _fsGesture = delta.dx.abs() > delta.dy.abs()
          ? _FsGesture.seek
          : (size.width > size.height
                ? _fsVerticalZone(_fsOrigin!.dx, size.width)
                : _FsGesture.episode);
    }
    switch (_fsGesture) {
      case _FsGesture.seek:
        final player = _player;
        if (player == null || player.state.duration <= Duration.zero) return;
        final seconds = delta.dx / size.width * _fsSeekSecondsPerWidth;
        final raw =
            _fsStartPosition +
            Duration(milliseconds: (seconds * 1000).round());
        final target = Duration(
          milliseconds: raw.inMilliseconds.clamp(
            0,
            player.state.duration.inMilliseconds,
          ),
        );
        _fsSeekTarget = target;
        // 0.7.5（XQ-0108）：拖动过程中让进度条跟手（只重建进度条）。
        _seekPreview.value = target.inMilliseconds / 1000;
        _interactions?.hint(
          '${seconds >= 0 ? '快进至' : '后退至'} ${formatPosition(target.inSeconds.toDouble())}',
        );
      case _FsGesture.brightness:
        // 0.7.8（XQ-0114）：改为调**窗口亮度**（覆盖系统亮度，系统暗也能拉亮）。
        // 灵敏度与音量一致（1.6 屏高走完），并以按下时的亮度为起点。
        final ratio = (_fsStartBrightRatio - delta.dy / (size.height * 1.6))
            .clamp(_minBrightness, 1.0);
        if ((ratio - _screenBrightnessRatio).abs() >= 0.01) {
          _setBrightness(ratio);
        }
      case _FsGesture.volume:
        // 0.7.5（XQ-0109）：直接调**系统媒体音量**，不再叠一层应用内音量。
        //
        // 0.7.6（用户反馈"滑一点就调太多"）：灵敏度从"0.7 屏高走完"降到
        // **1.6 屏高走完**（约 2.3 倍更细），以按下时的档位为起点计算。
        final max = _systemVolumeMax <= 0 ? 15 : _systemVolumeMax;
        final ratio = (_fsStartSystemRatio - delta.dy / (size.height * 1.6))
            .clamp(0.0, 1.0);
        final index = (ratio * max).round();
        if (index != _systemVolumeIndex) {
          _systemVolumeIndex = index;
          unawaited(SystemVolume.write(index));
        }
        _interactions?.hint(
          index <= 0 ? '已静音' : '音量 ${(ratio * 100).round()}%',
        );
      case _FsGesture.episode:
      case _FsGesture.none:
        break;
    }
  }

  void _fsPointerUp(PointerUpEvent event, Size size) {
    _interactions?.pointerUp(event);
    if (_fsPointer != event.pointer) return;
    final origin = _fsOrigin;
    final last = _fsLast ?? event.localPosition;
    final gesture = _fsGesture;
    final moved = _fsMoved;
    final guarded = _fsGuarded;
    final target = _fsSeekTarget;
    final downAt = _fsDownAt;
    _fsPointer = null;
    _fsOrigin = null;
    _fsLast = null;
    _fsMoved = false;
    _fsGuarded = false;
    _fsGesture = _FsGesture.none;
    _fsSeekTarget = null;
    if (origin == null || guarded) return;
    // 滑动后抑制紧随其后的单击，避免"滑完又弹出控件"。
    if (moved) _interactions?.blockTap();
    final delta = last - origin;
    switch (gesture) {
      case _FsGesture.seek:
        // 0.7.5（XQ-0108）：松手清掉预览，再真正跳转。
        _seekPreview.value = null;
        final player = _player;
        if (target == null || player == null) return;
        if (player.state.duration <= Duration.zero) return;
        unawaited(player.seek(target));
        _showControls();
      case _FsGesture.episode:
        final threshold = math.max(56.0, math.min(100.0, size.height * .1));
        if (delta.dy.abs() < threshold) return;
        if (delta.dy.abs() <= delta.dx.abs() * 1.5) return;
        if (event.timeStamp - downAt > const Duration(milliseconds: 1500)) {
          return;
        }
        final message = _swipeEpisode(delta.dy < 0 ? 1 : -1);
        if (message.isNotEmpty) _interactions?.hint(message);
      case _FsGesture.brightness:
      case _FsGesture.volume:
      case _FsGesture.none:
        return;
    }
  }

  void _fsPointerCancel(PointerCancelEvent event) {
    _interactions?.pointerCancel(event);
    _fsPointer = null;
    _fsOrigin = null;
    _fsLast = null;
    _fsMoved = false;
    _fsGuarded = false;
    _fsGesture = _FsGesture.none;
    _fsSeekTarget = null;
    _seekPreview.value = null;
  }

  _FsGesture _fsVerticalZone(double x, double width) {
    // 0.7.6（用户反馈"左右两侧区域太大"）：各占 1/4，中间切集区占一半。
    if (x < width / 4) return _FsGesture.brightness;
    if (x > width * 3 / 4) return _FsGesture.volume;
    return _FsGesture.episode;
  }

  void _setBrightness(double value) {
    _screenBrightnessRatio = value;
    unawaited(ScreenBrightness.set(value));
    _interactions?.hint('亮度 ${(value * 100).round()}%');
  }

  /// 读取系统当前亮度并缓存（0.7.8）——用于手势起点。
  Future<void> _syncScreenBrightness() async {
    final value = await ScreenBrightness.read();
    if (value == null || _closed) return;
    _screenBrightnessRatio = value.clamp(_minBrightness, 1.0);
  }

  // ===== 竖屏水平滑调进度（0.7.5，XQ-0108）=====
  //
  // 竖屏没有左右方向的手势占用（翻页是上下滑），因此可以在同一层叠加：
  // 水平主导 → 调进度；竖直主导 → 仍交给 `PlayerInteractions` 切集/翻页。
  double? _hOriginY;

  void _hPointerDown(PointerDownEvent event) {
    if (event.buttons != kPrimaryButton || _hPointer != null) return;
    _hPointer = event.pointer;
    _hOriginX = event.localPosition.dx;
    _hOriginY = event.localPosition.dy;
    _hStart = _player?.state.position ?? Duration.zero;
    _hTarget = null;
    _seekPreview.value = null;
  }

  void _hPointerMove(PointerMoveEvent event, double width) {
    if (_hPointer != event.pointer || _hOriginX == null) return;
    final player = _player;
    if (player == null || player.state.duration <= Duration.zero) return;
    final dx = event.localPosition.dx - _hOriginX!;
    final dy = event.localPosition.dy - (_hOriginY ?? event.localPosition.dy);
    // 只在明确"水平主导"时才接管，避免和上下滑切集抢手势。
    // 0.7.10：起点从 24 降到 12——水平识别器（阈值 6）赢下竞技场后，
    // 必须保证这里也会开始调进度，否则小幅度滑动会"既没进度也没翻页"。
    if (dx.abs() < 12 || dx.abs() <= dy.abs() * 1.2) return;
    final seconds = dx / width * _fsSeekSecondsPerWidth;
    final target = Duration(
      milliseconds:
          (_hStart + Duration(milliseconds: (seconds * 1000).round()))
              .inMilliseconds
              .clamp(0, player.state.duration.inMilliseconds),
    );
    _hTarget = target;
    _seekPreview.value = target.inMilliseconds / 1000;
    _interactions?.hint(
      '${seconds >= 0 ? '快进至' : '后退至'} ${formatPosition(target.inSeconds.toDouble())}',
    );
  }

  void _hPointerUp(PointerUpEvent event) {
    if (_hPointer != event.pointer) return;
    final target = _hTarget;
    _hPointer = null;
    _hOriginX = null;
    _hOriginY = null;
    _hTarget = null;
    _seekPreview.value = null;
    final player = _player;
    if (target == null || player == null) return;
    if (player.state.duration <= Duration.zero) return;
    unawaited(player.seek(target));
    _showControls();
  }

  void _hPointerCancel() {
    _hPointer = null;
    _hOriginX = null;
    _hOriginY = null;
    _hTarget = null;
    _seekPreview.value = null;
  }

  /// 全屏层内容：视频铺满 + 手势 + 可自动隐藏的简洁控件。
  ///
  /// 0.2.28（方案 D）：本层现在是**全屏路由的内容**（不是 OverlayEntry），
  /// 位于 Navigator 路由栈中，因此 `PopScope` 能正常拦截系统返回键。
  /// 按住返回键时：`canPop: true` → 由 `onPopInvokedWithResult` 里
  /// 调用 `_exitFullscreen()` 关闭路由，并复位方向与系统栏。
  Widget _buildFullscreenLayer() {
    return PopScope<void>(
      canPop: true,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) return;
        // 系统返回键关闭全屏路由：同步复位状态位与方向/系统栏。
        _fullscreenRouteOpen = false;
        // 0.7.9：返回键退出全屏也必须恢复亮度（此前漏了这一步，
        // 导致只有切视频时才恢复）。
        unawaited(ScreenBrightness.reset());
        if (_landscape && mounted && !_closed) {
          setState(() {
            _landscape = false;
            _controlsVisible = true;
          });
          unawaited(_restorePortraitSystemUi());
        }
      },
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: ValueListenableBuilder<int>(
          valueListenable: _fullscreenRevision,
          builder: (context, _, _) {
            final video = _video;
            final state = _player?.state;
            final duration = state?.duration.inMilliseconds ?? 0;
            final position = state?.position.inMilliseconds ?? 0;
            final buffered = state?.buffer.inMilliseconds ?? 0;
            final total = duration > 0 ? duration / 1000 : 1.0;
            // 加速中只留中央提示，隐藏整套控件（与竖滑流主层保持一致）。
            final boosting = _interactions?.boosting ?? false;
            final controlsVisible =
                !boosting &&
                // 0.7.2（XQ-0104）：自动连播换集期间不弹进度条与按钮。
                !_autoAdvancing &&
                (_controlsVisible || !(state?.playing ?? false) || _loading);
            return Material(
              // 全屏路由已脱离竖滑页所在的主题树（push 到 Navigator 之上），
              // 因此这里必须显式给出深色主题，否则滑块会退回默认样式
              // （横杆变成居中圆盘，表现为"进度条跑到中间"）。
              color: Colors.black,
              child: Theme(
                data: _fullscreenTheme,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    if (video != null)
                      _applyBrightness(
                        Video(
                          controller: video,
                          controls: (_) => const SizedBox.shrink(),
                          // 全屏时铺满整个屏幕。
                          fit: BoxFit.contain,
                        ),
                      )
                    else
                      const ColoredBox(color: Colors.black),
                    // 手势层（0.7.2，XQ-0105）：全屏横屏按左右分区处理
                    // 进度 / 亮度 / 音量 / 切集；单击显隐、双击暂停仍在这里。
                    Positioned.fill(
                      child: Listener(
                        behavior: HitTestBehavior.opaque,
                        onPointerDown: (event) =>
                            _fsPointerDown(event, MediaQuery.sizeOf(context)),
                        onPointerMove: (event) =>
                            _fsPointerMove(event, MediaQuery.sizeOf(context)),
                        onPointerUp: (event) =>
                            _fsPointerUp(event, MediaQuery.sizeOf(context)),
                        onPointerCancel: _fsPointerCancel,
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: _tap,
                          onDoubleTap: _togglePlayback,
                          // 0.7.9 修复（真机反馈"左右滑调进度时播放器会上下动"）：
                          // `Listener` 不参与手势竞技场，下层 PageView 的纵向拖动
                          // 仍能识别到手指的垂直分量 → 进度条在动、页面也在翻。
                          // 这里显式声明两个方向的拖动，让本层赢下竞技场，
                          // 下层 PageView 就收不到这次拖动。
                          onHorizontalDragStart: (_) {},
                          onHorizontalDragUpdate: (_) {},
                          onHorizontalDragEnd: (_) {},
                          onVerticalDragStart: (_) {},
                          onVerticalDragUpdate: (_) {},
                          onVerticalDragEnd: (_) {},
                        ),
                      ),
                    ),
                    // 与竖屏主层保持一致（0.6.11）：补上"已就绪但无画面"的兜底，
                    // 避免全屏时出现纯黑无文字。
                    if (_loading ||
                        (_awaitingFirstFrame && !(_player?.state.playing ?? false)) ||
                        // 0.7.13：改为判断"是否出过画面"。此前看 `width <= 0`，
                        // 而部分流始终不报宽高 → 正常播放时提示也一直挂着。
                        (!_userPaused && _ready && _error == null && !_hasVideoFrame))
                      const IgnorePointer(
                        child: LoadingHint(message: '正在加载视频…', dark: true),
                      )
                    else if (_error != null)
                      Center(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                _error!,
                                textAlign: TextAlign.center,
                                style: const TextStyle(color: Colors.white70),
                              ),
                              const SizedBox(height: 12),
                              OutlinedButton(
                                onPressed: () {
                                  _ready = false;
                                  // 0.3.5：播放器已释放时先重建再加载，避免在已释放实例上操作。
                                  unawaited(
                                    _playerReleased
                                        ? _resumeAfterRelease()
                                        : _prepare(force: true),
                                  );
                                },
                                child: const Text('重试'),
                              ),
                            ],
                          ),
                        ),
                      ),
                    // 0.7.2（XQ-0103）：全屏左上角**常显**集数标识。
                    // 用户明确要求"一直显示"，因此放在控件层之外，
                    // 不受 `controlsVisible` 影响；单集剧仍不显示（与竖屏判据一致）。
                    if (_hasEpisodeBadge)
                      IgnorePointer(
                        child: _episodeBadge(
                          textKey: const ValueKey(
                            'fullscreen-episode-badge',
                          ),
                        ),
                      ),
                    // 控件层：自动隐藏。
                    IgnorePointer(
                      ignoring: !controlsVisible,
                      child: AnimatedOpacity(
                        opacity: controlsVisible ? 1 : 0,
                        duration: const Duration(milliseconds: 180),
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            const IgnorePointer(
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  gradient: LinearGradient(
                                    begin: Alignment.topCenter,
                                    end: Alignment.bottomCenter,
                                    colors: [
                                      Color(0x99000000),
                                      Colors.transparent,
                                      Color(0xDD000000),
                                    ],
                                    stops: [0, .45, 1],
                                  ),
                                ),
                              ),
                            ),
                            // 中央：播放/暂停。
                            if (!(state?.playing ?? false) &&
                                !_loading &&
                                _error == null)
                              Center(
                                child: IconButton.filledTonal(
                                  tooltip: '播放',
                                  iconSize: 52,
                                  onPressed: _togglePlayback,
                                  icon: const Icon(Icons.play_arrow_rounded),
                                ),
                              ),
                            // 底部：进度条 + 时间。
                            //
                            // 0.2.26 修正：原先用 `Align(bottomCenter)`，
                            // 在实际全屏 Overlay 环境下受 `SafeArea`/`MediaQuery`
                            // 影响，进度条会被错误地居中/铺满，且触摸热区异常扩大，
                            // 表现为"屏幕任何位置都只能调节进度条"。
                            // 改为 `Positioned` 明确固定在底部，并限定高度，
                            // 让进度条只占底部一条，其余区域照常响应单击/长按/双击。
                            Positioned(
                              left: 0,
                              right: 0,
                              bottom: 0,
                              child: SafeArea(
                                top: false,
                                child: Padding(
                                  padding: const EdgeInsets.fromLTRB(
                                    16,
                                    0,
                                    16,
                                    8,
                                  ),
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      ValueListenableBuilder<double?>(
                                        valueListenable: _seekPreview,
                                        builder: (context, preview, _) => Row(
                                        children: [
                                          IconButton(
                                            key: const ValueKey(
                                              'fullscreen-play-toggle',
                                            ),
                                            tooltip: (state?.playing ?? false)
                                                ? '暂停'
                                                : '播放',
                                            onPressed: _togglePlayback,
                                            icon: Icon(
                                              (state?.playing ?? false)
                                                  ? Icons.pause_rounded
                                                  : Icons.play_arrow_rounded,
                                              color: Colors.white,
                                            ),
                                          ),
                                          Text(
                                            '${formatPosition(((preview ?? _seekValue) ?? position / 1000))} / ${formatPosition(duration / 1000)}',
                                            style: const TextStyle(
                                              color: Colors.white70,
                                              fontSize: 12,
                                            ),
                                          ),
                                          Expanded(
                                            child: SizedBox(
                                              height: 32,
                                              child: SliderTheme(
                                                data: fullscreenSliderTheme,
                                                child: Slider(
                                                  key: const ValueKey(
                                                    'fullscreen-progress',
                                                  ),
                                                  value:
                                                      ((preview ?? _seekValue) ??
                                                              position / 1000)
                                                          .clamp(0, total),
                                                  max: total,
                                                  secondaryTrackValue:
                                                      (buffered / 1000).clamp(
                                                        0,
                                                        total,
                                                      ),
                                                  onChangeStart: duration > 0
                                                      ? (_) {
                                                          _interactions
                                                              ?.cancel();
                                                          _hideTimer?.cancel();
                                                        }
                                                      : null,
                                                  onChanged: duration <= 0
                                                      ? null
                                                      : (value) {
                                                          _hideTimer?.cancel();
                                                          setState(
                                                            () => _seekValue =
                                                                value,
                                                          );
                                                        },
                                                  onChangeEnd: (value) {
                                                    if (duration > 0) {
                                                      unawaited(
                                                        _seekTo(
                                                          Duration(
                                                            milliseconds:
                                                                (value * 1000)
                                                                    .round(),
                                                          ),
                                                        ),
                                                      );
                                                    }
                                                    setState(
                                                      () => _seekValue = null,
                                                    );
                                                    _showControls();
                                                  },
                                                ),
                                              ),
                                            ),
                                          ),
                                          IconButton(
                                            key: const ValueKey(
                                              'fullscreen-exit',
                                            ),
                                            tooltip: '退出全屏',
                                            onPressed: _toggleLandscape,
                                            icon: const Icon(
                                              Icons.fullscreen_exit_rounded,
                                              color: Colors.white,
                                            ),
                                          ),
                                        ],
                                      ),
                                      ),
                                      Row(
                                        mainAxisAlignment:
                                            MainAxisAlignment.spaceEvenly,
                                        children: [
                                          _sideButton(
                                            key: const ValueKey(
                                              'fullscreen-speed',
                                            ),
                                            icon: Icons.speed_rounded,
                                            label: '${_speed}x',
                                            onPressed: _openSpeedMenu,
                                          ),
                                          _sideButton(
                                            key: const ValueKey(
                                              'fullscreen-quality',
                                            ),
                                            icon: Icons.hd_rounded,
                                            label: _qualityLabel,
                                            onPressed: _openQualityMenu,
                                          ),
                                          _sideButton(
                                            key: const ValueKey(
                                              'fullscreen-episodes',
                                            ),
                                            icon: Icons.grid_view_rounded,
                                            label: '选集',
                                            onPressed: _openEpisodes,
                                          ),
                                          _sideButton(
                                            key: const ValueKey(
                                              'fullscreen-follow',
                                            ),
                                            icon: _followed
                                                ? Icons.bookmark_rounded
                                                : Icons.bookmark_border_rounded,
                                            label: _followed ? '已追剧' : '追剧',
                                            onPressed: _toggleFollow,
                                          ),
                                          if (!widget.singleDrama)
                                            _sideButton(
                                              key: const ValueKey(
                                                'fullscreen-auto-next',
                                              ),
                                              icon: widget.autoNextEpisode
                                                  ? Icons.repeat_one_rounded
                                                  : Icons.skip_next_rounded,
                                              label: widget.autoNextEpisode
                                                  ? '连播本剧'
                                                  : '连播下一部',
                                              color: widget.autoNextEpisode
                                                  ? const Color(0xFFFF765F)
                                                  : Colors.white,
                                              onPressed:
                                                  widget.onToggleAutoNext,
                                            ),
                                        ],
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    // 长按加速提示（0.6.6 新增，用户反馈"**全屏横屏不显示这个悬浮窗**"）。
                    //
                    // 此前该提示**只在竖屏主层渲染**，全屏层（独立路由）完全没有，
                    // 于是横屏长按加速时看不到任何提示。
                    // 这里复用竖屏同一份 UI（`_boostHintText` + 相同样式），
                    // 保证两处外观与行为一致，避免以后改一处漏一处。
                    if (_interactions != null)
                      AnimatedBuilder(
                        animation: _interactions!,
                        builder: (context, _) {
                          final feedback = _interactions!.feedback;
                          if (feedback.isEmpty) return const SizedBox.shrink();
                          return IgnorePointer(
                            child: Align(
                              alignment: const Alignment(0, -.5),
                              child: Container(
                                margin: const EdgeInsets.all(16),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 16,
                                  vertical: 10,
                                ),
                                decoration: BoxDecoration(
                                  color: Colors.black.withValues(alpha: .22),
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                child: _boostHintText(feedback),
                              ),
                            ),
                          );
                        },
                      ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  /// 全屏层专用主题。
  ///
  /// 全屏层挂在 **root Overlay** 上，已脱离竖滑页所在的 Widget 树，
  /// `Theme.of(context)` / `SliderTheme.of(context)` 拿不到页面主题，
  /// 滑块会退回 Flutter 默认样式（横杆 + 大圆盘），表现为"进度条跑到中间"。
  /// 这里显式给一份深色主题，保证样式与竖滑流一致。
  static final ThemeData _fullscreenTheme = ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    colorScheme: const ColorScheme.dark(
      primary: Color(0xFFFF765F),
      surface: Colors.black,
      onSurface: Colors.white,
      onSurfaceVariant: Color(0xFFB9B6C2),
    ),
    iconTheme: const IconThemeData(color: Colors.white),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(foregroundColor: Colors.white),
    ),
    sliderTheme: fullscreenSliderTheme,
  );

  /// 全屏进度条样式：细横杆 + 小圆点，不用默认的大圆盘。
  static final SliderThemeData fullscreenSliderTheme = SliderThemeData(
    trackHeight: 3,
    activeTrackColor: const Color(0xFFFF765F),
    inactiveTrackColor: Colors.white24,
    secondaryActiveTrackColor: Colors.white38,
    thumbColor: const Color(0xFFFF765F),
    overlayColor: const Color(0x33FF765F),
    thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
    overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
    trackShape: const RectangularSliderTrackShape(),
  );

  /// 让全屏层重建（状态变化时调用）。
  ///
  /// 节流到 250ms（0.3.1 性能修复）：全屏层内容较重（进度条 + 选集），
  /// 而 position 流每秒推送多次，每次都整层重建会造成明显掉帧。
  /// [immediate] 为 true 时跳过节流，用于用户操作（切集、暂停等）需要立刻反馈的场景。
  void _refreshFullscreen({bool immediate = false}) {
    if (!_fullscreenRouteOpen) return;
    final now = DateTime.now();
    if (!immediate &&
        now.difference(_lastFullscreenRefresh) <
            const Duration(milliseconds: 250)) {
      return;
    }
    _lastFullscreenRefresh = now;
    _fullscreenRevision.value++;
  }

  @override
  Widget build(BuildContext context) {
    final video = _video;
    final state = _player?.state;
    // 长按加速（3 倍速）期间只保留中央的加速提示，
    // 必须把完整控件层（进度条 + 剧名 + 简介 + 按钮）整体隐藏，
    // 否则加速时这些信息会盖住画面。
    final boosting = _interactions?.boosting ?? false;
    final visible =
        !boosting &&
        // 0.7.5：**非全屏（竖屏）连播保留控件显示**（用户明确要求），
        // 静默只在全屏层生效（见全屏 `controlsVisible` 的 `!_autoAdvancing`）。
        (_controlsVisible ||
            _panelOpen ||
            _loading ||
            _error != null ||
            !(state?.playing ?? false));
    return Stack(
      fit: StackFit.expand,
      children: [
        if (widget.videoBuilder != null)
          // 测试注入的视频层：不依赖原生视频控制器。
          widget.videoBuilder!(const SizedBox.shrink())
        else if (video != null && !_landscape)
          _applyBrightness(
            Video(
              controller: video,
              controls: (_) => const SizedBox.shrink(),
              fit: BoxFit.contain,
            ),
          )
        else if (_landscape)
          // 全屏时画面由全屏层渲染，这里留黑避免同一路视频被渲染两次。
          const ColoredBox(color: Colors.black)
        else
          const ColoredBox(color: Colors.black),
        // 手势层：单击显隐控件，双击暂停，长按 3 倍速，上下滑切集；
        // 0.7.5（XQ-0108）：水平滑调进度（与上下滑互斥判定）。
        Positioned.fill(
          child: Listener(
            behavior: HitTestBehavior.opaque,
            onPointerDown: (event) {
              _interactions?.pointerDown(
                event,
                // 0.2.31：启用上下滑切集（方案 B：只切集、不切剧）。
                //
                // 0.7.14（XQ-0123）：连播本剧的竖滑改由父级"跟手滑动动画"
                // 统一处理，这里必须关掉，否则一次上滑会被两个入口各切一次
                // （动画结束后再切一集）。其余模式照旧。
                swipeEnabled: !widget.autoNextEpisode,
                height: MediaQuery.sizeOf(context).height,
              );
              _hPointerDown(event);
            },
            onPointerMove: (event) {
              _interactions?.pointerMove(event);
              _hPointerMove(event, MediaQuery.sizeOf(context).width);
            },
            onPointerUp: (event) {
              _interactions?.pointerUp(event);
              _hPointerUp(event);
            },
            onPointerCancel: (event) {
              _interactions?.pointerCancel(event);
              _hPointerCancel();
            },
            child: RawGestureDetector(
              behavior: HitTestBehavior.opaque,
              // 0.7.12（XQ-0120）：改用**方向锁定**识别器，不再靠"调阈值"。
              //
              // 历史教训：0.7.9 用默认水平识别器（阈值 18）、0.7.10 降到 6、
              // 0.7.11 把 PageView 阈值提到 36 —— 全都没治本。因为人手"左右滑"
              // 必然带竖直分量，只要竖直位移达到 PageView 的阈值，页面就会跟手。
              //
              // 现在按下后**直接比较两个方向的位移**：
              // - 水平不输（|dx| ≥ 6 且 |dx| ≥ |dy|）→ 立即赢下竞技场，PageView 收不到；
              // - 竖直明显主导（|dy| ≥ 12 且 |dy| > |dx| × 1.2）→ 立即让给 PageView；
              // - 松手时仍未定 → 让给 PageView。
              gestures: <Type, GestureRecognizerFactory>{
                _DirectionalSeekGestureRecognizer:
                    GestureRecognizerFactoryWithHandlers<
                      _DirectionalSeekGestureRecognizer
                    >(() => _DirectionalSeekGestureRecognizer(), (instance) {}),
              },
              // 0.7.12：删掉这里重复的一层 `Listener`（0.7.9 误加）。
              // 它让 `PlayerInteractions.pointerDown` 被调用两次，第二次会
              // 因"指针已登记"而 `cancel()`，把滑动/长按状态自我清空。
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _tap,
                onDoubleTap: _togglePlayback,
              ),
            ),
          ),
        ),
        // 0.6.11 修复（用户反馈"偶发下一个视频黑屏不播放"，且是**纯黑无文字**）：
        //
        // 纯黑无文字意味着**加载提示与错误提示都没渲染**，
        // 即 `_loading == false`、`_awaitingFirstFrame == false`、`_error == null`
        // 三者同时成立，但画面又没出来 —— 这是"中间态漏洞"。
        //
        // 兜底条件补上「已就绪但播放器没有任何画面」：
        // 只要本页已 `_ready`、无错误、且播放器**既没在播也没有可用帧**，
        // 就显示加载提示，绝不让用户面对一块没有任何文字的黑屏。
        if (_loading ||
            (_awaitingFirstFrame && !(state?.playing ?? false)) ||
            // 注意：必须排除 `_userPaused`，否则用户暂停后会错误地显示加载提示。
            // 0.7.13：改为判断"是否出过画面"，不再看 `width <= 0`
            // （部分流始终不报宽高，会让提示在正常播放时一直挂着）。
            (!_userPaused && _ready && _error == null && !_hasVideoFrame))
          const IgnorePointer(
            child: LoadingHint(message: '正在加载视频…', dark: true),
          )
        else if (_error != null)
          Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    _error!,
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white70),
                  ),
                  const SizedBox(height: 12),
                  OutlinedButton(
                    onPressed: () {
                      _ready = false;
                      // 0.3.5：播放器已释放时先重建再加载，避免在已释放实例上操作。
                      unawaited(
                        _playerReleased
                            ? _resumeAfterRelease()
                            : _prepare(force: true),
                      );
                    },
                    child: const Text('重试'),
                  ),
                ],
              ),
            ),
          ),
        // 长按加速提示（独立层）。
        //
        // 0.2.26 修正：原先该提示位于控件层内部，受 `IgnorePointer(ignoring: !visible)`
        // 与 `AnimatedOpacity(opacity: visible ? 1 : 0)` 控制；而加速时 `visible`
        // 恰好为 false（正是为了隐藏进度条/剧名/简介），结果连「3 倍速 · 松开恢复」
        // 也被一并隐藏，用户看到的是"按住后啥也不显示"。
        //
        // 现把它移出控件层、独立渲染，不受控件显隐影响：
        // - 加速中：显示「3 倍速 · 松开恢复」；
        // - 松开后：短暂显示「恢复 X 倍速」（由 PlayerInteractions 的 hint 控制）。
        //
        // 0.6.6 修正（用户反馈"**悬浮窗文字和对比度有问题，看不清字，
        // 然后不透明，会挡住画面**"）：
        // 用户要求是"**我需要能看到后面的画面，字不透明无所谓，
        // 但背景的透明度尽量高一些**"——即**背景要透、字要清楚**。
        // 因此改为：极淡的半透明底 + **高对比度白字 + 深色描边/阴影**。
        // 描边是关键：只靠半透明底，遇到亮画面（雪景、白墙）字会糊掉；
        // 加一圈深色描边后，无论背后是亮是暗都能看清。
        if (_interactions != null)
          AnimatedBuilder(
            animation: _interactions!,
            builder: (context, _) {
              final feedback = _interactions!.feedback;
              if (feedback.isEmpty) return const SizedBox.shrink();
              return IgnorePointer(
                child: Align(
                  alignment: const Alignment(0, -.5),
                  child: Container(
                    margin: const EdgeInsets.all(16),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 10,
                    ),
                    decoration: BoxDecoration(
                      // 透明度尽量高：仅 22% 黑，基本不挡画面。
                      color: Colors.black.withValues(alpha: .22),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: _boostHintText(feedback),
                  ),
                ),
              );
            },
          ),
        // 控件层。
        IgnorePointer(
          ignoring: !visible,
          child: AnimatedOpacity(
            opacity: visible ? 1 : 0,
            duration: const Duration(milliseconds: 180),
            // 进度条 / 时间 / 暂停按钮跟随 `_tick` 轻量重建（0.3.1）。
            //
            // 整页 setState 已移除（见 _ensurePlayer 的流监听），
            // 这里只重建底部控件子树，避免每秒多次重建整个手势层与选集按钮。
            //
            // 0.6.3 修复（用户反馈"双击恢复后中央图标仍是暂停"）：
            // 本 builder 的闭包**捕获的是外层 build 那一刻的 `state`**，
            // 而 `_tick` 变化只会重跑这里，不会重跑外层 build →
            // 于是这里一直用着过期状态，表现为"视频已在播放、图标却不变"。
            // （实测：推位置到 30s 后进度条仍为 0；单击触发整页 setState 才跳到 5s。）
            // 现在在 builder 内**重新读取实时状态**并遮蔽外层同名变量，
            // 让播放状态、进度、时间都随 `_tick` 真正刷新。
            child: ValueListenableBuilder<int>(
              valueListenable: _tick,
              builder: (context, _, _) {
                final live = _player?.state;
                final state = live;
                final duration = live?.duration.inMilliseconds ?? 0;
                final position = live?.position.inMilliseconds ?? 0;
                final buffered = live?.buffer.inMilliseconds ?? 0;
                final total = duration > 0 ? duration / 1000 : 1.0;
                return Stack(
                fit: StackFit.expand,
                children: [
                  const IgnorePointer(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            Color(0x99000000),
                            Colors.transparent,
                            Color(0xDD000000),
                          ],
                          stops: [0, .45, 1],
                        ),
                      ),
                    ),
                  ),
                  // 左上角集数标签（0.6.2）。
                  //
                  // 只在有多个剧集时显示：单集、本地单文件不显示，
                  // 避免出现"第1集"这种没有信息量的标签。
                  if (_hasEpisodeBadge) _episodeBadge(),
                  // 右上角推送按钮（0.6.4，从老播放器迁移）。
                  //
                  // 位置选择理由：底部按钮行已固定为 5 个等宽槽位
                  // （320 窄屏槽位仅 59.2px，而"连播下一部"标签已 55px），
                  // 再加第 6 个会把标签挤到截断；因此放在视频右上角，
                  // 与左上角集数标签左右对称，也不占用底部功能位。
                  // 位于控件层内 → 跟随控件一起显隐。
                  if (_canPush) _pushButton(),
                  // 暂停时显示中央播放按钮。
                  if (!(state?.playing ?? false) &&
                      !_loading &&
                      _error == null &&
                      !_panelOpen)
                    Center(
                      child: IconButton.filledTonal(
                        tooltip: '播放',
                        iconSize: 42,
                        onPressed: _togglePlayback,
                        icon: const Icon(Icons.play_arrow_rounded),
                      ),
                    ),
                  // 长按加速提示。
                  //
                  // 0.2.26 修正：【已移除】，改到控件层外独立渲染。
                  // 原因：该提示原先在控件层内部，受 `IgnorePointer(ignoring: !visible)`
                  // 控制；而加速时 `visible` 恰好为 false，导致长按加速时
                  // 连「3 倍速 · 松开恢复」都不显示（用户：“按住后啥也不显示”）。
                  // 详见文件下方“长按加速提示（独立层）”块。
                  // 底部区域：左侧信息面板 + 右侧功能按钮。
                  //
                  // 修复「横屏按钮点了没反应」的根因：原先底部面板与右侧按钮组
                  // 是两个独立的 Positioned / Align，面板内容多时（剧名 + 两行简介
                  // + 热度行）会向上撑高，把位于 right:8, bottom:190 的按钮组盖住，
                  // 导致按钮收不到点击（表现为"完全没反应"，连按钮文字都不变）。
                  // 改为同一个 Column 布局后，两者在结构上永不重叠。
                  Align(
                    alignment: Alignment.bottomCenter,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Container(
                          padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
                          decoration: const BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              colors: [Colors.transparent, Colors.black87],
                            ),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              _titleBar(),
                              ValueListenableBuilder<double?>(
                                valueListenable: _seekPreview,
                                builder: (context, preview, _) => Row(
                                children: [
                                  IconButton(
                                    key: const ValueKey('feed-play-toggle'),
                                    tooltip: (state?.playing ?? false)
                                        ? '暂停'
                                        : '播放',
                                    onPressed: _togglePlayback,
                                    icon: Icon(
                                      (state?.playing ?? false)
                                          ? Icons.pause_rounded
                                          : Icons.play_arrow_rounded,
                                      color: Colors.white,
                                    ),
                                  ),
                                  Text(
                                    '${formatPosition(((preview ?? _seekValue) ?? position / 1000))} / ${formatPosition(duration / 1000)}',
                                    style: const TextStyle(
                                      color: Colors.white70,
                                      fontSize: 12,
                                    ),
                                  ),
                                  Expanded(
                                    child: SliderTheme(
                                      data: SliderTheme.of(
                                        context,
                                      ).copyWith(trackHeight: 3),
                                      child: Slider(
                                        key: const ValueKey('feed-progress'),
                                        value:
                                            ((preview ?? _seekValue) ?? position / 1000)
                                                .clamp(0, total),
                                        max: total,
                                        secondaryTrackValue:
                                            (buffered / 1000).clamp(0, total),
                                        semanticFormatterCallback:
                                            formatPosition,
                                        onChangeStart: duration > 0
                                            ? (_) {
                                                _interactions?.cancel();
                                                _hideTimer?.cancel();
                                              }
                                            : null,
                                        onChanged: duration <= 0
                                            ? null
                                            : (value) {
                                                _hideTimer?.cancel();
                                                setState(
                                                  () => _seekValue = value,
                                                );
                                              },
                                        onChangeEnd: (value) {
                                          if (duration > 0) {
                                            unawaited(
                                              _seekTo(
                                                Duration(
                                                  milliseconds: (value * 1000)
                                                      .round(),
                                                ),
                                              ),
                                            );
                                          }
                                          setState(() => _seekValue = null);
                                          _showControls();
                                        },
                                      ),
                                    ),
                                  ),
                                  IconButton(
                                    key: const ValueKey('feed-landscape'),
                                    tooltip: _landscape ? '退出全屏' : '全屏',
                                    onPressed: _toggleLandscape,
                                    icon: Icon(
                                      _landscape
                                          ? Icons.fullscreen_exit_rounded
                                          : Icons.fullscreen_rounded,
                                      color: Colors.white,
                                    ),
                                  ),
                                ],
                              ),
                              ),
                              Row(
                                mainAxisAlignment:
                                    MainAxisAlignment.spaceEvenly,
                                children: [
                                  _sideButton(
                                    key: const ValueKey('feed-speed'),
                                    icon: Icons.speed_rounded,
                                    label: '${_speed}x',
                                    onPressed: _openSpeedMenu,
                                  ),
                                  _sideButton(
                                    key: const ValueKey('feed-quality'),
                                    icon: Icons.hd_rounded,
                                    label: _qualityLabel,
                                    onPressed: _openQualityMenu,
                                  ),
                                  _sideButton(
                                    key: const ValueKey('feed-episodes'),
                                    icon: Icons.grid_view_rounded,
                                    label: '选集',
                                    onPressed: _openEpisodes,
                                  ),
                                  _sideButton(
                                    key: const ValueKey('feed-follow'),
                                    icon: _followed
                                        ? Icons.bookmark_rounded
                                        : Icons.bookmark_border_rounded,
                                    label: _followed ? '已追剧' : '追剧',
                                    onPressed: _toggleFollow,
                                  ),
                                  if (!widget.singleDrama)
                                    _sideButton(
                                      key: const ValueKey('feed-auto-next'),
                                      icon: widget.autoNextEpisode
                                          ? Icons.repeat_one_rounded
                                          : Icons.skip_next_rounded,
                                      label: widget.autoNextEpisode
                                          ? '连播本剧'
                                          : '连播下一部',
                                      color: widget.autoNextEpisode
                                          ? const Color(0xFFFF765F)
                                          : Colors.white,
                                      onPressed: widget.onToggleAutoNext,
                                    ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  ],
                );
              },
            ),
          ),
        ),
      ],
    );
  }

  /// 底部功能按钮（0.6.3：改为等宽，位置固定）。
  ///
  /// 用户反馈："下方 5 个功能按钮位置没固定，切换连播本剧后由于和之前
  /// 连播下一部字数不同，所以 5 个按钮都会轻微挪动位置"。
  ///
  /// 根因：按钮行用 `MainAxisAlignment.spaceEvenly`，它按**每个子项的实际宽度**
  /// 分配剩余空间；"连播下一部"（实测 55px）比"连播本剧"（44px）宽，
  /// 切换时整行重新分配 → 5 个按钮集体位移（实测 1.38 ~ 5.5px）。
  ///
  /// 修法：每个按钮**固定占 1/5 槽位**（`Expanded` + 内容居中），
  /// 与标签文字长短无关，位置恒定；标签仍保留省略号兜底。
  Widget _sideButton({
    required Key key,
    required IconData icon,
    required String label,
    required VoidCallback onPressed,
    Color color = Colors.white,
  }) => Expanded(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          key: key,
          tooltip: label,
          onPressed: onPressed,
          icon: Icon(icon, color: color, size: 24),
        ),
        Text(
          label,
          style: TextStyle(color: color, fontSize: 11),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center,
        ),
      ],
    ),
  );
}


/// 方向锁定手势识别器（0.7.12，`XQ-0120`）。
///
/// 为什么需要它：竖屏竖滑流里，「左右滑调进度」与 `PageView` 的「上下翻页」
/// 天生竞争。靠调阈值治不好——人手横滑必然带竖直分量，竖直位移一达到
/// `PageView` 的阈值，页面就开始跟手。
///
/// 这里改为按下后**比较两个方向的位移**，谁主导就把这次手势判给谁：
///
/// - 水平占优（`|dx| >= 6` 且 `|dx| >= |dy| * 0.7`）→ accept：赢下竞技场，
///   下层 `PageView` 的纵向识别器被淘汰，页面不会跟着动；
/// - 竖直明显主导（`|dy| >= 12` 且 `|dy| > |dx| * 1.2`）→ reject：
///   立即让给 `PageView`，翻页动画与手感完全不受影响；
/// - 松手时仍未判定（例如只是轻点）→ reject。
class _DirectionalSeekGestureRecognizer extends OneSequenceGestureRecognizer {
  int? _pointer;
  Offset _start = Offset.zero;
  bool _decided = false;

  /// 水平方向判定为「主导」的最小位移。
  static const double _horizontalWin = 6;


  @override
  void addAllowedPointer(PointerDownEvent event) {
    _pointer = event.pointer;
    _start = event.position;
    _decided = false;
    startTrackingPointer(event.pointer, event.transform);
  }

  @override
  void handleEvent(PointerEvent event) {
    if (event.pointer != _pointer) return;
    if (event is PointerMoveEvent) {
      if (_decided) return;
      final delta = event.position - _start;
      final dx = delta.dx.abs();
      final dy = delta.dy.abs();
      // 只负责「抢下水平主导」；**不主动 reject**。
      //
      // 为什么不能提前 reject：用户"左右滑"往往先有十几二十像素的竖直位移，
      // 若在 `|dy| >= 12` 就放手，PageView 会立刻接管，页面又开始跟手。
      // 这里保持"观望"——水平位移占优（|dx| >= |dy| * 0.7）就赢；
      // 真正的竖直滑动则由 PageView 在它自己的阈值（60）处接管。
      if (dx >= _horizontalWin && dx >= dy * 0.7) {
        _decided = true;
        resolve(GestureDisposition.accepted);
      }
    } else if (event is PointerUpEvent || event is PointerCancelEvent) {
      if (!_decided) resolve(GestureDisposition.rejected);
      stopTrackingPointer(event.pointer);
      if (event.pointer == _pointer) _pointer = null;
    }
  }

  @override
  void didStopTrackingLastPointer(int pointer) {
    _pointer = null;
    _decided = false;
  }

  @override
  String get debugDescription => 'directionalSeek';
}
