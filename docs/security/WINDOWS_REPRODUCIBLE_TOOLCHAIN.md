# Windows Repeatable Toolchain and Release Baseline

## Scope and evidence claim

This manifest records the currently accepted repeatable Windows BUCK Wallet build baseline. It is a static, reviewable record: it does not install tools, execute a build, implement automation, or alter CI, product source, dependencies, identity, runtime behavior, or packaging.

**FACT:** The current evidence supports a repeatable-build baseline.

**UNPROVEN:** It does **not** prove bit-for-bit deterministic binary reproducibility. A repeatable build means that the pinned inputs and verified environment can be reconstructed to produce a functional release; it does not assert byte-identical output.

## Field classification

- **MUST PIN:** source baseline and authority reference; gitlinks; Flutter framework and engine revisions; dependency lockfiles and hashes; accepted Rust version baseline; Zcash parameter hashes.
- **MUST VERIFY:** tool paths and versions; Visual Studio workload; Windows target; executable identity, architecture, and subsystem; release-directory completeness.
- **INFORMATIONAL:** human-readable edition labels, DevTools metadata, nested toolchain context, and observed alternative tools.
- **ENVIRONMENT-SPECIFIC:** absolute installation/cache paths, endpoint-security state, and network/cache locations. Such paths describe the proven machine and are not universal product requirements unless an explicit policy below says to use them.

Labels used below distinguish **FACT**, **POLICY**, **CURRENT MACHINE OBSERVATION**, and **UNPROVEN / PENDING**.

## Source and authority baseline

**MUST PIN / FACT**

- Repository: `leader-ds/buck-wallet`
- Canonical branch: `security/curated-stage6r-baseline`
- Manifest implementation parent: `3c86120be5c796eb5767d8ff772909a2e728b02d`
- Authority: `leader-ds/buck-wallet` is the sole Flutter BUCK Wallet source authority.
- Authority reference: `docs/security/SOURCE_AUTHORITY_AND_PRESERVATION.md`

The P3 feature commit is a review candidate, not a permanent source compatibility requirement.

## Flutter and Dart SDK

**MUST PIN / FACT:** The accepted SDK is a Git checkout with:

- Flutter executable policy path: `C:\src\flutter_3245\bin\flutter.bat`
- Flutter: `3.24.5`
- Dart: `3.5.4`
- Flutter framework revision: `dec2ee5c1f98f8e84a7d5380c05eb8a3d0a81668`
- Engine revision: `a18df97ca57a249df5d8d68cd0820600223ce262`
- DevTools: `2.37.3` (informational metadata)

**POLICY:** Use the explicit pinned Flutter executable. Do not rely on a `flutter` selected from `PATH`.

**CURRENT MACHINE OBSERVATION:** P2 observed PATH Flutter `3.38.3`. Legacy Windows CI declares Flutter `3.22.2`. Neither is the accepted Windows baseline.

## Dart and Pub dependencies

**MUST PIN / FACT:**

| Input | SHA-256 |
|---|---|
| `pubspec.yaml` | `49dbe1d3c475b0bb24de698ab7cc437f8b2f73f5c1fb5a699e509b0676772b8b` |
| `pubspec.lock` | `5aeac11a4d8d6dae061de23af09cab7ba5181b64817fe759ab7af00bfaeda1ab` |
| `packages/warp_api_ffi/pubspec.yaml` | `f58b2c966f60e4f2aa3dbd24bc88592be7d90ea7c62b8e7acc0e079903950135` |
| `packages/warp_api_ffi/pubspec.lock` | `361ef5fe0f2d37ec49164adf6b67b8f38a3c5c615ed6c86ce7297e9855130479` |

The current `pubspec.yaml` authority is bound to canonical commit `61eeaccd366013a45f7b8a79d56c7fb5ddca6646`, Git blob `a9e10928ddd7d9a481cc03e0af0ab748a0310cfa`, and Windows checkout SHA-256 `49dbe1d3c475b0bb24de698ab7cc437f8b2f73f5c1fb5a699e509b0676772b8b`.

