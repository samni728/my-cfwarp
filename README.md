# my-cfwarp

一个面向 Ubuntu VPS 的 Cloudflare WARP 管理脚本集合。

当前仓库重点提供：

- `warp-menu.sh`
  一个交互式 Bash 菜单，负责安装、启动、停止、重启和检查 WARP
- `install-warp-dualstack.sh`
  一键安装 WARP 双栈的最小脚本
- `warp-dualstack-plan.md`
  这套方案的实现思路和排障说明

## 主要功能

- 安装 / 重装 Cloudflare WARP 双栈
- 启动 / 停止 / 重启 WARP
- 查看当前 Cloudflare IPv4 / IPv6 出口
- 切换 `IPv4 优先`
- 启用 / 关闭 `SOCKS5`
- 启用 / 关闭 `HTTP Proxy`
- 配置代理端口、用户名、密码
- 自动安全回滚

## 推荐脚本

优先使用：

```bash
bash warp-menu.sh
```

菜单版脚本包含：

- 安装 WARP
- 启动 / 停止
- 状态查看
- 代理管理
- 回滚确认

## 版本

当前菜单脚本版本号会直接显示在菜单标题里，例如：

```text
WARP 管理菜单 v2026.03.15.3
```

## 使用说明

### 1. 下载脚本

```bash
curl -fsSL <your-url>/warp-menu.sh -o warp-menu.sh
chmod +x warp-menu.sh
```

### 2. 运行

```bash
sudo bash warp-menu.sh
```

### 3. 验证

```bash
systemctl status wg-quick@warp
wg show warp
curl https://www.cloudflare.com/cdn-cgi/trace
```

当返回结果里出现：

```text
warp=on
```

说明 WARP 已经真正接管出口流量。

## 说明

- 本仓库不包含任何服务器密码、令牌或私有配置
- 建议只把通用脚本和文档纳入版本管理
- 生产环境使用前，先通过控制台或第二条 SSH 会话验证网络是否正常
