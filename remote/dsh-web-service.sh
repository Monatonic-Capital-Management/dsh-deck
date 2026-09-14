#!/usr/bin/env bash
# dsh-web-service.sh - run `dsh web` on a remote host under systemd --user.
#
# Why this exists (rather than ExecStart=dsh web directly):
#
#   1. Recent dsh prints a ONE-TIME authenticated URL at startup
#      (`dsh web: http://127.0.0.1:3080/?token=...`). That token is the only way
#      to obtain the browser's signed cookie. Under systemd there is no terminal
#      to read it from, so stdout is captured here and the URL is republished to
#      a file that the local launcher reads over SSH.
#
#   2. Older dsh (<= 0.1.1) prints no token and does not fence `/`. This script
#      must work with both, so every step below tolerates the token being absent.
#
#   3. `exec` keeps the node process as systemd's main process, so
#      `systemctl --user stop` signals the server itself rather than a wrapper
#      shell that outlived it.
#
# Usage: dsh-web-service.sh
# Env overrides: DSH_BIN, DSH_HOME, DSH_LOG_FILE, DSH_URL_FILE,
#                DSH_RUNTIME_DIR, DSH_PORT, DSH_WORKDIR

set -o pipefail

DSH_BIN="${DSH_BIN:-$HOME/.local/bin/dsh}"
DSH_HOME="${DSH_HOME:-$HOME/.dsh}"
LOG_FILE="${DSH_LOG_FILE:-$DSH_HOME/remote-web.log}"
URL_FILE="${DSH_URL_FILE:-$DSH_HOME/remote-web.url}"
RUNTIME_DIR="${DSH_RUNTIME_DIR:-${XDG_RUNTIME_DIR:-/tmp}/dsh-web}"
PORT="${DSH_PORT:-3080}"
WORKDIR="${DSH_WORKDIR:-$HOME}"

mkdir -p "$(dirname "$LOG_FILE")" "$(dirname "$URL_FILE")" "$RUNTIME_DIR"

# Resolve dsh. A systemd user service gets a minimal PATH, and npm's global
# prefix differs per host (npm config get prefix), so search the usual places
# instead of assuming one layout.
if [ ! -x "$DSH_BIN" ]; then
  RESOLVED="$(command -v dsh 2>/dev/null || true)"
  if [ -n "$RESOLVED" ]; then
    DSH_BIN="$RESOLVED"
  else
    for c in \
      "$HOME/.local/bin/dsh" \
      "$HOME/.npm-global/bin/dsh" \
      "$HOME/.local/node/bin/dsh" \
      "/usr/local/bin/dsh" \
      "/usr/bin/dsh"
    do
      if [ -x "$c" ]; then DSH_BIN="$c"; break; fi
    done
  fi
fi

if [ ! -x "$DSH_BIN" ]; then
  echo "dsh-web-service: cannot find the dsh binary (tried PATH, ~/.local/bin, ~/.npm-global/bin, ~/.local/node/bin, /usr/local/bin)" >&2
  echo "dsh-web-service: install it with: npm install -g @deepseek-ai/dsh" >&2
  exit 127
fi

# npm's global bin directory may not be on the service PATH, and dsh's shebang
# is `#!/usr/bin/env node`, so PATH must also expose a NEW enough node: on a host
# whose system node is older than dsh's requirement, resolving to it makes dsh
# exit 0 with no output at all. ~/.local/node is a node this tool installed, so
# it goes first when present.
if [ -x "$HOME/.local/node/bin/node" ]; then
  export PATH="$HOME/.local/node/bin:$PATH"
fi
export PATH="$(dirname "$DSH_BIN"):$HOME/.local/bin:$HOME/.npm-global/bin:$PATH"

cd "$WORKDIR" || exit 1

# Rotate the previous run's log so a stale token can never be mistaken for the
# current one, then remove the published URL and the readiness flag.
[ -s "$LOG_FILE" ] && mv -f "$LOG_FILE" "$LOG_FILE.1"
rm -f "$URL_FILE" "$RUNTIME_DIR/ready"

# Publish dsh's URL (token or plain) as soon as it appears.
publish_url() {
  local i url
  for i in $(seq 1 600); do
    if [ -s "$LOG_FILE" ]; then
      url="$(grep -oE 'https?://[^[:space:]]+' "$LOG_FILE" | head -n 1)"
      if [ -n "$url" ]; then
        printf '%s\n' "$url" > "$URL_FILE.tmp" && mv -f "$URL_FILE.tmp" "$URL_FILE"
        : > "$RUNTIME_DIR/ready"
        return 0
      fi
    fi
    sleep 0.2
  done
  return 1
}

publish_url &

# exec: systemd tracks the real server process; its stdout lands in LOG_FILE.
#
# The subshell above is what makes reporting tricky: with a bare `exec`, systemd
# sees only the exit status of the server, which is right, but a wrapper that
# dies before reaching `exec` would be reported as success. So the exit code is
# captured explicitly and a failure is written to the log AND propagated, rather
# than letting a silent 0 pretend the service started.
"$DSH_BIN" web --port "$PORT" --no-open >>"$LOG_FILE" 2>&1
code=$?

if [ "$code" -ne 0 ]; then
  {
    echo "dsh-web-service: dsh exited with status $code"
    echo "dsh-web-service: dsh binary was $DSH_BIN"
    echo "dsh-web-service: node is $(command -v node || echo 'not on PATH') $(node -v 2>/dev/null)"
    echo "dsh-web-service: run it by hand to see the real error --"
    echo "  $DSH_BIN web --port $PORT --no-open"
  } >>"$LOG_FILE" 2>&1
  exit "$code"
fi
