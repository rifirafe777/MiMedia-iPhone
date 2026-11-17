#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo 'Este paso necesita macOS con Xcode. Windows solo prepara las fuentes.' >&2
  exit 1
fi
test -s Web/index.html
test -s Web/native.js
xcodebuild -version
xcodegen --version
xcodegen generate --spec project.yml
build_root="$(mktemp -d "${TMPDIR:-/tmp}/mimedia-ipa.XXXXXX")"
mkdir -p "$build_root/derived" "$build_root/package/Payload" artifacts
xcodebuild -project MiMedia.xcodeproj -scheme MiMedia -configuration Release \
  -sdk iphoneos -destination 'generic/platform=iOS' \
  -derivedDataPath "$build_root/derived" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
  build 2>&1 | tee artifacts/build.log

app="$build_root/derived/Build/Products/Release-iphoneos/MiMedia.app"
test -d "$app"
executable=$(/usr/libexec/PlistBuddy -c 'Print CFBundleExecutable' "$app/Info.plist")
test -s "$app/$executable"
test -s "$app/Web/index.html"
test -s "$app/Web/native.js"
test -s "$app/prueba-mimedia.wav"
lipo -archs "$app/$executable" | grep -qw arm64
file "$app/$executable" | grep -q 'Mach-O'
/usr/libexec/PlistBuddy -c 'Print UIBackgroundModes' "$app/Info.plist" | grep -qw audio
ditto "$app" "$build_root/package/Payload/MiMedia.app"
(cd "$build_root/package" && ditto -c -k --keepParent Payload "$build_root/MiMedia-unsigned.ipa")
unzip -t "$build_root/MiMedia-unsigned.ipa"
unzip -Z1 "$build_root/MiMedia-unsigned.ipa" | grep -q '^Payload/MiMedia.app/Info.plist$'
cp "$build_root/MiMedia-unsigned.ipa" artifacts/MiMedia-unsigned.ipa
shasum -a 256 artifacts/MiMedia-unsigned.ipa > artifacts/SHA256SUMS.txt
printf '%s\n' 'Dispositivo arm64; compilado sin firma Apple para firma personal posterior en AltStore. Instalacion y audio en iPhone pendientes de validar.' > artifacts/ESTADO.txt
echo 'IPA sin firma generado y estructura comprobada. No esta firmado ni instalado.'
