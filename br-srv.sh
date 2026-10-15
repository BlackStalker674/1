#!/bin/bash
# =============================================================================
#  br-srv.sh — сервер филиала BR-SRV, контроллер домена (ALT Linux p10 Server)
#  КОД 09.02.06-1-2026
#   М1: имя, адрес, sshuser, SSH 2027
#   М2: Samba DC au-team.irpo (hquser1..5, группа hq), NTP-клиент,
#       Ansible (/etc/ansible), docker compose: testapp + db (порт 8080)
#   М3: node_exporter для мониторинга, импорт пользователей из users.csv, плейбук инвентаризации (PC-INFO),
#       rsyslog-клиент (warning+) на HQ-SRV
#  Запуск: после hq-srv.sh. Нужен подключённый образ Additional.iso (/dev/sr0).
# =============================================================================

# ---------------------------- ПАРАМЕТРЫ --------------------------------------
HOST_FQDN="br-srv.au-team.irpo"
TZ_NAME="Asia/Krasnoyarsk"
IF_LAN="enp7s1"
IP_ADDR="192.168.0.2/28"; GW="192.168.0.1"
SSH_PORT="2027"
SSH_USER="sshuser"; SSH_UID="2027"; PASS="P@ssw0rd"
NTP_SRV="172.16.2.1"
HQ_SRV="192.168.100.2"
REALM="AU-TEAM.IRPO"; DOMAIN="AU-TEAM"; ADMIN_PASS="P@ssw0rd"
DNS_FORWARDER="$HQ_SRV"
ISO_DEV="/dev/sr0"; ISO_MNT="/mnt/additional"
APP_DIR="/root/testapp"
APP_INNER_PORT="8000"            # порт, который слушает приложение внутри образа site
IMPORT_DEFAULT_PASS="P@ssw0rd1"  # если в users.csv нет столбца с паролем

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
SAMBA_AUTH=(-U administrator --password="$ADMIN_PASS")

# ============================== МОДУЛЬ 1 =====================================
step "Проверка интерфейса и имя"
check_iface "$IF_LAN"
set_hostname "$HOST_FQDN"
sed -i '/br-srv/d' /etc/hosts
echo "${IP_ADDR%/*} $HOST_FQDN br-srv" >> /etc/hosts

step "Адресация (на время установки DNS = 77.88.8.8)"
etcnet_eth "$IF_LAN" static "$IP_ADDR" "$GW" "77.88.8.8"
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

step "Установка пакетов модуля 2"
pkg_install task-samba-dc ansible sshpass docker-engine docker-compose-v2 python3
chrony_client "$NTP_SRV"

# ============================== МОДУЛЬ 2 =====================================
step "Samba DC: домен $REALM"
if [ -f /var/lib/samba/private/sam.ldb ]; then
  warn "Домен уже развёрнут — provision пропущен"
else
  for s in smb nmb krb5kdc slapd bind; do systemctl disable --now "$s" >/dev/null 2>&1 || true; done
  rm -f /etc/samba/smb.conf
  rm -rf /var/lib/samba /var/cache/samba
  mkdir -p /var/lib/samba/sysvol
  samba-tool domain provision --realm="$REALM" --domain="$DOMAIN" \
    --server-role=dc --dns-backend=SAMBA_INTERNAL --use-rfc2307 \
    --adminpass="$ADMIN_PASS" --option="dns forwarder = $DNS_FORWARDER" \
    || die "samba-tool domain provision завершился с ошибкой"
  ok "Домен развёрнут"
fi
cp -f /var/lib/samba/private/krb5.conf /etc/krb5.conf
systemctl enable samba >/dev/null 2>&1
systemctl restart samba || die "Служба samba не запустилась"
sleep 5
set_resolv "$IF_LAN" 127.0.0.1
samba-tool domain info 127.0.0.1 >/dev/null || die "Контроллер домена не отвечает"
ok "Samba DC работает"

