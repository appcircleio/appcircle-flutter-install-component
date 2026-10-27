# Appcircle Flutter Install

This workflow step installs the specified Flutter SDK to run the Flutter CLI for subsequent, Analyze, Build and Test operations.

Required Input Variables
- `$AC_SELECTED_FLUTTER_VERSION`: Flutter version or channel (`stable`, `beta`). Defaults to: `stable`. The step installs it from the official Flutter release archive to `~/flutter-sdk/<version>` and skips the download when that version is already there. Branches and commits require GitHub access ([Flutter SDK repo](https://github.com/flutter/flutter.git)).
- `$AC_FLUTTER_STORAGE_BASE_URL`: Base URL of the Flutter release archives. Defaults to: `https://storage.googleapis.com`. Set it to an internal mirror to install Flutter without internet access.

Output Variables
- `$PATH`: Added Flutter tool to your path.
