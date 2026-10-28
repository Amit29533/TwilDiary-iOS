#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
ARTIFACTS="$PWD/ios/.artifacts"
mkdir -p "$ARTIFACTS/logs"
PROJECT="$PWD/ios/TwilDiary.xcodeproj"
COMMON=(-project "$PROJECT" -scheme TwilDiary -clonedSourcePackagesDirPath "$PWD/ios/.spm" CODE_SIGNING_ALLOWED=NO COMPILER_INDEX_STORE_ENABLE=NO -showBuildTimingSummary)
SIM_ARCH=$(uname -m)

case "${1:?CI stage required}" in
  inventory)
    { sw_vers; xcodebuild -version; swift --version; } | tee "$ARTIFACTS/toolchain.txt"
    xcrun simctl list devices available -j > "$ARTIFACTS/devices.json"
    cat "$ARTIFACTS/devices.json"
    python3 - "$ARTIFACTS" <<'PY'
import json, os, pathlib, re, sys
folder = pathlib.Path(sys.argv[1])
devices = json.loads((folder / 'devices.json').read_text())['devices']
candidates = [(runtime, device) for runtime, items in devices.items() if runtime == 'com.apple.CoreSimulator.SimRuntime.iOS-26-5'
              for device in items if device['name'] == 'iPhone 17 Pro' and device.get('isAvailable', True)]
if not candidates:
    raise SystemExit('Required iPhone 17 Pro simulator is unavailable; inspect devices.json')
runtime, device = max(candidates, key=lambda item: tuple(map(int, re.findall(r'\d+', item[0]))))
record = {'runtime': runtime, 'name': device['name'], 'udid': device['udid']}
(folder / 'simulator.json').write_text(json.dumps(record, indent=2) + '\n')
layout = []
for name in ['iPhone 17e', 'iPhone 17 Pro Max']:
    match = next((item for item in devices[runtime] if item['name'] == name and item.get('isAvailable', True)), None)
    if match is None: raise SystemExit('Required layout simulator unavailable: ' + name)
    layout.append({'name': name, 'udid': match['udid']})
(folder / 'layout-simulators.json').write_text(json.dumps(layout, indent=2) + '\n')
print('Selected simulator:', json.dumps(record))
with open(os.environ['GITHUB_ENV'], 'a') as file:
    file.write('SIMULATOR_ID=' + device['udid'] + '\n')