**FORENSIC NOTE:** RC1B retired `beb5294fb9eb7391b642f98b26fa0ec6193238c58c3a9d6c5027cdae9f1d9f0f` because it did not correspond to the claimed committed `pubspec.yaml` source bytes.

- Dart root constraint: `>=3.0.0 <4.0.0`
- Resolved Dart constraint: `>=3.4.0 <4.0.0`
- Resolved Flutter constraint: `>=3.22.0`
- P2 dependency source counts: Hosted `216`, Git `2`, Path `1`, SDK `5`.
- `qr_flutter` resolved immutable SHA: `4bdb1126e553b474b80c8c91e9f9e43baf1e9c4e`
- `build_version` resolved SHA: `e3765f680f2d5decf7a47960b4470b8f60905a5f`
- `warp_api` resolves to the repository-local authoritative package dependency `packages/warp_api_ffi`.

**FACT / RISK:** The `build_version` declaration itself floats at repository HEAD. Therefore lockfile-based restoration is repeatable; lockfile regeneration is not guaranteed deterministic over time.

## Rust and Cargo

**MUST PIN / CURRENT MACHINE OBSERVATION:** P2 observed the accepted active Windows environment as `rustc 1.91.1`, Cargo `1.91.1`, host/target `x86_64-pc-windows-msvc`.

**FACT:** There is no root `rust-toolchain` and no root `rust-toolchain.toml`. The root Rust/Cargo selection is therefore **ENVIRONMENT-DEPENDENT**. This document records the accepted observed baseline but does not install or configure Rust.

**INFORMATIONAL:** Nested pins are `librustzcash` `1.82.0` and `orchard` `1.60.0`. They do not pin the root workspace build.

## Visual Studio, MSVC, and Windows SDK

**MUST VERIFY / ACCEPTED BUILD EVIDENCE:**

- Visual Studio: Community 2022
- VS version: `17.14.38`
- Installation version: `17.14.37531.7`
- Installation path: `C:\Program Files\Microsoft Visual Studio\2022\Community`
- Required workload: Desktop development with C++
- MSVC toolset: `14.44.35207`
- Platform toolset: `v143`
- `cl.exe`: `19.44.35228.0`
- Windows SDK: `10.0.26100.0`
- MSBuild: `17.14.51.32402`
- CMake generator: `Visual Studio 17 2022`

**FACT:** Flutter discovers Visual Studio through installed VS metadata. Ordinary shell `PATH` does not need to contain `cl.exe` or MSBuild for `flutter build windows`.

**POLICY:** An installed Visual Studio 2026 is not accepted merely because it is present.

## CMake and Ninja

**MUST VERIFY / ACCEPTED BUILD EVIDENCE:** CMake `3.31.6-msvc6` at `C:\Program Files\Microsoft Visual Studio\2022\Community\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe`, using generator `Visual Studio 17 2022`.

**INFORMATIONAL:** Ninja `1.12.1` is available beside Visual Studio, but the accepted Visual Studio generator build does not require Ninja.

**CURRENT MACHINE OBSERVATION / NOT ACCEPTED FOR THE PROVEN BUILD:** PATH exposes `C:\Strawberry\c\bin\cmake.exe` version `3.29.2` and `C:\Strawberry\c\bin\ninja.exe` version `1.12.0`.

## Perl

**MUST VERIFY / ACCEPTED BUILD EVIDENCE:**

- Distribution: Strawberry Perl
- Executable: `C:\Strawberry\perl\bin\perl.exe`
- Version: `5.42.2`
- Architecture: `MSWin32-x64-multi-thread`
- Required module: `Locale::Maketext::Simple` available

**FACT:** Perl is required by the native dependency compilation path involving sqlcipher and bundled OpenSSL source tooling. It is not required merely for Dart compilation or execution of an already-built Flutter package.

**POLICY:** Do not accept Git Perl merely because `perl.exe` exists. Use and verify the explicit Strawberry Perl environment for native builds.

