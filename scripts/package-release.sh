#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
python3 scripts/privacy-audit.py --app build/Ember.app
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' build/Ember.app/Contents/Info.plist)"
architecture="$(uname -m)"
mkdir -p dist
archive="Ember-$version-macOS-$architecture.zip"
# Explicitly archive only the sealed app. Exclude build caches, local diagnostics,
# real-app screenshots, preferences, resource forks and extended attributes.
COPYFILE_DISABLE=1 ditto -c -k --norsrc --noextattr --noqtn --keepParent build/Ember.app "dist/$archive"
python3 - "$archive" <<'PY'
import hashlib,pathlib,sys,zipfile
path=pathlib.Path('dist')/sys.argv[1]
with zipfile.ZipFile(path) as z:
    names=z.namelist()
    if any(not n.startswith('Ember.app/') or '__MACOSX' in n or n.endswith('.DS_Store') for n in names):
        raise SystemExit('Unexpected archive content')
checksum=hashlib.sha256(path.read_bytes()).hexdigest()
(path.parent/'SHA256SUMS').write_text(f'{checksum}  {path.name}\n')
print(f'Packaged {path.name}; SHA-256 {checksum}')
PY
