#!/usr/bin/env bash
# Fast-forward svge-ai/paper_forge refs/heads/main to Manuel1471/paper_forge
# refs/heads/main. This script never updates refs/heads/svge-main, never
# force-pushes, and treats divergence as a hard failure.
#
# GitHub's merge-upstream API is intentionally not used: on divergence it can
# create a merge commit. A fast-forward-only update stops instead.
set -euo pipefail

UPSTREAM_URL="https://github.com/Manuel1471/paper_forge.git"
UPSTREAM_SLUG="Manuel1471/paper_forge"
UPSTREAM_BRANCH="main"
FORK_URL="https://github.com/svge-ai/paper_forge.git"
FORK_SLUG="svge-ai/paper_forge"
DEST_BRANCH="main"
CONTRIB_BRANCH="svge-main"
DEST_REFSPEC="refs/heads/main"
PUSH_REFSPEC="HEAD:refs/heads/main"

export GIT_TERMINAL_PROMPT=0
export GIT_MERGE_AUTOEDIT=no
export GH_PROMPT_DISABLED=1

tmp_root="$(mktemp -d)"
trap 'rm -rf "$tmp_root"' EXIT

# Ignore global and system Git config so URL rewrites cannot retarget the
# fixed upstream or fork, and so ambient credentials are not used.
export GIT_CONFIG_GLOBAL="${tmp_root}/empty-gitconfig"
export GIT_CONFIG_NOSYSTEM=1
: >"$GIT_CONFIG_GLOBAL"

die() {
  echo "::error::$*" >&2
  exit 1
}

if [[ "${GITHUB_ACTIONS:-}" == "true" && "${SYNC_TEST_FIXTURE:-}" == "1" ]]; then
  die "SYNC_TEST_FIXTURE is refused when GITHUB_ACTIONS=true"
fi

if [[ "$DEST_BRANCH" != "main" || "$DEST_REFSPEC" != "refs/heads/main" || "$PUSH_REFSPEC" != "HEAD:refs/heads/main" ]]; then
  die "Refusing to update any ref other than refs/heads/main"
fi

if [[ "$CONTRIB_BRANCH" == "$DEST_BRANCH" || "$PUSH_REFSPEC" == *"$CONTRIB_BRANCH"* ]]; then
  die "Contribution branch must not be the sync destination"
fi

if [[ "${SYNC_TEST_FIXTURE:-}" == "1" ]]; then
  [[ -n "${SYNC_FIXTURE_UPSTREAM_URL:-}" && -n "${SYNC_FIXTURE_FORK_URL:-}" ]] || die "Fixture URLs are missing"
  case "$SYNC_FIXTURE_UPSTREAM_URL" in
    https://* | http://* | git@* | ssh://* | git+ssh://*)
      die "Fixture upstream URL must be a local path"
      ;;
  esac
  case "$SYNC_FIXTURE_FORK_URL" in
    https://* | http://* | git@* | ssh://* | git+ssh://*)
      die "Fixture fork URL must be a local path"
      ;;
  esac
  UPSTREAM_URL="$SYNC_FIXTURE_UPSTREAM_URL"
  FORK_URL="$SYNC_FIXTURE_FORK_URL"
else
  [[ "$FORK_URL" == "https://github.com/${FORK_SLUG}.git" ]] || die "Fork URL is not the fixed repository"
  [[ "$UPSTREAM_URL" == "https://github.com/${UPSTREAM_SLUG}.git" ]] || die "Upstream URL is not the fixed repository"
  if [[ -n "${GITHUB_REPOSITORY:-}" && "$GITHUB_REPOSITORY" != "$FORK_SLUG" ]]; then
    die "This sync only runs in ${FORK_SLUG} (saw ${GITHUB_REPOSITORY})"
  fi
  if [[ -n "${GITHUB_REF:-}" && "$GITHUB_REF" != "refs/heads/${CONTRIB_BRANCH}" ]]; then
    die "Refusing to run from ${GITHUB_REF}. Run this workflow from refs/heads/${CONTRIB_BRANCH} only"
  fi
  token="${GITHUB_TOKEN:-${GH_TOKEN:-}}"
  [[ -n "$token" ]] || die "GITHUB_TOKEN is required; this workflow does not use a PAT or a stored secret"
  export GH_TOKEN="$token"
  export GITHUB_TOKEN="$token"
  parent="$(gh api "repos/${FORK_SLUG}" --jq '.parent.full_name // empty')"
  [[ "$parent" == "$UPSTREAM_SLUG" ]] || die "Parent is '${parent:-<unset>}', expected ${UPSTREAM_SLUG}. Not syncing."
  upstream_default="$(gh api "repos/${UPSTREAM_SLUG}" --jq '.default_branch')"
  [[ "$upstream_default" == "$UPSTREAM_BRANCH" ]] || die "Upstream default branch is '${upstream_default}', expected ${UPSTREAM_BRANCH}. Not syncing."
