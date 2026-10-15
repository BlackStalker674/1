#!/bin/bash
# =============================================================================
#  hq-srv.sh — сервер главного офиса HQ-SRV (ALT Linux p10 Server)
#  КОД 09.02.06-1-2026
#   М1: имя, адрес (VLAN 100), sshuser, SSH 2027, DNS (dnsmasq)
#   М2: RAID0 md0 -> /raid, NFS /raid/nfs, NTP-клиент, Apache+MariaDB (webdb)
#   М3: CUPS (виртуальный PDF-принтер), сервер rsyslog в /opt + logrotate,
#       fail2ban для SSH (порт 2027), УЦ на ГОСТ (сертификаты на 30 дней),
#       мониторинг Prometheus + Grafana (http://mon.au-team.irpo)
#  Запуск: после роутеров. Нужен подключённый образ Additional.iso (/dev/sr0)
#  и два свободных диска по 1 ГБ.
# =============================================================================

# ---------------------------- ПАРАМЕТРЫ --------------------------------------
HOST_FQDN="hq-srv.au-team.irpo"
TZ_NAME="Asia/Krasnoyarsk"
IF_LAN="enp7s1"
IP_ADDR="192.168.100.2/27"; GW="192.168.100.1"
SSH_PORT="2027"
SSH_USER="sshuser"; SSH_UID="2027"; PASS="P@ssw0rd"
NTP_SRV="172.16.1.1"
DC_IP="192.168.0.2"                       # Samba DC на BR-SRV
DNS_FWD1="77.88.8.8"; DNS_FWD2="77.88.8.3"
NFS_NET="192.168.200.0/28"                # сеть HQ-CLI
ISO_DEV="/dev/sr0"; ISO_MNT="/mnt/additional"
WEB_ROOT="/var/www/html"
CA_DIR="/etc/pki/au-team-ca"; CA_DAYS="365"; CERT_DAYS="30"
MON_PASS="P@ssw0rd"                       # Grafana: admin / P@ssw0rd
DB_NAME="webdb"; DB_USER="web"; DB_PASS="P@ssw0rd"

# ---------------------------- ОБЩИЕ ФУНКЦИИ ----------------------------------
set -Eeo pipefail
LOG_FILE="/var/log/$(basename "$0" .sh)-setup.log"
exec > >(tee -a "$LOG_FILE") 2>&1
C_R='\033[1;31m'; C_G='\033[1;32m'; C_Y='\033[1;33m'; C_B='\033[1;34m'; C_N='\033[0m'
step() { echo -e "\n${C_B}==> $*${C_N}"; }
ok()   { echo -e "${C_G}[ OK ]${C_N} $*"; }
warn() { echo -e "${C_Y}[WARN]${C_N} $*"; }
die()  { echo -e "${C_R}[FAIL]${C_N} $*"; exit 1; }
trap 'rc=$?; echo -e "${C_R}[FAIL]${C_N} строка ${LINENO}: «${BASH_COMMAND}» вернула код ${rc}. Лог: ${LOG_FILE}"' ERR

[ "$(id -u)" -eq 0 ] || die "Запустите скрипт от root"
[ -r /etc/altlinux-release ] || warn "Нет /etc/altlinux-release — скрипт рассчитан на ALT Linux p10"

backup() { [ -e "$1" ] && [ ! -e "$1.orig" ] && cp -a "$1" "$1.orig"; return 0; }

