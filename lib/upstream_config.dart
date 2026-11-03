import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'core_bridge.dart';

/// 红果上游参数的外部化配置（0.7.18）。
///
/// App 启动后异步拉一次远程 JSON 交给原生核心；拉不到、格式不对、超时
/// 一律静默忽略，核心继续用内置默认值。这样红果改 UA / 版本号 / 接口域名
/// 这类**参数**时，只改仓库里的 `config/upstream.json` 即可生效，不必发版；
/// 若它改的是签名算法或注册协议（逻辑），仍然需要发版。
const upstreamConfigURL =
    'https://raw.githubusercontent.com/kuoluoss/zhenguojian/main/config/upstream.json';

/// 拉取并下发远程配置。永远不抛异常（失败只记 debug 日志）。
Future<void> refreshUpstreamConfig(AppRepository repository) async {
  HttpClient? client;
  try {
    client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 5)
      ..idleTimeout = const Duration(seconds: 5);
    final request = await client.getUrl(Uri.parse(upstreamConfigURL));
    request.headers.set(HttpHeaders.cacheControlHeader, 'no-cache');
    final response = await request.close().timeout(const Duration(seconds: 8));
    if (response.statusCode != HttpStatus.ok) return;
    final text = await response.transform(utf8.decoder).join();
    if (text.trim().isEmpty || text.length > 8192) return;
    // 先做一次 JSON 语法校验，字段合法性由原生核心把关。
    jsonDecode(text);
    await repository.applyUpstreamConfig(text);
  } catch (_) {
    // 静默失败：远程配置只是优化项，不影响启动与播放。
  } finally {
    client?.close(force: true);
  }
}