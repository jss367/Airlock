#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"
codesign_identity="$(./script/find-code-signing-identity.sh)"

echo "Killing Airlock..."
pkill -f Airlock || true

echo "Building with stable code-signing identity $codesign_identity..."
xcodebuild -project Airlock.xcodeproj -scheme Airlock -configuration Release build \
  CODE_SIGN_IDENTITY="$codesign_identity" CODE_SIGNING_REQUIRED=YES \
  -derivedDataPath .xcode-build \
  -quiet

echo "Running tests..."
swift test --quiet

echo "Building CLI..."
swift build --product airlock -c release --quiet

echo "Deploying to /Applications..."
rm -rf /Applications/Airlock.app
cp -r .xcode-build/Build/Products/Release/Airlock.app /Applications/Airlock.app
codesign --verify --deep --strict /Applications/Airlock.app

echo "Installing CLI..."
CLI_BIN=$(swift build --product airlock -c release --show-bin-path)/airlock
mkdir -p ~/.local/bin
cp "$CLI_BIN" ~/.local/bin/airlock

echo "Launching..."
open /Applications/Airlock.app

echo "Done."
