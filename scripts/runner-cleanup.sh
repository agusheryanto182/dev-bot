#!/usr/bin/env bash
# Daily cleanup for the self-hosted runner, run as the runner user by a systemd
# timer (installed by install-runner.sh).
#
# The Docker daemon is shared with my own work, so this only removes what CI
# created: compose projects named ci-*, claude-* or autofix-* (see the
# workflows). It never prunes images, containers or volumes globally.
#
# Options:
#   --runner-dir <dir>  runner install dir (default: ~/actions-runner)
#   --stale-hours <n>   CI stacks older than this are removed (default: 6)
#   --work-days <n>     repo checkouts unused for this long are removed (default: 14)
#   --dry-run           print what would be removed
set -euo pipefail

runner_dir="$HOME/actions-runner"
stale_hours=6
work_days=14
dry_run=false

while [ $# -gt 0 ]; do
  case "$1" in
    --runner-dir) runner_dir="${2:-}"; shift 2 ;;
    --stale-hours) stale_hours="${2:-}"; shift 2 ;;
    --work-days) work_days="${2:-}"; shift 2 ;;
    --dry-run) dry_run=true; shift ;;
    -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
    *) echo "error: unknown option: $1" >&2; exit 1 ;;
  esac
done

log() { echo "==> $*"; }
run() { if [ "$dry_run" = true ]; then echo "would run: $*" >&2; else "$@"; fi; }

ci_project='^(ci|claude|autofix)-[0-9]+-[0-9]+$'
cutoff=$(( $(date +%s) - stale_hours * 3600 ))

# 1. CI compose stacks left behind by jobs that were killed before their
#    `docker compose down -v` step (timeout, laptop shut down mid-job).
#    Jobs time out after 30 minutes, so anything older than stale_hours is dead.
projects=$(docker ps -a --format '{{.Label "com.docker.compose.project"}}' | sort -u | grep -E "$ci_project" || true)
for project in $projects; do
  newest=0
  for id in $(docker ps -aq --filter "label=com.docker.compose.project=$project"); do
    created=$(date -d "$(docker inspect -f '{{.Created}}' "$id")" +%s)
    [ "$created" -gt "$newest" ] && newest=$created
  done
  if [ "$newest" -lt "$cutoff" ]; then
    log "removing stale CI stack $project"
    ids=$(docker ps -aq --filter "label=com.docker.compose.project=$project")
    # shellcheck disable=SC2086 # word splitting of the id list is intended
    run docker rm -f -v $ids >/dev/null
  fi
done

# Volumes and networks of CI projects with no containers left.
for volume in $(docker volume ls -q --filter label=com.docker.compose.project); do
  project=$(docker volume inspect -f '{{index .Labels "com.docker.compose.project"}}' "$volume")
  [[ "$project" =~ $ci_project ]] || continue
  [ -z "$(docker ps -aq --filter "volume=$volume")" ] || continue
  log "removing CI volume $volume"
  run docker volume rm "$volume" >/dev/null
done
for network in $(docker network ls -q --filter label=com.docker.compose.project); do
  project=$(docker network inspect -f '{{index .Labels "com.docker.compose.project"}}' "$network")
  [[ "$project" =~ $ci_project ]] || continue
  [ "$(docker network inspect -f '{{len .Containers}}' "$network")" = "0" ] || continue
  log "removing CI network $project"
  run docker network rm "$network" >/dev/null
done

# 2. Repo checkouts in _work that no job has used for work_days. The runner
#    re-clones them on the next job. Its own dirs (_tool, _actions, _temp, ...)
#    start with an underscore and are kept.
if [ -d "$runner_dir/_work" ]; then
  while IFS= read -r dir; do
    # A job touches files inside the checkout, not always the top dir itself.
    [ -z "$(find "$dir" -maxdepth 3 -mtime -"$work_days" -print -quit)" ] || continue
    log "removing unused checkout $dir"
    run rm -rf "$dir"
  done < <(find "$runner_dir/_work" -mindepth 1 -maxdepth 1 -type d ! -name '_*')
fi

# 3. Old runner diagnostic logs.
if [ -d "$runner_dir/_diag" ]; then
  find "$runner_dir/_diag" -type f -name '*.log' -mtime +"$work_days" -print \
    | while IFS= read -r f; do run rm -f "$f"; done
fi

log "cleanup done"
