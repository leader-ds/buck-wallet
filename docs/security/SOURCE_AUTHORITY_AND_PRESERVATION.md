# Source Authority and Preservation Manifest

This manifest records the source-authority model and preservation boundaries for
BUCK Wallet. It is a documentation and compatibility-contract record; it does
not change runtime behavior, product identity, protocol behavior, dependencies,
submodule pins, build output, or preserved evidence.

## Source roles

The following roles are distinct and must not be conflated:

- **AUTHORITATIVE SOURCE**: the sole repository in which a product component is
  developed and released.
- **PRESERVED FORENSIC EVIDENCE**: an intentionally retained, read-only state
  used for historical or investigative proof.
- **NON-AUTHORITATIVE EVIDENCE CHECKOUT**: a read-only checkout used to inspect
  another authoritative repository; it is not a development authority.
- **BUILD/VALIDATION TREE**: disposable derived output or a checkout used only
  to validate an immutable source anchor; it has no source authority.
- **EXTERNAL DEPENDENCY/SUBMODULE**: independently sourced code whose selected
  revision is controlled by an authoritative superproject gitlink or dependency
  declaration.

## Wallet source authority

- Repository: `leader-ds/buck-wallet`
- Canonical branch: `security/curated-stage6r-baseline`
- Role: **AUTHORITATIVE SOURCE**

`leader-ds/buck-wallet` is the sole authoritative source for the Flutter BUCK
Wallet application and its wallet-specific native/runtime components.

The accepted canonical commit at manifest creation is
`9ec98edbd4ce1afd697fa12163f23035c501914a`. Its accepted history anchors are:

1. `78c5fcf4cd67ba68a0f2d07983ba09b3110318a3`
2. `31be154d582cf33f7e1f0ee354872502c690bf80`
3. `b22bd83fc7e083841fe56b8be0caaf1bcc9a7eba`
4. `8623d762e42747366840ccaf05043bf7ec6ed351`
5. `9b99be72742eeb63a48cf7d1871e316a7997b9ee`
6. `6583b7bff2721425ce34514e4dcf5a82aff3acb8`
7. `9ec98edbd4ce1afd697fa12163f23035c501914a`

## Core source authority

- Repository: `leader-ds/buck`
- Role: **AUTHORITATIVE SOURCE**

`leader-ds/buck` is the sole authoritative source for the BUCK core/node/daemon
implementation.

The current evidence candidate is
`662668a3295df9d40e609d4dd59fba86036f466e`.

**CORE COMPATIBILITY BASELINE: PENDING HUMAN APPROVAL**

The evidence candidate is not an approved compatibility baseline and is not
identified as a direct build dependency of `leader-ds/buck-wallet`.

## Authority model: Model C

The approved model is the refined compatibility-linked dual-component model:

- one authority per product component;
- no editable wallet source copy in core;
- no editable core source copy in wallet;
- no meta-repository authority;
- no snapshot-copy authority; and
- cross-repository coordination through immutable commit or release anchors,
  an explicit compatibility manifest, independent pull-request and release
  processes, and linked validation evidence.

There are **NO PARALLEL AUTHORITATIVE WALLET SOURCE TREES**. Secondary wallet
trees may be forensic, read-only evidence, validation-only, historical, or
disposable derived build output. They must not accept independent product
development.

## Direct dependency and runtime boundaries

**DIRECT CORE SOURCE BUILD DEPENDENCY: NO**

The wallet/core relationship is a **PROTOCOL / NETWORK SERVICE / RELEASE
COMPATIBILITY CONTRACT**, not a **SOURCE-TREE BUILD DEPENDENCY**.

The currently inspected runtime architecture is:

```text
Flutter/Dart
→ packages/warp_api_ffi
→ native zcash-sync FFI
→ pinned/embedded Zcash-family primitives
→ lightwalletd CompactTxStreamer gRPC/TLS
→ BUCK network/core-backed service
```

**DIRECT BUCKD/JSON-RPC RUNTIME PATH: NOT FOUND**

This statement describes the currently inspected architecture and does not rule
out a future, explicitly reviewed direct RPC design.

## Preserved wallet worktree

- Path: `C:\buck-wallet`
- Role: **PRESERVED FORENSIC EVIDENCE / READ-ONLY**
- Required branch: `buck/lightwallet-stabilization`
- Required HEAD: `ae545e6d800f94184809df02fae77addcaefdab1`
- State: intentional dirty/untracked forensic baseline

Rules for this worktree:

- **DO NOT CLEAN**
- **DO NOT RESET**
- **DO NOT RESTORE**
- **DO NOT STASH**
- **DO NOT NORMALIZE**

`C:\buck-wallet\diagnostics` is pre-existing forensic evidence. Known files
include `buck-last-raw-tx.txt`, `cargo-metadata-after.json`, and
`cargo-tree-zcash-warpsync-after.txt`. Reference these files only by preservation
path or hash. Do not import them into source or classify them as 01H-generated
artifacts.

## Preservation copy

- Path: `C:\buck-wallet-preservation-20260814-012306`
- Role: **IMMUTABLE PRESERVATION EVIDENCE**
- Verification reference: `10_verification\SHA256SUMS.txt`

Preservation files must not be regenerated or copied into normal source.

## Core evidence checkout

- Path at P1 creation: `C:\buck-core-evidence`
- Repository: `leader-ds/buck`
- Evidence HEAD: `662668a3295df9d40e609d4dd59fba86036f466e`
- Role: **READ-ONLY / NON-AUTHORITATIVE CORE EVIDENCE**

This evidence checkout is not a development authority.

## Submodule authority principle

Current wallet submodules remain controlled by the `leader-ds/buck-wallet`
superproject gitlinks. In particular, `native/zcash-sync` must remain a single
pinned gitlink and must not be copied into core, detached into a second
authority, silently repointed, or vendored without explicit review. No
submodule pin is modified by P1.

## Future development routing and gates

Current required task routing:

> Codex feladat futtatása: `leader-ds/buck-wallet` környezetben, helyi Windows
> gépen / PowerShell / Codex használatával.

All wallet product changes must begin by verifying the named repository,
worktree, branch, HEAD, live remote canonical, clean status, submodule state,
and preservation boundary.

All 01G repository mutations occur after 01H-SRC authority closure. Future 01G
work targets `leader-ds/buck-wallet` unless a later, separately approved
authority decision changes that routing.

## Core compatibility open items

The following compatibility-contract inputs remain unresolved and must not be
silently normalized in P1:

1. Core master/source version: `4.0.5`.
2. Highest current repository tag: `4.0.4`.
3. Immutable `4.0.5` release tag: absent.
4. Current core candidate SHA:
   `662668a3295df9d40e609d4dd59fba86036f466e`.
5. Exact production daemon SHA: unproven.
6. Exact lightwalletd backing-core SHA: unproven.
7. Core build validation: not yet performed for the candidate.
8. Derivation identity discrepancy: core `bip44CoinType = 147`; wallet Dart
   `coinIndex = 133`; wallet native derivation uses Zcash-compatible ZIP-32
   identity.

These are compatibility-contract inputs pending later validation and human
approval, **NOT** authorization to modify wallet derivation behavior.