fi

dry=0
if [[ "${SYNC_DRY_RUN:-0}" == "1" ]]; then
  dry=1
fi

ls_sha() {
  git ls-remote "$1" "$2" | awk 'NR==1 { print $1 }'
}

contrib_before="$(ls_sha "$FORK_URL" "refs/heads/${CONTRIB_BRANCH}")"
[[ -n "$contrib_before" ]] || die "${CONTRIB_BRANCH} is missing. Refusing to sync main."
fork_sha="$(ls_sha "$FORK_URL" "refs/heads/${DEST_BRANCH}")"
upstream_sha="$(ls_sha "$UPSTREAM_URL" "refs/heads/${UPSTREAM_BRANCH}")"
[[ -n "$fork_sha" && -n "$upstream_sha" ]] || die "Could not resolve main on the fork and upstream"

echo "fork ${DEST_BRANCH}: ${fork_sha}"
echo "upstream ${UPSTREAM_BRANCH}: ${upstream_sha}"
echo "${CONTRIB_BRANCH}: ${contrib_before}"

assert_contrib_unchanged() {
  local now
  now="$(ls_sha "$FORK_URL" "refs/heads/${CONTRIB_BRANCH}")"
  [[ "$now" == "$contrib_before" ]] || die "${CONTRIB_BRANCH} changed during sync (${contrib_before} -> ${now:-<missing>}). This job does not update it and will not repair it."
}

if [[ "$fork_sha" == "$upstream_sha" ]]; then
  echo "refs/heads/${DEST_BRANCH} already matches upstream. No push."
  assert_contrib_unchanged
  exit 0
fi

git clone --no-tags --no-local "$FORK_URL" "${tmp_root}/repo"
git -C "${tmp_root}/repo" remote add upstream "$UPSTREAM_URL"
git -C "${tmp_root}/repo" fetch --no-tags upstream "$UPSTREAM_BRANCH"
git -C "${tmp_root}/repo" fetch --no-tags origin "$DEST_BRANCH"

local_sha="$(git -C "${tmp_root}/repo" rev-parse "origin/${DEST_BRANCH}")"
fetched_upstream="$(git -C "${tmp_root}/repo" rev-parse "upstream/${UPSTREAM_BRANCH}")"
[[ "$local_sha" == "$fork_sha" ]] || die "origin/main moved during fetch (${fork_sha} -> ${local_sha}). Not syncing."
[[ "$fetched_upstream" == "$upstream_sha" ]] || die "upstream/main moved during fetch. Not syncing."

if ! git -C "${tmp_root}/repo" merge-base --is-ancestor "$local_sha" "$fetched_upstream"; then
  die "refs/heads/main diverged from ${UPSTREAM_SLUG} ${UPSTREAM_BRANCH} (fork=${local_sha} upstream=${fetched_upstream}). Refusing to merge, reset, or force-push. ${CONTRIB_BRANCH} was not modified."
fi

git -C "${tmp_root}/repo" checkout --detach "$local_sha"
git -C "${tmp_root}/repo" merge --ff-only "$fetched_upstream"
new_sha="$(git -C "${tmp_root}/repo" rev-parse HEAD)"
[[ "$new_sha" == "$fetched_upstream" ]] || die "Fast-forward result ${new_sha} does not equal upstream ${fetched_upstream}"

echo "push_refspec=${PUSH_REFSPEC}"
assert_contrib_unchanged

if [[ "$dry" == "1" ]]; then
  echo "Dry run: would fast-forward refs/heads/main from ${local_sha} to ${new_sha}. No push."
  assert_contrib_unchanged
  exit 0
fi

if [[ "${SYNC_TEST_FIXTURE:-}" == "1" ]]; then
  git -C "${tmp_root}/repo" push "$FORK_URL" "$PUSH_REFSPEC"
else
  git -C "${tmp_root}/repo" \
    -c "http.extraheader=AUTHORIZATION: bearer ${GITHUB_TOKEN}" \
    push "$FORK_URL" "$PUSH_REFSPEC"
fi

remote_main="$(ls_sha "$FORK_URL" "refs/heads/${DEST_BRANCH}")"
[[ "$remote_main" == "$new_sha" ]] || die "refs/heads/main is ${remote_main:-<missing>} after push, expected ${new_sha}. Not attempting a repair."
assert_contrib_unchanged
echo "Fast-forwarded refs/heads/main to ${new_sha}"
