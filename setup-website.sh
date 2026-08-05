#!/usr/bin/env bash
#
# setup-website.sh — deploy a static website from a .zip onto a Raspberry Pi.
#
#   setup-website.sh site.zip                 # deploy (first run also installs Caddy)
#   setup-website.sh site.zip --domain x.com  # deploy and serve on a domain
#   setup-website.sh --rollback               # revert to the previous release
#   setup-website.sh --status                 # show what is currently live
#
# Releases are extracted side by side under /var/www/<site>/releases/<timestamp>
# and swapped in by atomically flipping the /var/www/<site>/current symlink, so a
# deploy is instant and the previous release is always one command away.

set -euo pipefail

VERSION="1.0.0"

# ---------------------------------------------------------------- defaults ---

CONFIG_DIR="/etc/setup-website"
CONFIG_FILE=""   # resolved to $CONFIG_DIR/<site>.conf once the site is known
CADDY_SITES_DIR="/etc/caddy/sites"
CADDYFILE="/etc/caddy/Caddyfile"
LOG_DIR="/var/log/caddy"

SITE_NAME="website"
DOMAIN=""
MODE="direct"      # direct | tunnel
LISTEN_PORT=""     # blank -> 80 for direct, 8080 for tunnel
SPA="false"
KEEP_RELEASES="5"

# --------------------------------------------------------------- utilities ---

BOLD=""; DIM=""; RED=""; GREEN=""; YELLOW=""; BLUE=""; RESET=""
if [[ -t 1 ]]; then
	BOLD=$'\033[1m'; DIM=$'\033[2m'; RED=$'\033[31m'; GREEN=$'\033[32m'
	YELLOW=$'\033[33m'; BLUE=$'\033[34m'; RESET=$'\033[0m'
fi

# All progress logging goes to stderr, so a function that reports progress can
# still return a value through stdout via command substitution.
info()  { printf '%s==>%s %s\n' "$BLUE$BOLD" "$RESET" "$*" >&2; }
step()  { printf '  %s->%s %s\n' "$DIM" "$RESET" "$*" >&2; }
ok()    { printf '  %s+%s %s\n' "$GREEN" "$RESET" "$*" >&2; }
warn()  { printf '  %s!%s %s\n' "$YELLOW" "$RESET" "$*" >&2; }
die()   { printf '%serror:%s %s\n' "$RED$BOLD" "$RESET" "$*" >&2; exit 1; }

TMPDIR_DEPLOY=""
cleanup() {
	# Must end successfully: an EXIT trap's status becomes the script's exit code.
	if [[ -n "$TMPDIR_DEPLOY" && -d "$TMPDIR_DEPLOY" ]]; then
		rm -rf "$TMPDIR_DEPLOY"
	fi
	return 0
}
trap cleanup EXIT

usage() {
	cat <<EOF
${BOLD}setup-website.sh${RESET} v$VERSION — deploy a static site from a .zip onto a Raspberry Pi.

${BOLD}USAGE${RESET}
  setup-website.sh <site.zip> [options]
  setup-website.sh <command>

${BOLD}COMMANDS${RESET}
  --rollback           Switch back to the previous release.
  --list               List stored releases, newest first.
  --status             Show current config, live release, and service health.
  --reconfigure        Rewrite the Caddy config from saved settings and reload.
  --uninstall          Remove the site config and served files (asks first).
  -h, --help           Show this help.
  -V, --version        Show version.

${BOLD}OPTIONS${RESET}
  --domain <d>         Domain(s) to serve, space-separated. Empty for IP-only.
  --tunnel             Serve on localhost only, for use with a Cloudflare Tunnel.
  --direct             Serve on a public port directly (default).
  --port <n>           Listen port. Default 80 (direct) or 8080 (tunnel).
  --site <name>        Site name, used for paths. Default "$SITE_NAME".
  --spa                Fall back to /index.html for unknown paths (single-page apps).
  --no-spa             Turn SPA fallback off.
  --keep <n>           Number of old releases to retain. Default $KEEP_RELEASES.

${BOLD}EXAMPLES${RESET}
  sudo ./setup-website.sh site.zip --tunnel --domain example.com
  sudo setup-website.sh newfiles.zip
  sudo setup-website.sh --rollback

Settings are saved to $CONFIG_FILE, so later deploys need only the .zip.
EOF
}

