#!/usr/bin/env python3
import os

# Create icon directory
os.makedirs('Aranet4.iconset', exist_ok=True)

# Icon sizes needed for macOS
sizes = [
    (16, 'icon_16x16.png'),
    (32, 'icon_16x16@2x.png'),
    (32, 'icon_32x32.png'),
    (64, 'icon_32x32@2x.png'),
    (128, 'icon_128x128.png'),
    (256, 'icon_128x128@2x.png'),
    (256, 'icon_256x256.png'),
    (512, 'icon_256x256@2x.png'),
    (512, 'icon_512x512.png'),
    (1024, 'icon_512x512@2x.png'),
]

# Create SVG with lowercase 'a'
svg_template = '''<?xml version="1.0" encoding="UTF-8"?>
<svg width="{size}" height="{size}" xmlns="http://www.w3.org/2000/svg">
  <rect width="{size}" height="{size}" fill="white" rx="{radius}"/>
  <text x="50%" y="50%"
        font-family="SF Pro, Helvetica, Arial, sans-serif"
        font-size="{fontsize}"
        font-weight="500"
        fill="black"
        text-anchor="middle"
        dominant-baseline="central">a</text>
</svg>'''

print("Creating icon files...")
for size, filename in sizes:
    # Create SVG
    svg_content = svg_template.format(
        size=size,
        radius=int(size * 0.225),  # 22.5% corner radius
        fontsize=int(size * 0.65)
    )

    svg_path = f'temp_{size}.svg'
    with open(svg_path, 'w') as f:
        f.write(svg_content)

    # Convert SVG to PNG using qlmanage and sips
    png_path = f'Aranet4.iconset/{filename}'

    # Use sips to convert (requires temporary conversion through another format)
    # Actually, let's use the built-in conversion
    os.system(f'qlmanage -t -s {size} -o . {svg_path} > /dev/null 2>&1')

    # Move and rename the output
    temp_png = f'{svg_path}.png'
    if os.path.exists(temp_png):
        os.rename(temp_png, png_path)
        print(f"Created {filename}")
    else:
        # Fallback: create a simple colored square
        os.system(f'sips -s format png --resampleHeightWidth {size} {size} -s formatOptions best --out {png_path} {svg_path} 2>/dev/null')

    # Clean up SVG
    os.remove(svg_path)

print("\nConverting iconset to icns...")
os.system('iconutil -c icns Aranet4.iconset -o Aranet4.icns')

if os.path.exists('Aranet4.icns'):
    print("✓ Icon created successfully: Aranet4.icns")
    # Clean up iconset folder
    os.system('rm -rf Aranet4.iconset')
else:
    print("✗ Failed to create icon")
