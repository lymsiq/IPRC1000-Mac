# Project Notes

## Build verification

- Validate the macOS app with the same Release build configuration used by
  `scripts/package-app.sh`:

  ```sh
  SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk \
  CLANG_MODULE_CACHE_PATH=/private/tmp/iprc1000-module-cache \
  SWIFT_MODULECACHE_PATH=/private/tmp/iprc1000-module-cache \
    swift build --disable-sandbox -c release \
      --sdk /Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk
  ```

- Do not use a plain `swift build` result to judge this project. The default SDK
  may not match the installed Swift compiler, and restricted environments may
  prevent writes to the user module cache. Reproduce failures with the command
  above before calling them project or toolchain defects.
- Run `scripts/package-app.sh` only when packaging and code signing are required;
  it replaces the existing app under `dist/` and invokes `codesign`.

## Packaging variants

- Every packaging delivery must produce two separate artifacts without allowing
  one variant to overwrite the other:
  - GitHub Release artifact: use ad-hoc signing (`codesign --sign -`).
  - Local installation/test artifact: use the user's previously configured
    signing identity via `IPRC1000_CODE_SIGN_IDENTITY`.
- Give the two artifacts distinct names and verify each artifact's signature
  with `codesign` before reporting packaging complete.
