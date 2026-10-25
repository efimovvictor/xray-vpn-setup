#!/bin/bash
# setup-macos.sh - install Xray-core as a local (loopback-only) proxy from a VLESS + Reality link
#                 and point Claude Code at it.
#
# What it does:
#   1. Downloads the latest Xray-core release into ~/xray.
#   2. Builds config.json from the vless:// link (UUID, host, keys, SNI, flow - all from the link).
#   3. Installs a LaunchAgent so the proxy starts on login and restarts if it dies.
#   4. Merges HTTPS_PROXY / HTTP_PROXY / NO_PROXY into ~/.claude/settings.json
#      (existing keys are preserved, the file is backed up before any change).
#   5. Starts the proxy and verifies it with a real HTTPS request.
#
# What it does NOT do:
#   * no sudo, no system extensions, no TUN, no drivers
#   * no route changes, no system proxy, no firewall rules
#   * the proxy listens on 127.0.0.1 only, so a corporate VPN keeps working as usual
#
# Usage:
#   ./setup-macos.sh --link "vless://UUID@HOST:PORT?type=tcp&security=reality&pbk=...&sni=...&sid=...&flow=..."
#   ./setup-macos.sh --port 10808
#   ./setup-macos.sh --update
#   ./setup-macos.sh --uninstall
#
# Options:
#   --link URL        vless:// link. Omitted: an existing config is kept, otherwise you are prompted.
#   --port N          local proxy port (HTTP + SOCKS5). Default: 12345
#   --no-autostart    do not install the LaunchAgent
#   --no-claude       do not touch ~/.claude/settings.json
#   --update          re-download Xray-core (config.json is kept)
#   --uninstall       stop the proxy, remove the LaunchAgent, the install dir and the proxy settings
#   -h, --help        this text

set -eu

LABEL="local.xray"
PORT=12345
LINK=""
AUTOSTART=1
CLAUDE=1
UPDATE=0
UNINSTALL=0
XRAY_DIR="${XRAY_DIR:-$HOME/xray}"
NO_PROXY_LIST="localhost,127.0.0.1,::1"
PY=""

say()  { printf '==> %s\n' "$*"; }
note() { printf '    %s\n' "$*"; }
warn() { printf '    ! %s\n' "$*" >&2; }
die()  { printf 'Error: %s\n' "$*" >&2; exit 1; }

usage() { sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
    case "$1" in
        --link)
            [ $# -ge 2 ] || die "--link needs a value"
            LINK="$2"; shift 2 ;;
        --port)
            [ $# -ge 2 ] || die "--port needs a value"
            PORT="$2"; shift 2 ;;
        --no-autostart) AUTOSTART=0; shift ;;
        --no-claude)    CLAUDE=0; shift ;;
        --update)       UPDATE=1; shift ;;
        --uninstall)    UNINSTALL=1; shift ;;
        -h|--help)      usage; exit 0 ;;
        *)              die "unknown option: $1 (try --help)" ;;
    esac
done

case "$PORT" in
    ''|*[!0-9]*) die "port must be a number, got '$PORT'" ;;
esac

CONFIG="$XRAY_DIR/config.json"
XRAY="$XRAY_DIR/xray"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
CLAUDE_FILE="$HOME/.claude/settings.json"
PROXY="http://127.0.0.1:$PORT"

# ---------------------------------------------------------------- helpers

# python3 that is safe to call: on a Mac without the Command Line Tools, /usr/bin/python3
# is a stub that pops up an install dialog, so it is skipped in that case.
detect_python() {
    command -v python3 >/dev/null 2>&1 || return 0
    _p="$(command -v python3)"
    if [ "$_p" = "/usr/bin/python3" ] && ! xcode-select -p >/dev/null 2>&1; then
        return 0
    fi
    PY="$_p"
}

# param KEY -> value of KEY=... in the query string (empty if absent).
# Values in a vless:// link (uuid, base64url keys, hostnames, hex ids) are URL-safe,
# so no percent-decoding is needed.
param() {
    [ -n "$QUERY" ] || return 0
    _key="$1"
    _oldifs="$IFS"
    IFS='&'
    for _kv in $QUERY; do
        case "$_kv" in
            "$_key="*) IFS="$_oldifs"; printf '%s' "${_kv#*=}"; return 0 ;;
        esac
    done
    IFS="$_oldifs"
    return 0
}

