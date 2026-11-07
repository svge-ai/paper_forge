# SVGE branch and dependency pin policy

This fork is `svge-ai/paper_forge`. Its parent is `Manuel1471/paper_forge`.
SVGE work stays on this fork. This policy does not open pull requests against
the parent, and the sync workflow never pushes there.

## Branches

### `main` — canonical upstream mirror

`main` tracks `Manuel1471/paper_forge` branch `main` and nothing else.

- Automation may fast-forward it when it is a strict ancestor of that upstream branch.
- Automation must not merge, reset, force-push, or delete it.
- If `main` contains any commit upstream does not, sync stops and the workflow fails. The extra commits stay.
- If upstream rewrites history so this `main` is no longer an ancestor, sync stops the same way. It does not discard the commits already on `main`.
- SVGE workflows and SVGE docs do not go on `main`.

### `svge-main` — contribution branch

`svge-main` is where SVGE commits land, including this policy and the sync workflow.

- It was created at `d18482e4ad03c0a30629fd3fa5dfb79ad3208405`, the `main` commit of both this fork and `Manuel1471/paper_forge` when the branch was added.
- If the branch already exists, nothing in this setup moves it, even when a fast-forward would be possible.
- The upstream sync workflow does not push to it. The script records its SHA and fails if that SHA changes during the run.
- Bringing newer upstream commits onto `svge-main` is a separate reviewed intake. It is not done by the sync workflow.

## Default branch

GitHub runs `schedule` only for workflow files on the default branch, and it only offers `workflow_dispatch` when the workflow file is on the default branch. Both events use the workflow definition from that branch.

This workflow is stored on `svge-main` so `main` stays pristine. The repository default branch therefore needs to be `svge-main` before the schedule or the manual button can see it.

At setup, this agent called `PATCH /repos/svge-ai/paper_forge` with `default_branch=svge-main`. GitHub returned HTTP 403 `Resource not accessible by integration` (`https://docs.github.com/rest/repos/repos#update-a-repository`). The default branch was still `main` at that time. This credential cannot change repository settings, and no protection was added or removed to get around that.

The founder later set the default branch to `svge-main`. Later corrections do not change that setting.

An administrator can switch the default branch after the setup pull request is merged:

- Repository Settings → General → Default branch → `svge-main`, or
- `PATCH /repos/svge-ai/paper_forge` with `{"default_branch":"svge-main"}`

That change is reversible: set the default branch back to `main`. Reverting does not delete `svge-main` and does not change branch protection. While the default branch is `main`, GitHub will not schedule this workflow, because the workflow file is not on `main`.

Do not copy the workflow onto `main` to avoid the setting. That would stop `main` from being an upstream-only branch.

Branch protection observed at setup, and not changed:

- `main` `protected: false`, repository rulesets empty, branch rules for `main` empty
- `svge-main` `protected: false`, branch rules empty

`GET /repos/svge-ai/paper_forge/branches/main/protection` returned HTTP 403 `Resource not accessible by integration`, so the classic protection document itself could not be read. The public branch object says `protected: false`.

## Sync workflow

| Item | Value |
| --- | --- |
| Workflow | `.github/workflows/svge-sync-upstream-main.yml` |
| Script | `.github/scripts/svge-sync-upstream-main.sh` |
| Schedule | `17 7 * * *` UTC daily |
| Manual | `workflow_dispatch`, with optional `dry_run` |
| Upstream | `https://github.com/Manuel1471/paper_forge.git` branch `main` only |
| Destination | `refs/heads/main` on `svge-ai/paper_forge` only |
| Push refspec | `HEAD:refs/heads/main` |
| Token | Built-in `GITHUB_TOKEN` with workflow permission `contents: write` |
| Actions called | None. The triggering commit is fetched with inline `git` |

The script checks all of the following before a push:

1. The workflow ref is `refs/heads/svge-main` in `svge-ai/paper_forge` when those Actions variables are present.
2. The fork parent is exactly `Manuel1471/paper_forge`.
3. That parent's default branch is `main`.
4. `svge-main` exists. Its SHA is recorded.
5. Fork `main` and upstream `main` are resolved with `git ls-remote`.
6. Equal SHAs are a success with no push.
7. Otherwise fork `main` must be an ancestor of upstream `main`. The update is `git merge --ff-only`.
8. The resulting commit must equal upstream `main`.
9. Dry run stops before the push.
10. The only push is `HEAD:refs/heads/main`. There is no `--force`, reset, or delete.
11. After the push, `main` must equal that upstream commit. A mismatch fails and is not repaired.
12. `svge-main` must still be the SHA recorded at the start.

