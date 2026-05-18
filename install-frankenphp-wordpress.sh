#!/bin/bash
# ==========================================
# FrankenPHP + WordPress Auto Install Script
# Supports: Debian 12 / Ubuntu 20.04+
# ==========================================

# Warna untuk output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# ==========================================
# Helper Functions
# ==========================================
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "Script ini harus dijalankan sebagai root (sudo)."
        exit 1
    fi
}

check_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$NAME
        VER=$VERSION_ID
    else
        log_error "Sistem operasi tidak didukung atau tidak terdeteksi."
        exit 1
    fi
    log_info "Terdeteksi OS: $OS $VER"
}

# ==========================================
# 1. Update Sistem
# ==========================================
step_update_system() {
    log_info "1. Update Sistem..."
    apt update && apt upgrade -y
    log_success "Sistem berhasil diupdate."
}

# ==========================================
# 2. Instalasi Paket Dasar
# ==========================================
step_install_basics() {
    log_info "2. Instalasi Paket Dasar..."
    apt install -y apt-transport-https ca-certificates \
        certbot curl cron git gnupg lsb-release \
        software-properties-common supervisor \
        unzip wget
    log_success "Paket dasar terinstall."
}

# ==========================================
# 3 & 4. Konfigurasi Firewall
# ==========================================
step_setup_firewall() {
    log_info "3. Konfigurasi Firewall (UFW)..."
    apt install -y ufw
    ufw allow ssh
    ufw allow http
    ufw allow https
    ufw allow 3306 # MySQL
    echo "y" | ufw enable
    log_info "4. Status Firewall:"
    ufw status
}

# ==========================================
# 5. Instalasi PHP
# ==========================================
step_install_php() {
    log_info "5. Instalasi PHP..."

    echo "Pilih versi PHP yang ingin diinstall:"
    echo "1) PHP 8.4"
    echo "2) PHP 8.3"
    read -p "Masukkan pilihan (1/2): " php_choice

    # Setup Repo
    if [[ "$ID" == "ubuntu" ]]; then
        add-apt-repository -y ppa:ondrej/php
    elif [[ "$ID" == "debian" ]]; then
        curl -sSLo /usr/share/keyrings/deb.sury.org-php.gpg https://packages.sury.org/php/apt.gpg
        sh -c 'echo "deb [signed-by=/usr/share/keyrings/deb.sury.org-php.gpg] https://packages.sury.org/php/ $(lsb_release -sc) main" > /etc/apt/sources.list.d/php.list'
        apt update
    fi

    case $php_choice in
        1) PHP_VER="8.4" ;;
        2) PHP_VER="8.3" ;;
        *) PHP_VER="8.4" ;;
    esac

    if ! apt-cache show php$PHP_VER > /dev/null 2>&1; then
        log_warning "PHP $PHP_VER tidak ditemukan. Menggunakan PHP 8.3 sebagai fallback."
        PHP_VER="8.3"
    fi

    log_info "Menginstall PHP $PHP_VER..."
    apt install -y php$PHP_VER php$PHP_VER-cli php$PHP_VER-common php$PHP_VER-fpm \
        php$PHP_VER-mysql php$PHP_VER-zip php$PHP_VER-gd \
        php$PHP_VER-mbstring php$PHP_VER-curl php$PHP_VER-xml php$PHP_VER-bcmath \
        php$PHP_VER-intl php$PHP_VER-soap php$PHP_VER-imagick php$PHP_VER-opcache

    # Optimasi php.ini untuk WordPress
    PHP_INI="/etc/php/$PHP_VER/fpm/php.ini"
    if [ -f "$PHP_INI" ]; then
        sed -i 's/upload_max_filesize = .*/upload_max_filesize = 64M/' "$PHP_INI"
        sed -i 's/post_max_size = .*/post_max_size = 64M/' "$PHP_INI"
        sed -i 's/memory_limit = .*/memory_limit = 256M/' "$PHP_INI"
        sed -i 's/max_execution_time = .*/max_execution_time = 300/' "$PHP_INI"
        sed -i 's/max_input_vars = .*/max_input_vars = 3000/' "$PHP_INI"
    fi

    log_success "PHP $PHP_VER berhasil diinstall dan dioptimasi untuk WordPress."
}

# ==========================================
# 6. Instalasi Composer (Opsional untuk WP plugins)
# ==========================================
step_install_composer() {
    log_info "6. Instalasi Composer..."
    curl -sS https://getcomposer.org/installer | php
    mv composer.phar /usr/local/bin/composer
    chmod +x /usr/local/bin/composer
    log_success "Composer terinstall: $(composer --version)"
}

