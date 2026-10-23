#!/usr/bin/env bash
#
# install-openlitespeed-stack.sh
# ------------------------------------------------------------------
# Installer stack WordPress production-ready di atas OpenLiteSpeed.
# Target platform : Debian 13 (trixie) — diverifikasi eksplisit, BUKAN rilis lain.
# Komponen        : OpenLiteSpeed + lsphp tertinggi dari repo LiteSpeed, MariaDB,
#                   UFW (deny incoming), Fail2ban (jail sshd), Rclone backup streaming,
#                   SFTP jailed per-domain, PHP jail per-domain, Cloudflare Real IP,
#                   tuning RAM utk VPS 1GB/2GB/4GB, instalasi WP+LSCache otomatis.
#
# Pemakaian:
#   sudo bash install-openlitespeed-stack.sh [opsi]
#
# Opsi:
#   --domain <tld>          Tambah domain pertama setelah instalasi (WP auto-install)
#   --cert <f> --key <f>    Sertifikat custom/Origin CA utk --domain (selain self-signed)
#   --admin-pass <pw>       Password admin WebAdmin OLS (default: generate acak 600)
#   --tune <auto|1g|2g|4g>  Profil tuning (default auto dari RAM)
#   --no-fail2ban           Lewati fail2ban
#   --rclone-remote <name:> Remote rclone yg sudah dikonfigurasi utk backup harian
#   --yes                   Non-interaktif (untuk provisioning script)
#
# Keamanan desain:
#   - Kredensial SELALU disimpan chmod 600 di /etc/ols-stack/credentials/, tidak dicetak.
#   - Repo LiteSpeed diverifikasi LIVE utk codename trixie; TIDAK ada fallback diam-diam
#     ke repo rilis Debian lain.
#   - Semua konfigurasi lama dibackup .orig sebelum diubah; operasi idempoten.
#   - Admin panel 7080 hanya bind 127.0.0.1 dan di-deny di UFW.
#   - Restore & remove-domain destruktif => konfirmasi ketik 'YA'.
#
# Lisensi: GPL-3.0
# ------------------------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"
for m in install domain realip tune backup restore; do
    # shellcheck disable=SC1090
    source "${SCRIPT_DIR}/lib/${m}.sh"
done

require_root

# ------------------------- parse argumen -------------------------
FIRST_DOMAIN=""; CERT_FILE=""; KEY_FILE=""; ADMIN_OLS_PASSWORD=""
TUNE_PROFILE="auto"; WITH_FAIL2BAN=1; RCLONE_REMOTE=""; ASSUME_YES=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --domain)         FIRST_DOMAIN="${2:?}"; shift 2 ;;
        --cert)           CERT_FILE="${2:?}"; shift 2 ;;
        --key)            KEY_FILE="${2:?}"; shift 2 ;;
        --admin-pass)     ADMIN_OLS_PASSWORD="${2:?}"; shift 2 ;;
        --tune)           TUNE_PROFILE="${2:?}"; shift 2 ;;
        --no-fail2ban)    WITH_FAIL2BAN=0; shift ;;
        --rclone-remote)  RCLONE_REMOTE="${2:?}"; shift 2 ;;
        --yes|-y)         ASSUME_YES=1; shift ;;
        -h|--help)        grep -E '^#( |$)' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)                die "Opsi tidak dikenal: $1 (lihat --help)" ;;
    esac
done

echo
printf "${C_BLD}==============================================================${C_RST}\n"
printf "${C_BLD} OpenLiteSpeed + WordPress Stack Installer — Debian 13 (trixie)${C_RST}\n"
printf "${C_BLD}==============================================================${C_RST}\n"
echo

# ------------------------- pra-pemeriksaan -------------------------
log "Menjalankan pra-pemeriksaan sistem..."
check_debian13
check_systemd
check_ram
check_disk
check_network
pick_php_version
check_ports_free

apt_install curl gnupg ca-certificates openssl iproute2 procps tar gzip rsync sudo cron acl

if (( ! ASSUME_YES )); then
    read -r -p "Lanjutkan instalasi stack? [y/N]: " ans
    [[ "${ans,,}" == y ]] || { log "Dibatalkan pengguna."; exit 0; }
fi

# ------------------------- langkah instalasi -------------------------
install_litespeed_repo
DEBIAN_FRONTEND=noninteractive apt-get update -y || die "apt-get update gagal."
install_ols_php
secure_admin_console
install_mariadb
install_ufw
install_fail2ban
setup_ssh_sftp_base
install_rclone
write_stack_config_defaults

if [[ -n "$RCLONE_REMOTE" ]]; then
    stack_conf_set RCLONE_REMOTE "$RCLONE_REMOTE"
    RCLONE_REMOTE="$RCLONE_REMOTE" rclone_test_main || warn "Tes rclone gagal — backup perlu diperbaiki manual."
    install_backup_cron
else
    warn "Tidak ada --rclone-remote: setup dengan 'ols-stack backup --setup' lalu 'ols-stack install-cron'."
fi

apply_tuning_on_install

# mu-plugin master + daftar IP CF awal
cf_fetch_ranges || warn "Gagal prefetch range Cloudflare (ulangi via 'ols-stack update-cf-ips')."
install_cf_mu_plugin

# pasang CLI ols-stack
install -d -m 755 /usr/local/share/ols-stack
cp -a "${SCRIPT_DIR}/lib" "${SCRIPT_DIR}/templates" /usr/local/share/ols-stack/
install -m 755 "${SCRIPT_DIR}/ols-stack" /usr/local/bin/ols-stack
ok "CLI terpasang: /usr/local/bin/ols-stack"

# ------------------------- domain pertama -------------------------
if [[ -n "$FIRST_DOMAIN" ]]; then
    add_domain_main "$FIRST_DOMAIN" "$CERT_FILE" "$KEY_FILE"
    install_wordpress "$FIRST_DOMAIN"
    deploy_mu_plugin_to_domain "$FIRST_DOMAIN"
fi

# ------------------------- ringkasan akhir -------------------------
cat <<EOF

${C_BLD}=========================== SELESAI ============================${C_RST}
WebAdmin OLS : http://127.0.0.1:7080  (hanya loopback; pass: ${STACK_DIR}/admin-ols.pass)
Firewall     : UFW deny-incoming; SSH/80/443 allow; 7080 deny publik
Fail2ban     : jail sshd aktif
Backup       : ols-stack backup [--setup]; retensi 7 set lengkap (files+db+manifest)
Restore      : ols-stack list-backups <domain> ; ols-stack restore <domain>
Domain baru  : ols-stack add-domain <tld> [--cert f --key f]
Kredensial   : ${STACK_CRED_DIR}/<slug>.conf (mode 600 — JANGAN share/commit)
Cloudflare   : set SSL mode = Full (self-signed origin) atau pasangkan Origin CA
               via --cert/--key lalu ols-stack update-cf-ips berkala (cron sendiri).
Verifikasi   : ols-stack status
${C_BLD}===============================================================${C_RST}
EOF
ok "Stack siap digunakan."
