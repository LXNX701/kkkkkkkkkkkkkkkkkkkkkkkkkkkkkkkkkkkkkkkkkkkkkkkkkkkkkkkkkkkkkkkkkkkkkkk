# Texture Patch Runner

This build separates the Textures UI and execution path from FF / FF Max.

Textures must show only:
- INJETAR
- RESTORE ORIGINAL

If the installed IPA still shows `INJETAR (40%)` and `LOBBY`, that IPA was built from an older source tree; those strings no longer exist in the root `ThreeOneOSFive/ContentView.swift` used by the Xcode project.
