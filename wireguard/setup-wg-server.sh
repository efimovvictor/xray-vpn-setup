#!/bin/bash
# Устанавливает WireGuard-хаб на VPS из готового wg0.conf (лежит рядом со скриптом).
# Запуск от root:  bash setup-wg-server.sh
# Конфиг генерируется локально:  python gen-configs.py --vps <IP>
set -euo pipefail

CONF="${1:-/root/wg0.conf}"
TARGET="/etc/wireguard/wg0.conf"

if [[ $EUID -ne 0 ]]; then
  echo "Нужен root" >&2
  exit 1
fi
if [[ ! -f "$CONF" ]]; then
  echo "Не найден $CONF" >&2
  exit 1
fi

echo "== установка wireguard =="
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq wireguard iptables >/dev/null

echo "== ip forwarding =="
printf 'net.ipv4.ip_forward=1\n' >/etc/sysctl.d/99-wg-forward.conf
sysctl --system >/dev/null

echo "== конфиг =="
umask 077
install -m 600 "$CONF" "$TARGET"

echo "== порт в ufw =="
PORT="$(grep -E '^ListenPort' "$TARGET" | awk '{print $3}')"
if command -v ufw >/dev/null && ufw status | grep -q "Status: active"; then
  ufw allow "${PORT:-51821}/udp" >/dev/null
  echo "ufw: разрешён ${PORT:-51821}/udp"
else
  echo "ufw не активен — проверьте файрвол провайдера (UDP ${PORT:-51821})"
fi

echo "== запуск =="
systemctl enable wg-quick@wg0 >/dev/null 2>&1 || true
systemctl restart wg-quick@wg0
sleep 2

echo "== состояние =="
wg show
ip -4 addr show wg0 | grep inet || true
