#!/bin/bash
set -e

echo "Building..."
xcodebuild -project Airlock.xcodeproj -scheme Airlock -configuration Release build \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO \
  -derivedDataPath .xcode-build \
  -quiet

echo "Running tests..."
swift test --quiet

echo "Building CLI..."
swift build --product airlock -c release --quiet

echo "Done."
