#!/usr/bin/env bash
# Local safety checks for the upstream main sync. Fixture pushes stay on
# local bare repositories. A live dry run may read the public fork and is
# prevented from pushing to GitHub by the git wrapper below.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
script="${root}/.github/scripts/svge-sync-upstream-main.sh"
workflow="${root}/.github/workflows/svge-sync-upstream-main.yml"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

[[ -f "$script" && -f "$workflow" ]] || fail "missing sync files"

if grep -nE -- '--force|force-with-lease|reset --hard|git reset|push --all|push --mirror|--delete|branch -D|branch -d|update-ref|filter-branch|rebase' "$script"; then
  fail "script contains a forbidden history-rewrite operation"
fi

if grep -n 'push' "$script" | grep -q 'svge-main'; then
  fail "a push line mentions svge-main"
fi

if ! grep -nE '^[[:space:]]*git .* merge --ff-only ' "$script" >/dev/null; then
  fail "expected git merge --ff-only"
fi
if grep -nE '^[[:space:]]*git .* merge ' "$script" | grep -v -- '--ff-only' | grep -q .; then
  fail "merge must be fast-forward only"
fi

grep -q 'HEAD:refs/heads/main' "$script" || fail "fixed push refspec missing"
grep -q 'Manuel1471/paper_forge' "$script" || fail "fixed upstream missing"
grep -q 'svge-ai/paper_forge' "$script" || fail "fixed fork missing"
grep -q 'GIT_CONFIG_NOSYSTEM=1' "$script" || fail "script must ignore system git config"
grep -q 'SYNC_TEST_FIXTURE is refused when GITHUB_ACTIONS=true' "$script" || fail "fixture guard missing"

if grep -nE 'workflow_dispatch:|schedule:' "$workflow" >/dev/null; then
  :
else
  fail "workflow must be scheduled and manual"
fi
grep -q 'contents: write' "$workflow" || fail "workflow must request contents write"
grep -q 'persist-credentials: false' "$workflow" || fail "checkout must not persist credentials"
grep -q 'actions/checkout@11d5960a326750d5838078e36cf38b85af677262' "$workflow" || fail "checkout pin drifted"
if grep -nE 'secrets\.|PERSONAL|PAT|pull-requests:|id-token:' "$workflow"; then
  fail "workflow requests a secret or an extra permission"
fi

guard_dir="$(mktemp -d)"
trap 'rm -rf "$guard_dir"' EXIT
cat >"${guard_dir}/git" <<'EOF'
#!/usr/bin/env bash
saw_push=0
for arg in "$@"; do
  if [[ "$arg" == "push" ]]; then
    saw_push=1
  fi
  if [[ "$saw_push" == "1" ]]; then
    case "$arg" in
      https://github.com/* | http://github.com/* | git@github.com:* | ssh://git@github.com/* | git+ssh://git@github.com/*)
        echo "TEST GUARD refused git push to GitHub" >&2
        exit 99
        ;;
    esac
  fi
done
exec /usr/bin/git "$@"
EOF
chmod +x "${guard_dir}/git"
export PATH="${guard_dir}:${PATH}"

expect_fail() {
  local label="$1"
  shift
  set +e
  "$@" >"${guard_dir}/out.txt" 2>"${guard_dir}/err.txt"
  local code=$?
  set -e
  if [[ "$code" -eq 0 ]]; then
    cat "${guard_dir}/out.txt" >&2 || true
    cat "${guard_dir}/err.txt" >&2 || true
    fail "${label} succeeded and should have failed"
  fi
  if [[ "$code" -eq 99 ]]; then
    cat "${guard_dir}/err.txt" >&2 || true
    fail "${label} attempted a push to GitHub"
  fi
}

echo "test: fixture mode refused in GitHub Actions"
expect_fail "fixture mode" env GITHUB_ACTIONS=true SYNC_TEST_FIXTURE=1 \
  SYNC_FIXTURE_UPSTREAM_URL=/tmp/does-not-matter SYNC_FIXTURE_FORK_URL=/tmp/does-not-matter \
  bash "$script"

echo "test: production mode requires a token"
expect_fail "missing token" env -u GITHUB_TOKEN -u GH_TOKEN -u SYNC_TEST_FIXTURE -u GITHUB_ACTIONS -u GITHUB_REF \
  bash "$script"

new_fixture() {
  local dir upstream fork work
  dir="$(mktemp -d "${guard_dir}/fixture.XXXXXX")"
  upstream="${dir}/upstream.git"
  fork="${dir}/fork.git"
  work="${dir}/work"
  git init --bare -b main "$upstream" >/dev/null
  git init --bare -b main "$fork" >/dev/null
  git -C "$fork" config receive.denyNonFastForwards true
  git -C "$fork" config receive.denyDeletes true
  git init -b main "$work" >/dev/null
  git -C "$work" config user.name "SVGE sync test"
  git -C "$work" config user.email "test@example.invalid"
  echo base >"${work}/file.txt"
  git -C "$work" add file.txt
  git -C "$work" commit -m base >/dev/null
  git -C "$work" remote add origin "$fork"
  git -C "$work" push origin main >/dev/null
  git -C "$work" push origin "main:svge-main" >/dev/null
  git -C "$work" remote add upstream "$upstream"
  git -C "$work" push upstream main >/dev/null
  printf '%s\n%s\n' "$upstream" "$fork"
}

