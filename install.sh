#!/bin/sh
# awesome-ssh-login-screen installer — fastfetch/btop-style SSH login screen for any Linux server.
#
#   curl -fsSL https://raw.githubusercontent.com/RajdeepVerma/awesome-ssh-login-screen/main/install.sh | sh
#   curl -fsSL https://raw.githubusercontent.com/RajdeepVerma/awesome-ssh-login-screen/main/install.sh | sh -s -- --uninstall
#   sh install.sh [--uninstall] [--mode motd|profile]      (from a clone)
#
# Plain POSIX sh, so it works with `| sh`. Uses sudo by itself when not run as root.
#
# Two ways to hook into SSH logins:
#   motd     Debian / Ubuntu: pam_motd runs /etc/update-motd.d/* on every SSH login
#   profile  everything else: /etc/profile.d script, once per interactive SSH login shell
set -eu

REPO_RAW=https://raw.githubusercontent.com/RajdeepVerma/awesome-ssh-login-screen/main
SHARE=/usr/local/share/awesome-ssh-login-screen
MOTD_HOOK=/etc/update-motd.d/01-awesome-ssh-login-screen
PROFILE_HOOK=/etc/profile.d/zz-awesome-ssh-login-screen.sh
SSHD_DROPIN=/etc/ssh/sshd_config.d/50-awesome-ssh-login-screen.conf
STOCK="00-header 10-help-text 10-uname 50-motd-news 50-landscape-sysinfo 90-updates-available 91-contract-ua-esm-status 98-reboot-required"
# files from the earlier "motd-dashboard" versions
LEGACY="/etc/update-motd.d/01-dashboard /etc/ssh/sshd_config.d/50-motd-dashboard.conf /var/cache/motd-dashboard"

say() { printf '%s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

ACTION=install MODE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --uninstall) ACTION=uninstall ;;
    --mode) shift; MODE=${1:-} ;;
    --mode=*) MODE=${1#--mode=} ;;
    *) die "unknown option: $1" ;;
  esac
  shift
done

# root, or elevate each command with sudo (works with `curl | sh`: sudo asks on the terminal)
if [ "$(id -u)" -eq 0 ]; then
  SUDO=""
else
  have sudo || die "run as root or install sudo"
  SUDO="sudo"
  $SUDO true || die "sudo is required"   # (not `sudo -v`: that prompts even with NOPASSWD)
fi

# home of the human user (not root when run through sudo)
if [ -n "${SUDO_USER:-}" ]; then USER_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
else USER_HOME=${HOME:-}; fi

# directory of this script when run from a clone; empty when piped (curl | sh)
HERE=""
case "$0" in *install.sh) [ -f "$0" ] && HERE=$(cd "$(dirname "$0")" && pwd) ;; esac

reload_sshd() {
  if ! $SUDO sh -c 'PATH=$PATH:/usr/sbin:/sbin; sshd -t'; then say "! sshd config test failed — not reloading" >&2; return 1; fi
  $SUDO systemctl reload ssh 2>/dev/null || $SUDO systemctl reload sshd 2>/dev/null ||
    $SUDO rc-service sshd reload 2>/dev/null || $SUDO sv reload sshd 2>/dev/null ||
    say "! could not reload sshd — restart it to apply the Last login change"
}

remove_all() {
  $SUDO rm -rf "$SHARE" /var/cache/awesome-ssh-login-screen $LEGACY
  $SUDO rm -f "$MOTD_HOOK" "$PROFILE_HOOK"
  if [ -d /etc/update-motd.d ]; then
    for f in $STOCK; do [ -e "/etc/update-motd.d/$f" ] && $SUDO chmod +x "/etc/update-motd.d/$f"; done
  fi
  if [ -f /etc/default/motd-news ]; then $SUDO sed -i 's/^ENABLED=0/ENABLED=1/' /etc/default/motd-news; fi
}

if [ "$ACTION" = uninstall ]; then
  had_dropin=""; for f in "$SSHD_DROPIN" /etc/ssh/sshd_config.d/50-motd-dashboard.conf; do [ -f "$f" ] && had_dropin=1; done
  remove_all
  $SUDO rm -f "$SSHD_DROPIN"
  [ -n "$had_dropin" ] && reload_sshd
  say "✔ awesome-ssh-login-screen removed, stock login screen restored"
  exit 0
fi

# ── checks ───────────────────────────────────────────────────────────────
have bash || die "bash is required (e.g. apk add bash)"
have awk || die "awk is required"
if [ -z "$MODE" ]; then
  if [ -d /etc/update-motd.d ] && grep -qs 'pam_motd.so' /etc/pam.d/sshd; then MODE=motd; else MODE=profile; fi
