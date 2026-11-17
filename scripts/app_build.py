import base64
from dataclasses import dataclass

EDITIONS = {
    'hongguo': ('红果鉴', 'hongguojian'),
    'all': ('真果鉴', 'zhenguojian'),
    'languo': ('蓝果鉴', 'languojian'),
}
DEFAULT_EDITION = 'hongguo'


@dataclass(frozen=True)
class BuildVariant:
    edition: str = DEFAULT_EDITION

    def __post_init__(self):
        if self.edition not in EDITIONS:
            raise ValueError('未知构建版本：' + str(self.edition))

    @property
    def all_sources(self):
        return self.edition == 'all'

    @property
    def name(self):
        return EDITIONS[self.edition][0]

    @property
    def slug(self):
        return EDITIONS[self.edition][1]

    @property
    def arguments(self):
        return ['--edition', self.edition]

    @property
    def flutter_arguments(self):
        return ['--dart-define=EDITION=' + self.edition]

    @property
    def linker_flags(self):
        return '-s -w -X duanjuapp/native/core.buildEdition=' + self.edition

    @classmethod
    def from_dart_defines(cls, encoded):
        values = {}
        for item in encoded.split(','):
            if not item:
                continue
            key, separator, value = base64.b64decode(item, validate=True).decode('utf-8').partition('=')
            if separator:
                values[key] = value
        edition = values.get('EDITION')
        if edition in EDITIONS:
            return cls(edition)
        # 兼容旧参数：ALL_SOURCES=true 视为全源版本。
        return cls('all' if values.get('ALL_SOURCES') == 'true' else DEFAULT_EDITION)


def add_variant_argument(parser):
    parser.add_argument('--edition', choices=list(EDITIONS), default=DEFAULT_EDITION,
                        help='构建版本：hongguo=红果鉴（仅红果）/ all=真果鉴（全源含蓝果）/ languo=蓝果鉴（仅蓝果）')
