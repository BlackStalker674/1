#!/bin/bash
# =============================================================================
#  hq-cli.sh — рабочая станция HQ-CLI (ALT Linux p10 Рабочая станция)
#  КОД 09.02.06-1-2026
#   М1: имя, адрес по DHCP от HQ-RTR (сеть — через NetworkManager, не etcnet)
#   М2: ввод в домен au-team.irpo (SSSD), sudo для группы hq (cat, grep, id),
#       автомонтирование NFS в /mnt/nfs, NTP-клиент, Яндекс Браузер,
#       sshuser + SSH 2027 (для Ansible с BR-SRV)
#   М3: принтер PDF с HQ-SRV по умолчанию, доверие к УЦ (система, NSS, Firefox)
#  Запуск: последним, после br-srv.sh (домен должен уже работать).
# =============================================================================

# ---------------------------- ПАРАМЕТРЫ --------------------------------------
HOST_FQDN="hq-cli.au-team.irpo"
HOST_SHORT="hq-cli"
TZ_NAME="Asia/Krasnoyarsk"
IF_LAN="enp7s1"
EXPECTED_IP="192.168.200.2"     # зарезервирован на HQ-RTR за именем hq-cli
SSH_PORT="2027"
SSH_USER="sshuser"; SSH_UID="2027"; PASS="P@ssw0rd"
NTP_SRV="172.16.1.1"
HQ_SRV="192.168.100.2"
AD_DOMAIN="au-team.irpo"; AD_WORKGROUP="AU-TEAM"; AD_ADMIN="Administrator"; AD_PASS="P@ssw0rd"

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

# ============================== МОДУЛЬ 1 =====================================
step "Имя устройства"
check_iface "$IF_LAN"
set_hostname "$HOST_FQDN"

step "Сеть через NetworkManager (DHCP)"
command -v nmcli >/dev/null || die "nmcli не найден — на HQ-CLI сеть должна управляться NetworkManager"
systemctl is-active --quiet NetworkManager || systemctl enable --now NetworkManager || die "NetworkManager не запущен"
CON="$(nmcli -t -f NAME,DEVICE con show | awk -F: -v d="$IF_LAN" '$2==d{print $1; exit}' || true)"
if [ -z "$CON" ]; then
  nmcli con add type ethernet ifname "$IF_LAN" con-name "$IF_LAN" || die "Не удалось создать подключение"
  CON="$IF_LAN"
fi
nmcli con mod "$CON" ipv4.method auto ipv4.addresses "" ipv4.gateway "" \
  ipv4.ignore-auto-dns no ipv4.dhcp-send-hostname yes ipv4.dhcp-hostname "$HOST_SHORT" \
  connection.autoconnect yes || die "nmcli con mod не выполнен"
nmcli con down "$CON" >/dev/null 2>&1 || true
nmcli con up "$CON" || die "Подключение $CON не поднялось"
for i in $(seq 1 20); do ip -4 addr show "$IF_LAN" | grep -q 'inet ' && break; sleep 1; done
CUR_IP="$(ip -4 -o addr show "$IF_LAN" | awk '{print $4}' | cut -d/ -f1 | head -1 || true)"
[ -n "$CUR_IP" ] || die "Адрес по DHCP не получен — проверьте HQ-RTR (dnsmasq) и VLAN 200"
ok "Получен адрес $CUR_IP"
[ "$CUR_IP" = "$EXPECTED_IP" ] || warn "Адрес $CUR_IP, а в DNS hq-cli = $EXPECTED_IP. Проверьте dhcp-host на HQ-RTR"
grep -q "nameserver $HQ_SRV" /etc/resolv.conf && ok "DNS от DHCP: $HQ_SRV" || warn "В resolv.conf нет $HQ_SRV"
grep -q 'au-team.irpo' /etc/resolv.conf && ok "DNS-суффикс au-team.irpo получен" || warn "Нет суффикса au-team.irpo"
wait_inet

step "Часовой пояс и NTP"
set_tz
chrony_client "$NTP_SRV"

