#!/bin/bash
set -euo pipefail

tapaste_project_dir="$(cd "$(dirname "$0")/.." && pwd)"
tapaste_test_dir="$(mktemp -d "${TMPDIR:-/tmp}/tapaste-hotkey-test.XXXXXX")"
trap 'rm -rf "$tapaste_test_dir"' EXIT

if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app/Contents/Developer ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

tapaste_test_arch="$(uname -m)"
xcrun swiftc -swift-version 5 -parse-as-library \
    -target "${tapaste_test_arch}-apple-macos13.0" \
    -framework AppKit -framework Carbon \
    "$tapaste_project_dir/Tapaste/AppSettings.swift" \
    "$tapaste_project_dir/Tapaste/Localization.swift" \
    "$tapaste_project_dir/Tapaste/ClipboardModels.swift" \
    "$tapaste_project_dir/Tapaste/ClipboardStore.swift" \
    "$tapaste_project_dir/Tapaste/PlatformServices.swift" \
    "$tapaste_project_dir/Tests/HotKeyTests.swift" \
    -o "$tapaste_test_dir/hotkey-tests"

# Exit code 77 means the desktop session could not reserve both candidates.
"$tapaste_test_dir/hotkey-tests"
