/// 构建版本（三种）：
/// - `hongguo`：红果鉴，只含红果；
/// - `all`：真果鉴，含全部站源（含蓝果）；
/// - `languo`：蓝果鉴，只含蓝果。
const buildEdition = String.fromEnvironment('EDITION', defaultValue: 'hongguo');
const allSourcesEnabled = buildEdition == 'all';
const languoOnlyEnabled = buildEdition == 'languo';
const appName = allSourcesEnabled
    ? '真果鉴'
    : languoOnlyEnabled
    ? '蓝果鉴'
    : '红果鉴';
const appSlug = allSourcesEnabled
    ? 'zhenguojian'
    : languoOnlyEnabled
    ? 'languojian'
    : 'hongguojian';
