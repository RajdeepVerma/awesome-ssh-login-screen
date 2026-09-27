#!/bin/sh
# awesome-server-motd installer — fastfetch/btop-style SSH login screen for Ubuntu servers.
#
#   curl -fsSL https://raw.githubusercontent.com/RajdeepVerma/awesome-server-motd/main/install.sh | sh
#   curl -fsSL https://raw.githubusercontent.com/RajdeepVerma/awesome-server-motd/main/install.sh | sh -s -- --uninstall
#   sh install.sh [--uninstall]        (from a clone)
#
# Plain POSIX sh, so it works with `| sh` (dash). Uses sudo by itself when not run as root.
#
# What it does:
#   • installs /etc/update-motd.d/01-dashboard (runs on every SSH login via pam_motd)
#   • disables the stock MOTD parts it replaces (chmod -x, files are kept)
#   • moves sshd's "Last login" line into the dashboard (sshd_config.d drop-in)
#   • removes ~/.hushlogin so the MOTD is shown
set -eu

REPO_RAW=https://raw.githubusercontent.com/RajdeepVerma/awesome-server-motd/main
TARGET=/etc/update-motd.d/01-dashboard
SSHD_DROPIN=/etc/ssh/sshd_config.d/50-motd-dashboard.conf
STOCK="00-header 10-help-text 50-motd-news 50-landscape-sysinfo 90-updates-available 91-contract-ua-esm-status 98-reboot-required"

say() { printf '%s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

# root, or elevate each command with sudo (works with `curl | sh`: sudo asks on the terminal)
if [ "$(id -u)" -eq 0 ]; then
  SUDO=""
else
  command -v sudo >/dev/null 2>&1 || die "run as root or install sudo"
  SUDO="sudo"
  $SUDO true || die "sudo is required"   # (not `sudo -v`: that prompts even with NOPASSWD)
fi

[ -d /etc/update-motd.d ] || die "no /etc/update-motd.d — this needs Ubuntu (update-motd + pam_motd)"
command -v bash >/dev/null 2>&1 || die "bash is required for the dashboard itself"

# home of the human user (not root when run through sudo)
if [ -n "${SUDO_USER:-}" ]; then
  USER_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
else
  USER_HOME=${HOME:-}
fi

# directory of this script when run from a clone; empty when piped (curl | sh)
HERE=""
case "$0" in
  *install.sh) [ -f "$0" ] && HERE=$(cd "$(dirname "$0")" && pwd) ;;
esac

reload_sshd() {
  $SUDO sshd -t || { say "sshd config test failed — not reloading" >&2; return 1; }
  $SUDO systemctl reload ssh 2>/dev/null || $SUDO systemctl reload sshd
}

if [ "${1:-}" = "--uninstall" ]; then
  $SUDO rm -f "$TARGET"
  $SUDO rm -rf /var/cache/motd-dashboard
  for f in $STOCK; do
    if [ -e "/etc/update-motd.d/$f" ]; then $SUDO chmod +x "/etc/update-motd.d/$f"; fi
  done
  if [ -f /etc/default/motd-news ]; then $SUDO sed -i 's/^ENABLED=0/ENABLED=1/' /etc/default/motd-news; fi
  if [ -f "$SSHD_DROPIN" ]; then $SUDO rm -f "$SSHD_DROPIN"; reload_sshd; fi
  say "✔ awesome-server-motd removed, stock Ubuntu login screen restored"
  exit 0
fi

# use the copy next to this script (git clone), otherwise download it
if [ -n "$HERE" ] && [ -f "$HERE/01-dashboard" ]; then
  say "→ installing $TARGET (from $HERE)"
  $SUDO install -m 755 -o root -g root "$HERE/01-dashboard" "$TARGET"
else
  say "→ installing $TARGET (from $REPO_RAW)"
  tmp=$(mktemp)
  trap 'rm -f "$tmp"' EXIT
  if command -v curl >/dev/null 2>&1; then curl -fsSL "$REPO_RAW/01-dashboard" -o "$tmp"
  else wget -qO "$tmp" "$REPO_RAW/01-dashboard"; fi
  bash -n "$tmp" || die "downloaded dashboard failed a syntax check"
  $SUDO install -m 755 -o root -g root "$tmp" "$TARGET"
fi
$SUDO mkdir -p /var/cache/motd-dashboard

say "→ disabling stock MOTD parts it replaces"
for f in $STOCK; do
  if [ -e "/etc/update-motd.d/$f" ]; then $SUDO chmod -x "/etc/update-motd.d/$f"; fi
done
if [ -f /etc/default/motd-news ]; then $SUDO sed -i 's/^ENABLED=1/ENABLED=0/' /etc/default/motd-news; fi

# "Last login" is read from /var/log/auth.log; only hide sshd's own line if that log exists
if [ -f /var/log/auth.log ]; then
  say "→ moving 'Last login' into the dashboard"
  printf '# Last login is shown by the MOTD dashboard (%s)\nPrintLastLog no\n' "$TARGET" | $SUDO tee "$SSHD_DROPIN" >/dev/null
  reload_sshd
else
  say "! /var/log/auth.log not found (no rsyslog) — keeping sshd's own Last login line"
fi

if [ -n "$USER_HOME" ] && [ -f "$USER_HOME/.hushlogin" ]; then
  say "→ removing $USER_HOME/.hushlogin"
  $SUDO rm -f "$USER_HOME/.hushlogin"
fi

say "✔ done — preview:"
$SUDO run-parts --lsbsysinit /etc/update-motd.d
