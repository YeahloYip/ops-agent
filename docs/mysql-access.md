# MySQL 3306 访问控制（关闭公网 + 按需放行）

## 为什么

MySQL 默认监听 `0.0.0.0/::`，若防火墙又是放行状态，等于把数据库直接暴露在公网：
任何人都能尝试连接、爆破账号、触发漏洞。而大多数服务器上的应用（PHP）都是通过
`127.0.0.1` 连库的，**根本不需要公网可达**。

本项目提供 `scripts/mysql-guard.sh`，用防火墙专用链 `MYSQL_GUARD` 控制 3306：

| 来源 | 默认行为 |
|---|---|
| 本机回环 `lo`（127.0.0.1 / ::1） | ✅ 永久放行（应用不受影响） |
| 公网 IPv4 | ❌ DROP（除非在白名单） |
| IPv6 | ❌ DROP（默认不白名单，防止 IPv6 裸奔） |

> 选择防火墙而不是改 `bind-address`：改 bind 要重启 MySQL 才能切换；
> 防火墙可以随时开关、支持按来源 IP 放行、还能**自动过期**，不动数据库配置。
>
> 需要人工连库时，**优先用 SSH 隧道**（见下节），而不是开白名单。

## 日常远程访问：优先用 SSH 隧道（不用开任何端口）

这是**推荐的日常方案**：3306 全程保持关闭，通过 SSH 把服务器本机的 3306 映射到本地端口。
流量全程走 SSH 加密通道，不需要白名单、不需要改 MySQL 配置，也不受来源 IP 变化（NAT/代理）影响。

### 1. 建立隧道

```bash
# 在本地电脑执行：
#   -N            只做端口转发，不打开远程 shell
#   -L 13306:127.0.0.1:3306   本地 13306 → 服务器 127.0.0.1:3306
ssh -p <端口> -i ~/.ssh/<你的私钥> -N -L 13306:127.0.0.1:3306 <用户名>@<服务器地址>
```

示例（把尖括号内容换成自己的）：

```bash
# 如果 SSH 使用默认 22 端口、默认密钥 ~/.ssh/id_ed25519：
ssh -N -L 13306:127.0.0.1:3306 user@203.0.113.10
```

常用可选参数：

| 参数 | 作用 |
|---|---|
| `-N` | 不执行远程命令，只转发（推荐） |
| `-f` | 把 ssh 放到后台，命令立即返回 |
| `-C` | 开启压缩（跨公网慢链路时略快） |
| `-o ExitOnForwardFailure=yes` | 端口占用时直接失败，避免"看起来连上了其实没转发" |
| `-o ServerAliveInterval=30` | 每 30 秒保活，防止 NAT 断链空闲超时 |

### 2. 连接数据库

隧道建立后，**本机随便什么客户端**都连 `127.0.0.1:13306`，就像数据库在本地一样：

```bash
mysql -h 127.0.0.1 -P 13306 -u <数据库用户> -p
```

GUI 客户端（Navicat / DBeaver / TablePlus / DataGrip / MySQL Workbench）配置：

| 字段 | 值 |
|---|---|
| Host | `127.0.0.1` |
| Port | `13306`（与 `-L` 第一个端口一致） |
| User / Password | 数据库账号 |
| SSH 隧道 | 部分客户端内置：填服务器地址、SSH 端口、私钥、SSH 用户，即可省掉命令行 `ssh -L` |

### 3. 用例

```bash
# 后台常驻隧道（关终端也保持）
ssh -f -N -L 13306:127.0.0.1:3306 user@203.0.113.10

# 同时转发多个端口（例如顺带看 Redis/HTTP）
ssh -N -L 13306:127.0.0.1:3306 -L 16379:127.0.0.1:6379 user@203.0.113.10

# 用完关掉：按 Ctrl+C，或
pkill -f "ssh.*-L 13306:127.0.0.1:3306"
```

### 4. 为什么推荐这种方式

| 优点 | 说明 |
|---|---|
| 不暴露端口 | `nl -l`/`ss` 上 3306 对公网仍是 DROP，扫描器看不到 |
| 加密 | 数据库协议本身明文，走 SSH 后整条链路加密 |
| 无需白名单 | 隧道从服务器本机 `127.0.0.1` 发起，永远命中 `lo` 放行，白名单为空也不影响 |
| 可审计 | SSH 登录都会记录在 `/var/log/auth.log`，谁在什么时候开过隧道可追溯 |
| 可随身 | 换网络/换 IP 都不影响（不像白名单要改 IP） |

