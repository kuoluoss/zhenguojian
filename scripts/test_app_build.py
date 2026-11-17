import base64
import os
from pathlib import Path
import plistlib
import runpy
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

from app_build import BuildVariant
from configure_ios_branding import configure


def dart_defines(*values):
    return ','.join(base64.b64encode(value.encode()).decode() for value in values)


class AppBuildTests(unittest.TestCase):
    def test_omitted_or_unknown_flag_keeps_hongguo_only(self):
        for encoded in ['', dart_defines('EDITION=unknown'), dart_defines('OTHER=true')]:
            variant = BuildVariant.from_dart_defines(encoded)
            self.assertFalse(variant.all_sources)
            self.assertEqual(variant.edition, 'hongguo')
            self.assertEqual(variant.name, '红果鉴')
            self.assertEqual(variant.slug, 'hongguojian')

    def test_all_edition_decodes_among_other_flutter_defines(self):
        variant = BuildVariant.from_dart_defines(dart_defines(
            'OTHER=中文', 'EDITION=all', 'VALUE=a=b'))
        self.assertTrue(variant.all_sources)
        self.assertEqual(variant.name, '真果鉴')
        self.assertEqual(variant.slug, 'zhenguojian')

    def test_languo_edition_decodes(self):
        variant = BuildVariant.from_dart_defines(dart_defines('EDITION=languo'))
        self.assertFalse(variant.all_sources)
        self.assertEqual(variant.edition, 'languo')
        self.assertEqual(variant.name, '蓝果鉴')
        self.assertEqual(variant.slug, 'languojian')

    def test_legacy_all_sources_define_still_maps_to_all_edition(self):
        variant = BuildVariant.from_dart_defines(dart_defines('ALL_SOURCES=true'))
        self.assertEqual(variant.edition, 'all')

    def test_each_edition_has_its_own_name_and_slug(self):
        for edition, name, slug in [
            ('hongguo', '红果鉴', 'hongguojian'),
            ('all', '真果鉴', 'zhenguojian'),
            ('languo', '蓝果鉴', 'languojian'),
        ]:
            variant = BuildVariant(edition)
            self.assertEqual(variant.name, name)
            self.assertEqual(variant.slug, slug)
            self.assertIn('--dart-define=EDITION=' + edition, variant.flutter_arguments)
            self.assertIn('core.buildEdition=' + edition, variant.linker_flags)

    def test_ios_branding_can_switch_editions_without_replacing_bundle_identity(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / 'Info.plist'
            original = {'CFBundleIdentifier': 'com.duanju.duanjuApp', 'CFBundleVersion': '9'}
            path.write_bytes(plistlib.dumps(original))
            for edition, name, slug in [
                ('all', '真果鉴', 'zhenguojian'),
                ('languo', '蓝果鉴', 'languojian'),
                ('hongguo', '红果鉴', 'hongguojian'),
            ]:
                configure(path, dart_defines('EDITION=' + edition))
                actual = plistlib.loads(path.read_bytes())
                self.assertEqual(actual['CFBundleDisplayName'], name)
                self.assertEqual(actual['CFBundleName'], slug)
                for key, value in original.items():
                    self.assertEqual(actual[key], value)

    @unittest.skipUnless(shutil.which('cmake'), 'CMake is unavailable')
    def test_windows_reads_defines_from_flutter_tool_environment(self):
        branding = Path(__file__).resolve().parents[1] / 'windows/runner/app_branding.cmake'
        for flags, expected in [
            ([], '红果鉴'),
            (['EDITION=all'], '真果鉴'),
            (['EDITION=languo'], '蓝果鉴'),
            (['EDITION=hongguo'], '红果鉴'),
            (['ALL_SOURCES=true'], '真果鉴'),
        ]:
            with self.subTest(flags=flags), tempfile.TemporaryDirectory() as temporary:
                script = Path(temporary) / 'check.cmake'
                result = Path(temporary) / 'name.txt'
                script.write_text(
                    'list(APPEND FLUTTER_TOOL_ENVIRONMENT "OTHER=1" "DART_DEFINES=' + dart_defines(*flags) + '")\n'
                    'include("' + branding.as_posix() + '")\n'
                    'file(WRITE "' + result.as_posix() + '" "${APP_DISPLAY_NAME}")\n',
                    encoding='utf-8',
                )
                subprocess.run(['cmake', '-P', str(script)], check=True, capture_output=True)
                self.assertEqual(result.read_text(encoding='utf-8'), expected)

    def test_android_and_windows_propagate_one_edition_to_core_flutter_and_package(self):
        root = Path(__file__).resolve().parent
        for target in ['android', 'windows']:
            for edition in ['hongguo', 'all', 'languo']:
                with self.subTest(target=target, edition=edition):
                    script = root / f'build_{target}.py'
                    arguments = [str(script), '--edition', edition]
                    with mock.patch.object(sys, 'argv', arguments), \
                            mock.patch.dict(os.environ, {'PATH': '/tools'}, clear=True), \
                            mock.patch('shutil.which', return_value='/tools/flutter'), \
                            mock.patch('subprocess.run') as run:
                        runpy.run_path(str(script), run_name='__main__')
                    calls = [call.args[0] for call in run.call_args_list]
                    native = next(call for call in calls if any(str(arg).endswith('build_native.py') for arg in call))
                    flutter = next(call for call in calls if 'build' in call)
                    package = next(call for call in calls if any(str(arg).endswith('package_release.py') for arg in call))
                    self.assertIn('--edition', native)
                    self.assertIn(edition, native)
                    self.assertIn('--edition', package)
                    self.assertIn(edition, package)
                    self.assertIn('--dart-define=EDITION=' + edition, flutter)
                    self.assertIn('core.buildEdition=' + edition, BuildVariant(edition).linker_flags)


if __name__ == '__main__':
    unittest.main()
