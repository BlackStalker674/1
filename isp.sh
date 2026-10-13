#!/bin/bash
# ===== Модуль 1 — ISP (пп. 1, 2, 8-часть, 11) =====
# Имя, часовой пояс, адреса: WAN по DHCP, 172.16.1.1/28 (к HQ-RTR), 172.16.2.1/28 (к BR-RTR),
# маршрут по умолчанию (от DHCP), форвардинг и NAT (PAT) наружу.
# ALT Linux (etcnet). Запускать от root НА КОНСОЛИ (сеть перезапускается).
set -eu

# ---------- Переменные (проверьте: ip -br link) ----------
WAN_IF=${WAN_IF:-enp7s1}              # к магистральному провайдеру (DHCP)
HQ_IF=${HQ_IF:-enp7s2}                # к HQ-RTR, сеть 172.16.1.0/28
BR_IF=${BR_IF:-enp7s3}                # к BR-RTR, сеть 172.16.2.0/28
TZ_NAME=${TZ_NAME:-Asia/Krasnoyarsk}  # часовой пояс по месту проведения экзамена
HOST_FQDN=isp.au-team.irpo

die() { echo "!!! $*" >&2; exit 1; }
[ "$(id -u)" -eq 0 ] || die "Запускайте от root"

need_if() {
    for i in "$@"; do
        ip link show "$i" >/dev/null 2>&1 || die "Нет интерфейса $i (смотрите ip -br link), задайте: WAN_IF=... HQ_IF=... BR_IF=... bash $0"
    done
}

mkiface() { # IF PROTO [ADDR/MASK]
    local IF=$1 PROTO=$2 ADDR=${3:-} D=/etc/net/ifaces/$1
    mkdir -p "$D"
    cat > "$D/options" <<EOF
TYPE=eth
BOOTPROTO=$PROTO
CONFIG_IPV4=yes
DISABLED=no
NM_CONTROLLED=no
SYSTEMD_CONTROLLED=no
EOF
    rm -f "$D/ipv4address" "$D/ipv4route"
    if [ -n "$ADDR" ]; then echo "$ADDR" > "$D/ipv4address"; fi
    return 0
}

need_if "$WAN_IF" "$HQ_IF" "$BR_IF"

echo ">>> Имя"
hostnamectl set-hostname "$HOST_FQDN"

echo ">>> Интерфейсы"
mkiface "$WAN_IF" dhcp                      # адрес и маршрут по умолчанию приходят по DHCP
mkiface "$HQ_IF"  static 172.16.1.1/28
mkiface "$BR_IF"  static 172.16.2.1/28

echo ">>> Форвардинг"
SYSCTL=/etc/net/sysctl.conf
touch "$SYSCTL"
if grep -qE '^\s*net\.ipv4\.ip_forward' "$SYSCTL"; then
    sed -i -E 's/^\s*net\.ipv4\.ip_forward.*/net.ipv4.ip_forward = 1/' "$SYSCTL"
else
    echo 'net.ipv4.ip_forward = 1' >> "$SYSCTL"
fi
sysctl -w net.ipv4.ip_forward=1 >/dev/null

systemctl restart network
sleep 5

echo ">>> Пакеты"
apt-get update
apt-get install -y iptables tzdata
timedatectl set-timezone "$TZ_NAME"

echo ">>> NAT (PAT) в сторону Интернета"
iptables -t nat -C POSTROUTING -o "$WAN_IF" -j MASQUERADE 2>/dev/null || \
    iptables -t nat -A POSTROUTING -o "$WAN_IF" -j MASQUERADE
mkdir -p /etc/sysconfig
iptables-save > /etc/sysconfig/iptables
systemctl enable --now iptables

echo ""
echo "===== Проверка ====="
ip -br addr
ip route | grep '^default' || echo "ВНИМАНИЕ: нет маршрута по умолчанию (WAN не получил адрес по DHCP?)"
ping -c 2 77.88.8.8 || echo "ВНИМАНИЕ: Интернет недоступен"
iptables -t nat -S POSTROUTING
echo "ISP: модуль 1 готов"