step "Пользователь $SSH_USER и SSH $SSH_PORT (для Ansible)"
pkg_install openssh-server python3
create_user "$SSH_USER" "$SSH_UID" "$PASS"
install_sudoers "$SSH_USER" "$SSH_USER ALL=(ALL:ALL) NOPASSWD: ALL"
sshd_set Port "$SSH_PORT"
sshd_set PermitRootLogin no
sshd_apply

# ============================== МОДУЛЬ 2 =====================================
step "Ввод в домен $AD_DOMAIN"
pkg_install task-auth-ad-sssd
getent hosts br-srv.au-team.irpo >/dev/null || die "Не разрешается br-srv.au-team.irpo — проверьте DNS на HQ-SRV"
if command -v host >/dev/null 2>&1; then
  host -t SRV "_ldap._tcp.$AD_DOMAIN" >/dev/null && ok "SRV-записи домена разрешаются" || warn "Нет SRV _ldap._tcp — проверьте пересылку на HQ-SRV"
fi
if [ -f /etc/sssd/sssd.conf ] && grep -qi "$AD_DOMAIN" /etc/sssd/sssd.conf; then
  warn "Машина уже в домене — ввод пропущен"
else
  system-auth write ad "$AD_DOMAIN" "$HOST_SHORT" "$AD_WORKGROUP" "$AD_ADMIN" "$AD_PASS" \
    || die "system-auth write ad завершился с ошибкой (DC доступен? время синхронно?)"
fi
systemctl enable sssd >/dev/null 2>&1 || true
systemctl restart sssd || die "sssd не запустился"
sleep 3
if id hquser1 >/dev/null 2>&1 || id "hquser1@$AD_DOMAIN" >/dev/null 2>&1; then ok "Доменные пользователи видны (id hquser1)"
else warn "id hquser1 не разрешается — проверьте 'systemctl status sssd'"; fi

step "sudo для группы hq: только cat, grep, id"
control sudo public 2>/dev/null || true          # sudo доступен не только wheel (ALT control)
P_CAT="$(command -v cat)"; P_GREP="$(command -v grep)"; P_ID="$(command -v id)"
install_sudoers "hq" "%hq ALL=(ALL) $P_CAT, $P_GREP, $P_ID
%hq@$AD_DOMAIN ALL=(ALL) $P_CAT, $P_GREP, $P_ID"

step "NFS: автомонтирование $HQ_SRV:/raid/nfs -> /mnt/nfs"
pkg_install nfs-clients
mkdir -p /mnt/nfs
sed -i '\#[[:space:]]/mnt/nfs[[:space:]]#d' /etc/fstab
echo "$HQ_SRV:/raid/nfs /mnt/nfs nfs defaults,_netdev,x-systemd.automount 0 0" >> /etc/fstab
systemctl daemon-reload
systemctl restart remote-fs.target >/dev/null 2>&1 || true
mount -a || warn "mount -a вернул ошибку"
if ls /mnt/nfs >/dev/null 2>&1 && touch /mnt/nfs/.hq-cli-test 2>/dev/null; then
  rm -f /mnt/nfs/.hq-cli-test; ok "/mnt/nfs смонтирован, запись работает"
else warn "/mnt/nfs недоступен — проверьте экспорт на HQ-SRV"; fi

step "Яндекс Браузер"
if rpm -q yandex-browser-stable >/dev/null 2>&1; then ok "Уже установлен"
elif pkg_try yandex-browser-stable; then ok "Яндекс Браузер установлен"
else warn "Пакета нет в репозитории — установите через Центр приложений или .rpm с browser.yandex.ru"; fi

