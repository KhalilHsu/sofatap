#!/bin/bash
# Injected protocol and lifecycle checks; no network, Keychain, TV or desktop input.
set -euo pipefail
REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
ANDROID_STAGE="$(mktemp -d "${TMPDIR:-/tmp}/sofatap-android-tv-tests.XXXXXX")"
trap 'rm -rf "$ANDROID_STAGE"' EXIT
xcrun --sdk macosx swiftc -parse-as-library -swift-version 5 -D SOFATAP_ANDROID_TV_TESTING \
    -target "$(uname -m)-apple-macosx14.0" \
    "$REPO_ROOT/ios/SofaTap/Core/SofaClock.swift" \
    "$REPO_ROOT/ios/SofaTap/Core/SavedDevice.swift" \
    "$REPO_ROOT/ios/SofaTap/Core/Pairing.swift" \
    "$REPO_ROOT/ios/SofaTap/Core/TV/"AndroidTV*.swift \
    "$REPO_ROOT/tests/AndroidTVControllerTests.swift" \
    -o "$ANDROID_STAGE/android-tv-tests"
"$ANDROID_STAGE/android-tv-tests"
