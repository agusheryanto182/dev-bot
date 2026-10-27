# dev-bot: plan

Plug-and-play automation for my repos: issue → Claude agent → PR → CI → autofix → auto-merge → release PR.

One **public** `dev-bot` repo holds the reusable workflows and scripts. The runner is picked by the visibility of the repo that uses it:

| Repo using dev-bot | Runner |
|---|---|
| **Private** | self-hosted runner on my laptop |
| **Public** | GitHub-hosted (`ubuntu-latest`) |

**Focus first: self-hosted runner + private repos** (Phases 1–4). Public repos come after (Phase 5).

Status: draft. Open decisions are listed at the end.

## Goals

- Private repos run their jobs on my laptop, so they don't use GitHub Actions minutes.
- Public repos never run jobs on my laptop.
- Adding a new repo takes one script run, with no manual runner registration.
- The agent can't touch my own user's files (SSH keys, `.env` files, work projects).
- `dev-bot` contains no credentials or sensitive data.

## Non-goals (for now)

- Running when the laptop is off. Jobs queue and are picked up when it comes back online. GitHub fails jobs that wait about 24 hours.
- Full VM isolation (see [Security](#security)).
- Multiple runners or parallel jobs.

## Key facts that shape the design

| Fact | Consequence |
|---|---|
| Personal accounts only support **per-repo** runners | One runner process per repo, which is not plug-and-play. Use a free **organization** to get one runner for every private repo in it. |
| Self-hosted runner minutes are free, including for private repos | No Actions minutes used for private repos. Claude usage still counts against my subscription. |
| Reusable workflows in a **public** repo can be called by any repo (private or public, any owner) | One public `dev-bot` serves everything. A private `dev-bot` couldn't be called by public repos or repos outside the org. |
| A called workflow runs in the **caller's** context | Jobs, logs and secrets belong to the calling (private) repo. `dev-bot` only provides the definitions. |
| Actions taken with `GITHUB_TOKEN` don't trigger other workflows, close issues or delete branches | Use the bot app token (`agusheryanto182-bot`) for PRs and auto-merge. |
| Org-level secrets for private repos on the Free plan: **to be checked** | If not available, `setup-repo.sh` sets secrets per repo. |
| GitHub Free has **no branch protection, rulesets or auto-merge for private repos** (checked: API returns 403) | `merge-on-green.yml` merges a `claude/**` PR with the bot app token once CI passes on its head commit (`--match-head-commit`). Nothing technically blocks direct pushes to `develop`/`main`; only I have access. |

## Architecture

```
GitHub                                                  Laptop (Debian 12)
┌───────────────────────────────────────┐               ┌──────────────────────────────────┐
│ agusheryanto182/dev-bot (PUBLIC)      │               │ user: ghrunner (no sudo)         │
│   reusable workflows + scripts        │               │  actions-runner (systemd)        │
│   own CI: ubuntu-latest only          │               │   labels: self-hosted,laptop     │
│                                       │               │   └─ jobs from private repos     │
│ org agusheryanto182-lab (private repos)        │  long-poll    │      only (docker compose, pnpm, │
│   repo A ─┐  uses dev-bot@v1          │   (HTTPS)     │      claude-code-action)         │
│   repo B ─┼─ runs-on: self-hosted ────┼──────────────▶│                                  │
│   repo C ─┘                           │               │ user: suga (my files, not        │
│                                       │               │       visible to ghrunner)       │
│ public repos (e.g. test-automation)   │               └──────────────────────────────────┘
│   uses dev-bot@v1                     │
│   runs-on: ubuntu-latest (GitHub)     │
└───────────────────────────────────────┘
```

The runner connects **outbound** to GitHub. There are no open ports on the laptop.

## Phase 1: prepare the laptop

Done by me with `sudo`. Claude writes the script `scripts/install-runner.sh`; I read it before running it.

1. Create a system user `ghrunner` with a home directory and **no sudo**.
2. Add `ghrunner` to the `docker` group.
   - Trade-off: Docker access is effectively root on the host. Acceptable because the runner only serves my own private repos.
3. Install the toolchain the jobs need, available to `ghrunner`: `git`, `docker compose` v2, `curl`, `jq`, `gh`. Node and pnpm are installed per job by `actions/setup-node` and `pnpm/action-setup`, which cache them in the runner tool cache. Enable the Docker service at boot (it was disabled on this laptop).
4. Download the latest Linux x64 Actions runner into `/home/ghrunner/actions-runner` and verify its SHA-256 checksum.
5. Register it at **org level** with labels `self-hosted,linux,laptop`, using a one-time registration token from `gh api -X POST orgs/agusheryanto182-lab/actions/runners/registration-token`. The token expires after 1 hour and is never written to disk.
6. Install and start it as a systemd service running as `ghrunner` (`./svc.sh install ghrunner && ./svc.sh start`).
7. In org Settings → Actions → Runner groups → Default: **"Allow public repositories" off**.

**Done when:** the runner shows as **Idle** under org Settings → Actions → Runners, and it comes back online after a reboot.

## Phase 2: private sandbox repo

1. Create a private repo `agusheryanto182-lab/dev-bot-sandbox` with a tiny Node project and a `docker-compose.yml` (Postgres only).
2. Add a CI workflow with `runs-on: [self-hosted, laptop]` that runs `docker compose up -d --wait`, then the tests, then `docker compose down -v`.
3. Push and confirm the job runs on the laptop.
4. Then add the Claude, autofix and auto-PR workflows (based on the ones already working in `test-automation`, switched to the laptop runner) and test the full loop with a small issue.

**Done when:** label `claude` on an issue leads to a PR that is auto-merged by `agusheryanto182-bot`, all on the laptop runner, and the linked issue closes.

## Phase 3: make it safe and tidy

| Concern | Measure |
|---|---|
| Port clashes with my own `docker compose` while I work | Jobs set `COMPOSE_PROJECT_NAME=ci-${{ github.run_id }}` and use non-default host ports (for example Postgres on `55432`), passed to tests via env vars. |
| Leftover containers or volumes | Every job runs `docker compose down -v --remove-orphans` in an `if: always()` step. |
| Disk filling up | A daily systemd timer (`dev-bot-runner-cleanup.timer`, installed by `install-runner.sh`) runs `scripts/runner-cleanup.sh` as `ghrunner`. It removes CI compose stacks (`ci-*`, `claude-*`, `autofix-*`) older than 6 hours, their orphaned volumes and networks, repo checkouts in `_work` unused for 14 days, and old `_diag` logs. **It never prunes Docker globally**, because the daemon is shared with my own work. Images are not pruned; I do that by hand if needed. |
| Who can trigger jobs on the laptop | Workflows keep the actor check (repo owner, `agusheryanto182-bot` or `claude[bot]` only). Org setting: "Require approval for all outside collaborators". |
| A public repo using the laptop runner | Runner group "Allow public repositories" off, and `setup-repo.sh` never writes `self-hosted` for a public repo. |
| Laptop load while I work | One runner means one job at a time. Agent jobs keep `timeout-minutes: 30`. |
| Secrets on disk | None. Secrets come from GitHub per job. `ghrunner` can't read `/home/suga`, so I check `chmod 700 /home/suga`. |

**Done when:** a job running while my own compose stack is up doesn't clash, and nothing is left behind after it finishes.

## Phase 4: build dev-bot (public)

1. Create `agusheryanto182/dev-bot` as a **public** repo, with **secret scanning and push protection** on.
2. Reusable workflows in `.github/workflows/`: `ci.yml`, `claude.yml`, `ci-autofix.yml`, `auto-pr.yml`, `merge-on-green.yml`, `release-pr.yml`. Caller templates in `templates/workflows/`.
3. Runner as an input, using `runs-on: ${{ fromJSON(inputs.runner) }}`:
   - private repos: `runner: '["self-hosted","laptop"]'`
   - public repos: `runner: '"ubuntu-latest"'` (default)
4. Other inputs: `trigger-user` (default `agusheryanto182`), `model` (default `claude-sonnet-5-5`), `max-turns`, `timeout-minutes`, `max-attempts`, `base-branch`, `release-branch`, `allowed-tools`.
5. Project specifics live in the caller's **`.github/dev-bot.sh`** (sourced by bash): `node_version`, `ci_env`, `setup`, `check`, `teardown`. One file instead of the same inputs repeated in three callers. The workflows provide `CI_PORT` and `COMPOSE_PROJECT_NAME` per run. pnpm comes from `packageManager` in `package.json`.
6. **Merge on green for every repo**, public and private. One code path instead of auto-merge for public and `merge-on-green` for private. Public repos still get branch protection, so the merge also needs `ci / ci`.
7. `scripts/setup-repo.sh <owner/repo> --app-id <id> --private-key <pem> [--dry-run]`. It's idempotent and I run it myself:
   - checks `gh` scopes (`repo`, `workflow`, plus `admin:org` for private org repos) and that both apps are installed: `agusheryanto182-bot` and the Claude GitHub App
   - **reads the repo's visibility and picks the runner**: private → laptop, public → `ubuntu-latest`. There's no flag to override it. A private personal repo is refused, since the laptop runner is org-level.
   - creates `develop` from `main` and makes it the default branch
   - turns on delete-branch-on-merge and squash-only merges
   - creates the labels `claude` and `needs-human`
   - sets the missing secrets `CLAUDE_CODE_OAUTH_TOKEN` (prompted), `BOT_APP_ID`, `BOT_PRIVATE_KEY` (from the .pem, via stdin)
   - public repos: branch protection on `develop` and `main` requiring `ci / ci`. Private repos: none (GitHub Free).
   - opens a bootstrap PR `chore/dev-bot-setup` → `develop` with the caller workflows, plus `.github/dev-bot.sh` and `CLAUDE.md` templates when missing. I merge it by hand.
8. `self-check.yml` for `dev-bot` itself: `actionlint` and `shellcheck`, on **`ubuntu-latest` only**.
9. Versioning: `v1.0.0`, plus a moving `v1` tag. Caller repos use `@v1`.
10. Switch `dev-bot-sandbox` to the reusable workflows.

**Done when:** running `setup-repo.sh` on a fresh private repo, then labelling an issue, completes the full loop on the laptop without manual steps.

## Phase 5 (later): public repos

1. Run `setup-repo.sh` on `agusheryanto182/test-automation`. It picks `ubuntu-latest`.
2. Replace its current workflows with the dev-bot callers, then test the loop with issue #4.

**Done when:** `test-automation` runs the same loop on GitHub-hosted runners, with no job on the laptop.

## Security

- **dev-bot is public, so it must never contain credentials.** Secrets live in GitHub Secrets of each calling repo, and workflows only reference `${{ secrets.X }}`. Never commit `.pem`, `.env` or example files with real tokens. Secret scanning and push protection are the safety net.
- **What's visible in dev-bot:** workflow logic, prompts, the `CLAUDE.md` template, runner labels, org and bot names. None of it lets anyone trigger jobs.
- **Changes to dev-bot run on my laptop** (through private repos), so I review every PR to `dev-bot` and only move the `v1` tag after review.
- **Isolation on the laptop:** a separate user plus the docker group. This protects my files from casual access but **is not a sandbox**: a malicious job could get root through Docker. That's acceptable because only my private repos use the runner, and only I or my bots can trigger them.
- **Upgrade path if needed:** run the runner inside a VM (for example KVM or libvirt) or use ephemeral runners (`--ephemeral`, re-registered per job).
- **Never:** a public repo on the self-hosted runner, `pull_request_target` with checkout of PR code, `show_full_output` or printing env in workflows, or `dev-bot`'s own CI on the laptop.

## Risks

| Risk | Mitigation |
|---|---|
| Laptop asleep or offline for over 24 hours, so queued jobs fail | Re-run them when the laptop is back. |
| Runner auto-update breaks the service | The runner updates itself by default. If it breaks, re-run `install-runner.sh`. |
| Claude quota runs out from autofix loops | `max-attempts: 2`, `needs-human` label, Sonnet only, owner-only triggers. |
| A bad change in dev-bot breaks every repo | Callers pin `@v1`. Breaking changes go to `v2`. |
| A secret gets committed to dev-bot | Push protection blocks known token formats. If one leaks anyway, rotate it immediately. |
| Org-level secrets not available to private repos on the Free plan | Fall back to per-repo secrets set by `setup-repo.sh`. |

## Decisions

1. **Organization:** `agusheryanto182-lab` (Free plan, I'm admin). Private repos that use the laptop runner live here.
2. **Bot app:** `agusheryanto182-bot` is set to "Only on this account", which blocks installing it on the org. Change it to **"Any account"** (app settings → Advanced → Make public). This only lets others install *my* app on *their* repos, which gives them nothing; tokens still need my private key.

## Open decisions

1. Install the bot app on **all repositories** of the org, or select them one by one? Recommended: all repositories, so new repos work without an extra step.

## Progress

- **Phase 1: done (2026-10-27)**, except the reboot check. Runner `bookworm-laptop` is online at org level with labels `self-hosted,Linux,X64,laptop`. The service and Docker are enabled at boot, the Default runner group has public repositories off, and `/home/suga` and `/home/ghrunner` are mode 700.
  - Install command: `gh api -X POST orgs/agusheryanto182-lab/actions/runners/registration-token --jq .token | sudo ./scripts/install-runner.sh --org agusheryanto182-lab`
- **Phase 2: done (2026-10-27).** `agusheryanto182-lab/dev-bot-sandbox` (private): issue #1 labelled `claude` → agent pushed `claude/issue-1-*` → `agusheryanto182-bot` opened PR #2 → CI green → `merge-on-green` merged it as the bot → issue #1 closed, branch deleted, CI green on `develop`. Every job ran on `bookworm-laptop`, with no containers or volumes left behind.
  - Gotcha: the **Claude GitHub App** (`github.com/apps/claude`) must also be installed on the org, not only `agusheryanto182-bot`. Without it the action fails with "401 Claude Code is not installed on this repository". `setup-repo.sh` must check both apps.

- **Phase 3: done (2026-10-27)**, once the timer is installed. Per-run compose project names, per-run ports (`40000 + run_id % 10000`) and `down -v` are in the sandbox workflows. Tested: sandbox CI passed while my own stack ran on port 55432, and that stack was untouched. `runner-cleanup.sh` tested against a fake stale `ci-999-1` stack and a personal `mystack`: only the CI stack and the old checkout were removed.

- **Phase 4: done (2026-10-27).** `agusheryanto182/dev-bot` is public with secret scanning and push protection, `self-check` green, tagged `v1.0.0` and `v1`. `setup-repo.sh` migrated `dev-bot-sandbox` (bootstrap PR #3, merged by hand). Then issue #4 labelled `claude` → PR #5 opened and merged by `agusheryanto182-bot` → issue closed, branch deleted, CI green on `develop`. All 5 jobs that ran used `bookworm-laptop` via `dev-bot@v1`; nothing left behind.
  - Gotchas: `workflow_run` callers always use the workflow file from the default branch (`develop`). A bootstrap PR's CI fails until `.github/dev-bot.sh` is filled in, which is expected.
  - Not yet tested: `setup-repo.sh` on a brand-new repo (no `develop`, no secrets), and the autofix path through `dev-bot@v1`.

- **Phase 5: done (2026-10-27).** `setup-repo.sh` migrated `agusheryanto182/test-automation` (public → `ubuntu-latest`, bootstrap PR #16; `docker-compose.yml` host ports now overridable via env, defaults unchanged). Issue #17 labelled `claude` → PR #20 opened and merged by `agusheryanto182-bot` → issue closed. Every job ran on GitHub-hosted runners, none on the laptop.
  - Issue #5 failed first: the agent needed 45 turns (limit 25) and its push got a 403 for `claude[bot]`. The Claude app on my personal account was then set to all repositories and the push worked. **Decision: keep `max-turns: 25` and split big issues** (#5 → #17, #18, #19) instead of raising the limit.
  - Fixed in `67f2d43`: the push and pull_request CI runs finish together, so two `merge-on-green` runs raced and one failed with "Merge already in progress". Now serialized per branch, and an already-merged PR counts as success.
  - `setup-repo.sh` can't check GitHub App installs on a personal account (gh's OAuth token gets a 403 on `user/installations`), so it only warns there.

- **Autofix tested (2026-10-27)** in `dev-bot-sandbox` through `dev-bot@v1`: a hand-pushed commit on `claude/issue-6-autofix-test` had a real bug (`count(*)` comes back from node-postgres as a string). CI failed → `ci-autofix` found the root cause, fixed `src/notes.ts` with `Number(...)` without touching the test, posted the report on PR #7 (attempt 1/2) → CI green → merged by the bot → issue #6 closed. All on the laptop.
  - Bug found: the agent got an **empty CI log**, because `gh run view --log-failed` returns nothing for jobs from a reusable workflow. It reproduced the failure itself. Fixed in the next commit by fetching each failed job's log through the API.
  - `merge-on-green` also stops cleanly while the other CI run's required check is still pending (public repos with branch protection), in `c1c3502` (`v1.0.2`).

- **needs-human tested (2026-10-27)** in `dev-bot-sandbox` (issue #8, PR #9), with `dev-bot@v1.0.3`: the branch made `check()` in `.github/dev-bot.sh` require a missing secret. Both autofix attempts read the (now non-empty) CI log, named the cause, changed no code and pushed nothing. On the 3rd failure the PR got `needs-human` plus a "stopping automation" comment. After CI was fixed by hand and went green, `merge-on-green` left the labelled PR open.

## Next step

1. Reboot once and check that the runner comes back **online**.
2. Not yet tested: `setup-repo.sh` on a brand-new repo.
