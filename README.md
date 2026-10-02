# FastProxy

通过中文网页后台或 `fastproxy` 数字菜单管理 Linux 服务器端口转发。Node.js + TypeScript 后端、Vue 3 + Element Plus 前端，HAProxy 负责 TCP 数据转发。直接源码编译安装，无需 Docker。

```text
客户端 ⇄ 当前服务器:8000 ⇄ 目标服务器:9000
```

支持 IPv4 TCP：HAProxy 监听本机端口并连接目标服务器，将请求和响应的应用数据原样双向传递。不解密 TLS，不添加 HTTP / PROXY 头；目标看到转发服务器的 IP。目标填写 IPv4 地址，当前不支持域名、IPv6、保留客户端源 IP 或通用 UDP 转发。

## 功能

- 管理员登录，HttpOnly / SameSite 会话、CSRF 校验、登录失败限速。
- 添加、修改、删除、启停转发规则，保存即校验并生效，冲突或失败保留原配置。
- 网页与本机 root 控制台共用状态；并发修改用版本号防止互相覆盖。
- 查看 HAProxy 双向流量、连接数、版本和运行状态，预览配置，暂停 / 恢复全局转发。
- systemd 开机启动与故障重启，规则持久化，安装器自动准备私有 Node.js 运行环境。
- 保存配置时先执行 HAProxy 校验，新进程启动成功后平滑接替监听，已有 TCP 连接继续由旧进程服务。
- 新安装不修改防火墙或 sysctl，不需要 `CAP_NET_ADMIN`，不依赖内核 IP 转发。

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

安装器支持 **Debian 12+ / Ubuntu 20.04+、amd64 / arm64、正在运行的 systemd**。需要 root 和服务器出网能力，安装器自动安装系统 HAProxy 和校验过的私有 Node.js 24，不修改原有 Node.js 或 `/etc/haproxy/haproxy.cfg`。FastProxy 管理自己的 HAProxy 子进程，独立于系统 `haproxy.service`；其他 HAProxy 服务使用的端口同样不能被占用。

### 在源码仓库中安装

服务器已经下载源码时，直接执行：

```bash
cd ~/fastproxy
git pull --ff-only
sudo bash scripts/install.sh
sudo fastproxy
```

首次下载源码可以使用：

```bash
git clone https://github.com/bunnya33/fastproxy.git ~/fastproxy
cd ~/fastproxy
sudo bash scripts/install.sh
sudo fastproxy
```

安装器自动准备 Node.js 24，运行 `npm ci`、编译 Vue 前端和 TypeScript 后端，再安装后端生产依赖、systemd 服务与数字菜单。源码会复制到临时目录编译，不带入仓库的 node_modules、演示数据或 .env；编译成功后才替换服务。第一次安装需要下载依赖，请等待编译完成。

安装器会显示首次生成的随机管理密码。默认后台绑定 `127.0.0.1:8080`；在你的电脑建立 SSH 隧道：

```bash
ssh -N -L 8080:127.0.0.1:8080 用户@服务器
```

随后在电脑浏览器打开 `http://127.0.0.1:8080`。如需直接监听公网：

```bash
sudo bash scripts/install.sh --listen 0.0.0.0:8080
```

公网管理后台请配置 HTTPS 反向代理或限制管理端口来源。安装器不会自动开放云安全组或修改 UFW / firewalld。

### curl 安装（推荐）

