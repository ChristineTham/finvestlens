#!/usr/bin/env python3
"""Generate the FinvestLens app icon.

Authoring source is SVG (see design/appicon*.svg written below); this script
renders the SVGs to PNG with qlmanage (WebKit, full SVG fidelity) and downsamples
with sips, then populates finvestlens/Assets.xcassets/AppIcon.appiconset.

Concept — "Rising insight": a warm sunrise gradient (lavender warming to apricot)
with an upward growth curve ending in a glowing focal *lens* node and a sparkle.
Personal-finance growth + the "Lens" in FinvestLens; warm and inviting.
"""
import os
import subprocess
import shutil
import json

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DESIGN = os.path.join(ROOT, "design")
ICONSET = os.path.join(ROOT, "finvestlens", "Assets.xcassets", "AppIcon.appiconset")


def art(pal):
    """The icon artwork in a 0..1024 coordinate space (no background clip)."""
    return f"""
  <defs>
    <linearGradient id="bg" x1="0" y1="0" x2="1" y2="1">
      <stop offset="0" stop-color="{pal['bg0']}"/>
      <stop offset="0.52" stop-color="{pal['bg1']}"/>
      <stop offset="1" stop-color="{pal['bg2']}"/>
    </linearGradient>
    <radialGradient id="cool" cx="0.22" cy="0.18" r="0.62">
      <stop offset="0" stop-color="{pal['cool']}" stop-opacity="{pal['coolO']}"/>
      <stop offset="1" stop-color="{pal['cool']}" stop-opacity="0"/>
    </radialGradient>
    <radialGradient id="warm" cx="0.56" cy="0.92" r="0.8">
      <stop offset="0" stop-color="{pal['warm']}" stop-opacity="{pal['warmO']}"/>
      <stop offset="1" stop-color="{pal['warm']}" stop-opacity="0"/>
    </radialGradient>
    <linearGradient id="area" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#FFFFFF" stop-opacity="0.16"/>
      <stop offset="1" stop-color="#FFFFFF" stop-opacity="0"/>
    </linearGradient>
    <linearGradient id="line" x1="0" y1="1" x2="1" y2="0">
      <stop offset="0" stop-color="#FFFFFF"/>
      <stop offset="1" stop-color="#FFEFDC"/>
    </linearGradient>
    <radialGradient id="nodeGlow" cx="0.5" cy="0.5" r="0.5">
      <stop offset="0" stop-color="#FFFFFF" stop-opacity="0.55"/>
      <stop offset="1" stop-color="#FFFFFF" stop-opacity="0"/>
    </radialGradient>
  </defs>
  <rect width="1024" height="1024" fill="url(#bg)"/>
  <rect width="1024" height="1024" fill="url(#cool)"/>
  <rect width="1024" height="1024" fill="url(#warm)"/>
  <!-- area under the growth curve -->
  <path d="M280 652 L440 520 L570 586 L744 360 L744 732 L280 732 Z" fill="url(#area)"/>
  <!-- soft cast shadow of the line -->
  <path d="M280 658 L440 526 L570 592 L744 366" fill="none" stroke="#2E2154"
        stroke-opacity="0.16" stroke-width="40" stroke-linecap="round" stroke-linejoin="round"/>
  <!-- growth line -->
  <path d="M280 652 L440 520 L570 586 L744 360" fill="none" stroke="url(#line)"
        stroke-width="38" stroke-linecap="round" stroke-linejoin="round"/>
  <!-- focal lens node -->
  <circle cx="744" cy="360" r="96" fill="url(#nodeGlow)"/>
  <circle cx="744" cy="360" r="60" fill="none" stroke="#FFF7EE" stroke-width="14" stroke-opacity="0.92"/>
  <circle cx="744" cy="360" r="33" fill="#FFFBF4"/>
  <!-- sparkle -->
  <path d="M812 232 C 817 266 830 279 864 284 C 830 289 817 302 812 336
           C 807 302 794 289 760 284 C 794 279 807 266 812 232 Z" fill="#FFF6EA"/>
  <!-- small ledger dots along the baseline (rhythm, budgeting cadence) -->
  <circle cx="360" cy="792" r="9" fill="#FFFFFF" fill-opacity="0.5"/>
  <circle cx="512" cy="792" r="9" fill="#FFFFFF" fill-opacity="0.5"/>
  <circle cx="664" cy="792" r="9" fill="#FFFFFF" fill-opacity="0.5"/>
"""


