#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
ARTIFACTS="$PWD/ios/.artifacts"
mkdir -p "$ARTIFACTS/logs"
finish() {
  local status=$?
  trap - EXIT
  for result in "$ARTIFACTS"/PersonalSettings*.xcresult; do
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
swift test --package-path ios/Packages/TwilDiaryCore --filter 'profileMilestonesCountActualWatchesAndExcludeFutureRevokedAndPlannedTitles|profileMilestoneStreakUsesLocalHistoryAndCorrectionsUpdateProgress|statsAgreeWithUnchangedWebCalculationAcrossEveryPeriodAndEdgeCase' 2>&1 | tee "$ARTIFACTS/logs/personal-core-tests.log"
bash ios/scripts/ci.sh build-simulator
bash ios/scripts/ci.sh boot
xcodebuild test-without-building -project ios/TwilDiary.xcodeproj -scheme TwilDiary \
  -clonedSourcePackagesDirPath "$PWD/ios/.spm" CODE_SIGNING_ALLOWED=NO COMPILER_INDEX_STORE_ENABLE=NO \
  -destination "platform=iOS Simulator,id=$SIMULATOR_ID,arch=$(uname -m)" \
  -parallel-testing-enabled NO -test-timeouts-enabled YES \
  -default-test-execution-time-allowance 150 -maximum-test-execution-time-allowance 240 \
  -only-testing:TwilDiaryTests/PersonalProfileTests \
  -only-testing:TwilDiaryTests/NativeNavigationAndSynopsisTests \
  -only-testing:TwilDiaryTests/HomeMediaCardsTests \
  -only-testing:TwilDiaryUITests/PersonalSettingsUITests \
  -only-testing:TwilDiaryUITests/NativeScreensTests/testHomeMediaShelvesAndListCardsKeepRoutesAndIndependentSavedLayouts \
  -only-testing:TwilDiaryUITests/NativeScreensTests/testHistoryGridReusesCompactWatchedCardsAndKeepsTitleNavigation \
  -only-testing:TwilDiaryUITests/NativeScreensTests/testHomeStatsUsesTodayAndKeepsTheOriginalRangeBar \
  -derivedDataPath "$PWD/ios/.derived/simulator" -resultBundlePath "$ARTIFACTS/PersonalSettings.xcresult" \
  2>&1 | tee "$ARTIFACTS/logs/personal-settings-tests.log"
xcrun simctl shutdown "$SIMULATOR_ID"
while read -r slug layout_id; do
  export SIMULATOR_ID="$layout_id"
  bash ios/scripts/ci.sh boot
  xcodebuild test-without-building -project ios/TwilDiary.xcodeproj -scheme TwilDiary \
    -clonedSourcePackagesDirPath "$PWD/ios/.spm" CODE_SIGNING_ALLOWED=NO COMPILER_INDEX_STORE_ENABLE=NO \
    -destination "platform=iOS Simulator,id=$SIMULATOR_ID,arch=$(uname -m)" \
    -parallel-testing-enabled NO -test-timeouts-enabled YES \
    -default-test-execution-time-allowance 150 -maximum-test-execution-time-allowance 240 \
    -only-testing:TwilDiaryUITests/PersonalSettingsUITests/testProfileMenuOrderPersonalPageAvatarAndMilestones \
    -only-testing:TwilDiaryUITests/PersonalSettingsUITests/testLargeTextPersonalProfileKeepsAvatarAndSectionsReadable \
    -only-testing:TwilDiaryUITests/PersonalSettingsUITests/testUniversalSearchTrendingLocalMatchAndReturnToSearch \
    -only-testing:TwilDiaryUITests/PersonalSettingsUITests/testEveryRootScrollsUnderTheTopAreaAndStatisticsUsesTheSameViewport \
    -derivedDataPath "$PWD/ios/.derived/simulator" -resultBundlePath "$ARTIFACTS/PersonalSettings-$slug.xcresult" \
    2>&1 | tee "$ARTIFACTS/logs/personal-settings-$slug.log"
  xcrun simctl shutdown "$SIMULATOR_ID"
done < <(python3 - <<'LAYOUTS'
import json
for item in json.load(open('ios/.artifacts/layout-simulators.json')):
    print(item['name'].lower().replace(' ', '-'), item['udid'])
LAYOUTS
)
bash ios/scripts/ci.sh build-device
bash ios/scripts/ci.sh package
python3 - <<'PY'
import hashlib, json, os, pathlib, re, shutil, subprocess
root = pathlib.Path('ios/.artifacts')
for name in ['personal-settings-tests.log', 'personal-settings-iphone-17e.log', 'personal-settings-iphone-17-pro-max.log']:
    log = (root / 'logs' / name).read_text(errors='replace')
    if '** TEST EXECUTE SUCCEEDED **' not in log or re.search(r'\berror:|Test Case .* failed', log):
        raise SystemExit('Native settings checks did not pass: ' + name)
for name in ['simulator-build.log', 'device-build.log']:
    if re.search(r'\bwarning:', (root / 'logs' / name).read_text(errors='replace'), re.I):
        raise SystemExit('Build warning in ' + name)
ipa = root / 'TwilDiary-personal-settings.ipa'
shutil.copyfile(root / 'TwilDiary-unsigned.ipa', ipa)
digest = hashlib.sha256(ipa.read_bytes()).hexdigest()
(root / (ipa.name + '.sha256')).write_text(digest + '  ' + ipa.name + '\n')
value = {'kind': 'device-diagnostic', 'signed': False, 'regressionAcceptance': False, 'uiRegressionPassed': True,
         'sourceSHA': subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip(),
         'codemagicBuild': os.environ['CM_BUILD_ID'], 'sha256': digest,
         'note': 'Profile and milestone units; seven settings UI journeys, three Home/History journeys, and four settings journeys repeated on compact and large phones. No full regression claim.'}
(root / 'personal-settings-provenance.json').write_text(json.dumps(value, indent=2) + '\n')
print('Personal settings checks passed; unsigned phone IPA packaged.')
PY