sha_of() {
  git ls-remote "$1" "$2" | awk 'NR==1 { print $1 }'
}

echo "test: already in sync does not push"
mapfile -t repos < <(new_fixture)
env -u GITHUB_ACTIONS -u GITHUB_TOKEN -u GH_TOKEN \
  SYNC_TEST_FIXTURE=1 \
  SYNC_FIXTURE_UPSTREAM_URL="${repos[0]}" \
  SYNC_FIXTURE_FORK_URL="${repos[1]}" \
  bash "$script" >/dev/null
[[ "$(sha_of "${repos[1]}" refs/heads/main)" == "$(sha_of "${repos[0]}" refs/heads/main)" ]] || fail "noop drifted main"

echo "test: fast-forward updates main and leaves svge-main"
mapfile -t repos < <(new_fixture)
before_contrib="$(sha_of "${repos[1]}" refs/heads/svge-main)"
before_main="$(sha_of "${repos[1]}" refs/heads/main)"
wt="$(mktemp -d "${guard_dir}/wt.XXXXXX")"
git clone --no-local "${repos[0]}" "$wt" >/dev/null
git -C "$wt" config user.name "SVGE sync test"
git -C "$wt" config user.email "test@example.invalid"
echo next >>"${wt}/file.txt"
git -C "$wt" add file.txt
git -C "$wt" commit -m next >/dev/null
git -C "$wt" push origin main >/dev/null
env -u GITHUB_ACTIONS -u GITHUB_TOKEN -u GH_TOKEN \
  SYNC_TEST_FIXTURE=1 \
  SYNC_FIXTURE_UPSTREAM_URL="${repos[0]}" \
  SYNC_FIXTURE_FORK_URL="${repos[1]}" \
  bash "$script" >/dev/null
[[ "$(sha_of "${repos[1]}" refs/heads/main)" == "$(sha_of "${repos[0]}" refs/heads/main)" ]] || fail "fast-forward did not match upstream"
[[ "$(sha_of "${repos[1]}" refs/heads/main)" != "$before_main" ]] || fail "fast-forward did not move main"
[[ "$(sha_of "${repos[1]}" refs/heads/svge-main)" == "$before_contrib" ]] || fail "fast-forward moved svge-main"

echo "test: dry run does not fast-forward"
mapfile -t repos < <(new_fixture)
wt="$(mktemp -d "${guard_dir}/wt.XXXXXX")"
git clone --no-local "${repos[0]}" "$wt" >/dev/null
git -C "$wt" config user.name "SVGE sync test"
git -C "$wt" config user.email "test@example.invalid"
echo next >>"${wt}/file.txt"
git -C "$wt" add file.txt
git -C "$wt" commit -m next >/dev/null
git -C "$wt" push origin main >/dev/null
before_main="$(sha_of "${repos[1]}" refs/heads/main)"
before_contrib="$(sha_of "${repos[1]}" refs/heads/svge-main)"
env -u GITHUB_ACTIONS -u GITHUB_TOKEN -u GH_TOKEN \
  SYNC_TEST_FIXTURE=1 SYNC_DRY_RUN=1 \
  SYNC_FIXTURE_UPSTREAM_URL="${repos[0]}" \
  SYNC_FIXTURE_FORK_URL="${repos[1]}" \
  bash "$script" >/dev/null
[[ "$(sha_of "${repos[1]}" refs/heads/main)" == "$before_main" ]] || fail "dry run pushed main"
[[ "$(sha_of "${repos[1]}" refs/heads/svge-main)" == "$before_contrib" ]] || fail "dry run moved svge-main"

echo "test: divergence fails and discards nothing"
mapfile -t repos < <(new_fixture)
wt="$(mktemp -d "${guard_dir}/wt.XXXXXX")"
git clone --no-local "${repos[0]}" "$wt" >/dev/null
git -C "$wt" config user.name "SVGE sync test"
git -C "$wt" config user.email "test@example.invalid"
echo upstream >>"${wt}/file.txt"
git -C "$wt" add file.txt
git -C "$wt" commit -m upstream >/dev/null
git -C "$wt" push origin main >/dev/null
fork_wt="$(mktemp -d "${guard_dir}/forkwt.XXXXXX")"
git clone --no-local "${repos[1]}" "$fork_wt" >/dev/null
git -C "$fork_wt" config user.name "SVGE sync test"
git -C "$fork_wt" config user.email "test@example.invalid"
echo fork >>"${fork_wt}/file.txt"
git -C "$fork_wt" add file.txt
git -C "$fork_wt" commit -m fork-only >/dev/null
git -C "$fork_wt" push origin main >/dev/null
before_main="$(sha_of "${repos[1]}" refs/heads/main)"
before_contrib="$(sha_of "${repos[1]}" refs/heads/svge-main)"
before_upstream="$(sha_of "${repos[0]}" refs/heads/main)"
expect_fail "divergence" env -u GITHUB_ACTIONS -u GITHUB_TOKEN -u GH_TOKEN \
  SYNC_TEST_FIXTURE=1 \
  SYNC_FIXTURE_UPSTREAM_URL="${repos[0]}" \
  SYNC_FIXTURE_FORK_URL="${repos[1]}" \
  bash "$script"
