# ubuntu-bxlamp-autodiscover
Быстрая установка и оптимизация LEMP-окружения под 1С-Битрикс на Ubuntu.

## Что устанавливается
* Nginx (с базовым конфигом под Битрикс и security-заголовками)
* PHP 8.3 + FPM (полный набор расширений, OPcache, Redis, Imagick)
* MySQL 8 (с тюнингом под Битрикс: utf8mb4, InnoDB pool, slow log)
* Redis (для кеша/сессий)
* Node.js 22 LTS
* Certbot (Let's Encrypt + автопродление)

## Оптимизации первичной настройки сервера
* Тюнинг ядра через `sysctl` (TCP backlog, keepalive, swappiness, file-max)
* Увеличение лимитов файловых дескрипторов (`nofile = 65535`)
* Автоматическое создание swap-файла на серверах с RAM < 4 ГБ
* Авторасчёт `pm.max_children` PHP-FPM и `innodb_buffer_pool_size` исходя из объёма RAM
* OPcache, realpath cache, увеличенные лимиты `upload_max_filesize` / `memory_limit`
* UFW firewall (разрешены только SSH и Nginx)
* Fail2ban (sshd, nginx-http-auth, nginx-botsearch)
* `unattended-upgrades` для автоматических security-обновлений
* Синхронизация времени через `chrony`, настройка таймзоны
* Logrotate, htop, mc, git, rsync «из коробки»

## Использование
```bash
wget https://raw.githubusercontent.com/SeverCode/ubuntu-bxlamp-autodiscover/main/install.sh
sudo bash install.sh
```

Можно переопределить версии и таймзону через переменные окружения:
```bash
sudo PHP_VERSION=8.3 NODE_MAJOR=22 TZ=Europe/Moscow bash install.sh
```