fi
case "$MODE" in motd|profile) ;; *) die "--mode must be motd or profile" ;; esac
. /etc/os-release 2>/dev/null || true
say "→ ${PRETTY_NAME:-Linux} — using $MODE mode"

# ── files ────────────────────────────────────────────────────────────────
$SUDO mkdir -p "$SHARE"
fetch() {  # fetch <file> -> $SHARE/<file>, from the clone or from GitHub
  if [ -n "$HERE" ] && [ -f "$HERE/$1" ]; then
    $SUDO install -m "$2" "$HERE/$1" "$SHARE/$1"
  else
    tmp=$(mktemp)
    if have curl; then curl -fsSL "$REPO_RAW/$1" -o "$tmp"; else wget -qO "$tmp" "$REPO_RAW/$1"; fi
    $SUDO install -m "$2" "$tmp" "$SHARE/$1"; rm -f "$tmp"
  fi
}
say "→ installing $SHARE (from ${HERE:-$REPO_RAW})"
fetch dashboard.sh 755
fetch logos.txt 644
bash -n "$SHARE/dashboard.sh" || die "dashboard.sh failed a syntax check"

# remove the other hook and anything from older versions
$SUDO rm -rf $LEGACY
if [ "$MODE" = motd ]; then $SUDO rm -f "$PROFILE_HOOK"; else $SUDO rm -f "$MOTD_HOOK"; fi

# ── hook into SSH logins ─────────────────────────────────────────────────
if [ "$MODE" = motd ]; then
  say "→ adding $MOTD_HOOK"
  printf '#!/bin/sh\n# awesome-ssh-login-screen (run by pam_motd on SSH login)\nexec bash %s/dashboard.sh\n' "$SHARE" |
    $SUDO tee "$MOTD_HOOK" >/dev/null
  $SUDO chmod 755 "$MOTD_HOOK"
  say "→ disabling the stock MOTD parts it replaces (chmod -x, files kept)"
  for f in $STOCK; do [ -e "/etc/update-motd.d/$f" ] && $SUDO chmod -x "/etc/update-motd.d/$f"; done
  if [ -f /etc/default/motd-news ]; then $SUDO sed -i 's/^ENABLED=1/ENABLED=0/' /etc/default/motd-news; fi
else
  say "→ adding $PROFILE_HOOK"
  $SUDO tee "$PROFILE_HOOK" >/dev/null <<EOF
# awesome-ssh-login-screen: show the dashboard once per interactive SSH login
if [ -n "\${SSH_CONNECTION:-}" ] && [ -z "\${AWESOME_SSH_LOGIN_SCREEN:-}" ] && [ -t 1 ]; then
  case \$- in *i*)
    export AWESOME_SSH_LOGIN_SCREEN=1
    bash $SHARE/dashboard.sh --profile
  ;; esac
fi
EOF
  $SUDO chmod 644 "$PROFILE_HOOK"
fi

# ── "Last login" in the dashboard's style instead of sshd's plain line ──
# only when sshd reads sshd_config.d (RHEL 8 doesn't) and the dashboard has a login source
has_include=""; grep -qsiE '^[[:space:]]*Include[[:space:]].*sshd_config\.d' /etc/ssh/sshd_config && has_include=1
has_source=""
for f in /var/log/auth.log /var/log/secure; do [ -f "$f" ] && has_source=1; done
have journalctl && has_source=1
[ "$MODE" = profile ] && have last && has_source=1
if [ -n "$has_include" ] && [ -n "$has_source" ]; then
  say "→ moving 'Last login' into the dashboard"
  printf '# Last login is shown by awesome-ssh-login-screen\nPrintLastLog no\n' | $SUDO tee "$SSHD_DROPIN" >/dev/null
  $SUDO touch "$SHARE/show-last-login"
  reload_sshd || true
else
  $SUDO rm -f "$SSHD_DROPIN"
  say "! keeping sshd's own 'Last login' line (no sshd_config.d include or no login log)"
fi

if [ -n "$USER_HOME" ] && [ -f "$USER_HOME/.hushlogin" ]; then
  say "→ removing $USER_HOME/.hushlogin"
  $SUDO rm -f "$USER_HOME/.hushlogin"
fi

say "✔ done — preview:"
if [ "$MODE" = motd ]; then $SUDO bash "$SHARE/dashboard.sh"; else bash "$SHARE/dashboard.sh" --profile; fi
