# Appcircle Flutter Install

This workflow step installs the specified Flutter SDK to run the Flutter CLI for subsequent, Analyze, Build and Test operations.

The step installs Flutter from the official release archives (`flutter_infra_release/releases`), not from a git clone:

1. It reads `releases_macos.json` (`releases_linux.json` on Linux) and resolves the selected version. `stable` and `beta` resolve to the current release of that channel. The archive matches the runner architecture (arm64 or x64).
2. It downloads the archive, verifies its sha256 checksum and extracts it to `~/flutter-sdk/<version>`.
3. If the same version is already in `~/flutter-sdk/<version>` (a runner that keeps its state, or a Cache Pull step), it skips the download.

Branches and commits (for example `main`) have no release archive. The step clones them from the [Flutter SDK repo](https://github.com/flutter/flutter.git), which requires GitHub access.

Input Variables
- `$AC_SELECTED_FLUTTER_VERSION`: Flutter version or channel (`stable`, `beta`). Defaults to: `stable`. Branches and commits require GitHub access. `$AC_FLUTTER_VERSION` from the build configuration overrides this input.

Optional Environment Variables
- `$FLUTTER_STORAGE_BASE_URL`: Base URL of the Flutter storage. Defaults to: `https://storage.googleapis.com`. Point it to an internal mirror (for example a raw proxy of `https://storage.googleapis.com`) to install Flutter without internet access. The Flutter tool uses the same variable for engine artifacts.

Output Variables
- `$PATH`: Added Flutter tool to your path.

## Caching the Flutter SDK

To reuse the SDK across builds, cache `~/flutter-sdk` with a label per Flutter version:

```yaml
- componentType: appcircle_cache_pull
  stepName: Cache Pull (Flutter SDK)
  inputs:
  - AC_CACHE_LABEL: "flutter-sdk/$AC_SELECTED_FLUTTER_VERSION"
# ... Flutter Install (finds the SDK in ~/flutter-sdk/<version> and skips the download) ...
- componentType: appcircle_android_flutter_cache_push   # or appcircle_ios_flutter_cache_push
  stepName: Cache Push (Flutter SDK)
  inputs:
  - AC_CACHE_LABEL: "flutter-sdk/$AC_SELECTED_FLUTTER_VERSION"
  - AC_CACHE_INCLUDED_PATHS: "~/flutter-sdk"
```
