#!/bin/zsh
set -euo pipefail

project_dir=${0:A:h:h}
build_dir="$project_dir/.build"
app_dir="$build_dir/PhotoSearchExporter.app"
mkdir -p "$build_dir"
mkdir -p "$app_dir/Contents/MacOS"
cp "$project_dir/native/Info.plist" "$app_dir/Contents/Info.plist"

xcrun swiftc \
  -parse-as-library \
  "$project_dir/native/photo_export.swift" \
  -o "$app_dir/Contents/MacOS/photo-export" \
  -framework AppKit \
  -framework Photos

xcrun swiftc \
  "$project_dir/native/vision_ocr.swift" \
  -o "$build_dir/vision-ocr" \
  -framework Vision \
  -framework ImageIO

codesign --force --deep --sign - "$app_dir"
codesign --force --sign - "$build_dir/vision-ocr"

echo "Built native helpers in $build_dir"
