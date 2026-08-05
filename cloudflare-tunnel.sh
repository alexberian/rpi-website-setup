#!/usr/bin/env bash
#
# cloudflare-tunnel.sh — connect the Pi to Cloudflare so your domain reaches it
# without port forwarding, a static IP, or any router configuration.
#
# Two ways to do it:
#
#   Dashboard-managed (easiest — recommended)
#     Create the tunnel at one.dash.cloudflare.com -> Networks -> Tunnels,
#     copy the connector token it shows you, then:
#       sudo ./cloudflare-tunnel.sh --token eyJhIjoi...
#     Add the public hostname in the dashboard, pointing at http://localhost:8080.
#
#   CLI-managed (config lives on the Pi)
#     sudo ./cloudflare-tunnel.sh --name mypi --hostname example.com
#     Opens a browser link to authorize, then wires up DNS and the service.

set -euo pipefail

LOCAL_PORT="8080"
TOKEN=""
NAME=""
HOSTNAME_ARG=""

BOLD=""; DIM=""; RED=""; GREEN=""; BLUE=""; RESET=""
if [[ -t 1 ]]; then
	BOLD=$'\033[1m'; DIM=$'\033[2m'; RED=$'\033[31m'
	GREEN=$'\033[32m'; BLUE=$'\033[34m'; RESET=$'\033[0m'
fi
info() { printf '%s==>%s %s\n' "$BLUE$BOLD" "$RESET" "$*"; }
step() { printf '  %s->%s %s\n' "$DIM" "$RESET" "$*"; }
ok()   { printf '  %s+%s %s\n' "$GREEN" "$RESET" "$*"; }
die()  { printf '%serror:%s %s\n' "$RED$BOLD" "$RESET" "$*" >&2; exit 1; }

usage() {
	sed -n '3,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
	cat <<EOF

OPTIONS
  --token <t>      Connector token from the Cloudflare dashboard.
  --name <n>       Tunnel name, for the CLI-managed path.
  --hostname <h>   Public hostname to route, for the CLI-managed path.
  --port <n>       Local port Caddy serves on. Default $LOCAL_PORT.
  --status         Show tunnel service status.
  -h, --help       Show this help.
EOF
}

install_cloudflared() {
	command -v cloudflared >/dev/null 2>&1 && return 0
	info "Installing cloudflared"
	DEBIAN_FRONTEND=noninteractive apt-get install -y -qq curl gnupg ca-certificates >/dev/null
	curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg \
		>/usr/share/keyrings/cloudflare-main.gpg
	echo "deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared any main" \
		>/etc/apt/sources.list.d/cloudflared.list
	DEBIAN_FRONTEND=noninteractive apt-get update -qq
	DEBIAN_FRONTEND=noninteractive apt-get install -y -qq cloudflared >/dev/null
	command -v cloudflared >/dev/null 2>&1 || die "cloudflared installation failed"
	ok "$(cloudflared --version)"
}

setup_with_token() {
	install_cloudflared
	info "Installing the tunnel service from your connector token"
	systemctl stop cloudflared 2>/dev/null || true
	cloudflared service uninstall 2>/dev/null || true
	cloudflared service install "$TOKEN"
	systemctl enable --now cloudflared
	sleep 2
	systemctl is-active --quiet cloudflared \
		|| die "cloudflared did not start: journalctl -u cloudflared -n 50"
	ok "tunnel connected"
	cat <<EOF

${BOLD}One step left, in the Cloudflare dashboard:${RESET}
  one.dash.cloudflare.com -> Networks -> Tunnels -> your tunnel -> Public Hostname
    Subdomain/Domain : whatever you want to serve
    Service Type     : HTTP
    URL              : localhost:$LOCAL_PORT

Make sure the site is deployed in tunnel mode so it listens there:
  sudo setup-website.sh site.zip --tunnel --port $LOCAL_PORT
EOF
}

