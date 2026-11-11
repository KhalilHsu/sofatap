#!/bin/bash
# Production TV lifecycle with injected transport and storage: no network,
# device connection, Keychain reads/writes, application window or desktop input.
set -euo pipefail
REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
TV_STAGE="$(mktemp -d "${TMPDIR:-/tmp}/sofatap-tv-controller-tests.XXXXXX")"
trap 'rm -rf "$TV_STAGE"' EXIT
xcrun --sdk macosx swiftc -parse-as-library -swift-version 5 \
    -target "$(uname -m)-apple-macosx14.0" \
    "$REPO_ROOT/ios/SofaTap/Core/SofaClock.swift" \
    "$REPO_ROOT/ios/SofaTap/Core/SavedDevice.swift" \
    "$REPO_ROOT/ios/SofaTap/Core/TV/"WebOS*.swift \
    "$REPO_ROOT/tests/WebOSTVControllerTests.swift" \
    -o "$TV_STAGE/tv-controller-tests"
"$TV_STAGE/tv-controller-tests"