# ==========================================
# 7. Instalasi Node.js & NPM (Opsional)
# ==========================================
step_install_node() {
    log_info "7. Instalasi Node.js & NPM..."
    curl -fsSL https://deb.nodesource.com/setup_lts.x | bash -
    apt install -y nodejs
    log_success "Node.js $(node -v) dan npm $(npm -v) terinstall."
}

# ==========================================
# 8. Instalasi Database (MariaDB untuk WordPress)
# ==========================================
step_install_db() {
    log_info "8. Instalasi MariaDB untuk WordPress..."
    apt install -y mariadb-server
    systemctl enable mariadb
    systemctl start mariadb

    # Buat database dan user untuk WordPress
    echo ""
    read -p "Masukkan nama database WordPress (default: wordpress_db): " WP_DB_NAME
    WP_DB_NAME=${WP_DB_NAME:-wordpress_db}

    read -p "Masukkan username database (default: wp_user): " WP_DB_USER
    WP_DB_USER=${WP_DB_USER:-wp_user}

    read -sp "Masukkan password database: " WP_DB_PASS
    echo ""

    if [[ -z "$WP_DB_PASS" ]]; then
        WP_DB_PASS=$(openssl rand -base64 16)
        log_warning "Password tidak diisi, generated password: $WP_DB_PASS"
        log_warning "SIMPAN PASSWORD INI!"
    fi

    mysql -e "CREATE DATABASE IF NOT EXISTS \`$WP_DB_NAME\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
    mysql -e "CREATE USER IF NOT EXISTS '$WP_DB_USER'@'localhost' IDENTIFIED BY '$WP_DB_PASS';"
    mysql -e "GRANT ALL PRIVILEGES ON \`$WP_DB_NAME\`.* TO '$WP_DB_USER'@'localhost';"
    mysql -e "FLUSH PRIVILEGES;"

    log_success "MariaDB terinstall. Database '$WP_DB_NAME' dan user '$WP_DB_USER' dibuat."
}

# ==========================================
# 9. Instalasi FrankenPHP
# ==========================================
step_install_frankenphp() {
    log_info "9. Instalasi FrankenPHP..."

    # Download latest stable binary
    ARCH=$(uname -m)
    if [[ "$ARCH" == "x86_64" ]]; then
        FRANKEN_URL="https://github.com/dunglas/frankenphp/releases/latest/download/frankenphp-linux-x86_64"
    elif [[ "$ARCH" == "aarch64" ]]; then
        FRANKEN_URL="https://github.com/dunglas/frankenphp/releases/latest/download/frankenphp-linux-aarch64"
    else
        log_error "Arsitektur $ARCH tidak didukung."
        exit 1
    fi

    curl -L "$FRANKEN_URL" -o /usr/local/bin/frankenphp
    chmod +x /usr/local/bin/frankenphp

    log_success "FrankenPHP binary terinstall di /usr/local/bin/frankenphp"
}

