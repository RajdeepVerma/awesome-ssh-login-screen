# awesome-server-motd

A fastfetch / btop-style **SSH login screen** for Ubuntu servers — system info, live CPU/RAM/network, Docker stacks, and security status, shown every time you SSH in.

```

╭─ web ─────────────────────────────────────────────────────────┤ 10.0.0.12 ├──╮
│                                   OS       Ubuntu 24.04.1 LTS aarch64        │
│                    .ooo.          Host     KVM Virtual Machine               │
│             .:looo looo:          Kernel   6.14.0-1017-oracle                │
│           .looo''   ''            Uptime   142d 0h 2m                        │
│           'ol'       :oo.         Packages 994 (dpkg)                        │
│       .ooo.           ooo         Users    deploy                            │
│       'ooo'           ooo         CPU      Neoverse-N1 × 4                   │
│           .ol.       :oo'         Procs    326  ·  2 ssh sessions            │
│           'looo..   ..            Public   203.0.113.24                      │
│             ':looo looo:          Docker   28.1.1                            │
│                    'ooo'          Time     Sun 27 Sep, 09:48 UTC             │
│                                           ████████████████████████           │
│                                           ████████████████████████           │
╰──────────────────────────────────────────────────────────────────────────────╯

╭─ resources ──────────────────────────────────────────────────────────────────╮
│ cpu  ■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■  15%  of 4 cores                   │
│ ram  ■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■  21%  4.9G of 23G used             │
│ net  ↓ 2.6K/s   ↑ 2.8K/s    total  ↓ 30G  ↑ 25G                              │
╰──────────────────────────────────────────────────────────────────────────────╯

╭─ docker ─────────────────────────────────────────┤ 4/4 running · 2 stacks ├──╮
│ ◆ nginx-proxy-manager              /opt/stacks/nginx-proxy-manager       1/1 │
│  └─● nginx-proxy-manager-app… jc21/nginx-proxy-manager     host       12d    │
│                                                                              │
│ ◆ myapp                            /opt/stacks/myapp                     3/3 │
│  ├─● myapp-web                you/myapp                    :8080       3d    │
│  ├─●♥myapp-postgres           postgres:17-alpine                       3d    │
│  └─●♥myapp-redis              redis:7.2                                3d    │
╰──────────────────────────────────────────────────────────────────────────────╯

╭─ status ─────────────────────────────────────────────────────────────────────╮
│ ssh      ▲ 284 failed logins from 31 IPs in 24h · top 198.51.100.7           │
│ updates  ▲ 136 packages · apt list --upgradable                              │
│ reboot   ✖ required libc6 linux-base linux-image-6.17.0-1011-oracle          │
╰──────────────────────────────────────────────────────────────────────────────╯

  Last login: Sun Sep 27 09:30:49 2026 from 10.0.0.12
```
<sub>(rendered in true color — orange logo, green→yellow→red meters, colored status dots)</sub>

## Features

- **Header** — compact ASCII Ubuntu logo with OS, host, kernel, uptime, packages, users, CPU, processes, public IP, Docker version and a two-row color palette
- **Resources** — real CPU usage and network speed (sampled over ~0.2 s), RAM, total traffic since boot
- **Docker** — containers grouped by compose project, with status dot (running / starting / unhealthy / stopped), ♥ for passing health checks, image, published ports and uptime. Hidden when Docker isn't installed
- **Status** — failed SSH logins in the last 24 h (with the top offending IP), pending updates, reboot-required with the packages that need it
- **Last login** line in the same style, taken from `/var/log/auth.log`
- **Flicker-free & fast** — built in memory and written in a single write; ~0.3 s, no blocking network calls (public IP is cached and refreshed in the background)

## Install

One command — run it as your normal user, it asks for `sudo` when needed:

```sh
curl -fsSL https://raw.githubusercontent.com/RajdeepVerma/awesome-server-motd/main/install.sh | sh
```

No curl? `wget -qO- https://raw.githubusercontent.com/RajdeepVerma/awesome-server-motd/main/install.sh | sh`

Or from a clone:

```bash
git clone https://github.com/RajdeepVerma/awesome-server-motd.git
cd awesome-server-motd && sh install.sh
```

Several servers at once:

```bash
for h in web01 web02 db01; do
  ssh -t "$h" 'curl -fsSL https://raw.githubusercontent.com/RajdeepVerma/awesome-server-motd/main/install.sh | sh'
done
```

Re-running the installer updates to the latest version. Open a new SSH session to see it.

## What the installer changes

| Change | Why |
|---|---|
| Adds `/etc/update-motd.d/01-dashboard` | the dashboard; `pam_motd` runs it on every SSH login |
| `chmod -x` on stock `00-header`, `10-help-text`, `50-motd-news`, `50-landscape-sysinfo`, `90-updates-available`, `91-contract-ua-esm-status`, `98-reboot-required` | the dashboard replaces them — files are kept, nothing is deleted |
| Adds `/etc/ssh/sshd_config.d/50-motd-dashboard.conf` with `PrintLastLog no`, then `sshd -t` and reload | the "Last login" line is shown by the dashboard instead (skipped if `/var/log/auth.log` doesn't exist) |
| Removes your `~/.hushlogin` | a hushlogin file hides the MOTD |

Existing SSH sessions are not affected by the reload.

## Uninstall

```bash
curl -fsSL https://raw.githubusercontent.com/RajdeepVerma/awesome-server-motd/main/install.sh | sh -s -- --uninstall
```

Restores the stock Ubuntu login screen and sshd's own "Last login" line.

## Requirements

- Ubuntu 22.04 / 24.04 (uses `update-motd` + `pam_motd`), amd64 or arm64
- A true-color terminal (iTerm2, Windows Terminal, GNOME Terminal, Alacritty, kitty, WezTerm, …), 80+ columns
- `/var/log/auth.log` (rsyslog, default on Ubuntu) for failed-login counts and the last-login line
- Optional: Docker for the docker panel. Compose stacks under `/opt/stacks/<name>` show their folder

## Customize

Everything lives in one bash script: [`01-dashboard`](01-dashboard).

- **Colors** — the palette block at the top (`FG`, `AC`, `OR`, `GR`, `YE`, `RD`, …)
- **Width** — `W=80`
- **Logo** — the `logo=( … )` array
- **Panels** — each panel is a self-contained `# ── … panel ──` section; delete one to hide it

Preview without logging in: `sudo bash /etc/update-motd.d/01-dashboard`

## License

MIT