build_config() {
    link="$1"
    port="$2"

    case "$link" in
        vless://*) ;;
        *) die "expected a vless:// link" ;;
    esac

    rest="${link#vless://}"
    uuid="${rest%%@*}"
    [ "$uuid" != "$rest" ] || die "the link has no UUID (expected vless://UUID@HOST:PORT?...)"

    after="${rest#*@}"
    hostport="${after%%\?*}"
    hostport="${hostport%%#*}"
    host="${hostport%%:*}"
    sport="${hostport##*:}"

    if [ -z "$host" ] || [ -z "$sport" ] || [ "$host" = "$sport" ]; then
        die "cannot parse HOST:PORT from the link"
    fi

    QUERY=""
    case "$after" in
        *\?*) QUERY="${after#*\?}"; QUERY="${QUERY%%#*}" ;;
    esac

    pbk=$(param pbk)
    sni=$(param sni)
    sid=$(param sid)
    fp=$(param fp)
    flow=$(param flow)
    security=$(param security)

    [ -n "$pbk" ] || die "the link has no 'pbk' parameter - is it really a Reality link?"
    [ -n "$sni" ] || die "the link has no 'sni' parameter - is it really a Reality link?"
    if [ -n "$security" ] && [ "$security" != "reality" ]; then
        die "this script builds Reality configs only (link says security=$security)"
    fi
    [ -n "$fp" ] || fp="chrome"

    case "$host" in
        localhost|127.0.0.1|'[::1]'|'::1')
            die "the link points at $host instead of the server IP (panels generate such links when opened through a tunnel). Replace the host with the real server IP and run again." ;;
    esac

    if [ -n "$flow" ]; then
        users="{\"id\": \"$uuid\", \"encryption\": \"none\", \"flow\": \"$flow\"}"
    else
        users="{\"id\": \"$uuid\", \"encryption\": \"none\"}"
    fi

    mkdir -p "$XRAY_DIR"
    cat > "$CONFIG" <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "listen": "127.0.0.1",
      "port": $port,
      "protocol": "mixed",
      "settings": { "auth": "noauth", "udp": true }
    }
  ],
  "outbounds": [
    {
      "protocol": "vless",
      "settings": {
        "vnext": [
          {
            "address": "$host",
            "port": $sport,
            "users": [ $users ]
          }
        ]
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "serverName": "$sni",
          "fingerprint": "$fp",
          "publicKey": "$pbk",
          "shortId": "$sid"
        }
      }
    }
  ]
}
EOF

    note "server $host:$sport, SNI $sni, local port $port"
}

config_port() {
    [ -f "$CONFIG" ] || { printf '0'; return 0; }
    sed -n 's/.*"port": *\([0-9][0-9]*\).*/\1/p' "$CONFIG" | head -n 1
}

check_config() {
    [ -x "$XRAY" ] || die "xray binary not found at $XRAY"
    if "$XRAY" run -test -c "$CONFIG" >/dev/null 2>&1; then
        note "config check: OK"
    else
        "$XRAY" run -test -c "$CONFIG" || true
        die "the generated config is not valid (see above)"
    fi
}

install_binary() {
    case "$(uname -m)" in
        arm64|aarch64) asset="Xray-macos-arm64-v8a.zip" ;;
        x86_64|amd64)  asset="Xray-macos-64.zip" ;;
        *) die "unsupported architecture: $(uname -m)" ;;
    esac

    tmp="$(mktemp -d)"
    note "downloading $asset"
    if ! curl -fsSL -o "$tmp/xray.zip" \
        "https://github.com/XTLS/Xray-core/releases/latest/download/$asset"; then
        rm -rf "$tmp"
        die "could not download Xray-core"
    fi

    mkdir -p "$XRAY_DIR"
    unzip -o -q "$tmp/xray.zip" -d "$XRAY_DIR"
    rm -rf "$tmp"
    chmod +x "$XRAY"
    xattr -dr com.apple.quarantine "$XRAY_DIR" 2>/dev/null || true
    note "installed into $XRAY_DIR"
}

write_plist() {
    mkdir -p "$HOME/Library/LaunchAgents"
    cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$XRAY</string>
        <string>run</string>
        <string>-c</string>
        <string>$CONFIG</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>$XRAY_DIR/out.log</string>
    <key>StandardErrorPath</key>
    <string>$XRAY_DIR/error.log</string>
</dict>
</plist>
EOF
    note "launch agent: $PLIST"
}

