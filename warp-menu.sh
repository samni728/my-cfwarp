#!/usr/bin/env bash

set -euo pipefail

SCRIPT_VERSION="2026.03.15.3"

WARP_DIR="/etc/wireguard"
WARP_CONF="$WARP_DIR/warp.conf"
WARP_ACCOUNT="$WARP_DIR/warp-account.conf"
GAI_CONF="/etc/gai.conf"
DANTED_CONF="/etc/danted.conf"
TINYPROXY_CONF="/etc/tinyproxy/tinyproxy.conf"
RESOLV_CONF="/etc/resolv.conf"
SAFETY_DIR="/var/lib/warp-menu-safety"
ROLLBACK_SCRIPT="$SAFETY_DIR/rollback.sh"
ROLLBACK_DELAY_SECONDS="${ROLLBACK_DELAY_SECONDS:-120}"
STATIC_DNS_SERVERS="${STATIC_DNS_SERVERS:-1.1.1.1 8.8.8.8 223.5.5.5}"
SOCKS_USER_DEFAULT="warp_proxy"
SOCKS_PORT_DEFAULT="1080"
HTTP_PORT_DEFAULT="8888"

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "请用 root 执行"
    exit 1
  fi
}

pause() {
  echo
  read -r -p "按回车继续..." _
}

info() {
  echo
  echo "$1"
  echo
}

write_static_resolv_conf() {
  rm -f "$RESOLV_CONF"
  : > "$RESOLV_CONF"
  for dns in $STATIC_DNS_SERVERS; do
    echo "nameserver ${dns}" >> "$RESOLV_CONF"
  done
}

has_pending_rollback() {
  systemctl list-units --all 'warp-menu-rollback.timer' 'warp-menu-rollback.service' 2>/dev/null | grep -q 'warp-menu-rollback'
}

cancel_pending_rollback() {
  systemctl stop warp-menu-rollback.timer warp-menu-rollback.service >/dev/null 2>&1 || true
  systemctl reset-failed warp-menu-rollback.service >/dev/null 2>&1 || true
}

prepare_safe_rollback() {
  require_root
  cancel_pending_rollback
  rm -rf "$SAFETY_DIR"
  mkdir -p "$SAFETY_DIR"

  if [[ -f "$WARP_CONF" ]]; then cp -a "$WARP_CONF" "$SAFETY_DIR/warp.conf.bak"; fi
  if [[ -f "$WARP_ACCOUNT" ]]; then cp -a "$WARP_ACCOUNT" "$SAFETY_DIR/warp-account.conf.bak"; fi
  if [[ -f "$GAI_CONF" ]]; then cp -a "$GAI_CONF" "$SAFETY_DIR/gai.conf.bak"; fi
  if [[ -L "$RESOLV_CONF" ]]; then
    printf 'symlink:%s\n' "$(readlink "$RESOLV_CONF")" > "$SAFETY_DIR/resolv.mode"
  elif [[ -f "$RESOLV_CONF" ]]; then
    cp -a "$RESOLV_CONF" "$SAFETY_DIR/resolv.conf.bak"
  fi

  cat > "$ROLLBACK_SCRIPT" <<EOF
#!/usr/bin/env bash
set -euo pipefail
systemctl disable --now wg-quick@warp >/dev/null 2>&1 || true
systemctl stop danted tinyproxy >/dev/null 2>&1 || true
if [[ -f "$SAFETY_DIR/warp.conf.bak" ]]; then cp -af "$SAFETY_DIR/warp.conf.bak" "$WARP_CONF"; else rm -f "$WARP_CONF"; fi
if [[ -f "$SAFETY_DIR/warp-account.conf.bak" ]]; then cp -af "$SAFETY_DIR/warp-account.conf.bak" "$WARP_ACCOUNT"; else rm -f "$WARP_ACCOUNT"; fi
if [[ -f "$SAFETY_DIR/gai.conf.bak" ]]; then cp -af "$SAFETY_DIR/gai.conf.bak" "$GAI_CONF"; else sed -i '/^precedence ::ffff:0:0\\/96  100$/d' "$GAI_CONF" 2>/dev/null || true; fi
if [[ -f "$SAFETY_DIR/resolv.conf.bak" ]]; then cp -af "$SAFETY_DIR/resolv.conf.bak" "$RESOLV_CONF"; fi
if [[ -f "$SAFETY_DIR/resolv.mode" ]]; then
  target=\$(sed 's/^symlink://' "$SAFETY_DIR/resolv.mode")
  rm -f "$RESOLV_CONF"
  ln -s "\$target" "$RESOLV_CONF"
fi
ip link delete warp >/dev/null 2>&1 || true
systemctl daemon-reload >/dev/null 2>&1 || true
EOF
  chmod +x "$ROLLBACK_SCRIPT"

  systemd-run --unit warp-menu-rollback --on-active="${ROLLBACK_DELAY_SECONDS}" /bin/bash "$ROLLBACK_SCRIPT" >/dev/null
}

