#!/bin/bash
# HQ-CLI, модуль 1: адрес приходит по DHCP от HQ-RTR (VLAN 200)
TZ="Asia/Krasnoyarsk"   # поставьте часовой пояс места проведения экзамена

hostnamectl set-hostname hq-cli.au-team.irpo
apt-get update && apt-get install -y tzdata
timedatectl set-timezone "$TZ"

# Проверка: адрес из 192.168.200.0/28, шлюз 192.168.200.1, DNS 192.168.100.2, суффикс au-team.irpo
ip a
ip r
cat /etc/resolv.conf