### 5. 排错

| 现象 | 处理 |
|---|---|
| `bind: Address already in use` | 本地 13306 被占用：换一个本地端口，如 `-L 13307:...` |
| 隧道建立后连不上数据库 | 确认 `-L` 的右侧是**服务器上**的地址：应写 `127.0.0.1:3306`（不是本地地址） |
| 提示 `Permission denied (publickey)` | SSH 密钥/用户/端口不对，先用相同参数 `ssh <用户名>@<服务器地址>` 验证能登录 |
| 能登录但 `Access denied for user` | 是 MySQL 账号权限问题（与隧道无关）：检查该用户允许的 host、密码 |
| 隧道跑一会儿就断 | 加 `-o ServerAliveInterval=30 -o ServerAliveCountMax=3`，或用 `autossh` |
| 断开后重连报端口占用 | 旧 ssh 进程还在：`pkill -f "ssh.*-L 13306"` 后再连 |

> 安全提示：`-L` 默认只监听本机 `127.0.0.1`，仅本机可用。**不要**加 `-g`（会把隧道开放给同网段其他人）。

## 需要临时放行某个 IP（例如你的电脑直连）

```bash
# 在服务器上执行（默认 60 分钟后自动关闭）
bash scripts/mysql-guard.sh open 203.0.113.10 60 "临时取数"

# 查看到期时间/白名单
bash scripts/mysql-guard.sh status

# 用完立刻关闭
bash scripts/mysql-guard.sh close 203.0.113.10
```

- 分钟数填 `0` 表示**长期放行**（不自动过期）
- 支持 CIDR，例如 `open 203.0.113.0/24 30 "办公室出口"`
- 注意：如果客户端在 NAT/代理后面，服务器看到的是**出口 IP**，不是你的电脑 IP；
  可用 `curl -4 ifconfig.me` 查看自己出口 IP

## 自动过期

`open` 带分钟数时会写入到期时间，由 cron 定期清理并重建规则：

```cron
# 每 5 分钟清理过期白名单
*/5 * * * * /opt/ops-agent/scripts/mysql-guard.sh expire >/dev/null 2>&1
```

## 状态与确认

```bash
bash scripts/mysql-guard.sh status
```

输出包含：INPUT 链里 3306 的规则、`MYSQL_GUARD` 链（含匹配计数）、白名单及剩余时间、
以及是否存在「裸放行 3306」的历史规则；巡检模块 `03-vulnerability` 也会读这个状态并告警。

从外部验证（在本机执行，应当连不上/超时）：

```bash
nc -vz <server> 3306      # 预期被拒绝或超时
```

服务器上应用应仍然正常（走 127.0.0.1）：

```bash
mysql --defaults-extra-file=/root/.my.cnf -e 'select 1'
```

## 持久化（重启后仍然生效）

脚本在每次变更后调用 `netfilter-persistent save` 固化到 `/etc/iptables/rules.v4`。

如果服务器没有 `netfilter-persistent`（Debian/Ubuntu 包名 `iptables-persistent`），
可额外加一条开机重建规则：

```cron
@reboot /opt/ops-agent/scripts/mysql-guard.sh apply >/dev/null 2>&1
```

## 常见问题

| 现象 | 处理 |
|---|---|
| `open` 后仍然连不上 | 确认连接源 IP 是否为白名单里的（NAT/代理会换出口 IP）；云厂商还有一层「安全组/防火墙」，也要放行该端口 |
| 应用连不上数据库 | 应用应连 `127.0.0.1`；回环默认放行，若改过 MySQL `bind-address` 需与之一致 |
| 重启后规则丢失 | 检查 `netfilter-persistent save` 是否成功、`/etc/iptables/rules.v4` 是否含 `MYSQL_GUARD`；或加 `@reboot apply` |
| 白名单里放了 `0.0.0.0/0` | 脚本会拒绝：该地址等于对全网开放，请填具体 IP/CIDR |
| 想彻底关掉 MySQL 对外监听 | 可在 `/etc/mysql/mysql.conf.d/` 加 `bind-address = 127.0.0.1` 并重启 MySQL；此后白名单放行也不再有效（只推荐给只用本机的场景） |
