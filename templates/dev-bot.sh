# dev-bot config for this repo. dev-bot's workflows source this file (bash)
# after checkout. Everything is optional; delete what you don't need.
#
# Available when it's sourced:
#   CI_PORT               a free-ish host port for this run (40000-49999).
#                         Use CI_PORT, CI_PORT+1, ... if you need several.
#   COMPOSE_PROJECT_NAME  unique per run, so `docker compose` never clashes
#                         with stacks already running on the runner.

# Node.js version for actions/setup-node.
# shellcheck disable=SC2034 # read by the workflows
node_version=24

# Env vars for every step, one KEY=VALUE per line.
ci_env() {
  : # echo "PG_PORT=$CI_PORT"
  : # echo "DATABASE_URL=postgres://app:app@localhost:$CI_PORT/app"
}

# Start services before install and tests.
setup() {
  : # docker compose up -d --wait
}

# Checks CI runs after `pnpm install --frozen-lockfile`. Default: pnpm test.
check() {
  pnpm test
}

# Always runs at the end, also after failures.
teardown() {
  : # docker compose down -v --remove-orphans
}
