# dev-bot

Plug-and-play automation for my repos, built on [claude-code-action](https://github.com/anthropics/claude-code-action):

issue labelled `claude` → Claude agent opens a branch → bot opens a PR → CI → autofix on failure (max 2 attempts) → merge on green → daily release PR `develop` → `main` (merged by hand).

This repo holds reusable workflows and scripts only. It contains no credentials: every secret lives in the calling repo.

## Runners

The runner follows the visibility of the calling repo, and `setup-repo.sh` has no override:

| Calling repo | Runner |
|---|---|
| Private (in org `agusheryanto182-lab`) | my laptop: `["self-hosted","laptop"]` |
| Public | GitHub-hosted: `"ubuntu-latest"` |

Public repos never run on the laptop. On top of that, the org's runner group has "Allow public repositories" off.

## Workflows

| Reusable workflow | Caller trigger | What it does |
|---|---|---|
| `ci.yml` | push, pull_request | `pnpm install`, then `check` from `.github/dev-bot.sh` |
| `claude.yml` | issue labelled `claude`, `@claude` comments | Runs the agent (Sonnet), only for `trigger-user` |
| `auto-pr.yml` | push to `claude/**` | Opens a PR to `develop` as the bot app |
| `ci-autofix.yml` | CI failed on `claude/**` | Agent finds the root cause, comments, pushes a fix; `needs-human` after 2 attempts |
| `merge-on-green.yml` | CI passed on `claude/**` | Squash-merges the PR as the bot app, if CI passed on its head commit |
| `release-pr.yml` | daily cron | Opens `develop` → `main` PR |

Callers pin `@v1`. Breaking changes go to `v2`.

## Connect a repo

Needs: `gh` logged in with `repo`, `workflow` (and `admin:org` for org repos); the
[Claude](https://github.com/apps/claude) and `agusheryanto182-bot` GitHub Apps installed on the owner; a `main` branch.

```
./scripts/setup-repo.sh <owner/repo> --app-id <id> --private-key <bot.pem> [--dry-run]
```

It creates `develop` as the default branch, sets squash-only merges, labels, missing secrets, branch protection (public repos only), and opens a bootstrap PR with the caller workflows, `.github/dev-bot.sh` and `CLAUDE.md`. Fill those two in, then merge the PR by hand.

## Configure a repo

`.github/dev-bot.sh` is sourced (bash) by the workflows after checkout. All of it is optional:

```bash
node_version=24

ci_env() {            # env vars for every step, KEY=VALUE per line
  echo "DATABASE_URL=postgres://app:app@localhost:$CI_PORT/app"
}
setup()    { docker compose up -d --wait; }
check()    { pnpm lint && pnpm typecheck && pnpm test; }   # default: pnpm test
teardown() { docker compose down -v --remove-orphans; }    # always runs
```

`CI_PORT` (40000–49999) and `COMPOSE_PROJECT_NAME` are unique per run, so jobs don't clash with stacks already running on the laptop. Map your compose ports to them.

## Status

```
./scripts/status.sh                  # every repo with .github/dev-bot.sh
./scripts/status.sh owner/repo ...   # just these, faster
```

Read-only, with your own `gh` login: laptop runner state, agent runs in progress, open PRs (CI, autofix attempts, `needs-human`), issues waiting for the agent, and failed runs in the last 24 hours (`--since <hours>`). Nothing leaves the machine.

## Laptop runner

- `sudo ./scripts/install-runner.sh --org <org>` with a registration token on stdin (see the script header): dedicated `ghrunner` user without sudo, org-level runner, systemd service, daily cleanup timer.
- `scripts/runner-cleanup.sh` removes only what CI created (`ci-*`, `claude-*`, `autofix-*` compose stacks, old checkouts and logs). It never prunes Docker globally.

See [PLAN.md](PLAN.md) for the design, decisions and security notes.
