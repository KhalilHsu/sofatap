#!/bin/bash
# Source-identical fallback when installed Xcode SDK/runtime versions prevent destination selection.
# This does not install to a device, create a provisioning profile, or prove physical-device behavior.
set -euo pipefail
IOS_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_MODE="${1:-simulator}"
case "$BUILD_MODE" in
  simulator) BUILD_SDK=iphonesimulator; BUILD_TARGET=arm64-apple-ios15.0-simulator; BUILD_PLATFORM=iPhoneSimulator ;;
  device) BUILD_SDK=iphoneos; BUILD_TARGET=arm64-apple-ios15.0; BUILD_PLATFORM=iPhoneOS ;;
  *) printf 'Usage: %s [simulator|device]\n' "$0" >&2; exit 2 ;;
esac
BUILD_SDK_PATH="$(xcrun --sdk "$BUILD_SDK" --show-sdk-path)"
# FileProvider-backed Documents folders may add FinderInfo immediately after xattr removal.
# Build and sign in a fresh temporary directory, never mutate global Xcode caches or simulators.
BUILD_STAGE="$(mktemp -d "${TMPDIR:-/tmp}/sofatap-ios-${BUILD_MODE}.XXXXXX")"
APP_BUNDLE="$BUILD_STAGE/SofaTap.app"
mkdir -p "$APP_BUNDLE"
sources=()
while IFS= read -r source; do sources+=("$source"); done < <(find "$IOS_ROOT/SofaTap" -type f -name '*.swift' | LC_ALL=C sort)
compile_args=(-emit-executable -target "$BUILD_TARGET" -sdk "$BUILD_SDK_PATH" -swift-version 5 -module-name SofaTap)
if [[ "$BUILD_MODE" == simulator ]]; then
  # Match Xcode's simulated entitlement sections. Putting iOS identity into the macOS
  # host code signature is restricted and makes amfid reject an adhoc simulator app.
  xcrun derq query -f xml -i "$IOS_ROOT/Simulator.entitlements" -o "$BUILD_STAGE/Simulator.entitlements.der" --raw
  compile_args+=(-Xlinker -sectcreate -Xlinker __TEXT -Xlinker __entitlements -Xlinker "$IOS_ROOT/Simulator.entitlements"
                 -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __ents_der -Xlinker "$BUILD_STAGE/Simulator.entitlements.der")
fi
xcrun --sdk "$BUILD_SDK" swiftc "${compile_args[@]}" "${sources[@]}" -o "$APP_BUNDLE/SofaTap"
python3 - "$IOS_ROOT/SofaTap/Info.plist" "$APP_BUNDLE/Info.plist" "$BUILD_PLATFORM" "$BUILD_SDK" "$IOS_ROOT/project.yml" <<'PY'
import plistlib
import re
import sys
from pathlib import Path
source, output, platform, sdk, project = sys.argv[1:]
# Read the two scalar XcodeGen settings without requiring a YAML dependency.
# Reject ambiguous/missing settings instead of producing a stale version.
settings = Path(project).read_text()
def version_setting(name, pattern):
    matches = re.findall(r'^\s*' + name + r':\s*["\']?(' + pattern + r')["\']?\s*$', settings, re.MULTILINE)
    if len(matches) != 1:
        raise SystemExit(f"Expected one valid {name} in {project}")
    return matches[0]
version = version_setting('MARKETING_VERSION', r'\d+\.\d+(?:\.\d+)?')
build = version_setting('CURRENT_PROJECT_VERSION', r'\d+')
family_settings = re.findall(r'^\s*TARGETED_DEVICE_FAMILY:\s*["\']?([\d, ]+)["\']?\s*$', settings, re.MULTILINE)
families = {tuple(int(item.strip()) for item in value.split(',')) for value in family_settings}
if len(families) != 1:
    raise SystemExit(f"Expected consistent TARGETED_DEVICE_FAMILY settings in {project}")
device_family = list(families.pop())
if device_family != [1, 2]:
    raise SystemExit("The fallback supports the universal iPhone/iPad app only")
data = plistlib.loads(Path(source).read_bytes())
data.update({
    'CFBundleName': 'Sofatap', 'CFBundleIdentifier': 'com.chekusu.sofatap',
    'CFBundleExecutable': 'SofaTap', 'CFBundleShortVersionString': version,
    'CFBundleVersion': build, 'CFBundleSupportedPlatforms': [platform],
    'CFBundleDevelopmentRegion': 'en',
    'DTPlatformName': sdk, 'MinimumOSVersion': '15.0', 'UIDeviceFamily': device_family,
    'CFBundleIcons': {'CFBundlePrimaryIcon': {'CFBundleIconFiles': ['AppIcon60x60'], 'UIPrerenderedIcon': False}},
    'CFBundleIcons~ipad': {'CFBundlePrimaryIcon': {'CFBundleIconFiles': ['AppIcon76x76', 'AppIcon83.5x83.5'], 'UIPrerenderedIcon': False}}
})
Path(output).write_bytes(plistlib.dumps(data))
PY
sips -z 120 120 "$IOS_ROOT/SofaTap/Assets.xcassets/AppIcon.appiconset/AppIcon.png" --out "$APP_BUNDLE/AppIcon60x60@2x.png" >/dev/null
sips -z 180 180 "$IOS_ROOT/SofaTap/Assets.xcassets/AppIcon.appiconset/AppIcon.png" --out "$APP_BUNDLE/AppIcon60x60@3x.png" >/dev/null
sips -z 76 76 "$IOS_ROOT/SofaTap/Assets.xcassets/AppIcon.appiconset/AppIcon.png" --out "$APP_BUNDLE/AppIcon76x76~ipad.png" >/dev/null
sips -z 152 152 "$IOS_ROOT/SofaTap/Assets.xcassets/AppIcon.appiconset/AppIcon.png" --out "$APP_BUNDLE/AppIcon76x76@2x~ipad.png" >/dev/null
sips -z 167 167 "$IOS_ROOT/SofaTap/Assets.xcassets/AppIcon.appiconset/AppIcon.png" --out "$APP_BUNDLE/AppIcon83.5x83.5@2x~ipad.png" >/dev/null
cp "$IOS_ROOT/SofaTap/Assets.xcassets/BrandMark.imageset/BrandMark.png" "$APP_BUNDLE/BrandMark.png"
cp "$IOS_ROOT/SofaTap/PrivacyInfo.xcprivacy" "$APP_BUNDLE/PrivacyInfo.xcprivacy"
for localization in "$IOS_ROOT/SofaTap/"*.lproj; do
  [[ -d "$localization" ]] || continue
  cp -R "$localization" "$APP_BUNDLE/"
done
xattr -cr "$APP_BUNDLE"
if [[ "$BUILD_MODE" == simulator ]]; then
  codesign --force --sign - "$APP_BUNDLE"
  printf 'SIMULATOR_APP=%s\n' "$APP_BUNDLE"
else
  # Swift's linker may add an adhoc Mach-O signature; there is no distribution/development signing.
  printf 'UNPROVISIONED_DEVICE_APP=%s\n' "$APP_BUNDLE"
  printf 'Physical installation requires an Apple development team and provisioning in Xcode.\n'
fi
