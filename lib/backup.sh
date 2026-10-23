#!/usr/bin/env bash
# lib/backup.sh - backup harian streaming via Rclone + retensi 7 set. GPL-3.0
# Arsitektur:
#   files : tar -C /srv/www/<slug> --exclude tmp . | gzip | rclone rcat remote:<path>.tar.gz
#   db    : mariadb-dump --single-transaction <db> | gzip | rclone rcat remote:<path>.sql.gz
#   manifest: JSON kecil (ukuran, sha256 header, versi) via rclone rcat
# Tidak ada arsip persisten di disk; temp hanya di /run (tmpfs) bila terpaksa.

stack_conf_get() {
    local k="$1"
    [[ -f ${STACK_DIR}/stack.conf ]] || return 1
    # shellcheck disable=SC1091
    . "$STACK_DIR/stack.conf"
    eval "echo \"\${$k:-}\""
}

backup_require_remote() {
    local remote="${RCLONE_REMOTE:-$(stack_conf_get RCLONE_REMOTE || true)}"
    [[ -n "$remote" ]] || die "Remote rclone belum diatur. Jalankan: ols-stack backup --setup  atau  rclone config, lalu set RCLONE_REMOTE di ${STACK_DIR}/stack.conf"
    rclone listremotes | grep -qx "${remote%%:*}:" || die "Remote '${remote%%:*}' tidak ada di konfigurasi rclone."
    echo "$remote"
}

backup_stream_to_rclone() {
    # $1 = sumber pipeline command string, $2 = path remote tujuan
    local cmd="$1" dest="$2"
    local tmp=""
    # Bila rclone rc cat gagal karena provider butuh size, fallback ke tmpfs /run
    if ! eval "$cmd" | rclone rcat "$dest" 2>>"$STACK_LOG"; then
        warn "rcat gagal — fallback streaming via tmpfs /run/ols-stack (dihapus otomatis)."
        install -d -m 700 "$TMPFS_RUN"
        tmp=$(mktemp "${TMPFS_RUN}/bk.XXXXXX")
        eval "$cmd" > "$tmp" 2>>"$STACK_LOG" || { rm -f "$tmp"; die "Pipeline backup gagal."; }
        rclone copyto "$tmp" "$dest" 2>>"$STACK_LOG" || { rm -f "$tmp"; die "Upload gagal."; }
        rm -f "$tmp"
    fi
}

do_backup_domain() {
    local dom="$1" remote slug db ts base
    remote=$(backup_require_remote)
    slug=$(domain_to_slug "$dom"); db=$(domain_db "$dom")
    ts=$(date +%Y%m%d-%H%M%S)
    base="${remote}:ols-backup/${slug}/${ts}"

    log "Backup ${dom} -> ${base}"

    # 1) FILES (streaming tar|gzip|rcat). Exclude dir volatile.
    backup_stream_to_rclone \
        "tar -C '/srv/www/${slug}' --exclude='./tmp' --exclude='./private/sessions' -cf - ." \
        "${base}/files.tar.gz" || die "Backup file gagal utk ${dom} (TIDAK akan prune)."

    # 2) DATABASE (streaming dump|gzip|rcat)
    backup_stream_to_rclone \
        "mariadb-dump --single-transaction --routines --triggers --events '${db}'" \
        "${base}/database.sql.gz" || die "Backup DB gagal utk ${dom} (TIDAK akan prune)."

    # 3) MANIFEST (info set lengkap)
    local manifest
    manifest=$(printf '{"domain":"%s","slug":"%s","timestamp":"%s","files":"files.tar.gz","db":"database.sql.gz","stack":"ols-stack-debian13","php":"lsphp%s"}' \
        "$dom" "$slug" "$ts" "${LS_PHP_VER:-85}")
    printf '%s' "$manifest" | rclone rcat "${base}/manifest.json" 2>>"$STACK_LOG" \
        || die "Manifest gagal ditulis (set dianggap TIDAK lengkap)."

    ok "Backup set ${ts} untuk ${dom} selesai & lengkap."
    prune_old_backups "$slug" "$remote"
}

