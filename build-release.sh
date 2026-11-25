#!/bin/bash
cd "$(dirname "$0")"
source ./script/setup.sh

build_version="$(cat VERSION)"
codesign_identity=""
allow_adhoc_signing=0
require_developer_id=0
notarize=0
while test $# -gt 0; do
    case $1 in
        --build-version) build_version="$2"; shift 2;;
        --codesign-identity) codesign_identity="$2"; shift 2;;
        --allow-adhoc-signing) allow_adhoc_signing=1; shift;;
        --require-developer-id) require_developer_id=1; shift;;
        --notarize) notarize=1; require_developer_id=1; shift;;
        *) echo "Unknown option $1" > /dev/stderr; exit 1 ;;
    esac
done

if test -z "$codesign_identity"; then
    codesign_identity="$(./script/find-code-signing-identity.sh)"
fi
if test "$codesign_identity" = "-" && test "$allow_adhoc_signing" != 1; then
    echo "Refusing to package an ad-hoc-signed release. Use a stable signing identity." > /dev/stderr
    echo "Pass --allow-adhoc-signing only for a non-distributed CI build." > /dev/stderr
    exit 1
fi

notary_profile="${AIRLOCK_NOTARY_PROFILE:-airlock-notary}"
if test "$notarize" = 1 && ! xcrun notarytool history --keychain-profile "$notary_profile" > /dev/null; then
    echo "Can't notarize with the keychain profile '$notary_profile'. See dev-docs/development.md for how to create it." > /dev/stderr
    exit 1
fi

#############
### BUILD ###
#############

./build-docs.sh
./build-shell-completion.sh

./generate.sh --ignore-xcodeproj
./script/check-uncommitted-files.sh
./generate.sh --build-version "$build_version" --codesign-identity "$codesign_identity" --generate-git-hash

swift build -c release --arch arm64 --arch x86_64 --product airlock -Xswiftc -warnings-as-errors # CLI

# toolchain="$(plutil -extract CFBundleIdentifier raw ~/Library/Developer/Toolchains/swift-6.1-RELEASE.xctoolchain/Info.plist)"
# xcodebuild -toolchain "$toolchain" \
# Unfortunately, Xcode 16 fails with:
#     2025-05-05 15:51:15.618 xcodebuild[4633:13690815] Writing error result bundle to /var/folders/s1/17k6s3xd7nb5mv42nx0sd0800000gn/T/ResultBundle_2025-05-05_15-51-0015.xcresult
#     xcodebuild: error: Could not resolve package dependencies:
#       <unknown>:0: warning: legacy driver is now deprecated; consider avoiding specifying '-disallow-use-new-driver'
#     <unknown>:0: error: unable to execute command: <unknown>

rm -rf .release && mkdir .release

xcode_configuration="Release"
xcodebuild -version
xcodebuild-pretty .release/xcodebuild.log clean build \
    -scheme Airlock \
    -destination "generic/platform=macOS" \
    -configuration "$xcode_configuration" \
    -derivedDataPath .xcode-build

git checkout .

ditto ".xcode-build/Build/Products/$xcode_configuration/Airlock.app" .release/Airlock.app

############
### SIGN ###
############

bundle_app_args=(--app .release/Airlock.app --cli .build/apple/Products/Release/airlock --codesign-identity "$codesign_identity")
if test "$require_developer_id" = 1; then
    bundle_app_args+=(--timestamp)
fi
./script/bundle-app.sh "${bundle_app_args[@]}"

################
### VALIDATE ###
################

expected_layout=$(cat <<EOF
.release/Airlock.app
.release/Airlock.app/Contents
.release/Airlock.app/Contents/_CodeSignature
.release/Airlock.app/Contents/_CodeSignature/CodeResources
.release/Airlock.app/Contents/MacOS
.release/Airlock.app/Contents/MacOS/Airlock
.release/Airlock.app/Contents/Resources
.release/Airlock.app/Contents/Resources/default-config.toml
.release/Airlock.app/Contents/Resources/AppIcon.icns
.release/Airlock.app/Contents/Resources/Assets.car
.release/Airlock.app/Contents/Info.plist
.release/Airlock.app/Contents/PkgInfo
.release/Airlock.app/Contents/Helpers
.release/Airlock.app/Contents/Helpers/airlock
.release/Airlock.app/Contents/Frameworks
.release/Airlock.app/Contents/Frameworks/Sparkle.framework
EOF
)
expected_layout="$(sort <<< "$expected_layout")"
actual_layout="$(find .release/Airlock.app -name Sparkle.framework -prune -print -o -print | sort)"

if test "$expected_layout" != "$actual_layout"; then
    echo "!!! Expect/Actual layout don't match !!!"
    diff <(echo "$expected_layout") <(echo "$actual_layout") || true
    exit 1
fi

check-info-plist() {
    actual="$(plutil -extract "$1" raw .release/Airlock.app/Contents/Info.plist)"
    if test "$actual" != "$2"; then
        echo "$1 is '$actual' in Info.plist. Expected: '$2'"
        exit 1
    fi
}

