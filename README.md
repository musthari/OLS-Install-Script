# OpenLiteSpeed + WordPress Stack Installer — Debian 13 (trixie)

Installer satu-perintah untuk stack WordPress production-ready di VPS kecil:
**OpenLiteSpeed + PHP terbaru (lsphp) + MariaDB + UFW + Fail2ban + Rclone backup streaming**,
dengan manajemen multi-domain via CLI `ols-stack`.

> ⚠️ **Spesifik Debian 13 "trixie".** Installer memverifikasi codename sistem DAN
> ketersediaan live repo LiteSpeed untuk `trixie`. Tidak pernah memakai repo rilis
> lain secara diam-diam.

## Komponen & keputusan desain

| Kebutuhan | Implementasi |
|---|---|
| Web server | OpenLiteSpeed dari repo resmi `rpms.litespeedtech.com/debian` (codename `trixie`) |
| PHP | Versi **tertinggi yang tersedia di repo LiteSpeed** (dibaca live dari index `Packages`, fallback default dengan peringatan) |
| Database | MariaDB, hardened non-interaktif; root tetap `unix_socket`; DB+user unik per domain |
| Firewall | UFW `deny incoming`; allow hanya SSH/80/443; port admin **7080 di-deny publik** |
| Admin OLS | Di-bind ke `127.0.0.1:7080`; password generate acak → file mode **600** |
| Anti-brute | Fail2ban jail `sshd` saja (`--no-fail2ban` utk melewati) |
| Multi-domain | `ols-stack add-domain <tld>` / `remove-domain` / `list-domains` — idempoten |
| SFTP jailed | User `<slug>sftp` grup `sftpusers`, `ChrootDirectory %h`, `ForceCommand internal-sftp` (blok `Match` di sshd_config, divalidasi `sshd -t` sebelum reload) |
| PHP jail | Drop-in `conf.d` lsphp per-domain: `open_basedir`, `upload_tmp_dir` & `sys_temp_dir` di `/run` (tmpfs), `session.save_path` privat, `disable_functions` aman-WordPress |
| SSL Cloudflare | Default self-signed origin (mode CF **Full**) atau `--cert/--key` Origin CA/custom (**Full Strict**) |
| Real IP | Range IP CF diambil **live** dari `api.cloudflare.com/client/v4/ips`; native bila didukung + mu-plugin WP yang mengganti `REMOTE_ADDR` **hanya** jika koneksi asal termasuk CIDR Cloudflare |
| Performa | Profil tuning `auto|1g|2g|4g` (PHP children, OPcache, InnoDB buffer pool, sysctl) — dirancang tanpa overcommit RAM |
| Backup harian | `tar \| gzip \| rclone rcat` (streaming, **tanpa arsip persisten di disk**; fallback temp hanya tmpfs `/run`), per domain: `files.tar.gz` + `database.sql.gz` + `manifest.json` |
| Retensi | **7 set backup lengkap** (bukan 7 file) — hitung & prune hanya pada set yang punya ketiga artefak |
| Restore | Daftar backup terformat + konfirmasi ketik `YA`; file di-restore via `rclone cat \| tar -xz` streaming ke tmpfs |
| Kredensial | Disimpan di `/etc/ols-stack/credentials/<slug>.conf` **chmod 600**, tidak pernah dicetak ke stdout |
| Konfig lama | Selalu dibackup `.orig` sekali sebelum diubah; seluruh operasi idempoten |
| Optimasi WP | Auto-install WordPress core (WP-CLI phar resmi), salts API resmi (fallback generate lokal), prefix tabel random, plugin **LiteSpeed Cache** aktif, WooCommerce-aware, cache purge saat restore |

## Instalasi cepat

```bash
git clone https://github.com/dokeshibe/openlitespeed-stack.git
cd openlitespeed-stack
sudo bash install-openlitespeed-stack.sh \
     --domain contoh.com \
     --tune auto \
     --rclone-remote gdrive: \
     --yes
```

