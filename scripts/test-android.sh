#!/usr/bin/env bash
# Android core and app tests, lint and a debug build. Add -PrecordScreenshots to refresh docs/evidence/android.
set -euo pipefail
cd "$(dirname "$0")/../apps/android"
./gradlew :core:test :app:testDebugUnitTest :app:lintDebug :app:assembleDebug "$@"
