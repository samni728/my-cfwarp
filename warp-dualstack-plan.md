# Ubuntu VPS 上通过 Cloudflare WARP 实现双栈出口方案

## 目标

在一台 Ubuntu VPS 上：

- 保留原本网络接口
- 增加一个 WireGuard 形式的 Cloudflare WARP 接口
- 让主机同时具备 WARP IPv4 与 WARP IPv6 出口能力
- 最终通过 `curl https://www.cloudflare.com/cdn-cgi/trace` 看到 `warp=on`

## 这次环境里的真实问题

这次 VPS 不是单纯“WARP 没启动”，而是同时存在以下问题：

1. 旧的 WARP 安装残留不完整
- `warp` 命令还在
- `wg-quick@warp.service` 还在
- 但 `/etc/wireguard/warp.conf` 已经不存在

2. 原脚本重装流程在当前环境触发了内部 bug
- 执行 `warp d` 时，脚本在生成并修改 `warp.conf` 阶段中止
- 这会导致“看起来开始安装了，但配置没有完整落盘”

3. `engage.cloudflareclient.com` 在当前 VPS 环境里被错误解析
- 本地 DNS 把这个域名解析成了 `192.168.110.252`
- 这是内网网关地址，不是 Cloudflare WARP 真实端点
- 结果会出现“隧道像是起来了，但流量不正常”

## 最终采用的实现思路

不继续依赖 `warp-sh` 脚本完成整条安装链路，而是拆成稳定的 6 步：

1. 卸载旧 WARP 残留
- 停掉 `wg-quick@warp`
- 删除旧的 `/etc/wireguard/warp.conf`
- 删除旧账户信息和失效残留

2. 安装最小依赖
- `wireguard-tools`
- `openresolv`
- `dnsutils`
- `iptables`

3. 直接调用 Cloudflare 注册接口生成新设备
- 生成本地 X25519 密钥对
- 调用 `https://api.cloudflareclient.com/v0a2158/reg`
- 拿到新的 WARP 设备配置

4. 生成本地配置文件
- `/etc/wireguard/warp-account.conf`
- `/etc/wireguard/warp.conf`

5. 强制写入真实 Cloudflare IPv4 端点
- 不再使用 `engage.cloudflareclient.com:2408`
- 改用注册响应中的真实 `endpoint.v4`
- 例如这次实际拿到的是 `162.159.192.6:2408`

6. 启动并验证
- `systemctl enable --now wg-quick@warp`
- `wg show warp`
- `curl https://www.cloudflare.com/cdn-cgi/trace`

## 关键配置结构

`/etc/wireguard/warp.conf` 的核心形态如下：

```ini
[Interface]
PrivateKey = <private-key>
Address = 172.16.0.2/32
Address = <warp-ipv6>/128
DNS = 1.1.1.1
MTU = 1280

[Peer]
PublicKey = bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=
AllowedIPs = 0.0.0.0/0
AllowedIPs = ::/0
Endpoint = <cloudflare-endpoint-v4>:2408
```

这份配置的关键点：

- `Address = 172.16.0.2/32`
  Cloudflare WARP 虚拟 IPv4

- `Address = <warp-ipv6>/128`
  Cloudflare WARP 分配的 IPv6

- `AllowedIPs = 0.0.0.0/0` 和 `AllowedIPs = ::/0`
  表示双栈流量都走 WARP

- `Endpoint` 使用真实 IPv4 地址而不是域名
  避免本机 DNS 把域名错误解析到内网设备

## 验证方式

### 1. 看服务状态

```bash
systemctl status wg-quick@warp
```

### 2. 看 WireGuard 握手

```bash
wg show warp
```

关键看点：

- `latest handshake` 有时间
- `transfer` 有收发字节

### 3. 看 Cloudflare trace

```bash
curl https://www.cloudflare.com/cdn-cgi/trace
```

关键字段：

- `warp=on`
- `loc=US` 或其它地区

## 适用条件

这个方案适合：

- Ubuntu VPS
- 能访问 Cloudflare 注册接口
- 已开启 TUN
- 需要 WARP 双栈出口

## 不稳定点

1. DNS 环境
- 某些 VPS 会把 `engage.cloudflareclient.com` 解析到错误地址
- 所以建议直接使用注册结果里的 `endpoint.v4`

2. 第三方脚本行为变化
- `warp-sh` 版本更新后逻辑可能变化
- 但本文方案核心依赖的是 Cloudflare 注册接口和标准 WireGuard 配置，稳定性更高

3. 本地 DNS 被系统服务重写
- 如果你的系统后续重写 `/etc/resolv.conf`
- 可能需要额外处理 `systemd-resolved` 或 netplan

## 推荐执行顺序

1. 先执行清理
2. 再执行安装脚本
3. 验证 `wg show warp`
4. 验证 `curl https://www.cloudflare.com/cdn-cgi/trace`
5. 最后根据需要再决定是否切换到非全局模式



curl -fsSL https://tmp.123go.eu.org:8443/warp-menu.sh -o warp-menu.sh && chmod +x warp-menu.sh && bash warp-menu.sh

bash <(curl -fsSL https://tmp.123go.eu.org:8443/warp-menu.sh)

apt-get update && apt-get install -y curl




