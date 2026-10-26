# Shared helpers for the release steps. Sourced by every steps/*.sh (bash 3.2 safe).
set -euo pipefail

RELEASE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Optional local config (see .env.example). Exported so asc.mjs sees it too.
if [ -f "$RELEASE_HOME/.env" ]; then set -a; . "$RELEASE_HOME/.env"; set +a; fi
: "${APPLE_TEAM_ID:?set APPLE_TEAM_ID (your 10-character Apple Developer team ID)}"
TEAM_ID="$APPLE_TEAM_ID"
SIGNING_DIR="${SIGNING_DIR:-$HOME/.appstoreconnect/signing}"
CERT_ID="${ASC_CERT_ID:-$(cat "$SIGNING_DIR/cert-id.txt" 2>/dev/null || true)}"
[ -n "$CERT_ID" ] || { echo "set ASC_CERT_ID or write the distribution certificate ID to $SIGNING_DIR/cert-id.txt" >&2; exit 1; }
: "${WORK:?WORK (the run folder) must be set}"
mkdir -p "$WORK"
STATE="$WORK/state.env"

log() { printf '%s %s\n' "$(date '+%-I:%M:%S %p')" "$*"; }
die() { log "STOP: $*"; exit 1; }

asc() { node "$RELEASE_HOME/asc.mjs" "$@"; }

# json 'python expression over d' < body   e.g. asc GET /v1/apps | json "d['data'][0]['id']"
json() { python3 -c "import sys,json; d=json.load(sys.stdin); r=($1); print('' if r is None else r)"; }

# Persist a value for later steps (state.env is plain KEY='value' lines).
put() { python3 - "$STATE" "$1" "$2" <<'PY'
import sys, shlex
path, k, v = sys.argv[1:4]
try: lines = [l for l in open(path) if not l.startswith(k + '=')]
except FileNotFoundError: lines = []
lines.append(f"{k}={shlex.quote(v)}\n")
open(path, 'w').writelines(lines)
PY
}
load() { [ -f "$STATE" ] && . "$STATE" || true; }

notify() { osascript -e "display notification \"$2\" with title \"$1\"" >/dev/null 2>&1 || true; }

load