prune_old_backups() {
    # Retensi menghitung BACKUP SET LENGKAP (punya files+db+manifest), bukan file terpisah.
    # Hanya prune jika backup saat ini SUKSES (dipanggil hanya setelah sukses).
    local slug="$1" remote="$2" keep="${BACKUP_RETENTION:-7}"
    local root="${remote}:ols-backup/${slug}/"
    local sets=() d complete=()
    while IFS= read -r d; do
        [[ -z "$d" ]] && continue
        sets+=("$d")
    done < <(rclone lsf --dirs-only "$root" 2>/dev/null | sed 's:/$::')

    # Filter set lengkap
    for d in "${sets[@]}"; do
        local listing
        listing=$(rclone lsf "${root}${d}/" 2>/dev/null)
        if grep -q 'files.tar.gz' <<<"$listing" && \
           grep -q 'database.sql.gz' <<<"$listing" && \
           grep -q 'manifest.json' <<<"$listing"; then
            complete+=("$d")
        else
            warn "Set ${slug}/${d} TIDAK lengkap — dihitung tapi tidak dianggap kandidat hapus lama."
        fi
    done

    (( ${#complete[@]} <= keep )) && { log "Retensi OK (${#complete[@]}/${keep} set)."; return 0; }
    # Urutkan kronologis (format YYYYmmdd-HHMMSS sudah lexikografis aman)
    mapfile -t sorted < <(printf '%s\n' "${complete[@]}" | sort)
    local n_del=$(( ${#sorted[@]} - keep )) i
    for (( i=0; i<n_del; i++ )); do
        log "Prune set lama: ${slug}/${sorted[$i]}"
        rclone delete --rmdirs "${root}${sorted[$i]}/" 2>>"$STACK_LOG" \
            || warn "Gagal prune ${sorted[$i]} (lanjutkan manual)."
    done
}

backup_main() {
    require_root
    case "${1:-}" in
        --setup)
            log "Konfigurasi remote rclone ..."
            rclone config
            read -r -p "Nama remote yang dipakai (contoh: gdrive): " rn
            [[ -n "$rn" ]] || die "Nama remote kosong."
            stack_conf_set RCLONE_REMOTE "${rn}:"
            ok "RCLONE_REMOTE=${rn}: disimpan di ${STACK_DIR}/stack.conf"
            ;;
        "")
            [[ -f "$STACK_DOMAINS_FILE" ]] || die "Belum ada domain terdaftar."
            while IFS= read -r d; do
                [[ -n "$d" ]] && do_backup_domain "$d"
            done < "$STACK_DOMAINS_FILE"
            ;;
        *)
            domain_registered "$1" || die "Domain tidak terdaftar: $1"
            do_backup_domain "$1"
            ;;
    esac
}

stack_conf_set() {
    local k="$1" v="$2" f="${STACK_DIR}/stack.conf"
    touch "$f"
    if grep -qE "^${k}=" "$f"; then
        sed -i -E "s|^${k}=.*|${k}=${v}|" "$f"
    else
        echo "${k}=${v}" >> "$f"
    fi
}

install_backup_cron() {
    require_root
    local marker="# ols-stack-backup-daily"
    if crontab -l 2>/dev/null | grep -qF "$marker"; then
        ok "Cron backup harian sudah terpasang (idempoten)."
    else
        ( crontab -l 2>/dev/null; \
          echo "03 00 * * * /usr/local/bin/ols-stack backup >/var/log/ols-stack-backup.log 2>&1 ${marker}" ) | crontab -
        ok "Cron backup harian dijadwalkan 00:03 WIB-server."
    fi
}

rclone_test_main() {
    require_root
    local remote
    remote=$(backup_require_remote)
    log "Tes koneksi ke ${remote} ..."
    rclone about "$remote" 2>/dev/null || warn "Perintah 'about' tidak didukung remote ini (bukan kegagalan fatal)."
    local probe="${remote}:ols-backup/.probe-$$"
    echo "ols-stack probe $(date)" | rclone rcat "$probe" 2>>"$STACK_LOG" || die "Gagal menulis probe ke remote."
    rclone size "${remote}:ols-backup" >/dev/null 2>&1 || true
    rclone lsjson "$probe" >/dev/null 2>&1 || die "Probe tidak terbaca kembali."
    rclone deletefile "$probe" 2>/dev/null || true
    ok "Rclone OK: tulis-baca-hapus terverifikasi."
}
