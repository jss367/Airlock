#!/bin/bash
set -euo pipefail

airlock_developer_team_id="3CJQ95F6MT"

if test "${1:-}" = "--print-airlock-team-id"; then
    echo "$airlock_developer_team_id"
    exit 0
fi
if test $# -ne 0; then
    echo "Unknown option: $1" > /dev/stderr
    exit 1
fi

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
identity="$(awk -v team_id="$airlock_developer_team_id" '
    /"Developer ID Application:/ && index($0, "(" team_id ")") { print $2; exit }
' <<< "$identities")"

if test -z "$identity"; then
    developer_identities="$(awk '/"Developer ID Application:/ { print $2 }' <<< "$identities")"
    developer_id_count="$(awk 'NF { count += 1 } END { print count + 0 }' <<< "$developer_identities")"
    if test "$developer_id_count" -gt 1; then
        cat > /dev/stderr <<'EOF'
Multiple Developer ID Application certificates are installed, and none belongs
to Airlock's release team. Set AIRLOCK_CODE_SIGN_IDENTITY to the certificate
name or SHA-1 hash that should be used for local deployments.
EOF
        exit 1
    fi
    identity="$developer_identities"
fi

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
