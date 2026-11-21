"""Generate the ArkUI presets offline.

Radial color blends adapted from Mesh Gradient Generator, MIT (Andrew/Bifiku).
Reference commit e73d5ca99437e7da18abc3e0b40d5950899ddc77.
"""
from math import hypot
from pathlib import Path

from PIL import Image, ImageFilter

DESTINATION = Path(__file__).resolve().parents[1] / 'entry/src/main/resources/base/media'
SMALL = (272, 340)
OUTPUT = (768, 960)
BLOBS = ((.13, .18, .54), (.86, .28, .45), (.25, .79, .52), (.92, .86, .51))
PALETTES = {
    'fog_light': ['#F3F7FF', '#CBDFFF', '#BAD0F9', '#E0E8FC', '#D1E4FF'],
    'fog_dark': ['#101A30', '#25456C', '#23395A', '#283651', '#1B2B48'],
    'fern_light': ['#F3FCFA', '#BCE7DB', '#C3E2F4', '#CDEEE2', '#D4EFD8'],
    'fern_dark': ['#0E201F', '#194942', '#23405B', '#214235', '#275044'],
    'violet_light': ['#FAF5FF', '#DDC8F5', '#CFDBFF', '#F4DDF0', '#DCD5FA'],
    'violet_dark': ['#191529', '#3F2A58', '#303866', '#442D53', '#34304C'],
}

def render(palette):
    width, height = SMALL
    mesh = Image.new('RGB', SMALL, palette[0])
    for (x, y, radius), color in zip(BLOBS, palette[1:]):
        cx, cy, reach = x * width, y * height, radius * max(SMALL)
        alpha = Image.new('L', SMALL)
        alpha.putdata([round(229 * max(0, 1 - hypot(px - cx, py - cy) / reach))
                       for py in range(height) for px in range(width)])
        mesh.paste(Image.new('RGB', SMALL, color), (0, 0), alpha)
    return mesh.resize(OUTPUT, Image.Resampling.BICUBIC).filter(ImageFilter.GaussianBlur(24))

for key, palette in PALETTES.items():
    render(palette).save(DESTINATION / f'mesh_{key}.webp', 'WEBP', quality=87, method=6)
