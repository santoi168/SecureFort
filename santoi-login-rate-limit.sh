#!/usr/bin/env bash
# SecureFortGo — standalone nginx POST /login rate-limit reconciler.
# Only manages nginx configuration; never modifies Flask or CSRF files.
# Usage:
#   sudo bash santoi-login-rate-limit.sh --check   # read-only inspection
#   sudo bash santoi-login-rate-limit.sh           # check, apply only if needed
set -Eeuo pipefail

SITE="${SITE:-/etc/nginx/sites-enabled/default}"
RATE_CONF="${RATE_CONF:-/etc/nginx/conf.d/login-rate-limit.conf}"
NGINX_SERVICE="${NGINX_SERVICE:-santoi-nginx.service}"
BACKUP_DIR="${BACKUP_DIR:-/etc/nginx/santoi-backups}"
MODE="${1:-apply}"
[[ "$MODE" == apply || "$MODE" == --check ]] || { echo "Usage: sudo bash $0 [--check]" >&2; exit 2; }
[[ "$(id -u)" -eq 0 ]] || { echo 'ERROR: run with sudo' >&2; exit 1; }
command -v nginx >/dev/null && command -v python3 >/dev/null || { echo 'ERROR: nginx and python3 required' >&2; exit 1; }
[[ -f "$SITE" ]] || { echo "ERROR: site not found: $SITE" >&2; exit 1; }
SITE_REAL="$(readlink -f -- "$SITE")"
[[ -f "$SITE_REAL" ]] || { echo 'ERROR: invalid site symlink' >&2; exit 1; }
[[ ! -d "$RATE_CONF" ]] || { echo "ERROR: rate config is a directory: $RATE_CONF" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT
cat > "$TMP/login-rate-limit.conf" <<'NGINX'
# SecureFortGo — limit POST /login by client IP.
map "$request_method:$uri" $login_rate_key {
    default "";
    "POST:/login" $binary_remote_addr;
}

limit_req_zone $login_rate_key
    zone=login_per_ip:10m
    rate=5r/m;
NGINX

# Validate the current map/zone by their effective directives, not whitespace,
# comments or line breaks. Reject extra/competing directives rather than replacing them.
if [[ -e "$RATE_CONF" ]]; then
  [[ -f "$RATE_CONF" ]] || { echo "ERROR: not a regular file: $RATE_CONF" >&2; exit 1; }
  python3 - "$RATE_CONF" <<'PY'
import re, sys
s = open(sys.argv[1], encoding='utf-8').read()
s = re.sub(r'(?m)#.*$', '', s)
s = re.sub(r'\s+', ' ', s).strip()
expected_map = 'map "$request_method:$uri" $login_rate_key { default ""; "POST:/login" $binary_remote_addr; }'
expected_zone = 'limit_req_zone $login_rate_key zone=login_per_ip:10m rate=5r/m;'
if s != expected_map + ' ' + expected_zone:
    sys.exit('ERROR: existing rate-limit.conf differs from the managed policy; review manually. No files changed.')
PY
  CONF_ACTION=unchanged
else
  CONF_ACTION=create
fi

python3 - "$SITE_REAL" "$TMP/site.new" <<'PY'
import pathlib, re, sys
src, dst = map(pathlib.Path, sys.argv[1:])
s = src.read_text(encoding='utf-8')
# Avoid editing arbitrary nested nginx blocks; this site is expected to have a
# straightforward location / proxying to the local SecureFortGo Gunicorn port.
blocks = list(re.finditer(r'(?ms)^([ \t]*)location\s+/\s*\{[^\n]*\n(.*?)^\1\}', s))
targets = [b for b in blocks if re.search(r'(?m)^\s*proxy_pass\s+http://127\.0\.0\.1:8000\s*;', b.group(2))]
if len(targets) != 1:
    sys.exit(f'ERROR: expected one location / for 127.0.0.1:8000, found {len(targets)}; no files changed.')
b = targets[0]
required = [
    'limit_req zone=login_per_ip burst=4 nodelay;',
    'limit_req_status 429;',
    'limit_req_log_level warn;',
]
existing = re.findall(r'(?m)^\s*(limit_req(?:_status|_log_level)?\s+[^;]+;)', b.group(2))
norm = lambda x: re.sub(r'\s+', ' ', x.strip())
if existing:
    if sorted(map(norm, existing)) != sorted(map(norm, required)):
        sys.exit('ERROR: existing limit_req rules differ from policy; manual review required. No files changed.')
    result = s
else:
    indent = b.group(1) + '    '
    addition = ''.join(indent + line + '\n' for line in required) + '\n'
    result = s[:b.start(2)] + addition + s[b.start(2):]
dst.write_text(result, encoding='utf-8')
PY

if cmp -s "$SITE_REAL" "$TMP/site.new"; then SITE_ACTION=unchanged; else SITE_ACTION=update; fi
printf 'Preflight: nginx site = %s (%s)\n' "$SITE_REAL" "$SITE_ACTION"
printf 'Preflight: rate config = %s (%s)\n' "$RATE_CONF" "$CONF_ACTION"

if [[ "$SITE_ACTION" == unchanged && "$CONF_ACTION" == unchanged ]]; then
  echo 'ALREADY CONFIGURED: no file changes, no backup, no service reload.'
  exit 0
fi
if [[ "$MODE" == --check ]]; then
  echo 'CHECK ONLY: changes needed; no files, backups, or services modified.'
  exit 0
fi

# Verify current environment before editing.
nginx -t
[[ -d "$(dirname "$RATE_CONF")" ]] || { echo 'ERROR: nginx conf.d directory missing' >&2; exit 1; }
mkdir -p -- "$BACKUP_DIR"
chmod 700 -- "$BACKUP_DIR"
TS="$(date +%Y%m%d-%H%M%S)-$$"
SITE_BAK="$BACKUP_DIR/$(basename "$SITE_REAL").$TS.bak"
cp -a -- "$SITE_REAL" "$SITE_BAK"
CONF_BAK=''
if [[ -f "$RATE_CONF" ]]; then
  CONF_BAK="$BACKUP_DIR/$(basename "$RATE_CONF").$TS.bak"
  cp -a -- "$RATE_CONF" "$CONF_BAK"
fi
printf 'Backup: %s\n' "$SITE_BAK"
[[ -z "$CONF_BAK" ]] || printf 'Backup: %s\n' "$CONF_BAK"
SITE_CHANGED=0
CONF_CREATED=0
restore_files() {
  echo 'Restoring nginx files...' >&2
  (( SITE_CHANGED == 0 )) || cp -a -- "$SITE_BAK" "$SITE_REAL"
  (( CONF_CREATED == 0 )) || rm -f -- "$RATE_CONF"
  nginx -t || true
}

if [[ "$SITE_ACTION" == update ]]; then
  STAGED="$(mktemp "$(dirname "$SITE_REAL")/.santoi-login-rate.XXXXXX")"
  cp -a -- "$SITE_REAL" "$STAGED"
  cat "$TMP/site.new" > "$STAGED"
  mv -f -- "$STAGED" "$SITE_REAL"
  SITE_CHANGED=1
fi
if [[ "$CONF_ACTION" == create ]]; then
  install -m 644 "$TMP/login-rate-limit.conf" "$RATE_CONF"
  CONF_CREATED=1
fi

if ! nginx -t; then
  restore_files
  echo 'ERROR: nginx validation failed; reverted changes.' >&2
  exit 1
fi
if ! systemctl reload "$NGINX_SERVICE"; then
  restore_files
  systemctl reload "$NGINX_SERVICE" || true
  echo 'ERROR: nginx reload failed; reverted changes.' >&2
  exit 1
fi
if ! systemctl is-active --quiet "$NGINX_SERVICE"; then
  restore_files
  systemctl reload "$NGINX_SERVICE" || true
  echo 'ERROR: nginx service inactive; reverted changes.' >&2
  exit 1
fi
echo 'SUCCESS: nginx config changed, validated, and reloaded.'
echo 'Policy: POST /login, 5r/m per IP, burst=4 nodelay, HTTP 429.'
