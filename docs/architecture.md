# FastProxy 架构约定

数据通路：客户端 ⇄ HAProxy 本机 TCP 监听端口 ⇄ 目标 IPv4 和 TCP 端口。HAProxy 建立独立出站连接并双向传递应用数据，Node 管理服务不搬运业务数据。

- 支持 TCP；HAProxy 社区版不支持通用 UDP 转发。旧状态迁移到 schema 2，both 转为 TCP，UDP 保留为停用状态并禁止启用；原状态文件单独备份。
- 应用数据保持不变。目标服务器通常看到转发服务器的地址；首版不支持保留客户端源地址、跨 IPv4/IPv6 转换或动态域名目标。
- 默认监听全部本机 IPv4，也可指定一个本机 IPv4；支持本机和外部客户端访问该监听地址。
- 一条规则包括名称、协议、监听 IP/端口、目标 IP/端口、启用状态。开启的规则不允许监听端点重叠。管理端口和配置的 SSH 端口受到保护。
- Web 后台和 `fastproxy` 菜单调用同一套服务 API。网页需要登录和 CSRF 校验；本机控制台通过仅 root 可访问的 Unix socket 管理。
- 修改前检查规则并持久化意图，生成独立配置文件后执行 `haproxy -c -f` 校验。前台启动新 HAProxy 进程，用 `-x` 转移监听 socket、`-sf` 平滑停止旧进程。新统计 socket 确认 PID 后返回成功；配置或绑定失败恢复磁盘规则，原进程继续服务。
- HAProxy 由 Node 管理，独立于系统 haproxy.service 和 /etc/haproxy 配置；使用 /run/fastproxy 中的私有配置和管理 socket。systemd 只保留 CAP_NET_BIND_SERVICE，文件描述符限制为 16384。
- 不需要内核转发和 NAT；监听端口须允许 INPUT，目标访问须允许 OUTPUT。新安装不修改防火墙或 sysctl；旧版本迁移仅清理 FastProxy 专属表和未修改的专属 sysctl 文件，不更改其他工具的配置或当前全局转发值。
- 修改、停用、删除或暂停影响新连接，旧进程继续处理既有 TCP 会话，默认空闲超时 1 小时。正常停止会结束所有 HAProxy 进程和连接；活动进程异常退出触发 Node 退出，由 systemd 清理服务进程组并重启。
- 流量计数只读取当前活动进程的 FRONTEND 双向应用字节和连接数，不重复累计 BACKEND，也不包含旧进程继续处理的流量。每次重载 / 重启重置；健康状态不保证目标服务可用。最多允许 32 个活动和旧进程，防止持续长连接加频繁重载造成无限进程积累。
- systemd 开机启动并负责异常重启；规则文件位于 `/var/lib/fastproxy/state.json`，操作记录为 `audit.jsonl`，服务日志在 journal。
- 安装直接编译源码：仓库内使用当前目录的代码，curl 入口拉取 main 或指定标签；临时目录完成依赖安装、前后端构建和后端生产依赖安装后再替换服务。程序使用 `/opt/fastproxy/runtime` 中的私有 Node.js 24，更新保留 `/etc/fastproxy` 和 `/var/lib/fastproxy`。

后台面向运维人员，推荐通过 SSH 隧道或 HTTPS 反向代理访问。默认管理地址只绑定 `127.0.0.1:8080`。
