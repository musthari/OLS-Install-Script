#!/usr/bin/env bash
# lib/common.sh - fungsi bersama untuk OLS Stack (Debian 13 trixie)
# Sumber: di-include oleh install-openlitespeed-stack.sh dan /usr/local/bin/ols-stack
# Lisensi: GPL-3.0

# ---------------------------------------------------------------------------
# Warna & logging
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
    C_RED='\033[0;31m'; C_GRN='\033[0;32m'; C_YLW='\033[1;33m'
    C_BLU='\033[0;34m'; C_BLD='\033[1m'; C_RST='\033[0m'
else
    C_RED=''; C_GRN=''; C_YLW=''; C_BLU=''; C_BLD=''; C_RST=''
fi

log()   { printf "${C_BLU}[INFO]${C_RST} %s\n" "$*"; }
ok()    { printf "${C_GRN}[ OK ]${C_RST} %s\n" "$*"; }
warn()  { printf "${C_YLW}[WARN]${C_RST} %s\n" "$*" >&2; }
err()   { printf "${C_RED}[FAIL]${C_RST} %s\n" "$*" >&2; }
die()   { err "$*"; exit 1; }

# Handler ERR global: tampilkan baris yang gagal
trap 'err "Kegagalan pada ${BASH_SOURCE[0]}:${LINENO}: ${BASH_COMMAND}"' ERR

# ---------------------------------------------------------------------------
# Konstanta path
# ---------------------------------------------------------------------------
OLS_CONF_DIR="/usr/local/lsws/conf"
OLS_VHOST_DIR="${OLS_CONF_DIR}/vhosts"
OLS_ADMIN_CONF="${OLS_CONF_DIR}/admin_config.conf"
STACK_DIR="/etc/ols-stack"
STACK_CRED_DIR="${STACK_DIR}/credentials"
STACK_DOMAINS_FILE="${STACK_DIR}/domains.list"
STACK_LOG="/var/log/ols-stack.log"
TMPFS_RUN="/run/ols-stack"

# ---------------------------------------------------------------------------
# Util umum
# ---------------------------------------------------------------------------
require_root() {
    [[ "$(id -u)" -eq 0 ]] || die "Skrip ini harus dijalankan sebagai root (gunakan sudo)."
}

is_valid_domain() {
    local d="$1"
    [[ "$d" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)+$ ]]
}

# Nama DB/user aman (identifier MariaDB; kita batasi 32 char)
domain_to_slug() {
    echo "$1" | tr 'A-Z.' 'a-z-' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//' | cut -c1-32
}

rand_pass() {
    # Password acak N karakter alnum (aman untuk shell/SQL tanpa escaping rumit)
    LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c "${1:-24}"
}

rand_salt_key() {
    # Karakter untuk WP salts (hindari kutip ganda/backslash agar aman di sed/PHP)
    LC_ALL=C tr -dc 'A-Za-z0-9!@#$%^&*()_+=~`\[\]{}|:;<>,.-?' < /dev/urandom | head -c 64
}

file_exists_cmd() { command -v "$1" >/dev/null 2>&1; }

apt_install() {
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$@" \
        || die "Gagal menginstal paket: $*"
}

retry() {
    # retry <n> <sleep_sec> <cmd...>
    local n="$1" s="$2"; shift 2
    local i=1
    until "$@"; do
        if (( i >= n )); then return 1; fi
        warn "Perintah gagal (percobaan $i/$n): $* — tunggu ${s}s"
        sleep "$s"; ((i++))
    done
    return 0
}

run_logged() {
    # Jalankan perintah, catat ke log stack, jangan bocorkan output ke stdout
    { date '+%F %T'; echo "CMD: $*"; "$@"; } >>"$STACK_LOG" 2>&1 \
        || { err "Perintah gagal (lihat $STACK_LOG): $*"; return 1; }
}

# ---------------------------------------------------------------------------
# Deteksi sistem
# ---------------------------------------------------------------------------
check_debian13() {
    [[ -r /etc/os-release ]] || die "/etc/os-release tidak ditemukan."
    # shellcheck disable=SC1091
    . /etc/os-release
    [[ "${ID:-}" == "debian" ]] || die "Bukan Debian (ID=${ID:-kosong}). Installer ini khusus Debian 13."
    [[ "${VERSION_CODENAME:-}" == "trixie" ]] || die \
        "Codename = '${VERSION_CODENAME:-tidak diketahui}'. Installer ini khusus Debian 13 (trixie). Repo LiteSpeed resmi tersedia untuk trixie — installer TIDAK akan diam-diam memakai repo rilis lain."
    ok "Debian ${VERSION_ID:-13} (trixie) terdeteksi."
}

