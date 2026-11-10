#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

# Exercise only the build phase, with fake generator/build tools. The deployment
# phase is deliberately absent, so this test cannot install or launch the app.
grep -q '^# Stop the running app' deploy.sh
fixture="$(mktemp -d "${TMPDIR:-/tmp}/airlock-metadata-test.XXXXXX")"
trap 'rm -rf "$fixture"' EXIT
mkdir -p "$fixture/script" "$fixture/bin" "$fixture/backups" \
  "$fixture/Sources/Common" "$fixture/Sources/Cli" "$fixture/originals"
sed '/^# Stop the running app/,$d' deploy.sh > "$fixture/build-phase.sh"
cp VERSION "$fixture/"
cat > "$fixture/script/find-code-signing-identity.sh" <<'STUB'
#!/bin/bash
echo test-signing-identity
STUB
cat > "$fixture/generate.sh" <<'STUB'
#!/bin/bash
set -euo pipefail
test "$*" = '--generate-git-hash --mark-dirty --ignore-xcodeproj --ignore-cmd-help --ignore-shell-parser'
echo generate >> calls
for source in Sources/Common/versionGenerated.swift Sources/Common/gitHashGenerated.swift Sources/Cli/subcommandDescriptionsGenerated.swift; do
  echo generated > "$source"
done
if test "$FAIL_STAGE" = generate; then exit 42; fi
STUB
cat > "$fixture/bin/xcodebuild" <<'STUB'
#!/bin/bash
set -euo pipefail
grep -qx generated Sources/Common/gitHashGenerated.swift
printf '%s\n' "$@" | grep -qx "MARKETING_VERSION=$(cat VERSION)"
printf '%s\n' "$@" | grep -qx 'CODE_SIGN_IDENTITY=test-signing-identity'
echo xcodebuild >> calls
if test "$FAIL_STAGE" = xcodebuild; then exit 42; fi
STUB
cat > "$fixture/bin/swift" <<'STUB'
#!/bin/bash
set -euo pipefail
grep -qx generated Sources/Common/gitHashGenerated.swift
echo "$1" >> calls
if test "$FAIL_STAGE" = "$1"; then exit 42; fi
STUB
chmod +x "$fixture/script/find-code-signing-identity.sh" "$fixture/generate.sh" "$fixture/bin/"*

for original in snapshot local-edits; do
  for failure in none generate xcodebuild test build; do
    for source in Sources/Common/versionGenerated.swift Sources/Common/gitHashGenerated.swift Sources/Cli/subcommandDescriptionsGenerated.swift; do
      printf '%s %s\n' "$original" "$source" > "$fixture/$source"
      cp "$fixture/$source" "$fixture/originals/${source##*/}"
    done
    : > "$fixture/calls"
    status=0
    (
      cd "$fixture"
      PATH="$fixture/bin:$PATH" TMPDIR="$fixture/backups" FAIL_STAGE="$failure" \
        bash ./build-phase.sh > output 2>&1
    ) || status=$?
    if test "$failure" = none; then
      test "$status" -eq 0
      expected_calls=$'generate\nxcodebuild\ntest\nbuild'
    else
      test "$status" -eq 42
      case "$failure" in
        generate) expected_calls=generate ;;
        xcodebuild) expected_calls=$'generate\nxcodebuild' ;;
        test) expected_calls=$'generate\nxcodebuild\ntest' ;;
        build) expected_calls=$'generate\nxcodebuild\ntest\nbuild' ;;
      esac
    fi
    test "$(cat "$fixture/calls")" = "$expected_calls"
    for source in Sources/Common/versionGenerated.swift Sources/Common/gitHashGenerated.swift Sources/Cli/subcommandDescriptionsGenerated.swift; do
      cmp "$fixture/$source" "$fixture/originals/${source##*/}"
    done
    test -z "$(ls -A "$fixture/backups")"
    echo "PASS: $original restored after $failure"
  done
done

# Run the real metadata generator in a disposable Git repository. Verify that
# generation itself does not mark a clean build dirty, but initial edits do.
generator_fixture="$fixture/generator"
mkdir -p "$generator_fixture/script" "$generator_fixture/docs" \
  "$generator_fixture/Sources/Common" "$generator_fixture/Sources/Cli"
cp generate.sh VERSION "$generator_fixture/"
cp script/setup.sh "$generator_fixture/script/"
echo '/.deps/' > "$generator_fixture/.gitignore"
echo ':manpurpose: Fixture command' > "$generator_fixture/docs/airlock-test.adoc"
(
  cd "$generator_fixture"
  git init -q
  git config user.name 'Metadata Test'
  git config user.email 'metadata-test@example.invalid'
  ./generate.sh --ignore-xcodeproj --ignore-cmd-help --ignore-shell-parser
  git add .
  git -c commit.gpgsign=false commit -qm 'Metadata fixture'
  head="$(git rev-parse HEAD)"
  short_head="$(git rev-parse --short HEAD)"
  for state in clean tracked staged untracked; do
    git restore --staged --worktree Sources
    case "$state" in
      tracked) echo '// Local edit' >> Sources/Common/versionGenerated.swift ;;
      staged)
        echo '// Staged edit' >> Sources/Common/versionGenerated.swift
        git add Sources/Common/versionGenerated.swift
        ;;
      untracked) echo '// New source' > Sources/Common/new.swift ;;
    esac
    suffix=-dirty
    if test "$state" = clean; then suffix=; fi
    ./generate.sh --generate-git-hash --mark-dirty --ignore-xcodeproj --ignore-cmd-help --ignore-shell-parser
    grep -qx "public let gitHash = \"$head$suffix\"" Sources/Common/gitHashGenerated.swift
    grep -qx "public let gitShortHash = \"$short_head$suffix\"" Sources/Common/gitHashGenerated.swift
    echo "PASS: $state provenance"
  done
)
