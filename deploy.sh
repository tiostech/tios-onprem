#!/usr/bin/env bash
#
# deploy.sh - copy this repo to the KVM host and install the tiosvm scripts there.
#
#   ./deploy.sh [--host vm-machine.tioscapital.com] [--user tiostech]
#
# 1. rsyncs the repo (without .git) to ~/tios-onprem on the host.
# 2. Installs tiosvm, tiosvm-agent, tiosvm-metadata and tiosvm-rebake to /usr/local/bin,
#    only the ones that changed.
# 3. Restarts tiosvm-agent / tiosvm-metadata if their script changed. Running VMs keep running;
#    a launch the agent already took is in its spool, so a restart doesn't lose it.
#
# It does not re-run setup_kvm_host.sh (network, ZFS, services). For that, see README.md "Re-running".
# Run from your laptop; needs key-based SSH and passwordless sudo on the host.

set -Eeuo pipefail

HOST="vm-machine.tioscapital.com"
USER_NAME="tiostech"
SCRIPTS="tiosvm tiosvm-agent tiosvm-metadata tiosvm-rebake"

usage() { sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }
die()   { echo "ERROR: $*" >&2; exit 1; }
log()   { echo "$(date +%H:%M:%S) $*"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --host) HOST="$2"; shift 2 ;;
    --user) USER_NAME="$2"; shift 2 ;;
    -h|--help) usage ;;
    *) echo "Unknown option: $1"; usage ;;
  esac
done

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
TARGET="$USER_NAME@$HOST"

for f in $SCRIPTS; do
  case "$(head -1 "$REPO_DIR/$f")" in
    *python*) python3 -c "import ast,sys; ast.parse(open(sys.argv[1]).read())" "$REPO_DIR/$f" ;;
    *)        bash -n "$REPO_DIR/$f" ;;
  esac || die "$f has a syntax error; not deploying."
done

# Deploying uncommitted changes is allowed, but say so
if [ -n "$(git -C "$REPO_DIR" status --porcelain)" ]; then
  log "Note: deploying uncommitted changes:"
  git -C "$REPO_DIR" status --short
fi
log "Deploying $(git -C "$REPO_DIR" rev-parse --short HEAD) to $TARGET"

rsync -az --exclude .git "$REPO_DIR/" "$TARGET:tios-onprem/"

ssh "$TARGET" "SCRIPTS='$SCRIPTS' bash -s" <<'EOF'
set -Eeuo pipefail
cd ~/tios-onprem
changed=""
for f in $SCRIPTS; do
  if ! sudo cmp -s "$f" "/usr/local/bin/$f"; then
    sudo install -m 755 "$f" "/usr/local/bin/$f"
    echo "  installed $f"
    changed="$changed $f"
  fi
done
[ -n "$changed" ] || echo "  all scripts already up to date"

for svc in tiosvm-metadata tiosvm-agent; do
  case " $changed " in
    *" $svc "*)
      if systemctl is-enabled --quiet "$svc"; then
        sudo systemctl restart "$svc"
        echo "  restarted $svc: $(systemctl is-active "$svc")"
      fi ;;
  esac
done
EOF

log "Done. Check: curl -s https://ec2manager-stage-internal.tioscapital.com/onprem/status"
