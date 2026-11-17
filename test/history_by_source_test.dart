import 'package:duanju_app/app_build.dart';
import 'package:duanju_app/local_store.dart';
import 'package:duanju_app/models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// GitHub 议题 #13：最近观看按站源分开。
///
/// 需要 `--dart-define=ALL_SOURCES=true` 才有多个站源可选，
/// 单源构建下本组用例自动跳过。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Drama drama(String source, String id, String title) =>
      Drama(id: '$source:$id', source: source, title: title, episodes: 10);

  WatchEntry watch(Drama drama, {int episode = 1}) => WatchEntry(
    drama: drama,
    episode: episode,
    position: 5,
    duration: 60,
    updatedAt: DateTime.utc(2026, 11, 17),
  );

  Future<LocalStore> create() async {
    SharedPreferences.setMockInitialValues({});
    final store = LocalStore(await SharedPreferences.getInstance());
    addTearDown(store.dispose);
    return store;
  }

  test('activeSourceIds follows the current single source', () async {
    if (!allSourcesEnabled) return;
    final store = await create();
    await store.setSource('huangdou');
    expect(store.activeSourceIds, {'huangdou'});
    await store.setSource('hongguo');
    expect(store.activeSourceIds, {'hongguo'});
  });

  test('activeSourceIds uses multi selection when enabled', () async {
    if (!allSourcesEnabled) return;
    final store = await create();
    await store.setMultiSources(['hongguo', 'huangdou']);
    expect(store.activeSourceIds, {'hongguo', 'huangdou'});
    await store.setMultiSources(const []);
    expect(store.activeSourceIds, {'hongguo'});
  });

  test('clearHistory only removes entries of the given sources', () async {
    if (!allSourcesEnabled) return;
    final store = await create();
    final red = drama('hongguo', 'a', '红果剧');
    final dou = drama('huangdou', 'b', '黄豆剧');
    await store.saveWatch(watch(red));
    await store.saveWatch(watch(dou));
    expect(store.history, hasLength(2));

    await store.clearHistory(sources: const {'hongguo'});
    expect(store.history.map((entry) => entry.drama.source), ['huangdou']);

    final restarted = LocalStore(store.preferences);
    addTearDown(restarted.dispose);
    expect(restarted.history.map((entry) => entry.drama.source), ['huangdou']);
  });

  test('clearHistory keeps every source when no filter is passed', () async {
    if (!allSourcesEnabled) return;
    final store = await create();
    await store.saveWatch(watch(drama('hongguo', 'a', '红果剧')));
    await store.saveWatch(watch(drama('huangdou', 'b', '黄豆剧')));
    await store.clearHistory();
    expect(store.history, isEmpty);
  });
}
