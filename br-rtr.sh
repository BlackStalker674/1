#!/bin/bash
# =============================================================================
#  br-rtr.sh — маршрутизатор филиала BR-RTR (ALT Linux p10 / JeOS)
#  КОД 09.02.06-1-2026
#   М1: имя, адресация, net_admin, GRE-туннель, OSPF с MD5, NAT
#   М2: проброс 8080 -> BR-SRV:8080 и 2027 -> BR-SRV:2027, NTP-клиент
#   М3: rsyslog-клиент на HQ-SRV, IPsec поверх GRE, межсетевой экран на WAN
#  Запуск: после isp.sh (лучше после hq-rtr.sh), с консоли ВМ.
# =============================================================================

# ---------------------------- ПАРАМЕТРЫ --------------------------------------
HOST_FQDN="br-rtr.au-team.irpo"
TZ_NAME="Asia/Krasnoyarsk"
IF_WAN="enp7s1"                 # к ISP
IF_LAN="enp7s2"                 # к BR-SRV
WAN_IP="172.16.2.2/28"; WAN_GW="172.16.2.1"
LAN_IP="192.168.0.1/28"         # не более 16 адресов
TUN_LOCAL="172.16.2.2"; TUN_REMOTE="172.16.1.2"; TUN_IP="10.10.10.2/30"
OSPF_KEY="P@ssw0rd"
IPSEC_PSK="P@ssw0rd"              # общий ключ IPsec
BR_SRV="192.168.0.2"
HQ_SRV="192.168.100.2"
NTP_SRV="172.16.2.1"
SSH_PORT="2027"
APP_PORT="8080"                 # порт testapp на BR-SRV
ADMIN_USER="net_admin"; ADMIN_PASS="P@ssw0rd"

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
step "Проверка интерфейсов"
check_iface "$IF_WAN"; check_iface "$IF_LAN"

step "Имя устройства"
set_hostname "$HOST_FQDN"

step "Адресация"
etcnet_eth "$IF_WAN" static "$WAN_IP" "$WAN_GW" "77.88.8.8"
etcnet_eth "$IF_LAN" static "$LAN_IP"

step "GRE-туннель tun0"
modprobe gre || die "Модуль gre не загружен"
grep -qx gre /etc/modules 2>/dev/null || echo gre >> /etc/modules
mkdir -p /etc/net/ifaces/tun0
cat > /etc/net/ifaces/tun0/options <<EOF
TYPE=iptun
TUNTYPE=gre
TUNLOCAL=$TUN_LOCAL
TUNREMOTE=$TUN_REMOTE
TUNTTL=64
TUNOPTIONS='ttl 64'
HOST=$IF_WAN
DISABLED=no
NM_CONTROLLED=no
BOOTPROTO=static
CONFIG_IPV4=yes
EOF
echo "$TUN_IP" > /etc/net/ifaces/tun0/ipv4address
ok "tun0: $TUN_LOCAL -> $TUN_REMOTE, $TUN_IP"

enable_forward
restart_network
ip -4 addr show "$IF_LAN" | grep -q "${LAN_IP%/*}" || die "$IF_LAN без адреса"
ip -4 addr show tun0 | grep -q "${TUN_IP%/*}" || die "tun0 без адреса"
ok "Интерфейсы подняты"
wait_inet
ping -c2 -W2 10.10.10.1 >/dev/null 2>&1 && ok "Туннель до HQ-RTR отвечает" || warn "10.10.10.1 не отвечает (HQ-RTR ещё не настроен?)"

step "Часовой пояс"
set_tz

step "Пользователь $ADMIN_USER (sudo без пароля)"
create_user "$ADMIN_USER" "" "$ADMIN_PASS"
install_sudoers "$ADMIN_USER" "$ADMIN_USER ALL=(ALL:ALL) NOPASSWD: ALL"

step "OSPF (FRR) — только через tun0, MD5"
pkg_install frr
backup /etc/frr/daemons
sed -i -E 's/^ospfd=.*/ospfd=yes/' /etc/frr/daemons
grep -q '^ospfd=yes' /etc/frr/daemons || die "ospfd не включён в /etc/frr/daemons"
backup /etc/frr/frr.conf
cat > /etc/frr/frr.conf <<EOF
frr defaults traditional
hostname $HOST_FQDN
log syslog informational
!
interface tun0
 ip ospf network point-to-point
 ip ospf mtu-ignore
 ip ospf authentication message-digest
 ip ospf message-digest-key 1 md5 $OSPF_KEY
 no ip ospf passive