load_agent() {
    launchctl bootout "gui/$(id -u)/$LABEL" >/dev/null 2>&1 || true
    launchctl bootstrap "gui/$(id -u)" "$PLIST"
    launchctl kickstart -k "gui/$(id -u)/$LABEL" >/dev/null 2>&1 || true
}

set_claude_proxy() {
    file="$1"
    proxy="$2"

    mkdir -p "$(dirname "$file")"

    if [ ! -s "$file" ]; then
        cat > "$file" <<EOF
{
  "env": {
    "HTTPS_PROXY": "$proxy",
    "HTTP_PROXY": "$proxy",
    "NO_PROXY": "$NO_PROXY_LIST"
  }
}
EOF
        note "claude code proxy: $file (created)"
        return 0
    fi

    backup="$file.bak.$(date +%Y%m%d-%H%M%S)"
    cp "$file" "$backup"

    if [ -n "$PY" ] && "$PY" - "$file" "$proxy" "$NO_PROXY_LIST" <<'PYCODE'
import json, sys

path, proxy, no_proxy = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path, encoding="utf-8") as fh:
    data = json.load(fh)
if not isinstance(data, dict):
    raise SystemExit(1)
env = data.get("env")
if not isinstance(env, dict):
    env = {}
    data["env"] = env
env["HTTPS_PROXY"] = proxy
env["HTTP_PROXY"] = proxy
env["NO_PROXY"] = no_proxy
with open(path, "w", encoding="utf-8") as fh:
    json.dump(data, fh, indent=2, ensure_ascii=False)
    fh.write("\n")
PYCODE
    then
        note "claude code proxy: $file (merged, backup: $backup)"
        return 0
    fi

    warn "could not merge automatically, writing a minimal settings file instead"
    warn "the previous version is kept at $backup"
    cat > "$file" <<EOF
{
  "env": {
    "HTTPS_PROXY": "$proxy",
    "HTTP_PROXY": "$proxy",
    "NO_PROXY": "$NO_PROXY_LIST"
  }
}
EOF
}

remove_claude_proxy() {
    file="$1"
    proxy="$2"

    [ -f "$file" ] || return 0
    if [ -z "$PY" ]; then
        warn "python3 not available - remove HTTPS_PROXY / HTTP_PROXY / NO_PROXY from $file manually"
        return 0
    fi

    result=$("$PY" - "$file" "$proxy" "$NO_PROXY_LIST" <<'PYCODE'
import json, os, sys

path, proxy, no_proxy = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path, encoding="utf-8") as fh:
    data = json.load(fh)
env = data.get("env")
if isinstance(env, dict):
    for key in ("HTTPS_PROXY", "HTTP_PROXY"):
        if env.get(key) == proxy:
            del env[key]
    if env.get("NO_PROXY") == no_proxy:
        del env["NO_PROXY"]
    if not env:
        del data["env"]
if not data:
    os.remove(path)
    print("removed")
else:
    with open(path, "w", encoding="utf-8") as fh:
        json.dump(data, fh, indent=2, ensure_ascii=False)
        fh.write("\n")
    print("cleaned")
PYCODE
) || { warn "cannot parse $file - left untouched"; return 0; }

    note "$file: $result"
}

verify_tunnel() {
    i=0
    while [ $i -lt 8 ]; do
        out=$(curl -s -m 10 -x "$PROXY" https://api.ipify.org 2>/dev/null || true)
        if [ -n "$out" ]; then
            printf '%s' "$out"
            return 0
        fi
        i=$((i + 1))
        sleep 1
    done
    return 1
}

# ---------------------------------------------------------------- uninstall

[ "$(uname -s)" = "Darwin" ] || die "this script is for macOS (found $(uname -s))"
detect_python

if [ "$UNINSTALL" = "1" ]; then
    say "Removing the Xray proxy"

    p=$(config_port)
    case "$p" in ''|*[!0-9]*) p=0 ;; esac
    if [ "$p" -gt 0 ]; then PROXY="http://127.0.0.1:$p"; fi

    launchctl bootout "gui/$(id -u)/$LABEL" >/dev/null 2>&1 || true
    pkill -f "^$XRAY run" >/dev/null 2>&1 || true
    sleep 1
    note "process stopped"

    if [ -f "$PLIST" ]; then
        rm -f "$PLIST"
        note "removed $PLIST"
    fi

    if [ "$CLAUDE" = "1" ]; then
        remove_claude_proxy "$CLAUDE_FILE" "$PROXY"
    fi

    if [ -d "$XRAY_DIR" ]; then
        i=0
        while [ "$i" -lt 10 ] && [ -d "$XRAY_DIR" ]; do
            i=$((i + 1))
            rm -rf "$XRAY_DIR" 2>/dev/null || true
            if [ -d "$XRAY_DIR" ]; then sleep 1; fi
        done
        if [ -d "$XRAY_DIR" ]; then
            warn "could not remove $XRAY_DIR - delete it manually"
        else
            note "removed $XRAY_DIR"
        fi
    fi

    say "Done. Nothing else on this machine was changed."
    exit 0
