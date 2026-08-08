# BUCK Wallet Curated Baseline Provenance

## Reconstruction

- Stage: 6S.4 — Clean Curated Baseline Construction
- Design: Stage 6S.3 Option D
- Source repository: `C:\buck-wallet`
- Source branch: `buck/lightwallet-stabilization`
- Source HEAD: `ae545e6d800f94184809df02fae77addcaefdab1`
- Pre-Stage-4 functional boundary: `ed8a1bcc`
- Curated root: `5d09021ae5026d04d2afdd78fa6b8b2041e6eb8e`

The baseline was reconstructed as a new ancestry-free root snapshot. Source Git
ancestry was intentionally not inherited. Sensitive signing containers, unsafe
historical Apple signing workflows, and legacy development defaults were omitted
before the first commit. Secret values and sensitive binary contents were not
copied or inspected.

## Required pre-Stage-4 functional source commits

1. `968f6ce8`
2. `ade8418b`
3. `00104395`
4. `5a6a537e`
5. `d7887e7b`
6. `8d7e8f6e`
7. `885960be`
8. `0acb1bf5`
9. `3260ae36`
10. `64445d66`
11. `157f20c9`
12. `5a9f6a9f`
13. `e8607aa9`
14. `ed8a1bcc`

## Stage 4 through Stage 6R mapping

| Original source commit | Curated commit |
|---|---|
| `7926961ce33672c5685b7007d8ea5bace37f54e0` | `21704e7c603471753d88eb265e26538e2ca55562` |
| `226360c9b70613a69f6a1bce3e7e03d990eefdb5` | `86ffdb8dff8217fc67c2de53fdae5f75b40e8ea0` |
| `9e38c193d33d1cbccd116df2f5604ae31d8d68f1` | `0a576360980e0ddd29047ef798a435c7e44a9fdd` |
| `71d23ef9ceef17aafe26e64eddc494d73b191af1` | `369953a59ed7875efa8f0c878328c1bfe03f1a8c` |
| `6d97d17119dba6de8317858c8af6ff6c454cf5e6` | `dfcd46bf629b08c6995fcc6066a20bce194a494c` |
| `ae545e6d800f94184809df02fae77addcaefdab1` | `0d62944dc2b2ffa4f1fe84adceda665679d96f85` |

## Milestone mapping

| Milestone | Original target | Proposed curated target |
|---|---|---|
| `lightwallet-ha-stage4-baseline` | `7926961ce33672c5685b7007d8ea5bace37f54e0` | `21704e7c603471753d88eb265e26538e2ca55562` |
| `lightwallet-bootstrap-stage5d-baseline` | `226360c9b70613a69f6a1bce3e7e03d990eefdb5` | `86ffdb8dff8217fc67c2de53fdae5f75b40e8ea0` |
| `lightwallet-bootstrap-stage5-final` | `9e38c193d33d1cbccd116df2f5604ae31d8d68f1` | `0a576360980e0ddd29047ef798a435c7e44a9fdd` |

## Final exclusion set

- `ios/certs/Certificates.p12`
- `macos/certs/codesign.p12`
- `docker/zwallet.jks`
- `docker/zwallet-sample.jks`
- `ios/certs/YWallet_AppStore.mobileprovision`
- `.github/workflows/build-ios.yml`
- `.github/workflows/build-mac.yml`
- `env.sh`
- `install-dev.sh`
- `misc/vagrant/build-ubuntu.sh`
- `misc/fdroid/me.hanh.ywallet.yml`

The omitted historical signing workflow paths are
`.github/workflows/build-ios.yml` and `.github/workflows/build-mac.yml`.
