#!/bin/bash
set -euo pipefail

red=$(tput setaf 1)
green=$(tput setaf 2)
yellow=$(tput setaf 3)
reset=$(tput sgr0)

# Function to execute commands with error checking
execute() {
    echo "${green}==> $1${reset}"
    if ! eval "$2"; then
        echo "${red}Error executing: $2${reset}"
        exit 1
    fi
}

info() { echo "${yellow}--> $1${reset}"; }

# Must be root
if [ "$(id -u)" -ne 0 ]; then
    echo "${red}This script must be run as root.${reset}"
    exit 1
fi

# Versions (override via environment variables if needed)
PHP_VERSION="${PHP_VERSION:-8.3}"
NODE_MAJOR="${NODE_MAJOR:-22}"   # Node.js LTS

# Detect resources for tuning
TOTAL_MEM_KB=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
TOTAL_MEM_MB=$((TOTAL_MEM_KB / 1024))
CPU_CORES=$(nproc)
info "Detected: ${CPU_CORES} CPU cores, ${TOTAL_MEM_MB} MB RAM"

export DEBIAN_FRONTEND=noninteractive

# ---------------------------------------------------------------------------
# Base system update and tooling
# ---------------------------------------------------------------------------
execute "Updating system" "apt update -y && apt upgrade -y"
execute "Installing basic dependencies" "apt install -y -q curl wget gnupg ca-certificates lsb-release apt-transport-https software-properties-common unzip rsync htop mc git ufw fail2ban unattended-upgrades chrony logrotate"

# Set timezone (default Europe/Moscow, override via TZ env var)
execute "Setting timezone" "timedatectl set-timezone ${TZ:-Europe/Moscow}"
execute "Enabling time sync" "systemctl enable --now chrony"

# ---------------------------------------------------------------------------
# Kernel / sysctl optimizations
# ---------------------------------------------------------------------------
execute "Applying sysctl tuning" "cat > /etc/sysctl.d/99-bxlamp.conf << 'EOF'
# Network tuning
net.core.somaxconn = 65535
net.core.netdev_max_backlog = 65535
net.ipv4.tcp_max_syn_backlog = 65535
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 5
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_mtu_probing = 1

# File handles
fs.file-max = 2097152
fs.inotify.max_user_watches = 524288

# Memory
vm.swappiness = 10
vm.vfs_cache_pressure = 50
vm.overcommit_memory = 1
EOF
sysctl --system >/dev/null"

execute "Raising file descriptor limits" "cat > /etc/security/limits.d/99-bxlamp.conf << 'EOF'
* soft nofile 65535
* hard nofile 65535
root soft nofile 65535
root hard nofile 65535
EOF"

# Swap file (create if missing and RAM is small)
if ! swapon --show | grep -q '/swapfile' && [ "${TOTAL_MEM_MB}" -lt 4096 ]; then
    SWAP_SIZE_MB=$((TOTAL_MEM_MB * 2))
    info "Creating ${SWAP_SIZE_MB}MB swap file"
    execute "Allocating swap" "fallocate -l ${SWAP_SIZE_MB}M /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile"
    if ! grep -q '/swapfile' /etc/fstab; then
        echo "/swapfile none swap sw 0 0" >> /etc/fstab
    fi
fi

# ---------------------------------------------------------------------------
# Unattended security upgrades
# ---------------------------------------------------------------------------
execute "Enabling unattended security upgrades" "dpkg-reconfigure -f noninteractive unattended-upgrades"

# ---------------------------------------------------------------------------
# Nginx
# ---------------------------------------------------------------------------
execute "Installing Nginx" "apt install -y -q nginx"
execute "Installing Certbot" "apt install -y -q certbot python3-certbot-nginx"

# ---------------------------------------------------------------------------
# PHP
# ---------------------------------------------------------------------------
execute "Adding PHP repository" "add-apt-repository -y ppa:ondrej/php"
execute "Updating packages" "apt update -y"
execute "Installing PHP ${PHP_VERSION} and extensions" "apt install -y -q php${PHP_VERSION} php${PHP_VERSION}-{bcmath,bz2,cli,common,curl,dev,dom,exif,fpm,ftp,gd,gmp,iconv,imagick,imap,intl,mbstring,mysql,opcache,readline,redis,simplexml,soap,sockets,sqlite3,tokenizer,xml,xmlreader,xmlwriter,xsl,zip}"

# ---------------------------------------------------------------------------
# Node.js (LTS via NodeSource)
# ---------------------------------------------------------------------------
execute "Installing Node.js ${NODE_MAJOR}.x LTS" "curl -fsSL https://deb.nodesource.com/setup_${NODE_MAJOR}.x | bash - && apt install -y nodejs"

