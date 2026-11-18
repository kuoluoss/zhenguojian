import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_layout.dart';
import 'markdown_lite.dart';

/// 应用内更新检查。
///
/// 打开应用时向 GitHub 查询发布仓库的最新 Release 版本号，
/// 若高于当前版本则提示用户，用户点击后下载 APK 并拉起系统安装界面。
///
/// 设计约束（用户明确要求，不扩展）：
/// - 不接第三方推送服务，不做后台保活，不用服务器中转。
/// - 只在打开应用时检查一次。
/// - 网络失败静默跳过，不打扰用户。
/// - 用户选择“稍后”后，当天不再提示。
class AppUpdater {
  AppUpdater._();

  /// 发布仓库（用户自有仓库，README 已标明原作者 Topkill/guoapp3）。
  static const _owner = 'kuoluoss';
  static const _repo = 'zhenguojian';

  /// GitHub API 直连地址（国内可能不通，失败即静默跳过）。
  static const _apiUrl =
      'https://api.github.com/repos/$_owner/$_repo/releases/latest';

  /// Release 页面地址（**不占用 API 额度**，见 [_fetchFromRedirect]）。
  static const _latestPageUrl =
      'https://github.com/$_owner/$_repo/releases/latest';

  /// Release **Atom 订阅源**（0.6.5 新增，用于取更新日志）。
  ///
  /// 为什么用它：`api.github.com` 按 IP 限流（未认证 60 次/小时），
  /// VPN 节点是共享 IP，极易返回 **403**；而版本检测走的 `github.com`
  /// 与取日志走的 `api.github.com` **不是同一条通道**，
  /// 于是出现"能检测到新版本、但更新日志始终为空"。
  ///
  /// 实测（2026-10-14）：`releases.atom` 走系统代理 **1 秒**返回，
  /// 且 `<content type="html">` 里**直接含完整日志正文**，
  /// **完全不依赖 API 额度**。
  static const _atomUrl =
      'https://github.com/$_owner/$_repo/releases.atom';

  /// 下载加速镜像前缀（用于 APK 下载兜底，实测可用）。
  static const _mirrorPrefix = 'https://ghfast.top/';

  /// **API 代理**前缀（用于 API 兜底）。
  ///
  /// 注意：`ghfast.top` **只代理文件下载，不支持 GitHub API**
  /// （对 `api.github.com` 返回 403 `Invalid input.`，2026-10-13 实测），
  /// 因此 API 兜底必须用 `gh-proxy.com`（实测对 API 返回 200 且 JSON 可解析）。
  static const _apiProxyPrefix = 'https://gh-proxy.com/';

  /// 上一次检查失败的**用户可见原因**（供 UI 提示，空串表示无）。
  ///
  /// 0.5.1 新增：此前任何失败都被静默忽略，用户只看到"检查失败"，
  /// 无法区分"网络不通"与"GitHub 限流"。现在区分后给出可操作的提示。
  static String lastFailureReason = '';

  /// 记录用户点击“稍后”的日期，格式 yyyy-MM-dd。
  static const _snoozeKey = 'appUpdateSnoozedDate';

  /// 每天最多提示一次，避免反复打扰。
  static Future<bool> _shouldPromptToday() async {
    final preferences = await SharedPreferences.getInstance();
    final today = _today();
    return preferences.getString(_snoozeKey) != today;
  }