Global and system Git config are ignored for these commands so a URL rewrite cannot retarget the fixed repositories. The push authenticates with the built-in token's HTTP header and does not read a PAT or an Actions secret.

`contents: write` is repository-wide. GitHub Actions does not offer a permission that can move only `refs/heads/main`. The fixed refspec is what keeps the push on `main`.

A push made with `GITHUB_TOKEN` does not start other workflows. The existing CI workflow also listens only for `push` and `pull_request` targeting `main`. This setup does not change that CI workflow. Moving the default branch to `svge-main` means pull requests against `svge-main` will not run `.github/workflows/ci.yml` until a later, separate change adds that branch. Synced commits on `main` are commits that already exist on the parent.

## Actions the organization allows

The founder stated the organization policy after enabling Actions: inline workflow steps are allowed, actions must be owned by `svge-ai`, and any action reference must be a full 40-character commit SHA. `GET /orgs/svge-ai/actions/permissions` and `GET /orgs/svge-ai/actions/permissions/selected-actions` both returned HTTP 403 `Resource not accessible by integration`, so this document records that stated policy. It does not change the organization setting.

The sync workflow has no `uses:` step. It fetches `https://github.com/svge-ai/paper_forge.git` at the run's `GITHUB_SHA` with the runner's `git`, ignores global and system Git config, and does not put a token on that fetch. The built-in `GITHUB_TOKEN` is passed only to the fast-forward step.

`svge-ai/checkout` is a fork of `actions/checkout`. The sync workflow does not use that fork. The previously merged workflow called `actions/checkout@11d5960a326750d5838078e36cf38b85af677262`, which is `actions/checkout` v4.4.0. That reference is a full SHA and is owned by the `actions` organization, so it does not meet the stated policy.

`.github/workflows/ci.yml` is upstream CI and is not changed. It still references `actions/checkout@v4`, `erlef/setup-beam@v1`, and `actions/cache@v4`.

## What stays inactive

The setup pull request was squash-merged and the founder set the default branch to `svge-main`. The founder also enabled Actions for the organization. No sync run has succeeded. `GET /repos/svge-ai/paper_forge/actions/permissions` and `GET /repos/svge-ai/paper_forge/actions/permissions/workflow` returned HTTP 403 `Resource not accessible by integration`, so the repository workflow-token cap is still unread. Creating a workflow dispatch returned HTTP 403 with `x-accepted-github-permissions: actions=write`. Enabling the organization setting does not grant this integration that permission, and dispatch was not retried.

If the organization or repository caps `GITHUB_TOKEN` at read, the fast-forward push fails and `main` stays where it is. Do not work around that with a personal access token unless a later decision explicitly allows one. Do not weaken branch protection to make the push succeed.

## Dependency pin

Consumers, including the later Bizmojo pin, use this fork and `svge-main`. They do not use canonical `main`, because `main` moves when upstream moves.

Pin shape:

- Git repository: `https://github.com/svge-ai/paper_forge.git`
- Branch: `svge-main`
- `mix.lock` records the full 40-character commit SHA of the chosen `svge-main` revision

A branch name alone is not a pin. The lock entry is the immutable SHA. If the lock records a branch label, that label is `svge-main`. This repository change does not edit Bizmojo, any consumer, or a `mix.lock` outside this policy.

## Checked at setup

| Check | Result |
| --- | --- |
| Parent | `Manuel1471/paper_forge` |
| Upstream `main` | `d18482e4ad03c0a30629fd3fa5dfb79ad3208405` |
| Fork `main` | `d18482e4ad03c0a30629fd3fa5dfb79ad3208405` |
| `svge-main` at creation | `d18482e4ad03c0a30629fd3fa5dfb79ad3208405` |
| Default branch | `main` (switch to `svge-main` denied, HTTP 403) |

Re-check without changing anything:

```bash
gh api repos/svge-ai/paper_forge --jq '{parent:.parent.full_name,default:.default_branch}'
gh api repos/svge-ai/paper_forge/git/ref/heads/main --jq .object.sha
gh api repos/svge-ai/paper_forge/git/ref/heads/svge-main --jq .object.sha
gh api repos/Manuel1471/paper_forge/git/ref/heads/main --jq .object.sha
```
