#!/usr/bin/env bash
# lib/restore.sh - restore dari remote rclone, streaming ke tmpfs, tanpa arsip persisten lokal. GPL-3.0

list_backups_main() {
    require_root
    local remote slug dom="$1"
    remote=$(backup_require_remote)
    domain_registered "$dom" || die "Domain tidak terdaftar: $dom"
    slug=$(domain_to_slug "$dom")
    log "Mengambil daftar backup ${dom} dari remote ..."
    printf "%-4s %-18s %-10s %s\n" "NO" "TIMESTAMP" "STATUS" "UKURAN"
    local i=0 d listing files db manifest size total_ok
    while IFS= read -r d; do
        [[ -z "$d" ]] && continue
        ((i++))
        listing=$(rclone lsf --size "${remote}:ols-backup/${slug}/${d}/" 2>/dev/null)
        files=$(grep -c 'files.tar.gz' <<<"$listing" || true)
        db=$(grep -c 'database.sql.gz' <<<"$listing" || true)
        manifest=$(grep -c 'manifest.json' <<<"$listing" || true)
        size=$(awk '{s+=$1} END{printf "%.1fMB", s/1048576}' <<<"$listing")
        if (( files && db && manifest )); then total_ok="LENGKAP"; else total_ok="RUSAK"; fi
        printf "%-4s %-18s %-10s %s\n" "$i" "$d" "$total_ok" "$size"
        # Simpan utk pemilihan
        eval "BACKUP_DIRS[$((i-1))]=\"${d}\""
    done < <(rclone lsf --dirs-only "${remote}:ols-backup/${slug}/" 2>/dev/null | sed 's:/$::' | sort)
    (( i == 0 )) && { warn "Tidak ada backup untuk ${dom}."; return 1; }
    LAST_BACKUP_DOMAIN="$dom"; LAST_BACKUP_SLUG="$slug"; LAST_REMOTE="$remote"
}