PY
    SIM_ID=$(python3 -c 'import json; print(json.load(open("ios/.artifacts/simulator.json"))["udid"])')
    xcrun simctl boot "$SIM_ID" || true
    ;;
  build-simulator)
    xcodebuild build-for-testing "${COMMON[@]}" -destination "platform=iOS Simulator,id=$SIMULATOR_ID,arch=$SIM_ARCH" \
      -derivedDataPath "$PWD/ios/.derived/simulator" 2>&1 | tee "$ARTIFACTS/logs/simulator-build.log"
    python3 -B ios/tools/test_verify_build_log.py
    python3 ios/tools/verify-build-log.py "$ARTIFACTS/logs/simulator-build.log" '** TEST BUILD SUCCEEDED **'
    ;;
  build-device)
    xcodebuild build "${COMMON[@]}" -destination 'generic/platform=iOS' -configuration Release \
      -derivedDataPath "$PWD/ios/.derived/device" 2>&1 | tee "$ARTIFACTS/logs/device-build.log"
    python3 -B ios/tools/test_verify_build_log.py
    python3 ios/tools/verify-build-log.py "$ARTIFACTS/logs/device-build.log" '** BUILD SUCCEEDED **'
    ;;
  package)
    python3 -B ios/tools/test_verify_release_resources.py
    python3 ios/tools/verify-release-resources.py "$PWD/ios/.derived/device/Build/Products/Release-iphoneos/TwilDiary.app" | tee "$ARTIFACTS/logs/release-resources.log"
    mkdir -p "$ARTIFACTS/package/Payload"
    cp -R ios/.derived/device/Build/Products/Release-iphoneos/TwilDiary.app "$ARTIFACTS/package/Payload/"
    (cd "$ARTIFACTS/package" && ditto -c -k --keepParent Payload ../TwilDiary-unsigned.ipa)
    (cd "$ARTIFACTS" && shasum -a 256 TwilDiary-unsigned.ipa > TwilDiary-unsigned.ipa.sha256)
    ;;
  boot)
    xcrun simctl bootstatus "$SIMULATOR_ID" -b 2>&1 | tee "$ARTIFACTS/logs/simulator-boot.log"
    ;;
  test-unit)
    python3 -B ios/tools/test_run_bounded.py
    python3 ios/tools/run-bounded.py 480 xcodebuild test-without-building "${COMMON[@]}" -destination "platform=iOS Simulator,id=$SIMULATOR_ID,arch=$SIM_ARCH" \
      -parallel-testing-enabled NO -test-timeouts-enabled YES -default-test-execution-time-allowance 120 -maximum-test-execution-time-allowance 180 \
      -only-testing:TwilDiaryTests -derivedDataPath "$PWD/ios/.derived/simulator" -resultBundlePath "$ARTIFACTS/UnitTests.xcresult" \
      2>&1 | tee "$ARTIFACTS/logs/unit-tests.log"
    ;;
  test-repairs)
    # Exercise the actually failing cases before spending time on the long suite.
    # No retry-until-pass; any failure stops the run and retains its evidence.
    xcodebuild test-without-building "${COMMON[@]}" -destination "platform=iOS Simulator,id=$SIMULATOR_ID,arch=$SIM_ARCH" \
      -parallel-testing-enabled NO -test-timeouts-enabled YES -default-test-execution-time-allowance 180 -maximum-test-execution-time-allowance 240 \
      -only-testing:TwilDiaryUITests/NativeScreensTests/testT31LibraryLayoutAndSortSurviveAProcessRelaunch \
      -only-testing:TwilDiaryUITests/NativeScreensTests/testT35WatchedEpisodeOffersRewatchAndUndoKeepsItsOriginalWatch \
      -only-testing:TwilDiaryUITests/NativeScreensTests/testContinueCarouselSwipesAndRestoresAcrossTabsWithoutOverflowMenu \
      -only-testing:TwilDiaryUITests/NativeScreensTests/testToastExpiresAndCardCoverAndUsefulMenuWork \
      -only-testing:TwilDiaryUITests/NativeScreensTests/testNativeTabsAndTitleNavigation \
      -only-testing:TwilDiaryUITests/NativeScreensTests/testRootContentSwipesVisitEveryTabWithoutWrappingAndKeepCardGestures \
      -only-testing:TwilDiaryUITests/NativeScreensTests/testNavigationLensCanBeHeldAndSlidAcrossTheBarAndCancelledOutsideIt \
      -only-testing:TwilDiaryUITests/NativeScreensTests/testCollectionGridsKeepEpisodeActionsFoldersAndHistoryEntries \
      -only-testing:TwilDiaryUITests/NativeScreensTests/testTitleMenuRevealsAndScrollsNotesAndLocationsAndCopiesAPath \
      -only-testing:TwilDiaryUITests/NativeScreensTests/testCommunityInformationSheetUsesOverallStatsAndReturnsToTheTitle       -only-testing:TwilDiaryUITests/NativeScreensTests/testTraktReviewResolvesAWholeGroupOnlyAfterConfirmation       -only-testing:TwilDiaryUITests/NativeScreensTests/testTraktReviewAppliesSafeChangesThenRequiresAnExplicitConflictChoice \
      -only-testing:TwilDiaryUITests/NativeScreensTests/testApprovedLargeTraktImportKeepsRunningAcrossNativeTabsAndOffersPause \
      -only-testing:TwilDiaryUITests/NativeScreensTests/testColdQuotaImportRestoresAcrossTabsAfterResetWithoutManualRetry \
      -only-testing:TwilDiaryUITests/NativeScreensTests/testNativeBackReturnsFromEverySettingsDestination \
      -only-testing:TwilDiaryUITests/NativeScreensTests/testNativeExploreReturnsByBackActiveHomeTabAndFullContentSwipe \
      -only-testing:TwilDiaryUITests/LayoutScreensTests/testEveryThemeIsSelectableAndGlassSearchKeepsOneContainedField \
      -only-testing:TwilDiaryUITests/NativeScreensTests/testPersonShelvesOpenFilmographyLayoutsAndPreserveReturnNavigation \
      -only-testing:TwilDiaryUITests/NativeScreensTests/testTitleWatchAndUndoUpdateTheEpisodePiecesAndMovieHistory \
      -only-testing:TwilDiaryUITests/NativeScreensTests/testSearchReturnsDirectlyToRetainedResultsAndGlanceRemainsScoped \
      -derivedDataPath "$PWD/ios/.derived/simulator" -resultBundlePath "$ARTIFACTS/RepairGate.xcresult" \
      2>&1 | tee "$ARTIFACTS/logs/repair-tests.log"
    ;;
  test-progress)
    xcodebuild test-without-building "${COMMON[@]}" -destination "platform=iOS Simulator,id=$SIMULATOR_ID,arch=$SIM_ARCH" \
      -parallel-testing-enabled NO -test-timeouts-enabled YES -default-test-execution-time-allowance 300 -maximum-test-execution-time-allowance 360 \
      -only-testing:TwilDiaryUITests/NativeScreensTests/testTitleWatchAndUndoUpdateTheEpisodePiecesAndMovieHistory \
      -only-testing:TwilDiaryUITests/NativeScreensTests/testConfirmedWatchRefreshFailureRecoversWithoutAnotherWatchAndPreservesUndo \
      -only-testing:TwilDiaryUITests/NativeScreensTests/testFilesAndScannerMatchPublishLocationWithoutChangingWatchHistory \
      -only-testing:TwilDiaryUITests/NativeScreensTests/testManualTitleYearValidationStatusRatingAndSavedNavigation \
      -only-testing:TwilDiaryUITests/NativeScreensTests/testNativeExploreReturnsByBackActiveHomeTabAndFullContentSwipe \
      -only-testing:TwilDiaryUITests/NativeScreensTests/testRandomPickKeepsPlannedScopeAndLogoRerollsWithoutRepeating \
      -only-testing:TwilDiaryUITests/NativeScreensTests/testSearchReturnsDirectlyToRetainedResultsAndGlanceRemainsScoped \
      -only-testing:TwilDiaryUITests/NativeScreensTests/testTitleArtworkScrollsAwayBeforeTheEpisodeAndNotesContent \
      -only-testing:TwilDiaryUITests/NativeScreensTests/testNativeBackReturnsFromEverySettingsDestination \
      -only-testing:TwilDiaryUITests/NativeScreensTests/testGlanceNotesWaitForLateCastAndRelatedLayoutThenKeepEditorVisible \
      -derivedDataPath "$PWD/ios/.derived/simulator" -resultBundlePath "$ARTIFACTS/ProgressGate.xcresult" \
      2>&1 | tee "$ARTIFACTS/logs/progress-tests.log"
    ;;
  test)
    xcodebuild test-without-building -only-testing:TwilDiaryUITests "${COMMON[@]}" -destination "platform=iOS Simulator,id=$SIMULATOR_ID,arch=$SIM_ARCH" \
      -parallel-testing-enabled NO -test-timeouts-enabled YES -default-test-execution-time-allowance 300 -maximum-test-execution-time-allowance 360 -derivedDataPath "$PWD/ios/.derived/simulator" \
      -resultBundlePath "$ARTIFACTS/Tests.xcresult" 2>&1 | tee "$ARTIFACTS/logs/tests.log"
    ;;
  test-layouts)
    xcrun simctl shutdown "$SIMULATOR_ID" || true
    layout_status=0
    while IFS=$'\t' read -r layout_name layout_id; do
      if ! xcrun simctl boot "$layout_id" || ! xcrun simctl bootstatus "$layout_id" -b; then
        echo "Layout simulator failed to boot: $layout_name" >&2
        layout_status=1
        xcrun simctl shutdown "$layout_id" || true
        continue
      fi
      if ! xcodebuild test-without-building "${COMMON[@]}" -destination "platform=iOS Simulator,id=$layout_id,arch=$SIM_ARCH" \
        -parallel-testing-enabled NO -test-timeouts-enabled YES -default-test-execution-time-allowance 300 -maximum-test-execution-time-allowance 360 -only-testing:TwilDiaryUITests/LayoutScreensTests \
        -derivedDataPath "$PWD/ios/.derived/simulator" -resultBundlePath "$ARTIFACTS/Layout-$layout_name.xcresult" \
        2>&1 | tee "$ARTIFACTS/logs/layout-$layout_name-tests.log"; then
        layout_status=1
      fi
      xcrun simctl shutdown "$layout_id" || true
    done < <(python3 -c 'import json; [print(item["name"].replace(" ", "") + "\t" + item["udid"]) for item in json.load(open("ios/.artifacts/layout-simulators.json"))]')
    exit "$layout_status"
    ;;
  screenshots-progress)
    python3 - "$ARTIFACTS" <<'PY'
