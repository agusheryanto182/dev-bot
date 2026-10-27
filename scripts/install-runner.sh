#!/usr/bin/env bash
# Install a GitHub Actions self-hosted runner for an organization, running as a
# dedicated user under systemd. Safe to re-run.
#
# The registration token is read from stdin so it never lands in argv or on disk:
#
#   gh api -X POST orgs/<org>/actions/runners/registration-token --jq .token \
#     | sudo ./scripts/install-runner.sh --org <org>
#
# Once registered, re-run without a token to update the service and cleanup timer:
#
#   sudo ./scripts/install-runner.sh --org <org>
#
# Options:
#   --org <name>       organization to register with (required)
#   --name <name>      runner name (default: <hostname>-laptop)
#   --labels <list>    extra labels, comma separated (default: laptop)
#   --user <name>      system user that runs the jobs (default: ghrunner)
#   --version <x.y.z>  runner version (default: latest release)
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
org=""
name="$(hostname -s)-laptop"
labels="laptop"
run_user="ghrunner"
version=""

die() { echo "error: $*" >&2; exit 1; }
log() { echo "==> $*"; }
trap 'echo "error: command failed (exit $?) at line $LINENO" >&2' ERR

while [ $# -gt 0 ]; do
  case "$1" in
    --org) org="${2:-}"; shift 2 ;;
    --name) name="${2:-}"; shift 2 ;;
    --labels) labels="${2:-}"; shift 2 ;;
    --user) run_user="${2:-}"; shift 2 ;;
    --version) version="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,19p' "$0"; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

[ -n "$org" ] || die "--org is required"
[ "$(id -u)" -eq 0 ] || die "run with sudo"
[ "$(uname -m)" = "x86_64" ] || die "only x86_64 is supported"

for cmd in git curl jq tar sha256sum docker gh systemctl runuser; do
  command -v "$cmd" >/dev/null || die "missing dependency: $cmd"
done
docker compose version >/dev/null 2>&1 || die "missing dependency: docker compose v2"
getent group docker >/dev/null || die "the docker group does not exist"

# Jobs need the Docker daemon, including after a reboot.
if ! systemctl is-active --quiet docker; then
  log "starting the docker service"
  systemctl enable --now docker >/dev/null
fi
systemctl is-enabled --quiet docker || systemctl enable docker >/dev/null
docker info >/dev/null 2>&1 || die "the Docker daemon is not reachable"

runner_dir="/home/$run_user/actions-runner"
configured=false
[ -f "$runner_dir/.runner" ] && configured=true

token=""
if [ "$configured" = false ]; then
  [ -t 0 ] && die "pipe the registration token on stdin (see the header of this script)"
  read -r token || true
  [ -n "$token" ] || die "empty registration token on stdin"
fi

# 1. Dedicated user: no sudo, in the docker group.
if id "$run_user" >/dev/null 2>&1; then
  log "user $run_user already exists"
else
  log "creating user $run_user"
  useradd --system --create-home --home-dir "/home/$run_user" --shell /bin/bash "$run_user"
fi
chmod 700 "/home/$run_user"
if id -nG "$run_user" | tr ' ' '\n' | grep -qx docker; then
  log "$run_user is already in the docker group"
else
  log "adding $run_user to the docker group (note: docker access is effectively root)"
  usermod -aG docker "$run_user"
fi
if id -nG "$run_user" | tr ' ' '\n' | grep -qxE 'sudo|wheel|admin'; then
  die "$run_user must not be in a sudo group"
fi

