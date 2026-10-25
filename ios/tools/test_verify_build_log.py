import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('build_log', Path(__file__).with_name('verify-build-log.py'))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class BuildLogTests(unittest.TestCase):
    def test_success(self):
        module.verify('compile\n** BUILD SUCCEEDED **', '** BUILD SUCCEEDED **')

    def test_metadata_tool_warning_is_not_hidden_by_a_successful_build(self):
        with self.assertRaisesRegex(ValueError, 'AppIntents.framework'):
            module.verify('appintentsmetadataprocessor warning: No AppIntents.framework dependency found.\n** TEST BUILD SUCCEEDED **', '** TEST BUILD SUCCEEDED **')

    def test_missing_marker_is_a_failure(self):
        with self.assertRaisesRegex(ValueError, 'marker is missing'):
            module.verify('compiling...', '** BUILD SUCCEEDED **')


if __name__ == '__main__':
    unittest.main()