# ---------------------------------------------------------------------------
# Redis (recommended for Bitrix caching / sessions)
# ---------------------------------------------------------------------------
execute "Installing Redis" "apt install -y -q redis-server"
execute "Tuning Redis" "sed -i 's/^supervised .*/supervised systemd/' /etc/redis/redis.conf && sed -i 's/^# maxmemory-policy .*/maxmemory-policy allkeys-lru/' /etc/redis/redis.conf"
execute "Enabling Redis" "systemctl enable --now redis-server"

# ---------------------------------------------------------------------------
# MySQL
# ---------------------------------------------------------------------------
execute "Installing MySQL" "apt install -y -q mysql-server"

# MySQL tuning (~50% of RAM for InnoDB buffer pool)
INNODB_BUFFER_MB=$((TOTAL_MEM_MB / 2))
[ "${INNODB_BUFFER_MB}" -lt 256 ] && INNODB_BUFFER_MB=256
execute "Writing MySQL Bitrix tuning" "cat > /etc/mysql/mysql.conf.d/zz-bitrix.cnf << EOF
[mysqld]
# Bitrix recommended
sql_mode = \"\"
innodb_strict_mode = OFF
innodb_file_per_table = 1
innodb_flush_log_at_trx_commit = 2
innodb_flush_method = O_DIRECT
innodb_buffer_pool_size = ${INNODB_BUFFER_MB}M
innodb_log_file_size = 256M
innodb_log_buffer_size = 16M
innodb_io_capacity = 2000

max_allowed_packet = 128M
max_connections = 200
table_open_cache = 4000
table_definition_cache = 2000
tmp_table_size = 64M
max_heap_table_size = 64M
join_buffer_size = 4M
sort_buffer_size = 4M
read_buffer_size = 2M
read_rnd_buffer_size = 4M

character-set-server = utf8mb4
collation-server = utf8mb4_unicode_ci

slow_query_log = 1
slow_query_log_file = /var/log/mysql/slow.log
long_query_time = 2
EOF"
execute "Restarting MySQL" "systemctl restart mysql"
execute "Securing MySQL installation" "mysql_secure_installation"

# ---------------------------------------------------------------------------
# www user
# ---------------------------------------------------------------------------
if ! getent group www >/dev/null; then
    execute "Creating www group" "groupadd www"
fi
if ! id -u www >/dev/null 2>&1; then
    execute "Setting up www user" "mkdir -p /var/www && useradd -m -s /usr/bin/bash -g www -d /var/www/ www && chown www:www /var/www"
    execute "Setting password for www user" "passwd www"
fi