fi

# ---------------------------------------------------------------- install

say "Xray proxy setup"

# 1. config (done first, so a bad link fails before anything is downloaded)
say "Configuring"
if [ -n "$LINK" ]; then
    build_config "$LINK" "$PORT"
elif [ -f "$CONFIG" ]; then
    p=$(config_port)
    case "$p" in ''|*[!0-9]*) p=0 ;; esac
    if [ "$p" -gt 0 ]; then PORT="$p"; PROXY="http://127.0.0.1:$PORT"; fi
    note "existing config kept: $CONFIG (local port $PORT)"
    note "pass --link \"vless://...\" to replace it"
else
    printf 'Paste the vless:// link: '
    read -r LINK
    [ -n "$LINK" ] || die "no link provided"
    build_config "$LINK" "$PORT"
fi

# 2. binary
if [ -x "$XRAY" ] && [ "$UPDATE" = "0" ]; then
    say "Xray-core already present"
    note "$XRAY"
else
    say "Installing Xray-core"
    install_binary
fi
check_config

# 3. autostart
if [ "$AUTOSTART" = "1" ]; then
    say "Setting up autostart"
    write_plist
else
    say "Autostart: skipped (--no-autostart)"
fi

# 4. claude code
if [ "$CLAUDE" = "1" ]; then
    say "Configuring Claude Code"
    set_claude_proxy "$CLAUDE_FILE" "$PROXY"
else
    say "Claude Code settings: skipped (--no-claude)"
fi

# 5. start + verify
say "Starting the proxy"
if [ "$AUTOSTART" = "1" ]; then
    load_agent
else
    pkill -f "^$XRAY run" >/dev/null 2>&1 || true
    sleep 1
    nohup "$XRAY" run -c "$CONFIG" > "$XRAY_DIR/out.log" 2>&1 &
    sleep 2
fi

exit_ip=$(verify_tunnel || true)

say "Summary"
note "install dir : $XRAY_DIR"
note "config      : $CONFIG"
note "local proxy : $PROXY  (HTTP and SOCKS5)"
if [ "$CLAUDE" = "1" ]; then
    note "claude code : $CLAUDE_FILE"
else
    note "claude code : untouched - add this to $CLAUDE_FILE manually:"
    note "              \"env\": { \"HTTPS_PROXY\": \"$PROXY\", \"HTTP_PROXY\": \"$PROXY\", \"NO_PROXY\": \"$NO_PROXY_LIST\" }"
fi
if [ "$AUTOSTART" = "1" ]; then
    note "autostart   : $PLIST (starts on login, restarts on crash)"
fi

echo
if [ -n "$exit_ip" ]; then
    echo "Tunnel works. Exit IP: $exit_ip"
else
    echo "Proxy did not answer yet. Check the logs, then run it in the foreground to see why:"
    echo "  $XRAY run -c $CONFIG"
    echo "Logs: $XRAY_DIR/out.log and $XRAY_DIR/error.log"
fi

echo
note "Useful commands:"
if [ "$AUTOSTART" = "1" ]; then
    note "  stop    : launchctl bootout gui/\$(id -u)/$LABEL"
    note "  start   : launchctl bootstrap gui/\$(id -u) $PLIST"
    note "  restart : launchctl kickstart -k gui/\$(id -u)/$LABEL"
else
    note "  start   : $XRAY run -c $CONFIG &"
    note "  stop    : pkill -f '$XRAY run'"
fi
note "  test    : curl -s -x $PROXY https://api.ipify.org"
note "  remove  : $0 --uninstall"