## Zcash parameter files

**MUST PIN / FACT:**

| File | Size (bytes) | SHA-256 |
|---|---:|---|
| `sapling-spend.params` | `47,958,396` | `8e48ffd23abb3a5fd9c5589204f32d9c31285a04b78096ba40a79b75677efc13` |
| `sapling-output.params` | `3,592,860` | `2f0ebbcbb9bb0bcffe95a397e7eba89c29eb4dde6191c339db88570e3f3fb0e4` |

**CURRENT MACHINE OBSERVATION:** External copies were observed at `D:\.zcash-params`. Repository `assets/` copies exist with identical validated hashes. These files are required for the packaged/runtime wallet.

**POLICY:** Presence alone is insufficient; verify the fixed SHA-256 values. No external download source is approved here. Any future download provisioning must treat trusted-source selection as a separately controlled decision.

## Git and submodules

**CURRENT MACHINE OBSERVATION:** Git `2.52.0.windows.1`, executable `C:\Program Files\Git\cmd\git.exe`.

**MUST PIN / FACT:** `.gitmodules` SHA-256 is `949af2870770c9a44ed20798ab6d52c4c2e0311245a0e1110d4938b018e6f0cf`. Canonical gitlinks are:

| Path | Complete gitlink SHA |
|---|---|
| `native/zcash-sync` | `6bd60a6270bc3dd8be002afb0d6a85cdf4fe81d1` |
| `native/zcash-params` | `d6f179bf1186f226305f1372ee7cb7d78934ee6b` |
| `librustzcash` | `8b6c0c0a67105c5639450f41036963c9a5f57706` |
| `orchard` | `2186856809908e004c9a04b9374aa1ba5040f409` |
| `native/zcash-vote` | `7322086e471f60e302da07dad67315c47e3b47f0` |
| `misc/flathub` | `ac46f8397c8a9df2ac348a807ebf52ccce21a1c7` |

**POLICY:** Initialize with `git submodule update --init --recursive --checkout`, then verify every exact gitlink. Baseline reconstruction prohibits `--remote`. `native/zcash-sync` remains one pinned gitlink.

## Active native runtime

**FACT:**

- Source: `native/zcash-sync`
- Cargo package: `zcash-warpsync`
- Library: `warp_api_ffi`
- Crate types: `rlib`, `cdylib`
- Native release command baseline: `cargo build --locked --release --features=dart_ffi,sqlcipher`
- Expected output: `target\release\warp_api_ffi.dll`
- Required package destination: `build\windows\x64\runner\Release\warp_api_ffi.dll`
- Runtime loading: `DynamicLibrary.open('warp_api_ffi.dll')`

**POLICY:** Flutter does not automatically build this native runtime library. A separate native build is required. A successful Flutter compile without `warp_api_ffi.dll` is not sufficient proof of a runnable BUCK Wallet release.

## Native builder classification

**FACT:** `rust/rust_lib_buck_wallet` and `rust_builder` are detached/unused for the currently active Windows runtime. They are not `warp_api_ffi` and must not be substituted for the active runtime DLL.

**CARRIED VALIDATION:** Renamed builder crate Windows release build: **PASS**. This means the renamed builder crate builds; it does not prove the wallet release is runnable.

## Windows runner baseline

**MUST VERIFY / FACT:**

- Project: `buck_wallet`
- Binary: `buck-wallet.exe`
- Entry point: `wWinMain`
- Architecture: `x86-64`
- PE machine: `0x8664`
- Required subsystem: `2 / WINDOWS_GUI`
- Release directory: `build\windows\x64\runner\Release`
- Product: `BUCK Wallet`
- Original filename: `buck-wallet.exe`
- Icon: `windows\runner\resources\app.ico`
- Application version currently declared: `1.14.2+573`

Release verification must independently check executable identity, PE architecture, and subsystem.

## Runnable release-directory contract

