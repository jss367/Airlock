#!/bin/bash
cd "$(dirname "$0")/.."
source ./script/setup.sh

# Writes .release/appcast.xml, the feed that tells installed copies of Airlock about the packaged release.
# Run it after build-release.sh. The signing key is in the login keychain, see dev-docs/development.md

build_version="$(cat VERSION)"
notes_file='' # mandatory
key_file='' # Instead of the keychain
while test $# -gt 0; do
    case $1 in
        --build-version) build_version="$2"; shift 2 ;;
        --notes-file) notes_file="$2"; shift 2 ;;
        --ed-key-file) key_file="$2"; shift 2 ;;
        *) echo "Unknown option $1" > /dev/stderr; exit 1 ;;
    esac
done
if ! test -f "$notes_file"; then echo "--notes-file is mandatory and must exist" > /dev/stderr; exit 1; fi

sparkle_bin=.xcode-build/SourcePackages/artifacts/sparkle/Sparkle/bin
keychain_account=dev.airlock
archive="Airlock-app-v$build_version"

key_args=(--account "$keychain_account")
if test -n "$key_file"; then
    key_args=(--ed-key-file "$key_file")
else
    # An update signed with any other key is rejected by every installed copy
    expected_key="$(plutil -extract SUPublicEDKey raw .release/Airlock.app/Contents/Info.plist)"
    if test "$("$sparkle_bin/generate_keys" --account "$keychain_account" -p)" != "$expected_key"; then
        echo "The keychain's Sparkle key doesn't match SUPublicEDKey in Airlock.app" > /dev/stderr
        exit 1
    fi
fi

# generate_appcast treats every archive in the directory as a release, and takes its notes from the file with the same name
rm -rf .release/appcast .release/appcast.xml && mkdir .release/appcast
cp ".release/$archive.zip" .release/appcast
cp "$notes_file" ".release/appcast/$archive.md"
"$sparkle_bin/generate_appcast" "${key_args[@]}" \
    --download-url-prefix "https://github.com/jss367/Airlock/releases/download/v$build_version/" \
    --link https://github.com/jss367/Airlock \
    --embed-release-notes \
    --maximum-deltas 0 \
    -o .release/appcast.xml \
    .release/appcast

for expected in \
    "<sparkle:version>$build_version</sparkle:version>" \
    "url=\"https://github.com/jss367/Airlock/releases/download/v$build_version/$archive.zip\"" \
    'sparkle:edSignature="'
do
    if ! grep --fixed-string "$expected" .release/appcast.xml > /dev/null; then
        echo "appcast.xml doesn't contain $expected" > /dev/stderr
        exit 1
    fi
done
