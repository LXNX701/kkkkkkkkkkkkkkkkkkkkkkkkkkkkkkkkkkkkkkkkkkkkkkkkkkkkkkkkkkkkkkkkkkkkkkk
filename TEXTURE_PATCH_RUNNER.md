# Texture Patch Runner

Implemented a dedicated texture flow.

## Changes
- Added `ThreeOneOSFive/helpers/TexturePatchRunner.swift`.
- Textures now resolve only from `Bundle.main/Textures/`.
- Textures no longer use the FF/FF Max `PatchSlotRunner`.
- Texture cards expose only:
  - `INJETAR`
  - `RESTORE ORIGINAL`
- Restore uses the transaction receipt associated with the decoded package ID.
- Existing FF/FF Max `PatchSlotRunner` remains unchanged.
- `PatchPackageCodec` was not weakened or changed to accept unsupported schema versions.

## Xcode
`TexturePatchRunner.swift` is registered in the Xcode project sources phase.