**POLICY / MUST VERIFY:** A runnable release has this structural contract (generated plugin and MSVC runtime DLL names depend on the verified dependency/build output):

```text
build\windows\x64\runner\Release\
  buck-wallet.exe
  warp_api_ffi.dll
  flutter_windows.dll
  <required generated plugin DLLs>
  <required MSVC runtime DLLs if app-local deployment is retained>
  data\
    app.so
    icudtl.dat
    flutter_assets\
      AssetManifest.*
      FontManifest.json
      NOTICES.Z
      assets\
        sapling-spend.params
        sapling-output.params
        <branding/application assets>
      fonts\
      packages\
      shaders\
```

Release validation must check:

- `buck-wallet.exe` identity and BUCK metadata;
- x86-64 architecture and subsystem `2 / WINDOWS_GUI`;
- `warp_api_ffi.dll` presence and loadability;
- Flutter and plugin DLL completeness;
- packaged parameter hashes;
- version consistency;
- icon/resources presence;
- absence of legacy YWallet artifact names; and
- a successful runtime smoke test.

Flutter compilation alone is not release success.

## Recommended future build graph

**PROCEDURAL BASELINE, NOT P3 AUTOMATION:** Do not interpret this list as commands executed or automation implemented by this package.

1. Verify the exact repository checkout and baseline.
2. Recursively check out submodules and verify exact gitlinks.
3. Verify the toolchain.
4. Verify/provision Zcash parameters using approved data and hashes.
5. Restore locked Flutter dependencies using the explicit pinned SDK.
6. Perform required Dart code generation.
7. Build the native runtime.
8. Build the Flutter Windows release.
9. Package the runtime DLL and supplemental files.
10. Verify the release directory.
11. Run a controlled runtime smoke test.
12. Permit installer/archive input only after all preceding checks pass.

## Current CI difference

**FACT:** Current Windows CI is not yet the accepted reproducible baseline. It currently covers recursive checkout/submodules, native runtime DLL build, native DLL copy, and Flutter Windows release.

Missing or incomplete coverage includes:

- exact canonical SHA gate;
- accepted Flutter `3.24.5` revision and Dart revision verification;
- Rust toolchain verification;
- VS/MSVC/SDK and CMake/generator verification;
- Perl/module verification;
- parameter hash and Pub lock drift verification;
- `buck-wallet.exe` identity and x64/GUI subsystem verification;
- complete runtime packaging;
- settings migration tests;
- runtime smoke / blank-client detection;
- builder crate validation; and
- AV blocker classification.

Legacy CI declares Flutter `3.22.2`. P3 does not modify CI.

## Avast and Cargo validation boundary

**CARRIED FACT:**

- Cargo workspace check: **BLOCKED BY LOCAL AV / ENDPOINT ENVIRONMENT**
- Cargo workspace test: **NOT RUN AFTER CHECK BLOCKED**
- Detection: Avast EvoGen
- Assessment: **HIGH-CONFIDENCE LIKELY HEURISTIC FALSE POSITIVE**
- Vendor confirmation: **PENDING**

**POLICY:** An endpoint-security environmental blocker is neither PASS nor automatic product failure. Do not rerun the blocked command, disable Avast, add exclusions, or state that the Cargo workspace passed.

## Core compatibility separation

**UNPROVEN / PENDING:** Candidate core SHA `662668a3295df9d40e609d4dd59fba86036f466e`.

**CORE COMPATIBILITY BASELINE: PENDING HUMAN APPROVAL**

P3 does not approve this SHA. It is not a direct wallet source-tree build dependency. The `147`/`133` derivation discrepancy remains outside this package, and no derivation behavior change is authorized.

## Acceptance boundary

This manifest is usable with a clean clone, this repository documentation, and the required external tools/data. Every baseline reconstruction must pin immutable source inputs, verify environment-dependent tools rather than infer them, preserve pending classifications, and complete the runnable-release checks. It must not invent or silently select versions, hashes, download locations, compatibility approvals, or binary-determinism claims.
