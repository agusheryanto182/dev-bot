#!/usr/bin/env bash
# Show what dev-bot is doing across my repos, using my own gh login. Read-only.
#
#   ./scripts/status.sh                     # every repo of the owners that has .github/dev-bot.sh
#   ./scripts/status.sh owner/repo ...      # only these repos
#
# Per repo: agent runs in progress, open PRs (CI state, autofix attempts,
# needs-human), issues waiting for the agent, and failed runs. Plus the laptop
# runner(s) of each org (needs the admin:org scope).
#
# Options:
#   --owner <name>   owner to scan, repeatable (default: agusheryanto182 and agusheryanto182-lab)
#   --since <hours>  how far back to look for failed runs (default: 24)
set -euo pipefail

owners=()
repos=()
since_hours=24
MARKER='<!-- ci-autofix -->'

die() { echo "error: $*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --owner) owners+=("${2:-}"); shift 2 ;;
    --since) since_hours="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
    -*) die "unknown option: $1" ;;
    *) repos+=("$1"); shift ;;
  esac
done
[ ${#owners[@]} -gt 0 ] || owners=(agusheryanto182 agusheryanto182-lab)

for cmd in gh jq; do
  command -v "$cmd" >/dev/null || die "missing dependency: $cmd"
done

if [ -t 1 ]; then
  bold=$'\e[1m' dim=$'\e[2m' red=$'\e[31m' green=$'\e[32m' yellow=$'\e[33m' reset=$'\e[0m'
else
  bold='' dim='' red='' green='' yellow='' reset=''
fi

# jq helper: "5m", "3h", "2d" since an ISO timestamp.
# shellcheck disable=SC2016 # jq code, not shell
JQ_AGO='def ago: (now - fromdate) as $s
  | if $s < 3600 then "\($s / 60 | floor)m"
    elif $s < 86400 then "\($s / 3600 | floor)h"
    else "\($s / 86400 | floor)d" end;'

# 1. Repos: given, or every non-archived repo of the owners with .github/dev-bot.sh.
if [ ${#repos[@]} -eq 0 ]; then
  # Checked 8 at a time; a personal account can have many repos.
  while IFS= read -r repo; do
    repos+=("$repo")
  done < <(
    for owner in "${owners[@]}"; do
      gh repo list "$owner" --no-archived --limit 200 --json nameWithOwner --jq '.[].nameWithOwner'
    done | xargs -P 8 -I{} sh -c 'gh api "repos/{}/contents/.github/dev-bot.sh" --silent 2>/dev/null && echo {}' \
      | sort
  )
fi
[ ${#repos[@]} -gt 0 ] || die "no repos with .github/dev-bot.sh found for: ${owners[*]}"

# 2. Laptop runners, per org.
echo "${bold}Runners${reset}"
for owner in "${owners[@]}"; do
  if ! runners=$(gh api "orgs/$owner/actions/runners" 2>/dev/null); then
    continue # not an org, or no admin:org scope
  fi
  jq -r '.runners[] | "\(.name) \(.status) \(.busy)"' <<<"$runners" | while read -r name status busy; do
    if [ "$status" != online ]; then
      state="${red}offline${reset}"
    elif [ "$busy" = true ]; then
      state="${yellow}busy${reset}"
    else
      state="${green}idle${reset}"
    fi
    echo "  $owner/$name  $state"
  done
done

# 3. Per repo.
since=$(( $(date +%s) - since_hours * 3600 ))
for repo in "${repos[@]}"; do
  private=$(gh api "repos/$repo" --jq .private)
  where=$([ "$private" = true ] && echo "private, laptop" || echo "public, ubuntu-latest")
  echo
  echo "${bold}$repo${reset} ${dim}($where)${reset}"

  runs=$(gh run list -R "$repo" -L 50 --json databaseId,workflowName,displayTitle,status,conclusion,createdAt,headBranch)

  # Agent and autofix runs in progress or queued.
  active=$(jq -r "$JQ_AGO"' .[] | select(.status != "completed")
    | select(.workflowName == "Claude Code" or .workflowName == "CI Autofix")
    | "\(.workflowName): \(.displayTitle) (\(.status), \(.createdAt | ago) ago)"' <<<"$runs")
  if [ -n "$active" ]; then
    while IFS= read -r line; do echo "  ${yellow}▶${reset} $line"; done <<<"$active"
  fi

  # Open PRs with their CI state and autofix attempts.
  prs=$(gh pr list -R "$repo" --state open \
    --json number,title,headRefName,labels,statusCheckRollup,createdAt)
  if [ "$(jq length <<<"$prs")" -eq 0 ]; then
    echo "  ${dim}no open PRs${reset}"
  fi
  jq -c '.[]' <<<"$prs" | while IFS= read -r pr; do
    num=$(jq -r .number <<<"$pr")
    ci=$(jq -r '[.statusCheckRollup[]? | select(.name == "ci / ci" or .name == "ci")]
      | if length == 0 then "none"
        elif any(.[]; .status != "COMPLETED") then "running"
        elif any(.[]; .conclusion != "SUCCESS") then "failing"
        else "green" end' <<<"$pr")
    case "$ci" in
      green) ci="${green}CI green${reset}" ;;
      failing) ci="${red}CI failing${reset}" ;;
      running) ci="${yellow}CI running${reset}" ;;
      *) ci="${dim}no CI${reset}" ;;
    esac
    extra=""
    if jq -e '.headRefName | startswith("claude/")' >/dev/null <<<"$pr"; then
      attempts=$(gh api "repos/$repo/issues/$num/comments" --paginate \
        --jq "[.[] | select(.body | contains(\"$MARKER\"))] | length" | awk '{s+=$1} END {print s+0}')
      [ "$attempts" -eq 0 ] || extra+="  autofix $attempts"
    fi
    if jq -e '.labels | any(.name == "needs-human")' >/dev/null <<<"$pr"; then
      extra+="  ${red}needs-human${reset}"
    fi
    jq -r "$JQ_AGO"' "  PR #\(.number) \(.title) \u001f\(.createdAt | ago)"' <<<"$pr" \
      | { IFS=$'\x1f' read -r head age; echo "$head${dim}${age} old${reset}  $ci$extra"; }
  done

  # Issues labelled claude that are still open (queued or being worked on).
  issues=$(gh issue list -R "$repo" --label claude --state open --json number,title \
    --jq '.[] | "#\(.number) \(.title)"')
  if [ -n "$issues" ]; then
    while IFS= read -r line; do echo "  ${dim}issue${reset} $line"; done <<<"$issues"
  fi

  # Failed runs in the window, newest first.
  failed=$(jq -r --argjson since "$since" "$JQ_AGO"' .[]
    | select(.conclusion == "failure" and (.createdAt | fromdate) >= $since)
    | "\(.workflowName): \(.displayTitle) [\(.headBranch)] (\(.createdAt | ago) ago)"' <<<"$runs")
  if [ -n "$failed" ]; then
    count=$(wc -l <<<"$failed")
    echo "  ${red}$count failed run(s) in the last ${since_hours}h${reset}, newest:"
    head -n 5 <<<"$failed" | while IFS= read -r line; do echo "    $line"; done
  fi
done