step "DNS-записи офисов в зоне AD (для разрешения имён с самого DC)"
add_a() {
  samba-tool dns query 127.0.0.1 au-team.irpo "$1" A "${SAMBA_AUTH[@]}" >/dev/null 2>&1 \
    || samba-tool dns add 127.0.0.1 au-team.irpo "$1" A "$2" "${SAMBA_AUTH[@]}" >/dev/null 2>&1 \
    || warn "Не удалось добавить $1"
}
add_a hq-rtr 192.168.100.1; add_a hq-srv "$HQ_SRV"; add_a hq-cli 192.168.200.2
add_a br-rtr 192.168.0.1; add_a docker 172.16.1.1; add_a web 172.16.2.1
ok "Записи A добавлены"

step "Пользователи hquser1..5 и группа hq"
samba-tool group show hq >/dev/null 2>&1 || samba-tool group add hq || die "Группа hq не создана"
for i in 1 2 3 4 5; do
  u="hquser$i"
  if ! samba-tool user show "$u" >/dev/null 2>&1; then
    samba-tool user create "$u" "$PASS" || die "Не создан $u"
  fi
  samba-tool user setexpiry "$u" --noexpiry >/dev/null
  samba-tool group listmembers hq | grep -qx "$u" || samba-tool group addmembers hq "$u" >/dev/null
done
[ "$(samba-tool group listmembers hq | grep -c '^hquser')" -ge 5 ] && ok "В группе hq 5 пользователей" || die "Группа hq заполнена не полностью"

step "Ansible: /etc/ansible"
mkdir -p /etc/ansible/PC-INFO
cat > /etc/ansible/ansible.cfg <<'EOF'
[defaults]
inventory = /etc/ansible/hosts
host_key_checking = False
interpreter_python = auto_silent
deprecation_warnings = False
command_warnings = False
EOF
cat > /etc/ansible/hosts <<EOF
[servers]
hq-srv ansible_host=$HQ_SRV ansible_user=$SSH_USER

[clients]
hq-cli ansible_host=192.168.200.2 ansible_user=$SSH_USER

[routers]
hq-rtr ansible_host=192.168.100.1 ansible_user=net_admin
br-rtr ansible_host=192.168.0.1 ansible_user=net_admin

[all:vars]
ansible_port=$SSH_PORT
ansible_password=$PASS
ansible_python_interpreter=/usr/bin/python3
EOF
chmod 600 /etc/ansible/hosts
ansible-inventory --list >/dev/null || die "Ошибка в инвентаре"
ok "Инвентарь: hq-srv, hq-cli, hq-rtr, br-rtr"
if (cd /etc/ansible && ansible all -m ping -o); then ok "Все хосты отвечают pong"
else warn "Не все хосты отвечают — после настройки остальных ВМ: cd /etc/ansible && ansible all -m ping"; fi

step "Docker: стек testapp + db"
systemctl enable --now docker || die "docker не запустился"
if mount_iso; then
  DOCKER_SRC="$(find "$ISO_MNT" -maxdepth 2 -type d -iname docker | head -1)"
  [ -n "$DOCKER_SRC" ] || die "В образе нет каталога docker"
  load_img() {
    local tar; tar="$(find "$DOCKER_SRC" -maxdepth 1 -iname "$1*.tar*" | head -1)"
    [ -n "$tar" ] || die "Не найден архив образа $1 в $DOCKER_SRC"
    docker load -i "$tar" | sed -n 's/^Loaded image: //p' | tail -1
  }
  APP_IMAGE="$(load_img site)"; DB_IMAGE="$(load_img mariadb)"
  [ -n "$APP_IMAGE" ] && [ -n "$DB_IMAGE" ] || die "Не удалось определить имена загруженных образов"
  ok "Образы: $APP_IMAGE, $DB_IMAGE"
  mkdir -p "$APP_DIR"
  cat > "$APP_DIR/compose.yaml" <<EOF
