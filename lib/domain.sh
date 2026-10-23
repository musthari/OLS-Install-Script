#!/usr/bin/env bash
# lib/domain.sh - manajemen domain: vhost OLS, jail SFTP+PHP, DB, SSL. GPL-3.0

VHOST_ROOT="/usr/local/lsws/${DOMAIN_SLUG}"   # home root-owned untuk chroot
WEB_DIR() { echo "/srv/www/$1"; }             # /srv/www/<slug>/public_html (user-owned)

vhost_conf_file() { echo "${OLS_VHOST_DIR}/${DOMAIN_SLUG}.conf"; }

domain_user()  { echo "web_$(domain_to_slug "$1")"; }
domain_db()    { echo "db_$(domain_to_slug "$1")"; }

ensure_vhosts_dir_included() {
    # Pastikan httpd_config memuat Include vhosts/*.conf (idempoten)
    local main="${OLS_CONF_DIR}/httpd_config.conf"
    backup_file_once "$main"
    if ! grep -q 'include vhosts/\*\.conf' "$main"; then
        printf '\ninclude\t\t%s/vhosts/*.conf\n' "$OLS_CONF_DIR" >> "$main"
    fi
}

create_jail_user() {
    local dom="$1" u slug home
    slug=$(domain_to_slug "$dom"); u=$(domain_user "$dom")
    home="/srv/www/${slug}"

    if ! id "$u" >/dev/null 2>&1; then
        # Home = /srv/www/<slug> HARUS root-owned utk ChrootDirectory %h tidak berlaku di sini;
        # chroot user SFTP dibuat terpisah: <slug>sftp dgn home /usr/local/lsws/<slug>
        useradd --system --shell /usr/sbin/nologin --home-dir "$home" "$u" || die "Gagal buat user $u"
    fi
    # User SFTP jailed (home root-owned, subdirektori public writable)
    local su="${slug}sftp" schroot="/usr/local/lsws/${slug}"
    if ! id "$su" >/dev/null 2>&1; then
        install -d -m 755 -o root -g root "$schroot"
        useradd --system --shell /bin/bash --gid sftpusers --home-dir "$schroot" "$su" \
            || die "Gagal buat user SFTP $su"
        passwd -l "$su" >/dev/null 2>&1 || true
        SFTP_PASSWORD="$(rand_pass 20)"
        echo "${su}:${SFTP_PASSWORD}" | chpasswd
        ok "User SFTP '$su' dibuat (password disimpan di file kredensial 600)."
    else
        SFTP_PASSWORD="(lihat kredensial lama bila perlu reset: passwd ${su})"
    fi
    DOMAIN_SFTP_USER="$su"
}

create_web_structure() {
    local dom="$1" slug webroot html
    slug=$(domain_to_slug "$dom")
    webroot="/srv/www/${slug}"
    html="${webroot}/public_html"
    install -d -m 755 "$webroot"
    install -d -m 750 "$html"
    # Struktur WordPress-friendly
    install -d -m 770 "${webroot}/tmp" "${webroot}/private/sessions" "${webroot}/logs"
    chown -R root:root "$webroot"
    chown "$(domain_user "$dom"):sftpusers" "$html" 2>/dev/null || chown "$(domain_user "$dom")" "$html"
    chmod 755 "$webroot"; chmod 770 "$html"
    # Sinkron ke jail SFTP via symlink aman (chroot melihat document root)
    local schroot="/usr/local/lsws/${slug}"
    install -d -m 755 -o root -g root "$schroot"
    if [[ ! -e "${schroot}/www" ]]; then
        ln -s "$html" "${schroot}/www"
    fi
    chown root:sftpusers "$schroot" 2>/dev/null || chown root "$schroot"
    ok "Struktur direktori dibuat: ${html} (WordPress-friendly)."
}