Opsi installer:

```
--domain <tld>            Tambah domain pertama + auto-install WordPress
--cert F --key F          Sertifikat Origin CA/custom (Cloudflare Full Strict)
--admin-pass <pw>         Password WebAdmin OLS (default: acak, disimpan 600)
--tune <auto|1g|2g|4g>    Profil tuning RAM (default: auto)
--no-fail2ban             Lewati fail2ban
--rclone-remote <name:>   Remote rclone yang sudah ada di konfigurasi
--yes                     Non-interaktif
```

## CLI `ols-stack`

```bash
ols-stack add-domain toko.id            # vhost+jail+DB+SSL+WP otomatis
ols-stack add-domain blog.id --cert o.crt --key o.key   # Origin CA / Full Strict
ols-stack list-domains
ols-stack remove-domain blog.id         # destruktif, konfirmasi 'YA' (--yes utk scripted)
ols-stack optimize-wp                   # pastikan WP+LSCache di semua domain
ols-stack secure-admin                  # re-kunci panel 7080 ke loopback
ols-stack update-cf-ips                 # refresh CIDR Cloudflare (realIPList + mu-plugin)
ols-stack tune 2g                       # profil manual; ols-stack zram utk swap RAM kecil
ols-stack backup --setup                # rclone config interaktif + simpan remote
ols-stack backup [domain]               # jalankan sekarang (cron otomatis setelah setup)
ols-stack list-backups toko.id          # tabel: nomor, timestamp, LENGKAP/RUSAK, ukuran
ols-stack restore toko.id [nomor]       # restore streaming + fix permission + purge cache
ols-stack rclone-test                   # verifikasi tulis-baca-hapus remote
ols-stack status                        # service, firewall, daftar domain, path kredensial
```

## Arsitektur direktori

```
/srv/www/<slug>/public_html        document root WordPress (user web_<slug>)
/srv/www/<slug>/private/sessions   session PHP privat
/run/ols-stack/<slug>              upload/sys temp tmpfs per-domain (hilang saat reboot)
/usr/local/lsws/<slug>/www         symlink dlm chroot SFTP -> public_html
/etc/ols-stack/                    stack.conf, php-jail/, ssl/, credentials/ (700/600)
/var/log/ols-stack.log             log operasi
```

## Catatan verifikasi penting (jangan dianggap tersirat)

1. **Repo trixie**: ketersediaan `dists/trixie` diverifikasi LIVE saat install; bila belum
   tersedia, installer **berhenti** dan menjelaskan opsi aman — bukan substitusi diam-diam.
2. **Real IP**: dukungan directive native (`realIPList`) dideteksi dari binary, tidak
   diasumsikan; fallback selalu aktif lewat mu-plugin (anti-spoof karena cek CIDR asal).
3. **PHP jail bersama**: lsphp instance tunggal = drop-in conf.d berlaku global; isolasi
   antar-domain dicapai lewat `open_basedir` + user unix berbeda. Untuk hard-isolation
   penuh, jalankan extlsapp terpisah per vhost (WebAdmin) — stack ini sengaja tidak
   mengarang sintaks multi-instance.
4. **Selalu uji di VPS staging** sebelum produksi: `bash -n` lolos ≠ perilaku runtime.

## Struktur repo

```
install-openlitespeed-stack.sh   # entrypoint instalasi
ols-stack                        # CLI manajemen pasca-instal
lib/common.sh                    # logging, validasi, util
lib/install.sh                   # repo, paket, hardening
lib/domain.sh                    # vhost/jail/DB/SSL/add-remove-list
lib/realip.sh                    # Cloudflare Real IP
lib/tune.sh                      # profil performa + zram
lib/backup.sh                    # rclone streaming + retensi set + cron
lib/restore.sh                   # restore + permission + WP/LSCache optimasi
templates/vhost.conf.tpl         # template vhost OLS
templates/mu-plugin-cloudflare-real-ip.php
```

## Lisensi

GPL-3.0