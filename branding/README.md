# BUCK Branding Assets

## Branding source

These files were imported from the official [buck.red](https://buck.red/) Logo
page and are the approved source set for BUCK branding.

- Local import source: `C:\Users\DS\Desktop\buck_logo\`
- Import date: 2026-07-24

## Directory purpose

- `branding/source/` contains untouched originals with their original filenames.
- `branding/exported/` contains normalized, reusable exports.
- `assets/branding/` contains the Flutter application copies.

## Canonical filenames and intended usage

| Canonical filename | Intended usage |
| --- | --- |
| `buck_logo_coin_black.png` | Primary coin logo on light backgrounds |
| `buck_logo_coin_white.png` | Primary coin logo on dark backgrounds |
| `buck_wordmark_black.png` | Horizontal wordmark on light backgrounds |
| `buck_wordmark_white.png` | Horizontal wordmark on dark backgrounds |
| `buck_wordmark_grey.png` | Secondary neutral wordmark |
| `buck_logo_coin_grey.png` | Secondary neutral coin logo |
| `buck_symbol_black.png` | Transparent-background black BUCK symbol |
| `buck_symbol_white.png` | Transparent-background white BUCK symbol |
| `buck_symbol_grey.png` | Transparent-background grey BUCK symbol |
| `buck_logo_qr.png` | High-contrast center mark used only inside QR codes |
| `buck_logo_small_ui.png` | High-contrast BUCK symbol for 24–48 px in-wallet use |

## Rules

- Never edit files in `branding/source/`.
- Derive all new assets from files in `branding/source/`.
- Do not stretch or distort the artwork; always keep its aspect ratio.
- Use black variants on light backgrounds.
- Use white variants on dark backgrounds.
- Use `buck_logo_qr.png` only inside QR codes.
- Use `buck_logo_small_ui.png` for BUCK-only coin and compact UI imagery.
- Preserve adequate clear space around every mark.

## Size-optimized derivatives

`buck_logo_qr.png` and `buck_logo_small_ui.png` are technical,
size-optimized derivatives of the official triangle-and-eye component from
`branding/source/buck-logo-black-coinonly-1000x1000.png`. They crop away the
wordmark, rings, and excess clear space that become illegible at small sizes,
without redrawing, distorting, or otherwise redesigning the official mark.

- `buck_logo_qr.png`: 512×512, opaque white safety background, symbol at 74%
  of the canvas width; optimized for the 50×50 embedded image in a 200 px QR.
- `buck_logo_small_ui.png`: 256×256, opaque white background, symbol at 86%
  of the canvas width; optimized for 24–48 px BUCK-only coin/UI use.
