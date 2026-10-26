"""Require executed stage-specific native evidence; never a stable-release gate."""
import json
import pathlib
import re
import subprocess

root = pathlib.Path('ios/.artifacts')
logs = root / 'logs'
def read(name):
    return (logs / name).read_text(errors='replace')

unit = read('unit-tests.log')
ui = read('stage1-ui-tests.log')
if '** TEST EXECUTE SUCCEEDED **' not in unit or '** TEST EXECUTE SUCCEEDED **' not in ui:
    raise SystemExit('Stage 1 unit/UI execution was not successful.')
new_cases = set(re.findall(r"Test Case '-\[TwilDiaryTests.SessionTests (testStage1[^]]+)\]' passed", unit))
if len(new_cases) != 10:
    raise SystemExit('Stage 1 requires all ten executed freshness/recovery tests.')
ui_cases = set(re.findall(r"Test Case '-\[TwilDiaryUITests.NativeScreensTests ([^]]+)\]' passed", ui))
if len(ui_cases) != 4:
    raise SystemExit('Stage 1 requires four executed native UI cases.')
for path in logs.glob('*.log'):
    content = path.read_text(errors='replace')
    if re.search(r'\bwarning:|\berror:|Test Case .* failed', content, re.I):
        raise SystemExit('Native diagnostics remain in ' + path.name)
value = {'scope':'Stage 1 only; not full app release qualification',
         'sourceSHA':subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip(),
         'freshnessCases':sorted(new_cases), 'uiCases':sorted(ui_cases), 'warnings':0}
(root / 'stage1-native-verification.json').write_text(json.dumps(value,indent=2)+'\n')
print('Stage 1 native checks passed: 10 freshness cases, 4 UI cases, zero warnings.')
