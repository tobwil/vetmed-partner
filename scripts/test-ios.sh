#!/bin/zsh
set -eu
cd "$(dirname "$0")/.."
xcodegen generate --spec apps/ios/project.yml
xcodebuild -project apps/ios/VetMed.xcodeproj -scheme VetMed \
  -destination "${VETMED_SIM_DESTINATION:-platform=iOS Simulator,name=iPhone 17}" \
  -derivedDataPath .build/ios -skipPackagePluginValidation -skipMacroValidation \
  test
