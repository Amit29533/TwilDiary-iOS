#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
ARTIFACTS="$PWD/ios/.artifacts"
mkdir -p "$ARTIFACTS/logs"
finish() {
  local status=$?
  trap - EXIT
  if [ -d "$ARTIFACTS/Navigation.xcresult" ]; then
    xcrun xcresulttool export attachments --path "$ARTIFACTS/Navigation.xcresult" --output-path "$ARTIFACTS/screenshots" || true
  fi
  exit "$status"
}
trap finish EXIT
export GITHUB_ENV="${CM_ENV:?Codemagic environment file required}"
bash ios/scripts/ci.sh inventory
export SIMULATOR_ID="$(python3 -c 'import json; print(json.load(open("ios/.artifacts/simulator.json"))["udid"])')"
bash ios/scripts/xcodegen.sh
swift test --package-path ios/Packages/TwilDiaryCore --filter 'jellyfinDiskFilterMatchesLibraryShortcutKeys|animeAppearanceNavigationRequiresAnUnambiguousTitleMatch|voiceActorPersonMatchingUsesUniqueTmdbCastIdentity' 2>&1 | tee "$ARTIFACTS/logs/focused-navigation-tests.log"
bash ios/scripts/ci.sh build-simulator
bash ios/scripts/ci.sh boot
xcodebuild test-without-building -project ios/TwilDiary.xcodeproj -scheme TwilDiary \
  -clonedSourcePackagesDirPath "$PWD/ios/.spm" CODE_SIGNING_ALLOWED=NO COMPILER_INDEX_STORE_ENABLE=NO \
  -destination "platform=iOS Simulator,id=$SIMULATOR_ID,arch=$(uname -m)" \
  -parallel-testing-enabled NO -test-timeouts-enabled YES \
  -default-test-execution-time-allowance 120 -maximum-test-execution-time-allowance 180 \
  -only-testing:TwilDiaryTests/AnimeNavigationLookupTests \
  -only-testing:TwilDiaryUITests/NativeScreensTests/testCharacterAppearancesAndVoiceActorAnimeOpenTheirTitleAndKeepCharacterLinks \
  -only-testing:TwilDiaryUITests/NativeScreensTests/testAnimeExactMatchesSkipTheSearchPageWithUnrelatedDiaryResults \
  -derivedDataPath "$PWD/ios/.derived/simulator" -resultBundlePath "$ARTIFACTS/Navigation.xcresult" \
  2>&1 | tee "$ARTIFACTS/logs/navigation-tests.log"
bash ios/scripts/ci.sh build-device
bash ios/scripts/ci.sh package
python3 - <<'PY'
import hashlib, json, os, pathlib, plistlib, re, shutil, subprocess
root = pathlib.Path('ios/.artifacts')
tests = (root / 'logs/navigation-tests.log').read_text(errors='replace')
for case in ['testCharacterAppearancesAndVoiceActorAnimeOpenTheirTitleAndKeepCharacterLinks', 'testAnimeExactMatchesSkipTheSearchPageWithUnrelatedDiaryResults']:
    if not re.search(r'Test Case .*' + re.escape(case) + r'.* passed', tests):
        raise SystemExit('Required native UI case did not pass: ' + case)
if not re.search(r"Test Suite '[^']*AnimeNavigationLookupTests' passed", tests):
    raise SystemExit('Native lookup unit tests did not pass.')
for name in ['simulator-build.log', 'device-build.log']:
    log = (root / 'logs' / name).read_text(errors='replace')
    if re.search(r'\bwarning:', log, re.I):
        raise SystemExit('Build warning in ' + name)
ipa = root / 'TwilDiary-native-navigation.ipa'
shutil.copyfile(root / 'TwilDiary-unsigned.ipa', ipa)
digest = hashlib.sha256(ipa.read_bytes()).hexdigest()
(root / (ipa.name + '.sha256')).write_text(digest + '  ' + ipa.name + '\n')
info = plistlib.loads(pathlib.Path('ios/.derived/device/Build/Products/Release-iphoneos/TwilDiary.app/Info.plist').read_bytes())
value = {'kind': 'device-diagnostic', 'regressionAcceptance': False, 'uiRegressionPassed': True,
         'sourceSHA': subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip(),
         'buildNumber': info['CFBundleVersion'], 'codemagicBuild': os.environ['CM_BUILD_ID'], 'sha256': digest,
         'note': 'Three focused core cases, native lookup unit class and two targeted XCUITests; no full regression rerun.'}
(root / 'native-navigation-provenance.json').write_text(json.dumps(value, indent=2) + '\n')
print('Native navigation checks passed; unsigned phone IPA packaged.')
PY
