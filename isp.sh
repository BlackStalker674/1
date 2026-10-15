#!/bin/bash
# =============================================================================
#  isp.sh — маршрутизатор провайдера ISP (ALT Linux p10 / JeOS)
#  КОД 09.02.06-1-2026
#   М1: имя, адресация, NAT для HQ-RTR и BR-RTR, часовой пояс
#   М2: chrony-сервер (stratum 5), nginx — обратный прокси + basic-auth
#   SSH переведён на порт 2027
#   М3: HTTPS на обратном прокси (сертификаты УЦ HQ-SRV, ГОСТ + RSA)
#  Запуск: первым из всех, с консоли ВМ (сеть перезапускается):  ./isp.sh
#  После hq-srv.sh — только перевод прокси на HTTPS:              ./isp.sh tls
# =============================================================================

# ---------------------------- ПАРАМЕТРЫ --------------------------------------
HOST_FQDN="isp.au-team.irpo"
TZ_NAME="Asia/Krasnoyarsk"
IF_WAN="enp7s1"            # к магистральному провайдеру (DHCP)
IF_HQ="enp7s2"             # к HQ-RTR
IF_BR="enp7s3"             # к BR-RTR
IP_HQ="172.16.1.1/28"
IP_BR="172.16.2.1/28"
SSH_PORT="2027"
NTP_UPSTREAM="ru.pool.ntp.org"
WEB_BACKEND="172.16.1.2:8080"     # HQ-RTR -> DNAT -> HQ-SRV:80
DOCKER_BACKEND="172.16.2.2:8080"  # BR-RTR -> DNAT -> BR-SRV:8080
HTUSER="WEB"
HTPASS="P@ssw0rd"
CERT_HOST="172.16.1.2"; CERT_PORT="2027"   # HQ-SRV через DNAT на HQ-RTR
CERT_USER="sshuser"; CERT_PASS="P@ssw0rd"
STAGE="${1:-all}"                          # all | tls

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
if [ "$STAGE" != "tls" ]; then
# ============================== МОДУЛЬ 1 =====================================
step "Проверка интерфейсов"
check_iface "$IF_WAN"; check_iface "$IF_HQ"; check_iface "$IF_BR"

step "Имя устройства"
set_hostname "$HOST_FQDN"

step "Адресация (etcnet)"
etcnet_eth "$IF_WAN" dhcp           # адрес от магистрального провайдера по DHCP
etcnet_eth "$IF_HQ"  static "$IP_HQ"
etcnet_eth "$IF_BR"  static "$IP_BR"
enable_forward
restart_network
ip -4 addr show "$IF_HQ" | grep -q "${IP_HQ%/*}" || die "$IF_HQ без адреса $IP_HQ"
ip -4 addr show "$IF_BR" | grep -q "${IP_BR%/*}" || die "$IF_BR без адреса $IP_BR"
ip -4 addr show "$IF_WAN" | grep -q 'inet ' || die "$IF_WAN не получил адрес по DHCP"
ip route | grep -q '^default' || die "Нет маршрута по умолчанию (DHCP должен его выдать)"
ok "Адреса и маршрут по умолчанию на месте"
wait_inet

step "Часовой пояс"
set_tz

step "NAT (динамическая трансляция портов) для HQ-RTR и BR-RTR"
pkg_install iptables
iptables -t nat -F POSTROUTING
iptables -t nat -A POSTROUTING -s 172.16.1.0/28 -o "$IF_WAN" -j MASQUERADE
iptables -t nat -A POSTROUTING -s 172.16.2.0/28 -o "$IF_WAN" -j MASQUERADE
iptables-save > /etc/sysconfig/iptables || die "Не удалось сохранить правила"
systemctl enable iptables >/dev/null 2>&1 || die "Не удалось включить iptables.service"
iptables -t nat -S POSTROUTING | grep -q MASQUERADE && ok "MASQUERADE настроен и сохранён" || die "Правило NAT не применилось"

# ============================== МОДУЛЬ 2 =====================================
step "chrony — NTP-сервер, stratum 5"
pkg_install chrony
backup /etc/chrony.conf
cat > /etc/chrony.conf <<EOF
# Вышестоящий сервер
pool $NTP_UPSTREAM iburst
# Собственный стратум сервера
local stratum 5
# Клиенты: сети к HQ-RTR/BR-RTR и офисные сети
allow 172.16.0.0/12
allow 192.168.0.0/16
allow 10.0.0.0/8
driftfile /var/lib/chrony/drift
makestep 1.0 3
rtcsync
EOF
systemctl enable chronyd >/dev/null 2>&1
systemctl restart chronyd || die "chronyd не запустился"
systemctl is-active --quiet chronyd && ok "chronyd работает" || die "chronyd не активен"