APT_UPDATED=0
apt_update() {
  [ "$APT_UPDATED" -eq 1 ] && return 0
  apt-get update -q || die "apt-get update не выполнен — проверьте Интернет/DNS"
  APT_UPDATED=1
}
pkg_install() {             # установка с проверкой наличия в репозитории
  apt_update
  local p miss=()
  for p in "$@"; do apt-cache show "$p" >/dev/null 2>&1 || miss+=("$p"); done
  [ ${#miss[@]} -eq 0 ] || die "Нет в репозитории: ${miss[*]}"
  apt-get install -y "$@" || die "Ошибка установки: $*"
  for p in "$@"; do rpm -q "$p" >/dev/null 2>&1 || rpm -q --whatprovides "$p" >/dev/null 2>&1 || die "Пакет $p не установлен"; done
  ok "Пакеты установлены: $*"
}
check_iface() { ip link show "$1" >/dev/null 2>&1 || die "Интерфейс $1 не найден (ip -br link)"; ok "Интерфейс $1 есть"; }
set_hostname() {
  hostnamectl set-hostname "$1" || die "hostnamectl не сработал"
  if [ -f /etc/sysconfig/network ]; then
    sed -i '/^HOSTNAME=/d' /etc/sysconfig/network; echo "HOSTNAME=$1" >> /etc/sysconfig/network
  fi
  [ "$(hostname)" = "$1" ] && ok "Имя хоста: $1" || die "Имя хоста не применилось"
}
set_tz() {
  pkg_install tzdata                              # tzdata — до смены пояса
  timedatectl set-timezone "$TZ_NAME" || die "Не удалось установить часовой пояс"
  readlink -f /etc/localtime | grep -q "$TZ_NAME" && ok "Часовой пояс: $TZ_NAME" || die "Часовой пояс не применился"
}
# etcnet: $1 iface, $2 BOOTPROTO, $3 адрес/маска, $4 шлюз, $5 DNS
etcnet_eth() {
  local d="/etc/net/ifaces/$1"; mkdir -p "$d"
  cat > "$d/options" <<EOF
TYPE=eth
DISABLED=no
NM_CONTROLLED=no
BOOTPROTO=$2
CONFIG_IPV4=yes
EOF
  if [ "$2" = "static" ]; then
    rm -f "$d/ipv4address" "$d/ipv4route"
    if [ -n "$3" ]; then echo "$3" > "$d/ipv4address"; fi
    if [ -n "$4" ]; then echo "default via $4" > "$d/ipv4route"; fi
  fi
  if [ -n "$5" ]; then printf 'search au-team.irpo\nnameserver %s\n' "$5" > "$d/resolv.conf"; fi
  ok "etcnet: $1 ($2 ${3:-})"
}
enable_forward() {
  local f=/etc/net/sysctl.conf
  if grep -qE '^\s*net\.ipv4\.ip_forward' "$f"; then
    sed -i -E 's/^\s*net\.ipv4\.ip_forward.*/net.ipv4.ip_forward = 1/' "$f"
  else echo "net.ipv4.ip_forward = 1" >> "$f"; fi
  sysctl -w net.ipv4.ip_forward=1 >/dev/null
  [ "$(cat /proc/sys/net/ipv4/ip_forward)" = "1" ] && ok "IP forwarding включён" || die "ip_forward не включён"
}
restart_network() {
  systemctl restart network || die "Не удалось перезапустить network"
  sleep 3; ok "Сеть перезапущена"
}
wait_inet() {
  local i; for i in $(seq 1 40); do
    ping -c1 -W1 77.88.8.8 >/dev/null 2>&1 && { ok "Интернет доступен"; return 0; }; sleep 1
  done; die "Нет связи с 77.88.8.8 — проверьте адресацию/NAT"
}
SSHD_CFG=/etc/openssh/sshd_config
sshd_set() {   # удаляет все варианты директивы и ставит её в начало файла (до блоков Match)
  sed -i -E "/^[#[:space:]]*$1[[:space:]]/d" "$SSHD_CFG"
  sed -i "1i $1 $2" "$SSHD_CFG"
}
sshd_apply() {
  /usr/sbin/sshd -t || die "Ошибка в $SSHD_CFG (sshd -t)"
  systemctl enable sshd >/dev/null 2>&1 || true
  systemctl restart sshd || die "sshd не перезапустился"
  ss -tln | grep -q ":$SSH_PORT " && ok "sshd слушает порт $SSH_PORT" || die "sshd не слушает $SSH_PORT"
}

pkg_try() {                 # нефатальная установка: вернёт 1, если пакета нет
  apt_update
  local p
  for p in "$@"; do apt-cache show "$p" >/dev/null 2>&1 || { warn "Пакет $p не найден в репозитории"; return 1; }; done
  apt-get install -y "$@" || { warn "Не удалось установить: $*"; return 1; }
  ok "Пакеты установлены: $*"
}
create_user() {             # $1 имя, $2 UID (может быть пустым), $3 пароль; группа wheel
  local u="$1" uid="$2" pw="$3"
  if id "$u" >/dev/null 2>&1; then
    warn "Пользователь $u уже существует — обновляю пароль и группы"
    if [ -n "$uid" ] && [ "$(id -u "$u")" != "$uid" ]; then warn "UID $u = $(id -u "$u"), ожидался $uid"; fi
  elif [ -n "$uid" ]; then
    useradd -m -u "$uid" -G wheel -s /bin/bash "$u" || die "useradd $u не выполнен"
  else
    useradd -m -G wheel -s /bin/bash "$u" || die "useradd $u не выполнен"
  fi
  echo "$u:$pw" | chpasswd || die "chpasswd для $u не выполнен"
  usermod -aG wheel "$u"
  id -nG "$u" | grep -qw wheel && ok "Пользователь $u (uid $(id -u "$u")) в группе wheel" || die "$u не в wheel"
}
install_sudoers() {         # $1 имя файла в /etc/sudoers.d, $2 содержимое
  pkg_install sudo
  grep -Eq '^[@#]includedir[[:space:]]+/etc/sudoers\.d' /etc/sudoers || echo '@includedir /etc/sudoers.d' >> /etc/sudoers
  local f="/etc/sudoers.d/$1"
  printf '%s\n' "$2" > "$f.tmp"          # файлы с точкой sudo игнорирует — безопасная проверка
  chmod 0400 "$f.tmp"
  visudo -cf "$f.tmp" >/dev/null || { rm -f "$f.tmp"; die "Синтаксическая ошибка в правиле sudo $1"; }
  mv -f "$f.tmp" "$f"; chown root:root "$f"; chmod 0400 "$f"
  visudo -c >/dev/null || die "visudo -c: ошибка в конфигурации sudo"
  ok "sudo: $f (права 0400)"
}
chrony_client() {           # $1 — адрес NTP-сервера ISP
  pkg_install chrony
  backup /etc/chrony.conf
  cat > /etc/chrony.conf <<EOF
server $1 iburst prefer
driftfile /var/lib/chrony/drift
makestep 1.0 3
rtcsync
EOF
  systemctl enable chronyd >/dev/null 2>&1
  systemctl restart chronyd || die "chronyd не запустился"
  ok "chrony-клиент сервера $1"
}
rsyslog_client() {          # $1 — сервер сбора логов; уровень warning и выше
  if pkg_try rsyslog-classic || pkg_try rsyslog; then
    mkdir -p /etc/rsyslog.d
    echo "*.warning @@$1:514" > /etc/rsyslog.d/90-remote.conf
    systemctl enable rsyslog >/dev/null 2>&1 || true
    systemctl restart rsyslog && ok "rsyslog: *.warning -> $1:514/tcp" || warn "rsyslog не перезапустился"
  else warn "rsyslog не установлен — пропуск"; fi
}
set_resolv() {              # $1 iface (etcnet), $2 nameserver
  printf 'search au-team.irpo\nnameserver %s\n' "$2" > "/etc/net/ifaces/$1/resolv.conf"
  if command -v resolvconf >/dev/null 2>&1; then
    resolvconf -u >/dev/null 2>&1 || true
  fi
  grep -q "nameserver $2" /etc/resolv.conf || printf 'search au-team.irpo\nnameserver %s\n' "$2" > /etc/resolv.conf
  ok "DNS: $2"
}
enable_first() {            # запускает первую существующую службу из списка
  local s; for s in "$@"; do
    if systemctl list-unit-files "$s.service" 2>/dev/null | grep -q "^$s.service"; then
      systemctl enable --now "$s" && { ENABLED_SVC="$s"; ok "Служба $s запущена"; return 0; }
    fi
  done; die "Не найдена/не запустилась ни одна из служб: $*"
}

mount_iso() {
  mkdir -p "$ISO_MNT"
  if mountpoint -q "$ISO_MNT"; then return 0; fi
  [ -b "$ISO_DEV" ] || { warn "Нет $ISO_DEV — подключите Additional.iso"; return 1; }
  mount -o ro "$ISO_DEV" "$ISO_MNT" || { warn "Не удалось смонтировать $ISO_DEV"; return 1; }
  ok "Additional.iso смонтирован в $ISO_MNT"
}
# ============================== МОДУЛЬ 1 =====================================
step "Проверка интерфейса и имя"
check_iface "$IF_LAN"
set_hostname "$HOST_FQDN"
grep -q "$HOST_FQDN" /etc/hosts || echo "${IP_ADDR%/*} $HOST_FQDN hq-srv" >> /etc/hosts

step "Адресация (на время установки DNS = $DNS_FWD1)"
etcnet_eth "$IF_LAN" static "$IP_ADDR" "$GW" "$DNS_FWD1"
restart_network
wait_inet

step "Часовой пояс"
set_tz

step "Пользователь $SSH_USER (UID $SSH_UID, sudo без пароля)"
create_user "$SSH_USER" "$SSH_UID" "$PASS"
install_sudoers "$SSH_USER" "$SSH_USER ALL=(ALL:ALL) NOPASSWD: ALL"

step "Безопасный SSH"
echo "Authorized access only" > /etc/openssh/banner
sshd_set Port "$SSH_PORT"
sshd_set AllowUsers "$SSH_USER"
sshd_set MaxAuthTries 2
sshd_set Banner /etc/openssh/banner
sshd_set PermitRootLogin no
sshd_apply

step "DNS-сервер (dnsmasq) для au-team.irpo"
pkg_install dnsmasq
backup /etc/dnsmasq.conf
cat > /etc/dnsmasq.conf <<EOF
# Не читать /etc/resolv.conf — пересылка только на указанные серверы
no-resolv
server=$DNS_FWD1
server=$DNS_FWD2
# SRV-записи Active Directory пересылаются на Samba DC (BR-SRV)
server=/_msdcs.au-team.irpo/$DC_IP
server=/_tcp.au-team.irpo/$DC_IP
server=/_udp.au-team.irpo/$DC_IP
server=/_sites.au-team.irpo/$DC_IP
domain=au-team.irpo
listen-address=127.0.0.1,${IP_ADDR%/*}
bind-interfaces
cache-size=1000
# ---- Таблица 3: записи A + PTR ----
host-record=hq-rtr.au-team.irpo,192.168.100.1
host-record=hq-srv.au-team.irpo,${IP_ADDR%/*}
host-record=hq-cli.au-team.irpo,192.168.200.2
# ---- Таблица 3: только записи A ----
address=/br-rtr.au-team.irpo/192.168.0.1
address=/br-srv.au-team.irpo/$DC_IP
address=/docker.au-team.irpo/172.16.1.1
address=/web.au-team.irpo/172.16.2.1
# ---- Модуль 3: мониторинг ----
address=/mon.au-team.irpo/${IP_ADDR%/*}
EOF
dnsmasq --test || die "Ошибка в /etc/dnsmasq.conf"
systemctl enable dnsmasq >/dev/null 2>&1
systemctl restart dnsmasq || die "dnsmasq не запустился"
sleep 1
set_resolv "$IF_LAN" 127.0.0.1
pkg_try bind-utils || true
if command -v host >/dev/null 2>&1; then
  host hq-rtr.au-team.irpo 127.0.0.1 | grep -q 192.168.100.1 && ok "A hq-rtr" || die "Не разрешается hq-rtr.au-team.irpo"
  host 192.168.100.2 127.0.0.1 | grep -q hq-srv && ok "PTR hq-srv" || die "Нет PTR для HQ-SRV"
  host ya.ru 127.0.0.1 >/dev/null && ok "Пересылка во внешний DNS работает" || warn "Пересылка не работает"
else
  getent hosts hq-srv.au-team.irpo >/dev/null && ok "DNS отвечает" || die "DNS не отвечает"
fi

# ============================== МОДУЛЬ 2 =====================================
step "NTP-клиент"
chrony_client "$NTP_SRV"

step "RAID0 /dev/md0 -> /raid (ext4)"
pkg_install mdadm
if [ -b /dev/md0 ]; then
  warn "/dev/md0 уже существует — создание пропущено"
else
  mapfile -t DISKS < <(lsblk -dnbpo NAME,TYPE,SIZE | awk '$2=="disk" && $3>=900000000 && $3<=1300000000 {print $1}' |
    while read -r d; do [ "$(lsblk -no NAME "$d" | wc -l)" -eq 1 ] && ! mdadm --examine "$d" >/dev/null 2>&1 && echo "$d"; done)
  [ ${#DISKS[@]} -ge 2 ] || die "Нужно два свободных диска ~1 ГБ, найдено: ${DISKS[*]:-нет}"
  echo "Диски для массива: ${DISKS[0]} ${DISKS[1]}"
  mdadm --create /dev/md0 --level=0 --raid-devices=2 --run "${DISKS[0]}" "${DISKS[1]}" || die "mdadm --create не выполнен"
fi
mdadm --detail --scan > /etc/mdadm.conf
grep -q md0 /etc/mdadm.conf && ok "Конфигурация массива в /etc/mdadm.conf" || die "md0 не записан в mdadm.conf"
if [ ! -b /dev/md0p1 ]; then
  echo ',,L' | sfdisk -q /dev/md0 || die "Не удалось создать раздел на md0"
  partprobe /dev/md0 2>/dev/null || true; sleep 2
  mkfs.ext4 -F /dev/md0p1 || die "mkfs.ext4 не выполнен"
fi
mkdir -p /raid
UUID_MD="$(blkid -s UUID -o value /dev/md0p1 || true)"
[ -n "$UUID_MD" ] || die "Нет UUID у /dev/md0p1"
sed -i '\#[[:space:]]/raid[[:space:]]#d' /etc/fstab
echo "UUID=$UUID_MD /raid ext4 defaults 0 0" >> /etc/fstab
systemctl daemon-reload
mount -a || die "mount -a завершился с ошибкой"
mountpoint -q /raid && ok "/raid смонтирован (автомонтирование через fstab)" || die "/raid не смонтирован"

step "NFS-сервер: /raid/nfs для $NFS_NET"
pkg_install nfs-server
mkdir -p /raid/nfs; chmod 777 /raid/nfs
backup /etc/exports
sed -i '\#^/raid/nfs[[:space:]]#d' /etc/exports
echo "/raid/nfs $NFS_NET(rw,sync,no_subtree_check)" >> /etc/exports
enable_first nfs-server nfs
exportfs -ra || die "exportfs -ra не выполнен"
exportfs -v | grep -q /raid/nfs && ok "Экспорт /raid/nfs активен" || die "Экспорт не применился"

step "Веб-приложение: Apache + MariaDB"
pkg_install lamp-server
enable_first mariadb mysqld
enable_first httpd2
if mount_iso; then
  WEB_SRC="$(find "$ISO_MNT" -maxdepth 2 -type d -iname web | head -1)"
  [ -n "$WEB_SRC" ] || die "В образе нет каталога web"
  DUMP="$(find "$WEB_SRC" -maxdepth 1 -iname 'dump.sql' | head -1)"
  [ -n "$DUMP" ] || die "Нет dump.sql в $WEB_SRC"
  mysql -u root <<EOF || die "Ошибка создания БД/пользователя"
CREATE DATABASE IF NOT EXISTS $DB_NAME;
CREATE USER IF NOT EXISTS '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASS';
ALTER USER '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASS';
GRANT ALL PRIVILEGES ON $DB_NAME.* TO '$DB_USER'@'localhost';
FLUSH PRIVILEGES;
EOF
  if [ "$(mysql -u root -N -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='$DB_NAME'")" -eq 0 ]; then
    mysql -u root "$DB_NAME" < "$DUMP" || die "Импорт dump.sql не выполнен"
  else warn "В $DB_NAME уже есть таблицы — импорт пропущен"; fi
  ok "БД $DB_NAME: таблиц $(mysql -u root -N -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='$DB_NAME'")"
  mkdir -p "$WEB_ROOT"
  rm -f "$WEB_ROOT/index.html"
  cp -f "$WEB_SRC"/index.php "$WEB_ROOT/" || die "Нет index.php в $WEB_SRC"
  [ -d "$WEB_SRC/images" ] && cp -rf "$WEB_SRC/images" "$WEB_ROOT/"
  find "$WEB_SRC" -maxdepth 1 -type f \( -iname '*.png' -o -iname '*.jpg' -o -iname '*.css' \) -exec cp -f {} "$WEB_ROOT/" \;
  # Учётные данные БД в index.php (одинарные или двойные кавычки)
  sed -i -E \
    -e "s/(\\\$servername[[:space:]]*=[[:space:]]*)[\"'][^\"']*[\"']/\\1\"localhost\"/" \
    -e "s/(\\\$username[[:space:]]*=[[:space:]]*)[\"'][^\"']*[\"']/\\1\"$DB_USER\"/" \
    -e "s/(\\\$password[[:space:]]*=[[:space:]]*)[\"'][^\"']*[\"']/\\1\"$DB_PASS\"/" \
    -e "s/(\\\$dbname[[:space:]]*=[[:space:]]*)[\"'][^\"']*[\"']/\\1\"$DB_NAME\"/" \
    "$WEB_ROOT/index.php"
  if grep -q "\"$DB_NAME\"" "$WEB_ROOT/index.php" && grep -q "\"$DB_USER\"" "$WEB_ROOT/index.php"; then
    ok "index.php: подключение к $DB_NAME под $DB_USER"
  else
    warn "Имена переменных в index.php другие — поправьте вручную:"; grep -nE 'mysqli|PDO|\$[a-z_]+ *=' "$WEB_ROOT/index.php" | head -15
  fi
  chown -R apache2:apache2 "$WEB_ROOT" 2>/dev/null || chown -R apache:apache "$WEB_ROOT" 2>/dev/null || true
  systemctl restart httpd2
  curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1/ | grep -q '^200$' && ok "Сайт отвечает 200" || warn "Сайт не вернул 200 — проверьте journalctl -u httpd2"
else
  warn "Образ не подключён — веб-приложение пропущено. Подключите ISO и перезапустите скрипт."
fi

# ============================== МОДУЛЬ 3 =====================================
step "CUPS: виртуальный PDF-принтер"
if pkg_try cups cups-pdf; then
  systemctl enable --now cups || die "cups не запустился"
  PDF_PPD="$(lpinfo -m 2>/dev/null | grep -i 'pdf' | head -1 | awk '{print $1}' || true)"
  if lpstat -p PDF >/dev/null 2>&1; then warn "Принтер PDF уже есть"
  else lpadmin -p PDF -E -v cups-pdf:/ ${PDF_PPD:+-m "$PDF_PPD"} || die "lpadmin не создал принтер"; fi
  lpadmin -p PDF -o printer-is-shared=true
  cupsctl --share-printers --remote-any || die "cupsctl не выполнен"
  systemctl restart cups
  lpstat -p PDF && ok "Принтер PDF опубликован: ipp://hq-srv.au-team.irpo:631/printers/PDF"
fi

step "rsyslog-сервер: /opt/<имя машины>/ (только удалённые логи, warning+)"
pkg_try rsyslog-classic || pkg_install rsyslog
mkdir -p /etc/rsyslog.d
loaded() { grep -hEqs "^[[:space:]]*(\\\$ModLoad[[:space:]]+$1|module\(load=\"$1\")" /etc/rsyslog.conf /etc/rsyslog.d/*.conf; }
{
  loaded imudp || echo 'module(load="imudp")'
  loaded imtcp || echo 'module(load="imtcp")'
  cat <<'EOF'
template(name="RemoteByHost" type="string" string="/opt/%HOSTNAME%/%HOSTNAME%.log")
# Отдельный ruleset для сетевых входов: локальные логи сервера сюда не попадают
ruleset(name="remote") {
    if prifilt("*.warning") then {
        action(type="omfile" dynaFile="RemoteByHost" createDirs="on")
    }
    stop
}
input(type="imudp" port="514" ruleset="remote")
input(type="imtcp" port="514" ruleset="remote")
EOF
} > /etc/rsyslog.d/10-remote-server.conf
rm -f /etc/rsyslog.d/90-remote.conf          # сервер не является клиентом самому себе
rsyslogd -N1 >/dev/null 2>&1 || die "Ошибка в конфигурации rsyslog (rsyslogd -N1)"
systemctl enable rsyslog >/dev/null 2>&1
systemctl restart rsyslog || die "rsyslog не запустился"
ss -tln | grep -q ':514 ' && ok "rsyslog принимает 514/tcp и 514/udp" || die "rsyslog не слушает 514"
cat > /etc/logrotate.d/opt-remote-logs <<'EOF'
/opt/*.log /opt/*/*.log {
    weekly
    minsize 10M
    compress
    rotate 4
    missingok
    notifempty
    sharedscripts
    postrotate
        /bin/systemctl kill -s HUP rsyslog.service >/dev/null 2>&1 || true
    endscript
}
EOF
logrotate -d /etc/logrotate.d/opt-remote-logs >/dev/null 2>&1 && ok "logrotate: еженедельно, сжатие, от 10 МБ" || die "Ошибка в правиле logrotate"

step "fail2ban для SSH (порт $SSH_PORT)"
pkg_install fail2ban python3-module-systemd iptables
cat > /etc/fail2ban/jail.local <<EOF
[DEFAULT]
banaction = iptables-multiport

[sshd]
enabled  = true
port     = $SSH_PORT
filter   = sshd
backend  = systemd
maxretry = 3
findtime = 10m
bantime  = 1m
EOF
fail2ban-client -t >/dev/null || die "Ошибка конфигурации fail2ban"
systemctl enable fail2ban >/dev/null 2>&1
systemctl restart fail2ban || die "fail2ban не запустился"
sleep 2
fail2ban-client status sshd && ok "Jail sshd: 3 попытки -> бан на 1 минуту" || die "Jail sshd не активен"

step "Центр сертификации: ГОСТ Р 34.10-2012 (+ RSA-цепочка для совместимости браузеров)"
pkg_install openssl
if pkg_try openssl-gost-engine; then control openssl-gost enabled >/dev/null 2>&1 || true; fi
GOST_OK=0
openssl list -public-key-algorithms 2>/dev/null | grep -qi 'gost2012_256' && GOST_OK=1
[ "$GOST_OK" = 1 ] && ok "Алгоритмы ГОСТ доступны в OpenSSL (engine gost)" \
                   || warn "ГОСТ-движок OpenSSL недоступен — будет выпущена только RSA-цепочка"
mkdir -p "$CA_DIR"; chmod 700 "$CA_DIR"
# $1 = gost|rsa, $2 = путь к ключу
gen_key() {
  if [ "$1" = gost ]; then openssl genpkey -algorithm gost2012_256 -pkeyopt paramset:A -out "$2"
  else openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$2"; fi
  chmod 600 "$2"
}
md_of() { [ "$1" = gost ] && echo "-md_gost12_256" || echo "-sha256"; }
make_ca() {                 # корневой сертификат УЦ
  local a="$1" k="$CA_DIR/ca-$1.key" c="$CA_DIR/ca-$1.crt"
  [ -s "$c" ] && { ok "УЦ $a уже существует"; return 0; }
  gen_key "$a" "$k" || die "Не создан ключ УЦ $a"
  openssl req -x509 -new $(md_of "$a") -key "$k" -days "$CA_DAYS" \
    -subj "/C=RU/O=AU-TEAM/CN=AU-TEAM Root CA ($a)" \
    -addext "basicConstraints=critical,CA:TRUE" \
    -addext "keyUsage=critical,keyCertSign,cRLSign" -out "$c" || die "Не создан сертификат УЦ $a"
  ok "УЦ $a: $c"
}
issue() {                   # $1 алгоритм, $2 короткое имя (web|docker) — срок CERT_DAYS
  local a="$1" n="$2" fq="$2.au-team.irpo" k="$CA_DIR/$2-$1.key" csr="$CA_DIR/$2-$1.csr" c="$CA_DIR/$2-$1.crt"
  gen_key "$a" "$k" || die "Не создан ключ $fq ($a)"
  openssl req -new $(md_of "$a") -key "$k" -subj "/C=RU/O=AU-TEAM/CN=$fq" -out "$csr" || die "CSR $fq"
  printf 'basicConstraints=CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\nsubjectAltName=DNS:%s\n' "$fq" > "$CA_DIR/$n.ext"
  openssl x509 -req -in "$csr" -CA "$CA_DIR/ca-$a.crt" -CAkey "$CA_DIR/ca-$a.key" -CAcreateserial \
    $(md_of "$a") -days "$CERT_DAYS" -extfile "$CA_DIR/$n.ext" -out "$c" || die "Не подписан сертификат $fq ($a)"
  openssl verify -CAfile "$CA_DIR/ca-$a.crt" "$c" >/dev/null || die "Цепочка $fq ($a) не проверяется"
  cat "$c" "$CA_DIR/ca-$a.crt" > "$CA_DIR/$n-$a.fullchain.crt"
  ok "Выдан $fq ($a) на $CERT_DAYS дней"
}
ALGS="rsa"; [ "$GOST_OK" = 1 ] && ALGS="gost rsa"
for a in $ALGS; do make_ca "$a"; issue "$a" web; issue "$a" docker; done
# Корневые сертификаты — клиенту через NFS; сертификаты и ключи — для nginx на ISP
mkdir -p /raid/nfs/ca
cp -f "$CA_DIR"/ca-*.crt /raid/nfs/ca/; chmod 644 /raid/nfs/ca/*.crt
SU_HOME="$(getent passwd "$SSH_USER" | cut -d: -f6)"
mkdir -p "$SU_HOME/certs"
for a in $ALGS; do for n in web docker; do
  cp -f "$CA_DIR/$n-$a.fullchain.crt" "$SU_HOME/certs/$n-$a.crt"
  cp -f "$CA_DIR/$n-$a.key" "$SU_HOME/certs/$n-$a.key"
done; done
chown -R "$SSH_USER": "$SU_HOME/certs"; chmod 700 "$SU_HOME/certs"; chmod 600 "$SU_HOME/certs"/*
ok "Корневые сертификаты: /raid/nfs/ca (для HQ-CLI); комплект для ISP: $SU_HOME/certs"
echo "На ISP после этого выполните: ./isp.sh tls"

step "Мониторинг: Prometheus + node_exporter + Grafana -> http://mon.au-team.irpo"
# Выбор: открытое ПО из репозитория ALT; node_exporter даёт ЦП/ОЗУ/диск,
# Grafana — визуализация и вход admin/P@ssw0rd. Grafana: 127.0.0.1:3000,
# Prometheus: 127.0.0.1:9090, снаружи только Apache :80 с доступом из сетей HQ.
pkg_install prometheus prometheus-node_exporter grafana
enable_first node_exporter prometheus-node_exporter prometheus-node-exporter
backup /etc/prometheus/prometheus.yml
cat > /etc/prometheus/prometheus.yml <<EOF
global:
  scrape_interval: 15s
scrape_configs:
  - job_name: node
    static_configs:
      - targets: ['${IP_ADDR%/*}:9100']
        labels: { host: 'hq-srv' }
      - targets: ['$DC_IP:9100']
        labels: { host: 'br-srv' }
EOF
if [ -f /etc/sysconfig/prometheus ]; then
  grep -q 'web.listen-address' /etc/sysconfig/prometheus || \
    sed -i -E 's|^(ARGS=")|\1--web.listen-address=127.0.0.1:9090 |' /etc/sysconfig/prometheus
fi
enable_first prometheus
systemctl restart prometheus || die "prometheus не перезапустился"
# Grafana: слушает только localhost, учётная запись admin
backup /etc/grafana/grafana.ini
sed -i -E '/^\[server\]/,/^\[/{s|^;?http_addr *=.*|http_addr = 127.0.0.1|;s|^;?http_port *=.*|http_port = 3000|;s|^;?domain *=.*|domain = mon.au-team.irpo|}' /etc/grafana/grafana.ini
sed -i -E '/^\[security\]/,/^\[/{s|^;?admin_user *=.*|admin_user = admin|;s|^;?admin_password *=.*|admin_password = '"$MON_PASS"'|}' /etc/grafana/grafana.ini
GP=/etc/grafana/provisioning
mkdir -p "$GP/datasources" "$GP/dashboards" /var/lib/grafana/dashboards
cat > "$GP/datasources/prometheus.yaml" <<'EOF'
apiVersion: 1
datasources:
  - name: Prometheus
    uid: prom
    type: prometheus
    access: proxy
    url: http://127.0.0.1:9090
    isDefault: true
EOF
cat > "$GP/dashboards/servers.yaml" <<'EOF'
apiVersion: 1
providers:
  - name: servers
    type: file
    options:
      path: /var/lib/grafana/dashboards
EOF
panel() {   # $1 id, $2 заголовок, $3 PromQL, $4 y
  cat <<EOF
    {"id": $1, "type": "timeseries", "title": "$2",
     "datasource": {"type": "prometheus", "uid": "prom"},
     "gridPos": {"x": 0, "y": $4, "w": 24, "h": 8},
     "fieldConfig": {"defaults": {"unit": "percent", "min": 0, "max": 100}, "overrides": []},
     "targets": [{"refId": "A", "expr": "$3", "legendFormat": "{{host}}"}]}
EOF
}
{
  echo '{"uid": "servers", "title": "HQ-SRV и BR-SRV", "schemaVersion": 36, "refresh": "30s",'
  echo ' "time": {"from": "now-1h", "to": "now"}, "panels": ['
  panel 1 "Загрузка ЦП, %" '100 - avg by (host) (rate(node_cpu_seconds_total{mode=\"idle\"}[1m])) * 100' 0; echo ','
  panel 2 "Занятая ОЗУ, %" '(1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes) * 100' 8; echo ','
  panel 3 "Занято на диске /, %" '(1 - node_filesystem_avail_bytes{mountpoint=\"/\"} / node_filesystem_size_bytes{mountpoint=\"/\"}) * 100' 16
  echo ']}'
} > /var/lib/grafana/dashboards/servers.json
python3 -m json.tool /var/lib/grafana/dashboards/servers.json >/dev/null || die "Ошибка в JSON дашборда"
chown -R grafana: /var/lib/grafana 2>/dev/null || chown -R _grafana: /var/lib/grafana 2>/dev/null || true
GRAFANA_SVC=grafana-server; systemctl list-unit-files grafana-server.service | grep -q grafana-server || GRAFANA_SVC=grafana
systemctl enable "$GRAFANA_SVC" >/dev/null 2>&1
systemctl restart "$GRAFANA_SVC" || die "Grafana не запустилась"
sleep 8
# Пароль задаётся и при уже созданной БД Grafana
grafana-cli --homepath /usr/share/grafana --config /etc/grafana/grafana.ini admin reset-admin-password "$MON_PASS" >/dev/null 2>&1 \
  || grafana cli --homepath /usr/share/grafana --config /etc/grafana/grafana.ini admin reset-admin-password "$MON_PASS" >/dev/null 2>&1 \
  || warn "Не удалось сбросить пароль admin через grafana-cli"
# Apache: виртуальный хост mon.au-team.irpo -> Grafana, только для сетей HQ
command -v a2enmod >/dev/null && { a2enmod proxy >/dev/null 2>&1 || true; a2enmod proxy_http >/dev/null 2>&1 || true; }
SITES=/etc/httpd2/conf/sites-available
mkdir -p "$SITES"
# Явный виртуальный хост по умолчанию для веб-приложения (идёт первым по алфавиту)
cat > "$SITES/000-webapp.conf" <<EOF
<VirtualHost *:80>
    ServerName hq-srv.au-team.irpo
    ServerAlias web.au-team.irpo
    DocumentRoot $WEB_ROOT
</VirtualHost>
EOF
cat > "$SITES/mon.conf" <<'EOF'
<VirtualHost *:80>
    ServerName mon.au-team.irpo
    ProxyPreserveHost On
    ProxyPass        / http://127.0.0.1:3000/
    ProxyPassReverse / http://127.0.0.1:3000/
    <Location />
        Require ip 127.0.0.1 192.168.100.0/27 192.168.200.0/28 192.168.99.0/29
    </Location>
</VirtualHost>
EOF
if command -v a2ensite >/dev/null; then a2ensite 000-webapp >/dev/null; a2ensite mon >/dev/null
else
  mkdir -p /etc/httpd2/conf/sites-enabled
  ln -sf "$SITES/000-webapp.conf" /etc/httpd2/conf/sites-enabled/000-webapp.conf
  ln -sf "$SITES/mon.conf" /etc/httpd2/conf/sites-enabled/mon.conf
fi
httpd2 -t || die "Ошибка конфигурации Apache (httpd2 -t)"
systemctl restart httpd2 || die "httpd2 не перезапустился"
sleep 2
curl -s -o /dev/null -w '%{http_code}' -H 'Host: mon.au-team.irpo' http://127.0.0.1/login | grep -q '^200$' \
  && ok "Мониторинг: http://mon.au-team.irpo (admin / $MON_PASS), Grafana на 127.0.0.1:3000" \
  || warn "mon.au-team.irpo не вернул 200 — journalctl -u $GRAFANA_SVC"
curl -s http://127.0.0.1:9090/api/v1/targets 2>/dev/null | grep -o '"health":"[a-z]*"' | sort | uniq -c || true

# ============================== ИТОГ =========================================
step "Итоговая проверка"
ip -br -4 addr; cat /proc/mdstat; df -h /raid; exportfs -v
echo -e "${C_G}HQ-SRV настроен. Лог: $LOG_FILE${C_N}"