LIGHT = dict(bg0="#7A5BF0", bg1="#C173A6", bg2="#F7A05F",
             cool="#AC9BF7", coolO="0.55", warm="#FFCF97", warmO="0.62")
DARK = dict(bg0="#43357E", bg1="#6E4576", bg2="#9E5E52",
            cool="#8E7EE6", coolO="0.40", warm="#E9B589", warmO="0.34")


def svg_fullbleed(pal):
    return (f'<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" '
            f'viewBox="0 0 1024 1024">{art(pal)}</svg>')


def svg_macos(pal):
    """macOS tile: rounded-square with the standard ~100px transparent margin."""
    return (
        '<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" '
        'viewBox="0 0 1024 1024">'
        '<defs><clipPath id="sq"><rect x="100" y="100" width="824" height="824" rx="185" ry="185"/></clipPath></defs>'
        f'<g clip-path="url(#sq)"><g transform="translate(100,100) scale(0.8046875)">{art(pal)}</g></g>'
        '</svg>')


def write(path, text):
    with open(path, "w") as f:
        f.write(text)


def qlrender(svg_path, out_png, size):
    tmp = os.path.join(DESIGN, "_ql")
    os.makedirs(tmp, exist_ok=True)
    subprocess.run(["qlmanage", "-t", "-s", str(size), "-o", tmp, svg_path],
                   check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    produced = os.path.join(tmp, os.path.basename(svg_path) + ".png")
    shutil.move(produced, out_png)


def resize(src, dst, px):
    shutil.copyfile(src, dst)
    subprocess.run(["sips", "-Z", str(px), dst],
                   check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def main():
    os.makedirs(DESIGN, exist_ok=True)
    # Author SVGs (reference base) --------------------------------------------
    write(os.path.join(DESIGN, "appicon.svg"), svg_fullbleed(LIGHT))
    write(os.path.join(DESIGN, "appicon-dark.svg"), svg_fullbleed(DARK))
    write(os.path.join(DESIGN, "appicon-macos.svg"), svg_macos(LIGHT))

    # Render masters at 1024 ---------------------------------------------------
    m_ios = os.path.join(DESIGN, "_ios1024.png")
    m_ios_dark = os.path.join(DESIGN, "_ios1024_dark.png")
    m_mac = os.path.join(DESIGN, "_mac1024.png")
    qlrender(os.path.join(DESIGN, "appicon.svg"), m_ios, 1024)
    qlrender(os.path.join(DESIGN, "appicon-dark.svg"), m_ios_dark, 1024)
    qlrender(os.path.join(DESIGN, "appicon-macos.svg"), m_mac, 1024)

    os.makedirs(ICONSET, exist_ok=True)
    # iOS -----------------------------------------------------------------------
    shutil.copyfile(m_ios, os.path.join(ICONSET, "icon-ios-1024.png"))
    shutil.copyfile(m_ios_dark, os.path.join(ICONSET, "icon-ios-1024-dark.png"))

    # macOS ladder --------------------------------------------------------------
    mac_specs = [("16", "1x", 16), ("16", "2x", 32), ("32", "1x", 32), ("32", "2x", 64),
                 ("128", "1x", 128), ("128", "2x", 256), ("256", "1x", 256),
                 ("256", "2x", 512), ("512", "1x", 512), ("512", "2x", 1024)]
    mac_images = []
    for base, scale, px in mac_specs:
        fn = f"icon-mac-{base}-{scale}.png"
        resize(m_mac, os.path.join(ICONSET, fn), px)
        mac_images.append({"idiom": "mac", "scale": scale, "size": f"{base}x{base}", "filename": fn})

    contents = {
        "images": [
            {"idiom": "universal", "platform": "ios", "size": "1024x1024",
             "filename": "icon-ios-1024.png"},
            {"idiom": "universal", "platform": "ios", "size": "1024x1024",
             "filename": "icon-ios-1024-dark.png",
             "appearances": [{"appearance": "luminosity", "value": "dark"}]},
        ] + mac_images,
        "info": {"author": "xcode", "version": 1},
    }
    write(os.path.join(ICONSET, "Contents.json"), json.dumps(contents, indent=2) + "\n")

    # Clean scratch
    for p in (m_ios, m_ios_dark, m_mac):
        os.remove(p)
    shutil.rmtree(os.path.join(DESIGN, "_ql"), ignore_errors=True)
    print("Done. Wrote", ICONSET)


if __name__ == "__main__":
    main()
