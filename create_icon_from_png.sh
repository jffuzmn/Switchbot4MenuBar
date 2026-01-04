#!/bin/bash

# Create iconset directory
mkdir -p Aranet4.iconset

# Check if base image exists
if [ ! -f "icon_1024.png" ]; then
    echo "Error: Please save your icon image as icon_1024.png first"
    exit 1
fi

# Generate all required sizes
sips -z 16 16 icon_1024.png --out Aranet4.iconset/icon_16x16.png
sips -z 32 32 icon_1024.png --out Aranet4.iconset/icon_16x16@2x.png
sips -z 32 32 icon_1024.png --out Aranet4.iconset/icon_32x32.png
sips -z 64 64 icon_1024.png --out Aranet4.iconset/icon_32x32@2x.png
sips -z 128 128 icon_1024.png --out Aranet4.iconset/icon_128x128.png
sips -z 256 256 icon_1024.png --out Aranet4.iconset/icon_128x128@2x.png
sips -z 256 256 icon_1024.png --out Aranet4.iconset/icon_256x256.png
sips -z 512 512 icon_1024.png --out Aranet4.iconset/icon_256x256@2x.png
sips -z 512 512 icon_1024.png --out Aranet4.iconset/icon_512x512.png
sips -z 1024 1024 icon_1024.png --out Aranet4.iconset/icon_512x512@2x.png

# Convert to icns
iconutil -c icns Aranet4.iconset -o Aranet4.icns

echo "✓ Icon created: Aranet4.icns"

# Clean up
rm -rf Aranet4.iconset