grep -q 'diverged' "${guard_dir}/err.txt" || fail "divergence error was not explicit"
[[ "$(sha_of "${repos[1]}" refs/heads/main)" == "$before_main" ]] || fail "divergence changed fork main"
[[ "$(sha_of "${repos[1]}" refs/heads/svge-main)" == "$before_contrib" ]] || fail "divergence changed svge-main"
[[ "$(sha_of "${repos[0]}" refs/heads/main)" == "$before_upstream" ]] || fail "divergence changed upstream"

echo "test: missing svge-main fails before a push"
mapfile -t repos < <(new_fixture)
git -C "${repos[1]}" update-ref -d refs/heads/svge-main
before_main="$(sha_of "${repos[1]}" refs/heads/main)"
expect_fail "missing svge-main" env -u GITHUB_ACTIONS -u GITHUB_TOKEN -u GH_TOKEN \
  SYNC_TEST_FIXTURE=1 \
  SYNC_FIXTURE_UPSTREAM_URL="${repos[0]}" \
  SYNC_FIXTURE_FORK_URL="${repos[1]}" \
  bash "$script"
[[ "$(sha_of "${repos[1]}" refs/heads/main)" == "$before_main" ]] || fail "missing svge-main changed main"

echo "test: fork-only commits are divergence, not a rewind"
mapfile -t repos < <(new_fixture)
fork_wt="$(mktemp -d "${guard_dir}/ahead.XXXXXX")"
git clone --no-local "${repos[1]}" "$fork_wt" >/dev/null
git -C "$fork_wt" config user.name "SVGE sync test"
git -C "$fork_wt" config user.email "test@example.invalid"
echo ahead >>"${fork_wt}/file.txt"
git -C "$fork_wt" add file.txt
git -C "$fork_wt" commit -m ahead >/dev/null
git -C "$fork_wt" push origin main >/dev/null
before_main="$(sha_of "${repos[1]}" refs/heads/main)"
before_contrib="$(sha_of "${repos[1]}" refs/heads/svge-main)"
expect_fail "fork ahead" env -u GITHUB_ACTIONS -u GITHUB_TOKEN -u GH_TOKEN \
  SYNC_TEST_FIXTURE=1 \
  SYNC_FIXTURE_UPSTREAM_URL="${repos[0]}" \
  SYNC_FIXTURE_FORK_URL="${repos[1]}" \
  bash "$script"
[[ "$(sha_of "${repos[1]}" refs/heads/main)" == "$before_main" ]] || fail "ahead sync rewound main"
[[ "$(sha_of "${repos[1]}" refs/heads/svge-main)" == "$before_contrib" ]] || fail "ahead sync moved svge-main"

if [[ "${SYNC_LIVE_DRY_RUN:-}" == "1" ]]; then
  echo "test: live dry run against the public fork"
  token="$(gh auth token)"
  before_main="$(gh api repos/svge-ai/paper_forge/git/ref/heads/main --jq .object.sha)"
  before_contrib="$(gh api repos/svge-ai/paper_forge/git/ref/heads/svge-main --jq .object.sha)"
  before_upstream="$(gh api repos/Manuel1471/paper_forge/git/ref/heads/main --jq .object.sha)"
  env -u GITHUB_ACTIONS -u GITHUB_REF -u SYNC_TEST_FIXTURE \
    GITHUB_TOKEN="$token" SYNC_DRY_RUN=1 \
    bash "$script"
  after_main="$(gh api repos/svge-ai/paper_forge/git/ref/heads/main --jq .object.sha)"
  after_contrib="$(gh api repos/svge-ai/paper_forge/git/ref/heads/svge-main --jq .object.sha)"
  after_upstream="$(gh api repos/Manuel1471/paper_forge/git/ref/heads/main --jq .object.sha)"
  [[ "$after_main" == "$before_main" ]] || fail "live dry run changed fork main"
  [[ "$after_contrib" == "$before_contrib" ]] || fail "live dry run changed svge-main"
  [[ "$before_main" == "$before_upstream" && "$after_main" == "$after_upstream" ]] || fail "live SHAs were not an unchanged match"
fi

echo "all sync safety tests passed"
