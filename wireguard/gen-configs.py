# -*- coding: utf-8 -*-
"""Генерирует конфиги WireGuard-хаба: сервер (VPS), ПК (split), телефон (full tunnel).

Ключи создаются локально и никуда не отправляются. Скрипт отказывается
перезаписывать существующие конфиги, чтобы случайно не сломать рабочие пиры.

    python gen-configs.py --vps 1.2.3.4 --port 51821 --out out
    python gen-configs.py --vps 1.2.3.4 --force      # перегенерировать (пиры придётся переимпортировать)

Нужны wg.exe (WireGuard for Windows) и пакет qrcode (pip install qrcode pillow).
"""
import argparse
import os
import subprocess
import sys

WG_EXE = r"C:\Program Files\WireGuard\wg.exe"


def genkey():
    priv = subprocess.run([WG_EXE, "genkey"], capture_output=True, text=True, check=True).stdout.strip()
    pub = subprocess.run([WG_EXE, "pubkey"], input=priv, capture_output=True, text=True, check=True).stdout.strip()
    return priv, pub


def build(vps, port, subnet, out):
    if not os.path.exists(WG_EXE):
        sys.exit(f"Не найден {WG_EXE} — установите WireGuard for Windows")

    os.makedirs(out, exist_ok=True)
    targets = ["wg0.conf", "wg-pc.conf", "wg-phone.conf", "wg-phone-qr.png"]
    existing = [t for t in targets if os.path.exists(os.path.join(out, t))]
    if existing and "--force" not in sys.argv:
        sys.exit("Конфиги уже есть: " + ", ".join(existing) + "\nПерегенерация сломает текущих пиров. Добавьте --force, если это осознанно.")

    server_priv, server_pub = genkey()
    pc_priv, pc_pub = genkey()
    phone_priv, phone_pub = genkey()

    server = f"""[Interface]
Address = {subnet}.1/24
ListenPort = {port}
PrivateKey = {server_priv}
MTU = 1420

PostUp = iptables -A FORWARD -i %i -j ACCEPT; iptables -A FORWARD -o %i -j ACCEPT; iptables -A FORWARD -i %i -o %i -j ACCEPT; iptables -t nat -A POSTROUTING -s {subnet}.0/24 ! -d {subnet}.0/24 -j MASQUERADE
PostDown = iptables -D FORWARD -i %i -j ACCEPT; iptables -D FORWARD -o %i -j ACCEPT; iptables -D FORWARD -i %i -o %i -j ACCEPT; iptables -t nat -D POSTROUTING -s {subnet}.0/24 ! -d {subnet}.0/24 -j MASQUERADE

[Peer]
# phone (Claude + ADB)
PublicKey = {phone_pub}
AllowedIPs = {subnet}.2/32

[Peer]
# pc (ADB/RDP к телефону, только подсеть)
PublicKey = {pc_pub}
AllowedIPs = {subnet}.3/32
"""

    pc = f"""[Interface]
PrivateKey = {pc_priv}
Address = {subnet}.3/24
MTU = 1420

[Peer]
PublicKey = {server_pub}
Endpoint = {vps}:{port}
AllowedIPs = {subnet}.0/24
PersistentKeepalive = 25
"""

    phone = f"""[Interface]
PrivateKey = {phone_priv}
Address = {subnet}.2/24
DNS = 1.1.1.1
MTU = 1380

[Peer]
PublicKey = {server_pub}
Endpoint = {vps}:{port}
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
"""

    with open(os.path.join(out, "wg0.conf"), "w", newline="\n", encoding="utf-8") as fh:
        fh.write(server)
    with open(os.path.join(out, "wg-pc.conf"), "w", newline="", encoding="utf-8") as fh:
        fh.write(pc.replace("\n", "\r\n"))
    with open(os.path.join(out, "wg-phone.conf"), "w", newline="\n", encoding="utf-8") as fh:
        fh.write(phone)

    try:
        import qrcode

        qr = qrcode.QRCode(error_correction=qrcode.constants.ERROR_CORRECT_M, border=4, box_size=12)
        qr.add_data(phone)
        qr.make(fit=True)
        qr.make_image(fill_color="black", back_color="white").save(os.path.join(out, "wg-phone-qr.png"))
    except ImportError:
        print("qrcode не установлен — QR не создан (pip install qrcode pillow)")

    print(f"Готово: {os.path.abspath(out)}")
    print("  wg0.conf        — на VPS в /etc/wireguard/")
    print("  wg-pc.conf      — импортировать в WireGuard на ПК (split, только подсеть)")
    print("  wg-phone.conf   — импортировать в WireGuard на телефоне (full tunnel)")
    print("  wg-phone-qr.png — то же в виде QR")
    print()
    print("public keys (для сверки):")
    print("  server:", server_pub)
    print("  pc    :", pc_pub)
    print("  phone :", phone_pub)


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--vps", required=True, help="IP или домен VPS")
    ap.add_argument("--port", default=51821, type=int, help="UDP-порт (по умолчанию 51821)")
    ap.add_argument("--subnet", default="10.66.66", help="подсеть без последнего октета (10.66.66)")
    ap.add_argument("--out", default="out", help="куда писать конфиги")
    ap.add_argument("--force", action="store_true", help="перезаписать существующие конфиги")
    args = ap.parse_args()
    build(args.vps, args.port, args.subnet, args.out)
