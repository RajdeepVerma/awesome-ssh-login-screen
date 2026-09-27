#!/bin/bash
# awesome-ssh-login-screen — fastfetch-style header + btop-style panels, shown on SSH login.
#
#   dashboard.sh            run by pam_motd / update-motd (Debian, Ubuntu) — runs as root
#   dashboard.sh --profile  run from /etc/profile.d on other distros — runs as the user
#
# Rendered into a buffer and written in ONE write at the end (no flicker).
# Helpers write into variables (printf -v) instead of $(...) to avoid forks — keeps login fast.
# Nothing blocks on the network or on slow package managers: those values are cached and
# refreshed in the background.
# https://github.com/RajdeepVerma/awesome-ssh-login-screen

MODE=motd; [ "${1:-}" = "--profile" ] && MODE=profile
SELF_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SHARE=/usr/local/share/awesome-ssh-login-screen

# a UTF-8 locale so ${#var} counts characters (box drawing, logos)
{ for loc in C.UTF-8 C.utf8 en_US.UTF-8 en_US.utf8; do export LC_ALL=$loc; x=█; ((${#x} == 1)) && break; done; } 2>/dev/null

if [ -w /var/cache ]; then CACHE_DIR=/var/cache/awesome-ssh-login-screen
else CACHE_DIR=${XDG_CACHE_HOME:-$HOME/.cache}/awesome-ssh-login-screen; fi
mkdir -p "$CACHE_DIR" 2>/dev/null

# ── palette (catppuccin-ish) ─────────────────────────────────────────────
R=$'\e[0m' B=$'\e[1m'
FG=$'\e[38;2;205;214;244m'   # text
MU=$'\e[38;2;127;132;156m'   # muted
BD=$'\e[38;2;88;91;112m'     # borders / empty meter
AC=$'\e[38;2;137;180;250m'   # accent
OR=$'\e[38;2;250;179;135m'   # peach
GR=$'\e[38;2;166;227;161m' YE=$'\e[38;2;249;226;175m' RD=$'\e[38;2;243;139;168m'

W=80            # total width
IW=$((W - 4))   # inner width of a panel
OUT=""
emit() { OUT+="$1"$'\n'; }
vlen() {                                    # visible length, ANSI stripped -> VL
  local x=$1 pre rest                       # (loop is ~30x faster than an extglob ${//})
  while [[ $x == *$'\e['* ]]; do pre=${x%%$'\e['*}; rest=${x#*$'\e['}; x=$pre${rest#*m}; done
  VL=${#x}
}
rep() { local s; printf -v s "%*s" "$2" ""; REP="${s// /$1}"; }      # -> REP
fit() { local s=$1; ((${#s} > $2)) && s="${s:0:$2-1}…"; printf -v FIT "%-$2s" "$s"; }  # -> FIT
cut_to() { local s=$1; ((${#s} > $2)) && s="${s:0:$2-1}…"; CUT=$s; }                  # -> CUT
human() {                                                           # bytes -> HUM
  local v=$1 u=(B K M G T P) i=0
  while ((v >= 10240 && i < 5)); do v=$((v / 1024)); i=$((i + 1)); done
  if ((v >= 1024)); then HUM="$((v / 1024)).$((v % 1024 * 10 / 1024))${u[i + 1]}"; else HUM="${v}${u[i]}"; fi
}
have() { command -v "$1" >/dev/null 2>&1; }
now_us() { if [ -n "${EPOCHREALTIME:-}" ]; then NOW=${EPOCHREALTIME/[.,]/}; else NOW=$(date +%s%6N); fi; }
printf -v NOW_S '%(%s)T' -1

# cached <key> <ttl-minutes> <command…>  -> CV (last value; refreshed in the background when stale)
cached() {
  local f=$CACHE_DIR/$1 ttl=$2; shift 2
  CV=""; [ -r "$f" ] && CV=$(<"$f")
  if [ -z "$(find "$f" -mmin -"$ttl" 2>/dev/null)" ]; then
    ( "$@" >"$f.tmp" 2>/dev/null && mv "$f.tmp" "$f" ) </dev/null >/dev/null 2>&1 &
  fi
}

panel_top() { # panel_top "title" ["right text"]
  local t=" ${B}${AC}$1${R}${BD} " rt="" tl rl
  [ -n "$2" ] && rt="${BD}┤${R} $2 ${BD}├"
  vlen "$t"; tl=$VL; vlen "$rt"; rl=$VL
  rep ─ $((W - 4 - tl - rl))
  emit "${BD}╭─${t}${REP}${rt}─╮${R}"
}
panel_row() { vlen "$1"; local pad=$((IW - VL)); ((pad < 0)) && pad=0; emit "${BD}│${R} $1$(printf '%*s' $pad '') ${BD}│${R}"; }
panel_bot() { rep ─ $((W - 2)); emit "${BD}╰${REP}╯${R}"; }

# btop-style meter: green → yellow → red by position   -> MET
meter() {
  local p=$1 n=$2 f i c last="" s=""
  ((p > 100)) && p=100; f=$(((p * n + 50) / 100))
  for ((i = 0; i < f; i++)); do
    if ((i * 100 / n >= 85)); then c=$RD; elif ((i * 100 / n >= 60)); then c=$YE; else c=$GR; fi
    [ "$c" != "$last" ] && s+="$c" && last=$c
    s+='■'
  done
  rep '■' $((n - f)); MET="${s}${BD}${REP}${R}"
}

# ── first snapshot for cpu % / net speed (second one is taken at the resources panel) ──
IFACE=""; have ip && read -r _ _ _ _ IFACE _ < <(ip -4 -o route show default 2>/dev/null)
snap() {
  local c u n s i io irq sirq st
  read -r c u n s i io irq sirq st _ </proc/stat
  CTOT=$((u + n + s + i + io + irq + sirq + st)); CIDLE=$((i + io))
  RX=0 TX=0
  [ -n "$IFACE" ] && while read -r ifn rx _ _ _ _ _ _ _ tx _; do [ "$ifn" = "$IFACE:" ] && { RX=$rx TX=$tx; break; }; done </proc/net/dev
}
snap; CTOT0=$CTOT CIDLE0=$CIDLE RX0=$RX TX0=$TX; now_us; T0=$NOW

# ── gather ───────────────────────────────────────────────────────────────
ID="" ID_LIKE="" PRETTY_NAME=""
[ -r /etc/os-release ] && . /etc/os-release
HOST=${HOSTNAME%%.*}
read -r _ _ KERNEL _ </proc/version
ARCH=$(uname -m)
read -r up _ </proc/uptime; up=${up%.*}
UPTIME="$((up / 86400))d $((up % 86400 / 3600))h $((up % 3600 / 60))m"
CORES=$(nproc 2>/dev/null || grep -c ^processor /proc/cpuinfo)
CPU=""; have lscpu && CPU=$(lscpu 2>/dev/null | awk -F: '/Model name/{gsub(/^ +/,"",$2); print $2; exit}')
[ -z "$CPU" ] && CPU=$(awk -F: '/^(model name|Hardware|cpu model)/{gsub(/^ +/,"",$2); print $2; exit}' /proc/cpuinfo)
VIRT=""; [ -r /sys/class/dmi/id/product_name ] && read -r VIRT </sys/class/dmi/id/product_name
PROCS=$(ls -d /proc/[0-9]* 2>/dev/null | wc -l)
declare -A seen; USERS="" SESS=0
while read -r u _; do SESS=$((SESS + 1)); [ -n "${seen[$u]:-}" ] || { seen[$u]=1; USERS+="${USERS:+ }$u"; }; done < <(who 2>/dev/null)
LAN=""; have ip && read -r _ _ _ _ _ _ LAN _ < <(ip -4 -o route get 1.1.1.1 2>/dev/null)
[ -z "$LAN" ] && LAN=$(hostname -I 2>/dev/null | awk '{print $1}')

# packages — fast managers directly, rpm (slow) / snap / flatpak cached
PKGS=""
add_pkgs() { [ -n "$1" ] && [ "$1" != 0 ] && PKGS+="${PKGS:+, }$1 ($2)"; }
if have dpkg-query; then add_pkgs "$(dpkg-query -f '.\n' -W 2>/dev/null | wc -l)" dpkg; fi
if have pacman; then add_pkgs "$(pacman -Qq 2>/dev/null | wc -l)" pacman; fi
if have apk; then add_pkgs "$(apk info 2>/dev/null | wc -l)" apk; fi
if have xbps-query; then add_pkgs "$(xbps-query -l 2>/dev/null | wc -l)" xbps; fi
if have rpm && ! have dpkg-query; then cached pkgs-rpm 60 sh -c 'rpm -qa | wc -l'; add_pkgs "$CV" rpm; fi
if have flatpak; then cached pkgs-flatpak 60 sh -c 'flatpak list --app | wc -l'; add_pkgs "$CV" flatpak; fi
if have snap; then cached pkgs-snap 60 sh -c 'snap list 2>/dev/null | tail -n +2 | wc -l'; add_pkgs "$CV" snap; fi

cached public_ip 60 curl -4 -fsS -m 3 https://ifconfig.me; PUB=$CV

HAVE_DOCKER=0
if have docker && DPS=$(docker ps -a --format '{{.Label "com.docker.compose.project"}}|{{.Names}}|{{.Image}}|{{.State}}|{{.Status}}|{{.Ports}}|{{.Networks}}' 2>/dev/null); then
  HAVE_DOCKER=1
  DVER=$(docker version -f '{{.Server.Version}}' 2>/dev/null)
fi

# ── logo: this distro's ID, then ID_LIKE, then generic tux ───────────────
LOGOS=""
for f in "$SHARE/logos.txt" "$SELF_DIR/logos.txt"; do [ -r "$f" ] && { LOGOS=$f; break; }; done
logo=() LW=0
if [ -n "$LOGOS" ]; then
  mapfile -t blk < <(awk -v want="${ID,,} ${ID_LIKE,,} linux" '
    BEGIN { n = split(want, w, " "); for (i = 1; i <= n; i++) if (!(w[i] in rank)) rank[w[i]] = i; best = n + 1 }
    /^@ / { b++; for (i = 2; i <= NF; i++) if (($i in rank) && rank[$i] < best) { best = rank[$i]; pick = b }; next }
    b     { body[b] = body[b] $0 "\n" }
    END   { if (pick) printf "%s", body[pick] }' "$LOGOS")
  if ((${#blk[@]} > 1)); then
    read -r -a lcol <<<"${blk[0]#= }"
    for l in "${blk[@]:1}"; do
      v=${l//\$[0-9]/}; ((${#v} > LW)) && LW=${#v}
      for n in 1 2 3 4 5 6 7 8 9; do l=${l//\$$n/$'\e['${lcol[n - 1]:-39}m}; done
      logo+=($'\e['"${lcol[0]:-39}m${l}"); logow+=(${#v})
    done
  fi
fi

# ── header (fastfetch style: logo left, info right) ──────────────────────
IC=$((LW + 5 < 34 ? 34 : LW + 5))   # column where the info starts
ML=$(((IC - 3 - LW) / 2))            # logo left margin
VW=$((IW - IC - 9))                  # room for an info value
k() { cut_to "$2" "$VW"; printf -v KV "${AC}${B}%-9s${R}${FG}%s${R}" "$1" "$CUT"; }
info=()
k OS "${PRETTY_NAME:-Linux}";         info+=("$KV")
[ -n "$VIRT" ] && { k Host "$VIRT"; info+=("$KV"); }
k Kernel "$KERNEL $ARCH";             info+=("$KV")
k Uptime "$UPTIME";                   info+=("$KV")
[ -n "$PKGS" ] && { k Packages "$PKGS"; info+=("$KV"); }
[ -n "$USERS" ] && { k Users "$USERS"; info+=("$KV"); }
k CPU "${CPU:-$ARCH} × $CORES";       info+=("$KV")
k Procs "$PROCS  ·  $SESS ssh sessions";  info+=("$KV")
k Public "${PUB:-resolving…}";        info+=("$KV")
((HAVE_DOCKER)) && { k Docker "${DVER:-n/a}"; info+=("$KV"); }
printf -v tm '%(%a %d %b, %H:%M %Z)T' -1; k Time "$tm"; info+=("$KV")
p1="" p2=""; for c in 0 1 2 3 4 5 6 7; do p1+=$'\e'"[4${c}m   "; p2+=$'\e'"[10${c}m   "; done
printf -v KV "%-9s%s" "" "${p1}${R}"; info+=("$KV")      # normal colors
printf -v KV "%-9s%s" "" "${p2}${R}"; info+=("$KV")      # bright colors

emit ""
panel_top "$HOST" "${LAN:+${FG}${LAN}${R}}"
rows=$(( ${#info[@]} > ${#logo[@]} ? ${#info[@]} : ${#logo[@]} ))
off=$(( (rows - ${#logo[@]}) / 2 ))
printf -v lm "%*s" "$ML" ""
for ((i = 0; i < rows; i++)); do
  l="" w=0; ((i >= off && i - off < ${#logo[@]})) && { l=${logo[i - off]}; w=${logow[i - off]}; }
  printf -v pad "%*s" $((IC - ML - w)) ""
  panel_row "${lm}${l}${R}${pad}${info[i]:-}"
done
panel_bot

# (read before the resources panel so it overlaps with the cpu / net sampling window)
# ── sshd log: auth.log / secure (either timestamp style) or the journal ──
# normalized to "YYYY-MM-DDTHH:MM:SS <event> <user> <ip>", event = ok | fail
printf -v YEAR '%(%Y)T' -1
printf -v NOWISO '%(%Y-%m-%dT%H:%M:%S)T' -1
SSHLOG_AWK='
  function ts(   m) {
    if ($1 ~ /^[0-9][0-9][0-9][0-9]-/) return substr($1, 1, 19)
    m = (index("JanFebMarAprMayJunJulAugSepOctNovDec", $1) + 2) / 3
    t = sprintf("%s-%02d-%02dT%s", Y, m, $2, $3)
    if (t > NOW) t = sprintf("%s-%02d-%02dT%s", Y - 1, m, $2, $3)   # log from last December
    return t
  }
  !/sshd(-session)?\[[0-9]+\]: / { next }
  (i = index($0, "Accepted ")) { split(substr($0, i + 9), a, " "); print ts(), "ok", a[3], a[5]; next }
  /Failed password|Invalid user/ { j = index($0, " from "); split(substr($0, j + 6), b, " ")
                                   u = $0; sub(/.*(Invalid user|Failed password for( invalid user)?) /, "", u); sub(/ .*/, "", u)
                                   print ts(), "fail", u, b[1] }'
SSHLOG_SRC=""
for f in /var/log/auth.log /var/log/secure; do [ -r "$f" ] && { SSHLOG_SRC=$f; break; }; done
if [ -n "$SSHLOG_SRC" ]; then
  sshlog() {   # grep pre-filter: much faster than awk over a multi-MB log
    LC_ALL=C grep -hE 'sshd(-session)?\[[0-9]+\]: (Accepted |Failed password|Invalid user)' "$SSHLOG_SRC.1" "$SSHLOG_SRC" 2>/dev/null |
      awk -v Y="$YEAR" -v NOW="$NOWISO" "$SSHLOG_AWK"
  }
elif have journalctl && { [ "$(id -u)" = 0 ] || id -nG | grep -qwE 'systemd-journal|adm|wheel'; }; then
  SSHLOG_SRC=journal
  sshlog() {
    { journalctl -q --no-pager -o short-iso _COMM=sshd _COMM=sshd-session -n 50 -g '^Accepted '
      journalctl -q --no-pager -o short-iso _COMM=sshd _COMM=sshd-session --since -24h -g 'Failed password|Invalid user'
    } 2>/dev/null | awk -v Y="$YEAR" -v NOW="$NOWISO" "$SSHLOG_AWK" | sort
  }
fi
[ -n "$SSHLOG_SRC" ] && mapfile -t SSHLOG < <(sshlog)

# ── resources panel ─────────────────────────────────────────────────────
# cpu % and net speed = difference between the snapshot taken at the top and now (~0.2s window)
now_us; while ((NOW - T0 < 200000)); do sleep 0.05; now_us; done
snap; dt=$((NOW - T0))                                         # µs
cpu_pct=$(( (CTOT - CTOT0) > 0 ? 100 * ((CTOT - CTOT0) - (CIDLE - CIDLE0)) / (CTOT - CTOT0) : 0 ))
rx_s=$(( (RX - RX0) * 1000000 / dt )); tx_s=$(( (TX - TX0) * 1000000 / dt ))
emit ""
panel_top "resources"
row() { meter "$2" 36; printf -v RW "${FG}%-4s${R} %s ${FG}${B}%3d%%${R}  ${MU}%s${R}" "$1" "$MET" "$2" "$3"; panel_row "$RW"; }
row "cpu" "$cpu_pct" "of $CORES cores"
while read -r key val _; do case $key in MemTotal:) mt=$val ;; MemAvailable:) ma=$val ;; esac; done </proc/meminfo
human $(((mt - ma) * 1024)); a=$HUM; human $((mt * 1024))
row "ram" $(((mt - ma) * 100 / mt)) "$a of $HUM used"
if [ -n "$IFACE" ]; then
  human "$rx_s"; a=$HUM; human "$tx_s"; b=$HUM; human "$RX"; c=$HUM; human "$TX"
  printf -v RW "${FG}%-4s${R} ${GR}↓${R} ${FG}${B}%-8s${R} ${OR}↑${R} ${FG}${B}%-8s${R}  ${MU}total  ↓ %s  ↑ %s${R}" net "$a/s" "$b/s" "$c" "$HUM"
  panel_row "$RW"
fi
panel_bot

# ── docker panel ────────────────────────────────────────────────────────
if ((HAVE_DOCKER)) && [ -n "$DPS" ]; then
  total=0 running=0
  while IFS='|' read -r _ _ _ state _; do total=$((total + 1)); [ "$state" = running ] && running=$((running + 1)); done <<<"$DPS"
  stacks=(/opt/stacks/*/); [ -d "${stacks[0]}" ] || stacks=()
  ((running == total)) && sc=$GR || sc=$YE
  emit ""
  sttl=""; ((${#stacks[@]})) && sttl=" · ${#stacks[@]} stacks"
  panel_top "docker" "${sc}${B}${running}/${total}${R} ${MU}running${sttl}${R}"
  first=1
  while read -r proj; do
    mapfile -t rows < <(awk -F'|' -v p="$proj" '($1==""?"(standalone)":$1)==p' <<<"$DPS" | sort -t'|' -k2,2)
    n=${#rows[@]} r=0 bad=0
    for row_ in "${rows[@]}"; do
      [[ $row_ == *"|running|"* ]] && r=$((r + 1))
      [[ $row_ == *"|running|"* && $row_ != *unhealthy* ]] || bad=1
    done
    ((bad)) && pc=$RD || pc=$GR
    ((first)) || panel_row ""
    first=0
    dir=""; [ -d "/opt/stacks/$proj" ] && dir="/opt/stacks/$proj"
    fit "$proj" 32; a=$FIT; fit "$dir" 32
    printf -v RW "${pc}◆${R} ${B}${FG}%s${R} ${MU}%s${R}    ${pc}${B}%5s${R}" "$a" "$FIT" "$r/$n"
    panel_row "$RW"
    i=0
    for row_ in "${rows[@]}"; do
      IFS='|' read -r _ name image state status ports nets <<<"$row_"
      i=$((i + 1)); ((i == n)) && br="└─" || br="├─"
      if [[ $state != running ]]; then dc=$RD; up="$state"
      elif [[ $status == *unhealthy* ]]; then dc=$RD; up="unhealthy"
      elif [[ $status == *starting* ]]; then dc=$YE; up="starting"
      else dc=$GR; up=${status#Up }; up=${up% (*}; up=${up/About an /1 }; up=${up/About a /1 }; up=${up/Less than a second/now}
        up=${up/ minutes/m}; up=${up/ minute/m}; up=${up/ hours/h}; up=${up/ hour/h}; up=${up/ seconds/s}
        up=${up/ days/d}; up=${up/ weeks/w}; up=${up/ months/mo}; up=${up/ month/mo}; up=${up/ years/y}; up=${up/ year/y}; fi
      hc=" "; [[ $status == *"(healthy)"* ]] && hc="${GR}♥${R}"
      img=$image; [[ ${img%%/*} == *.* && $img == */* ]] && img=${img#*/}   # drop registry host
      img=${img%:latest}
      pub=""
      while [[ $ports =~ 0\.0\.0\.0:([0-9]+)- ]]; do [[ " $pub " == *" :${BASH_REMATCH[1]} "* ]] || pub+="${pub:+ }:${BASH_REMATCH[1]}"; ports=${ports#*"${BASH_REMATCH[0]}"}; done
      [ -z "$pub" ] && [ "$nets" = host ] && pub="host"
      fit "$name" 24; a=$FIT; fit "$img" 28; b=$FIT; fit "$pub" 8; c=$FIT
      printf -v RW " ${BD}%s${R}${dc}●${R}%s${FG}%s${R} ${MU}%s${R} ${AC}%s${R} ${FG}%5s${R}" "$br" "$hc" "$a" "$b" "$c" "$up"
      panel_row "$RW"
    done
  done < <(awk -F'|' '{print ($1==""?"(standalone)":$1)}' <<<"$DPS" | sort -u)
  panel_bot
fi

# ── status panel ────────────────────────────────────────────────────────
ST_ROWS=()
st_row() { printf -v RW "${FG}%-9s${R}%s" "$1" "$2"; ST_ROWS+=("$RW"); }

if [ -n "$SSHLOG_SRC" ] && ((${#SSHLOG[@]})); then
  printf -v since '%(%Y-%m-%dT%H:%M:%S)T' $((NOW_S - 86400))
  read -r fails ips top < <(printf '%s\n' "${SSHLOG[@]}" | awk -v d="$since" '$2 == "fail" && $1 >= d { n++; c[$4]++ }
    END { m = 0; for (i in c) { u++; if (c[i] > m) { m = c[i]; t = i } } printf "%d %d %s\n", n, u, t }')
  if ((${fails:-0} > 0)); then
    st_row ssh "${YE}▲ ${fails} failed logins${R} ${MU}from ${ips} IPs in 24h · top ${top}${R}"
  else
    st_row ssh "${GR}✔ no failed logins in 24h${R}"
  fi
fi
have systemctl && systemctl is-active -q fail2ban 2>/dev/null && st_row fail2ban "${GR}✔ active${R}"

# updates — Ubuntu's precomputed file, else the package manager's cached metadata (in background)
count_updates() {
  local out rc
  if have apt-get; then out=$(apt-get -s -o Debug::NoLocking=1 upgrade 2>/dev/null) || return 1; grep -c '^Inst' <<<"$out"
  elif have dnf || have yum; then          # exit 0 = none, 100 = updates, else no usable cache
    local pm=dnf out rc; have dnf || pm=yum
    out=$($pm -q -C check-update 2>/dev/null); rc=$?
    ((rc == 0 || rc == 100)) || return 1
    grep -cE '^[^ ]+\.[^ ]+ +[^ ]+ +[^ ]+$' <<<"$out"; return 0
  elif have zypper; then out=$(zypper -q --no-refresh lu 2>/dev/null) || return 1; grep -c '^v ' <<<"$out"
  elif have checkupdates; then out=$(checkupdates 2>/dev/null); rc=$?; ((rc == 0 || rc == 2)) || return 1; grep -c . <<<"$out"   # 2 = none
  elif have apk; then out=$(apk -u list 2>/dev/null) || return 1; grep -c . <<<"$out"
  elif have xbps-install; then out=$(xbps-install -un 2>/dev/null) || return 1; grep -c . <<<"$out"
  else return 1; fi
  return 0
}
upd_hint=""
for m in "apt-get:apt list --upgradable" "dnf:dnf check-update" "yum:yum check-update" "zypper:zypper lu" \
         "checkupdates:checkupdates" "apk:apk -u list" "xbps-install:xbps-install -un"; do
  have "${m%%:*}" && { upd_hint=${m#*:}; break; }
done
n="" s=""
if [ -r /var/lib/update-notifier/updates-available ]; then
  f=/var/lib/update-notifier/updates-available
  n=$(grep -oE '^[0-9]+ updates? can' "$f" | awk '{print $1}'); n=${n:-0}
  s=$(grep -oE '^[0-9]+ of these' "$f" | awk '{print $1}')
elif [ -n "$upd_hint" ]; then
  cached updates 60 count_updates; n=$CV
fi
if [ -n "$n" ]; then
  if ((n > 0)); then
    st_row updates "${YE}▲ ${n} packages${R}${s:+ ${RD}(${s} security)${R}} ${MU}· ${upd_hint}${R}"
  else
    st_row updates "${GR}✔ up to date${R}"
  fi
fi

# reboot needed — Debian/Ubuntu flag file, RHEL needs-restarting, else "running kernel's modules are gone"
if [ -f /var/run/reboot-required ]; then
  st_row reboot "${RD}${B}✖ required${R} ${MU}$(sort -u /var/run/reboot-required.pkgs 2>/dev/null | head -3 | tr '\n' ' ')${R}"
elif [ ! -e /.dockerenv ] && [ ! -e /run/.containerenv ] && [ -n "$(ls -A /usr/lib/modules 2>/dev/null)" ] &&
     [ ! -d "/usr/lib/modules/$(uname -r)" ] && [ ! -d "/lib/modules/$(uname -r)" ]; then
  st_row reboot "${RD}${B}✖ required${R} ${MU}kernel was updated${R}"
elif have needs-restarting; then
  cached reboot 60 sh -c 'needs-restarting -r >/dev/null 2>&1 && echo no || echo yes'
  [ "$CV" = yes ] && st_row reboot "${RD}${B}✖ required${R} ${MU}needs-restarting -r${R}"
fi
if ((${#ST_ROWS[@]})); then
  emit ""; panel_top "status"
  for RW in "${ST_ROWS[@]}"; do panel_row "$RW"; done
  panel_bot
fi
emit ""

# ── last login: same wording as sshd's own line, just colored ────────────
# sshd logs "Accepted …" before the session starts, so this user's newest entry is the
# current login and the one before it is the previous one.
LASTLINE="" prev="" pfrom=""
if [ -n "$SSHLOG_SRC" ]; then
  who_=${USER:-}; [ "$MODE" = motd ] && who_=""
  cnt=0
  for ((i = ${#SSHLOG[@]} - 1; i >= 0; i--)); do
    read -r t ev u f <<<"${SSHLOG[i]}"
    [ "$ev" = ok ] || continue
    [ -z "$who_" ] && who_=$u
    [ "$u" = "$who_" ] || continue
    cnt=$((cnt + 1)); ((cnt == 2)) && { prev=$t; pfrom=$f; break; }
  done
  [ -n "$prev" ] && prev=$(date -d "${prev/T/ }" '+%a %b %e %H:%M:%S %Y' 2>/dev/null || echo "${prev/T/ }")
elif [ "$MODE" = profile ] && have last; then
  # wtmp already has this session, so the 2nd entry is the previous login
  read -r _ _ pfrom d1 d2 d3 d4 d5 _ < <(last -F -w -i -n 2 "$USER" 2>/dev/null | sed -n 2p)
  [ -n "${d5:-}" ] && prev="$d1 $d2 $d3 $d4 $d5"
fi
# only when the installer turned off sshd's own line (otherwise it would show twice)
[ -n "$prev" ] && [ -e "$SHARE/show-last-login" ] && LASTLINE="  ${MU}Last login:${R} ${FG}${prev}${R} ${MU}from${R} ${AC}${pfrom}${R}"

[ -n "$LASTLINE" ] && emit "$LASTLINE" && emit ""
printf '%s' "$OUT"
