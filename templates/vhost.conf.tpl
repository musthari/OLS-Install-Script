# Template konfigurasi OpenLiteSpeed vhost — ols-stack (Debian 13 trixie)
# Placeholder diisi oleh lib/domain.sh :: render_vhost()
#
# PRINSIP "JANGAN MENGARANG DIREKTIF":
# - Struktur virtualHost / domain / key / cert / rewrite / .htaccess / context lsapi
#   di bawah adalah sintaks httpd_config OLS yang terdokumentasi resmi.
# - Jail PHP per-domain TIDAK memakai nama direktif karangan. Implementasinya:
#     a) file drop-in php.ini per-domain (/etc/ols-stack/php-jail/<slug>/99-jail.ini)
#        yang disalin ke conf.d lsphp sehingga open_basedir/tmp/session/disable_functions
#        berlaku utk SELURUH request lsphp, dan
#     b) env PHPINIDIR pada context lsapi (opsional; bila versi OLS tidak mendukung,
#        biarkan kosong — drop-in conf.d tetap bekerja).
# - Verifikasi setelah reload: WebAdmin > Server > PHP atau `lsphp -i | grep open_basedir`.

virtualHost __SLUG__ {
  vhRoot                      /srv/www/__SLUG__/
  docRoot                     /srv/www/__SLUG__/public_html/
  allowSymbolLink             1
  enableScript                1
  authorizedGroup             __WEBUSER__

  # ---- Domain & SSL per-vhost (untuk listener HTTPS/SNI via Cloudflare Full) ----
  domain                      __DOMAIN__
  domain                      www.__DOMAIN__
  key                         __SSLDIR__/privkey.pem
  cert                        __SSLDIR__/fullchain.pem

  # ---- Rewrite WordPress (permalink) ----
  rewrite {
    enable                    1
    last                      1
    rule                      RewriteEngine On
    rule                      RewriteBase /
    rule                      RewriteRule ^index\.php$ - [L]
    rule                      RewriteCond %{REQUEST_FILENAME} !-f
    rule                      RewriteCond %{REQUEST_FILENAME} !-d
    rule                      RewriteRule . /index.php [L]
  }

  # ---- .htaccess (WordPress plugin sering menulis file ini) ----
  .htaccess {
    autoLoad                  1
  }

  # ---- Context PHP per-vhost (extlsapp 'lsphp' didefinisikan installer di config utama) ----
  context lsapi:__DEFAULT__ {
    location                  /srv/www/__SLUG__/public_html/
    allowAccess               1
    autoLoad                  1
    maxReqPerConn             10000
    failureBackoff            2
    starterCount              2
    env PHP_LSAPI_CHILDREN    $SERVER_PHP_CHILDREN
    env LSAPI_AUTO_START      yes
    env LSAPI_REQUEST_TIMEOUT 30
    env LSAPI_IDLE_TIMEOUT    60
  }

  # ---- Log akses per vhost ----
  accessLog {
    logFormat                 "%h %l %u %t \"%r\" %>s %b \"%{Referer}i\" \"%{User-Agent}i\""
  }
}