# ---------------------------------------------------------------------------
# Nginx base config for Bitrix
# ---------------------------------------------------------------------------
execute "Preparing Nginx base config" "cat > /etc/nginx/base.conf << 'EOF'
        ssi on;
        gzip on;
        gzip_comp_level 7;
        gzip_min_length 1024;
        gzip_proxied any;
        gzip_vary on;
        gzip_types application/x-javascript application/javascript application/json application/xml text/css text/plain text/xml image/svg+xml;
        charset off;
        index index.php;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Host \$host;
        client_max_body_size 1024M;
        client_body_buffer_size 4M;

        add_header X-Frame-Options SAMEORIGIN always;
        add_header X-Content-Type-Options nosniff always;
        add_header Referrer-Policy strict-origin-when-cross-origin always;

        location / {
                try_files \$uri \$uri/ @bitrix;
        }

        location ~* /upload/.*\.(php|php[3-6]|phtml|pl|asp|aspx|cgi|dll|exe|shtm|shtml|fcg|fcgi|fpl|asmx|pht|py|psp|rb|var)\$ {
                deny all;
        }

        location ~ \.php\$ {
                try_files \$uri @bitrix;
                fastcgi_pass \$php_sock;
                fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
                fastcgi_read_timeout 300;
                include fastcgi_params;
        }
        location @bitrix {
                fastcgi_pass \$php_sock;
                fastcgi_read_timeout 300;
                include fastcgi_params;
                fastcgi_param SCRIPT_FILENAME \$document_root/bitrix/urlrewrite.php;
        }
        location ~* /bitrix/admin.+\.php\$ {
                try_files \$uri @bitrixadm;
                fastcgi_pass \$php_sock;
                fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
                include fastcgi_params;
        }
        location @bitrixadm {
                fastcgi_pass \$php_sock;
                include fastcgi_params;
                fastcgi_param SCRIPT_FILENAME \$document_root/bitrix/admin/404.php;
        }

        location = /favicon.ico {
                log_not_found off;
                access_log off;
        }

        location = /robots.txt {
                allow all;
                log_not_found off;
                access_log off;
        }
        location ~* /\.ht { deny all; }
        location ~* /\.(svn|hg|git) { deny all; }
        location ~* ^/bitrix/(modules|local_cache|stack_cache|managed_cache|php_interface) { deny all; }
        location ~* ^/upload/1c_[^/]+/ { deny all; }
        location ~* /\.\./ { deny all; }
        location ~* ^/bitrix/html_pages/\.config\.php { deny all; }
        location ~* ^/bitrix/html_pages/\.enabled { deny all; }
        location ^~ /upload/support/not_image { internal; }
        location ~* @.*\.html\$ {
          internal;
          expires -1y;
          add_header X-Bitrix-Composite \"Nginx (file)\";
        }

        location ~* ^/bitrix/components/bitrix/player/mediaplayer/player\$ {
          add_header Access-Control-Allow-Origin *;
        }

        location ~* ^/bitrix/cache/(css/.+\.css|js/.+\.js)\$ {
          expires 30d;
          error_page 404 /404.html;
        }

        location ~* ^/bitrix/cache { deny all; }

        location ^~ /upload/bx_cloud_upload/ {
          location ~ ^/upload/bx_cloud_upload/(http[s]?)\.([^/:]+)\.(s3|s3-us-west-1|s3-eu-west-1|s3-ap-southeast-1|s3-ap-northeast-1)\.amazonaws\.com/(.+)\$ {
                internal;
                resolver 8.8.8.8;
                proxy_method GET;
                proxy_set_header X-Real-IP \$remote_addr;
                proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
                proxy_set_header X-Forwarded-Server \$host;
                proxy_pass \$1://\$2.\$3.amazonaws.com/\$4;
          }
          location ~* .*\$ { deny all; }
        }

        location ~* ^/(upload|bitrix/images|bitrix/tmp) {
          expires 30d;
        }

        location ~* \.(css|js|gif|png|jpg|jpeg|ico|ogg|ttf|woff|woff2|eot|otf|svg)\$ {
          error_page 404 /404.html;
          expires 30d;
          access_log off;
        }

        location = /404.html {
                access_log off;
        }
EOF"

# Tune nginx.conf
execute "Tuning nginx.conf" "sed -i \
    -e 's/^worker_processes .*/worker_processes auto;/' \
    -e 's/^# *multi_accept .*/multi_accept on;/' \
    -e 's/worker_connections .*/worker_connections 4096;/' \
    -e 's/^# *server_tokens .*/server_tokens off;/' \
    /etc/nginx/nginx.conf"

# ---------------------------------------------------------------------------
# Website
# ---------------------------------------------------------------------------
read -r -p "${green}Please enter website address (without 'www.'): ${reset}" website

execute "Creating website directory" "mkdir -p /var/www/${website}/public_html && chown -R www:www /var/www/${website}"

if ! grep -q "${website}" /etc/hosts; then
    execute "Updating hosts file" "echo -e \"127.0.0.1\\t${website}\\twww.${website}\" >> /etc/hosts"
fi

execute "Creating Nginx site config" "cat > /etc/nginx/sites-enabled/${website}.conf << EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${website} www.${website};
    root \\\$root_path;
    set \\\$root_path /var/www/${website}/public_html;
    set \\\$php_sock unix:/var/www/php-fpm/php.sock;
    access_log /var/log/nginx/${website}.access.log;
    error_log /var/log/nginx/${website}.error.log warn;
    include \"base.conf\";
}
EOF"

execute "Removing default Nginx site" "rm -f /etc/nginx/sites-enabled/default"
execute "Testing Nginx configuration" "nginx -t"

execute "Creating test PHP file" "echo '<?=\"php \".phpversion().\" is installed and working\"?>' > /var/www/${website}/public_html/index.php && chown www:www /var/www/${website}/public_html/index.php"

# ---------------------------------------------------------------------------
# PHP-FPM
# ---------------------------------------------------------------------------
execute "Preparing PHP-FPM dirs" "mkdir -p /var/www/mod-tmp /var/www/php-fpm && chown -R www:www /var/www/mod-tmp /var/www/php-fpm"

