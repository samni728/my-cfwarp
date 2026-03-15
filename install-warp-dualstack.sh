#!/usr/bin/env bash

set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  echo "请用 root 执行"
  exit 1
fi

apt-get update >/dev/null
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
  wireguard-tools \
  openresolv \
  dnsutils \
  iptables >/dev/null

mkdir -p /etc/wireguard

python3 <<'PY'
import base64
import datetime
import json
import os
import subprocess
import urllib.request


def run(cmd: str) -> str:
    return subprocess.check_output(cmd, shell=True, text=True).strip()


def ensure_parent(path: str) -> None:
    os.makedirs(os.path.dirname(path), exist_ok=True)


def main() -> None:
    priv = run("wg genkey")
    pub = subprocess.check_output(
        ["bash", "-lc", f"printf '%s' '{priv}' | wg pubkey"], text=True
    ).strip()
    install_id = run("tr -dc 'A-Za-z0-9' </dev/urandom | head -c 22")
    fcm_suffix = run("tr -dc 'A-Za-z0-9' </dev/urandom | head -c 134")
    fcm_token = f"{install_id}:APA91b{fcm_suffix}"

    payload = {
        "key": pub,
        "install_id": install_id,
        "fcm_token": fcm_token,
        "tos": datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%S.000Z"),
        "model": "PC",
        "serial_number": install_id,
        "locale": "zh_CN",
    }

    req = urllib.request.Request(
        "https://api.cloudflareclient.com/v0a2158/reg",
        data=json.dumps(payload).encode(),
        headers={
            "User-Agent": "okhttp/3.12.1",
            "CF-Client-Version": "a-6.10-2158",
            "Content-Type": "application/json",
        },
        method="POST",
    )

    with urllib.request.urlopen(req, timeout=20) as resp:
        account = json.load(resp)

    account["private_key"] = priv
    client_id = account["config"]["client_id"]
    reserved = list(base64.b64decode(client_id))[:3]
    account["config"]["reserved"] = reserved

    ensure_parent("/etc/wireguard/warp-account.conf")
    with open("/etc/wireguard/warp-account.conf", "w", encoding="utf-8") as f:
        json.dump(account, f, indent=2)

    v6 = account["config"]["interface"]["addresses"]["v6"]
    endpoint_v4 = account["config"]["peers"][0]["endpoint"]["v4"]
    endpoint_host = endpoint_v4.split(":")[0]
    peer_key = account["config"]["peers"][0]["public_key"]

    warp_conf = f"""[Interface]
PrivateKey = {priv}
Address = 172.16.0.2/32
Address = {v6}/128
DNS = 1.1.1.1
MTU = 1280
#Reserved = [{reserved[0]}, {reserved[1]}, {reserved[2]}]
#Table = off
#PostUp = /etc/wireguard/NonGlobalUp.sh
#PostDown = /etc/wireguard/NonGlobalDown.sh

[Peer]
PublicKey = {peer_key}
AllowedIPs = 0.0.0.0/0
AllowedIPs = ::/0
Endpoint = {endpoint_host}:2408
"""

    with open("/etc/wireguard/warp.conf", "w", encoding="utf-8") as f:
        f.write(warp_conf)
    os.chmod("/etc/wireguard/warp.conf", 0o600)

    non_global_up = """sleep 5
ip -4 rule add from 172.16.0.2 lookup 51820
ip -4 rule add table main suppress_prefixlength 0
ip -4 route add default dev warp table 51820
ip -6 rule add oif warp lookup 51820
ip -6 rule add table main suppress_prefixlength 0
ip -6 route add default dev warp table 51820
"""

    non_global_down = """ip -4 rule delete from 172.16.0.2 lookup 51820 || true
ip -4 rule delete table main suppress_prefixlength 0 || true
ip -4 route delete default dev warp table 51820 || true
ip -6 rule delete oif warp lookup 51820 || true
ip -6 rule delete table main suppress_prefixlength 0 || true
ip -6 route delete default dev warp table 51820 || true
"""

    with open("/etc/wireguard/NonGlobalUp.sh", "w", encoding="utf-8") as f:
        f.write(non_global_up)
    os.chmod("/etc/wireguard/NonGlobalUp.sh", 0o755)

    with open("/etc/wireguard/NonGlobalDown.sh", "w", encoding="utf-8") as f:
        f.write(non_global_down)
    os.chmod("/etc/wireguard/NonGlobalDown.sh", 0o755)


if __name__ == "__main__":
    main()
PY

printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' > /etc/resolv.conf

systemctl enable --now wg-quick@warp >/dev/null

echo
echo "WARP 双栈安装完成"
echo
echo "检查服务:"
echo "systemctl status wg-quick@warp"
echo
echo "检查握手:"
echo "wg show warp"
echo
echo "检查出口:"
echo "curl https://www.cloudflare.com/cdn-cgi/trace"
