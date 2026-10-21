#!/usr/bin/env python3
"""Writes App/Xipper/AppIcon.icon, the Icon Composer bundle of the app icon (UI_SPEC 11, canvas A3):
a white zipper X on a #4AA3FF -> #0A57D4 gradient. macOS derives the dark, tinted and clear
variants from its layers; Xcode compiles it (and a fallback .icns) with actool.
Usage: python3 scripts/make-app-icon.py
"""
import json, os

root = os.path.join(os.path.dirname(__file__), "..", "App", "Xipper", "AppIcon.icon")
os.makedirs(os.path.join(root, "Assets"), exist_ok=True)

# The glyph in the design's 40x40 coordinates, in the central 64% of the 1024 canvas (inset 18%).
k = 1024 * 0.64 / 40
o = 1024 * 0.18
def point(x, y): return f"{o + x * k:.1f} {o + y * k:.1f}"
x_lines = [((8, 6), (32, 34)), ((32, 6), (8, 34))]
teeth = [((17, 11), (12, 11)), ((23, 11), (28, 11)), ((15, 16), (10, 16)), ((25, 16), (30, 16)),
         ((15, 24), (10, 24)), ((25, 24), (30, 24)), ((17, 29), (12, 29)), ((23, 29), (28, 29))]
def path(lines): return " ".join(f"M{point(*a)} L{point(*b)}" for a, b in lines)

svg = f'''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024">
  <path d="{path(x_lines)}" stroke="#FFFFFF" stroke-width="{5 * k:.1f}" stroke-linecap="round" fill="none"/>
  <path d="{path(teeth)}" stroke="#FFFFFF" stroke-width="{2.4 * k:.1f}" stroke-linecap="round" fill="none"/>
</svg>
'''
open(os.path.join(root, "Assets", "glyph.svg"), "w").write(svg)

icon = {
    "fill": {"linear-gradient": ["extended-srgb:0.29020,0.63922,1.00000,1.00000",
                                 "extended-srgb:0.03922,0.34118,0.83137,1.00000"]},
    "groups": [{"layers": [{"image-name": "glyph.svg", "name": "glyph"}]}],
    "supported-platforms": {"squares": ["macOS"]},
}
open(os.path.join(root, "icon.json"), "w").write(json.dumps(icon, indent=2) + "\n")
print("icon written to", os.path.normpath(root))
