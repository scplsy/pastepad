#!/bin/bash
set -euo pipefail

tapaste_project_dir="$(cd "$(dirname "$0")/.." && pwd)"
tapaste_test_dir="$(mktemp -d "${TMPDIR:-/tmp}/tapaste-group-swipe.XXXXXX")"
trap 'rm -rf "$tapaste_test_dir"' EXIT

if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app/Contents/Developer ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

xcrun swiftc -swift-version 5 -parse-as-library \
    "$tapaste_project_dir/Tapaste/GroupSwipeRecognizer.swift" \
    "$tapaste_project_dir/Tests/GroupSwipeTests.swift" \
    -o "$tapaste_test_dir/group-swipe-tests"

"$tapaste_test_dir/group-swipe-tests"