# Other users' home directories must not be readable by the runner user.
for home in /home/*; do
  [ "$home" = "/home/$run_user" ] && continue
  [ -d "$home" ] || continue
  perms=$(stat -c '%a' "$home")
  case "$perms" in
    *00) ;;
    *) echo "warning: $home has mode $perms, so $run_user may read it. Consider: chmod 700 $home" >&2 ;;
  esac
done

# 2. Download and verify the runner.
if [ "$configured" = true ]; then
  log "runner already configured in $runner_dir, skipping download and registration"
else
  release_url="https://api.github.com/repos/actions/runner/releases/latest"
  [ -n "$version" ] && release_url="https://api.github.com/repos/actions/runner/releases/tags/v$version"
  release=$(curl -fsSL "$release_url")
  version=$(echo "$release" | jq -r '.tag_name' | sed 's/^v//')
  if [ -z "$version" ] || [ "$version" = "null" ]; then
    die "could not resolve runner version"
  fi
  sha=$(echo "$release" | jq -r '.body' \
    | grep -o '<!-- BEGIN SHA linux-x64 -->[0-9a-f]\{64\}<!-- END SHA linux-x64 -->' \
    | sed -E 's/<!--[^>]*-->//g')
  [ -n "$sha" ] || die "could not find the linux-x64 checksum in release v$version"

  tarball="actions-runner-linux-x64-$version.tar.gz"
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT
  log "downloading runner v$version"
  curl -fsSL -o "$tmp/$tarball" "https://github.com/actions/runner/releases/download/v$version/$tarball"
  echo "$sha  $tmp/$tarball" | sha256sum -c --quiet - || die "checksum mismatch for $tarball"
  log "checksum ok"

  install -d -m 700 "$runner_dir"
  tar -xzf "$tmp/$tarball" -C "$runner_dir"
  chown -R "$run_user:$run_user" "$runner_dir"

  # The upstream helper exits non-zero on unrelated apt problems (expired repo
  # keys, missing fallback packages), so check the libraries ourselves after it.
  log "installing runner system dependencies"
  "$runner_dir/bin/installdependencies.sh" >/dev/null 2>&1 \
    || echo "warning: installdependencies.sh failed, checking libraries directly" >&2
  libs=$(ldconfig -p)
  for lib in libicuuc.so libssl.so.3 liblttng-ust.so libgssapi_krb5.so.2 libz.so.1; do
    grep -qF "$lib" <<<"$libs" || die "missing runner library: $lib"
  done

  # 3. Register with the org. The token goes through the environment, not argv.
  log "registering runner '$name' with org $org (labels: self-hosted,Linux,X64,$labels)"
  (
    export ACTIONS_RUNNER_INPUT_TOKEN="$token"
    cd "$runner_dir"
    runuser -u "$run_user" -- ./config.sh --unattended \
      --url "https://github.com/$org" \
      --name "$name" \
      --labels "$labels" \
      --runnergroup Default \
      --work _work \
      --replace
  )
  token=""
fi

# 4. systemd service.
cd "$runner_dir"
if [ -f "$runner_dir/.service" ] && [ -f "/etc/systemd/system/$(cat "$runner_dir/.service")" ]; then
  log "service already installed: $(cat "$runner_dir/.service")"
else
  log "installing systemd service"
  ./svc.sh install "$run_user" >/dev/null
fi
service=$(cat "$runner_dir/.service")
systemctl enable --now "$service" >/dev/null
sleep 3
systemctl is-active --quiet "$service" || die "service $service is not running; check: journalctl -u $service"

# 5. Daily cleanup of what CI leaves behind, as the runner user. The script is
#    root-owned so jobs can't change what the timer runs.
install -D -m 755 -o root -g root "$script_dir/runner-cleanup.sh" /usr/local/lib/dev-bot/runner-cleanup.sh
cat > /etc/systemd/system/dev-bot-runner-cleanup.service <<EOF
[Unit]
Description=Clean up what GitHub Actions jobs left behind
After=docker.service

[Service]
Type=oneshot
User=$run_user
ExecStart=/usr/local/lib/dev-bot/runner-cleanup.sh --runner-dir $runner_dir
EOF
cat > /etc/systemd/system/dev-bot-runner-cleanup.timer <<'EOF'
[Unit]
Description=Daily cleanup for the GitHub Actions runner

[Timer]
OnCalendar=daily
Persistent=true
RandomizedDelaySec=1h

[Install]
WantedBy=timers.target
EOF
systemctl daemon-reload
systemctl enable --now dev-bot-runner-cleanup.timer >/dev/null
log "cleanup timer enabled: dev-bot-runner-cleanup.timer"

log "done: $service is running"
echo "Check it in https://github.com/organizations/$org/settings/actions/runners"