!
router ospf
 ospf router-id ${TUN_IP%/*}
 passive-interface default
 network 10.10.10.0/30 area 0
 network 192.168.0.0/28 area 0
 area 0 authentication message-digest
!
line vty
!
EOF
chown frr:frr /etc/frr/frr.conf 2>/dev/null || true
chmod 640 /etc/frr/frr.conf
systemctl enable frr >/dev/null 2>&1
systemctl restart frr || die "frr не запустился"
sleep 3
vtysh -c "show running-config" | grep -q "router ospf" || die "OSPF не загрузился в FRR"
ok "OSPF настроен"

step "NAT в сторону ISP и проброс портов"
pkg_install iptables
iptables -t nat -F
iptables -t nat -A POSTROUTING -o "$IF_WAN" -j MASQUERADE
iptables -t nat -A PREROUTING -i "$IF_WAN" -p tcp --dport 8080 -j DNAT --to-destination "$BR_SRV:$APP_PORT"
iptables -t nat -A PREROUTING -i "$IF_WAN" -p tcp --dport "$SSH_PORT" -j DNAT --to-destination "$BR_SRV:$SSH_PORT"
iptables-save > /etc/sysconfig/iptables || die "Не удалось сохранить правила"
systemctl enable iptables >/dev/null 2>&1 || die "Не удалось включить iptables.service"
iptables -t nat -S | grep -q "DNAT.*$BR_SRV:$SSH_PORT" && ok "NAT/DNAT сохранены" || die "DNAT не применился"

step "SSH на порт $SSH_PORT"
sshd_set Port "$SSH_PORT"
sshd_set PermitRootLogin no
sshd_apply

# ============================== МОДУЛЬ 2/3 ===================================
step "NTP-клиент и Python для Ansible"
chrony_client "$NTP_SRV"
pkg_install python3

step "rsyslog -> HQ-SRV"
rsyslog_client "$HQ_SRV"

# ============================== МОДУЛЬ 3 =====================================
step "Шифрование туннеля: IPsec (strongSwan, IKEv2) поверх GRE"
# Выбор: strongSwan есть в репозитории ALT p10, работает в ядре (XFRM),
# в транспортном режиме шифрует только GRE между внешними адресами роутеров.
# Туннель tun0 и OSPF не меняются; для OSPF добавлен mtu-ignore, MTU tun0 = 1400.
pkg_install strongswan
if [ -d /etc/strongswan ]; then IPSEC_DIR=/etc/strongswan; else IPSEC_DIR=/etc; fi
backup "$IPSEC_DIR/ipsec.conf"
cat > "$IPSEC_DIR/ipsec.conf" <<EOF
config setup
    charondebug="ike 1, knl 1"

conn %default
    keyexchange=ikev2
    ike=aes256-sha256-modp2048!
    esp=aes256-sha256!
    keyingtries=%forever
    dpdaction=restart
    dpddelay=30s

conn gre-protect
    type=transport
    authby=secret
    left=$TUN_LOCAL
    right=$TUN_REMOTE
    leftprotoport=gre
    rightprotoport=gre
    auto=start
EOF
printf '%s %s : PSK "%s"\n' "$TUN_LOCAL" "$TUN_REMOTE" "$IPSEC_PSK" > "$IPSEC_DIR/ipsec.secrets"
chmod 600 "$IPSEC_DIR/ipsec.secrets"
ok "Конфигурация: $IPSEC_DIR/ipsec.conf, ключ в ipsec.secrets"
ip link set tun0 mtu 1400
echo "mtu 1400" > /etc/net/ifaces/tun0/iplink
enable_first ipsec strongswan-starter strongswan
systemctl restart "$ENABLED_SVC" || die "Служба $ENABLED_SVC не перезапустилась"
IPSEC_UP=0
for i in $(seq 1 20); do
  if ipsec statusall 2>/dev/null | grep -q ESTABLISHED || ip xfrm state 2>/dev/null | grep -q 'proto esp'; then IPSEC_UP=1; break; fi
  sleep 2
done
if [ "$IPSEC_UP" = 1 ]; then ok "IPsec SA установлена (ip xfrm state)"
else warn "IPsec пока не поднят — второй роутер ещё не настроен? Проверка: ipsec statusall"; fi
systemctl restart frr
sleep 8
vtysh -c "show ip ospf neighbor" | grep -q Full && ok "OSPF восстановил соседство через зашифрованный туннель" \
  || warn "Соседа OSPF пока нет — проверьте после настройки второго роутера"

step "Межсетевой экран на интерфейсе $IF_WAN (в сторону ISP)"
# Из офиса наружу разрешено всё (http, https, dns, ntp, icmp работают).
# Из Интернета внутрь — только ответы, ICMP, опубликованные DNAT-порты,
# а на сам роутер — GRE/IPsec от второго роутера.
for ch in WAN_IN WAN_FWD; do iptables -N "$ch" 2>/dev/null || iptables -F "$ch"; done
iptables -D INPUT   -i "$IF_WAN" -j WAN_IN  2>/dev/null || true
iptables -D FORWARD -i "$IF_WAN" -j WAN_FWD 2>/dev/null || true
iptables -I INPUT   1 -i "$IF_WAN" -j WAN_IN
iptables -I FORWARD 1 -i "$IF_WAN" -j WAN_FWD
iptables -A WAN_IN -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -A WAN_IN -p icmp -j ACCEPT
iptables -A WAN_IN -s "$TUN_REMOTE" -p gre -j ACCEPT
iptables -A WAN_IN -s "$TUN_REMOTE" -p esp -j ACCEPT
iptables -A WAN_IN -s "$TUN_REMOTE" -p udp -m multiport --dports 500,4500 -j ACCEPT
iptables -A WAN_IN -j DROP
iptables -A WAN_FWD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -A WAN_FWD -m conntrack --ctstate DNAT -j ACCEPT      # 8080 и 2027 (статический проброс)
iptables -A WAN_FWD -p icmp -j ACCEPT
iptables -A WAN_FWD -j DROP
iptables-save > /etc/sysconfig/iptables || die "Не удалось сохранить правила"
iptables -S WAN_IN | grep -q DROP && iptables -S WAN_FWD | grep -q DROP && ok "Межсетевой экран применён и сохранён" || die "Правила МЭ не применились"
ping -c1 -W2 77.88.8.8 >/dev/null 2>&1 && ok "Выход в Интернет после МЭ работает" || warn "Нет ответа от 77.88.8.8 после применения МЭ"

# ============================== ИТОГ =========================================
step "Итоговая проверка"
ip -br -4 addr
sleep 10
vtysh -c "show ip ospf neighbor" || true
ip route | grep -q '192.168.100.0/27' && ok "Маршрут в сеть HQ получен по OSPF" || warn "Маршрутов HQ пока нет — проверьте hq-rtr и 'show ip ospf neighbor'"
echo -e "${C_G}BR-RTR настроен. Лог: $LOG_FILE${C_N}"