# Tune PHP-FPM child count from RAM (assume ~60MB per worker)
PM_MAX_CHILDREN=$(( (TOTAL_MEM_MB * 60 / 100) / 60 ))
[ "${PM_MAX_CHILDREN}" -lt 5 ] && PM_MAX_CHILDREN=5
PM_START_SERVERS=$(( PM_MAX_CHILDREN / 4 ))
[ "${PM_START_SERVERS}" -lt 2 ] && PM_START_SERVERS=2
PM_MIN_SPARE=$(( PM_MAX_CHILDREN / 5 ))
[ "${PM_MIN_SPARE}" -lt 1 ] && PM_MIN_SPARE=1
PM_MAX_SPARE=$(( PM_MAX_CHILDREN / 2 ))
[ "${PM_MAX_SPARE}" -lt 4 ] && PM_MAX_SPARE=4

execute "Creating PHP-FPM pool config" "cat > /etc/php/${PHP_VERSION}/fpm/pool.d/www.conf << EOF
[www]
pm = dynamic
pm.start_servers = ${PM_START_SERVERS}
pm.min_spare_servers = ${PM_MIN_SPARE}
pm.max_spare_servers = ${PM_MAX_SPARE}
pm.max_children = ${PM_MAX_CHILDREN}
pm.max_requests = 500
pm.process_idle_timeout = 60s
request_terminate_timeout = 300

php_admin_value[log_errors] = On
listen = /var/www/php-fpm/php.sock
listen.mode = 0660
listen.owner = www
listen.group = www
user = www
group = www
chdir = /
php_admin_value[upload_tmp_dir] = /var/www/mod-tmp
php_admin_value[session.save_path] = /var/www/mod-tmp
php_admin_value[opcache.enable] = 1
php_admin_value[opcache.memory_consumption] = 256
php_admin_value[opcache.interned_strings_buffer] = 32
php_admin_value[opcache.max_accelerated_files] = 100000
php_admin_value[opcache.validate_timestamps] = 1
php_admin_value[opcache.revalidate_freq] = 2
php_admin_value[opcache.save_comments] = 1
php_admin_value[realpath_cache_size] = 4096k
php_admin_value[realpath_cache_ttl] = 600
php_admin_value[max_input_vars] = 10000
php_admin_value[short_open_tag] = On
php_admin_value[memory_limit] = 512M
php_admin_value[upload_max_filesize] = 1024M
php_admin_value[post_max_size] = 1024M
php_admin_value[max_execution_time] = 300
php_admin_value[max_input_time] = 300
php_admin_value[date.timezone] = ${TZ:-Europe/Moscow}
catch_workers_output = yes
php_admin_value[error_log] = /var/log/php-fpm-error.log
EOF"

execute "Updating Nginx user" "sed -i 's/user www-data/user www/g' /etc/nginx/nginx.conf"
execute "Testing PHP-FPM configuration" "php-fpm${PHP_VERSION} -t"

# ---------------------------------------------------------------------------
# Firewall (UFW)
# ---------------------------------------------------------------------------
execute "Configuring UFW firewall" "ufw --force reset >/dev/null && ufw default deny incoming && ufw default allow outgoing && ufw allow OpenSSH && ufw allow 'Nginx Full' && ufw --force enable"

# ---------------------------------------------------------------------------
# Fail2ban for SSH and nginx
# ---------------------------------------------------------------------------
execute "Configuring fail2ban" "cat > /etc/fail2ban/jail.d/bxlamp.local << 'EOF'
[DEFAULT]
bantime = 1h
findtime = 10m
maxretry = 5

[sshd]
enabled = true

[nginx-http-auth]
enabled = true

[nginx-botsearch]
enabled = true
EOF
systemctl enable --now fail2ban && systemctl restart fail2ban"

# ---------------------------------------------------------------------------
# Restart services
# ---------------------------------------------------------------------------
execute "Enabling and restarting services" "systemctl enable nginx php${PHP_VERSION}-fpm mysql && systemctl restart nginx php${PHP_VERSION}-fpm"

# ---------------------------------------------------------------------------
# SSL via Certbot
# ---------------------------------------------------------------------------
execute "Running Certbot for SSL" "certbot --nginx -d ${website} -d www.${website} --redirect --agree-tos --no-eff-email --register-unsafely-without-email || certbot --nginx"
execute "Enabling Certbot auto-renew" "systemctl enable --now certbot.timer"

# ---------------------------------------------------------------------------
# Smoke test
# ---------------------------------------------------------------------------
execute "Testing website" "curl -I http://${website} || true"

echo "${green}Installation completed successfully!${reset}"
echo "${yellow}Summary:${reset}"
echo "  PHP:                 ${PHP_VERSION}"
echo "  Node.js:             ${NODE_MAJOR}.x LTS"
echo "  PHP-FPM max workers: ${PM_MAX_CHILDREN}"
echo "  MySQL InnoDB pool:   ${INNODB_BUFFER_MB} MB"
echo "  Website:             https://${website}"
