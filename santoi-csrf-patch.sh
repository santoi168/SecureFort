#!/usr/bin/env bash
# santoi-csrf-patch.sh
# Idempotent patcher for santoi-rp4-issaquah:
#   1. /etc/nginx/sites-available/default  : security headers, hide upstream CORS/security
#                                            headers, Origin-based CSRF block (403)
#   2. /etc/nginx/conf.d/csrf-origin.conf   : map used by the Origin check
#   3. /etc/santoi/web/SecureFortGo.py      : double-submit-cookie CSRF token for /login
# Then: nginx -t, reload santoi-nginx, restart santoi-go, verify.
# Usage: sudo bash santoi-csrf-patch.sh
# Rollback: every changed file is backed up as <file>.bak.<timestamp>.

set -euo pipefail

NGINX_DEFAULT="${NGINX_DEFAULT:-/etc/nginx/sites-available/default}"
CSRF_CONF="${CSRF_CONF:-/etc/nginx/conf.d/csrf-origin.conf}"
GO_PY="${GO_PY:-/etc/santoi/web/SecureFortGo.py}"
NO_SERVICES="${NO_SERVICES:-0}"   # 1 = only patch files (used for testing)
ALLOWED_ORIGINS_RE='192\.168\.3\.1|127\.0\.0\.1'

TS="$(date +%s)"
CHANGED_NGINX=0
CHANGED_GO=0
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