import json, os, pathlib, re, shutil, sys
folder = pathlib.Path(sys.argv[1])
value = (folder / 'logs/progress-tests.log').read_text(errors='replace')
cases = set(re.findall(r"Test Case '-\[TwilDiaryUITests\.NativeScreensTests ([^]]+)\]' passed", value))
if '** TEST EXECUTE SUCCEEDED **' not in value or len(cases) != 10 or re.search(r'Test Case .* failed', value):
    raise SystemExit('Refusing passed early screenshots without the ten successful UI cases.')
target = folder / 'progress-evidence'
target.mkdir(parents=True, exist_ok=True)
shutil.copy2(folder / 'logs/progress-tests.log', target / 'progress-tests.log')
(target / 'scope.json').write_text(json.dumps({
    'scope': 'Ten passed early UI cases only. Full regression and release acceptance are pending.',
    'source': os.environ.get('GITHUB_SHA') or os.environ.get('CM_COMMIT'),
    'run': os.environ.get('GITHUB_RUN_ID') or os.environ.get('CM_BUILD_ID'),
    'tests': sorted(cases)
}, indent=2) + '\n')
PY
    xcrun xcresulttool export attachments --path "$ARTIFACTS/ProgressGate.xcresult" --output-path "$ARTIFACTS/progress-evidence/screenshots"
    ;;
  screenshots)
    mkdir -p "$ARTIFACTS/screenshots"
    # DEBUG app diagnostics contain only native stack/gesture flags, never title
    # names, account data, URLs or credentials. Retain them even after UI failure.
    xcrun simctl spawn "$SIMULATOR_ID" log show --style compact --last 2h \
      --predicate 'subsystem == "com.amit29533.TwilDiary.navigation"' \
      > "$ARTIFACTS/logs/navigation-runtime.log" 2>&1 || true
    xcrun simctl io "$SIMULATOR_ID" screenshot "$ARTIFACTS/screenshots/final-screen.png" || true
    if [ -f "$ARTIFACTS/Tests.xcresult/Info.plist" ]; then
      xcrun xcresulttool export attachments --path "$ARTIFACTS/Tests.xcresult" --output-path "$ARTIFACTS/screenshots"
    fi
    if [ -f "$ARTIFACTS/ProgressGate.xcresult/Info.plist" ]; then
      xcrun xcresulttool export attachments --path "$ARTIFACTS/ProgressGate.xcresult" --output-path "$ARTIFACTS/screenshots/ProgressGate"
    fi
    if [ -f "$ARTIFACTS/RepairGate.xcresult/Info.plist" ]; then
      xcrun xcresulttool export attachments --path "$ARTIFACTS/RepairGate.xcresult" --output-path "$ARTIFACTS/screenshots/RepairGate"
    fi
    for result in "$ARTIFACTS"/Layout-*.xcresult; do
      if [ -f "$result/Info.plist" ]; then
        folder_name=$(basename "$result" .xcresult)
        xcrun xcresulttool export attachments --path "$result" --output-path "$ARTIFACTS/screenshots/$folder_name"
      fi
    done
    ;;
  summary)
    python3 - "$ARTIFACTS" <<'PY'