# ==========================================
# 10. Download & Install WordPress
# ==========================================
step_install_wordpress() {
    log_info "10. Download dan Install WordPress..."

    echo ""
    read -p "Masukkan Nama Domain (contoh: example.com): " DOMAIN_NAME
    if [[ -z "$DOMAIN_NAME" ]]; then
        log_error "Domain tidak boleh kosong."
        exit 1
    fi

    APP_DIR="/var/www/$DOMAIN_NAME"
    mkdir -p "$APP_DIR"

    # Download WordPress
    cd /tmp
    wget -q https://wordpress.org/latest.tar.gz
    tar -xzf latest.tar.gz
    cp -a wordpress/. "$APP_DIR/"
    rm -rf wordpress latest.tar.gz

    # Setup wp-config.php
    cp "$APP_DIR/wp-config-sample.php" "$APP_DIR/wp-config.php"

    # Konfigurasi database di wp-config.php
    sed -i "s/database_name_here/$WP_DB_NAME/" "$APP_DIR/wp-config.php"
    sed -i "s/username_here/$WP_DB_USER/" "$APP_DIR/wp-config.php"
    sed -i "s/password_here/$WP_DB_PASS/" "$APP_DIR/wp-config.php"

    # Generate WordPress Security Keys
    SALT=$(curl -s https://api.wordpress.org/secret-key/1.1/salt/)
    if [[ -n "$SALT" ]]; then
        # Hapus placeholder keys dan ganti dengan yang baru
        sed -i '/AUTH_KEY/d' "$APP_DIR/wp-config.php"
        sed -i '/SECURE_AUTH_KEY/d' "$APP_DIR/wp-config.php"
        sed -i '/LOGGED_IN_KEY/d' "$APP_DIR/wp-config.php"
        sed -i '/NONCE_KEY/d' "$APP_DIR/wp-config.php"
        sed -i '/AUTH_SALT/d' "$APP_DIR/wp-config.php"
        sed -i '/SECURE_AUTH_SALT/d' "$APP_DIR/wp-config.php"
        sed -i '/LOGGED_IN_SALT/d' "$APP_DIR/wp-config.php"
        sed -i '/NONCE_SALT/d' "$APP_DIR/wp-config.php"
        sed -i "/@-*/a $SALT" "$APP_DIR/wp-config.php"
    fi

    # Set permissions
    chown -R www-data:www-data "$APP_DIR"
    find "$APP_DIR" -type d -exec chmod 755 {} \;
    find "$APP_DIR" -type f -exec chmod 644 {} \;

    log_success "WordPress berhasil didownload dan dikonfigurasi di $APP_DIR"
}

# ==========================================
# 11. Konfigurasi FrankenPHP + Caddyfile untuk WordPress
# ==========================================
step_configure_frankenphp_wordpress() {
    log_info "11. Konfigurasi FrankenPHP untuk WordPress..."

    echo "Pilih Mode Web Server:"
    echo "1) Nginx sebagai Reverse Proxy ke FrankenPHP"
    echo "2) FrankenPHP Standalone (Auto SSL, recommended)"
    read -p "Pilihan (1/2): " WEB_MODE

    # Buat Caddyfile untuk WordPress
    mkdir -p /etc/frankenphp

    if [[ "$WEB_MODE" == "2" ]]; then
        # Standalone mode - FrankenPHP handle SSL otomatis
        cat > /etc/frankenphp/Caddyfile <<EOF
{
    email admin@$DOMAIN_NAME
    frankenphp
}

$DOMAIN_NAME {
    root * $APP_DIR
    encode zstd gzip

    # WordPress permalink support
    @notStatic {
        not path /wp-includes/* /wp-content/*
        not file
    }
    rewrite @notStatic /index.php

    # PHP handling
    php_server

    # Security headers
    header {
        X-Content-Type-Options nosniff
        X-Frame-Options SAMEORIGIN
        Referrer-Policy strict-origin-when-cross-origin
    }

    # Block access to sensitive files
    @blocked {
        path /wp-config.php
        path /.htaccess
        path /readme.html
        path /license.txt
    }
    respond @blocked 403

    # Static file caching
    @static {
        path *.css *.js *.ico *.gif *.jpg *.jpeg *.png *.svg *.woff *.woff2
    }
    header @static Cache-Control "public, max-age=31536000"
}
EOF

        # Supervisor config - Standalone
        cat > /etc/supervisor/conf.d/frankenphp-$DOMAIN_NAME.conf <<EOF
[program:frankenphp-$DOMAIN_NAME]
command=/usr/local/bin/frankenphp run --config /etc/frankenphp/Caddyfile
autostart=true
autorestart=true
user=root
redirect_stderr=true
stdout_logfile=/var/log/frankenphp-$DOMAIN_NAME.log
stdout_logfile_maxbytes=10MB
EOF

        # Set capability untuk bind port 80/443
        setcap CAP_NET_BIND_SERVICE=+eip /usr/local/bin/frankenphp

        # Stop nginx jika aktif
        systemctl stop nginx 2>/dev/null || true
        systemctl disable nginx 2>/dev/null || true

        log_info "SSL akan ditangani otomatis oleh FrankenPHP (Caddy)."

    else
        # Nginx reverse proxy mode
        FRANKEN_PORT="8080"

        cat > /etc/frankenphp/Caddyfile <<EOF
{
    frankenphp
    auto_https off
    admin off
}

:$FRANKEN_PORT {
    root * $APP_DIR
    encode zstd gzip

    @notStatic {
        not path /wp-includes/* /wp-content/*
        not file
    }
    rewrite @notStatic /index.php

    php_server
}
EOF

        # Supervisor config - Behind Nginx
        cat > /etc/supervisor/conf.d/frankenphp-$DOMAIN_NAME.conf <<EOF
[program:frankenphp-$DOMAIN_NAME]
command=/usr/local/bin/frankenphp run --config /etc/frankenphp/Caddyfile
autostart=true
autorestart=true
user=www-data
redirect_stderr=true
stdout_logfile=/var/log/frankenphp-$DOMAIN_NAME.log
stdout_logfile_maxbytes=10MB
EOF

        # Install & Configure Nginx
        apt install -y nginx python3-certbot-nginx

        cat > /etc/nginx/sites-available/$DOMAIN_NAME <<EOF
server {
    listen 80;
    server_name $DOMAIN_NAME;

    client_max_body_size 64M;

    location / {
        proxy_pass http://127.0.0.1:$FRANKEN_PORT;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_buffering off;
    }

    # Cache static files at Nginx level
    location ~* \.(css|js|ico|gif|jpg|jpeg|png|svg|woff|woff2)$ {
        proxy_pass http://127.0.0.1:$FRANKEN_PORT;
        proxy_set_header Host \$host;
        expires 30d;
        add_header Cache-Control "public, immutable";
    }
}
EOF

        ln -sf /etc/nginx/sites-available/$DOMAIN_NAME /etc/nginx/sites-enabled/
        rm -f /etc/nginx/sites-enabled/default
        nginx -t && systemctl restart nginx

        # SSL dengan Certbot
        log_info "Setup SSL dengan Certbot..."
        certbot --nginx -d $DOMAIN_NAME --non-interactive --agree-tos -m admin@$DOMAIN_NAME
    fi

    # Restart Supervisor
    supervisorctl reread
    supervisorctl update
    supervisorctl restart frankenphp-$DOMAIN_NAME 2>/dev/null || true

    log_success "FrankenPHP dikonfigurasi untuk WordPress."
}

# ==========================================
# 12. Install WP-CLI (Bonus)
# ==========================================
step_install_wpcli() {
    log_info "12. Instalasi WP-CLI..."
    curl -O https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar
    chmod +x wp-cli.phar
    mv wp-cli.phar /usr/local/bin/wp
    log_success "WP-CLI terinstall: $(wp --info --allow-root | grep 'WP-CLI version')"
}

# ==========================================
# 13. Tampilkan Status & Info
# ==========================================
step_show_status() {
    echo ""
    echo "=========================================="
    echo -e "${GREEN}  INSTALASI SELESAI!${NC}"
    echo "=========================================="
    echo ""
    echo "Informasi Server:"
    echo "-----------------------------------"
    echo "Domain:       $DOMAIN_NAME"
    echo "WordPress:    $APP_DIR"
    echo "FrankenPHP:   $(/usr/local/bin/frankenphp version 2>/dev/null || echo 'installed')"
    echo "PHP CLI:      $(php -v | head -n 1)"
    echo "MariaDB:      $(mysql --version 2>/dev/null || echo 'not installed')"
    echo "WP-CLI:       $(wp --version --allow-root 2>/dev/null || echo 'not installed')"
    echo "Node.js:      $(node -v 2>/dev/null || echo 'not installed')"
    echo "-----------------------------------"
    echo ""
    echo "Database Info:"
    echo "-----------------------------------"
    echo "DB Name:      $WP_DB_NAME"
    echo "DB User:      $WP_DB_USER"
    echo "DB Pass:      $WP_DB_PASS"
    echo "-----------------------------------"
    echo ""
    echo -e "${YELLOW}LANGKAH SELANJUTNYA:${NC}"
    echo "1. Arahkan DNS domain $DOMAIN_NAME ke IP server ini"
    echo "2. Buka https://$DOMAIN_NAME di browser"
    echo "3. Ikuti wizard instalasi WordPress"
    echo "4. Selesai!"
    echo ""
    echo -e "${YELLOW}PERINTAH BERGUNA:${NC}"
    echo "  supervisorctl status                    # Cek status FrankenPHP"
    echo "  supervisorctl restart frankenphp-$DOMAIN_NAME  # Restart FrankenPHP"
    echo "  wp plugin list --path=$APP_DIR --allow-root    # List WP plugins"
    echo ""
    log_success "Selamat! WordPress + FrankenPHP siap digunakan."
}

# ==========================================
# Main Execution
# ==========================================
check_root
check_os
step_update_system
step_install_basics
step_setup_firewall
step_install_php
step_install_composer
step_install_node
step_install_db
step_install_frankenphp
step_install_wordpress
step_configure_frankenphp_wordpress
step_install_wpcli
step_show_status

exit 0
