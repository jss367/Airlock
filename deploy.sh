#!/bin/bash
set -e

echo "Killing Airlock..."
pkill -f Airlock || true

echo "Building..."
xcodebuild -project Airlock.xcodeproj -scheme Airlock -configuration Release build \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO \
  -derivedDataPath .xcode-build \
  -quiet

echo "Running tests..."
swift test --quiet

echo "Building CLI..."
swift build --product airlock -c release --quiet

echo "Deploying to /Applications..."
rm -rf /Applications/Airlock.app
cp -r .xcode-build/Build/Products/Release/Airlock.app /Applications/Airlock.app

echo "Installing CLI..."
CLI_BIN=$(swift build --product airlock -c release --show-bin-path)/airlock
mkdir -p ~/.local/bin
cp "$CLI_BIN" ~/.local/bin/airlock

echo "Launching..."
open /Applications/Airlock.app

echo "Done."
