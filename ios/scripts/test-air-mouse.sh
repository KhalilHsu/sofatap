#!/bin/bash
# Filter, attitude, display-width mapping and card gestures. No CoreMotion, network or pointer injection.
set -euo pipefail
REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/sofatap-air-mouse-tests.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
xcrun swiftc -warnings-as-errors \
    "$REPO_ROOT/ios/SofaTap/Core/AirMouseMotion.swift" \
    "$REPO_ROOT/tests/AirMouseMotionTests.swift" -o "$STAGE/air-mouse"
xcrun swiftc -warnings-as-errors \
    "$REPO_ROOT/ios/SofaTap/Core/AirMouseCardGesture.swift" \
    "$REPO_ROOT/tests/AirMouseCardGestureTests.swift" -o "$STAGE/air-mouse-card"
"$STAGE/air-mouse-card"
"$STAGE/air-mouse"
swiftc -warnings-as-errors \
    "$REPO_ROOT/ios/SofaTap/Core/ReceiverState.swift" \
    "$REPO_ROOT/tests/ReceiverStateTests.swift" -o "$STAGE/receiver"
"$STAGE/receiver"
