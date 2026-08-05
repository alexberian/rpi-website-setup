# rpi-website-setup

Deploy a static website to a Raspberry Pi from a `.zip`, with one command.

```bash
sudo setup-website.sh newfiles.zip
```

That's the whole workflow. The first run installs and configures a web server;
every run after that is an update. Releases are kept side by side and swapped in
atomically, so a deploy is instant and rolling back is one command.

---

## Quick start

On the Pi:

```bash
git clone https://github.com/alexberian/rpi-website-setup.git
cd rpi-website-setup
sudo ./install.sh          # optional: puts setup-website.sh on your PATH
```

Then, from anywhere:

```bash
scp site.zip pi@raspberrypi.local:~     # from your laptop
ssh pi@raspberrypi.local
sudo setup-website.sh site.zip
```

Open `http://<pi-ip>` and the site is there.

To put it on a real domain, see [Going public with Cloudflare](#going-public-with-cloudflare).

---

## What the zip should contain

A plain static site — `index.html` plus whatever CSS, JS, and images go with it.
Exactly what Claude's design tools hand you.

You do **not** need to flatten the archive first. If everything is wrapped in a
top-level folder, the script finds the shallowest `index.html` and treats its
directory as the web root. `__MACOSX` and `.DS_Store` junk is stripped.

The archive is rejected if it has no `index.html`, isn't a valid zip, or contains
absolute paths or `../` escapes.

---

## Commands

| Command | What it does |
| --- | --- |
| `setup-website.sh site.zip` | Deploy or update. |
| `setup-website.sh --rollback` | Switch back to the previous release. |
| `setup-website.sh --list` | List stored releases, newest first, marking the live one. |
| `setup-website.sh --status` | Config, live release, service health. |
| `setup-website.sh --reconfigure` | Rewrite the server config from saved settings. |
| `setup-website.sh --uninstall` | Remove the site and its config (asks first). |

All of them take `sudo`.

### Options

| Option | Meaning |
| --- | --- |
| `--domain <d>` | Domain(s) to serve. Space-separate several. |
| `--tunnel` / `--direct` | Serve on localhost for a Cloudflare Tunnel, or on a public port. |
| `--port <n>` | Listen port. Defaults to 80 (direct) or 8080 (tunnel). |
| `--site <name>` | Name used for paths, so you can host more than one site. |
| `--spa` / `--no-spa` | Fall back to `/index.html` for unknown paths. |
| `--keep <n>` | How many old releases to retain. Default 5. |

Options are saved to `/etc/setup-website/<site>.conf` the first time you pass
them, so later deploys are just `sudo setup-website.sh newfiles.zip`.

---

## Going public with Cloudflare

Two options. The tunnel is the better one for a Pi at home.

### Cloudflare Tunnel (recommended)

An outbound-only connection from the Pi to Cloudflare. **No port forwarding, no
static IP, no router changes, and nothing on your home network is exposed.**
Cloudflare terminates HTTPS, so the Pi never handles certificates.

Easiest path — create the tunnel in the dashboard and paste its token:

1. Go to `one.dash.cloudflare.com` → **Networks** → **Tunnels** → **Create a tunnel** → **Cloudflared**.
2. Name it, then copy the connector token from the install command it shows you
   (the long `eyJhIjoi...` string).
3. On the Pi:

   ```bash
   sudo ./cloudflare-tunnel.sh --token eyJhIjoi...
   sudo setup-website.sh site.zip --tunnel --domain example.com
   ```

4. Back in the dashboard, add a **Public Hostname**: pick your domain, service
   type **HTTP**, URL `localhost:8080`.

Or let the CLI do the DNS wiring for you:

```bash
sudo ./cloudflare-tunnel.sh --name mypi --hostname example.com
sudo setup-website.sh site.zip --tunnel --domain example.com
```

This prints a link to authorize the Pi with your Cloudflare account, creates the
tunnel, adds the DNS record, and installs the service.

Check on it any time with `sudo ./cloudflare-tunnel.sh --status`.

### Direct, with port forwarding

If you'd rather forward ports 80 and 443 from your router to the Pi:

```bash
sudo setup-website.sh site.zip --domain example.com
```

Caddy obtains and renews a Let's Encrypt certificate automatically. Point an
`A` record at your public IP. If you keep Cloudflare's proxy on (orange cloud),
set **SSL/TLS → Overview → Full (strict)** so Cloudflare validates the Pi's real
certificate. Leave it on "Flexible" and you get a redirect loop.

---

## How it works

```
/var/www/<site>/
├── releases/
│   ├── 20260805-141233/     <- previous
│   └── 20260805-152901/     <- newest
└── current -> releases/20260805-152901
```

Each deploy extracts into a fresh timestamped directory, then repoints `current`
with a single atomic rename. No request ever sees a half-written site, and the
previous release stays on disk for `--rollback`. Older ones are pruned past
`--keep`.

The server is [Caddy](https://caddyserver.com/), installed from its official apt
repository. The generated config lives in `/etc/caddy/sites/<site>.caddyfile`;
`/etc/caddy/Caddyfile` is reduced to an `import` of that directory, and anything
that was there before is backed up alongside it first. Config is validated with
`caddy validate` before the reload, so a bad config never takes the site down.

The generated config sets compression, `nosniff` and referrer-policy headers,
long cache lifetimes for static assets with `no-cache` on HTML, and rolling logs
in `/var/log/caddy/<site>.log`.

### Files it touches

| Path | Purpose |
| --- | --- |
| `/var/www/<site>/` | Releases and the `current` symlink. |
| `/etc/setup-website/<site>.conf` | Saved settings, one file per site. |
| `/etc/caddy/sites/<site>.caddyfile` | Generated server config. |
| `/etc/caddy/Caddyfile` | Reduced to an import; originals backed up to `.bak-<timestamp>`. |
| `/var/log/caddy/<site>.log` | Access logs. |
| `/etc/cloudflared/` | Tunnel config, if you use one. |

---

## Hosting more than one site

`--site` namespaces everything — releases, config, and server block:

```bash
sudo setup-website.sh blog.zip  --site blog  --domain blog.example.com
sudo setup-website.sh shop.zip  --site shop  --domain shop.example.com
```

Caddy routes by hostname, so both share port 443. Settings are stored per site,
so updating one never disturbs the other:

```bash
sudo setup-website.sh newblog.zip --site blog     # keeps blog.example.com
```

With exactly one site configured, `--site` is optional and that site is used.
With several, omitting it warns and lists the names.

---

## Troubleshooting

**Deploy succeeded but the page doesn't load.**
`sudo setup-website.sh --status` shows the live release and service state.
Then `sudo journalctl -u caddy -n 50`.

**Health check reports something other than 200.**
Expected when serving a domain in direct mode — the check requests
`localhost`, which doesn't match the configured hostname. Test with the real
name instead: `curl -I https://example.com`.

**Domain resolves but times out.** In direct mode, ports 80 and 443 have to be
forwarded to the Pi. In tunnel mode, check `sudo ./cloudflare-tunnel.sh --status`.

**Caddy won't start after an edit.** Run `caddy validate --config
/etc/caddy/Caddyfile --adapter caddyfile` to see the parse error, or
`sudo setup-website.sh --reconfigure` to regenerate the file from saved settings.

**A deploy broke the site.** `sudo setup-website.sh --rollback`.

---

## Requirements

Raspberry Pi OS or any Debian/Ubuntu-based system, with `sudo` and internet
access on first run. Everything else — Caddy, `unzip`, `cloudflared` — is
installed for you.

---

## License

MIT. See [LICENSE](LICENSE).