show_pending_rollback_notice() {
  info "已启用安全回滚。请在 ${ROLLBACK_DELAY_SECONDS} 秒内验证 SSH 和网络是否正常。确认没问题后，回到菜单执行“确认保留当前变更”；否则会自动回滚。"
}

confirm_keep_changes() {
  require_root
  cancel_pending_rollback
  rm -rf "$SAFETY_DIR"
  info "已确认保留当前变更，自动回滚已取消"
}

rollback_now() {
  require_root
  if [[ -x "$ROLLBACK_SCRIPT" ]]; then
    cancel_pending_rollback
    bash "$ROLLBACK_SCRIPT"
    rm -rf "$SAFETY_DIR"
    info "已立即执行回滚"
  else
    info "当前没有可回滚的待确认变更"
  fi
}

validate_warp_or_rollback() {
  local ok=0
  local attempt

  for attempt in 1 2 3 4 5; do
    if wg show warp >/tmp/warp-menu-wg.txt 2>/dev/null; then
      if grep -q 'latest handshake' /tmp/warp-menu-wg.txt; then
        if getent hosts www.cloudflare.com >/tmp/warp-menu-dns.txt 2>/dev/null; then
          if curl -sS --max-time 12 https://www.cloudflare.com/cdn-cgi/trace >/tmp/warp-menu-trace.txt 2>/dev/null; then
            if grep -q 'warp=on' /tmp/warp-menu-trace.txt; then
              ok=1
              break
            fi
          fi
        fi
      fi
    fi
    sleep 3
  done

  if [[ "$ok" -ne 1 ]]; then
    echo
    echo "WARP 启动后的连通性验证失败，立即回滚。"
    echo "--- wg show ---"
    cat /tmp/warp-menu-wg.txt 2>/dev/null || true
    echo "--- dns ---"
    cat /tmp/warp-menu-dns.txt 2>/dev/null || true
    echo "--- trace ---"
    cat /tmp/warp-menu-trace.txt 2>/dev/null || true
    rollback_now
    return 1
  fi

  rm -f /tmp/warp-menu-wg.txt /tmp/warp-menu-dns.txt /tmp/warp-menu-trace.txt
}

ensure_base_packages() {
  local resolver_pkg=""
  apt-get update >/dev/null
  if apt-cache policy openresolv 2>/dev/null | grep -q 'Candidate:' && ! apt-cache policy openresolv 2>/dev/null | grep -q 'Candidate: (none)'; then
    resolver_pkg="openresolv"
  elif apt-cache policy resolvconf 2>/dev/null | grep -q 'Candidate:' && ! apt-cache policy resolvconf 2>/dev/null | grep -q 'Candidate: (none)'; then
    resolver_pkg="resolvconf"
  fi
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    wireguard-tools \
    dnsutils \
    iptables \
    curl \
    ca-certificates \
    python3 \
    ${resolver_pkg:+$resolver_pkg} >/dev/null
}

cleanup_old_warp() {
  systemctl disable --now wg-quick@warp >/dev/null 2>&1 || true
  rm -f "$WARP_CONF" "$WARP_ACCOUNT"
}