# ============================== МОДУЛЬ 3 =====================================
step "Принтер PDF с HQ-SRV по умолчанию"
if pkg_try cups; then
  systemctl enable --now cups || warn "cups не запустился"
  URI="ipp://hq-srv.au-team.irpo:631/printers/PDF"
  lpadmin -p PDF -E -v "$URI" -m everywhere 2>/dev/null \
    || lpadmin -p PDF -E -v "$URI" -m raw 2>/dev/null \
    || warn "Принтер не добавлен (HQ-SRV/CUPS доступен?)"
  if lpstat -p PDF >/dev/null 2>&1; then
    lpadmin -d PDF; lpoptions -d PDF >/dev/null
    lpstat -d | grep -q PDF && ok "PDF — принтер по умолчанию"
  fi
fi

step "Доверие к корневым сертификатам УЦ HQ-SRV"
CA_SRC=/mnt/nfs/ca
if ls "$CA_SRC"/ca-*.crt >/dev/null 2>&1; then
  pkg_try openssl-gost-engine && { control openssl-gost enabled >/dev/null 2>&1 || true; }
  # 1) Системное хранилище (curl, wget, приложения на OpenSSL/GnuTLS)
  mkdir -p /etc/pki/ca-trust/source/anchors
  cp -f "$CA_SRC"/ca-*.crt /etc/pki/ca-trust/source/anchors/
  update-ca-trust extract 2>/dev/null || update-ca-trust || warn "update-ca-trust не выполнен"
  ok "Корневые сертификаты добавлены в системное хранилище"
  # 2) NSS (Яндекс Браузер/Chromium): /etc/skel и существующие профили
  if pkg_try nss-utils; then
    add_nss() {
      local db="$1" owner="$2" c
      mkdir -p "$db"
      [ -f "$db/cert9.db" ] || certutil -N -d "sql:$db" --empty-password
      for c in "$CA_SRC"/ca-*.crt; do
        certutil -D -d "sql:$db" -n "AU-TEAM $(basename "$c" .crt)" >/dev/null 2>&1 || true
        certutil -A -d "sql:$db" -n "AU-TEAM $(basename "$c" .crt)" -t "C,," -i "$c"
      done
      [ -n "$owner" ] && chown -R "$owner": "$(dirname "$db")"
      return 0
    }
    add_nss /etc/skel/.pki/nssdb ""                    # для новых (в т.ч. доменных) пользователей
    add_nss /root/.pki/nssdb ""
    for h in /home/*; do
      u="$(basename "$h")"; id "$u" >/dev/null 2>&1 && add_nss "$h/.pki/nssdb" "$u"
    done
    ok "Сертификаты УЦ добавлены в NSS (Яндекс Браузер)"
  fi
  # 3) Firefox — через политики
  mkdir -p /etc/firefox/policies
  {
    echo '{"policies": {"Certificates": {"ImportEnterpriseRoots": true, "Install": ['
    first=1; for c in /etc/pki/ca-trust/source/anchors/ca-*.crt; do
      [ $first = 1 ] || echo ','; first=0; printf '"%s"' "$c"
    done
    echo ']}}}'
  } > /etc/firefox/policies/policies.json
  python3 -m json.tool /etc/firefox/policies/policies.json >/dev/null && ok "Политика Firefox: /etc/firefox/policies/policies.json"
  # Проверка
  for n in web docker; do
    code="$(curl -s -o /dev/null -w '%{http_code}' "https://$n.au-team.irpo/" || true)"
    case "$code" in
      200|301|302|401) ok "https://$n.au-team.irpo — сертификат принят (HTTP $code)";;
      *) warn "https://$n.au-team.irpo — нет ответа/ошибка TLS (код '$code'). Выполнен ли ./isp.sh tls?";;
    esac
  done
else
  warn "Нет $CA_SRC/ca-*.crt — сначала hq-srv.sh (УЦ) и работающий /mnt/nfs"
fi

# ============================== ИТОГ =========================================
step "Итоговая проверка"
ip -br -4 addr; cat /etc/resolv.conf
df -h /mnt/nfs 2>/dev/null || true
echo -e "${C_G}HQ-CLI настроен. Лог: $LOG_FILE${C_N}"
echo "Проверьте вход доменным пользователем hquser1 (пароль $PASS) в графическом сеансе."
