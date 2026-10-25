#!/usr/bin/env bash
set -euo pipefail

# The same verified universal vendor binary on Intel GitHub and Apple Silicon
# Codemagic. Never use a machine's unpinned preinstalled/Homebrew executable.
tool_temp="${RUNNER_TEMP:-${TMPDIR:-/tmp}}"
archive="$tool_temp/twildiary-xcodegen-2.46.0.zip"
curl --fail --location --retry 3 --retry-all-errors --connect-timeout 20 --max-time 120 --silent --show-error \
  https://github.com/yonaskolb/XcodeGen/releases/download/2.46.0/xcodegen.zip --output "$archive"
printf '%s  %s\n' 4d9e34b62172d645eed6457cac13fc222569974098ef4ee9c3368bedf0196806 "$archive" | shasum -a 256 --check -
tools_dir="$(mktemp -d "$tool_temp/twildiary-xcodegen.XXXXXX")"
unzip -q "$archive" -d "$tools_dir"
"$tools_dir/xcodegen/bin/xcodegen" --version
"$tools_dir/xcodegen/bin/xcodegen" generate --spec ios/project.yml
