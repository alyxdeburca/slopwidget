#!/usr/bin/env bash
#
# Regenerates AppIntentsMetadata/Metadata.appintents.
#
# iOS will not run an interactive widget AppIntent unless the host app bundle
# contains Metadata.appintents/extract.actionsdata. Xcode normally produces it
# with `appintentsmetadataprocessor`, which only runs on macOS. This script runs
# a Python reimplementation against the `.swiftconstvalues` files that the Swift
# compiler already emits, then copies the result where xtool picks it up
# (`resources:` in xtool.yml, so it lands at the app bundle root).
#
# Run it after changing anything in slopWidget/CycleOpenCodeMeterIntent.swift:
#
#     ./scripts/update-appintents-metadata.sh
#
# It needs the output of a previous `xtool dev build`, so build first.
set -euo pipefail

cd "$(dirname "$0")/.."

SDK="${DARWIN_SDK:-$HOME/.config/swiftpm/swift-sdks/darwin.artifactbundle/Xcode.app}"
TOOL_URL="https://raw.githubusercontent.com/William-BnCRocks/alt-apple-dev/main/tools/appintentsmeta.py"
TEAM_ID="${TEAM_ID:-L25T52S232}"
BASE_ID="com.example.slopWidget"
CACHE_DIR=".build/appintentsmeta"
TOOL="$CACHE_DIR/appintentsmeta.py"

CONST_VALUES_DIR=$(find .build/out/Intermediates.noindex -type d -path '*slopWidget-t.build/Objects-normal/arm64' | head -1)
if [[ -z "$CONST_VALUES_DIR" ]]; then
    echo "error: no build output found; run 'xtool dev build' first" >&2
    exit 1
fi

mkdir -p "$CACHE_DIR"
if [[ ! -f "$TOOL" ]]; then
    echo "Fetching appintentsmeta.py..."
    curl -fsSL -o "$TOOL" "$TOOL_URL"
fi

rm -rf AppIntentsMetadata
mkdir -p AppIntentsMetadata

python3 "$TOOL" \
    --module-name slopWidget \
    --bundle-identifier "XTL-$TEAM_ID.$BASE_ID" \
    --output AppIntentsMetadata \
    --const-values "$CONST_VALUES_DIR"/*.swiftconstvalues \
    --info-plist xtool/slopWidget.app/Info.plist \
    --sdk-root "$SDK/Contents/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS.sdk"

echo "Wrote AppIntentsMetadata/Metadata.appintents"