setup_with_cli() {
	install_cloudflared
	local cred_dir="/etc/cloudflared"
	mkdir -p "$cred_dir"

	if [[ ! -f "$HOME/.cloudflared/cert.pem" && ! -f "$cred_dir/cert.pem" ]]; then
		info "Authorizing this Pi with your Cloudflare account"
		echo "  A URL will be printed below — open it on any device and pick your domain."
		cloudflared tunnel login
	fi
	[[ -f "$HOME/.cloudflared/cert.pem" ]] && cp -n "$HOME/.cloudflared/cert.pem" "$cred_dir/cert.pem"

	local uuid
	if cloudflared tunnel list 2>/dev/null | awk '{print $2}' | grep -qx "$NAME"; then
		step "reusing existing tunnel '$NAME'"
	else
		info "Creating tunnel '$NAME'"
		cloudflared tunnel create "$NAME"
	fi
	uuid="$(cloudflared tunnel list --output json 2>/dev/null \
		| python3 -c 'import json,sys;print(next((t["id"] for t in json.load(sys.stdin) if t["name"]==sys.argv[1]),""))' "$NAME")"
	[[ -n "$uuid" ]] || die "could not determine the tunnel id for '$NAME'"

	local creds="$HOME/.cloudflared/$uuid.json"
	[[ -f "$creds" ]] || die "credentials file not found: $creds"
	cp -f "$creds" "$cred_dir/$uuid.json"
	chmod 600 "$cred_dir/$uuid.json"

	info "Writing $cred_dir/config.yml"
	cat >"$cred_dir/config.yml" <<EOF
# Managed by cloudflare-tunnel.sh
tunnel: $uuid
credentials-file: $cred_dir/$uuid.json

ingress:
  - hostname: $HOSTNAME_ARG
    service: http://localhost:$LOCAL_PORT
  - service: http_status:404
EOF

	info "Routing DNS: $HOSTNAME_ARG -> $NAME"
	cloudflared tunnel route dns "$NAME" "$HOSTNAME_ARG" || \
		step "DNS route already exists, continuing"

	info "Installing the tunnel service"
	systemctl stop cloudflared 2>/dev/null || true
	cloudflared service uninstall 2>/dev/null || true
	cloudflared service install
	systemctl enable --now cloudflared
	sleep 2
	systemctl is-active --quiet cloudflared \
		|| die "cloudflared did not start: journalctl -u cloudflared -n 50"

	ok "tunnel is up"
	cat <<EOF

Your site should now be reachable at ${BOLD}https://$HOSTNAME_ARG${RESET}
Cloudflare terminates TLS, so no certificates are needed on the Pi.

Deploy in tunnel mode so Caddy listens where the tunnel expects:
  sudo setup-website.sh site.zip --tunnel --port $LOCAL_PORT --domain $HOSTNAME_ARG
EOF
}

show_status() {
	if systemctl cat cloudflared >/dev/null 2>&1; then
		systemctl status cloudflared --no-pager -n 20 || true
	else
		echo "cloudflared service is not installed."
	fi
}

COMMAND="setup"
while [[ $# -gt 0 ]]; do
	case "$1" in
		--token)    TOKEN="${2:-}"; shift 2 ;;
		--name)     NAME="${2:-}"; shift 2 ;;
		--hostname) HOSTNAME_ARG="${2:-}"; shift 2 ;;
		--port)     LOCAL_PORT="${2:-}"; shift 2 ;;
		--status)   COMMAND="status"; shift ;;
		-h|--help)  usage; exit 0 ;;
		*)          die "unknown option: $1 (try --help)" ;;
	esac
done

[[ "$COMMAND" == "status" ]] && { show_status; exit 0; }

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
	die "run with sudo: sudo $0 $*"
fi

if [[ -n "$TOKEN" ]]; then
	setup_with_token
elif [[ -n "$NAME" && -n "$HOSTNAME_ARG" ]]; then
	setup_with_cli
else
	usage
	exit 1
fi
