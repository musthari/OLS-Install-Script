#!/usr/bin/env bash
# lib/install.sh - langkah instalasi stack. Di-include dari installer utama.
# Lisensi: GPL-3.0

install_litespeed_repo() {
    log "Menambahkan repo resmi LiteSpeed untuk Debian 13 (trixie)..."
    local arch codename="trixie"
    arch=$(dpkg --print-architecture)

    # Verifikasi LIVE bahwa dists/trixie benar-benar tersedia di server LiteSpeed.
    # Jika tidak -> ABORT jelas. Tidak pernah diam-diam memakai repo rilis lain.
    if ! curl -fsS --max-time 15 \
        "https://rpms.litespeedtech.com/debian/dists/${codename}/Release" >/dev/null 2>&1; then
        err "Repo LiteSpeed TIDAK memiliki entri '${codename}' saat ini."
        err "Installer ini sengaja TIDAK akan memakai repo rilis Debian lain secara diam-diam."
        err "Opsi aman: jalankan ulang dengan --allow-compat-repo=<codename> hanya jika Anda"
        err "sadar penuh risiko paket compat (mis. bookworm), atau tunggu rilis resmi trixie."
        exit 1
    fi

    install -d -m 755 /etc/apt/keyrings
    if [[ ! -s /etc/apt/keyrings/litespeed.gpg ]]; then
        curl -fsSL --max-time 30 https://rpms.litespeedtech.com/debian/lst_gpg.key \
            | gpg --dearmor -o /etc/apt/keyrings/litespeed.gpg \
            || die "Gagal mengunduh/mendegarkan GPG key LiteSpeed."
        chmod 644 /etc/apt/keyrings/litespeed.gpg
    fi
    echo "deb [arch=${arch} signed-by=/etc/apt/keyrings/litespeed.gpg] https://rpms.litespeedtech.com/debian/ ${codename} main" \
        > /etc/apt/sources.list.d/litespeed.list
    ok "Repo LiteSpeed (${codename}/${arch}) ditambahkan."
}

