# P5A onboarding runtime finding

P5A portable Windows runtime validation passed. The executable started, the
wallet persisted across a clean restart, and backend connection and
synchronization operated successfully.

The first-run Welcome and Disclaimer visuals did not match the final BUCK
identity, and their image-heavy layout required remediation for the supported
Windows window and smaller resized windows. The post-onboarding Main Wallet UI
was already aligned with the current black, dark, and red BUCK direction.

This finding is limited to onboarding presentation and window fit. No wallet
seeds, addresses, private data, or runtime screenshots are included here.

UI1 replaced the generic Welcome and Disclaimer imagery with a BUCK-specific
onboarding identity. Runtime validation was completed under a fresh, dedicated
Windows standard-user profile with these results:

- Welcome: PASS.
- Disclaimer / Self-Custody: PASS.
- New Account: PASS.
- Normal and reduced window sizes: PASS.
- Responsive text wrapping and scrolling when required: PASS.
- Clean shutdown: PASS.

No wallet or account was created, no seed was generated, and no restore was
performed. The disposable runtime executable and injected native DLL retained
their verified integrity after testing. The onboarding redesign was accepted
as implemented; additional visual remediation is not required.