  static Future<void> _snoozeToday() async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(_snoozeKey, _today());
  }

  static String _today() {
    final now = DateTime.now();
    final month = now.month.toString().padLeft(2, '0');
    final day = now.day.toString().padLeft(2, '0');
    return '${now.year}-$month-$day';
  }

  /// 仅 Android 支持（Windows 版本次不实现更新）。
  static bool get _supported => Platform.isAndroid;

  /// 应用启动时调用。有新版且今天未提示过时弹出更新对话框。
  static Future<void> checkOnStartup(BuildContext context) async {
    if (!_supported) return;
    if (!await _shouldPromptToday()) return;

    final release = await _fetchLatestRelease();
    if (release == null) return; // 网络失败：静默跳过
    if (!release.isNewerThan(context)) return;
    if (!context.mounted) return;

    await showUpdateDialog(context, release);
  }

  /// 「关于」里手动点「检测新版本」时调用。
  ///
  /// 与启动检查的区别：不读取“今天已提示过”的记录，用户主动触发就必须给结果。
  static Future<void> checkManually(BuildContext context) async {
    if (!_supported) {
      _toast(context, '当前平台暂不支持应用内更新');
      return;
    }
    final progress = ValueNotifier<String>('正在检查更新…');
    if (!context.mounted) return;
    unawaited(
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) => AlertDialog(
          content: Row(
            children: [
              const SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(strokeWidth: 2.5),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: ValueListenableBuilder<String>(
                  valueListenable: progress,
                  builder: (_, value, _) => Text(value),
                ),
              ),
            ],
          ),
        ),
      ),
    );

    final release = await _fetchLatestRelease();
    progress.value = '正在检查更新…';
    if (!context.mounted) return;
    Navigator.of(context, rootNavigator: true).pop(); // 关闭进度框
    if (!context.mounted) return;

    if (release == null) {
      // 0.5.1：区分"限流"与"普通网络失败"，给出可操作的提示。
      _toast(
        context,
        lastFailureReason.isNotEmpty
            ? lastFailureReason
            : '检查失败，请检查网络后重试',
      );
      return;
    }
    if (!release.isNewerThan(context)) {
      final current = AppLayout.versionOf(context);
      _toast(context, '当前已是最新版本（$current）');
      return;
    }
    await showUpdateDialog(context, release);
  }

  /// 查询最新 Release。失败返回 null（调用方静默处理）。
  ///
  /// 0.2.27 修正（用户真机反馈第 4 条："开了 VPN 后无法检查更新"）：
  /// 原来只直连 `api.github.com`，VPN 下常因分流/速度慢而超时，
  /// 表现为"检查不到新版本"。现在改为**多路依次尝试**：
  /// 1. GitHub API 直连；
  /// 2. `ghfast.top` 镜像代理（该镜像此前已在下载 APK 时验证可用）。
  /// 任意一路成功即返回；全部失败才返回 null。
  ///
  /// 0.5.1 修正（用户真机反馈：**开着 VPN 依旧无法检测更新**）：
  /// 定位到两个独立原因，本次一并处理：
  /// 1. **GitHub API 按 IP 限流**（未认证请求每小时 60 次）。VPN 节点是共享 IP，
  ///    额度极易被他人耗尽，返回 **403 `API rate limit exceeded`**（不是超时）。
  ///    旧代码只认 200，403 被静默当失败。
  /// 2. **`ghfast.top` 不支持 API**（对 `api.github.com` 返回 403 `Invalid input.`），
  ///    因此旧代码的"镜像兜底"这一路**从来就没生效过**。
  ///
  /// 新策略（**首选不占 API 额度的路径**）：
  /// 1. **重定向法**：请求 `releases/latest` 页面，读 302 的 `Location`
  ///    得到 tag，再解析 `expanded_assets` 页面拿附件名。**完全不走 API，不受限流**。
  /// 2. API 直连（走系统代理）；
  /// 3. API 代理兜底（`gh-proxy.com`，走系统代理）。
  static Future<AppRelease?> _fetchLatestRelease() async {
    lastFailureReason = '';
    // 读取系统代理（Android：`ConnectivityManager.defaultProxy`）。
    //
    // Dart 的 `HttpClient` **不会自动读取系统代理**：它只认 `findProxy` 或
    // `HTTP_PROXY` 环境变量。而 VPN（Clash 等）在 Android 上设置的是系统代理，
    // `HttpClient` 看不见 → 直连 `api.github.com` 超时 → 表现为"检测不到更新"。
    // 这正是 WT-0028 记录的问题（用户 2026-10-11 曾决定暂缓，2026-10-13 恢复处理）。
    final proxy = await _systemProxy();

    // 第 1 路：重定向法（不占 API 额度，优先）。
    final redirected = await _fetchFromRedirect(proxy);
    if (redirected != null) return redirected;

    // 第 2、3 路：API（直连 + 代理兜底）。
    var rateLimited = false;
    for (final candidate in _apiCandidates(proxy)) {
      final result = await _fetchReleaseFrom(candidate.url, candidate.proxy);
      if (result != null) return result;
      if (_lastStatus == 403) rateLimited = true;
    }
    if (rateLimited) {
      lastFailureReason = 'GitHub 访问受限（该网络出口请求过多），请稍后重试或关闭 VPN 再试';
    }
    return null;
  }

  /// 上一次请求的 HTTP 状态码（0 表示未取到响应）。
  static int _lastStatus = 0;

  /// **重定向法**：不经 API 获取最新 Release。
  ///
  /// 原理：`/releases/latest` 会 302 到 `/releases/tag/<tag>`，
  /// 从 `Location` 头即可拿到版本号；附件名再从
  /// `/releases/expanded_assets/<tag>` 页面解析。
  /// **这两步都不占用 GitHub API 额度**，因此不受共享 IP 限流影响。
  ///
  /// 失败（网络/解析）返回 null，由调用方继续走 API 兜底。
  ///
  /// 0.6.2 补充：本路径原先固定 `notes: ''`，导致**更新日志在应用内不再显示**
  /// （0.5.1 改用它作为首选路径后引入）。现改为在拿到 tag 后
  /// **额外尝试取一次更新日志**（见 [_fetchNotes]）：
  /// 取到就显示，取不到（含被限流）**只影响日志、不影响版本检测**。
  static Future<AppRelease?> _fetchFromRedirect(String? proxy) async {
    final tag = await _resolveLatestTag(proxy);
    if (tag == null) return null;
    final version = _parseVersion(tag);
    if (version == null) return null;
    final apkName = await _resolveAssetName(tag, proxy);
    if (apkName == null) return null;
    return AppRelease(
      version: version,
      tag: tag,
      apkName: apkName,
      // 用 release 的固定下载地址，不依赖 API 返回的 browser_download_url。
      apkUrl: 'https://github.com/$_owner/$_repo/releases/download/$tag/$apkName',
      notes: await _fetchNotes(tag, proxy),
    );
  }

  /// 按 tag 取该 Release 的更新日志。
  ///
  /// 0.6.5 重写（用户反馈"**日志依旧不显示**"，已连续两版未修好）：
  ///
  /// **原先的问题**：只有 API 一条路（直连 + `gh-proxy.com` 兜底），
  /// 而 `api.github.com` 按 IP 限流，VPN 共享 IP 极易 **403**。
  /// 关键点是：**版本检测走 `github.com`、取日志走 `api.github.com`，
  /// 两者不是同一条通道**——所以会出现"能检测到新版本、日志却一直是空的"，
  /// 这也解释了为什么前一版"补取日志"的修复在真机上仍无效。
  ///
  /// **现在的顺序**（都不占 API 额度，API 降为最后兜底）：
  /// 1. **Atom 订阅源**：`releases.atom` 的 `<content type="html">`
  ///    直接含日志正文，实测走代理 1 秒返回；
  /// 2. **Release 网页**：`releases/tag/<tag>` 的 `markdown-body` 区块；
  /// 3. API 直连；4. API 代理兜底。
  ///
  /// 失败处理：任何异常或取不到一律返回空串，
  /// 调用方据此不显示"更新日志"区块，**版本检测结果不受影响**。
  static Future<String> _fetchNotes(String tag, String? proxy) async {
    // 保存并恢复 `_lastStatus`：本方法只是"顺带取日志"，
    // 不应把它的 403 等状态写进调用方的限流判定逻辑。
    final savedStatus = _lastStatus;
    try {
      // 第 1 路：Atom 订阅源（最快、不占额度）。
      final atom = _notesFromAtom(await _get(_atomUrl, proxy), tag);
      if (atom.isNotEmpty) return atom;

      // 第 2 路：Release 网页（同样不占额度）。
      final page = _notesFromPage(
        await _get('https://github.com/$_owner/$_repo/releases/tag/$tag', proxy),
      );
      if (page.isNotEmpty) return page;

      // 第 3、4 路：API（直连 + 代理兜底），会受 IP 限流影响。
      final direct = await _get(_apiTagsUrl(tag), proxy);
      final notes = _notesFrom(direct);
      if (notes.isNotEmpty) return notes;
      final viaProxy = await _get('$_apiProxyPrefix${_apiTagsUrl(tag)}', proxy);
      return _notesFrom(viaProxy);
    } catch (_) {
      return '';
    } finally {
      _lastStatus = savedStatus;
    }
  }

  /// 从 Atom 订阅源里取指定 tag 的日志正文（0.6.5 新增）。
  ///
  /// 结构（实测）：
  /// ```
  /// <entry>
  ///   <link ... href=".../releases/tag/v0.6.4"/>
  ///   <content type="html">&lt;h1&gt;…&lt;/h1&gt;…</content>
  /// </entry>
  /// ```
  /// 正文是 **HTML 转义**过的，需要反转义；再转成 MarkdownLite 认得的
  /// 轻量 Markdown（保留标题、列表、加粗），避免把 HTML 标签当文字显示。
  static String _notesFromAtom(String? body, String tag) {
    if (body == null || body.isEmpty) return '';
    // 按 <entry> 切分，逐条找 href 里含目标 tag 的那条。
    for (final chunk in body.split('<entry>')) {
      if (!chunk.contains('/releases/tag/$tag')) continue;
      final match = RegExp(
        r'<content type="html">([\s\S]*?)</content>',
      ).firstMatch(chunk);
      if (match == null) continue;
      return _htmlToMarkdown(_unescapeHtml(match.group(1)!.trim()));
    }
    return '';
  }

  /// 从 Release 网页里取日志正文（0.6.5 新增）。
  ///
  /// 网页里日志位于 `<div class="markdown-body …">…</div>`；
  /// 取到后同样转成轻量 Markdown。
  static String _notesFromPage(String? body) {
    if (body == null || body.isEmpty) return '';
    final match = RegExp(
      r'<div[^>]*class="[^"]*markdown-body[^"]*"[^>]*>([\s\S]*?)</div>\s*</div>',
    ).firstMatch(body);
    if (match == null) return '';
    return _htmlToMarkdown(match.group(1)!.trim());
  }

  /// 反转义 HTML 实体（`&lt;` → `<` 等）。
  static String _unescapeHtml(String text) => text
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .replaceAll('&apos;', "'")
      .replaceAll('&nbsp;', ' ')
      .replaceAll('&amp;', '&');

  /// 把日志 HTML 转成 MarkdownLite 支持的轻量 Markdown（0.6.5 新增）。
  ///
  /// 只处理日志实际会出现的标签：`h1`~`h3`、`li`、`strong`、`code`、`br`、`p`。
  /// 其余标签直接去掉，避免把 HTML 源码暴露给用户。
  static String _htmlToMarkdown(String html) {
    var text = html;
    // 标题（GitHub 的 h1/h2/h3 对应日志里的 # / ## / ###）。
    for (var level = 1; level <= 3; level++) {
      text = text.replaceAllMapped(
        RegExp('<h$level[^>]*>([\\s\\S]*?)</h$level>'),
        (m) => '\n${'#' * level} ${m.group(1)!.trim()}\n',
      );
    }
    // 无序列表项：统一成 `- `（嵌套缩进保留两级）。
    text = text.replaceAllMapped(
      RegExp(r'<li[^>]*>([\s\S]*?)</li>'),
      (m) => '\n- ${m.group(1)!.trim()}',
    );
    // 加粗与等宽。
    text = text
        .replaceAllMapped(
          RegExp(r'<strong[^>]*>([\s\S]*?)</strong>'),
          (m) => '**${m.group(1)!.trim()}**',
        )
        .replaceAllMapped(
          RegExp(r'<code[^>]*>([\s\S]*?)</code>'),
          (m) => '`${m.group(1)!.trim()}`',
        );
    // 换行与段落。
    text = text.replaceAll(RegExp(r'<br\s*/?>'), '\n');
    text = text.replaceAll(RegExp(r'</p>'), '\n');
    // 去掉剩余标签（ul/ol/div/p/span 等）。
    text = text.replaceAll(RegExp(r'<[^>]+>'), '');
    // 折叠多余空行，去掉行尾空白。
    final lines = text
        .split('\n')
        .map((line) => line.trimRight())
        .toList();
    final out = <String>[];
    var blanks = 0;
    for (final line in lines) {
      if (line.trim().isEmpty) {
        blanks++;
        if (blanks > 1) continue;
      } else {
        blanks = 0;
      }
      out.add(line);
    }
    return out.join('\n').trim();
  }

  /// 指定 tag 的 Release API 地址（形如 `.../releases/tags/v0.6.2`）。
  static String _apiTagsUrl(String tag) =>
      'https://api.github.com/repos/$_owner/$_repo/releases/tags/$tag';

  /// 从 API 返回的 JSON 文本里取 `body`；无法解析返回空串。
  static String _notesFrom(String? body) {
    if (body == null || body.isEmpty) return '';
    try {
      final json = jsonDecode(body);
      if (json is! Map) return '';
      return json['body']?.toString() ?? '';
    } catch (_) {
      return '';
    }
  }

  /// 读 `releases/latest` 的 302 目标，解析出 tag（如 `v0.5.0`）。
  static Future<String?> _resolveLatestTag(String? proxy) async {
    final client = HttpClient();
    _applyProxy(client, proxy);
    client.connectionTimeout = const Duration(seconds: 10);
    try {
      final request = await client.getUrl(Uri.parse(_latestPageUrl));
      request.headers.set(HttpHeaders.userAgentHeader, 'zhenguojian-updater');
      // 手动处理重定向，才能拿到 Location。
      // 注意：`followRedirects` 是 `HttpClientRequest` 的属性，不是 `HttpClient` 的。
      request.followRedirects = false;
      final response = await request.close().timeout(
        const Duration(seconds: 20),
      );
      _lastStatus = response.statusCode;
      // 302/301 时从 Location 取 tag；200 说明已被自动跟随（理论上不会）。
      final location = response.headers.value(HttpHeaders.locationHeader);
      await response.drain<void>();
      if (location == null) return null;
      final match = RegExp(r'/releases/tag/([^/?#]+)').firstMatch(location);
      return match?.group(1);
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  /// 从 `expanded_assets` 页面解析 arm64-v8a 的 APK 文件名。
  static Future<String?> _resolveAssetName(String tag, String? proxy) async {
    final client = HttpClient();
    _applyProxy(client, proxy);
    client.connectionTimeout = const Duration(seconds: 10);
    try {
      final url =
          'https://github.com/$_owner/$_repo/releases/expanded_assets/$tag';
      final request = await client.getUrl(Uri.parse(url));
      request.headers.set(HttpHeaders.userAgentHeader, 'zhenguojian-updater');
      final response = await request.close().timeout(
        const Duration(seconds: 20),
      );
      if (response.statusCode != 200) return null;
      final body = await response.transform(utf8.decoder).join();
      // 页面里含形如 <slug>-0.9.0+81-arm64-v8a.apk 的文件名；按当前版本 slug 匹配，
      // 避免三版本发布后把用户更新成另一个版本（议题 #14）。
      final match = RegExp(
        RegExp.escape(appSlug) + r'-[0-9][0-9.+]*-arm64-v8a\.apk',
      ).firstMatch(body);
      return match?.group(0);
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  /// 更新检查候选地址（API 路径，重定向法失败后才走）。
  ///
  /// 顺序策略：**系统代理存在时优先走代理**（VPN 下直连 GitHub 通常不通），
  /// 其次走 API 代理兜底；无代理时直连优先，保持原有行为不变。
  ///
  /// 0.5.1：兜底由 `ghfast.top` 改为 `gh-proxy.com`——前者**不支持 API**
  /// （对 `api.github.com` 返回 403 `Invalid input.`），旧兜底形同虚设。
  static List<({String url, String? proxy})> _apiCandidates(String? proxy) => [
    (url: _apiUrl, proxy: proxy),
    (url: '$_apiProxyPrefix$_apiUrl', proxy: proxy),
  ];

  /// 读取系统代理，返回 PAC 形式的 `PROXY host:port`；无代理或失败返回 null。
  static Future<String?> _systemProxy() async {
    if (!_supported) return null;
    try {
      final result = await const MethodChannel(
        'duanju/device',
      ).invokeMapMethod<String, dynamic>('systemProxy');
      if (result == null) return null;
      final address = (result['http'] ?? result['https'])?.toString() ?? '';
      return _pacFrom(address);
    } catch (_) {
      return null;
    }
  }

  /// 把 `http://host:port` 转成 `findProxy` 需要的 `PROXY host:port`。
  static String? _pacFrom(String address) {
    final value = address.trim().replaceFirst(
      RegExp(r'^[a-zA-Z][a-zA-Z0-9+.\-]*://'),
      '',
    );
    return value.isEmpty ? null : 'PROXY $value';
  }

  /// 给客户端挂上系统代理（null 表示直连）。
  static void _applyProxy(HttpClient client, String? proxy) {
    if (proxy == null) return;
    client.findProxy = (_) => proxy;
  }

  /// 从单个地址解析 Release；失败（网络/解析）返回 null。
  static Future<AppRelease?> _fetchReleaseFrom(String url, String? proxy) async {
    try {
      final body = await _get(url, proxy);
      if (body == null) return null;
      final json = jsonDecode(body);
      if (json is! Map) return null;

      final tag = json['tag_name']?.toString() ?? '';
      final version = _parseVersion(tag);
      if (version == null) return null;

      // 从附件中挑选 arm64-v8a 的 APK（本项目只发这一种架构）。
      String? apkName;
      String? apkUrl;
      final assets = json['assets'];
      if (assets is List) {
        for (final asset in assets) {
          if (asset is! Map) continue;
          final name = asset['name']?.toString() ?? '';
          if (!name.toLowerCase().endsWith('.apk')) continue;
          if (!name.contains('arm64')) continue;
          // 只认当前版本自己的安装包，否则三版本发布后会更新成别的版本（议题 #14）。
          if (!name.startsWith('$appSlug-')) continue;
          apkName = name;
          apkUrl = asset['browser_download_url']?.toString();
          break;
        }
      }
      if (apkUrl == null || apkUrl.isEmpty) return null;

      return AppRelease(
        version: version,
        tag: tag,
        apkName: apkName ?? 'update.apk',
        apkUrl: apkUrl,
        notes: json['body']?.toString() ?? '',
      );
    } catch (_) {
      return null;
    }
  }

  /// 简单的 HTTP GET，返回正文；任何失败均返回 null。
  ///
  /// 0.2.27：连接/响应超时放宽（8s/12s → 10s/20s），
  /// 兼顾 VPN/弱网环境；但仍远低于用户的等待上限。
  /// 0.4.1：支持走系统代理（见 [_systemProxy]），修复 WT-0028。
  static Future<String?> _get(String url, [String? proxy]) async {
    final client = HttpClient();
    _applyProxy(client, proxy);
    client.connectionTimeout = const Duration(seconds: 10);
    try {
      final request = await client.getUrl(Uri.parse(url));
      request.headers.set(HttpHeaders.userAgentHeader, 'zhenguojian-updater');
      request.headers.set(
        HttpHeaders.acceptHeader,
        'application/vnd.github+json',
      );
      final response = await request.close().timeout(
        const Duration(seconds: 20),
      );
      // 0.5.1：记录状态码，供调用方识别 403 限流。
      _lastStatus = response.statusCode;
      if (response.statusCode != 200) return null;
      return await response.transform(utf8.decoder).join();
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  /// 解析 tag，如 "v0.2.17" -> 0.2.17；(0,2,17)；无法解析返回 null。
  static List<int>? _parseVersion(String tag) {
    final match = RegExp(r'(\d+)\.(\d+)\.(\d+)').firstMatch(tag);
    if (match == null) return null;
    return [
      int.parse(match.group(1)!),
      int.parse(match.group(2)!),
      int.parse(match.group(3)!),
    ];
  }

  /// 弹出的更新对话框。
  static Future<void> showUpdateDialog(
    BuildContext context,
    AppRelease release,
  ) async {
    final action = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
        title: const Text('发现新版本'),
        content: SizedBox(
          width: double.maxFinite,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('新版本：${release.version.join('.')}'),
                const SizedBox(height: 6),
                Text('当前版本：${AppLayout.versionOf(context)}'),
                // 0.2.27 新增（用户反馈第 3 条）：展示 GitHub Release 的更新日志。
                // 内容来自 GitHub Release 的 body 字段，就是发布时填写的更新说明。
                // 0.3.3 修复（用户反馈）：原来直接把 Markdown 源码当纯文本显示，
                // `#`、`**`、反引号全部外露且排版拥挤；改用 MarkdownLite 渲染
                // 标题/加粗/等宽/列表，并补上分隔线与段间距。
                if (release.notes.trim().isNotEmpty) ...[
                  const SizedBox(height: 14),
                  const Divider(height: 1),
                  const SizedBox(height: 10),
                  const Text(
                    '更新日志（GitHub）',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  MarkdownLite(release.notes.trim()),
                ],
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop('later'),
            child: const Text('稍后'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop('update'),
            child: const Text('更新'),
          ),
        ],
      ),
    );

    if (action == 'later') {
      await _snoozeToday();
      return;
    }
    if (action != 'update') return;
    if (!context.mounted) return;

    await _downloadAndInstall(context, release);
  }

  /// 下载 APK 并拉起系统安装界面。
  static Future<void> _downloadAndInstall(
    BuildContext context,
    AppRelease release,
  ) async {
    final progress = ValueNotifier<double?>(null);
    if (!context.mounted) return;

    // 下载进度对话框（不可取消，避免半途残留）。
    unawaited(
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) => AlertDialog(
          title: const Text('正在下载更新'),
          content: ValueListenableBuilder<double?>(
            valueListenable: progress,
            builder: (_, value, _) => Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                LinearProgressIndicator(value: value),
                const SizedBox(height: 12),
                Text(
                  value == null
                      ? '正在连接…'
                      : '${(value * 100).clamp(0, 100).toStringAsFixed(0)}%',
                ),
              ],
            ),
          ),
        ),
      ),
    );

    try {
      final file = await _download(
        release,
        onProgress: (v) => progress.value = v,
      );
      if (!context.mounted) return;
      Navigator.of(context, rootNavigator: true).pop(); // 关闭进度框

      if (file == null) {
        _toast(context, '下载失败，请稍后重试');
        return;
      }
      final status = await _install(file);
      if (!context.mounted) return;
      if (status == 'ok') return;
      if (status == 'no_permission') {
        await _promptInstallPermission(context);
        return;
      }
      if (status == 'missing') {
        _toast(context, '安装包已失效，请重新下载后重试');
        return;
      }
      _toast(context, '安装未完成（$status），可尝试在文件管理器中手动安装');
    } catch (_) {
      if (context.mounted) {
        Navigator.of(context, rootNavigator: true).pop();
        _toast(context, '下载失败，请稍后重试');
      }
    } finally {
      progress.dispose();
    }
  }

  /// 下载到应用缓存目录。失败返回 null。
  ///
  /// 必须放在应用缓存目录内，否则系统安装器拿不到文件（FileProvider 白名单）。
  static Future<File?> _download(
    AppRelease release, {
    void Function(double?)? onProgress,
  }) async {
    Directory directory;
    try {
      directory = await getTemporaryDirectory();
    } catch (_) {
      directory = Directory.systemTemp;
    }
    final target = File(
      '${directory.path}/zhenguojian-update-${release.apkName}',
    );

    // 下载同样需要走系统代理：否则 VPN 下会出现"能检测到更新、却下载不动"。
    // 0.5.1：`ghfast.top` 对**文件下载**可用（实测 200），故仍作下载兜底；
    // 再补一路 `gh-proxy.com`（同样支持文件下载），提高 VPN 下的成功率。
    final proxy = await _systemProxy();
    for (final url in [
      release.apkUrl,
      '$_mirrorPrefix${release.apkUrl}',
      '$_apiProxyPrefix${release.apkUrl}',
    ]) {
      final ok = await _downloadFrom(
        url,
        target,
        onProgress: onProgress,
        proxy: proxy,
      );
      if (ok) return target;
    }
    return null;
  }

  static Future<bool> _downloadFrom(
    String url,
    File target, {
    void Function(double?)? onProgress,
    String? proxy,
  }) async {
    final client = HttpClient();
    _applyProxy(client, proxy);
    client.connectionTimeout = const Duration(seconds: 10);
    try {
      var request = await client.getUrl(Uri.parse(url));
      request.headers.set(HttpHeaders.userAgentHeader, 'zhenguojian-updater');
      var response = await request.close().timeout(const Duration(seconds: 15));

      // GitHub Releases 会 302 到对象存储，镜像站点通常直接返回。
      var redirects = 0;
      while (response.isRedirect && redirects < 5) {
        final location = response.headers.value(HttpHeaders.locationHeader);
        if (location == null) break;
        request = await client.getUrl(Uri.parse(location));
        request.headers.set(HttpHeaders.userAgentHeader, 'zhenguojian-updater');
        response = await request.close().timeout(const Duration(seconds: 15));
        redirects++;
      }

      if (response.statusCode != 200) return false;

      final total = response.contentLength;
      var received = 0;
      final sink = target.openWrite();
      await for (final chunk in response) {
        sink.add(chunk);
        received += chunk.length;
        if (onProgress != null && total > 0) {
          onProgress(received / total);
        }
      }
      await sink.close();

      // 基本校验：APK 必须是有效 ZIP（PK 开头），避免把错误页当成安装包。
      if (target.lengthSync() < 1024 * 1024) return false;
      final raf = target.openSync();
      final header = raf.readSync(2);
      raf.closeSync();
      if (header.length < 2 || header[0] != 0x50 || header[1] != 0x4B) {
        return false;
      }
      return true;
    } catch (_) {
      return false;
    } finally {
      client.close(force: true);
    }
  }

  /// 拉起系统安装界面。使用 MethodChannel 调用 MainActivity。
  ///
  /// 返回 'ok' / 'missing' / 'no_permission' / 'failed:原因'，
  /// 便于调用方区分“真没权限”和“其它失败”。
  static Future<String> _install(File file) async {
    try {
      const channel = MethodChannel('duanju/updater');
      final result = await channel.invokeMethod<String>('installApk', {
        'path': file.path,
      });
      return result ?? 'failed:无返回';
    } catch (error) {
      return 'failed:$error';
    }
  }

  /// 系统确实没给「安装未知应用」权限时的引导：一键跳到设置页。
  static Future<void> _promptInstallPermission(BuildContext context) async {
    final go = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('需要安装权限'),
        content: const Text(
          '系统尚未允许本应用安装应用。点「去设置」打开「允许来自此来源的应用」，'
          '然后回到软件重新点一次更新即可。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('稍后'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('去设置'),
          ),
        ],
      ),
    );
    if (go != true) return;
    try {
      const channel = MethodChannel('duanju/updater');
      final opened = await channel.invokeMethod<bool>('openInstallSettings');
      if (opened == true) return;
    } catch (_) {
      // 忽略：下面统一提示。
    }
    if (context.mounted) {
      _toast(context, '请手动在系统设置中允许本应用安装应用');
    }
  }

  static void _toast(BuildContext context, String message) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }
}

/// 一次可用的更新信息。
class AppRelease {
  const AppRelease({
    required this.version,
    required this.tag,
    required this.apkName,
    required this.apkUrl,
    required this.notes,
  });

  final List<int> version;
  final String tag;
  final String apkName;
  final String apkUrl;
  final String notes;

  /// 与当前版本比较，是否更新。
  bool isNewerThan(BuildContext context) {
    return _isNewer(version, _currentVersion(context));
  }

  static List<int> _currentVersion(BuildContext context) {
    final text = AppLayout.versionOf(context);
    final match = RegExp(r'(\d+)\.(\d+)\.(\d+)').firstMatch(text);
    if (match == null) return const [0, 0, 0];
    return [
      int.parse(match.group(1)!),
      int.parse(match.group(2)!),
      int.parse(match.group(3)!),
    ];
  }

  /// 字典序比较：remote > local 返回 true。
  static bool _isNewer(List<int> remote, List<int> local) {
    for (var i = 0; i < 3; i++) {
      final r = i < remote.length ? remote[i] : 0;
      final l = i < local.length ? local[i] : 0;
      if (r != l) return r > l;
    }
    return false;
  }
}
