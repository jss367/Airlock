#!/bin/bash
# Check PR status and send a macOS notification with the result.
# Usage: check-pr.sh <pr-url>

PR_URL="$1"
if [ -z "$PR_URL" ]; then
  echo "Usage: check-pr.sh <pr-url>" >&2
  exit 1
fi

# Extract owner/repo#number from the URL
PR_NUMBER=$(echo "$PR_URL" | grep -oE '[0-9]+$')
REPO=$(echo "$PR_URL" | sed -E 's|https://github.com/([^/]+/[^/]+)/pull/[0-9]+|\1|')

if [ -z "$PR_NUMBER" ] || [ -z "$REPO" ]; then
  osascript -e "display notification \"Could not parse PR URL: $PR_URL\" with title \"Airlock PR Check\" sound name \"Basso\""
  exit 1
fi

# Check CI status
CHECKS=$(gh pr checks "$PR_NUMBER" --repo "$REPO" 2>&1)
CHECKS_EXIT=$?

# Check PR state
PR_STATE=$(gh pr view "$PR_NUMBER" --repo "$REPO" --json state,mergeable,reviewDecision --jq '"\(.state) mergeable=\(.mergeable) review=\(.reviewDecision)"' 2>&1)

if [ $CHECKS_EXIT -eq 0 ]; then
  SUMMARY="All checks passing. $PR_STATE"
  SOUND="Glass"
else
  FAILING=$(echo "$CHECKS" | grep -c "fail\|X")
  PENDING=$(echo "$CHECKS" | grep -c "pending\|*")
  SUMMARY="${FAILING} failing, ${PENDING} pending. $PR_STATE"
  SOUND="Basso"
fi

osascript -e "display notification \"$SUMMARY\" with title \"Airlock PR #${PR_NUMBER}\" sound name \"$SOUND\""
