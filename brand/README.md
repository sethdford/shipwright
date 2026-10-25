# Shipwright brand mark

- `mark.svg`: the mark in one colour (`currentColor`), for the wordmark and docs.
- `dashboard/public/favicon.svg`: the same geometry with `prefers-color-scheme` colours (oklch tokens). Browsers that support oklch use it.
- `favicon-32.svg` / `favicon-32.png` and `apple-touch-icon.svg` / `apple-touch-icon.png`: raster fallbacks. These use sRGB hex values converted from the dashboard tokens, because `rsvg-convert` does not support `oklch()`.

Regenerate the PNGs after editing an SVG (needs `librsvg`):

    rsvg-convert -w 32 -h 32 brand/favicon-32.svg -o brand/favicon-32.png
    rsvg-convert -w 180 -h 180 brand/apple-touch-icon.svg -o brand/apple-touch-icon.png

The mark is original work for Shipwright. It uses no third-party logo, font glyph or emoji.
