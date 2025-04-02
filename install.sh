#!/bin/bash
red=$(tput setaf 1)
green=$(tput setaf 2)
reset=$(tput sgr0)

# Function to execute commands with error checking
execute() {
    echo "${green}$1${reset}"
    if ! eval "$2"; then
        echo "${red}Error executing: $2${reset}"
        exit 1
    fi
}

# Update system and install basic packages
execute "Updating system" "apt update -y"
execute "Installing basic dependencies" "apt install -y -q curl gnupg software-properties-common"

# Install Nginx
execute "Installing Nginx" "apt install -y -q nginx"
execute "Installing Certbot" "apt install -y -q certbot python3-certbot-nginx"

# Install PHP 8.3
execute "Adding PHP repository" "add-apt-repository -y ppa:ondrej/php"
execute "Updating packages" "apt update -y"
execute "Installing PHP 8.3 and extensions" "apt install -y -q php8.3 php8.3-{bcmath,bz2,cli,common,curl,dev,dom,exif,fpm,ftp,gd,gmp,iconv,imagick,imap,intl,mysql,opcache,posix,readline,simplexml,soap,sockets,sqlite3,tokenizer,xml,xmlreader,xmlwriter,xsl,zip}"

# Install Node.js
execute "Installing Node.js" "curl -fsSL https://deb.nodesource.com/setup_current.x | bash - && apt install -y nodejs"

# Install MySQL
execute "Installing MySQL" "apt install -y -q mysql-server"
execute "Securing MySQL installation" "mysql_secure_installation"

# Setup www user
execute "Setting up www user" "groupadd www && mkdir -p /var/www && useradd -m -s /usr/bin/bash -g www -d /var/www/ www && chown www:www /var/www"
execute "Setting password for www user" "passwd www"

# Configure Nginx base config
execute "Preparing Nginx config files" "cat > /etc/nginx/base.conf << 'EOF'
        ssi on;
        gzip on;
        gzip_comp_level 7;
        gzip_types application/x-javascript application/javascript text/css;
        charset off;
        index index.php;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header Host \$host;
        client_max_body_size 1024M;
        client_body_buffer_size 4M;

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
                include fastcgi_params;
        }
        location @bitrix {
                fastcgi_pass \$php_sock;
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

        location ~* \.(css|js|gif|png|jpg|jpeg|ico|ogg|ttf|woff|eot|otf)\$ {
          error_page 404 /404.html;
          expires 30d;
        }

        location = /404.html {
                access_log off;
        }
EOF"

# Get website name
read -r -p "${green}Please enter website address (without 'www.'): ${reset}" website

# Create website directory
execute "Creating website directory" "mkdir -p /var/www/${website}/public_html && chown -R www:www /var/www/${website}"

# Add to hosts if not exists
if ! grep -q "${website}" /etc/hosts; then
    execute "Updating hosts file" "echo -e \"127.0.0.1\\t${website}\\twww.${website}\" >> /etc/hosts"
fi

# Create Nginx site config
execute "Creating Nginx site config" "cat > /etc/nginx/sites-enabled/${website}.conf << EOF
server {
    server_name ${website} www.${website};
    root \$root_path;
    set \$root_path /var/www/${website}/public_html;
    set \$php_sock unix:/var/www/php-fpm/php.sock;
    access_log /var/log/nginx/${website}.access.log;
    error_log /var/log/nginx/${website}.error.log warn;
    include \"base.conf\";
}
EOF"

# Test Nginx config
execute "Testing Nginx configuration" "nginx -t"

# Create test PHP file
execute "Creating test PHP file" "echo '<?=\"php \".phpversion().\" is installed and working\"?>' > /var/www/${website}/public_html/index.php && chown www:www /var/www/${website}/public_html/index.php"

# Configure PHP-FPM
execute "Preparing PHP-FPM config" "mkdir -p /var/www/mod-tmp /var/www/php-fpm && chown -R www:www /var/www/mod-tmp"

execute "Creating PHP-FPM pool config" "cat > /etc/php/8.3/fpm/pool.d/www.conf << EOF
[www]
pm = dynamic
pm.start_servers = 2
pm.min_spare_servers = 1
pm.max_spare_servers = 4
pm.max_children = 10
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
php_admin_value[opcache.max_accelerated_files] = 100000
php_admin_value[max_input_vars] = 10000
php_admin_value[short_open_tag] = On
catch_workers_output = yes
php_admin_value[error_log] = /var/log/php-fpm-error.log
EOF"

# Update Nginx user in config
execute "Updating Nginx user" "sed -i 's/user www-data/user www/g' /etc/nginx/nginx.conf"

# Test PHP-FPM config
execute "Testing PHP-FPM configuration" "php-fpm8.3 -t"

# Restart services
execute "Restarting services" "systemctl restart nginx php8.3-fpm"

# Run Certbot
execute "Running Certbot for SSL" "certbot --nginx"

# Test website
execute "Testing website" "curl -I ${website}"

echo "${green}Installation completed successfully!${reset}"
