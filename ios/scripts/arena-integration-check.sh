#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
ARTIFACTS="$PWD/ios/.artifacts"
mkdir -p "$ARTIFACTS/logs"
finish() {
  local status=$?
  trap - EXIT
  for result in "$ARTIFACTS"/Arena*.xcresult; do
    [ -d "$result" ] || continue
    xcrun xcresulttool export attachments --path "$result" --output-path "$ARTIFACTS/screenshots/$(basename "$result" .xcresult)" || true
  done
  exit "$status"
}
trap finish EXIT
export GITHUB_ENV="${CM_ENV:?Codemagic environment file required}"
bash ios/scripts/ci.sh inventory
export SIMULATOR_ID="$(python3 -c 'import json; print(json.load(open("ios/.artifacts/simulator.json"))["udid"])')"
bash ios/scripts/xcodegen.sh
swift test --package-path ios/Packages/TwilDiaryCore 2>&1 | tee "$ARTIFACTS/logs/arena-core-tests.log"
bash ios/scripts/ci.sh build-simulator
bash ios/scripts/ci.sh boot
python3 ios/scripts/native-test-watchdog.py --label arena-unit --budget 1500 -- xcodebuild test-without-building -project ios/TwilDiary.xcodeproj -scheme TwilDiary \
  -clonedSourcePackagesDirPath "$PWD/ios/.spm" CODE_SIGNING_ALLOWED=NO COMPILER_INDEX_STORE_ENABLE=NO \
  -destination "platform=iOS Simulator,id=$SIMULATOR_ID,arch=$(uname -m)" \
  -parallel-testing-enabled NO -test-timeouts-enabled YES \
  -default-test-execution-time-allowance 150 -maximum-test-execution-time-allowance 240 \
  -only-testing:TwilDiaryTests \
  -derivedDataPath "$PWD/ios/.derived/simulator" -resultBundlePath "$ARTIFACTS/ArenaUnits.xcresult" \
  2>&1 | tee "$ARTIFACTS/logs/arena-unit-tests.log"
python3 ios/scripts/native-test-watchdog.py --label arena-ui --budget 1800 -- xcodebuild test-without-building -project ios/TwilDiary.xcodeproj -scheme TwilDiary \
  -clonedSourcePackagesDirPath "$PWD/ios/.spm" CODE_SIGNING_ALLOWED=NO COMPILER_INDEX_STORE_ENABLE=NO \
  -destination "platform=iOS Simulator,id=$SIMULATOR_ID,arch=$(uname -m)" \
  -parallel-testing-enabled NO -test-timeouts-enabled YES \
  -default-test-execution-time-allowance 150 -maximum-test-execution-time-allowance 240 \
  -only-testing:TwilDiaryUITests/PersonalSettingsUITests \
  -only-testing:TwilDiaryUITests/ArenaIntegrationUITests \
  -only-testing:TwilDiaryUITests/NativeScreensTests/testHomeMediaShelvesAndListCardsKeepRoutesAndIndependentSavedLayouts \
  -only-testing:TwilDiaryUITests/NativeScreensTests/testHistoryGridReusesCompactWatchedCardsAndKeepsTitleNavigation \
  -derivedDataPath "$PWD/ios/.derived/simulator" -resultBundlePath "$ARTIFACTS/ArenaUI.xcresult" \
  2>&1 | tee "$ARTIFACTS/logs/arena-ui-tests.log"
bash ios/scripts/ci.sh build-device
bash ios/scripts/ci.sh package
python3 - <<'PY'
import hashlib, json, pathlib, re, shutil, subprocess, zipfile
root = pathlib.Path('ios/.artifacts')
for name in ['simulator-build.log', 'device-build.log']:
    if re.search(r'\bwarning:', (root / 'logs' / name).read_text(errors='replace'), re.I):
        raise SystemExit('Build warning in ' + name)
ipa = root / 'TwilDiary-arena-integration.ipa'
shutil.copyfile(root / 'TwilDiary-unsigned.ipa', ipa)
with zipfile.ZipFile(ipa) as archive:
    names = archive.namelist()
    if not any('/PlugIns/TwilDiaryWidgets.appex/' in name for name in names):
        raise SystemExit('Live Activity extension is missing from the device package')
digest = hashlib.sha256(ipa.read_bytes()).hexdigest()
(root / (ipa.name + '.sha256')).write_text(digest + '  ' + ipa.name + '\n')
(root / 'arena-integration-provenance.json').write_text(json.dumps({
    'commit': subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip(),
    'version': '2.0.0', 'build': '67', 'signed': False, 'sha256': digest,
    'scope': 'Full Core and app unit suites; Profile, universal Search, Home cards and Arena integration UI on the primary simulator; unsigned device compile including WidgetKit extension.'
}, indent=2) + '\n')
PY
