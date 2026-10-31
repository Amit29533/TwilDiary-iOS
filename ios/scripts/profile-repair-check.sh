#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
ARTIFACTS="$PWD/ios/.artifacts"
mkdir -p "$ARTIFACTS/logs"
finish() {
  local status=$?
  trap - EXIT
  for result in "$ARTIFACTS"/*.xcresult; do
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
swift test --package-path ios/Packages/TwilDiaryCore --filter 'personSectionsMatchWebRoleProminenceAndServerMediaIdentity|personFilmographyMatchesAllWebGoldenFiltersSortsAndErrors|animeAppearanceNavigationRequiresAnUnambiguousTitleMatch|voiceActorPersonMatchingUsesUniqueTmdbCastIdentity|homeAgreesWithWebWeekCoveragePlannedOrderAndUpcomingRules' 2>&1 | tee "$ARTIFACTS/logs/focused-profile-core-tests.log"
bash ios/scripts/ci.sh build-simulator
bash ios/scripts/ci.sh boot
xcodebuild test-without-building -project ios/TwilDiary.xcodeproj -scheme TwilDiary \
  -clonedSourcePackagesDirPath "$PWD/ios/.spm" CODE_SIGNING_ALLOWED=NO COMPILER_INDEX_STORE_ENABLE=NO \
  -destination "platform=iOS Simulator,id=$SIMULATOR_ID,arch=$(uname -m)" \
  -parallel-testing-enabled NO -test-timeouts-enabled YES \
  -default-test-execution-time-allowance 120 -maximum-test-execution-time-allowance 240 \
  -only-testing:TwilDiaryTests/AnimeNavigationLookupTests \
  -only-testing:TwilDiaryTests/ProfileBiographyContentTests \
  -only-testing:TwilDiaryTests/RankedPeopleTests \
  -only-testing:TwilDiaryTests/ProfileRepairTests \
  -only-testing:TwilDiaryTests/ProfileFormattingTests \
  -only-testing:TwilDiaryUITests/ProfileFormattingUITests \
  -only-testing:TwilDiaryTests/HomeMediaCardsTests \
  -only-testing:TwilDiaryUITests/NativeScreensTests/testProfileRepairsKeepNativeLinksWatchedRatingsAndHiddenTabs \
  -only-testing:TwilDiaryUITests/NativeScreensTests/testHomeMediaShelvesAndListCardsKeepRoutesAndIndependentSavedLayouts \
  -only-testing:TwilDiaryUITests/NativeScreensTests/testCharacterAppearancesAndVoiceActorAnimeOpenTheirTitleAndKeepCharacterLinks \
  -only-testing:TwilDiaryUITests/NativeScreensTests/testAnimeExactMatchesSkipTheSearchPageWithUnrelatedDiaryResults \
  -only-testing:TwilDiaryUITests/NativeScreensTests/testPersonShelvesOpenFilmographyLayoutsAndPreserveReturnNavigation \
  -only-testing:TwilDiaryUITests/NativeScreensTests/testAnimeCharactersOpenTheirPageAndHeartsCollectInFavourites \
  -only-testing:TwilDiaryUITests/NativeScreensTests/testFavouritesShelvesViewAllAndIndependentLayoutsKeepProfileNavigation \
  -derivedDataPath "$PWD/ios/.derived/simulator" -resultBundlePath "$ARTIFACTS/ProfileRepairs.xcresult" \
  2>&1 | tee "$ARTIFACTS/logs/profile-repair-tests.log"
# Repeat only the profile format matrix on compact and large phones, including
# accessibility text. Existing navigation/Home journeys run once above.
while read -r slug layout_id; do
  export SIMULATOR_ID="$layout_id"
  bash ios/scripts/ci.sh boot
  xcodebuild test-without-building -project ios/TwilDiary.xcodeproj -scheme TwilDiary \
    -clonedSourcePackagesDirPath "$PWD/ios/.spm" CODE_SIGNING_ALLOWED=NO COMPILER_INDEX_STORE_ENABLE=NO \
    -destination "platform=iOS Simulator,id=$SIMULATOR_ID,arch=$(uname -m)" \
    -parallel-testing-enabled NO -test-timeouts-enabled YES \
    -default-test-execution-time-allowance 120 -maximum-test-execution-time-allowance 240 \
    -only-testing:TwilDiaryUITests/ProfileFormattingUITests \
    -derivedDataPath "$PWD/ios/.derived/simulator" -resultBundlePath "$ARTIFACTS/ProfileLayout-$slug.xcresult" \
    2>&1 | tee "$ARTIFACTS/logs/profile-layout-$slug.log"
done < <(python3 - <<'LAYOUTS'
import json
for item in json.load(open('ios/.artifacts/layout-simulators.json')):
    print(item['name'].lower().replace(' ', '-'), item['udid'])
LAYOUTS
)
bash ios/scripts/ci.sh build-device
bash ios/scripts/ci.sh package
python3 - <<'PY'
import hashlib, json, os, pathlib, plistlib, re, shutil, subprocess
root = pathlib.Path('ios/.artifacts')
tests = (root / 'logs/profile-repair-tests.log').read_text(errors='replace')
for case in ['testProfileRepairsKeepNativeLinksWatchedRatingsAndHiddenTabs', 'testHomeMediaShelvesAndListCardsKeepRoutesAndIndependentSavedLayouts', 'testCharacterAppearancesAndVoiceActorAnimeOpenTheirTitleAndKeepCharacterLinks', 'testAnimeExactMatchesSkipTheSearchPageWithUnrelatedDiaryResults',
             'testPersonShelvesOpenFilmographyLayoutsAndPreserveReturnNavigation',
             'testAnimeCharactersOpenTheirPageAndHeartsCollectInFavourites',
             'testFavouritesShelvesViewAllAndIndependentLayoutsKeepProfileNavigation']:
    if not re.search(r'Test Case .*' + re.escape(case) + r'.* passed', tests):
        raise SystemExit('Required native UI case did not pass: ' + case)
if not re.search(r"Test Suite '[^']*AnimeNavigationLookupTests' passed", tests):
    raise SystemExit('Native lookup unit tests did not pass.')
if not re.search(r"Test Suite '[^']*ProfileBiographyContentTests' passed", tests):
    raise SystemExit('Profile biography and date tests did not pass.')
if not re.search(r"Test Suite '[^']*RankedPeopleTests' passed", tests):
    raise SystemExit('Ranking identity and snapshot tests did not pass.')
for suite in ['ProfileRepairTests', 'ProfileFormattingTests', 'HomeMediaCardsTests']:
    if not re.search(r"Test Suite '[^']*" + suite + r"' passed", tests):
        raise SystemExit('Required focused unit suite did not pass: ' + suite)
format_cases = ['testCastProfilesKeepLocationsContextAliasesAndAgeAtDeath', 'testCharacterProfilesPreserveRangesYearOnlyDatesAndNativeRelationships', 'testVoiceProfilesSeparateLinksFactsCareerAndBiography', 'testLargeTextStacksFactsAndKeepsHeartsPinnedAcrossProfileTypes']
for name in ['profile-repair-tests.log', 'profile-layout-iphone-17e.log', 'profile-layout-iphone-17-pro-max.log']:
    log = (root / 'logs' / name).read_text(errors='replace')
    for case in format_cases:
        if not re.search(r'Test Case .*' + re.escape(case) + r'.* passed', log):
            raise SystemExit('Profile matrix did not pass: ' + name + ' ' + case)
core = (root / 'logs/focused-profile-core-tests.log').read_text(errors='replace')
for case in ['personSectionsMatchWebRoleProminenceAndServerMediaIdentity', 'personFilmographyMatchesAllWebGoldenFiltersSortsAndErrors', 'animeAppearanceNavigationRequiresAnUnambiguousTitleMatch', 'voiceActorPersonMatchingUsesUniqueTmdbCastIdentity', 'homeAgreesWithWebWeekCoveragePlannedOrderAndUpcomingRules']:
    if case + '() passed' not in core:
        raise SystemExit('Required focused core case did not pass: ' + case)
for name in ['simulator-build.log', 'device-build.log']:
    log = (root / 'logs' / name).read_text(errors='replace')
    if re.search(r'\bwarning:', log, re.I):
        raise SystemExit('Build warning in ' + name)
ipa = root / 'TwilDiary-profile-repairs.ipa'
shutil.copyfile(root / 'TwilDiary-unsigned.ipa', ipa)
digest = hashlib.sha256(ipa.read_bytes()).hexdigest()
(root / (ipa.name + '.sha256')).write_text(digest + '  ' + ipa.name + '\n')
info = plistlib.loads(pathlib.Path('ios/.derived/device/Build/Products/Release-iphoneos/TwilDiary.app/Info.plist').read_bytes())
value = {'kind': 'device-diagnostic', 'regressionAcceptance': False, 'uiRegressionPassed': True,
         'sourceSHA': subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip(),
         'buildNumber': info['CFBundleVersion'], 'codemagicBuild': os.environ['CM_BUILD_ID'], 'sha256': digest,
         'note': 'Five focused core cases; lookup, profile, formatting, ranking and Home model units; seven navigation/Home journeys and four profile matrix journeys on each of three phone sizes, including accessibility text. No full regression rerun.'}
(root / 'profile-repair-provenance.json').write_text(json.dumps(value, indent=2) + '\n')
print('Focused profile repair checks passed; unsigned phone IPA packaged.')
PY
