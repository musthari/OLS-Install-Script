<?php
/**
 * mu-plugin: Cloudflare Real IP — ols-stack (Debian 13 trixie)
 *
 * Fungsi: memulihkan IP pengunjung asli di balik Cloudflare secara AMAN.
 *  - REMOTE_ADDR HANYA diganti jika koneksi asal benar-benar dari CIDR Cloudflare
 *    (daftar dibaca live dari cache /etc/ols-stack/cloudflare-ips.txt, refresh harian).
 *  - Tidak pernah mempercayai X-Forwarded-For dari IP non-Cloudflare.
 *  - Pasang sebagai mu-plugin => aktif sebelum plugin lain, utk LSCache/WAF/analytics WP.
 *
 * Lisensi: GPL-3.0
 */

if (!defined('ABSPATH')) { exit; }

define('OLS_CF_IPS_CACHE', '/etc/ols-stack/cloudflare-ips.txt');
define('OLS_CF_FETCH_URL', 'https://api.cloudflare.com/client/v4/ips');

/** Ambil daftar CIDR Cloudflare (cache lokal; fallback fetch langsung). */
function ols_cf_cidrs() {
    $cidrs = array();
    if (is_readable(OLS_CF_IPS_CACHE)) {
        $lines = file(OLS_CF_IPS_CACHE, FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES);
        foreach ($lines as $l) {
            if (strpos($l, '/') !== false) { $cidrs[] = trim($l); }
        }
    }
    if (!$cidrs) {
        // Fallback: fetch langsung dengan timeout pendek (hanya bila webserver bisa keluar)
        $ctx = stream_context_create(array('http' => array('timeout' => 5)));
        $json = @file_get_contents(OLS_CF_FETCH_URL, false, $ctx);
        if ($json) {
            $data = json_decode($json, true);
            if (!empty($data['success']) && !empty($data['result'])) {
                $r = $data['result'];
                foreach (array('ipv4_cidrs','ipv6_cidrs') as $k) {
                    if (!empty($r[$k])) { $cidrs = array_merge($cidrs, $r[$k]); }
                }
            }
        }
    }
    return $cidrs;
}

/** Cek IP dalam CIDR (IPv4 & IPv6, tanpa ekstensi). */
function ols_ip_in_cidr($ip, $cidr) {
    if (strpos($cidr, '/') === false) { return $ip === $cidr; }
    list($subnet, $bits) = explode('/', $cidr, 2);
    $bits = (int)$bits;
    $bin_ip     = @inet_pton($ip);
    $bin_subnet = @inet_pton($subnet);
    if ($bin_ip === false || $bin_subnet === false) { return false; }
    if (strlen($bin_ip) !== strlen($bin_subnet)) { return false; } // beda keluarga (v4 vs v6)
    $len = strlen($bin_ip) * 8;
    if ($bits > $len || $bits < 0) { return false; }
    $mask = '';
    for ($i = 0; $i < $len; $i += 8) {
        $remaining = $bits - $i;
        $byte_bits = $remaining >= 8 ? 8 : max($remaining, 0);
        $mask .= chr($byte_bits == 8 ? 0xFF : (0xFF << (8 - $byte_bits)) & 0xFF);
    }
    return ($bin_ip & $mask) === ($bin_subnet & $mask);
}

/** Jalankan secepat mungkin sebelum WP membaca REMOTE_ADDR untuk analytics/cache key. */
function ols_cloudflare_real_ip() {
    if (empty($_SERVER['REMOTE_ADDR'])) { return; }
    $real = isset($_SERVER['HTTP_CF_CONNECTING_IP']) ? trim($_SERVER['HTTP_CF_CONNECTING_IP']) : '';
    if ($real === '') { return; }
    $trusted = false;
    foreach (ols_cf_cidrs() as $cidr) {
        if (ols_ip_in_cidr($_SERVER['REMOTE_ADDR'], $cidr)) { $trusted = true; break; }
    }
    if ($trusted) {
        $_SERVER['REMOTE_ADDR_ORIG'] = $_SERVER['REMOTE_ADDR'];
        $_SERVER['REMOTE_ADDR'] = $real;
        // Beberapa plugin membaca header ini juga:
        $_SERVER['HTTP_X_REAL_IP'] = $real;
    }
}
add_action('muplugins_loaded', 'ols_cloudflare_real_ip', 1);

/**
 * Integrasi LiteSpeed Cache: pastikan cache key memakai IP yang sudah dipulihkan
 * bila plugin meminta 'real ip'. (Perilaku default LSCache + setting "Check Cloudflare"
 * tetap yang utama; mu-plugin ini pelapis aman.)
 */
add_filter('litespeed_conf_data', function ($val, $k) {
    if ($k === 'cache_cloudflare') { return true; }
    return $val;
}, 10, 2);