# Sparkle needs all of these to find, verify, and compare releases
check-info-plist CFBundleVersion "$build_version"
check-info-plist CFBundleShortVersionString "$build_version"
check-info-plist SUFeedURL "https://github.com/jss367/Airlock/releases/latest/download/appcast.xml"
check-info-plist SUPublicEDKey "$(plutil -extract SUPublicEDKey raw resources/Info.plist)"

check-universal-binary() {
    if ! file "$1" | grep --fixed-string -q "Mach-O universal binary with 2 architectures: [x86_64:Mach-O 64-bit executable x86_64] [arm64"; then
        echo "$1 is not a universal binary"
        exit 1
    fi
}

check-contains-hash() {
    hash=$(git rev-parse HEAD)
    if ! strings "$1" | grep --fixed-string "$hash" > /dev/null; then
        echo "$1 doesn't contain $hash"
        exit 1
    fi
}

check-universal-binary .release/Airlock.app/Contents/MacOS/Airlock
check-universal-binary .release/Airlock.app/Contents/Helpers/airlock

check-contains-hash .release/Airlock.app/Contents/MacOS/Airlock
check-contains-hash .release/Airlock.app/Contents/Helpers/airlock

codesign --verify --deep --strict .release/Airlock.app
codesign -v .release/Airlock.app/Contents/Helpers/airlock

app_codesign_info="$(codesign -dvv .release/Airlock.app 2>&1)"
cli_codesign_info="$(codesign -dvv .release/Airlock.app/Contents/Helpers/airlock 2>&1)"

if test "$allow_adhoc_signing" != 1; then
    if grep '^Signature=adhoc$' > /dev/null <<< "$app_codesign_info"; then
        echo "Refusing to package an ad-hoc-signed Airlock.app" > /dev/stderr
        exit 1
    fi
    if grep '^Signature=adhoc$' > /dev/null <<< "$cli_codesign_info"; then
        echo "Refusing to package an ad-hoc-signed airlock CLI" > /dev/stderr
        exit 1
    fi
fi

if test "$require_developer_id" = 1; then
    airlock_developer_team_id="$(./script/find-code-signing-identity.sh --print-airlock-team-id)"
    if ! grep '^Authority=Developer ID Application:' > /dev/null <<< "$app_codesign_info"; then
        echo "Refusing to package a public release without a Developer ID Application signature" > /dev/stderr
        exit 1
    fi
    if ! grep '^Authority=Developer ID Application:' > /dev/null <<< "$cli_codesign_info"; then
        echo "Refusing to package a public CLI release without a Developer ID Application signature" > /dev/stderr
        exit 1
    fi
    if ! grep "^TeamIdentifier=$airlock_developer_team_id$" > /dev/null <<< "$app_codesign_info"; then
        echo "Refusing to package a public release for a team other than $airlock_developer_team_id" > /dev/stderr
        exit 1
    fi
    if ! grep "^TeamIdentifier=$airlock_developer_team_id$" > /dev/null <<< "$cli_codesign_info"; then
        echo "Refusing to package a public CLI release for a team other than $airlock_developer_team_id" > /dev/stderr
        exit 1
    fi
fi

################
### NOTARIZE ###
################

if test "$notarize" = 1; then
    ditto -c -k --keepParent .release/Airlock.app .release/notarize.zip
    # Check the status in the output. The exit code can be 0 even when Apple rejects the archive
    xcrun notarytool submit .release/notarize.zip --keychain-profile "$notary_profile" --wait | tee .release/notarize.log || true
    if ! grep '^ *status: Accepted$' .release/notarize.log > /dev/null; then
        submission="$(awk '$1 == "id:" { print $2; exit }' .release/notarize.log)"
        xcrun notarytool log "$submission" --keychain-profile "$notary_profile" > /dev/stderr || true
        echo "Apple rejected the notarization" > /dev/stderr
        exit 1
    fi
    xcrun stapler staple .release/Airlock.app
    rm .release/notarize.zip
fi

############
### PACK ###
############

# Sparkle installs from an archive that holds only the app. ditto keeps the symlinks inside Sparkle.framework.
# Without --norsrc it also adds ._ files, and unzip leaves them in the bundle, which breaks the signature.
ditto -c -k --norsrc --keepParent .release/Airlock.app ".release/Airlock-app-v$build_version.zip"

mkdir -p ".release/Airlock-v$build_version/manpage" && cp .man/*.1 ".release/Airlock-v$build_version/manpage"
cp -r ./legal ".release/Airlock-v$build_version/legal"
cp LICENSE.txt ".release/Airlock-v$build_version/LICENSE.txt"
cp -r .shell-completion ".release/Airlock-v$build_version/shell-completion"
cd .release
    ditto Airlock.app "Airlock-v$build_version/Airlock.app"
    zip --symlinks -r "Airlock-v$build_version.zip" "Airlock-v$build_version"
cd -

#################
### Brew Cask ###
#################
for cask_name in airlock airlock-dev; do
    ./script/build-brew-cask.sh \
        --cask-name "$cask_name" \
        --zip-uri ".release/Airlock-v$build_version.zip" \
        --build-version "$build_version"
done
