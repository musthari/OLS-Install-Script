#!/usr/bin/env bash
# lib/tune.sh - tuning performa utk VPS 1GB/2GB/4GB. GPL-3.0
# Prinsip: JANGAN overcommit — total alokasi PHP workers + MariaDB buffer harus < RAM nyata.

tune_pick_profile() {
    # auto -> 1g/2g/4g berdasarkan RAM nyata
    local mb="${RAM_MB:-$(awk '/^MemTotal:/{print int($2/1024)}' /proc/meminfo)}"
    if   (( mb < 1700 )); then echo "1g"
    elif (( mb < 3400 )); then echo "2g"
    else                       echo "4g"
    fi
}

tune_profile_values() {
    # Set variabel profil berdasarkan nama
    local p="$1"
    case "$p" in
        1g) LS_WORKERS=2;  PHP_CHILD_MAX=4;  PHP_LSAPI_MEM=64M;  PHP_FPC=64M
            INNO_BUF=128M; MY_SMALL=1; CF_WORKERS=2 ;;
        2g) LS_WORKERS=2;  PHP_CHILD_MAX=8;  PHP_LSAPI_MEM=96M;  PHP_FPC=128M
            INNO_BUF=256M; MY_SMALL=1; CF_WORKERS=2 ;;
        4g) LS_WORKERS=4;  PHP_CHILD_MAX=12; PHP_LSAPI_MEM=128M; PHP_FPC=256M
            INNO_BUF=512M; MY_SMALL=0; CF_WORKERS=4 ;;
        *)  die "Profil tidak dikenal: $p (pakai auto|1g|2g|4g)" ;;
    esac
    TUNE_PROFILE_USED="$p"
}

