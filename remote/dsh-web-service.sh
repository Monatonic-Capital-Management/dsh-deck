#!/usr/bin/env bash
# Private URL publication and sanitized application logs for systemd --user.
# Env: DSH_BIN, DSH_HOME, DSH_LOG_FILE, DSH_URL_FILE, DSH_RUNTIME_DIR,
#      DSH_PORT, DSH_WORKDIR. systemd owns the whole service cgroup.
set -o pipefail
umask 077

DSH_BIN="${DSH_BIN:-$HOME/.local/bin/dsh}"
export DSH_HOME="${DSH_HOME:-$HOME/.dsh}"
LOG_FILE="${DSH_LOG_FILE:-$DSH_HOME/remote-web.log}"
URL_FILE="${DSH_URL_FILE:-$DSH_HOME/remote-web.url}"
RUNTIME_DIR="${DSH_RUNTIME_DIR:-${XDG_RUNTIME_DIR:-/tmp}/dsh-web}"
PORT="${DSH_PORT:-3080}"
WORKDIR="${DSH_WORKDIR:-$HOME}"
if ! [[ "$PORT" =~ ^[0-9]+$ ]] || [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then
  echo 'dsh-web-service: invalid DSH_PORT' >&2
  exit 2
fi

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

: > "$LOG_FILE"
chmod 600 "$LOG_FILE"
VERSION_FILE="$DSH_HOME/remote-web.version"
version="$("$DSH_BIN" --version 2>/dev/null | head -1)"
if [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9.-]+)?(\+[A-Za-z0-9.-]+)?$ ]]; then
  version_tmp="$(mktemp "$VERSION_FILE.XXXXXX")" || exit 1
  printf '%s\n' "$version" > "$version_tmp" && mv -f "$version_tmp" "$VERSION_FILE"
else
  rm -f "$VERSION_FILE"
fi

capture_output() {
  local line url temp_file
  while IFS= read -r line || [ -n "$line" ]; do
    if [[ "$line" =~ dsh\ web:[[:space:]]+(http://127\.0\.0\.1:[0-9]+/[^[:space:]\(\)]*) ]]; then
      url="${BASH_REMATCH[1]}"
      case "$url" in
        "http://127.0.0.1:$PORT/"*)
          temp_file="$(mktemp "$URL_FILE.XXXXXX")" || return 1
          printf '%s\n' "$url" > "$temp_file" && mv -f "$temp_file" "$URL_FILE"
          : > "$RUNTIME_DIR/ready"
          ;;
      esac
    fi
    printf '%s\n' "$line" | sed -E \
      -e 's|(https?://[^?#[:space:]]*)[?#][^[:space:]]*|\1?[redacted]|g' \
      -e 's/([Bb]earer[[:space:]]+)[^[:space:]]+/\1[redacted]/g' \
      -e 's/((token|api[_-]?key|password|secret|cookie|authorization)"?[[:space:]]*[:=][[:space:]]*)("[^"]*"|[^[:space:]]+)/\1[redacted]/Ig' \
      -e 's/sk-[A-Za-z0-9_-]+/[redacted]/g' >> "$LOG_FILE"
  done
}

# Process substitution stays in the service cgroup; systemd tracks dsh itself.
exec "$DSH_BIN" web --port "$PORT" --no-open > >(capture_output) 2>&1