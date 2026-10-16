#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
configuration="${1:-release}"
if [[ "$configuration" != release && "$configuration" != debug ]]; then
    echo "Usage: $0 [release|debug]" >&2
    exit 1
fi
signing_identity="${EMBER_SIGNING_IDENTITY:--}"
mkdir -p build
assembly="$(mktemp -d "$PWD/build/assembly.XXXXXX")"
app="$assembly/Ember.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$app/Contents/Library/LaunchDaemons"
build_flags=(--build-system native -c "$configuration" -Xswiftc -gnone -Xswiftc -file-prefix-map -Xswiftc "$PWD=/Ember" -Xswiftc -debug-prefix-map -Xswiftc "$PWD=/Ember" -Xcc -g0 -Xcc "-ffile-prefix-map=$PWD=/Ember")
swift build "${build_flags[@]}" --product Ember
binary_directory="$(swift build --build-system native -c "$configuration" --show-bin-path)"
cp "$binary_directory/Ember" "$app/Contents/MacOS/Ember"
swift build "${build_flags[@]}" --product EmberFanClient
cp "$binary_directory/EmberFanClient" "$app/Contents/MacOS/EmberFanClient"
if [[ "$configuration" == release ]]; then
    strip -S "$app/Contents/MacOS/Ember" "$app/Contents/MacOS/EmberFanClient"
fi
codesign --force --options runtime --sign "$signing_identity" --identifier app.ember.heatmonitor.fanclient "$app/Contents/MacOS/EmberFanClient"
client_hash="$(codesign -dvvv "$app/Contents/MacOS/EmberFanClient" 2>&1 | sed -n 's/^CDHash=//p')"
if [[ ! "$client_hash" =~ ^[0-9a-f]{40}$ ]]; then echo 'Missing client signing hash' >&2; exit 1; fi
# Public code-identity pin, not a key or credential. Null-terminated Mach-O section.
printf 'identifier "app.ember.heatmonitor.fanclient" and cdhash H"%s"\0' "$client_hash" > build/fan-client-requirement.bin
swift build "${build_flags[@]}" --product EmberFanHelper \
    -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __ember_client -Xlinker "$PWD/build/fan-client-requirement.bin"
cp "$binary_directory/EmberFanHelper" "$app/Contents/MacOS/EmberFanHelper"
if [[ "$configuration" == release ]]; then strip -S "$app/Contents/MacOS/EmberFanHelper"; fi
codesign --force --options runtime --sign "$signing_identity" --identifier app.ember.heatmonitor.fans "$app/Contents/MacOS/EmberFanHelper"
cp Resources/Info.plist "$app/Contents/Info.plist"
cp Resources/LaunchDaemons/*.plist "$app/Contents/Library/LaunchDaemons/"
python3 - "$app" <<'PYBUILD'
import pathlib,plistlib,re,subprocess,sys
app=pathlib.Path(sys.argv[1])
info=subprocess.run(['codesign','-dvvv',str(app/'Contents/MacOS/EmberFanHelper')],capture_output=True,check=True).stderr
hash=re.search(rb'^CDHash=([a-f0-9]{40})$',info,re.M)[1].decode()
path=app/'Contents/Library/LaunchDaemons/app.ember.heatmonitor.fans.plist'
plist=plistlib.loads(path.read_bytes())
# Explicit exact-code launch policy. A rebuild updates the configuration checksum
# rather than relying on a cached designated requirement for an older ad-hoc build.
plist['SpawnConstraint']={'signing-identifier':'app.ember.heatmonitor.fans','cdhash':bytes.fromhex(hash)}
path.write_bytes(plistlib.dumps(plist))
PYBUILD
swift scripts/icon.swift "$PWD/build/Ember.iconset"
iconutil -c icns "$PWD/build/Ember.iconset" -o "$app/Contents/Resources/Ember.icns"
codesign --force --options runtime --sign "$signing_identity" "$app"
codesign --verify --deep --strict "$app"
if [[ -d build/Ember.app ]]; then
    previous="$(mktemp -d "$PWD/build/previous-build.XXXXXX")"
    mv build/Ember.app "$previous/Ember.app"
fi
mv "$app" "$PWD/build/Ember.app"
rmdir "$assembly"
echo "Built $PWD/build/Ember.app"
