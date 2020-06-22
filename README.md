# Appcircle Flutter Install

This workflow step installs the specified Flutter SDK to run the Flutter CLI for subsequent, Analyze, Build and Test operations.

Required Input Variables
- `$AC_SELECTED_FLUTTER_VERSION`: Specifies the Flutter version to install. Defaults to: `stable`. You can use any available tag or branch in [Flutter SDK repo](https://github.com/flutter/flutter.git)

Output Variables
- `$PATH`: Added Flutter tool to your path.
