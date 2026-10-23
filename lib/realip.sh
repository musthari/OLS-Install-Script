#!/usr/bin/env bash
# lib/realip.sh - Cloudflare Real IP untuk OpenLiteSpeed. GPL-3.0
# Strategi:
#  1) Ambil range resmi Cloudflare (IPv4+IPv6) dari api.cloudflare.com — live, bukan hardcode.
#  2) Jika OLS mendukung directive native realIPList/realAccessControl (dicek via binary),
#     pakai directive tsb -> hanya koneksi dari IP CF yang boleh pakai header X-Forwarded-For.
#  3) Fallback aman: log CF-Connecting-IP di format akses + mu-plugin WP yang menyetel
#     REMOTE_ADDR HANYA jika $_SERVER['REMOTE_ADDR'] termasuk CIDR Cloudflare.

CF_RANGE_CACHE="${STACK_DIR}/cloudflare-ips.txt"

cf_fetch_ranges() {
    local v4 v6
    v4=$(curl -fsS --max-time 15 https://api.cloudflare.com/client/v4/ips \
         | grep -oE '"ipv4_cidrs":\[[^]]*\]' | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]+' || true)
    v6=$(curl -fsS --max-time 15 https://api.cloudflare.com/client/v4/ips \
         | grep -oE '"ipv6_cidrs":\[[^]]*\]' | grep -oE '([0-9a-fA-F:]+/[0-9]+)' || true)
    [[ -z "$v4" && -z "$v6" ]] && return 1
    { echo "$v4"; echo "$v6"; } | sed '/^$/d' > "${CF_RANGE_CACHE}.tmp"
    mv "${CF_RANGE_CACHE}.tmp" "$CF_RANGE_CACHE"
    chmod 644 "$CF_RANGE_CACHE"
}

ols_supports_realip() {
    # Deteksi dukungan native, jangan mengarang: cek string pada binary OLS.
    if strings /usr/local/lsws/bin/lshttpd 2>/dev/null | grep -qx 'realIPList'; then
        return 0
    fi
    return 1
}

apply_ols_native_realip() {
    local main="${OLS_CONF_DIR}/httpd_config.conf"
    backup_file_once "$main"
    local list
    list=$(awk '{printf "%s ", $0}' "$CF_RANGE_CACHE")
    if grep -qE '^realIPList' "$main"; then
        sed -i -E "s|^realIPList.*|realIPList                      ${list}|" "$main"
    else
        printf '\nrealIPList\t%s\n' "$list" >> "$main"
    fi
    ok "Directive native realIPList diterapkan (percayai proxy hanya dari range Cloudflare)."
}

install_cf_mu_plugin() {
    # mu-plugin dipasang per-domain saat add-domain; fungsi ini menulis template master.
    local tpl="${SCRIPT_DIR:-/usr/local/share/ols-stack}/templates/mu-plugin-cloudflare-real-ip.php"
    [[ -f "$tpl" ]] || die "Template mu-plugin tidak ditemukan: $tpl"
    install -d -m 755 "${STACK_DIR}/mu-plugins"
    install -m 644 "$tpl" "${STACK_DIR}/mu-plugins/cloudflare-real-ip.php"
    ok "Master mu-plugin Cloudflare Real IP tersedia di ${STACK_DIR}/mu-plugins/"
}

deploy_mu_plugin_to_domain() {
    local dom="$1" slug mu
    slug=$(domain_to_slug "$dom")
    mu="/srv/www/${slug}/public_html/wp-content/mu-plugins"
    if [[ -d "/srv/www/${slug}/public_html/wp-content" ]]; then
        install -d -m 755 "$mu"
        install -m 644 "${STACK_DIR}/mu-plugins/cloudflare-real-ip.php" "${mu}/cloudflare-real-ip.php" 2>/dev/null || true
        chown -R "$(domain_user "$dom"):" "$mu" 2>/dev/null || true
    fi
}

setup_realip_if_needed() {
    require_root
    install -d -m 755 "$STACK_DIR"
    if [[ ! -s "$CF_RANGE_CACHE" ]] || \
       [[ $(find "$CF_RANGE_CACHE" -mmin +$((24*60)) 2>/dev/null | wc -l) -eq 1 ]]; then
        cf_fetch_ranges || warn "Gagal mengambil range Cloudflare (offline?). Pakai cache/kosong."
    fi
    if ols_supports_realip; then
        apply_ols_native_realip
    else
        warn "OLS versi ini tidak mendeteksi 'realIPList' native — memakai fallback aman:"
        # 1) Log CF-Connecting-IP secara eksplisit (hanya sebagai LOG, bukan kepercayaan)
        local main="${OLS_CONF_DIR}/httpd_config.conf"
        backup_file_once "$main"
        # Kami TIDAK menulis directive log custom yang tidak terverifikasi ke config utama
        # (risiko merusak httpd_config). Sebagai gantinya, format log alternatif disimpan
        # di file dokumentasi utk dipasang manual lewat WebAdmin bila diinginkan.
        install -d -m 755 "${STACK_DIR}/snippets"
        cat > "${STACK_DIR}/snippets/cf-logformat.txt" <<'EOF'
# Opsional: pasang via WebAdmin (Listeners > Log > Custom Log Format) atau edit manual.
# Sintaks variabel header request OLS: %{HeaderName}i — verifikasi di WebAdmin sebelum dipakai.
{%a} [%t] "%r" %>s %b "%{Referer}i" "%{User-Agent}i" "cf-connecting-ip=%{CF-Connecting-IP}i"
EOF
        warn "Snippet format log CF tersedia di ${STACK_DIR}/snippets/cf-logformat.txt (pasang manual/verifikasi)."
    fi
    # 2) mu-plugin selalu disiapkan (verifikasi CIDR di sisi PHP — trust hanya utk IP CF)
    install_cf_mu_plugin
    deploy_mu_plugin_to_domain "${1:-}" 2>/dev/null || true
}

update_cloudflare_ips_main() {
    require_root
    log "Memperbarui daftar IP Cloudflare ..."
    cf_fetch_ranges || die "Gagal mengambil range IP Cloudflare."
    ok "Range diperbarui: $(wc -l < "$CF_RANGE_CACHE") entri CIDR."
    if ols_supports_realip; then
        apply_ols_native_realip
        reload_ols 2>/dev/null || systemctl restart litespeed 2>/dev/null || true
        ok "OLS direstart dengan realIPList baru."
    fi
    # Perbarui mu-plugin yg sudah ter-deploy agar daftar CIDR ikut terbaru
    while IFS= read -r d; do
        [[ -n "$d" ]] && deploy_mu_plugin_to_domain "$d"
    done < "$STACK_DOMAINS_FILE" 2>/dev/null || true
}
