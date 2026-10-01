# FastProxy

通过中文网页后台或 `fastproxy` 数字菜单管理 Linux 服务器端口转发。Node.js + TypeScript 后端、Vue 3 + Element Plus 前端，转发由 nftables 在内核完成。无需 Docker。

```text
客户端 ⇄ 当前服务器:8000 ⇄ 目标服务器:9000
```

支持 IPv4 TCP / UDP。DNAT 改写目标，SNAT/MASQUERADE 保证响应经过转发服务器；应用数据不变，目标通常看到转发服务器的 IP。目标填写 IPv4 地址，首版不支持域名、IPv6 或保留客户端源 IP。

## 功能

- 管理员登录，HttpOnly / SameSite 会话、CSRF 校验、登录失败限速。
- 添加、修改、删除、启停转发规则，保存即校验并生效，冲突或失败保留原配置。
- 网页与本机 root 控制台共用状态；并发修改用版本号防止互相覆盖。
- 查看真实内核流量计数、运行状态、配置预览，暂停 / 恢复全局转发。
- systemd 开机启动与故障重启，规则持久化，安装器自动准备私有 Node.js 运行环境。
- 仅操作 `ip fastproxy` 专属表，不执行 `flush ruleset`。

## 本地开发与预览

需要 Node.js 22.12+，推荐 Node.js 24 LTS。

```bash
npm ci
npm run dev
```

打开 Vite 输出的本地地址（通常为 `http://127.0.0.1:5173`）。演示账号：`admin` / `FastProxy-demo-2026`。演示模式可以管理规则和预览配置，**不会修改系统网络，也不会实际转发**。数据存放在 `apps/server/data`。

```bash
npm run typecheck
npm test
npm run build
```

构建后的前端在 `apps/server/public`，后端在 `apps/server/dist`。Linux 上设置生产环境变量后可以用 `npm start`；正式部署推荐以下安装器。

## 服务器安装

安装器支持 **Debian 12+ / Ubuntu 20.04+、amd64 / arm64、正在运行的 systemd**。需要 root、nftables、支持 NAT / conntrack 的 Linux 内核和服务器出网能力。安装器不会修改服务器原有 Node.js，而是安装校验过的私有 Node.js 24 运行时。Ubuntu 20.04 使用系统自带的 nftables 即可，无需升级系统或安装 Docker。

### 使用本地发布包

在 Linux / WSL 或 GitHub Actions 中构建发布包：

```bash
npm ci
bash scripts/package.sh
```

将 `dist/fastproxy-v0.1.1.tar.gz` 和 `scripts/install.sh` 上传到服务器，然后执行：

```bash
sudo bash install.sh --package ./fastproxy-v0.1.1.tar.gz
sudo fastproxy
```

安装器会显示首次生成的随机管理密码。默认后台绑定 `127.0.0.1:8080`；在你的电脑建立 SSH 隧道：

```bash
ssh -N -L 8080:127.0.0.1:8080 用户@服务器
```

随后在电脑浏览器打开 `http://127.0.0.1:8080`。如需直接监听公网：

```bash
sudo bash install.sh --package ./fastproxy-v0.1.1.tar.gz --listen 0.0.0.0:8080
```

公网管理后台请配置 HTTPS 反向代理或限制管理端口来源。安装器不会自动开放云安全组或修改 UFW / firewalld 的转发策略。

### curl 安装（推荐）