tune_apply_profile() {
    require_root
    local p="${1:-auto}"
    [[ "$p" == "auto" ]] && p=$(tune_pick_profile)
    tune_profile_values "$p"
    log "Menerapkan profil tuning: ${p} (RAM ${RAM_MB:-?}MB)"

    # ---- OpenLiteSpeed (httpd_config.conf) ----
    local main="${OLS_CONF_DIR}/httpd_config.conf"
    if [[ -f "$main" ]]; then
        backup_file_once "$main"
        # Directories worker config — key yang benar-benar ada di OLS:
        # 'maxConnections', 'checkCertRevocation'... Untuk worker kita set pada block
        # 'phpMyAdmin'/listener saja bila tersedia; hindari mengarang key.
        # Yang aman & terdokumentasi: jumlah proses lsapi child per app via env var.
        : # perubahan utama dilakukan lewat file lsapi context di vhost template
    fi

    # ---- LSPHP (lsapi app) melalui snippet include jika support ----
    local lsapi_snip="${STACK_DIR}/lsapi-tuning.conf"
    cat > "$lsapi_snip" <<EOF
# Hasil ols-stack tune profil ${p}
# Nilai ini dipakai template vhost (context lsapi) & php.ini drop-in.
PHP_LSAPI_CHILDREN=${PHP_CHILD_MAX}
LSAPI_REQUEST_TIMEOUT=30
LSAPI_IDLE_TIMEOUT=60
LSAPI_ALLOW_ENCODING=gzip
EOF

    # ---- php.ini drop-in utk lsphp (bukan override seluruh config bawaan) ----
    local phpd="/etc/php/${LS_PHP_VER}/litespeed/conf.d"
    if [[ -d "/etc/php/${LS_PHP_VER}" ]] || install -d -m 755 "/etc/php/${LS_PHP_VER}/litespeed/conf.d"; then
        cat > "${phpd}/99-ols-stack.ini" <<EOF
; Dihasilkan ols-stack tune (${p})
opcache.enable=1
opcache.memory_consumption=${PHP_FPC}
opcache.interned_strings_buffer=8
opcache.max_accelerated_files=10000
opcache.validate_timestamps=1
opcache.revalidate_freq=60
memory_limit=128M
upload_max_filesize=32M
post_max_size=32M
max_execution_time=60
realpath_cache_size=4096K
realpath_cache_ttl=600
EOF
        ok "PHP tuning ditulis ke ${phpd}/99-ols-stack.ini"
    else
        warn "Struktur /etc/php/${LS_PHP_VER} tak ditemukan — lewati php.ini tuning (cek manual)."
    fi

    # ---- MariaDB tuning kecil (drop-in, bukan replace my.cnf) ----
    install -d -m 755 /etc/mariadb.conf.d 2>/dev/null || true
    if [[ -d /etc/mysql/mariadb.conf.d ]]; then
        cat > /etc/mysql/mariadb.conf.d/99-ols-stack.cnf <<EOF
# Dihasilkan ols-stack tune (${p}) — jangan overcommit
[mysqld]
innodb_buffer_pool_size = ${INNO_BUF}
innodb_log_buffer_size  = 8M
key_buffer_size         = 16M
tmp_table_size          = 16M
max_heap_table_size     = 16M
query_cache_size        = 0
query_cache_type        = 0
max_connections         = $(( MY_SMALL ? 40 : 80 ))
performance_schema      = OFF
EOF
        systemctl restart mariadb >/dev/null 2>&1 || warn "MariaDB restart gagal — cek journalctl."
        ok "MariaDB tuning ditulis (innodb_buffer_pool_size=${INNO_BUF})."
    fi

    # ---- sysctl ringan (aman, reversibel) ----
    cat > /etc/sysctl.d/99-ols-stack.conf <<EOF
net.core.somaxconn = 1024
net.ipv4.tcp_fastopen = 3
vm.swappiness = 10
EOF
    sysctl --system >/dev/null 2>&1 || true

    # ---- Ringkasan ----
    local inno_mb="${INNO_BUF%M}" php_est=$(( PHP_CHILD_MAX * 40 ))
    local est=$(( inno_mb + php_est + 350 ))   # + OS/OLS/nginx-ish overhead ±350MB
    echo
    printf "${C_BLD}Ringkasan tuning profil %s:${C_RST}\n" "$p"
    printf "  PHP children max/domain : %s\n" "$PHP_CHILD_MAX"
    printf "  OLS worker processes    : %s (diusulkan)\n" "$LS_WORKERS"
    printf "  OPcache                 : %s\n" "$PHP_FPC"
    printf "  InnoDB buffer pool      : %s\n" "$INNO_BUF"
    printf "  Estimasi pemakaian puncak: ~%sMB dari %sMB RAM (didesain tanpa overcommit)\n" \
        "$est" "${RAM_MB:-?}"
    (( est > ${RAM_MB:-99999} )) && warn "Estimasi melebihi RAM! Turunkan profil atau aktifkan zram."
    reload_ols 2>/dev/null || true
}

tune_zram_enable() {
    require_root
    log "Mengaktifkan zram swap (opsional, utk RAM kecil) ..."
    apt_install zram-tools 2>/dev/null || apt_install util-linux
    if [[ -f /etc/default/zramswap ]]; then
        sed -i -E 's/^PERCENT=.*/PERCENT=10/' /etc/default/zramswap
        systemctl enable --now zramswap 2>/dev/null || true
    else
        # Fallback manual idempoten via systemd unit sederhana
        if [[ ! -f /etc/systemd/system/zram-create.service ]]; then
            cat > /etc/systemd/system/zram-create.service <<'EOF'
[Unit]
Description=Create zram swap (ols-stack)
Before=swap.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStartPre=/sbin/modprobe zram
ExecStart=/bin/sh -c 'echo 512M > /sys/block/zram0/disksize'
ExecStart=/sbin/mkswap /dev/zram0
ExecStart=/sbin/swapon -p 5 /dev/zram0
ExecStop=/sbin/swapoff /dev/zram0

[Install]
WantedBy=multi-user.target
EOF
        fi
        systemctl daemon-reload
        systemctl enable --now zram-create.service
    fi
    free -h | awk 'NR==1||/Swap|Mem/{print}'
    ok "zram aktif (±512MB–10% RAM)."
}
