#!/bin/bash
set -e

# Debug builds keep this loop incremental. deploy.sh does the release builds.
echo "Building..."
xcodebuild -project Airlock.xcodeproj -scheme Airlock -configuration Debug build \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO \
  -derivedDataPath .xcode-build \
  -quiet

echo "Running tests..."
swift test --quiet

echo "Done."
