#!/bin/bash
set -euo pipefail

# Puts the command-line tool inside a built Airlock.app and signs everything in the bundle.
#
# Xcode signs Sparkle.framework but not the helpers inside it, and an update must replace the app and the
# command-line tool together. Both change the bundle after Xcode signed it, so it's signed again here.

app=''
cli=''
identity=''
timestamp='--timestamp=none' # Local builds shouldn't need Apple's timestamp server
while test $# -gt 0; do
    case $1 in
        --app) app="$2"; shift 2 ;;
        --cli) cli="$2"; shift 2 ;;
        --codesign-identity) identity="$2"; shift 2 ;;
        --timestamp) timestamp='--timestamp'; shift ;; # Notarization requires it
        *) echo "Unknown option $1" > /dev/stderr; exit 1 ;;
    esac
done
if test -z "$app" || test -z "$cli" || test -z "$identity"; then
    echo "Usage: $0 --app <Airlock.app> --cli <airlock> --codesign-identity <identity> [--timestamp]" > /dev/stderr
    exit 1
fi

sign() {
    codesign --force --options runtime "$timestamp" --sign "$identity" "$@"
}

# macOS file systems usually ignore case, so the tool can't sit next to Contents/MacOS/Airlock
mkdir -p "$app/Contents/Helpers"
cp "$cli" "$app/Contents/Helpers/airlock"
sign "$app/Contents/Helpers/airlock"

# Innermost code first. https://sparkle-project.org/documentation/sandboxing/#code-signing
sparkle="$app/Contents/Frameworks/Sparkle.framework"
sign "$sparkle/Versions/B/XPCServices/Installer.xpc"
sign --preserve-metadata=entitlements "$sparkle/Versions/B/XPCServices/Downloader.xpc"
sign "$sparkle/Versions/B/Autoupdate"
sign "$sparkle/Versions/B/Updater.app"
sign "$sparkle"

entitlements="$(mktemp -d)/Airlock.entitlements"
trap 'rm -rf "$(dirname "$entitlements")"' EXIT
cp "$(dirname "$0")/../resources/Airlock.entitlements" "$entitlements"
# The hardened runtime loads only frameworks with the app's Team ID. Self-signed and ad-hoc identities have none,
# so without this entitlement such a build crashes at launch when it loads Sparkle.
if codesign -dv "$sparkle" 2>&1 | grep '^TeamIdentifier=not set$' > /dev/null; then
    /usr/libexec/PlistBuddy -c 'Add :com.apple.security.cs.disable-library-validation bool true' "$entitlements"
fi
# Keep the designated requirement that Xcode wrote: macOS ties Accessibility permission to it
sign --preserve-metadata=requirements --entitlements "$entitlements" "$app"

codesign --verify --deep --strict "$app"