install_warp_dualstack() {
  require_root
  prepare_safe_rollback
  ensure_base_packages
  cleanup_old_warp
  mkdir -p "$WARP_DIR"

  python3 <<'PY'
import base64
import datetime
import json
import os
import subprocess
import urllib.request

WARP_DIR = "/etc/wireguard"
WARP_ACCOUNT = f"{WARP_DIR}/warp-account.conf"
WARP_CONF = f"{WARP_DIR}/warp.conf"


def run(cmd: str) -> str:
    return subprocess.check_output(cmd, shell=True, text=True).strip()


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

    with open(WARP_ACCOUNT, "w", encoding="utf-8") as f:
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

    with open(WARP_CONF, "w", encoding="utf-8") as f:
        f.write(warp_conf)
    os.chmod(WARP_CONF, 0o600)

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

    for path, content in (
        (f"{WARP_DIR}/NonGlobalUp.sh", non_global_up),
        (f"{WARP_DIR}/NonGlobalDown.sh", non_global_down),
    ):
        with open(path, "w", encoding="utf-8") as f:
            f.write(content)
        os.chmod(path, 0o755)


if __name__ == "__main__":
    main()
PY

  write_static_resolv_conf
  systemctl enable --now wg-quick@warp >/dev/null
  validate_warp_or_rollback
  info "WARP 双栈安装完成"
  show_pending_rollback_notice
}

start_warp() {
  require_root
  prepare_safe_rollback
  write_static_resolv_conf
  systemctl enable --now wg-quick@warp
  validate_warp_or_rollback
  info "WARP 已启动"
  show_pending_rollback_notice
}

stop_warp() {
  require_root
  systemctl disable --now wg-quick@warp || true
  info "WARP 已停止"
}

restart_warp() {
  require_root
  systemctl restart wg-quick@warp
  info "WARP 已重启"
}

show_trace() {
  local flag="$1"
  timeout 12 curl "$flag" -sS https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null || true
}

show_status() {
  echo
  systemctl status wg-quick@warp --no-pager -l || true
  echo "---"
  wg show warp || true
  echo "---"
  echo "IPv4 Trace:"
  show_trace -4 | sed -n '1,20p'
  echo "---"
  echo "IPv6 Trace:"
  show_trace -6 | sed -n '1,20p'
  echo
}

set_priority_ipv4() {
  require_root
  cp -f "$GAI_CONF" "${GAI_CONF}.bak.$(date +%s)" 2>/dev/null || true
  grep -v '^precedence ::ffff:0:0/96  100$' "$GAI_CONF" 2>/dev/null > /tmp/gai.conf.new || true
  {
    cat /tmp/gai.conf.new 2>/dev/null || true
    echo 'precedence ::ffff:0:0/96  100'
  } > "$GAI_CONF"
  rm -f /tmp/gai.conf.new
  info "已设置为 IPv4 优先"
}

set_priority_default() {
  require_root
  if [[ -f "$GAI_CONF" ]]; then
    grep -v '^precedence ::ffff:0:0/96  100$' "$GAI_CONF" > /tmp/gai.conf.new || true
    mv /tmp/gai.conf.new "$GAI_CONF"
  fi
  info "已恢复系统默认优先级"
}

install_socks_proxy() {
  require_root
  local username password port
  read -r -p "SOCKS 用户名 [${SOCKS_USER_DEFAULT}]: " username
  username="${username:-$SOCKS_USER_DEFAULT}"
  read -r -s -p "SOCKS 密码: " password
  echo
  read -r -p "SOCKS 端口 [${SOCKS_PORT_DEFAULT}]: " port
  port="${port:-$SOCKS_PORT_DEFAULT}"

  apt-get update >/dev/null
  DEBIAN_FRONTEND=noninteractive apt-get install -y dante-server >/dev/null

  if id "$username" >/dev/null 2>&1; then
    echo "${username}:${password}" | chpasswd
  else
    useradd -r -M -s /usr/sbin/nologin "$username"
    echo "${username}:${password}" | chpasswd
  fi

  cat > "$DANTED_CONF" <<EOF
logoutput: syslog
user.privileged: root
user.notprivileged: nobody
internal: 0.0.0.0 port = ${port}
external: warp
clientmethod: none
socksmethod: username

client pass {
  from: 0.0.0.0/0 to: 0.0.0.0/0
  log: error connect disconnect
}

socks pass {
  from: 0.0.0.0/0 to: 0.0.0.0/0
  command: connect udpassociate
  log: error connect disconnect iooperation
  socksmethod: username
}

socks pass {
  from: 0.0.0.0/0 to: 0.0.0.0/0
  command: bindreply udpreply
  log: error connect disconnect iooperation
}
EOF

  systemctl enable --now danted
  info "SOCKS5 已启用，端口: ${port}，用户: ${username}"
}

