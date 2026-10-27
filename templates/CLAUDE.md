# CLAUDE.md

<!-- Describe the project in one or two lines. -->

## Workflow

- Branch from `develop` as `claude/issue-<N>-<short-slug>`. PRs target `develop`, never `main`.
- One issue per PR. Keep changes small and focused on the issue.
- Commit messages follow Conventional Commits (`feat:`, `fix:`, `test:`, `chore:`).
- You can't edit `.github/`. If a change needs it, say so in the PR instead.

## Before every push

The project's services are already running and their env vars are set (see
`ci_env` and `setup` in `.github/dev-bot.sh`). Run `pnpm install`, then the
commands in the `check` function of `.github/dev-bot.sh`. Push only when all of
them pass.

## Code

<!-- Language, layout, conventions, how tests are written. -->

- Every new behaviour gets a test. Never delete or weaken a test to make it pass.
