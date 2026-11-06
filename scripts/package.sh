#!/bin/bash
set -euo pipefail

pastepad_root="$(cd "$(dirname "$0")/.." && pwd)"
bash "$pastepad_root/scripts/build.sh"
codesign --verify --strict "$pastepad_root/build/PastePad.app"

pastepad_stage="$(mktemp -d "${TMPDIR:-/tmp}/pastepad-installer.XXXXXX")"
trap 'rm -rf "$pastepad_stage"' EXIT
ditto "$pastepad_root/build/PastePad.app" "$pastepad_stage/PastePad.app"
ln -s /Applications "$pastepad_stage/Applications"
hdiutil create -volname PastePad -srcfolder "$pastepad_stage" \
    -format UDZO -ov "$pastepad_root/build/PastePad.dmg"
hdiutil verify "$pastepad_root/build/PastePad.dmg"
printf '\nInstaller: %s/build/PastePad.dmg\n' "$pastepad_root"
