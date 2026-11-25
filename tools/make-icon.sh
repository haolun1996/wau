#!/bin/sh
# Regenerates App/Resources/Assets.xcassets/AppIcon.appiconset.
#
#   tools/make-icon.sh                  # draw the vector icon (tools/make-icon.swift)
#   tools/make-icon.sh design/icon/X.png  # use generated art, fitted by tools/import-icon.swift
set -eu
cd "$(dirname "$0")/.."
SET=App/Resources/Assets.xcassets/AppIcon.appiconset
mkdir -p "$SET"
if [ $# -ge 1 ]; then
  swift tools/import-icon.swift "$1" "$SET/icon_1024.png"
else
  swift tools/make-icon.swift "$SET/icon_1024.png"
fi
for px in 16 32 64 128 256 512; do
  sips -z $px $px "$SET/icon_1024.png" --out "$SET/icon_$px.png" >/dev/null
done
cat > "$SET/Contents.json" <<'JSON'
{
  "images" : [
    { "idiom" : "mac", "scale" : "1x", "size" : "16x16",   "filename" : "icon_16.png" },
    { "idiom" : "mac", "scale" : "2x", "size" : "16x16",   "filename" : "icon_32.png" },
    { "idiom" : "mac", "scale" : "1x", "size" : "32x32",   "filename" : "icon_32.png" },
    { "idiom" : "mac", "scale" : "2x", "size" : "32x32",   "filename" : "icon_64.png" },
    { "idiom" : "mac", "scale" : "1x", "size" : "128x128", "filename" : "icon_128.png" },
    { "idiom" : "mac", "scale" : "2x", "size" : "128x128", "filename" : "icon_256.png" },
    { "idiom" : "mac", "scale" : "1x", "size" : "256x256", "filename" : "icon_256.png" },
    { "idiom" : "mac", "scale" : "2x", "size" : "256x256", "filename" : "icon_512.png" },
    { "idiom" : "mac", "scale" : "1x", "size" : "512x512", "filename" : "icon_512.png" },
    { "idiom" : "mac", "scale" : "2x", "size" : "512x512", "filename" : "icon_1024.png" }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
JSON
echo "updated $SET"
