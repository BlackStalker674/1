#!/bin/bash
# ===== Модуль 1 — HQ-SRV =====
# hostname, часовой пояс, remote_user (UID 2026) + SSH:2026 с баннером, DNS-сервер (dnsmasq)
# Предварительно: адрес 192.168.100.2/27, шлюз 192.168.100.1, nameserver 77.88.8.8
# Источник: HQ-SRV.sh, dnsmasq.conf

hostnamectl set-hostname hq-srv.au-team.irpo
apt-get update && apt-get install -y chrony tzdata dnsmasq
timedatectl set-timezone Asia/Krasnoyarsk
systemctl enable --now chronyd

# --- Учётные записи (задание 1.3) -------------------------------------------
# remote_user — просто локальная учётная запись
# sshuser    — UID 2026, пароль P@ssw0rd, sudo без пароля, единственный,
#              кому разрешён вход по SSH (см. п.1.5)
id -u remote_user >/dev/null 2>&1 || useradd -m remote_user
echo "remote_user:P@ssw0rd" | chpasswd

id -u sshuser >/dev/null 2>&1 || useradd -u 2026 -m sshuser
echo "sshuser:P@ssw0rd" | chpasswd
gpasswd -a sshuser wheel 2>/dev/null || true
grep -q '^sshuser ' /etc/sudoers || echo "sshuser ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers

# --- SSH
sed -i 's/^#*Port .*/Port 2026/' /etc/openssh/sshd_config
sed -i 's/^#*PermitRootLogin.*/PermitRootLogin no/' /etc/openssh/sshd_config
sed -i 's/^#*MaxAuthTries.*/MaxAuthTries 2/' /etc/openssh/sshd_config
# вход разрешён ИСКЛЮЧИТЕЛЬНО пользователю sshuser
sed -i 's/^AllowUsers.*/AllowUsers sshuser/' /etc/openssh/sshd_config
grep -q '^AllowUsers' /etc/openssh/sshd_config || echo "AllowUsers sshuser" >> /etc/openssh/sshd_config
grep -q '^Banner' /etc/openssh/sshd_config || echo "Banner /etc/openssh/banner" >> /etc/openssh/sshd_config
echo "Authorized access only" > /etc/openssh/banner
systemctl enable --now sshd
systemctl restart sshd

# --- DNS-сервер (dnsmasq)
cat > /etc/dnsmasq.conf <<'EOF'
domain-needed
bogus-priv
no-resolv
domain=au-team.irpo
server=77.88.8.8
listen-address=127.0.0.1,192.168.100.2
interface=*
expand-hosts
localise-queries

address=/hq-rtr.au-team.irpo/192.168.100.1
ptr-record=1.100.168.192.in-addr.arpa,hq-rtr.au-team.irpo
cname=moodle.au-team.irpo,hq-rtr.au-team.irpo
cname=wiki.au-team.irpo,hq-rtr.au-team.irpo

address=/br-rtr.au-team.irpo/192.168.0.1
ptr-record=1.0.168.192.in-addr.arpa,br-rtr.au-team.irpo

address=/hq-srv.au-team.irpo/192.168.100.2
ptr-record=2.100.168.192.in-addr.arpa,hq-srv.au-team.irpo

address=/br-srv.au-team.irpo/192.168.0.2
ptr-record=2.0.168.192.in-addr.arpa,br-srv.au-team.irpo

address=/hq-cli.au-team.irpo/192.168.200.2
ptr-record=2.200.168.192.in-addr.arpa,hq-cli.au-team.irpo

# ISP интерфейсы (Таблица 3)
address=/isp-hq.au-team.irpo/172.16.1.1
ptr-record=1.1.16.172.in-addr.arpa,isp-hq.au-team.irpo
address=/isp-br.au-team.irpo/172.16.2.1
ptr-record=1.2.16.172.in-addr.arpa,isp-br.au-team.irpo

# Обратный прокси (Tаблица 3) — резолвятся на ISP, который отдаёт прокси
address=/web.au-team.irpo/172.16.1.1
address=/docker.au-team.irpo/172.16.1.1

conf-dir=/etc/dnsmasq.d
EOF
mkdir -p /etc/dnsmasq.d
systemctl enable --now dnsmasq
systemctl restart dnsmasq

# --- resolv.conf на себя
chattr -i /etc/resolv.conf 2>/dev/null
cat > /etc/resolv.conf <<EOF
search au-team.irpo
nameserver 127.0.0.1
EOF
chattr +i /etc/resolv.conf

# --- Firewall (порт 53 для dnsmasq, 2026 для SSH)
apt-get install -y iptables
iptables -A INPUT -p udp --dport 53 -j ACCEPT
iptables -A INPUT -p tcp --dport 53 -j ACCEPT
iptables -A INPUT -p tcp --dport 2026 -j ACCEPT
iptables -A INPUT -i lo -j ACCEPT
iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
mkdir -p /etc/sysconfig
iptables-save > /etc/sysconfig/iptables
systemctl enable --now iptables

# --- Мониторинг CPU / RAM / диск (задание 5)
cat > /usr/local/bin/monitor.sh <<'EOF'
#!/bin/bash
LOG=/var/log/monitor.log
CPU=$(top -bn1 | grep "Cpu(s)" | awk '{print 100 - $8}')
RAM=$(free -m | awk '/Mem:/ {printf "%.0f%%", $3/$2*100}')
DISK=$(df -h / | awk 'NR==2 {print $5}')
echo "$(date '+%F %T') CPU=${CPU} RAM=${RAM} DISK=${DISK}" >> "$LOG"
EOF
chmod +x /usr/local/bin/monitor.sh
echo "*/5 * * * * root /usr/local/bin/monitor.sh" > /etc/cron.d/monitor

# --- Проверка
ping -c 2 hq-rtr.au-team.irpo
ping -c 2 ya.ru

echo "HQ-SRV: модуль 1 завершён"
