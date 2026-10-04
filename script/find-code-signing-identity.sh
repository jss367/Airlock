#!/bin/bash
set -euo pipefail

if test -n "${AIRLOCK_CODE_SIGN_IDENTITY:-}"; then
    if test "$AIRLOCK_CODE_SIGN_IDENTITY" = "-"; then
        echo "AIRLOCK_CODE_SIGN_IDENTITY must name a stable certificate, not ad-hoc signing (-)." > /dev/stderr
        exit 1
    fi
    echo "$AIRLOCK_CODE_SIGN_IDENTITY"
    exit 0
fi

identities="$(security find-identity -v -p codesigning)"

# Prefer a Developer ID certificate. Its designated requirement remains stable
# across builds, which lets macOS preserve Accessibility permission on updates.
identity="$(awk '/"Developer ID Application:/ { print $2; exit }' <<< "$identities")"
if test -z "$identity"; then
    identity="$(awk '/"airlock-codesign-certificate"/ { print $2; exit }' <<< "$identities")"
fi

if test -z "$identity"; then
    cat > /dev/stderr <<'EOF'
No stable code-signing identity was found.

Install a Developer ID Application certificate or create the local
'airlock-codesign-certificate' described in dev-docs/development.md.
You can also set AIRLOCK_CODE_SIGN_IDENTITY to a certificate name or SHA-1 hash.
EOF
    exit 1
fi

echo "$identity"