import os, pathlib, re, sys
folder = pathlib.Path(sys.argv[1]); warnings = []; errors = []; tests = []
for path in sorted((folder / 'logs').glob('*.log')):
    for line in path.read_text(errors='replace').splitlines():
        if re.search(r'\b(?:error:|Test Case .* failed)', line): errors.append(f'{path.name}: {line}')
        if ('build' in path.name or path.name == 'core-tests.log') and re.search(r'\bwarning:', line, re.I): warnings.append(f'{path.name}: {line}')
        if re.search(r'Executed \d+ tests|\*\* TEST .* \*\*', line): tests.append(line)
progress_log = folder / 'logs' / 'progress-tests.log'
if progress_log.exists() and '** TEST EXECUTE SUCCEEDED **' not in progress_log.read_text(errors='replace'):
    errors.append('Progress drag/Undo preflight did not complete successfully; inspect ProgressGate.xcresult.')
unit_log = folder / 'logs' / 'unit-tests.log'
if not unit_log.exists() or '** TEST EXECUTE SUCCEEDED **' not in unit_log.read_text(errors='replace'):
    errors.append('Native unit execution did not finish successfully; inspect UnitTests.xcresult.')
repair_log = folder / 'logs' / 'repair-tests.log'
if not repair_log.exists() or '** TEST EXECUTE SUCCEEDED **' not in repair_log.read_text(errors='replace'):
    errors.append('Current stability repair gate incomplete/failed; inspect RepairGate.xcresult.')
test_log = folder / 'logs' / 'tests.log'
if not test_log.exists() or '** TEST EXECUTE SUCCEEDED **' not in test_log.read_text(errors='replace'):
    errors.append('tests.log: Unit/UI execution did not finish successfully; inspect the job timeout and xcresult before accepting this build.')
layout_config = folder / 'layout-simulators.json'
if layout_config.exists():
    import json
    for device in json.loads(layout_config.read_text()):
        path = folder / 'logs' / ('layout-' + device['name'].replace(' ', '') + '-tests.log')
        if not path.exists() or '** TEST EXECUTE SUCCEEDED **' not in path.read_text(errors='replace'):
            errors.append('Layout regression incomplete/failed: ' + device['name'])
summary = '\n'.join(['## iOS build diagnostics', f'Build warnings: {len(warnings)}', f'Errors/failures: {len(errors)}',
                     *errors[:20], *warnings[:20], *tests[-12:]]) + '\n'
print(summary)
if os.environ.get('GITHUB_STEP_SUMMARY'):
    with open(os.environ['GITHUB_STEP_SUMMARY'], 'a') as output: output.write(summary)
if warnings or errors: raise SystemExit(1)
PY
    ;;
  *) echo 'Unknown CI stage' >&2; exit 2 ;;
esac
