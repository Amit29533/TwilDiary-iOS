import importlib.util
import contextlib
import io
from pathlib import Path
import sys
import unittest

spec = importlib.util.spec_from_file_location('bounded', Path(__file__).with_name('run-bounded.py'))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class BoundedCommandTests(unittest.TestCase):
    def test_success(self):
        self.assertEqual(module.run([sys.executable, '-c', 'pass'], 10), 0)

    def test_failure_is_preserved(self):
        self.assertEqual(module.run([sys.executable, '-c', 'raise SystemExit(65)'], 10), 65)

    def test_hung_process_fails_instead_of_waiting_for_the_whole_build(self):
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            self.assertEqual(module.run([sys.executable, '-c', 'import time; time.sleep(30)'], .2, grace=1), 124)
        self.assertIn('exceeded', output.getvalue())


if __name__ == '__main__':
    unittest.main()
