# Block on review threads someone other than Codex left open on current code.
# Input: the PR's review threads, as `gh api graphql --paginate --slurp`
# pages. Arg: $author (Codex's GraphQL login, without the [bot] suffix).
# Prints "ok" or the reason to skip.
#
# Threads containing only verified Codex comments are gated by its structured state instead
# (has_unresolved_findings in codex_state.jq) and by the 👍 postdating its
# latest review, since it often leaves a fixed finding's thread open.
# Outdated human threads also block until resolved. A thread with no readable author fails closed.
[ .[].data.repository.pullRequest.reviewThreads.nodes[]
  | select(.isResolved == false )
  | ([.comments.nodes[] | .author.login // null]
     | map(select(. != $author)) | first) as $by
  | select((.comments.nodes | length) == 0 or any(.comments.nodes[]; .author.login != $author))
  | "\($by // "unknown") at \(.path):\(.line // "?")" ] as $open
| if $open == [] then "ok"
  else "\($open | length) unresolved review thread(s): \($open | join(", "))"
  end
