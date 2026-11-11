#!/bin/bash
# Offscreen render of the delivery hint row (de/fr/ru x 3 states) at a given width.
# usage: render-delivery-hints.sh OUT_DIR [WIDTH=320] [PREFIX=se]
set -euo pipefail
REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/sofatap-hint-render.XXXXXX")"; trap 'rm -rf "$STAGE"' EXIT
xcrun --sdk macosx swiftc -parse-as-library -swift-version 5 -target "$(uname -m)-apple-ios17.0-macabi" -sdk "$SDK" \
    -F "$SDK/System/iOSSupport/System/Library/Frameworks" -I "$SDK/System/iOSSupport/usr/include" \
    "$REPO_ROOT/ios/SofaTap/Views/KareStyle.swift" "$REPO_ROOT/tests/DeliveryNoticeRender.swift" -o "$STAGE/render"
"$STAGE/render" "$REPO_ROOT" "$1" "${2:-320}" "${3:-se}"
