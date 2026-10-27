#!/usr/bin/env bash
# Connect a repo to dev-bot. Safe to re-run. I run it myself, with my own gh login.
#
#   ./scripts/setup-repo.sh <owner/repo> --app-id <id> --private-key <file.pem> [--dry-run]
#
# The runner follows the repo's visibility, with no override:
#   private -> the laptop runner ["self-hosted","laptop"] (repo must be in an org with it)
#   public  -> "ubuntu-latest"
#
# Steps: check gh scopes and that both GitHub Apps are installed; create `develop`
# and make it the default branch; squash-only merges and delete branch on merge;
# labels `claude` and `needs-human`; secrets CLAUDE_CODE_OAUTH_TOKEN, BOT_APP_ID
# and BOT_PRIVATE_KEY (only those missing); branch protection requiring `ci / ci`
# (public repos only, GitHub Free has none for private ones); then a bootstrap
# PR to develop with the caller workflows, .github/dev-bot.sh and CLAUDE.md
# (the last two only if missing).
#
# Options:
#   --app-id <id>          agusheryanto182-bot App ID (needed if BOT_APP_ID is missing)
#   --private-key <file>   its private key .pem (needed if BOT_PRIVATE_KEY is missing)
#   --ref <ref>            dev-bot version the callers use (default: v1)
#   --trigger-user <user>  the only user who can start the agent (default: agusheryanto182)
#   --dry-run              show what would change, change nothing
set -euo pipefail

DEV_BOT=agusheryanto182/dev-bot
BOT_APP=agusheryanto182-bot
CLAUDE_APP=claude
RUNNER_LABEL=laptop
SECRETS=(CLAUDE_CODE_OAUTH_TOKEN BOT_APP_ID BOT_PRIVATE_KEY)

repo=""
app_id=""
private_key=""
ref=v1
trigger_user=agusheryanto182
dry_run=false

die() { echo "error: $*" >&2; exit 1; }
log() { echo "==> $*"; }
warn() { echo "warning: $*" >&2; }
run() { if [ "$dry_run" = true ]; then echo "would run: $*" >&2; else "$@"; fi; }
trap 'echo "error: command failed (exit $?) at line $LINENO" >&2' ERR

while [ $# -gt 0 ]; do
  case "$1" in
    --app-id) app_id="${2:-}"; shift 2 ;;
    --private-key) private_key="${2:-}"; shift 2 ;;
    --ref) ref="${2:-}"; shift 2 ;;
    --trigger-user) trigger_user="${2:-}"; shift 2 ;;
    --dry-run) dry_run=true; shift ;;
    -h|--help) sed -n '2,25p' "$0"; exit 0 ;;
    -*) die "unknown option: $1" ;;
    *) [ -z "$repo" ] || die "only one repo at a time"; repo="$1"; shift ;;
  esac
done