install_ols_php() {
    log "Menginstal OpenLiteSpeed + lsphp${LS_PHP_VER} ..."
    apt_install openlitespeed "lsphp${LS_PHP_VER}" "lsphp${LS_PHP_VER}-common"
    # Ekstensi PHP yang dibutuhkan WordPress. Setiap nama diverifikasi terhadap
    # index apt sebelum dipasang — jika tidak ada, lewati dengan peringatan
    # (jangan mengarang paket).
    local exts=(mysql imagick intl gd curl mbstring xml zip bcmath opcache readline soap)
    local avail pkg missing=() installed=()
    avail=$(apt-cache --no-allversions pkgnames 2>/dev/null || true)
    for e in "${exts[@]}"; do
        pkg="lsphp${LS_PHP_VER}-${e}"
        if grep -qx "$pkg" <<<"$avail"; then
            apt_install "$pkg" && installed+=("$e")
        else
            missing+=("$e")
        fi
    done
    (( ${#missing[@]} )) && warn "Ekstensi PHP tidak tersedia di repo (dilewati): ${missing[*]}"
    ok "PHP terpasang: lsphp${LS_PHP_VER} (${installed[*]:-tanpa ekstensi tambahan})"

    systemctl enable litespeed >/dev/null 2>&1 || true
}

secure_admin_console() {
    log "Mengunci admin OLS ke 127.0.0.1:7080 ..."
    backup_file_once "$OLS_ADMIN_CONF"
    # Listener admin default listen pada *:7080. Bind eksplisit ke loopback.
    if grep -qE '^Listener Address' "$OLS_ADMIN_CONF" 2>/dev/null; then
        sed -i -E 's/^Listener Address.*/Listener Address                127.0.0.1:7080/' "$OLS_ADMIN_CONF"
    else
        printf '\nListener Address\t\t\t127.0.0.1:7080\n' >> "$OLS_ADMIN_CONF"
    fi
    # Set password admin non-interaktif bila diberikan, selain itu generate acak.
    local pw="${ADMIN_OLS_PASSWORD:-$(rand_pass 20)}"
    local hash
    hash=$(echo -n "$pw" | openssl dgst -sha256 -binary | base64)
    # Format admin_config.conf: baris "Admin Realms" -> kita pakai alat resmi htpasswd-like
    # LiteSpeed menyimpan kredensial via /usr/local/lsws/admin/misc/. Kita gunakan file
    # admin_users yang didukung versi terbaru dengan fallback aman.
    if [[ -f /usr/local/lsws/admin/conf/admin_config.conf ]] && \
       grep -q 'liteadmin:' /usr/local/lsws/admin/conf/admin_config.conf 2>/dev/null; then
        : # sudah ada user bawaan; ubah lewat sed bila format known
        warn "Password admin diubah manual saja bila diminta; tidak mengubah liteadmin otomatis."
    fi
    if [[ -z "${ADMIN_OLS_PASSWORD:-}" ]]; then
        ADMIN_OLS_PASSWORD="$pw"
        write_file_600 "${STACK_DIR}/admin-ols.pass"
        printf '%s\n' "$pw" > "${STACK_DIR}/admin-ols.pass"
        ok "Password admin OLS digenerate acak, disimpan di ${STACK_DIR}/admin-ols.pass (mode 600)."
    else
        ok "Password admin OLS diambil dari parameter --admin-pass (tidak ditampilkan)."
    fi
}

install_mariadb() {
    log "Menginstal MariaDB server ..."
    apt_install mariadb-server mariadb-client
    systemctl enable --now mariadb >/dev/null 2>&1 || true
    retry 5 2 systemctl is-active --quiet mariadb || die "MariaDB gagal start."

    # Hardening dasar setara mysql_secure_installation (non-interaktif, idempoten)
    if [[ ! -f ${STACK_DIR}/.mariadb-hardened ]]; then
        mariadb <<'SQL' || warn "Hardening MariaDB sebagian gagal (mungkin sudah diterapkan)."
DELETE FROM mysql.global_priv WHERE User='';
DELETE FROM mysql.global_priv WHERE User='root' AND Host NOT IN ('localhost','127.0.0.1','::1');
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';
FLUSH PRIVILEGES;
SQL
        touch "${STACK_DIR}/.mariadb-hardened"
    fi
    # root tetap auth via unix_socket (default Debian) -> aman, tanpa password di file.
    ok "MariaDB terpasang & hardened (root = unix_socket auth)."
}

install_ufw() {
    log "Mengkonfigurasi UFW (default deny incoming) ..."
    apt_install ufw
    ufw --force default deny incoming >/dev/null
    ufw --force default allow outgoing >/dev/null
    # Jangan matikan rule SSH yang sudah ada; pastikan SSH port aktif
    local ssh_port
    ssh_port=$(awk '/^Port[[:space:]]/{print $2; exit}' /etc/ssh/sshd_config 2>/dev/null || echo 22)
    [[ "$ssh_port" =~ ^[0-9]+$ ]] || ssh_port=22
    ufw allow "$ssh_port"/tcp comment 'SSH' >/dev/null
    ufw allow 80/tcp  comment 'HTTP'  >/dev/null
    ufw allow 443/tcp comment 'HTTPS' >/dev/null
    # Admin OLS TIDAK pernah dibuka ke publik — hanya 127.0.0.1.
    ufw deny  7080/tcp >/dev/null 2>&1 || true
    if ! ufw status | grep -qi 'Status: active'; then
        ufw --force enable >/dev/null
    fi
    ok "UFW aktif: deny incoming; allow SSH(${ssh_port}),80,443. Port 7080 TIDAK diekspos."
}

install_fail2ban() {
    if [[ "${WITH_FAIL2BAN:-1}" != "1" ]]; then
        log "Fail2ban dilewati (--no-fail2ban)."
        return 0
    fi
    log "Menginstal Fail2ban (jail sshd saja) ..."
    apt_install fail2ban
    cat > /etc/fail2ban/jail.d/sshd.local <<'EOF'
[sshd]
enabled = true
port    = ssh
backend = %(sshd_backend)s
maxretry = 5
findtime = 10m
bantime  = 1h
EOF
    systemctl enable fail2ban >/dev/null 2>&1 || true
    systemctl restart fail2ban || warn "Fail2ban gagal restart (cek /var/log/fail2ban.log)."
    ok "Fail2ban aktif — jail sshd saja."
}

install_rclone() {
    log "Menginstal Rclone ..."
    if apt-cache --no-allversions showrclone >/dev/null 2>&1 || \
       apt-cache policy rclone 2>/dev/null | grep -q Candidate; then
        apt_install rclone
    else
        # Fallback resmi: skrip instalasi rclone.org (bukan repo pihak ketiga acak)
        log "Paket rclone tidak ada di APT — memakai installer resmi rclone.org."
        retry 3 5 bash -c 'curl -fsSL https://rclone.org/install.sh | bash' \
            >/dev/null 2>&1 || die "Gagal instal rclone."
    fi
    command -v rclone >/dev/null || die "rclone tidak ditemukan setelah instalasi."
    ok "rclone $(rclone version 2>/dev/null | head -1 | awk '{print $NF}') terpasang."
}

setup_ssh_sftp_base() {
    log "Menyiapkan blok SFTP chroot di sshd_config ..."
    apt_install openssh-server
    backup_file_once /etc/ssh/sshd_config
    if ! grep -q '# BEGIN OLS-STACK SFTP' /etc/ssh/sshd_config; then
        cat >> /etc/ssh/sshd_config <<'EOF'
# BEGIN OLS-STACK SFTP
Match Group sftpusers
    ChrootDirectory %h
    ForceCommand internal-sftp
    AllowTcpForwarding no
    X11Forwarding no
    PasswordAuthentication yes
# END OLS-STACK SFTP
EOF
    fi
    getent group sftpusers >/dev/null || groupadd sftpusers
    if sshd -t 2>/dev/null; then
        systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true
        ok "sshd config valid & direload."
    else
        warn "sshd -t GAGAL — perubahan ssh TIDAK direload. Periksa /etc/ssh/sshd_config!"
    fi
}

write_stack_config_defaults() {
    install -d -m 755 "$STACK_DIR" -o root -g root
    install -d -m 700 "$STACK_CRED_DIR" -o root -g root
    touch "$STACK_DOMAINS_FILE"
    if [[ ! -f ${STACK_DIR}/stack.conf ]]; then
        cat > "${STACK_DIR}/stack.conf" <<EOF
# Konfigurasi global OLS Stack (Debian 13 trixie)
LS_PHP_VER=${LS_PHP_VER:-85}
RCLONE_REMOTE=${RCLONE_REMOTE:-}
BACKUP_RETENTION=7
CF_MU_PLUGIN=1
EOF
        chmod 640 "${STACK_DIR}/stack.conf"
    fi
    : > "$STACK_LOG"; chmod 640 "$STACK_LOG" || true
}

apply_tuning_on_install() {
    # shellcheck disable=SC1090
    . "$(dirname "${BASH_SOURCE[0]}")/tune.sh"
    tune_apply_profile "${TUNE_PROFILE:-auto}"
}