check_systemd() {
    [[ -d /run/systemd/system ]] || die "systemd tidak terdeteksi. Lingkungan ini bukan systemd."
    ok "systemd aktif."
}

check_ram() {
    local mem_kb
    mem_kb=$(awk '/^MemTotal:/{print $2}' /proc/meminfo)
    RAM_MB=$(( mem_kb / 1024 ))
    if (( RAM_MB < 768 )); then
        die "RAM ${RAM_MB}MB terlalu kecil (minimum efektif ~1GB)."
    fi
    ok "RAM terdeteksi: ${RAM_MB} MB"
}

check_disk() {
    local free_mb
    free_mb=$(df -Pm / | awk 'NR==2{print $4}')
    if (( free_mb < 5120 )); then
        die "Ruang disk di / hanya ${free_mb}MB. Minimum 5GB kosong direkomendasikan."
    fi
    ok "Disk bebas di /: ${free_mb} MB"
}

check_network() {
    if ! curl -fsS --max-time 10 https://rpms.litespeedtech.com/debian/dists/trixie/Release >/dev/null 2>&1; then
        die "Tidak dapat menghubungi repo LiteSpeed (rpms.litespeedtech.com). Periksa koneksi/DNS/firewall keluar."
    fi
    ok "Koneksi ke repo LiteSpeed OK."
}

check_ports_free() {
    local p out
    for p in 80 443 7080; do
        out=$(ss -Hlt "( sport = :$p )" 2>/dev/null || true)
        if [[ -n "$out" ]] && ! pgrep -x litespeed >/dev/null 2>&1; then
            warn "Port $p sudah dipakai:"
            ss -Hltp "( sport = :$p )" || true
            die "Port $p bentrok dengan layanan lain. Hentikan layanan lama sebelum instalasi."
        fi
    done
    ok "Port 80/443/7080 siap."
}

pick_php_version() {
    # Ambil lsphpXX tertinggi dari index Packages LiteSpeed trixie (bukan asumsi).
    # Fallback aman: jika jaringan gagal, pakai LS_PHP_VER default (85) + peringatan.
    local arch pkgs_url v
    arch=$(dpkg --print-architecture)
    pkgs_url="https://rpms.litespeedtech.com/debian/dists/trixie/main/binary-${arch}/Packages"
    if v=$(curl -fsS --max-time 20 "$pkgs_url" 2>/dev/null \
            | grep -oE '^Package: lsphp[0-9]+$' | grep -oE '[0-9]+' | sort -n | tail -1) && [[ -n "$v" ]]; then
        LS_PHP_VER="$v"
        ok "PHP tertinggi di repo LiteSpeed trixie (${arch}): lsphp${LS_PHP_VER}"
    else
        LS_PHP_VER="${LS_PHP_VER:-85}"
        warn "Gagal membaca daftar paket repo; memakai default lsphp${LS_PHP_VER} (fallback, diverifikasi saat install)."
    fi
}

# ---------------------------------------------------------------------------
# Backup konfigurasi (idempoten)
# ---------------------------------------------------------------------------
backup_file_once() {
    local f="$1"
    [[ -f "$f" && ! -e "${f}.orig" ]] && cp -a "$f" "${f}.orig"
    return 0
}

write_file_600() {
    local f="$1"
    umask 077
    install -d -m 700 "$(dirname "$f")"
    : > "$f"
    chmod 600 "$f"
}

# ---------------------------------------------------------------------------
# Registrasi domain & kredensial
# ---------------------------------------------------------------------------
domain_cred_file() { echo "${STACK_CRED_DIR}/$(domain_to_slug "$1").conf"; }

register_domain() {
    local d="$1"
    install -d -m 700 "$STACK_CRED_DIR"
    touch "$STACK_DOMAINS_FILE"
    grep -qxF "$d" "$STACK_DOMAINS_FILE" || echo "$d" >> "$STACK_DOMAINS_FILE"
}

domain_registered() {
    [[ -f "$STACK_DOMAINS_FILE" ]] && grep -qxF "$1" "$STACK_DOMAINS_FILE"
}

load_domain_cred() {
    local d="$1" f
    f=$(domain_cred_file "$d")
    [[ -f "$f" ]] || die "File kredensial tidak ada: $f"
    # shellcheck disable=SC1090
    . "$f"
}