step "nginx — обратный прокси web/docker + basic-auth"
pkg_install nginx openssl
mkdir -p /etc/nginx/sites-available.d /etc/nginx/sites-enabled.d
# Хеш apr1 через openssl — не нужен пакет с htpasswd
printf '%s:%s\n' "$HTUSER" "$(openssl passwd -apr1 "$HTPASS")" > /etc/nginx/.htpasswd
chmod 644 /etc/nginx/.htpasswd
cat > /etc/nginx/sites-available.d/proxy.conf <<EOF
# web.au-team.irpo -> веб-приложение HQ-SRV (через DNAT на HQ-RTR)
server {
    listen 80;
    server_name web.au-team.irpo;
    auth_basic "Authorized access only";
    auth_basic_user_file /etc/nginx/.htpasswd;
    location / {
        proxy_pass http://$WEB_BACKEND;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    }
}
# docker.au-team.irpo -> testapp на BR-SRV (через DNAT на BR-RTR)
server {
    listen 80;
    server_name docker.au-team.irpo;
    location / {
        proxy_pass http://$DOCKER_BACKEND;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    }
}
EOF
ln -sf /etc/nginx/sites-available.d/proxy.conf /etc/nginx/sites-enabled.d/proxy.conf
grep -q 'sites-enabled.d' /etc/nginx/nginx.conf || warn "nginx.conf не подключает sites-enabled.d — проверьте include"
nginx -t || die "Ошибка конфигурации nginx (nginx -t)"
systemctl enable nginx >/dev/null 2>&1
systemctl restart nginx || die "nginx не запустился"
systemctl is-active --quiet nginx && ok "nginx работает, .htpasswd: /etc/nginx/.htpasswd" || die "nginx не активен"

step "SSH на порт $SSH_PORT"
sshd_set Port "$SSH_PORT"
sshd_apply

fi   # конец этапа all

# ============================== МОДУЛЬ 3 =====================================
step "Перевод обратного прокси на HTTPS"
pkg_install nginx sshpass
SSL_DIR=/etc/nginx/ssl
mkdir -p "$SSL_DIR"; chmod 700 "$SSL_DIR"
if sshpass -p "$CERT_PASS" scp -q -P "$CERT_PORT" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
     "$CERT_USER@$CERT_HOST:certs/*" "$SSL_DIR/"; then
  chmod 600 "$SSL_DIR"/*.key
  ok "Сертификаты получены с HQ-SRV: $(ls "$SSL_DIR" | tr '\n' ' ')"
  for n in web docker; do
    [ -s "$SSL_DIR/$n-rsa.crt" ] && [ -s "$SSL_DIR/$n-rsa.key" ] || die "Нет $n-rsa.crt/.key — перезапустите hq-srv.sh"
  done
  # Пара ГОСТ подключается, только если её понимает OpenSSL на ISP
  USE_GOST=0
  if [ -s "$SSL_DIR/web-gost.crt" ]; then
    if pkg_try openssl-gost-engine; then control openssl-gost enabled >/dev/null 2>&1 || true; fi
    openssl list -public-key-algorithms 2>/dev/null | grep -qi gost2012_256 && USE_GOST=1
  fi
  gen_site() {      # $1 короткое имя, $2 backend, $3 basic-auth (1/0), $4 использовать ГОСТ (1/0)
    cat <<EOF
server {
    listen 80;
    server_name $1.au-team.irpo;
    return 301 https://\$host\$request_uri;
}
server {
    listen 443 ssl;
    server_name $1.au-team.irpo;
    ssl_certificate     $SSL_DIR/$1-rsa.crt;
    ssl_certificate_key $SSL_DIR/$1-rsa.key;
EOF
    if [ "$4" = 1 ]; then cat <<EOF
    ssl_certificate     $SSL_DIR/$1-gost.crt;
    ssl_certificate_key $SSL_DIR/$1-gost.key;
EOF
    fi
    cat <<EOF
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers GOST2012-KUZNYECHIK-KUZNYECHIKOMAC:GOST2012-MAGMA-MAGMAOMAC:GOST2012-GOST8912-GOST8912:HIGH:!aNULL:!MD5;
    ssl_prefer_server_ciphers on;
EOF
    if [ "$3" = 1 ]; then cat <<EOF
    auth_basic "Authorized access only";
    auth_basic_user_file /etc/nginx/.htpasswd;
EOF
    fi
    cat <<EOF
    location / {
        proxy_pass http://$2;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
    }
}
EOF
  }
  write_conf() { { gen_site web "$WEB_BACKEND" 1 "$1"; gen_site docker "$DOCKER_BACKEND" 0 "$1"; } > /etc/nginx/sites-available.d/proxy.conf; }
  backup /etc/nginx/sites-available.d/proxy.conf
  write_conf "$USE_GOST"
  if ! nginx -t 2>/dev/null; then
    if [ "$USE_GOST" = 1 ]; then
      warn "nginx не принял ГОСТ-ключи — оставляю только RSA-цепочку того же УЦ"
      USE_GOST=0; write_conf 0
    fi
    nginx -t || die "Ошибка конфигурации nginx (nginx -t)"
  fi
  ln -sf /etc/nginx/sites-available.d/proxy.conf /etc/nginx/sites-enabled.d/proxy.conf
  systemctl restart nginx || die "nginx не перезапустился"
  ss -tln | grep -q ':443 ' && ok "nginx слушает 443 (ГОСТ: $([ $USE_GOST = 1 ] && echo да || echo нет)), HTTP -> HTTPS" || die "nginx не слушает 443"
  for n in web docker; do
    openssl x509 -in "$SSL_DIR/$n-rsa.crt" -noout -subject -enddate | tr '\n' ' '; echo
  done
else
  warn "Не удалось забрать сертификаты с $CERT_USER@$CERT_HOST:$CERT_PORT — после hq-srv.sh выполните: ./isp.sh tls"
fi
# ============================== ИТОГ =========================================
step "Итоговая проверка"
ip -br -4 addr
ip route
iptables -t nat -S POSTROUTING
chronyc tracking | sed -n '1,4p' || true
echo -e "${C_G}ISP настроен. Лог: $LOG_FILE${C_N}"
echo "Дальше: hq-rtr.sh и br-rtr.sh"
