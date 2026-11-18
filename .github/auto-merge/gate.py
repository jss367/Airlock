"""Synchronous merge gate. Only default-branch code runs with the write token."""

import json
import os
import re
import subprocess
from copy import deepcopy
from datetime import datetime
from pathlib import Path
from urllib.parse import urlencode

GATE = Path(__file__).resolve().parent
BOT = "chatgpt-codex-connector[bot]"
EXPECTED_REPO = "jss367/Airlock"
POSTMERGE_WORKFLOW = "post-merge-tests.yml"
THREAD_QUERY = """query($owner:String!,$name:String!,$number:Int!,$endCursor:String){
 repository(owner:$owner,name:$name){pullRequest(number:$number){
 reviewThreads(first:100,after:$endCursor){pageInfo{hasNextPage endCursor}
 nodes{isResolved isOutdated path line comments(first:1){nodes{id author{login}}}}}}}}"""

FEEDBACK_QUERY = """query($owner:String!,$name:String!,$number:Int!,$endCursor:String){
 repository(owner:$owner,name:$name){pullRequest(number:$number){
 reviews(first:100,after:$endCursor){pageInfo{hasNextPage endCursor}
 nodes{fullDatabaseId updatedAt}}}}}"""


def api(path, *, method="GET", fields=None, pages=False):
    cmd = ["gh", "api", path, "--method", method]
    if pages:
        cmd += ["--paginate", "--slurp"]
    for key, value in (fields or {}).items():
        cmd += ["-F" if isinstance(value, int) else "-f", f"{key}={value}"]
    return json.loads(subprocess.check_output(cmd, text=True))


def verdict(program, data, **args):
    cmd = ["jq", "-r"]
    for key, value in args.items():
        cmd += [
            "--arg" if isinstance(value, str) else "--argjson",
            key,
            value if isinstance(value, str) else json.dumps(value),
        ]
    cmd += ["-f", str(GATE / program)]
    return subprocess.check_output(cmd, input=json.dumps(data), text=True).strip()


def require(condition, reason):
    if not condition:
        raise ValueError(reason)


def trusted_feedback(entry):
    # GitHub supplies author_association and user.type, not comment text.
    # No textual automation marker exempts a real owner's feedback.
    if entry.get("author_association") not in {"OWNER", "COLLABORATOR"}:
        return False
    kind = entry["user"]["type"]
    require(kind in {"User", "Bot"}, "unknown trusted feedback author type")
    body = entry.get("body")
    require(body is None or isinstance(body, str), "unreadable trusted feedback body")
    return kind == "User" and bool(body and body.strip())


def feedback_time(value):
    require(isinstance(value, str), "missing trusted feedback timestamp")
    parsed = datetime.fromisoformat(value)
    require(parsed.tzinfo is not None, "ambiguous trusted feedback timestamp")
    return parsed


def review_id(value):
    # GitHub BigInt may be a decimal JSON string while REST uses an integer.
    # Never round through float or accept bool (a subclass of int in Python).
    require(
        type(value) is int
        or (isinstance(value, str) and value.isascii() and value.isdecimal()),
        "invalid review database ID",
    )
    number = int(value)
    require(number > 0, "invalid review database ID")
    return str(number)


def review_edit_times(pages):
    result = {}
    for page in pages:
        for review in page["data"]["repository"]["pullRequest"]["reviews"]["nodes"]:
            key = review_id(review["fullDatabaseId"])
            require(key not in result, "duplicate review database ID")
            result[key] = review["updatedAt"]
    return result


def check_feedback(comments, reviews, review_updates, thumbs):
    cutoff = feedback_time(thumbs)
    for page in comments:
        for entry in page:
            if trusted_feedback(entry):
                # Both creation and edits matter, including an old comment
                # changed into an objection after the approval.
                require(
                    all(
                        feedback_time(entry.get(field)) < cutoff
                        for field in ("created_at", "updated_at")
                    ),
                    "trusted feedback comment is not older than Codex approval",
                )
    for page in reviews:
        for entry in page:
            if trusted_feedback(entry):
                # REST omits review edit times. Join GraphQL's updatedAt by
                # database ID so editing an old COMMENTED review also blocks.
                require(
                    feedback_time(entry.get("submitted_at")) < cutoff
                    and feedback_time(review_updates.get(review_id(entry["id"])))
                    < cutoff,
                    "trusted feedback review is not older than Codex approval",
                )