源码位于 [bunnya33/fastproxy](https://github.com/bunnya33/fastproxy)。通过 curl 执行时，安装器自动用 Git 拉取 main 源码并在服务器编译，不使用 FastProxy 预编译压缩包。

```bash
curl -fsSL https://raw.githubusercontent.com/bunnya33/fastproxy/main/scripts/install.sh \
  | sudo bash
```

也可先下载脚本后执行。指定版本使用 `sudo bash install.sh --version v0.2.0`，或使用 `--version latest` 拉取最新发布标签。指定其他本地源码目录使用 `--source /path/to/fastproxy`；它不能与 `--repo` / `--version` 同时使用。

重新执行安装器可更新程序，保留管理地址、密码、规则和审计记录。仓库安装更新前先 `git pull --ff-only`；curl 安装重新运行命令即可。v0.1.3 起移除了 `--package` 和应用打包步骤，旧安装器的发布包检查错误通过更新安装器解决。

### 从 nftables 版本升级

在源码目录 `git pull --ff-only` 后执行 `sudo bash scripts/install.sh` 即可迁移到 HAProxy。迁移短暂停止旧服务，密码和管理地址保留；TCP 规则保留，`both` 规则改成 TCP，纯 UDP 规则保留但停用，后台会提示它们不受支持。旧规则备份在 `/var/lib/fastproxy/state.nftables-backup.json`，旧环境配置备份在 `/etc/fastproxy/fastproxy.env.nftables-backup`。迁移启动失败会回退程序、环境配置和原规则。

旧服务停止时会移除自身转发表；如果之前异常退出留下 `ip fastproxy` 表，安装器仅删除该专属表。迁移成功后移除未被修改的 `/etc/sysctl.d/90-fastproxy.conf`，不改变当前全局 `ip_forward` 值，也不删除系统 nftables 包或其他防火墙配置。

## 数字菜单

```bash
sudo fastproxy
```

菜单提供服务器 / HAProxy 状态、规则列表、添加 / 修改规则、启停 / 删除规则、修改管理地址 / 密码、启动 / 停止 / 重启服务、查看日志、暂停 / 恢复全部转发和重新应用规则。

也支持快捷命令：

```bash
sudo fastproxy status
sudo fastproxy list
sudo fastproxy restart
sudo fastproxy stop
sudo fastproxy start
sudo fastproxy logs
```

网页的“启用状态”与全局转发开关分开保存，暂停全部转发不会删除规则。启停和修改规则影响**新连接**；已有 TCP 连接由旧 HAProxy 进程继续服务，默认空闲超时为 1 小时。停止 / 重启整个 FastProxy 服务会结束已有连接，再次启动恢复磁盘规则。活动 HAProxy 进程异常退出会使管理服务退出，systemd 清理剩余进程并重启。

## 防火墙与端口

添加规则前确认本机端口未用于其他服务，并在云安全组放行 TCP 监听端口。端口已占用、配置无效或无法绑定本机 IP 时保存失败，原规则和监听继续工作。默认保护 SSH 端口 22 和管理端口；安装器在 `SSH_CONNECTION` 可用时会记录当前 SSH 服务端口。使用自定义 SSH 端口时检查 `FASTPROXY_PROTECTED_PORTS`。

如果 UFW 开启，放行本机监听端口，例如本机 `8000/tcp` 转发到 `10.0.0.20:9000`：

```bash
sudo ufw allow 8000/tcp
```

HAProxy 接受本机 INPUT 连接并通过 OUTPUT 连接目标。若出站策略受限，还需允许访问目标 IP / TCP 端口；无需放行 FORWARD 或配置目标返回客户端的特殊路由。目标必须正在监听且能从转发服务器访问。

监听 `0.0.0.0` 时支持服务器本机及外部客户端连接；监听指定 IPv4 时仅接受该地址的连接。管理后台默认绑定 `127.0.0.1:8080`，如需公网访问，通过数字菜单改为 `0.0.0.0:8080` 并单独放行管理端口。

## 配置和数据

`/etc/fastproxy/fastproxy.env` 为 root 专用的 systemd EnvironmentFile（权限 0600）：

```ini
FASTPROXY_MODE=haproxy
FASTPROXY_LISTEN=127.0.0.1:8080
FASTPROXY_ADMIN_USER=admin
FASTPROXY_ADMIN_PASSWORD="至少12个字符的密码"
FASTPROXY_COOKIE_SECURE=false
FASTPROXY_PROTECTED_PORTS=22
FASTPROXY_DATA_DIR=/var/lib/fastproxy
FASTPROXY_SOCKET=/run/fastproxy/control.sock
FASTPROXY_HAPROXY_BINARY=/usr/sbin/haproxy
```

HTTPS 反向代理部署时设置 `FASTPROXY_COOKIE_SECURE=true`，保留请求的 `Host`，然后重启。密码修改或服务重启后需要重新网页登录。请勿把密码文件提交到 Git。

| 路径 | 用途 |
| --- | --- |
| `/opt/fastproxy` | 程序、静态网页、私有 Node 运行时 |
| `/var/lib/fastproxy/state.json` | 规则和全局启停状态 |
| `/var/lib/fastproxy/audit.jsonl` | 登录与配置操作记录 |
| `/run/fastproxy/control.sock` | 仅 root 可访问的控制台 API |
| `/run/fastproxy/g-*/haproxy.cfg` | 各 HAProxy 进程的生成配置和统计 socket |

服务日志：`journalctl -u fastproxy -f`。首次排查可执行 `sudo fastproxy status`、`sudo ss -ltnp`，并在后台查看 HAProxy 配置。HAProxy 健康只代表进程和管理 socket 正常，不代表目标服务器正在监听。流量统计为当前活动 HAProxy 进程的应用字节数和累计连接数，每次重载或重启重置；不包含旧进程继续处理的连接。最多允许 32 个活动 / 等待旧连接结束的进程，达到限制时等待会话结束或重启服务后再修改规则。

备份时保存 `/var/lib/fastproxy` 和 `/etc/fastproxy`；规则文件损坏时服务会停止启动并保留文件，不会静默清空配置。审计文件可按需配置 logrotate。

## 测试

`npm test` 覆盖登录、CSRF、规则增删改、并发版本控制、校验和失败恢复。Linux 下还可以运行真实网络测试：

```bash
npm test
sudo unshare --mount --net --fork env FASTPROXY_INTEGRATION=1 \
  "$(command -v node)" --test apps/server/dist-test/test/network.test.js
```

真实测试在独立网络命名空间内建立请求端、转发端和目标端，在内核转发关闭时验证 TCP 二进制数据及回包、监听 / 目标端口修改、已有连接跨重载继续工作、停用 / 恢复、配置失败和端口冲突回退、服务恢复与停止清理。不会改变主机网络。

如需验证真实 systemd 单元的权限限制、启动、重启恢复和停止清理，在已构建的 Linux 项目目录运行 `sudo bash scripts/test-systemd.sh`。脚本使用独立网络命名空间和临时单元，结束后清理，不安装正式服务。

安装器回归测试：`sudo bash scripts/test-install.sh`。使用 Ubuntu 20.04 / Debian 12 系统信息和离线下载、构建及服务替身，覆盖本地源码、curl 入口、版本选择、配置保留、编译失败保留原服务和 Node 校验失败。

真实源码安装测试：`sudo env FASTPROXY_TEST_NODE="$(command -v node)" bash scripts/test-install.sh --real`，需要 Linux Node.js 24、HAProxy、iproute2、jq、curl 和 npm registry 出网。测试预先准备独立 npm 缓存，然后在挂载和网络命名空间内真实安装依赖、编译 Vue / TypeScript、启动 Node / HAProxy、通过菜单查看规则，并验证旧配置迁移、更新后恢复和停止清理；systemd 操作及旧表清理由测试替身执行。结束后清理，不安装正式服务或修改主机网络。CI 同时在 Ubuntu 20.04 用户环境中执行安装和转发测试。