# Re-run under sudo if we are not root; every path we touch needs it.
require_root() {
	if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
		command -v sudo >/dev/null 2>&1 || die "must be run as root (sudo not available)"
		exec sudo -- bash "$SCRIPT_PATH" "${ORIGINAL_ARGS[@]}"
	fi
}

# ------------------------------------------------------------------ config ---

# Settings are stored per site, so hosting several sites never lets one site's
# domain or port bleed into another's deploy.
resolve_config_file() {
	CONFIG_FILE="$CONFIG_DIR/$SITE_NAME.conf"

	# No --site given and no config under the default name: if exactly one site
	# is configured, that is unambiguously the one they mean.
	if [[ ! -f "$CONFIG_FILE" && "$SITE_NAME" == "$DEFAULT_SITE_NAME" ]]; then
		local found=() f
		for f in "$CONFIG_DIR"/*.conf; do [[ -f "$f" ]] && found+=("$f"); done
		if [[ ${#found[@]} -eq 1 ]]; then
			CONFIG_FILE="${found[0]}"
			SITE_NAME="$(basename "${found[0]}" .conf)"
		elif [[ ${#found[@]} -gt 1 ]]; then
			warn "several sites are configured; defaulting to '$SITE_NAME'. Use --site to pick one:"
			for f in "${found[@]}"; do warn "    --site $(basename "$f" .conf)"; done
		fi
	fi
}

load_config() {
	[[ -f "$CONFIG_FILE" ]] || return 0
	# shellcheck disable=SC1090
	source "$CONFIG_FILE"
}

save_config() {
	mkdir -p "$CONFIG_DIR"
	CONFIG_FILE="$CONFIG_DIR/$SITE_NAME.conf"   # --site may have changed since load
	cat >"$CONFIG_FILE" <<EOF
# Written by setup-website.sh — safe to edit, then run: setup-website.sh --reconfigure
SITE_NAME=$(printf '%q' "$SITE_NAME")
DOMAIN=$(printf '%q' "$DOMAIN")
MODE=$(printf '%q' "$MODE")
LISTEN_PORT=$(printf '%q' "$LISTEN_PORT")
SPA=$(printf '%q' "$SPA")
KEEP_RELEASES=$(printf '%q' "$KEEP_RELEASES")
EOF
	chmod 644 "$CONFIG_FILE"
}

effective_port() {
	if [[ -n "$LISTEN_PORT" ]]; then
		printf '%s' "$LISTEN_PORT"
	elif [[ "$MODE" == "tunnel" ]]; then
		printf '8080'
	else
		printf '80'
	fi
}

site_root() { printf '/var/www/%s' "$SITE_NAME"; }

# --------------------------------------------------------- dependency setup ---

apt_install() {
	local pkgs=("$@") missing=()
	local p
	for p in "${pkgs[@]}"; do
		dpkg -s "$p" >/dev/null 2>&1 || missing+=("$p")
	done
	[[ ${#missing[@]} -eq 0 ]] && return 0
	step "installing: ${missing[*]}"
	DEBIAN_FRONTEND=noninteractive apt-get update -qq
	DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${missing[@]}" >/dev/null
}

install_caddy() {
	command -v caddy >/dev/null 2>&1 && return 0
	info "Installing Caddy"
	apt_install debian-keyring debian-archive-keyring apt-transport-https curl gnupg
	step "adding the official Caddy apt repository"
	curl -fsSL 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
		| gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
	curl -fsSL 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
		>/etc/apt/sources.list.d/caddy-stable.list
	DEBIAN_FRONTEND=noninteractive apt-get update -qq
	DEBIAN_FRONTEND=noninteractive apt-get install -y -qq caddy >/dev/null
	command -v caddy >/dev/null 2>&1 || die "Caddy installation failed"
	ok "Caddy $(caddy version | head -1)"
}

ensure_deps() {
	command -v apt-get >/dev/null 2>&1 \
		|| die "this script targets Debian-based systems (Raspberry Pi OS). No apt-get found."
	apt_install unzip ca-certificates
	install_caddy
}

# ---------------------------------------------------------- caddy configing ---

# Take ownership of /etc/caddy/Caddyfile, backing up whatever was there first,
# and reduce it to an import of the per-site fragments we manage.
ensure_caddyfile_import() {
	mkdir -p "$CADDY_SITES_DIR"
	local marker="# Managed by setup-website.sh"
	if [[ -f "$CADDYFILE" ]] && ! grep -qF "$marker" "$CADDYFILE"; then
		local backup="$CADDYFILE.bak-$(date +%Y%m%d%H%M%S)"
		cp -a "$CADDYFILE" "$backup"
		warn "existing Caddyfile backed up to $backup"
	fi
	cat >"$CADDYFILE" <<EOF
$marker — edit files in $CADDY_SITES_DIR instead.
import $CADDY_SITES_DIR/*.caddyfile
EOF
	chmod 644 "$CADDYFILE"
}

site_address() {
	local port; port="$(effective_port)"
	if [[ "$MODE" == "tunnel" ]]; then
		printf 'http://127.0.0.1:%s' "$port"
	elif [[ -n "$DOMAIN" ]]; then
		# "a.com b.com" -> "a.com, b.com"; Caddy then provisions certs for both.
		printf '%s' "$(echo "$DOMAIN" | tr -s ' ' | sed 's/ /, /g')"
	else
		printf 'http://:%s' "$port"
	fi
}

write_caddy_site() {
	local root fragment try
	root="$(site_root)/current"
	fragment="$CADDY_SITES_DIR/$SITE_NAME.caddyfile"

	# The package normally creates this, but Caddy fails to start if it is missing.
	mkdir -p "$LOG_DIR"
	if id -u caddy >/dev/null 2>&1; then chown caddy:caddy "$LOG_DIR" || true; fi

	if [[ "$SPA" == "true" ]]; then
		try='try_files {path} {path}/index.html {path}.html /index.html'
	else
		try='try_files {path} {path}/index.html {path}.html'
	fi

	cat >"$fragment" <<EOF
# Managed by setup-website.sh — regenerate with: setup-website.sh --reconfigure
$(site_address) {
	root * $root
	encode zstd gzip

	$try
	file_server

	header {
		-Server
		X-Content-Type-Options "nosniff"
		Referrer-Policy "strict-origin-when-cross-origin"
	}

	# Fingerprinted assets can be cached hard; HTML must not be.
	@immutable path *.css *.js *.woff2 *.woff *.png *.jpg *.jpeg *.gif *.svg *.webp *.avif *.ico
	header @immutable Cache-Control "public, max-age=31536000"
	@html path *.html /
	header @html Cache-Control "no-cache"

	log {
		output file $LOG_DIR/$SITE_NAME.log {
			roll_size 10MiB
			roll_keep 5
		}
	}
}
EOF
	chmod 644 "$fragment"
}

reload_caddy() {
	step "validating Caddy config"
	if ! caddy validate --config "$CADDYFILE" --adapter caddyfile >/dev/null 2>&1; then
		caddy validate --config "$CADDYFILE" --adapter caddyfile || true
		die "Caddy rejected the generated config (see above)"
	fi
	systemctl enable --now caddy >/dev/null 2>&1 || true
	if systemctl is-active --quiet caddy; then
		systemctl reload caddy
	else
		systemctl restart caddy
	fi
	systemctl is-active --quiet caddy || die "Caddy failed to start: journalctl -u caddy -n 50"
	ok "Caddy reloaded"
}

# ------------------------------------------------------------- zip handling ---

validate_zip() {
	local zip="$1"
	[[ -f "$zip" ]] || die "no such file: $zip"
	unzip -tqq "$zip" >/dev/null 2>&1 || die "not a readable .zip archive: $zip"

	# Refuse absolute paths and ../ escapes rather than trusting unzip's handling.
	local entry
	while IFS= read -r entry; do
		case "$entry" in
			/*|*/../*|../*) die "archive contains an unsafe path: $entry" ;;
		esac
	done < <(unzip -Z1 "$zip")
}

# Extract, then locate the directory that actually holds the site. Zips exported
# from design tools usually wrap everything in one top-level folder, so we look
# for the shallowest index.html and treat its directory as the web root.
extract_zip() {
	local zip="$1" dest="$2"
	unzip -qq -o "$zip" -d "$dest"

	find "$dest" -name '__MACOSX' -type d -prune -exec rm -rf {} + 2>/dev/null || true
	find "$dest" -name '.DS_Store' -type f -delete 2>/dev/null || true

	# Prefer a real index.html, matched case-insensitively.
	local index
	index="$(find "$dest" -iname 'index.html' -type f -printf '%d\t%p\n' 2>/dev/null \
		| sort -n | head -1 | cut -f2-)"

	# Otherwise fall back to the shallowest .html file. Downloads are often named
	# after the project ("Tucson landscaping.html") rather than index.html, so
	# promote that page to the site's entry point.
	if [[ -z "$index" ]]; then
		local page
		page="$(find "$dest" -iname '*.html' -type f -printf '%d\t%p\n' 2>/dev/null \
			| sort -n | head -1 | cut -f2-)"
		if [[ -n "$page" ]]; then
			step "no index.html; using $(basename "$page") as the home page"
			cp "$page" "$(dirname "$page")/index.html"
			index="$(dirname "$page")/index.html"
		fi
	fi

	if [[ -z "$index" ]]; then
		printf '\n%sThe archive contains no .html file. Its contents:%s\n' "$BOLD" "$RESET" >&2
		find "$dest" -mindepth 1 -maxdepth 3 -printf '  %P\n' 2>/dev/null | sort | head -40 >&2
		local total; total="$(find "$dest" -mindepth 1 | wc -l)"
		[[ "$total" -gt 40 ]] && printf '  ... and %s more entries\n' "$((total - 40))" >&2
		echo >&2
		die "no web page found — this does not look like a static website zip"
	fi

	# Case-insensitive match may have found INDEX.HTML; Caddy needs the lowercase name.
	if [[ "$(basename "$index")" != "index.html" ]]; then
		mv "$index" "$(dirname "$index")/index.html"
		index="$(dirname "$index")/index.html"
	fi

	dirname "$index"
}

# ---------------------------------------------------------------- releases ---

list_releases() {
	local dir="$(site_root)/releases"
	[[ -d "$dir" ]] || return 0
	find "$dir" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | sort -r
}

current_release() {
	local link="$(site_root)/current"
	[[ -L "$link" ]] || return 0
	basename "$(readlink -f "$link")"
}

# Flip the symlink in one rename() so no request ever sees a half-built root.
activate_release() {
	local release="$1" root; root="$(site_root)"
	ln -sfn "$root/releases/$release" "$root/current.tmp"
	mv -Tf "$root/current.tmp" "$root/current"
}

prune_releases() {
	local keep="$KEEP_RELEASES" current root n=0 r
	current="$(current_release)"
	root="$(site_root)"
	[[ "$keep" =~ ^[0-9]+$ && "$keep" -gt 0 ]] || keep=5
	while IFS= read -r r; do
		[[ -z "$r" ]] && continue
		n=$((n + 1))
		if [[ $n -gt $keep && "$r" != "$current" ]]; then
			rm -rf "${root:?}/releases/${r:?}"
			step "pruned old release $r"
		fi
	done < <(list_releases)
}

health_check() {
	local port url; port="$(effective_port)"
	url="http://127.0.0.1:$port/"
	local code
	# curl already prints 000 on a connection failure; swallow its exit status so
	# `set -e` cannot abort a deploy that otherwise succeeded.
	code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$url" 2>/dev/null)" || true
	case "$code" in
		200)    ok "health check: $url -> 200" ;;
		000|"") warn "health check: could not reach $url" ;;
		*)      warn "health check: $url -> $code (expected when serving a specific domain)" ;;
	esac
}

# ---------------------------------------------------------------- commands ---

cmd_deploy() {
	local zip="$1"
	require_root
	validate_zip "$zip"
	ensure_deps

	local root; root="$(site_root)"
	local first_run="false"
	[[ -e "$root/current" ]] || first_run="true"

	info "Deploying $(basename "$zip") to $SITE_NAME"

	TMPDIR_DEPLOY="$(mktemp -d)"
	local src release target
	src="$(extract_zip "$zip" "$TMPDIR_DEPLOY/unpacked")"
	local rel; rel="$(realpath --relative-to="$TMPDIR_DEPLOY/unpacked" "$src")"
	if [[ "$rel" == "." ]]; then
		step "web root: top level of the archive"
	else
		step "web root: $rel/ inside the archive"
	fi

	release="$(date +%Y%m%d-%H%M%S)"
	target="$root/releases/$release"
	mkdir -p "$target"
	cp -a "$src/." "$target/"

	chown -R root:root "$target"
	find "$target" -type d -exec chmod 755 {} +
	find "$target" -type f -exec chmod 644 {} +

	local files size
	files="$(find "$target" -type f | wc -l)"
	size="$(du -sh "$target" | cut -f1)"
	ok "staged release $release ($files files, $size)"

	ensure_caddyfile_import
	write_caddy_site
	activate_release "$release"
	ok "activated release $release"
	save_config
	reload_caddy
	prune_releases
	health_check

	echo
	if [[ "$first_run" == "true" ]]; then
		info "Site is live."
	else
		info "Site updated."
	fi
	print_endpoints
}

print_endpoints() {
	local port; port="$(effective_port)"
	local ip; ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
	if [[ "$MODE" == "tunnel" ]]; then
		printf '  local:   http://127.0.0.1:%s\n' "$port"
		if [[ -n "$DOMAIN" ]]; then
			printf '  public:  https://%s %s(via Cloudflare Tunnel)%s\n' "${DOMAIN%% *}" "$DIM" "$RESET"
		fi
		printf '\n  %sTunnel not set up yet? See the Cloudflare Tunnel section of the README.%s\n' "$DIM" "$RESET"
	elif [[ -n "$DOMAIN" ]]; then
		local d
		for d in $DOMAIN; do printf '  public:  https://%s\n' "$d"; done
		printf '  local:   http://%s\n' "${ip:-<pi-ip>}"
	else
		printf '  local:   http://%s%s\n' "${ip:-<pi-ip>}" "$( [[ "$port" == 80 ]] || printf ':%s' "$port")"
	fi
}

cmd_rollback() {
	require_root
	local current previous
	current="$(current_release)"
	[[ -n "$current" ]] || die "nothing is deployed yet"
	previous="$(list_releases | grep -A1 -x -- "$current" | tail -1)"
	[[ -n "$previous" && "$previous" != "$current" ]] \
		|| die "no earlier release to roll back to (only $current is stored)"

	info "Rolling back $current -> $previous"
	activate_release "$previous"
	reload_caddy
	health_check
	ok "now serving $previous"
}

cmd_list() {
	local current r n=0
	current="$(current_release)"
	[[ -n "$current" ]] || { echo "No releases deployed yet."; return 0; }
	printf '%sReleases for %s%s\n' "$BOLD" "$SITE_NAME" "$RESET"
	while IFS= read -r r; do
		[[ -z "$r" ]] && continue
		n=$((n + 1))
		if [[ "$r" == "$current" ]]; then
			printf '  %s%s  <- live%s\n' "$GREEN" "$r" "$RESET"
		else
			printf '  %s\n' "$r"
		fi
	done < <(list_releases)
	[[ $n -eq 0 ]] && echo "  (none)"
	return 0
}

cmd_status() {
	printf '%sConfiguration%s  (%s)\n' "$BOLD" "$RESET" "$CONFIG_FILE"
	printf '  site      %s\n' "$SITE_NAME"
	printf '  domain    %s\n' "${DOMAIN:-(none — served over IP)}"
	printf '  mode      %s\n' "$MODE"
	printf '  port      %s\n' "$(effective_port)"
	printf '  spa       %s\n' "$SPA"
	printf '  keep      %s releases\n' "$KEEP_RELEASES"
	echo
	printf '%sDeployment%s\n' "$BOLD" "$RESET"
	printf '  root      %s/current\n' "$(site_root)"
	printf '  live      %s\n' "$(current_release || echo '(nothing deployed)')"
	printf '  stored    %s release(s)\n' "$(list_releases | grep -c . || true)"
	echo
	printf '%sServices%s\n' "$BOLD" "$RESET"
	local svc
	for svc in caddy cloudflared; do
		if systemctl list-unit-files "$svc.service" >/dev/null 2>&1 \
			&& systemctl cat "$svc" >/dev/null 2>&1; then
			printf '  %-12s %s\n' "$svc" "$(systemctl is-active "$svc" 2>/dev/null)"
		else
			printf '  %-12s %snot installed%s\n' "$svc" "$DIM" "$RESET"
		fi
	done
	echo
	[[ -n "$(current_release)" ]] && health_check
	return 0
}

cmd_reconfigure() {
	require_root
	ensure_deps
	ensure_caddyfile_import
	write_caddy_site
	save_config
	reload_caddy
	info "Configuration rewritten."
	print_endpoints
}

cmd_uninstall() {
	require_root
	printf '%sThis will remove:%s\n' "$BOLD" "$RESET"
	printf '  %s  (all releases)\n' "$(site_root)"
	printf '  %s/%s.caddyfile\n' "$CADDY_SITES_DIR" "$SITE_NAME"
	printf '  %s\n' "$CONFIG_FILE"
	printf 'Caddy itself is left installed. Continue? [y/N] '
	local reply; read -r reply
	[[ "$reply" =~ ^[Yy] ]] || { echo "Aborted."; return 0; }
	rm -rf "$(site_root)"
	rm -f "$CADDY_SITES_DIR/$SITE_NAME.caddyfile" "$CONFIG_FILE"
	systemctl reload caddy 2>/dev/null || systemctl restart caddy 2>/dev/null || true
	ok "removed"
}

# -------------------------------------------------------------------- main ---

SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
ORIGINAL_ARGS=("$@")
DEFAULT_SITE_NAME="$SITE_NAME"

# Pre-scan for --site: which site is being addressed decides which saved
# settings to load, so it has to be known before the real parse below.
prev=""
for arg in "$@"; do
	[[ "$prev" == "--site" ]] && SITE_NAME="$arg"
	prev="$arg"
done
[[ "$SITE_NAME" =~ ^[A-Za-z0-9._-]+$ ]] || die "--site must be alphanumeric (dots, dashes, underscores ok)"

resolve_config_file
load_config

ZIP=""
COMMAND="deploy"

while [[ $# -gt 0 ]]; do
	case "$1" in
		--domain)   DOMAIN="${2:-}"; shift 2 ;;
		--tunnel)   MODE="tunnel"; shift ;;
		--direct)   MODE="direct"; shift ;;
		--port)     LISTEN_PORT="${2:-}"; shift 2 ;;
		--site)     SITE_NAME="${2:-}"; shift 2 ;;
		--spa)      SPA="true"; shift ;;
		--no-spa)   SPA="false"; shift ;;
		--keep)     KEEP_RELEASES="${2:-}"; shift 2 ;;
		--rollback)     COMMAND="rollback"; shift ;;
		--list)         COMMAND="list"; shift ;;
		--status)       COMMAND="status"; shift ;;
		--reconfigure)  COMMAND="reconfigure"; shift ;;
		--uninstall)    COMMAND="uninstall"; shift ;;
		-h|--help)      usage; exit 0 ;;
		-V|--version)   echo "$VERSION"; exit 0 ;;
		-*)         die "unknown option: $1 (try --help)" ;;
		*)
			[[ -z "$ZIP" ]] || die "only one .zip may be given (got '$ZIP' and '$1')"
			ZIP="$1"; shift ;;
	esac
done

[[ "$MODE" == "direct" || "$MODE" == "tunnel" ]] || die "--mode must be direct or tunnel"
[[ -z "$LISTEN_PORT" || "$LISTEN_PORT" =~ ^[0-9]+$ ]] || die "--port must be a number"
[[ "$SITE_NAME" =~ ^[A-Za-z0-9._-]+$ ]] || die "--site must be alphanumeric (dots, dashes, underscores ok)"

case "$COMMAND" in
	deploy)
		[[ -n "$ZIP" ]] || { usage; exit 1; }
		cmd_deploy "$ZIP" ;;
	rollback)     cmd_rollback ;;
	list)         cmd_list ;;
	status)       cmd_status ;;
	reconfigure)  cmd_reconfigure ;;
	uninstall)    cmd_uninstall ;;
esac