[[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || die "usage: $0 <owner/repo> [options] (see --help)"
owner=${repo%%/*}
script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
templates="$script_dir/../templates"

for cmd in gh git jq; do
  command -v "$cmd" >/dev/null || die "missing dependency: $cmd"
done

# 1. gh login and scopes.
scopes=$(gh auth status 2>&1 | sed -n "s/.*Token scopes: //p" | tr -d "'")
for scope in repo workflow; do
  grep -qw "$scope" <<<"$scopes" || die "gh token lacks the '$scope' scope: gh auth refresh -h github.com -s $scope"
done

# 2. Visibility picks the runner.
info=$(gh api "repos/$repo") || die "can't read $repo"
private=$(jq -r .private <<<"$info")
owner_type=$(jq -r .owner.type <<<"$info")
default_branch=$(jq -r .default_branch <<<"$info")

if [ "$private" = true ]; then
  [ "$owner_type" = Organization ] \
    || die "$repo is a private personal repo. The laptop runner is org-level, so move the repo to the org (or make it public)."
  grep -qw admin:org <<<"$scopes" || die "checking the org runner needs the 'admin:org' scope: gh auth refresh -h github.com -s admin:org"
  runners=$(gh api "orgs/$owner/actions/runners" --jq "[.runners[] | select(any(.labels[]; .name == \"$RUNNER_LABEL\"))] | length")
  [ "$runners" -gt 0 ] || die "org $owner has no runner with label '$RUNNER_LABEL'. Run install-runner.sh first."
  runner='["self-hosted","laptop"]'
else
  runner='"ubuntu-latest"'
fi
log "$repo is $([ "$private" = true ] && echo private || echo public): runner $runner"

# 3. Both GitHub Apps must be installed: Claude to run the agent, the bot for PRs and merges.
if [ "$owner_type" = Organization ]; then
  apps=$(gh api "orgs/$owner/installations" --jq '.installations[] | "\(.app_slug) \(.repository_selection) \(.id)"')
else
  apps=$(gh api user/installations --jq ".installations[] | select(.account.login == \"$owner\") | \"\(.app_slug) \(.repository_selection) \(.id)\"")
fi
for app in "$CLAUDE_APP" "$BOT_APP"; do
  line=$(awk -v a="$app" '$1 == a' <<<"$apps")
  [ -n "$line" ] || die "GitHub App '$app' is not installed on $owner. Install it: https://github.com/apps/$app"
  read -r _ selection id <<<"$line"
  if [ "$selection" = selected ]; then
    gh api "user/installations/$id/repositories" --paginate --jq '.repositories[].full_name' | grep -qx "$repo" \
      || die "GitHub App '$app' is installed on $owner but not for $repo. Add the repo in the app's settings."
  fi
done
log "GitHub Apps $CLAUDE_APP and $BOT_APP are installed"

# 4. Branches: main for releases, develop as the default branch.
branch_sha() { gh api "repos/$repo/branches/$1" --jq .commit.sha 2>/dev/null || true; }
main_sha=$(branch_sha main)
[ -n "$main_sha" ] || die "$repo has no 'main' branch (default branch is '$default_branch')"
if [ -z "$(branch_sha develop)" ]; then
  log "creating develop from main"
  run gh api -X POST "repos/$repo/git/refs" -f ref=refs/heads/develop -f sha="$main_sha" >/dev/null
fi

# 5. Repo settings.
log "settings: default branch develop, squash only, delete branch on merge"
run gh repo edit "$repo" --default-branch develop --enable-squash-merge \
  --enable-merge-commit=false --enable-rebase-merge=false --delete-branch-on-merge

# 6. Labels.
run gh label create claude -R "$repo" --color 7057ff --description "Let the Claude agent work on this" --force
run gh label create needs-human -R "$repo" --color B60205 --description "Automation gave up; needs a person" --force

# 7. Secrets, only the missing ones. Values never go through argv.
existing=$(gh secret list -R "$repo" --json name --jq '.[].name')
for secret in "${SECRETS[@]}"; do
  if grep -qx "$secret" <<<"$existing"; then
    log "secret $secret already set"
    continue
  fi
  case "$secret" in
    CLAUDE_CODE_OAUTH_TOKEN)
      log "secret $secret: paste the token from 'claude setup-token'"
      [ "$dry_run" = true ] || gh secret set "$secret" -R "$repo" ;;
    BOT_APP_ID)
      [ -n "$app_id" ] || die "secret BOT_APP_ID is missing: pass --app-id"
      log "setting secret $secret"
      [ "$dry_run" = true ] || gh secret set "$secret" -R "$repo" --body "$app_id" ;;
    BOT_PRIVATE_KEY)
      [ -n "$private_key" ] || die "secret BOT_PRIVATE_KEY is missing: pass --private-key <file.pem>"
      [ -r "$private_key" ] || die "can't read $private_key"
      log "setting secret $secret from $private_key"
      [ "$dry_run" = true ] || gh secret set "$secret" -R "$repo" < "$private_key" ;;
  esac
done

# 8. Branch protection: public repos only.
if [ "$private" = false ]; then
  for branch in develop main; do
    log "branch protection on $branch: require 'ci / ci'"
    run gh api -X PUT "repos/$repo/branches/$branch/protection" --input - >/dev/null <<'EOF'
{
  "required_status_checks": { "strict": false, "contexts": ["ci / ci"] },
  "enforce_admins": false,
  "required_pull_request_reviews": null,
  "restrictions": null
}
EOF
  done
else
  log "no branch protection: GitHub Free has none for private repos (merge-on-green waits for CI instead)"
fi

# 9. Bootstrap PR with the caller workflows.
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
gh repo clone "$repo" "$work/repo" -- -q --depth 1 --no-single-branch
cd "$work/repo"
branch=chore/dev-bot-setup
# In a dry run develop may not exist yet.
git checkout -q -B "$branch" origin/develop 2>/dev/null || git checkout -q -B "$branch" origin/main
mkdir -p .github/workflows
for f in "$templates"/workflows/*.yml; do
  sed -e "s#__DEV_BOT__#$DEV_BOT#" -e "s#__REF__#$ref#" \
      -e "s#__RUNNER__#$runner#" -e "s#__TRIGGER_USER__#$trigger_user#" \
      "$f" > ".github/workflows/$(basename "$f")"
done
[ -f .github/dev-bot.sh ] || cp "$templates/dev-bot.sh" .github/dev-bot.sh
[ -f CLAUDE.md ] || cp "$templates/CLAUDE.md" CLAUDE.md
if [ "$private" = true ]; then
  # Lets actionlint accept the custom runner label.
  printf 'self-hosted-runner:\n  labels:\n    - %s\n' "$RUNNER_LABEL" > .github/actionlint.yaml
fi

git add -A
if git diff --cached --quiet; then
  log "workflows already up to date, no PR needed"
  exit 0
fi
git diff --cached --stat
if [ "$dry_run" = true ]; then
  log "dry run: not pushing $branch"
  exit 0
fi
git commit -q -m "chore: set up dev-bot ($ref)"
git push -q --force origin "$branch"
pr=$(gh pr list -R "$repo" --head "$branch" --state open --json url --jq '.[0].url')
if [ -z "$pr" ]; then
  pr=$(gh pr create -R "$repo" --base develop --head "$branch" --title "chore: set up dev-bot ($ref)" \
    --body "Caller workflows for [dev-bot]($(printf 'https://github.com/%s' "$DEV_BOT"))@$ref, runner \`$runner\`. Fill in \`.github/dev-bot.sh\` and \`CLAUDE.md\` before merging. Merge this PR by hand.")
fi
log "bootstrap PR: $pr"
