#!/bin/zsh
set -eu
cd "$(dirname "$0")/.."
# Seed a synthetic image for the native PhotosPicker attachment UI test.
vetmed_destination="${VETMED_SIM_DESTINATION:-platform=iOS Simulator,name=iPhone 17}"
vetmed_device=$(python3 - "$vetmed_destination" <<'PYDEVICE'
import re, sys
match = re.search(r'(?:^|,)(?:id|name)=([^,]+)', sys.argv[1])
if not match:
    raise SystemExit("The simulator destination must include id= or name=.")
print(match.group(1))
PYDEVICE
)
xcrun simctl boot "$vetmed_device" 2>/dev/null || true
xcrun simctl bootstatus "$vetmed_device" -b
xcrun simctl addmedia "$vetmed_device" docs/evidence/standalone-quick-check.png
xcodegen generate --spec apps/ios/project.yml
xcodebuild -project apps/ios/VetMed.xcodeproj -scheme VetMed \
  -destination "$vetmed_destination" \
  -derivedDataPath .build/ios -skipPackagePluginValidation -skipMacroValidation \
  test