def thread_participants(threads, inline):
    # The thread query returns its first comment only. REST independently
    # paginates every inline comment/reply, including edited and outdated ones.
    by_id, by_node, replies = {}, {}, {}
    for page in inline:
        for comment in page:
            key = review_id(comment["id"])
            node = comment["node_id"]
            require(
                isinstance(node, str) and bool(node), "missing inline comment node ID"
            )
            require(
                key not in by_id and node not in by_node, "duplicate inline comment ID"
            )
            by_id[key], by_node[node] = comment, key
            if comment.get("in_reply_to_id") is not None:
                parent = review_id(comment["in_reply_to_id"])
                replies.setdefault(parent, []).append(key)
    result = deepcopy(threads)
    for page in result:
        for thread in page["data"]["repository"]["pullRequest"]["reviewThreads"][
            "nodes"
        ]:
            first = (
                thread["comments"]["nodes"][0] if thread["comments"]["nodes"] else {}
            )
            if (
                thread["isResolved"]
                or (first.get("author") or {}).get("login") != "chatgpt-codex-connector"
            ):
                continue
            root = by_node.get(first.get("id"))
            require(
                root is not None,
                "Codex thread root missing from paginated inline comments",
            )
            # The first visible comment may itself reply to a deleted root.
            # Follow parent IDs first so sibling replies are not silently lost.
            ancestors = set()
            while root in by_id and by_id[root].get("in_reply_to_id") is not None:
                require(root not in ancestors, "cyclic inline reply chain")
                ancestors.add(root)
                root = review_id(by_id[root]["in_reply_to_id"])
            pending, seen, authors = [root], set(), []
            while pending:
                key = pending.pop()
                require(key not in seen, "cyclic inline reply chain")
                seen.add(key)
                if (
                    key not in by_id
                ):  # A deleted original root can still link visible replies.
                    pending.extend(replies.get(key, []))
                    continue
                user = by_id[key].get("user") or {}
                if user.get("login") == BOT and user.get("type") == "Bot":
                    login = "chatgpt-codex-connector"
                else:
                    login = user.get("login")
                    if login == "chatgpt-codex-connector":
                        login = None  # An unverified human identity cannot stand in for Codex.
                authors.append({"author": {"login": login}})
                pending.extend(replies.get(key, []))
            thread["comments"]["nodes"] = authors
    return result


def children(repo, pr):
    if pr["head"]["repo"]["full_name"] != repo:
        return []
    return api(
        f"repos/{repo}/pulls?"
        + urlencode({"state": "open", "base": pr["head"]["ref"], "per_page": 100}),
        pages=True,
    )


def snapshot(repo, number, head, default, workflows):
    """Fetch all authoritative evidence; missing data/errors cannot authorize a merge."""
    root = f"repos/{repo}"
    pr = api(f"{root}/pulls/{number}")
    require(
        verdict("live.jq", pr, head=head, default=default) == "ok", "PR state blocks"
    )
    require(pr.get("mergeable") is True, "mergeability unknown or conflicting")
    require(pr.get("auto_merge") is None, "native auto-merge still armed")
    child_pages = children(repo, pr)
    require(not any(child_pages), "open child PRs target this branch")
    reactions = api(f"{root}/issues/{number}/reactions?per_page=100", pages=True)
    thumbs = max(
        (
            r["created_at"]
            for page in reactions
            for r in page
            if r["content"] == "+1" and r["user"]["login"] == BOT
        ),
        default="",
    )
    require(bool(thumbs), "no Codex approval reaction")
    timeline = api(f"{root}/issues/{number}/timeline?per_page=100", pages=True)
    retargeted = max(
        (
            e["created_at"]
            for page in timeline
            for e in page
            if e.get("event") == "base_ref_changed"
        ),
        default="",
    )
    require(thumbs > retargeted, "approval predates base change")
    reviews = api(f"{root}/pulls/{number}/reviews?per_page=100", pages=True)
    require(
        all(
            thumbs > r["submitted_at"]
            for page in reviews
            for r in page
            if r["user"]["login"] == BOT
        ),
        "approval predates Codex findings",
    )
    require(verdict("reviews.jq", reviews) == "ok", "standing change request")
    comments = api(f"{root}/issues/{number}/comments?per_page=100", pages=True)
    require(
        verdict("codex_state.jq", comments, bot=BOT, head=head, thumbs=thumbs) == "ok",
        "no clean exact-head structured Codex review",
    )
    review_updates = {}
    if any(trusted_feedback(r) for page in reviews for r in page):
        updates = api(
            "graphql",
            method="POST",
            fields={
                "owner": repo.split("/")[0],
                "name": repo.split("/")[1],
                "number": number,
                "query": FEEDBACK_QUERY,
            },
            pages=True,
        )
        review_updates = review_edit_times(updates)
    inline = api(f"{root}/pulls/{number}/comments?per_page=100", pages=True)
    check_feedback(comments + inline, reviews, review_updates, thumbs)
    threads = api(
        "graphql",
        method="POST",
        fields={
            "owner": repo.split("/")[0],
            "name": repo.split("/")[1],
            "number": number,
            "query": THREAD_QUERY,
        },
        pages=True,
    )
    require(
        verdict(
            "threads.jq",
            thread_participants(threads, inline),
            author="chatgpt-codex-connector",
        )
        == "ok",
        "unresolved review threads",
    )
    evidence = []
    for workflow, required_jobs in workflows.items():
        runs = api(
            f"{root}/actions/workflows/{workflow}/runs?"
            + urlencode({"event": "pull_request", "head_sha": head, "per_page": 100}),
            pages=True,
        )
        run = json.loads(
            verdict(
                "ci_run.jq",
                runs,
                head=head,
                source_repo=pr["head"]["repo"]["full_name"],
                source_branch=pr["head"]["ref"],
                retargeted=retargeted,
                number=number,
                target_title=f"Tests for pull request #{number} against {default}",
            )
        )
        require(
            run is not None
            and run["status"] == "completed"
            and run["conclusion"] == "success",
            f"{workflow}: latest exact-head CI missing or not successful",
        )
        require(
            any(
                p.get("number") == number
                and p.get("base", {}).get("sha") == pr["base"]["sha"]
                for p in run["pull_requests"]
            ),
            "CI tested another base revision",
        )
        jobs = api(
            f"{root}/actions/runs/{run['id']}/jobs?filter=all&per_page=100", pages=True
        )
        require(
            verdict("ci_jobs.jq", jobs, required=required_jobs) == "true",
            f"{workflow}: required jobs missing or not successful",
        )
        evidence.append((runs, jobs))
    # Comparing complete fetched evidence also detects reruns, edited summaries,
    # newly added objections, retargeting and children during the first pass.
    return (
        pr,
        child_pages,
        reactions,
        timeline,
        reviews,
        comments,
        inline,
        review_updates,
        threads,
        evidence,
    )


