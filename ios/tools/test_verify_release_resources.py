import importlib.util
import plistlib
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('release_resources', Path(__file__).with_name('verify-release-resources.py'))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class ReleaseResourceTests(unittest.TestCase):
    def manifest(self, bundle, entries=None):
        if entries is None:
            entries = [{'NSPrivacyAccessedAPIType': category, 'NSPrivacyAccessedAPITypeReasons': [reason]}
                       for category, reason in module.REQUIRED_REASONS.items()]
        (bundle / 'PrivacyInfo.xcprivacy').write_bytes(plistlib.dumps({'NSPrivacyAccessedAPITypes': entries}))

    def test_required_bundle_and_production_json(self):
        with tempfile.TemporaryDirectory() as folder:
            bundle = Path(folder) / 'TwilDiary.app'
            with self.assertRaises(ValueError):
                module.verify(bundle)
            bundle.mkdir()
            (bundle / 'demo-attribution.json').write_text('{}')
            self.manifest(bundle)
            module.verify(bundle)

    def test_missing_or_malformed_manifest_is_rejected(self):
        with tempfile.TemporaryDirectory() as folder:
            bundle = Path(folder)
            with self.assertRaisesRegex(ValueError, 'missing.*manifest'):
                module.verify(bundle)
            for contents in [b'not a plist', plistlib.dumps([]), plistlib.dumps({})]:
                (bundle / 'PrivacyInfo.xcprivacy').write_bytes(contents)
                with self.assertRaisesRegex(ValueError, 'manifest'):
                    module.verify(bundle)

    def test_missing_wrong_and_duplicate_required_reasons_are_rejected(self):
        standard = [{'NSPrivacyAccessedAPIType': category, 'NSPrivacyAccessedAPITypeReasons': [reason]}
                    for category, reason in module.REQUIRED_REASONS.items()]
        invalid = [[], standard[:1], [*standard, standard[0]],
                   [dict(standard[0], NSPrivacyAccessedAPITypeReasons=['1C8F.1']), standard[1]],
                   [dict(standard[0], NSPrivacyAccessedAPITypeReasons='CA92.1'), standard[1]], [False]]
        for entries in invalid:
            with self.subTest(entries=entries), tempfile.TemporaryDirectory() as folder:
                bundle = Path(folder)
                self.manifest(bundle, entries)
                with self.assertRaisesRegex(ValueError, 'manifest'):
                    module.verify(bundle)

    def test_shipping_manifest_and_plist_reasons_are_verified(self):
        source = Path(__file__).resolve().parents[1] / 'App' / 'PrivacyInfo.xcprivacy'
        with tempfile.TemporaryDirectory() as folder:
            bundle = Path(folder)
            (bundle / source.name).write_bytes(source.read_bytes())
            module.verify(bundle)
            privacy = plistlib.loads(source.read_bytes())
            self.assertIs(privacy.get('NSPrivacyTracking'), False)
            self.assertNotIn('NSPrivacyCollectedDataTypes', privacy, 'No unreviewed zero-collection declaration')

    def test_nested_fixtures_fail_including_the_old_production_core_bundle(self):
        for name in ['workspace.json', 'reference-workspace.json', 'catalog-tv-1.json', 'trakt-sync.json', 'stats-golden.json']:
            with self.subTest(name=name), tempfile.TemporaryDirectory() as folder:
                bundle = Path(folder)
                nested = bundle / 'TwilDiaryCore_TwilDiaryCore.bundle'
                nested.mkdir()
                (nested / name).write_text('{}')
                with self.assertRaisesRegex(ValueError, name):
                    module.verify(bundle)

    def test_test_support_bundle_itself_is_forbidden_even_if_empty(self):
        with tempfile.TemporaryDirectory() as folder:
            bundle = Path(folder)
            (bundle / 'TwilDiaryCore_TwilDiaryTestSupport.bundle').mkdir()
            with self.assertRaisesRegex(ValueError, 'TwilDiaryTestSupport'):
                module.verify(bundle)


if __name__ == '__main__':
    unittest.main()