services:
  db:
    image: $DB_IMAGE
    container_name: db
    restart: always
    environment:
      MARIADB_DATABASE: testdb
      MARIADB_USER: test
      MARIADB_PASSWORD: "P@ssw0rd"
      MARIADB_ROOT_PASSWORD: "P@ssw0rd"
      MYSQL_DATABASE: testdb
      MYSQL_USER: test
      MYSQL_PASSWORD: "P@ssw0rd"
      MYSQL_ROOT_PASSWORD: "P@ssw0rd"
    volumes:
      - db_data:/var/lib/mysql
  testapp:
    image: $APP_IMAGE
    container_name: testapp
    restart: always
    depends_on:
      - db
    ports:
      - "8080:$APP_INNER_PORT"
    environment:
      DB_TYPE: maria
      DB_HOST: db
      DB_PORT: "3306"
      DB_NAME: testdb
      DB_USER: test
      DB_PASS: "P@ssw0rd"
volumes:
  db_data:
EOF
  (cd "$APP_DIR" && docker compose config -q) || die "Ошибка в compose.yaml"
  (cd "$APP_DIR" && docker compose up -d) || die "docker compose up не выполнен"
  for i in $(seq 1 30); do
    curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8080/ 2>/dev/null | grep -qE '^(200|30[0-9])$' && break; sleep 2
  done
  docker ps --format '{{.Names}}\t{{.Status}}\t{{.Ports}}'
  curl -s -o /dev/null http://127.0.0.1:8080/ && ok "testapp доступен на :8080" || warn "testapp не отвечает — docker logs testapp (проверьте APP_INNER_PORT)"
else
  warn "Образ не подключён — docker-стек пропущен"
fi