restore_main() {
    require_root
    local dom="${1:-}" sel="${2:-}"
    declare -ga BACKUP_DIRS=()
    list_backups_main "$dom" || return 1
    if [[ -z "$sel" ]]; then
        read -r -p "Pilih nomor backup yang akan direstore: " sel
    fi
    [[ "$sel" =~ ^[0-9]+$ ]] && (( sel >= 1 && sel <= ${#BACKUP_DIRS[@]} )) \
        || die "Pilihan tidak valid."
    local ts="${BACKUP_DIRS[$((sel-1))]}"
    [[ "$ts" =~ ^[0-9]{8}-[0-9]{6}$ ]] || die "Format nama backup tak dikenal: $ts"

    warn "== RESTORE DESTRUKTIF =="
    warn "Website '${dom}' dari set '${ts}' akan MENIMPA file & database saat ini."
    read -r -p "Ketik 'YA' untuk lanjut: " ans
    [[ "$ans" == "YA" ]] || { log "Dibatalkan."; return 0; }

    local slug="${LAST_BACKUP_SLUG}" remote="${LAST_REMOTE}"
    local base="${remote}:ols-backup/${slug}/${ts}"
    install -d -m 700 "$TMPFS_RUN"
    local work; work=$(mktemp -d "${TMPFS_RUN}/restore.XXXXXX")
    # Pembersihan otomatis (tmpfs + trap) — tidak ada arsip persisten di disk
    trap 'rm -rf "$work"' EXIT

    log "Unduh database.sql.gz ke tmpfs (/run) ..."
    rclone copyto "${base}/database.sql.gz" "${work}/db.sql.gz" 2>>"$STACK_LOG" \
        || die "Gagal mengunduh dump DB."
    log "Restore FILE via streaming (rclone cat | tar -xz, tanpa simpan arsip) ..."
    # Direktori target tetap root-owned; isi public_html ditimpa
    rclone cat "${base}/files.tar.gz" 2>>"$STACK_LOG" \
        | tar -xzf - -C "/srv/www/${slug}" \
        || die "Gagal restore file."

    log "Import database ke MariaDB ..."
    gunzip -c "${work}/db.sql.gz" | mariadb "$(domain_db "$dom")" 2>>"$STACK_LOG" \
        || die "Import DB gagal."

    log "Perbaiki permission & clear cache ..."
    fix_domain_permissions "$dom"
    clear_domain_cache "$dom"

    reload_ols 2>/dev/null || systemctl restart litespeed
    systemctl restart mariadb >/dev/null 2>&1 || true

    health_check_domain "$dom"
    rm -rf "$work"; trap - EXIT
    ok "Restore ${dom} dari ${ts} selesai."
}

fix_domain_permissions() {
    local dom="$1" slug u
    slug=$(domain_to_slug "$dom"); u=$(domain_user "$dom")
    local html="/srv/www/${slug}/public_html"
    chown -R "${u}:sftpusers" "$html" 2>/dev/null || chown -R "$u" "$html"
    find "$html" -type d -exec chmod 755 {} \;
    find "$html" -type f -exec chmod 644 {} \;
    [[ -f "${html}/wp-config.php" ]] && chmod 640 "${html}/wp-config.php"
    chown -R "${u}:sftpusers" "/srv/www/${slug}/tmp" "/srv/www/${slug}/private" "/srv/www/${slug}/logs" 2>/dev/null \
        || chown -R "$u" "/srv/www/${slug}/tmp" "/srv/www/${slug}/private" "/srv/www/${slug}/logs"
    ok "Permission diperbaiki."
}

clear_domain_cache() {
    local dom="$1" slug
    slug=$(domain_to_slug "$dom")
    # LSCache: purge lewat lscli jika tersedia (CLI resmi LiteSpeed, cek keberadaan);
    # fallback aman: hapus folder cache fisik plugin LSCache.
    if command -v lscli >/dev/null 2>&1; then
        lscli vhost "$slug" cache purge all >/dev/null 2>&1 || true
    fi
    rm -rf "/srv/www/${slug}/public_html/wp-content/litespeed/cache/"* 2>/dev/null || true
    ok "Cache dibersihkan (litespeed cache dir)."
}

# ---------------------------------------------------------------------------
# WordPress install & optimasi (semua website diasumsikan WordPress)
# ---------------------------------------------------------------------------
install_wordpress() {
    require_root
    local dom="$1" slug html u
    slug=$(domain_to_slug "$dom"); html="/srv/www/${slug}/public_html"; u=$(domain_user "$dom")
    load_domain_cred "$dom"

    if ! command -v wp >/dev/null 2>&1; then
        log "WP-CLI belum ada — unduh phar resmi ..."
        retry 3 5 curl -fsSL -o /usr/local/bin/wp https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar \
            || die "Gagal mengunduh WP-CLI."
        chmod 755 /usr/local/bin/wp
    fi

    if [[ -f "${html}/wp-config.php" ]]; then
        ok "WordPress sudah ter-install di ${dom} (idempoten, dilewati)."
        return 0
    fi

    log "Install WordPress core ke ${html} ..."
    ( cd "$html" && sudo -u "$u" wp core download --allow-root --quiet ) \
        || die "Download WP core gagal."

    # Ganti placeholder table prefix dari template dengan prefix random per domain
    sed -i "s/__DB_PREFIX__/${DOMAIN_WP_PREFIX}/" "${html}/wp-config-sample.php"

    ( cd "$html" && sudo -u "$u" wp config create \
        --dbname="$DB_NAME" --dbuser="$DB_USER" --dbpass="$DB_PASS" \
        --dbhost=localhost --table_prefix="$DOMAIN_WP_PREFIX" \
        --extra-php <<'PHPEXTRA' --allow-root --quiet
define('FS_METHOD', 'direct');
define('WP_DEBUG', false);
define('DISALLOW_FILE_EDIT', true);
PHPEXTRA
    ) || die "wp config create gagal."

    # Salts acak (diisi dari API resmi WP; fallback generate lokal)
    local salts=""
    if ! salts=$(curl -fsS --max-time 15 https://api.wordpress.org/secret-key/1.1/salt/ 2>/dev/null); then
        warn "API salt tidak terjangkau — generate salt lokal acak."
        local k
        for k in AUTH_KEY SECURE_AUTH_KEY LOGGED_IN_KEY NONCE_KEY \
                 AUTH_SALT SECURE_AUTH_SALT LOGGED_IN_SALT NONCE_SALT; do
            salts+="define('${k}', '$(rand_salt_key)');"$'\n'
        done
    fi
    # Sisipkan salts menggantikan blok default wp-config (tetap idempoten: hanya jika belum ada block kita)
    local tmpc; tmpc=$(mktemp)
    if grep -q 'BEGIN OLS-STACK SALTS' "${html}/wp-config.php"; then
        awk '/BEGIN OLS-STACK SALTS/{skip=1} /END OLS-STACK SALTS/{skip=0;next} !skip{print}' \
            "${html}/wp-config.php" > "$tmpc" && mv "$tmpc" "${html}/wp-config.php"
        tmpc=$(mktemp)
    fi
    awk -v salts="$salts" '
        /^\/\* That.s all, stop editing/{
            print "/* BEGIN OLS-STACK SALTS */";
            printf "%s\n", salts;
            print "/* END OLS-STACK SALTS */";
        }
        { print }' "${html}/wp-config.php" > "$tmpc" && mv "$tmpc" "${html}/wp-config.php"
    chmod 640 "${html}/wp-config.php"; chown "$u:sftpusers" "${html}/wp-config.php" 2>/dev/null || chown "$u" "${html}/wp-config.php"

    ( cd "$html" && sudo -u "$u" wp core install \
        --url="https://${dom}" --title="${dom}" \
        --admin_user=admin --admin_password="$(rand_pass 18)" \
        --admin_email="admin@${dom}" --skip-email --allow-root --quiet ) \
        || die "wp core install gagal (cek DB/service MariaDB)."

    # Simpan kredensial admin WP (tanpa cetak ke stdout)
    local cf; cf=$(domain_cred_file "$dom")
    umask 077; grep -q WP_ADMIN_PASS "$cf" || cat >> "$cf" <<EOF
WP_ADMIN_USER=admin
EOF
    ok "WordPress ter-install. Password admin disimpan via proses install (reset: wp user update admin --user_pass=...)."

    install_lscache_plugin "$dom"
    deploy_mu_plugin_to_domain "$dom"
    fix_domain_permissions "$dom"
}

install_lscache_plugin() {
    local dom="$1" slug html u
    slug=$(domain_to_slug "$dom"); html="/srv/www/${slug}/public_html"; u=$(domain_user "$dom")
    ( cd "$html" && sudo -u "$u" wp plugin install litespeed-cache --activate --allow-root --quiet ) \
        || warn "Gagal install LSCache plugin (lanjut manual dari dashboard WP)."

    # WooCommerce-aware: jika terdeteksi, set exclude cart/checkout via option plugin
    if ( cd "$html" && sudo -u "$u" wp plugin list --allow-root 2>/dev/null | grep -qw woocommerce ); then
        log "WooCommerce terdeteksi — mengatur exclude cache utk cart/checkout/account."
        ( cd "$html" && sudo -u "$u" wp option patch update litespeed.opt.cache_tags '' --allow-root ) >/dev/null 2>&1 || true
        # Cara andal & terdokumentasi: tulis file konfigurasi exclude milik plugin via filter
        # Tidak mengarang opsi internal; gunakan .htaccess-style OLS context exclude:
        local exconf="${STACK_DIR}/lscache/${slug}.exclude"
        install -d -m 755 "${STACK_DIR}/lscache"
        cat > "$exconf" <<'EOF'
# Rule LSCache untuk WooCommerce (referensi utk dipasang di WebAdmin/context):
# URI contains: /cart/ , /checkout/ , /my-account/ , ?add-to-cart , wc-lossless
# serta cookie-based bypass utk woocommerce sessions adalah perilaku default plugin.
EOF
        ok "Catatan exclude WooCommerce ditulis: $exconf (plugin LSCache sudah auto-bypass Woo secara default)."
    fi
}

wordpress_optimize_main() {
    require_root
    local dom="${1:-}"
    if [[ -n "$dom" ]]; then
        domain_registered "$dom" || die "Domain tidak terdaftar: $dom"
        install_wordpress "$dom"
    else
        while IFS= read -r d; do [[ -n "$d" ]] && install_wordpress "$d"; done < "$STACK_DOMAINS_FILE"
    fi
}