def dispatch(repo, workflow, default, merge_sha):
    done = subprocess.run(
        [
            "gh",
            "workflow",
            "run",
            workflow,
            "--repo",
            repo,
            "--ref",
            default,
            "-f",
            f"merged_sha={merge_sha}",
        ],
        check=False,
    )
    if done.returncode:
        raise RuntimeError(
            f"Merged, but postmerge tests failed to dispatch: {workflow}"
        )


def merge_candidate(repo, number, head, default, workflows):
    before = snapshot(repo, number, head, default, workflows)
    after = snapshot(repo, number, head, default, workflows)
    require(before == after, "merge evidence changed during evaluation")
    require(api(f"repos/{repo}")["default_branch"] == default, "default branch changed")
    live = api(f"repos/{repo}/pulls/{number}")
    require(
        live == after[0] and not any(children(repo, live)),
        "final PR or child state changed",
    )
    # REST's sha precondition is atomic. Unlike gh pr merge, this cannot
    # silently queue/arm an auto-merge request when checks are pending.
    try:
        result = api(
            f"repos/{repo}/pulls/{number}/merge",
            method="PUT",
            fields={"sha": head, "merge_method": "squash"},
        )
        if not isinstance(result, dict) or result.get("merged") is not True:
            raise ValueError("GitHub did not confirm the merge")
    except Exception as error:
        # A transport/decode failure may happen AFTER GitHub merged. Never
        # swallow it as a rejection, retry the write, or continue to other PRs.
        raise RuntimeError(
            f"PR #{number}: merge write failed or outcome is uncertain; stop for operator recovery. "
            "Verify the PR merge state and dispatch required postmerge tests if merged before rerunning."
        ) from error
    # GITHUB_TOKEN push events do not start workflows. Explicit dispatch starts
    # only a dedicated build/test workflow at the actual merge commit. The
    # existing build.yml also installs a release on its ephemeral runner, so
    # it is deliberately NOT dispatched after a token merge.
    merge_sha = result.get("sha")
    if (
        not isinstance(merge_sha, str)
        or re.fullmatch(r"[0-9a-f]{40}", merge_sha) is None
    ):
        raise RuntimeError(
            "Merged, but response lacks a valid merge SHA; operator must recover postmerge tests"
        )
    dispatch(repo, POSTMERGE_WORKFLOW, default, merge_sha)


def main():
    repo = os.environ["REPO"]
    workflows = json.loads((GATE / "required-ci.json").read_text())
    metadata = api(f"repos/{repo}")
    require(
        repo == EXPECTED_REPO and metadata.get("full_name") == EXPECTED_REPO,
        "This gate is reserved for jss367/Airlock",
    )
    require(
        metadata.get("private") is False,
        "Public repository required for the $0 hosted-runner policy",
    )
    default = metadata["default_branch"]
    pulls = api(f"repos/{repo}/pulls?state=open&per_page=100", pages=True)
    for page in pulls:
        for pr in page:
            number = pr["number"]
            # Remove legacy deferred requests even for PRs that now fail gates.
            # No repository/branch protection settings are read or changed.
            if pr.get("auto_merge") is not None:
                subprocess.run(
                    [
                        "gh",
                        "pr",
                        "merge",
                        str(number),
                        "--repo",
                        repo,
                        "--disable-auto",
                    ],
                    check=True,
                )
            try:
                merge_candidate(repo, number, pr["head"]["sha"], default, workflows)
            except (
                ValueError,
                KeyError,
                TypeError,
                subprocess.CalledProcessError,
            ) as error:
                print(f"PR #{number}: stopped: {error}", flush=True)


if __name__ == "__main__":
    main()
