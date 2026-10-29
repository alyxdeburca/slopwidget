#!/usr/bin/env bash
#
# Regenerate the screenshots in assets/screenshots/ from the current app.
# Requires isim + xtool on Linux (see README). Run locally:
#
#     ./scripts/regenerate-screenshots.sh
#
set -euo pipefail
cd "$(dirname "$0")/.."

export PATH="$HOME/.local/bin:$PATH"

xtool dev generate-xcode-project
isim build -workspace xtool/slopWidget.xcworkspace -scheme slopWidget-App -o build

APP=build/slopWidget-App.app
OUT=assets/screenshots

declare -A MAP=(
  [MainDashboard]=main_dashboard.png
  [LoginSheet]=login_sheet.png
  [Widget1x1]=widget_1x1.png
  [Widget1x2]=widget_1x2.png
  [Widget1x3]=widget_1x3.png
  [Widget2x2]=widget_2x2.png
)

for name in "${!MAP[@]}"; do
  isim preview "$APP" "$name" -o "$OUT/${MAP[$name]}"
done

echo "Screenshots regenerated in $OUT"
