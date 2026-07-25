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

## Rules

- Never edit files in `branding/source/`.
- Derive all new assets from files in `branding/source/`.
- Do not stretch or distort the artwork; always keep its aspect ratio.
- Use black variants on light backgrounds.
- Use white variants on dark backgrounds.
- Use `buck_logo_qr.png` only inside QR codes.
- Preserve adequate clear space around every mark.

## Current scope

This phase imports assets only. UI references, splash screens, the About page,
the QR widget, launcher icons, and platform metadata will be handled in later
commits.