disable_socks_proxy() {
  require_root
  systemctl disable --now danted || true
  info "SOCKS5 已关闭"
}

install_http_proxy() {
  require_root
  local username password port
  read -r -p "HTTP 用户名 [${SOCKS_USER_DEFAULT}]: " username
  username="${username:-$SOCKS_USER_DEFAULT}"
  read -r -s -p "HTTP 密码: " password
  echo
  read -r -p "HTTP 端口 [${HTTP_PORT_DEFAULT}]: " port
  port="${port:-$HTTP_PORT_DEFAULT}"

  apt-get update >/dev/null
  DEBIAN_FRONTEND=noninteractive apt-get install -y tinyproxy >/dev/null

  cat > "$TINYPROXY_CONF" <<EOF
User tinyproxy
Group tinyproxy
Port ${port}
Listen 0.0.0.0
Timeout 600
DefaultErrorFile "/usr/share/tinyproxy/default.html"
StatFile "/usr/share/tinyproxy/stats.html"
LogFile "/var/log/tinyproxy/tinyproxy.log"
LogLevel Info
PidFile "/run/tinyproxy/tinyproxy.pid"
MaxClients 100
StartServers 4
MinSpareServers 2
MaxSpareServers 8
BasicAuth ${username} ${password}
DisableViaHeader Yes
ConnectPort 443
ConnectPort 563
EOF

  systemctl enable --now tinyproxy
  info "HTTP Proxy 已启用，端口: ${port}，用户: ${username}"
}

disable_http_proxy() {
  require_root
  systemctl disable --now tinyproxy || true
  info "HTTP Proxy 已关闭"
}

show_proxy_status() {
  echo
  systemctl status danted --no-pager -l || true
  echo "---"
  systemctl status tinyproxy --no-pager -l || true
  echo "---"
  ss -lntp | egrep '(:1080|:8888|danted|tinyproxy)' || true
  echo
}

print_menu() {
  cat <<EOF

================ WARP 管理菜单 v${SCRIPT_VERSION} ================
1. 安装 / 重装 WARP 双栈
2. 启动 WARP
3. 停止 WARP
4. 重启 WARP
5. 查看当前状态 / CF IPv4 / IPv6
6. 设置 IPv4 优先
7. 恢复系统默认优先级
8. 启用 SOCKS5 代理
9. 关闭 SOCKS5 代理
10. 启用 HTTP Proxy
11. 关闭 HTTP Proxy
12. 查看代理状态
13. 确认保留当前变更
14. 立即回滚到变更前
0. 退出
=============================================

EOF
}

main() {
  require_root

  while true; do
    print_menu
    read -r -p "请选择: " choice
    case "$choice" in
      1) install_warp_dualstack; pause ;;
      2) start_warp; pause ;;
      3) stop_warp; pause ;;
      4) restart_warp; pause ;;
      5) show_status; pause ;;
      6) set_priority_ipv4; pause ;;
      7) set_priority_default; pause ;;
      8) install_socks_proxy; pause ;;
      9) disable_socks_proxy; pause ;;
      10) install_http_proxy; pause ;;
      11) disable_http_proxy; pause ;;
      12) show_proxy_status; pause ;;
      13) confirm_keep_changes; pause ;;
      14) rollback_now; pause ;;
      0) exit 0 ;;
      *) echo "无效选项"; pause ;;
    esac
  done
}

main "$@"
