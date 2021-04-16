#!/bin/bash
red=`tput setaf 1`
green=`tput setaf 2`
reset=`tput sgr0`

echo "${green}Updating system${reset}"
apt update
echo "${green}Install nginx${reset}"
apt install -y -q nginx
apt install -y -q certbot python3-certbot-nginx
echo "${green}Install php 7.4${reset}"
apt -y  install software-properties-common
apt install -y -q php7.4-{bcmath,bz2,cli,common,curl,dev,dom,exif,fpm,ftp,gd,gmp,iconv,imagick,imap,intl,json,mbstring,mysql,opcache,posix,simplexml,soap,sockets,ssh2,tokenizer,xml,xmlreader,xmlrpc,zip}

echo "${green}Install mysql8${reset}"
apt install -y -q mysql-server && mysql_secure_installation
echo "${green}Adding www user. You will now be asked for password${reset}"
groupadd www
mkdir /var/www
useradd -m -s /usr/bin/bash -g www -d /var/www/ www
chown www:www /var/www
passwd www

echo "${green}Preparing nginx config files${reset}";
rm -rf /etc/nginx/base.conf
touch /etc/nginx/base.conf
echo '
        ssi on;
        gzip on;
        gzip_comp_level 7;
	gzip_types                      application/x-javascript application/javascript text/css;
        charset off;
        index index.php;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header Host $host;
        client_max_body_size 1024M;
        client_body_buffer_size 4M;

        location / {
                try_files      $uri $uri/ @bitrix;
        }

        location ~* /upload/.*\.(php|php3|php4|php5|php6|phtml|pl|asp|aspx|cgi|dll|exe|shtm|shtml|fcg|fcgi|fpl|asmx|pht|py|psp|rb|var)$ {
                types {
                        text/plain text/plain php php3 php4 php5 php6 phtml pl asp aspx cgi dll exe ico shtm shtml fcg fcgi fpl asmx pht py psp rb var;
                }
        }

        location ~ \.php$ {
                try_files       $uri @bitrix;
                fastcgi_pass    $php_sock;
                fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
                include fastcgi_params;
        }
        location @bitrix {
                fastcgi_pass    $php_sock;
                include fastcgi_params;
                fastcgi_param SCRIPT_FILENAME $document_root/bitrix/urlrewrite.php;
        }
        location ~* /bitrix/admin.+\.php$ {
                try_files       $uri @bitrixadm;
                fastcgi_pass    $php_sock;
                fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
                include fastcgi_params;
        }
        location @bitrixadm{
                fastcgi_pass    $php_sock;
                include fastcgi_params;
                fastcgi_param SCRIPT_FILENAME $document_root/bitrix/admin/404.php;
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
        # ht(passwd|access)
        location ~* /\.ht  { deny all; }

        # repositories
        location ~* /\.(svn|hg|git) { deny all; }

        # bitrix internal locations
        location ~* ^/bitrix/(modules|local_cache|stack_cache|managed_cache|php_interface) {
          deny all;
        }

        # upload files
        location ~* ^/upload/1c_[^/]+/ { deny all; }

        # use the file system to access files outside the site (cache)
        location ~* /\.\./ { deny all; }
        location ~* ^/bitrix/html_pages/\.config\.php { deny all; }
        location ~* ^/bitrix/html_pages/\.enabled { deny all; }

        # Intenal locations
        location ^~ /upload/support/not_image   { internal; }

        location ~* @.*\.html$ {
          internal;
          expires -1y;
          add_header X-Bitrix-Composite "Nginx (file)";
        }

        location ~* ^/bitrix/components/bitrix/player/mediaplayer/player$ {
          add_header Access-Control-Allow-Origin *;
        }

        location ~* ^/bitrix/cache/(css/.+\.css|js/.+\.js)$ {
          expires 30d;
          error_page 404 /404.html;
        }

        location ~* ^/bitrix/cache              { deny all; }

        location ^~ /upload/bx_cloud_upload/ {
          location ~ ^/upload/bx_cloud_upload/(http[s]?)\.([^/:]+)\.(s3|s3-us-west-1|s3-eu-west-1|s3-ap-southeast-1|s3-ap-northeast-1)\.amazonaws\.com/(.+)$ {
                internal;
                resolver 8.8.8.8;
                proxy_method GET;
                proxy_set_header    X-Real-IP               $remote_addr;
                proxy_set_header    X-Forwarded-For         $proxy_add_x_forwarded_for;
                proxy_set_header    X-Forwarded-Server      $host;
                proxy_pass $1://$2.$3.amazonaws.com/$4;
          }
          location ~* .*$       { deny all; }
        }
        # Static content
        location ~* ^/(upload|bitrix/images|bitrix/tmp) {
          expires 30d;
        }

        location  ~* \.(css|js|gif|png|jpg|jpeg|ico|ogg|ttf|woff|eot|otf)$ {
          error_page 404 /404.html;
          expires 30d;
        }

        location = /404.html {
                access_log off ;
        }
' >> /etc/nginx/base.conf
printf "${green}Please enter website address (without 'www.')${reset}: ";
read -r website
mkdir /var/www/${website}
chown www:www /var/www/${website}

if [ -n "$(grep $website /etc/hosts)" ]
then
    :
else
    echo '127.0.0.1\t ${website} www.${website}' >> /etc/hosts
fi

mkdir /var/www/${website}/public_html
chown www:www /var/www/${website}/public_html

rm -rf /etc/nginx/sites-enabled/${website}.conf
touch /etc/nginx/sites-enabled/${website}.conf

echo "server {
    server_name ${website} www.${website};
    root \$root_path;
    set  \$root_path /var/www/${website}/public_html;
    set \$php_sock unix:/var/www/php-fpm/php.sock;
    access_log /var/log/nginx/${website}.access.log;
    error_log /var/log/nginx/${website}.error.log warn;
    include "base.conf";
}" >> /etc/nginx/sites-enabled/${website}.conf
echo "${green}/etc/nginx/sites-enabled/${website}.conf written.${reset}"
echo "${green}/var/www/${website} is a home directory of ${website} now.${reset}"
nginx -t

rm -rf /var/www/${website}/public_html/index.php
touch /var/www/${website}/public_html/index.php
chown www:www /var/www/${website}/public_html/index.php
echo '<?="php ".phpversion()." is installed and working"?>
' >> /var/www/${website}/public_html/index.php

echo "${green}Preparing php-fpm config files${reset}"
mkdir /var/www/mod-tmp
chown www:www /var/www/mod-tmp

mkdir /var/www/php-fpm/

rm -rf /etc/php/7.4/fpm/pool.d/*

touch /etc/php/7.4/fpm/pool.d/www.conf
echo "[www]
pm = dynamic
pm.start_servers = 1
pm.min_spare_servers = 1
pm.max_children = 5
pm.max_spare_servers = 5
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
php_admin_value[mbstring.func_overload] =
php_admin_value[mbstring.internal_encoding] = UTF-8
php_admin_value[opcache.max_accelerated_files] = 100000
php_admin_value[max_input_vars] = 10000
php_admin_value[short_open_tag] =  On
catch_workers_output = yes
php_admin_value[error_log] = /var/log/php-fpm-error.log" >> /etc/php/7.4/fpm/pool.d/www.conf

sed -i 's/user www-data/user www/g' /etc/nginx/nginx.conf

php-fpm7.4 -tt

echo "${green}Restarting services${reset}"
service nginx restart
service php7.4-fpm restart

curl -i ${website}

echo "${green}Install finished${reset}"