# ============================== МОДУЛЬ 3 =====================================
step "Импорт пользователей из users.csv"
CSV=""
if mount_iso; then CSV="$(find "$ISO_MNT" -maxdepth 2 -iname 'users.csv' | head -1)"; fi
if [ -n "$CSV" ]; then
  tr -d '\r' < "$CSV" | sed '1s/^\xEF\xBB\xBF//' > /tmp/users.csv
  head -1 /tmp/users.csv | grep -q ';' && DELIM=';' || DELIM=','
  IFS="$DELIM" read -r -a HDR < /tmp/users.csv
  col() { local i; for i in "${!HDR[@]}"; do echo "${HDR[$i]}" | grep -qiE "$1" && { echo "$i"; return; }; done; echo -1; }
  C_FIRST=$(col 'first|given|^имя'); C_LAST=$(col 'last|surname|фамил')
  C_LOGIN=$(col 'login|user|samaccount|логин'); C_PASS=$(col 'pass|парол')
  C_OU=$(col '^ou$|^ou[ _]|unit|отдел|подраздел'); C_PHONE=$(col 'phone|тел')
  C_TITLE=$(col 'title|role|должн')
  echo "Заголовок CSV: ${HDR[*]}"
  CNT=0; FAIL=0
  while IFS="$DELIM" read -r -a R; do
    [ ${#R[@]} -gt 1 ] || continue
    fn="${R[$C_FIRST]:-}"; ln="${R[$C_LAST]:-}"; [ "$C_FIRST" -ge 0 ] || fn=""; [ "$C_LAST" -ge 0 ] || ln=""
    if [ "$C_LOGIN" -ge 0 ] && [ -n "${R[$C_LOGIN]}" ]; then login="${R[$C_LOGIN]}"
    else login="$(echo "$fn.$ln" | tr '[:upper:]' '[:lower:]' | tr -d ' ')"; fi
    [ -n "$login" ] && [ "$login" != "." ] || continue
    pw="$IMPORT_DEFAULT_PASS"; [ "$C_PASS" -ge 0 ] && [ -n "${R[$C_PASS]}" ] && pw="${R[$C_PASS]}"
    args=()
    [ -n "$fn" ] && args+=(--given-name="$fn"); [ -n "$ln" ] && args+=(--surname="$ln")
    [ "$C_PHONE" -ge 0 ] && [ -n "${R[$C_PHONE]}" ] && args+=(--telephone-number="${R[$C_PHONE]}")
    [ "$C_TITLE" -ge 0 ] && [ -n "${R[$C_TITLE]}" ] && args+=(--job-title="${R[$C_TITLE]}")
    if [ "$C_OU" -ge 0 ] && [ -n "${R[$C_OU]}" ]; then
      ou="${R[$C_OU]}"
      samba-tool ou create "OU=$ou,DC=au-team,DC=irpo" >/dev/null 2>&1 || true
      args+=(--userou="OU=$ou")
    fi
    if samba-tool user show "$login" >/dev/null 2>&1; then continue; fi
    if samba-tool user create "$login" "$pw" "${args[@]}" >/dev/null 2>&1; then
      samba-tool user setexpiry "$login" --noexpiry >/dev/null 2>&1 || true; CNT=$((CNT+1))
    else FAIL=$((FAIL+1)); warn "Не создан: $login"; fi
  done < <(tail -n +2 /tmp/users.csv)
  ok "Импортировано пользователей: $CNT, ошибок: $FAIL"
else
  warn "users.csv не найден в образе — импорт пропущен"
fi

step "Плейбук инвентаризации -> /etc/ansible, отчёты в PC-INFO"
if mountpoint -q "$ISO_MNT"; then
  PB_SRC="$(find "$ISO_MNT" -maxdepth 2 -type d -iname playbook | head -1)"
  if [ -n "$PB_SRC" ]; then cp -f "$PB_SRC"/*.y*ml /etc/ansible/ 2>/dev/null && ok "Плейбук скопирован в /etc/ansible" || warn "В $PB_SRC нет *.yml"
  else warn "Каталог playbook в образе не найден"; fi
fi

step "rsyslog -> HQ-SRV"
rsyslog_client "$HQ_SRV"

step "Агент мониторинга node_exporter (:9100) для HQ-SRV"
pkg_install prometheus-node_exporter
enable_first node_exporter prometheus-node_exporter prometheus-node-exporter
ss -tln | grep -q ':9100 ' && ok "node_exporter слушает 9100" || warn "node_exporter не слушает 9100"

step "Инвентаризация HQ-SRV и HQ-CLI через Ansible"
PB=""
for f in /etc/ansible/*.yml /etc/ansible/*.yaml; do
  [ -f "$f" ] && grep -q 'hosts:' "$f" && { PB="$f"; break; }
done
if [ -z "$PB" ]; then
  PB=/etc/ansible/inventory.yml
  cat > "$PB" <<'EOF'
---
- name: Инвентаризация рабочих мест
  hosts: hq-srv,hq-cli
  gather_facts: true
  tasks:
    - name: Сохранить имя и IP-адрес в /etc/ansible/PC-INFO/<имя>.yml
      copy:
        dest: "/etc/ansible/PC-INFO/{{ ansible_hostname }}.yml"
        content: |
          hostname: {{ ansible_hostname }}
          fqdn: {{ ansible_fqdn }}
          ip_address: {{ ansible_default_ipv4.address }}
      delegate_to: localhost
EOF
  ok "В образе плейбука нет — создан $PB"
else
  ok "Используется плейбук из образа: $PB"
fi
if (cd /etc/ansible && ansible-playbook "$PB"); then
  ls -1 /etc/ansible/PC-INFO/; ok "Отчёты сохранены в /etc/ansible/PC-INFO"
else
  warn "Плейбук не отработал (HQ-SRV/HQ-CLI ещё не готовы?). Повтор: cd /etc/ansible && ansible-playbook $PB"
fi

# ============================== ИТОГ =========================================
step "Итоговая проверка"
ip -br -4 addr
samba-tool domain level show 2>/dev/null | head -3 || true
samba-tool group listmembers hq
echo -e "${C_G}BR-SRV настроен. Лог: $LOG_FILE${C_N}"