say() { printf '\n== %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "run as root: sudo bash $0"
[ -f "$NGINX_DEFAULT" ] || die "missing $NGINX_DEFAULT"
[ -f "$GO_PY" ] || die "missing $GO_PY"

# ---------------------------------------------------------------------------
# 1. New SecureFortGo.py
# ---------------------------------------------------------------------------
cat > "$TMP/SecureFortGo.new.py" <<'PYEOF'
import re
import secrets
import subprocess
import threading
import logging
from urllib.parse import unquote_plus

from flask import Flask, Response, request, redirect
import requests

# --- CSRF (double-submit cookie) settings ---
CSRF_COOKIE = "csrf_token"
CSRF_FIELD = "csrf_token"
CSRF_HEADER = "X-CSRFToken"
CSRF_PROTECTED_PATHS = {"login"}  # paths validated on write methods (no leading slash)
CSRF_TOKEN_RE = re.compile(r"[A-Za-z0-9_-]{20,128}")
FORM_POST_RE = re.compile(rb"""<form\b[^>]*\bmethod\s*=\s*["']?post["']?[^>]*>""", re.IGNORECASE)
CSRF_WRITE_METHODS = ("POST", "PUT", "PATCH", "DELETE")


def _csrf_valid_token(value):
    return bool(value) and CSRF_TOKEN_RE.fullmatch(value) is not None


def _csrf_ok(cookie_token, submitted):
    if not _csrf_valid_token(cookie_token) or not _csrf_valid_token(submitted):
        return False
    return secrets.compare_digest(cookie_token, submitted)


def _split_csrf_field(body):
    """Return (token found in body or None, body with the csrf pair removed)."""
    token = None
    kept = []
    for pair in body.split(b"&"):
        name, _, value = pair.partition(b"=")
        if unquote_plus(name.decode("latin-1")) == CSRF_FIELD:
            if token is None:
                token = unquote_plus(value.decode("latin-1"))
        else:
            kept.append(pair)
    return token, b"&".join(kept)


class SecureFortGunicornApp:
    def __init__(self, executable_path, host="127.0.0.1", port=5000, timeout=90):
        self.executable_path = executable_path
        self.host = host
        self.port = port
        self.timeout = timeout  # Timeout in seconds
        self.proc = None  # To hold the subprocess

    def start_executable(self):
        # Launch the PyInstaller executable
        self.proc = subprocess.Popen([self.executable_path], stdout=subprocess.PIPE, stderr=subprocess.PIPE)

    def stop_executable(self):
        if self.proc:
            self.proc.terminate()

    def create_proxy_app(self):
        # Create a Flask app to act as a reverse proxy
        proxy_app = Flask(__name__)

        # Enable logging
        proxy_app.logger.setLevel(logging.DEBUG)

        @proxy_app.route('/', defaults={'path': ''})
        @proxy_app.route('/<path:path>', methods=["GET", "POST", "PUT", "DELETE", "PATCH"])
        def proxy(path):
            # Log incoming request details for debugging
            # (request headers/body are deliberately not logged: they contain passwords and cookies)
            proxy_app.logger.debug(f"Received {request.method} request for path: {path}")

            # Forward the request to the executable's internal server
            # target_url = f"http://{self.host}:{self.port}/{path}"
            target_url = request.args.get('url')
            if target_url == "http://www.neverssl.com":
                second_app_url = "http://127.0.0.1:5000/proxy"
                proxy_app.logger.debug(f"Using external target URL: {target_url}")
                try:
                    session = requests.Session()
                    response = session.get(second_app_url, params={'url': target_url}, allow_redirects=False, timeout=self.timeout)
                    # Check if the response is a redirect
                    proxy_app.logger.debug(f"response.status_code received from internal proxy: {response.status_code}")
                    proxy_app.logger.debug(f"response headers are {response.headers}")
                    if 300 <= response.status_code < 400:
                        # Modify the redirect URL if necessary
                        location = response.headers.get('Location', '')
                        if location:
                            proxy_app.logger.debug(f"Forwarding redirect to client: {location}")
                            proxy_app.logger.debug(f"response.status_code received: {response.status_code}")
                            try:
                                # Stream the response manually to handle chunking issues
                                with session.get(location, timeout=self.timeout):
                                    return redirect(location, code=response.status_code)
                            except requests.exceptions.RequestException as e:
                                proxy_app.logger.error(f"Error forwarding request to redirected URL: {e}")
                                return f"Error forwarding request to redirected URL: {e}", 500
                    # Return the response to the client
                    return Response(response.content, response.status_code, response.headers.items())
                except requests.exceptions.RequestException as e:
                    proxy_app.logger.error(f"Error forwarding request to second app: {e}")
                    return f"Error forwarding request to second app: {e}", 500
            else:
                # Construct the target URL based on internal server
                target_url = f"http://{self.host}:{self.port}/{path}"
                proxy_app.logger.debug(f"Using internal target URL: {target_url}")

                protected = path.strip("/").lower() in CSRF_PROTECTED_PATHS
                body = request.get_data()
                fwd_headers = {k: v for k, v in request.headers
                               if k.lower() not in ("content-length", "accept-encoding")}
                # Ask upstream for an uncompressed body so HTML can be edited
                fwd_headers["Accept-Encoding"] = "identity"

                if protected and request.method in CSRF_WRITE_METHODS:
                    submitted = request.headers.get(CSRF_HEADER)
                    ctype = (request.content_type or "").split(";")[0].strip().lower()
                    if ctype == "application/x-www-form-urlencoded":
                        from_body, body = _split_csrf_field(body)
                        submitted = from_body or submitted
                    if not _csrf_ok(request.cookies.get(CSRF_COOKIE), submitted):
                        proxy_app.logger.warning(
                            f"CSRF check failed: {request.method} /{path} from {request.remote_addr}")
                        return Response("CSRF validation failed. Reload the page and try again.\n",
                                        status=400, mimetype="text/plain")

                try:
                    # Forward the request to the target URL with timeout
                    response = requests.request(
                        method=request.method,  # Forward the method (GET, POST, etc.)
                        url=target_url,  # The URL of the internal executable server
                        headers=fwd_headers,  # Forward headers
                        data=body,  # Forward the body (e.g., form data)
                        cookies=request.cookies,  # Forward cookies
                        allow_redirects=False,  # Do not follow redirects automatically
                        timeout=self.timeout  # Set the timeout for the request
                    )

                    # Check if the response is a redirect
                    proxy_app.logger.debug(f"response.status_code received is {response.status_code}.")
                    if 300 <= response.status_code < 400:
                        # Modify the redirect URL if necessary
                        location = response.headers.get('Location', '')
                        if location:
                            # Here you can modify the Location URL to use the proxy path
                            # For example, change internal URL to external URL
                            new_location = f"http://{request.host}{location}"  # Modify based on the actual proxy host
                            response.headers['Location'] = new_location
                            proxy_app.logger.debug(f"Redirecting to: {new_location}")

                    # Inject the CSRF token into every HTML page that has a POST form
                    # (the login form is served at "/" as well as "/login")
                    if (response.status_code == 200
                            and "text/html" in response.headers.get("Content-Type", "").lower()):
                        token = request.cookies.get(CSRF_COOKIE)
                        if not _csrf_valid_token(token):
                            token = secrets.token_urlsafe(32)
                        hidden = ('<input type="hidden" name="%s" value="%s">' % (CSRF_FIELD, token)).encode()
                        content, count = FORM_POST_RE.subn(lambda m: m.group(0) + hidden, response.content)
                        if count == 0:
                            proxy_app.logger.debug(f"No POST form found to inject CSRF token on /{path}")
                        skip = {"content-length", "content-encoding", "transfer-encoding"}
                        out_headers = [(k, v) for k, v in response.headers.items() if k.lower() not in skip]
                        out = Response(content, response.status_code, out_headers)
                        out.set_cookie(CSRF_COOKIE, token, httponly=True, samesite="Strict", path="/")
                        return out

                    # Return the response to the client
                    return Response(response.content, response.status_code, response.headers.items())

                except requests.exceptions.RequestException as e:
                    # Log the error if the request to the executable fails
                    proxy_app.logger.error(f"Error proxying request: {e}")
                    return f"Error proxying request: {e}", 500

        return proxy_app

# Instantiate the SecureFortGunicornApp with the path to your executable and a custom timeout
executable_path = "/etc/santoi/bin/SecureFort"
timeout = 90  # Set the timeout to 15 seconds (default is 10)
secure_fort = SecureFortGunicornApp(executable_path, timeout=timeout)

# Start the PyInstaller executable in a separate thread
threading.Thread(target=secure_fort.start_executable).start()

# Create the proxy app and expose it as 'app'
app = secure_fort.create_proxy_app()

if __name__ == "__main__":
    # Run the Flask app to serve proxy requests on all IP addresses
    app.run(host="127.0.0.1", port=8000)
PYEOF

python3 -I -c "import ast,sys; ast.parse(open(sys.argv[1]).read())" "$TMP/SecureFortGo.new.py" \
    || die "new SecureFortGo.py has a syntax error; nothing was changed"

# ---------------------------------------------------------------------------
# 2. nginx map file
# ---------------------------------------------------------------------------
cat > "$TMP/csrf-origin.conf" <<EOF
# Origin check for write requests: no Origin or an allowed Origin passes, anything else is blocked
map "\$request_method \$http_origin" \$csrf_block {
    default 0;
    "~^(POST|PUT|PATCH|DELETE) \$" 0;
    "~^(POST|PUT|PATCH|DELETE) https?://(${ALLOWED_ORIGINS_RE})(:[0-9]+)?\$" 0;
    "~^(POST|PUT|PATCH|DELETE) .+" 1;
}
EOF

# ---------------------------------------------------------------------------
# 3. Patch nginx default (idempotent)
# ---------------------------------------------------------------------------
cat > "$TMP/patch_default.py" <<'PYEOF'
import re
import sys

path = sys.argv[1]
s = open(path).read()
orig = s

SERVER_NAME = re.compile(r'^([ \t]*)server_name _;[ \t]*$', re.M)
PROXY_PASS = re.compile(r'^([ \t]*)proxy_pass http://127\.0\.0\.1:8000;[ \t]*$', re.M)

CSP = ("default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; "
       "img-src 'self' data:; connect-src 'self'; frame-ancestors 'none'; base-uri 'self'; form-action 'self'")

def insert_after(pattern, text, lines):
    def repl(m):
        ind = m.group(1)
        return m.group(0) + "".join("\n" + ind + ln if ln else "\n" for ln in lines)
    new, n = pattern.subn(repl, text, count=1)
    if n != 1:
        sys.exit("pattern not found: " + pattern.pattern)
    return new

if "$csrf_block" not in s:
    s = insert_after(SERVER_NAME, s, ["if ($csrf_block) { return 403; }"])

missing = []
if "add_header X-Frame-Options" not in s:
    missing.append('add_header X-Frame-Options "DENY" always;')
if "add_header X-Content-Type-Options" not in s:
    missing.append('add_header X-Content-Type-Options "nosniff" always;')
if "add_header Referrer-Policy" not in s:
    missing.append('add_header Referrer-Policy "strict-origin-when-cross-origin" always;')
if not re.search(r'add_header Content-Security-Policy(-Report-Only)? ', s):
    missing.append('add_header Content-Security-Policy "%s" always;' % CSP)
if missing:
    s = insert_after(SERVER_NAME, s, [""] + ["# security headers"] + missing)

hide = [h for h in ("Access-Control-Allow-Origin", "X-Frame-Options", "X-Content-Type-Options",
                    "Content-Security-Policy", "Referrer-Policy")
        if "proxy_hide_header %s;" % h not in s]
if hide:
    s = insert_after(PROXY_PASS, s, ["proxy_hide_header %s;" % h for h in hide])

if s != orig:
    if len(sys.argv) < 3 or sys.argv[2] != "--check":
        open(path, "w").write(s)
    print("CHANGED")
else:
    print("UNCHANGED")
PYEOF

# ---------------------------------------------------------------------------
# Already patched? Check all three files without touching anything; if so, stop.
# ---------------------------------------------------------------------------
say "Checking current patch state"
NEED=0
r_default="$(python3 -I "$TMP/patch_default.py" "$NGINX_DEFAULT" --check)" || die "cannot analyse $NGINX_DEFAULT"
if [ "$r_default" = "UNCHANGED" ]; then echo "nginx default      : patched"; else echo "nginx default      : NOT patched"; NEED=1; fi
if cmp -s "$TMP/csrf-origin.conf" "$CSRF_CONF" 2>/dev/null; then echo "csrf-origin.conf   : patched"; else echo "csrf-origin.conf   : NOT patched"; NEED=1; fi
if cmp -s "$TMP/SecureFortGo.new.py" "$GO_PY"; then echo "SecureFortGo.py    : patched"; else echo "SecureFortGo.py    : NOT patched"; NEED=1; fi

if [ "$NEED" = "0" ]; then
    echo
    echo "Already patched. Nothing changed, no services restarted."
    exit 0
fi

# ---------------------------------------------------------------------------
# Apply
# ---------------------------------------------------------------------------
say "Backups (timestamp $TS)"
cp -a "$NGINX_DEFAULT" "$NGINX_DEFAULT.bak.$TS"
cp -a "$GO_PY" "$GO_PY.bak.$TS"
[ -f "$CSRF_CONF" ] && cp -a "$CSRF_CONF" "$CSRF_CONF.bak.$TS" || true
echo "backed up to *.bak.$TS"

say "Patching $NGINX_DEFAULT"
r="$(python3 -I "$TMP/patch_default.py" "$NGINX_DEFAULT")" || die "nginx patch failed (backup: $NGINX_DEFAULT.bak.$TS)"
echo "default: $r"
[ "$r" = "CHANGED" ] && CHANGED_NGINX=1

if ! cmp -s "$TMP/csrf-origin.conf" "$CSRF_CONF" 2>/dev/null; then
    install -m 644 "$TMP/csrf-origin.conf" "$CSRF_CONF"
    echo "csrf-origin.conf: written"
    CHANGED_NGINX=1
else
    echo "csrf-origin.conf: unchanged"
fi

say "Patching $GO_PY"
if ! cmp -s "$TMP/SecureFortGo.new.py" "$GO_PY"; then
    install -m 644 "$TMP/SecureFortGo.new.py" "$GO_PY"
    id admin >/dev/null 2>&1 && chown admin:admin "$GO_PY" || true
    echo "SecureFortGo.py: written"
    CHANGED_GO=1
else
    echo "SecureFortGo.py: unchanged"
fi

if [ "$NO_SERVICES" = "1" ]; then
    say "NO_SERVICES=1: files patched, services untouched"
    exit 0
fi

# ---------------------------------------------------------------------------
# Services
# ---------------------------------------------------------------------------
say "nginx -t"
if ! nginx -t; then
    echo "nginx config test failed, restoring nginx files" >&2
    cp -a "$NGINX_DEFAULT.bak.$TS" "$NGINX_DEFAULT"
    if [ -f "$CSRF_CONF.bak.$TS" ]; then cp -a "$CSRF_CONF.bak.$TS" "$CSRF_CONF"; else rm -f "$CSRF_CONF"; fi
    nginx -t || true
    die "nginx files restored; SecureFortGo.py was already updated, restart santoi-go manually if needed"
fi
if [ "$CHANGED_NGINX" = "1" ]; then
    systemctl reload santoi-nginx
    echo "santoi-nginx reloaded"
else
    echo "nginx unchanged, no reload"
fi

if [ "$CHANGED_GO" = "1" ]; then
    say "Restarting santoi-go"
    systemctl restart santoi-go
    sleep 3
    if ! systemctl is-active --quiet santoi-go; then
        echo "santoi-go failed to start, restoring SecureFortGo.py" >&2
        cp -a "$GO_PY.bak.$TS" "$GO_PY"
        systemctl restart santoi-go
        die "restored previous SecureFortGo.py"
    fi
    echo "santoi-go active"
fi

# ---------------------------------------------------------------------------
# Verify
# ---------------------------------------------------------------------------
say "Verification"
FAIL=0
check() { # name, ok(0/1)
    if [ "$2" = "0" ]; then echo "PASS  $1"; else echo "FAIL  $1"; FAIL=1; fi
}
BASE="http://127.0.0.1"

for p in / /login /logout /nonexistent; do
    h="$(curl -sI -m 10 "$BASE$p" || true)"
    ok=0
    for need in 'x-frame-options' 'x-content-type-options' 'referrer-policy' 'content-security-policy:'; do
        echo "$h" | grep -qi "^$need" || ok=1
    done
    echo "$h" | grep -qi '^access-control-allow-origin' && ok=1
    check "headers on $p (4 security headers, no ACAO)" "$ok"
done

code="$(curl -s -o /dev/null -m 10 -w '%{http_code}' -X POST "$BASE/login" -H 'Origin: http://evil.example' -d 'username=a&password=b' || true)"
check "cross-origin POST /login -> 403 (got $code)" "$([ "$code" = 403 ] && echo 0 || echo 1)"

code="$(curl -s -o /dev/null -m 10 -w '%{http_code}' -X POST "$BASE/login" -H 'Origin: http://192.168.3.1' -d 'username=a&password=b' || true)"
check "POST /login without CSRF token -> 400 (got $code)" "$([ "$code" = 400 ] && echo 0 || echo 1)"

jar="$(mktemp)"
tok="$(curl -s -m 10 -c "$jar" "$BASE/" | grep -o 'name="csrf_token" value="[^"]*"' | sed 's/.*value="//;s/"$//' | head -1 || true)"
check "GET / injects csrf_token field + cookie" "$([ -n "$tok" ] && grep -q csrf_token "$jar" && echo 0 || echo 1)"
out="$(curl -s -m 10 -b "$jar" -X POST "$BASE/login" --data-urlencode 'username=csrf-selftest' --data-urlencode 'password=x' --data-urlencode "csrf_token=$tok" || true)"
check "POST /login with valid token reaches app" "$(echo "$out" | grep -q 'Invalid credentials' && echo 0 || echo 1)"
code="$(curl -s -o /dev/null -m 10 -w '%{http_code}' -b "$jar" -X POST "$BASE/login" -d 'username=a&password=b&csrf_token=aaaaaaaaaaaaaaaaaaaaaaaaaaaa' || true)"
check "POST /login with mismatched token -> 400 (got $code)" "$([ "$code" = 400 ] && echo 0 || echo 1)"
rm -f "$jar"

echo
if [ "$FAIL" = "0" ]; then
    echo "ALL CHECKS PASSED. Now hard-refresh http://192.168.3.1/ in the browser and log in once."
else
    echo "SOME CHECKS FAILED. Backups: *.bak.$TS" >&2
    echo "Rollback:" >&2
    echo "  sudo cp -a $GO_PY.bak.$TS $GO_PY && sudo systemctl restart santoi-go" >&2
    echo "  sudo cp -a $NGINX_DEFAULT.bak.$TS $NGINX_DEFAULT && sudo nginx -t && sudo systemctl reload santoi-nginx" >&2
    exit 1
fi
