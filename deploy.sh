#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"
codesign_identity="$(./script/find-code-signing-identity.sh)"

# Generation changes tracked sources. Restore their original contents, including
# local edits, on both success and failure rather than resetting them to Git HEAD.
generated_sources=(
  Sources/Common/versionGenerated.swift
  Sources/Common/gitHashGenerated.swift
  Sources/Cli/subcommandDescriptionsGenerated.swift
)
metadata_backup="$(mktemp -d)"
if ! cp "${generated_sources[@]}" "$metadata_backup/"; then
  rm -rf "$metadata_backup"
  exit 1
fi
restore_generated_sources() {
  for source in "${generated_sources[@]}"; do
    cp "$metadata_backup/${source##*/}" "$source" || return
  done
  rm -rf "$metadata_backup"
}
trap restore_generated_sources EXIT

echo "Stamping build version and Git commit..."
./generate.sh --generate-git-hash --ignore-xcodeproj --ignore-cmd-help --ignore-shell-parser

echo "Building with stable code-signing identity $codesign_identity..."
xcodebuild -project Airlock.xcodeproj -scheme Airlock -configuration Release build \
  MARKETING_VERSION="$(cat VERSION)" \
  CODE_SIGN_IDENTITY="$codesign_identity" CODE_SIGNING_REQUIRED=YES \
  -derivedDataPath .xcode-build \
  -quiet

echo "Running tests..."
swift test --quiet

echo "Building CLI..."
swift build --product airlock -c release --quiet

restore_generated_sources
trap - EXIT

# Stop the running app only after everything above succeeded, so a failed build or test leaves it running.
echo "Killing Airlock..."
pkill -f Airlock || true

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
