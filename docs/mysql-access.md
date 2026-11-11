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

## 日常远程访问：优先用 SSH 隧道（不用开任何端口）

```bash
# 本地执行：把服务器 127.0.0.1:3306 映射到本地 13306
ssh -p 2222 -i ~/.ssh/id_ed25519_aoyo -N -L 13306:127.0.0.1:3306 root@<server>

# 另开终端，用本机客户端连 127.0.0.1:13306 即可
mysql -h 127.0.0.1 -P 13306 -u root -p
```

推荐日常都用隧道，`3306` 保持全程关闭。

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
