# Airlock synchronous auto-merge

This adds actual squash merging, not a report-only check. The scheduled/manual
workflow and Codex-summary webhook execute only the gate checked out from the
repository's validated default branch. The Python entry point verifies the
canonical `jss367/Airlock` identity and public visibility before scanning PRs.
No repository, account, billing, runner-registration or protection settings are
queried or changed.

A PR must be open, ready, mergeable, target the default branch, lack
`no-automerge`, and have no open same-repository child PRs. Only a Codex-authored
structured `codex-review-state:v1` summary completing a clean review of the full
current head SHA, followed strictly by Codex's approval reaction, authorizes
consideration. Human emoji comments/reactions do not grant approval. Requested
additional Codex reviews must also be finished without unresolved findings.
Standing change requests and unresolved non-Codex threads block.

All issue comments and every paginated inline comment/reply are inspected.
Nonempty authenticated OWNER/COLLABORATOR human feedback must strictly predate
approval, including edits. Review edit times use GraphQL `fullDatabaseId`
normalized exactly against REST IDs; malformed, missing, duplicate and unmatched
IDs fail closed. Human-authored automation markers have no exemption. Codex-root
threads are exempt only if all visible participants are verified Codex accounts;
human replies, nested replies and siblings after a deleted root are included.

## Required real CI

`required-ci.json` requires these observed job names from the existing build:

- `build.yml`: `build-debug (macos-26)` and `build-release (macos-26)`.
- `merge-checks.yml`: `Merge gate regressions`.

The latest matching PR run must complete successfully for the exact head,
source repository/branch, PR number, target name and current tested-base SHA.
Each required job's latest execution must pass. Missing, pending, failed,
skipped, cancelled, stale or newer unsuccessful reruns block. Quoted run names
preserve the PR/base discriminator. Fork runs missing the PR/tested-base
association are unsupported for automatic merge; no success/head/title-only
fallback is used.

Every authoritative snapshot is fetched twice and compared before final PR and
child rechecks. The REST merge request atomically guards the reviewed head SHA.
It never arms deferred native auto-merge, and existing native requests are
cancelled before evaluation. Branches are retained. GitHub cannot atomically
guard labels, reviews, base or child state, so a narrow mutable-state race remains.

## Deployment isolation and postmerge verification

The existing `build.yml` release job packages an ad-hoc artifact and smoke-tests
installation on its disposable GitHub runner. It does not publish a release or
deploy to the user's Mac. That existing PR CI remains required and is otherwise
preserved. The new gate does **not** dispatch `build.yml` after merging.

Token-generated merges do not trigger push workflows. The gate instead
explicitly dispatches only `post-merge-tests.yml`, passing GitHub's returned
40-character merge commit SHA. That workflow checks out this exact commit and
runs the gate regressions plus the existing native debug build/test commands.
It never calls `build-release.sh`, `install-from-sources.sh` or `deploy.sh`, never
installs/launches Airlock, and has only `contents: read` permission. It does not
upload artifacts, register runners, or grant macOS permissions.

An uncertain merge-write result fails the entire gate job without retrying or
continuing to other PRs. Missing merge SHA or failed postmerge dispatch also fails
for operator recovery: inspect the actual merge state and, if merged, dispatch
`post-merge-tests.yml` with that merge SHA before rerunning the gate. Ordinary
pre-write gate rejection is nonfatal.

## Capacity, cost and activation

The public repository already successfully uses standard GitHub-hosted
`macos-26` runners for both required native jobs (for example run
[44190275353](https://github.com/jss367/Airlock/actions/runs/44190275353)). The new
jobs use the same macOS image and standard Ubuntu runners, without new artifact
or Actions cache storage. Standard hosted compute for public repositories is
[free](https://docs.github.com/en/billing/concepts/product-billing/github-actions).
No paid runner type or service is introduced. CI still may queue; queued work
cannot pass the gate.

The new write-capable workflow is not activated until a maintainer approves and
merges this change into the default branch. Draft PRs cannot merge. This change
does not set account/protection policy or guarantee GitHub will accept a future
write; an API refusal fails closed. Write/dispatch paths are tested synthetically,
without performing a live merge or postmerge dispatch in this implementation PR.

Run offline gate tests with Python, pytest, pytest-socket, PyYAML and jq:

```bash
python -m pytest -q --disable-socket --allow-unix-socket .github/auto-merge/tests
python -m ruff check .github/auto-merge
```

These tests live under `.github` because a root `tests/` directory on
case-insensitive macOS masks SwiftPM's existing `Sources/AppBundleTests`
discovery. Native builds/tests remain in Airlock's existing scripts.
