"""Check real YAML run names against the exact-head CI selector contract."""

import importlib.util
import json
from pathlib import Path

import pytest
import yaml

ROOT = Path(__file__).resolve().parents[3]
SPEC = importlib.util.spec_from_file_location(
    "workflow_fixtures", Path(__file__).with_name("test_auto_merge.py")
)
fixtures = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(fixtures)
REQUIRED = json.loads((ROOT / ".github/auto-merge/required-ci.json").read_text())


@pytest.mark.parametrize("workflow", REQUIRED)
def test_required_workflow_yaml_title_is_accepted_by_ci_selector(workflow):
    document = yaml.safe_load((ROOT / ".github/workflows" / workflow).read_text())
    title = (
        document["run-name"]
        .replace("${{ github.event.pull_request.number }}", "7")
        .replace("${{ github.event.pull_request.base.ref }}", "main")
    )
    run = fixtures.run(3)
    run["display_title"] = title
    # An unquoted # is a YAML comment: the actual API title is truncated, and
    # the exact-head gate must reject it even though the job itself passed.
    selected = fixtures.ci_run(run)
    assert selected is not None, (
        f"{workflow}: parsed YAML run-name {title!r} cannot pass the merge gate"
    )
    assert selected["id"] == run["id"]


@pytest.mark.parametrize(
    "branch, exit_code", [("main", 17), ("", 0), ("bad branch", 0), ("main\nother", 0)]
)
def test_default_branch_lookup_failure_never_writes_checkout_output(
    tmp_path, branch, exit_code
):
    import os
    import subprocess

    document = yaml.safe_load((ROOT / ".github/workflows/auto-merge.yml").read_text())
    steps = document["jobs"]["auto-merge"]["steps"]
    script = next(step["run"] for step in steps if step.get("id") == "default")
    gh = tmp_path / "gh"
    gh.write_text('#!/bin/sh\nprintf "%s" "$STUB_BRANCH"\nexit "$STUB_EXIT"\n')
    gh.chmod(0o755)
    output = tmp_path / "output"
    env = dict(
        os.environ,
        PATH=f"{tmp_path}{os.pathsep}{os.environ['PATH']}",
        STUB_BRANCH=branch,
        STUB_EXIT=str(exit_code),
        GH_TOKEN="synthetic-token",
        REPO="owner/repo",
        GITHUB_OUTPUT=str(output),
    )
    result = subprocess.run(
        ["bash", "--noprofile", "--norc", "-e", "-o", "pipefail", "-c", script],
        env=env,
        capture_output=True,
        text=True,
        check=False,
    )
    assert result.returncode != 0
    assert not output.exists() or output.read_text() == ""


@pytest.mark.parametrize("branch", ["main", "release/next"])
def test_successful_default_lookup_selects_validated_checkout_ref(tmp_path, branch):
    import os
    import subprocess

    document = yaml.safe_load((ROOT / ".github/workflows/auto-merge.yml").read_text())
    steps = document["jobs"]["auto-merge"]["steps"]
    script = next(step["run"] for step in steps if step.get("id") == "default")
    checkout = next(
        step for step in steps if step.get("uses", "").startswith("actions/checkout@")
    )
    assert checkout["with"]["ref"] == "${{ steps.default.outputs.branch }}"
    gh = tmp_path / "gh"
    gh.write_text('#!/bin/sh\nprintf "%s" "$STUB_BRANCH"\n')
    gh.chmod(0o755)
    output = tmp_path / "output"
    env = dict(
        os.environ,
        PATH=f"{tmp_path}{os.pathsep}{os.environ['PATH']}",
        STUB_BRANCH=branch,
        GH_TOKEN="synthetic-token",
        REPO="owner/repo",
        GITHUB_OUTPUT=str(output),
    )
    subprocess.run(
        ["bash", "--noprofile", "--norc", "-e", "-o", "pipefail", "-c", script],
        env=env,
        capture_output=True,
        text=True,
        check=True,
    )
    assert output.read_text() == f"branch={branch}\n"


def test_required_native_job_names_match_existing_matrix():
    document = yaml.safe_load((ROOT / ".github/workflows/build.yml").read_text())
    names = []
    for key, job in document["jobs"].items():
        for image in job["strategy"]["matrix"]["os"]:
            assert (
                image == "macos-26"
            )  # Existing successful standard runner, not a paid larger runner.
            names.append(f"{job.get('name', key)} ({image})")
    assert REQUIRED["build.yml"] == names


def test_postmerge_is_explicit_test_only_dispatch_at_the_merge_sha():
    document = yaml.safe_load(
        (ROOT / ".github/workflows/post-merge-tests.yml").read_text()
    )
    triggers = document.get("on", document.get(True))
    assert set(triggers) == {"workflow_dispatch"}
    assert triggers["workflow_dispatch"]["inputs"]["merged_sha"]["required"] is True
    assert document["permissions"] == {"contents": "read"}
    native = document["jobs"]["native-tests"]
    assert native["runs-on"] == "macos-26"
    checkout = next(
        step
        for step in native["steps"]
        if step.get("uses", "").startswith("actions/checkout@")
    )
    assert checkout["with"] == {
        "ref": "${{ inputs.merged_sha }}",
        "persist-credentials": False,
    }
    commands = [step["run"] for step in native["steps"] if "run" in step]
    assert commands == [
        '[[ "$MERGED_SHA" =~ ^[0-9a-f]{40}$ ]]',
        "./.github/gh-actions-runner-xcode-select.sh",
        "brew install swiftly",
        "swiftly init --skip-install --assume-yes --verbose && swiftly install",
        "./build-debug.sh\n./run-tests.sh\n",
    ]
    regression = document["jobs"]["gate-tests"]
    assert regression["uses"] == "./.github/workflows/merge-checks.yml"
    assert regression["with"]["checkout_ref"] == "${{ inputs.merged_sha }}"


def test_gate_regressions_do_not_mask_swiftpm_tests_directory():
    assert not (ROOT / "tests").exists()
    assert not (ROOT / "Tests").exists()
    assert (ROOT / "Sources/AppBundleTests").is_dir()
