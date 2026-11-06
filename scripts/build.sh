#!/bin/bash
set -euo pipefail

tapaste_root="$(cd "$(dirname "$0")/.." && pwd)"
if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app/Contents/Developer ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

xcodebuild -project "$tapaste_root/Tapaste.xcodeproj" -scheme Tapaste \
    -configuration Release -destination 'generic/platform=macOS' \
    -derivedDataPath "$tapaste_root/build/DerivedData" \
    CODE_SIGN_IDENTITY=- build

ditto "$tapaste_root/build/DerivedData/Build/Products/Release/PastePad.app" "$tapaste_root/build/PastePad.app"
ditto -c -k --sequesterRsrc --keepParent "$tapaste_root/build/PastePad.app" "$tapaste_root/build/PastePad.zip"
printf '\nBuilt: %s/build/PastePad.app\n' "$tapaste_root"