源码位于 [bunnya33/fastproxy](https://github.com/bunnya33/fastproxy)，安装器从 [GitHub Releases](https://github.com/bunnya33/fastproxy/releases) 下载构建好的网页、服务程序与校验文件。

```bash
curl -fsSL https://raw.githubusercontent.com/bunnya33/fastproxy/main/scripts/install.sh \
  | sudo bash
```

也可先下载脚本后执行。指定版本使用 `sudo bash install.sh --version v0.1.1`。重新执行安装器可更新程序，保留管理地址、密码、规则和审计记录。

## 数字菜单

```bash
sudo fastproxy
```

菜单提供服务器 / 内核状态、规则列表、添加 / 修改规则、启停 / 删除规则、修改管理地址 / 密码、启动 / 停止 / 重启服务、查看日志、暂停 / 恢复全部转发和重新应用规则。

也支持快捷命令：

```bash
sudo fastproxy status
sudo fastproxy list
sudo fastproxy restart
sudo fastproxy stop
sudo fastproxy start
sudo fastproxy logs
```

网页的“启用状态”与全局转发开关分开保存，暂停全部转发不会删除规则。启停和修改规则影响**新连接**；已存在的 conntrack 会话可能继续到超时。正常停止服务会移除专属表，再次启动恢复磁盘规则；异常退出后内核规则可能保留，systemd 会尝试恢复服务。

## 防火墙与端口

添加规则前确认本机端口未用于其他服务，并在云安全组放行对应协议的监听端口。默认保护 SSH 端口 22 和管理端口；安装器在 `SSH_CONNECTION` 可用时会记录当前 SSH 服务端口。使用自定义 SSH 端口时检查 `FASTPROXY_PROTECTED_PORTS`。

如果 UFW 开启，需要允许路由转发。例如本机 `8000/tcp` 转发到 `10.0.0.20:9000`：

```bash
sudo ufw route allow proto tcp to 10.0.0.20 port 9000
```

UDP 对应使用 `proto udp`。其他防火墙也应放行 FORWARD 流量，**FastProxy 表中的 accept 无法覆盖其他表中的 drop**。无需为目标服务器配置返回客户端的特殊路由，但转发服务器必须能访问目标地址和端口。

端口映射处理外部进入本机的流量。请从另一台机器测试转发端口；服务所在服务器自身的请求不经过 prerouting，首版不做本机 OUTPUT 转发。

## 配置和数据

`/etc/fastproxy/fastproxy.env` 为 root 专用的 systemd EnvironmentFile（权限 0600）：

```ini
FASTPROXY_MODE=nftables
FASTPROXY_LISTEN=127.0.0.1:8080
FASTPROXY_ADMIN_USER=admin
FASTPROXY_ADMIN_PASSWORD="至少12个字符的密码"
FASTPROXY_COOKIE_SECURE=false
FASTPROXY_PROTECTED_PORTS=22
FASTPROXY_DATA_DIR=/var/lib/fastproxy
FASTPROXY_SOCKET=/run/fastproxy/control.sock
FASTPROXY_NFT_BINARY=/usr/sbin/nft
```

HTTPS 反向代理部署时设置 `FASTPROXY_COOKIE_SECURE=true`，保留请求的 `Host`，然后重启。密码修改或服务重启后需要重新网页登录。请勿把密码文件提交到 Git。

| 路径 | 用途 |
| --- | --- |
| `/opt/fastproxy` | 程序、静态网页、私有 Node 运行时 |
| `/var/lib/fastproxy/state.json` | 规则和全局启停状态 |
| `/var/lib/fastproxy/audit.jsonl` | 登录与配置操作记录 |
| `/run/fastproxy/control.sock` | 仅 root 可访问的控制台 API |
| `/etc/sysctl.d/90-fastproxy.conf` | 开机启用 IPv4 转发 |

服务日志：`journalctl -u fastproxy -f`。首次排查可执行 `sudo nft list table ip fastproxy`、`sysctl net.ipv4.ip_forward`、`sudo fastproxy status`。如果其他工具重载防火墙导致专属表丢失，使用菜单“重新应用已保存规则”。内核状态正常只代表规则已安装，不代表目标服务器正在监听。流量统计是双向数据包字节数，每次发布或重启后重置，不包含被其他防火墙提前丢弃的数据。

备份时保存 `/var/lib/fastproxy` 和 `/etc/fastproxy`；规则文件损坏时服务会停止启动并保留文件，不会静默清空配置。审计文件可按需配置 logrotate。

## 测试

`npm test` 覆盖登录、CSRF、规则增删改、并发版本控制、校验和失败恢复。Linux 下还可以运行真实网络测试：

```bash
npm test
sudo unshare --mount --net --fork env FASTPROXY_INTEGRATION=1 \
  "$(command -v node)" --test apps/server/dist-test/test/network.test.js
```

真实测试在独立网络命名空间内建立请求端、转发端和目标端，验证 TCP / UDP 原始数据及回包、SNAT、端口修改、停用 / 恢复、规则事务失败和已有防火墙保留。不会改变主机网络规则。

如需验证真实 systemd 单元的权限限制、启动、重启恢复和停止清理，在已构建的 Linux 项目目录运行 `sudo bash scripts/test-systemd.sh`。脚本使用独立网络命名空间和临时单元，结束后清理，不安装正式服务。
