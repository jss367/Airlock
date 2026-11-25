#!/bin/bash
if test $# -ne 2 || test "$1" != --notes-file || ! test -f "$2"; then
    echo "Usage: $0 --notes-file <release-notes.md>" > /dev/stderr
    exit 1
fi
notes_file="$(realpath "$2")"
cd "$(dirname "$0")"
source ./script/setup.sh

# Builds, notarizes, and publishes the version in VERSION as a GitHub release.
# In-app updates read appcast.xml from the latest release, so every release must include it.

repo=jss367/Airlock
version="$(cat VERSION)"
tag="v$version"

if ! grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' > /dev/null <<< "$version"; then
    echo "'$version' in VERSION is not a release version" > /dev/stderr
    exit 1
fi

./script/check-uncommitted-files.sh
git fetch --quiet --tags origin main
head="$(git rev-parse HEAD)"
if test "$head" != "$(git rev-parse origin/main)"; then
    echo "Publish only the latest commit of origin/main" > /dev/stderr
    exit 1
fi
# The tag exists already when an earlier run failed to publish
tagged="$(git rev-parse --quiet --verify "$tag^{commit}" || true)"
if test -n "$tagged" && test "$tagged" != "$head"; then
    echo "$tag is a different commit. Bump VERSION" > /dev/stderr
    exit 1
fi
if gh release view "$tag" --repo "$repo" > /dev/null 2>&1; then
    echo "$tag is already published" > /dev/stderr
    exit 1
fi

./build-release.sh --notarize
./script/generate-appcast.sh --notes-file "$notes_file"

cd .release
    assets=("Airlock-v$version.zip" "Airlock-app-v$version.zip" appcast.xml)
    shasum -a 256 "${assets[@]}" > SHA256SUMS
cd - > /dev/null

if test -z "$tagged"; then
    git tag -a "$tag" -m "Airlock $version"
fi
git push origin "refs/tags/$tag"
gh release create "$tag" "${assets[@]/#/.release/}" .release/SHA256SUMS \
    --repo "$repo" --verify-tag --latest --title "Airlock $version" --notes-file "$notes_file"

feed="$(plutil -extract SUFeedURL raw .release/Airlock.app/Contents/Info.plist)"
for _ in {1..12}; do
    if curl --fail --silent --location "$feed" | cmp - .release/appcast.xml; then
        echo "Published $tag. Installed copies of Airlock can update to it."
        exit 0
    fi
    sleep 5
done
echo "Published $tag, but $feed doesn't serve its appcast.xml yet. Check that it's the latest release" > /dev/stderr
exit 1