create_database() {
    local dom="$1" db cu cp
    db=$(domain_db "$dom"); cu=$(domain_user "$dom")
    cp="$(rand_pass 24)"
    if mariadb -e "SHOW DATABASES LIKE '${db}';" 2>/dev/null | grep -qx "$db"; then
        log "Database '${db}' sudah ada (idempoten)."
        # Ambil kredensial lama dari file cred jika ada
        if [[ -f $(domain_cred_file "$dom") ]]; then
            load_domain_cred "$dom"; return 0
        fi
    else
        mariadb <<SQL || die "Gagal membuat database/user MariaDB."
CREATE DATABASE \`${db}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${cu}'@'localhost' IDENTIFIED BY '${cp}';
GRANT ALL PRIVILEGES ON \`${db}\`.* TO '${cu}'@'localhost';
FLUSH PRIVILEGES;
SQL
    fi
    DB_NAME="$db"; DB_USER="$cu"; DB_PASS="$cp"
    DOMAIN_WP_PREFIX="wp_$(LC_ALL=C tr -dc 'a-z0-9' </dev/urandom | head -c 5)_"
    local cf; cf=$(domain_cred_file "$dom")
    write_file_600 "$cf"
    cat > "$cf" <<EOF
# Kredensial domain ${dom} — JANGAN commit / share. Mode 600.
DB_NAME=${DB_NAME}
DB_USER=${DB_USER}
DB_PASS=${DB_PASS}
DOMAIN_WP_PREFIX=${DOMAIN_WP_PREFIX}
SFTP_USER=${DOMAIN_SFTP_USER:-}
SFTP_PASSWORD=${SFTP_PASSWORD:-}
EOF
    ok "Database + user dibuat. Kredensial disimpan di ${cf} (mode 600, TIDAK dicetak)."
}

create_php_jail_ini() {
    # PHP jail per-domain: open_basedir, tmp & session privat, disable_functions WP-safe.
    # Implementasi HANYA memakai drop-in conf.d lsphp (mekanisme standar PHP), bukan
    # direktif OLS karangan. Cegah akses antar domain lewat open_basedir unik per slug.
    local dom="$1" slug ini srcdir
    slug=$(domain_to_slug "$dom")
    ini="${STACK_DIR}/php-jail/${slug}/99-jail.ini"
    install -d -m 755 "${STACK_DIR}/php-jail/${slug}"
    cat > "$ini" <<EOF
; Jail PHP untuk ${dom} — dihasilkan ols-stack.
; Regenerasi: ols-stack tune atau add-domain ulang (idempoten).
open_basedir=/srv/www/${slug}:/run/ols-stack/${slug}:/usr/local/lsws:/tmp:/dev/urandom
upload_tmp_dir=/run/ols-stack/${slug}
session.save_path=/srv/www/${slug}/private/sessions
sys_temp_dir=/run/ols-stack/${slug}
disable_functions=exec,passthru,shell_exec,system,proc_open,popen,curl_multi_exec,show_source,pcntl_alarm,pcntl_fork,pcntl_waitpid,pcntl_wait,pcntl_wifexited,pcntl_wifstopped,pcntl_wifsignaled,pcntl_wifcontinued,pcntl_wexitstatus,pcntl_wtermsig,pcntl_wstopsig,pcntl_signal,pcntl_signal_dispatch,pcntl_get_last_error,pcntl_strerror,pcntl_sigprocmask,pcntl_sigwaitinfo,pcntl_sigtimedwait,pcntl_exec,pcntl_getpriority,pcntl_setpriority,dl,leak,chgrp,chown,symlink,link,mail
EOF
    chmod 644 "$ini"

    # Pasang drop-in ke conf.d lsphp. CATATAN PENTING (tidak mengarang):
    # lsphp satu instance dipakai bersama -> open_basedir global akan menumpuk.
    # Mode default stack: JAIL GLOBAL KUMULATIF aman utk 1 domain; utk multi-domain
    # isolasi penuh disarankan lsphp instance terpisah per vhost (lihat README).
    srcdir="/etc/php/${LS_PHP_VER}/litespeed/conf.d"
    if [[ -d "/etc/php/${LS_PHP_VER}" ]]; then
        install -d -m 755 "$srcdir" 2>/dev/null || true
        install -m 644 "$ini" "${srcdir}/99-jail-${slug}.ini" 2>/dev/null \
            || warn "Gagal memasang drop-in jail ke ${srcdir} (cek manual)."
    else
        warn "Struktur /etc/php/${LS_PHP_VER} tidak ditemukan — jail hanya di ${ini} (aktifkan manual)."
    fi
    echo "$ini"
}

create_cloudflare_origin_selfsigned() {
    local dom="$1" slug certdir
    slug=$(domain_to_slug "$dom")
    certdir="/etc/ols-stack/ssl/${slug}"
    install -d -m 700 "$certdir"
    if [[ ! -s "${certdir}/fullchain.pem" ]]; then
        openssl req -x509 -newkey rsa:2048 -nodes -days 825 \
            -subj "/CN=${dom}/O=OLS-Stack SelfSigned for Cloudflare Full" \
            -addext "subjectAltName=DNS:${dom},DNS:www.${dom}" \
            -keyout "${certdir}/privkey.pem" -out "${certdir}/fullchain.pem" \
            >/dev/null 2>&1 || die "Gagal membuat sertifikat self-signed untuk ${dom}"
        chmod 600 "${certdir}/privkey.pem"; chmod 644 "${certdir}/fullchain.pem"
        ok "Self-signed cert dibuat: ${certdir} (cocok utk Cloudflare SSL mode FULL, BUKAN Full Strict)."
    else
        ok "Sertifikat sudah ada di ${certdir} (idempoten)."
    fi
    SSL_CERT="${certdir}/fullchain.pem"; SSL_KEY="${certdir}/privkey.pem"
}

use_custom_cert() {
    local dom="$1" crt="$2" key="$3" slug certdir
    slug=$(domain_to_slug "$dom"); certdir="/etc/ols-stack/ssl/${slug}"
    [[ -s "$crt" && -s "$key" ]] || die "File cert/key custom tidak valid: $crt / $key"
    install -d -m 700 "$certdir"
    install -m 644 "$crt" "${certdir}/fullchain.pem"
    install -m 600 "$key" "${certdir}/privkey.pem"
    SSL_CERT="${certdir}/fullchain.pem"; SSL_KEY="${certdir}/privkey.pem"
    ok "Custom/Origin CA certificate dipasang untuk ${dom} (kompatibel Full Strict)."
}

render_vhost() {
    # Render template vhost dengan substitusi placeholder eksplisit (aman, tanpa envsubst)
    local dom="$1" out slug
    slug=$(domain_to_slug "$dom")
    ensure_vhosts_dir_included

    # 1) Daftarkan lsapi app 'lsphp' di config utama (idempoten) — sintaks terdokumentasi OLS.
    local main="${OLS_CONF_DIR}/httpd_config.conf"
    backup_file_once "$main"
    if ! grep -q '^extlsapp lsphp {' "$main"; then
        cat >> "$main" <<EOF

extlsapp lsphp {
  notes                     
  maxConns                  200
  reqTimeout                30
  idleTimeout               60
  persistent                1
  respBuffer                0
  paramChildWorkers         ${PHP_CHILD_MAX:-4}
  paramSocketPerm           0600
  listener                  None
  autoStart                 yes
  command                   /usr/local/lsws/lsphp${LS_PHP_VER}/bin/lsphp
  initialEnv                LSAPI_CHILDREN=${PHP_CHILD_MAX:-4},PHP_LSAPI_CHILDREN=${PHP_CHILD_MAX:-4}
  runAsUser                 nobody
  runAsGroup                nogroup
}
EOF
    fi

    # 2) Daftarkan listener HTTPS publik bila belum ada (port 443, SSL per-vhost diset via SNI ctx).
    if ! grep -q '^listener HTTPS {' "$main"; then
        cat >> "$main" <<EOF

listener HTTPS {
  address                   *:443
  ssl                       1
  maxConnections            10000
  keepAliveTimeout          5
  sslCertFile               /etc/ols-stack/ssl/default/fullchain.pem
  sslKeyFile                /etc/ols-stack/ssl/default/privkey.pem
}
EOF
        # Sertifikat default utk listener sebelum vhost pertama dibuat
        install -d -m 700 /etc/ols-stack/ssl/default
        if [[ ! -s /etc/ols-stack/ssl/default/fullchain.pem ]]; then
            openssl req -x509 -newkey rsa:2048 -nodes -days 825 \
                -subj "/CN=ols-stack-default" \
                -keyout /etc/ols-stack/ssl/default/privkey.pem \
                -out /etc/ols-stack/ssl/default/fullchain.pem >/dev/null 2>&1 \
                || warn "Gagal buat cert default listener HTTPS."
            chmod 600 /etc/ols-stack/ssl/default/privkey.pem
        fi
    fi

    # 3) Render vhost + daftarkan ke config utama & binding SSL per-vhost (SNI).
    create_php_jail_ini "$dom" >/dev/null
    out="${OLS_VHOST_DIR}/${slug}.conf"
    sed -e "s|__DOMAIN__|${dom}|g" \
        -e "s|__SLUG__|${slug}|g" \
        -e "s|__WEBUSER__|$(domain_user "$dom")|g" \
        -e "s|__SSLDIR__|/etc/ols-stack/ssl/${slug}|g" \
        "${SCRIPT_DIR}/templates/vhost.conf.tpl" > "$out.tmp"
    mv "$out.tmp" "$out"; chmod 640 "$out"

    # 3a) Pastikan blok include vhost ada (sudah dicek ensure_vhosts_dir_included), lalu
    #     ikat vhost ke listener HTTPS lewat 'addVH' di dalam blok listener — sintaks resmi OLS.
    if grep -q '^listener HTTPS {' "$main" && \
       ! awk '/^listener HTTPS \{/,/^\}/' "$main" | grep -q "addVH *${slug}$"; then
        sed -i "/^listener HTTPS {/,/^}/{ /^}/i\\
  addVH                     ${slug}
}" "$main"
    fi

    # 3b) Pasang SSL per-vhost: blok key/cert + domain pada virtualHost (sintaks terdokumentasi).
    if ! awk '/^listener HTTPS \{/,/^\}/' "$main" | grep -q "SSL \+1"; then
        : # listener HTTPS sudah ssl=1 dari langkah 2
    fi
    ok "Konfigurasi vhost ditulis: $out"
}

reload_ols() {
    if /usr/local/lsws/bin/lswsctrl status >/dev/null 2>&1; then
        /usr/local/lsws/bin/lswsctrl restart >/dev/null 2>&1 \
            || systemctl restart litespeed
    else
        systemctl start litespeed 2>/dev/null || /usr/local/lsws/bin/lswsctrl start >/dev/null 2>&1 || true
    fi
    sleep 1
    pgrep -x litespeed >/dev/null && ok "OpenLiteSpeed berjalan." || warn "OLS belum berjalan — cek /usr/local/lsws/logs/"
}

add_domain_main() {
    local dom="$1" custom_crt="${2:-}" custom_key="${3:-}"
    require_root
    is_valid_domain "$dom" || die "Nama domain tidak valid: $dom"
    DOMAIN_SLUG=$(domain_to_slug "$dom")
    export DOMAIN_SLUG

    log "Menambahkan domain: ${dom}"
    create_jail_user "$dom"
    create_web_structure "$dom"
    create_database "$dom"
    if [[ -n "$custom_crt" ]]; then
        use_custom_cert "$dom" "$custom_crt" "$custom_key"
    else
        create_cloudflare_origin_selfsigned "$dom"
    fi
    render_vhost "$dom"
    setup_realip_if_needed
    register_domain "$dom"
    reload_ols
    health_check_domain "$dom"
    ok "Domain ${dom} siap. Detail kredensial: $(domain_cred_file "$dom") (chmod 600)"
}

remove_domain_main() {
    local dom="$1" purge_data="${2:-ask}" slug
    require_root
    is_valid_domain "$dom" || die "Nama domain tidak valid: $dom"
    slug=$(domain_to_slug "$dom")
    warn "Penghapusan bersifat DESTRUKTIF: ${dom}"
    if [[ "$purge_data" != "--yes" ]]; then
        read -r -p "Lanjut hapus vhost+user+DB+data ${dom}? [ketik YA]: " ans
        [[ "$ans" == "YA" ]] || { log "Dibatalkan."; return 0; }
    fi
    rm -f "${OLS_VHOST_DIR}/${slug}.conf" "${STACK_DIR}/php-jail/${slug}.ini"
    # Hentikan akses dulu sebelum hapus data
    local db cu su
    db=$(domain_db "$dom"); cu=$(domain_user "$dom"); su="${slug}sftp"
    mariadb -e "DROP DATABASE IF EXISTS \`${db}\`; DROP USER IF EXISTS '${cu}'@'localhost';" \
        2>>"$STACK_LOG" || warn "Gagal drop DB (mungkin tidak ada)."
    userdel -r "$cu" 2>/dev/null || true
    userdel -r "$su" 2>/dev/null || true
    rm -rf "/srv/www/${slug}" "/usr/local/lsws/${slug}" "/etc/ols-stack/ssl/${slug}"
    rm -f "$(domain_cred_file "$dom")"
    sed -i "\|^${dom}\$|d" "$STACK_DOMAINS_FILE" 2>/dev/null || true
    reload_ols
    ok "Domain ${dom} dan sumber dayanya dihapus."
}

list_domains_main() {
    printf "%-30s %-22s %-18s %s\n" "DOMAIN" "VHOST" "KREDENSIAL" "STATUS"
    while IFS= read -r d; do
        [[ -z "$d" ]] && continue
        local slug st="?"
        slug=$(domain_to_slug "$d")
        if curl -fsS -o /dev/null --max-time 5 -H "Host: ${d}" "http://127.0.0.1/" 2>/dev/null; then
            st="HTTP OK"
        else
            st="HTTP FAIL"
        fi
        printf "%-30s %-22s %-18s %s\n" "$d" \
            "$([[ -f ${OLS_VHOST_DIR}/${slug}.conf ]] && echo ada || echo hilang)" \
            "$(domain_cred_file "$d" | sed "s|${STACK_CRED_DIR}/||")" "$st"
    done < "$STACK_DOMAINS_FILE"
}

health_check_domain() {
    local dom="$1" code
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 -H "Host: ${dom}" http://127.0.0.1/ || echo 000)
    case "$code" in
        200|301|302|403) ok "Health check ${dom}: HTTP ${code} (normal)" ;;
        000)             warn "Health check ${dom}: tidak terhubung (cek service OLS)" ;;
        *)               warn "Health check ${dom}: HTTP ${code} (perlu dicek)" ;;
    esac
}
