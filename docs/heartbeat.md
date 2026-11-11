# 外部心跳（healthchecks.io）配置指南

## 为什么需要

ops-agent 的所有检查都在**同一台服务器**上，用的是这台机器的 cron。如果：

- cron 服务挂了 / crontab 被清空
- 服务器宕机、断网、磁盘满导致脚本无法启动
- 脚本本身崩溃（还没走到发信逻辑）

那么「今天没有收到告警邮件」这件事本身是**没有任何信号**的——你会以为一切正常。

外部心跳（dead man's switch）解决这个问题：ops-agent 每次巡检结束都向
[healthchecks.io](https://healthchecks.io/) 发一个「我还活着」的信号；
如果超过约定周期没收到信号，healthchecks 会**反向**发邮件/短信给你。

healthchecks.io 免费计划足够用（20 个 Check、邮件/Webhook 通知）。

> 任何支持「HTTP GET 即视为存活」的服务都可以替代 healthchecks.io，
> 只需把 `HEARTBEAT_URL` 指向该服务的 ping 地址即可（本项目的 `/fail` 语义是 healthchecks 的约定）。

---

## 一、注册并创建 Check

1. 打开 <https://healthchecks.io/>，注册账号（免费，邮箱注册）
2. 登录后点 **Create Check**（或 `+ Add Check`），填写：

| 字段 | 建议值 | 说明 |
|---|---|---|
| Name | `web-01 ops-agent` | 任意，建议带主机名 |
| Tags | `ops-agent` | 可选，便于分组 |
| **Period** | **12 hours** | 巡检周期。09:00 与 21:00 各 ping 一次，间隔 12 小时 |
| **Grace Time** | **2 hours** | 超过 Period + Grace 才报警，避免巡检稍有延迟就误报 |
| Timezone | 你的时区（如 `Asia/Shanghai`） | 仅影响面板显示 |
| Channels | 勾选 **Email** | 不勾通知渠道就不会发信 |

> 如果以后只保留 09:00 一次巡检，把 Period 改成 **24 hours**，Grace 保持 2 hours 即可。

3. 保存后进入该 Check 的页面，在 **Integrations / Ping URL** 区域复制形如下面的地址：

```
https://hc-ping.com/70ff45c7-e762-40e8-9d71-55ceb035a0cf
```

> 这个 UUID 就是你的私有 ping key，**不要提交到 Git**。本项目只把它放在本地的
> `config.env`（已被 `.gitignore` 忽略）。

---

## 二、配置 ops-agent

编辑 `config.env`（私有文件）：

```bash
HEARTBEAT_ENABLED=true
HEARTBEAT_URL="https://hc-ping.com/<你的-uuid>"
```

保存后立即手动验证一次：

```bash
bash scripts/heartbeat-test.sh
# 或者：
curl -fsS -m 10 "$HEARTBEAT_URL" && echo "ping ok"
```

回到 healthchecks 面板，该 Check 应显示 **New / Up**，并出现刚才的 Last Ping 时间。

---

## 三、运行时的行为

| 场景 | 动作 | 面板表现 |
|---|---|---|
| 巡检正常结束（无 CRIT） | `GET https://hc-ping.com/<uuid>` | Up（绿） |
| 巡检发现 CRIT | `GET https://hc-ping.com/<uuid>/fail` | Down（红），若配置了通知会立刻发信 |
| 超过 Period + Grace 没有任何 ping | 不上报 | **反向告警**：cron 挂了 / 机器挂了 / 脚本崩溃 |

- 两种巡检模式都会 ping：`agent.sh`（09:00 完整巡检）与 `agent.sh --crit-only`（21:00 仅 CRIT）
- `--dry-run` / `--report-only` **不会** ping（避免调试时掩盖真实故障）
- 每次 ping 的结果记录在 `logs/.state/heartbeat.log`，例如：

```
2026-11-11 14:08:52 ping ok (ok)
2026-11-12 21:00:03 ping ok (ok)
2026-11-13 09:00:05 ping fail (fail)     # 当天有 CRIT，已同时发邮件
```

- 未配置 `HEARTBEAT_URL` 或 `HEARTBEAT_ENABLED=false` 时自动跳过，不影响巡检

---

## 四、验证通知是否真的能收到

1. 在 Check 页面点 **Send test notification**（healthchecks 会通过已勾选的渠道发一条测试消息）
2. 确认邮箱收到、且能正常显示
3. 也可以在面板把 Check 手动 **Pause** 超过 Period+Grace 验证一次真实告警（验证后记得 Resume）

---

## 五、常见问题

| 现象 | 原因与处理 |
|---|---|
| `heartbeat.log` 里 `ping FAIL` | 服务器到 healthchecks.io 网络不通（DNS/防火墙/代理）；先 `curl -4 -v "$HEARTBEAT_URL"` 排查 |
| 偶尔超时、过一会儿又正常 | 很可能是**本机 IPv6 不通**：healthchecks 有 AAAA 记录，curl 会先连 IPv6 后超时。本项目的 ping 已强制 `curl -4` 并带 3 次重试；若你自行调用 curl，请加 `-4` |
| 面板一直不显示 ping | `HEARTBEAT_URL` 填错（少了 `/fail` 以外的路径也算对，但 uuid 错会 404）；或 `HEARTBEAT_ENABLED=false` |
| 每天都报 Down | Period 设置过短（比如设成 1 小时）；按本指南设 12h + 2h Grace |
| 收到 CRIT 邮件后面板也 Down，是否重复告警？ | 是**有意的双保险**：项目自己的邮件含详细信息，healthchecks 作为独立通道兜底 |
| 免费额度够吗 | 免费计划 20 个 Check，本项目 1 个足够；周期最小可到 1 分钟 |
| 想关闭心跳 | `config.env` 里设 `HEARTBEAT_ENABLED=false`，或删掉 `HEARTBEAT_URL` |

---

## 六、可选：用 API 查看 Check 状态

healthchecks 提供 API（需要面板 **Settings → API Access** 里的 key）：

```bash
# 列出所有 Check（含 status / last_ping / next_ping）
curl -fsS -H "X-Api-Key: <your-api-key>" https://healthchecks.io/api/v1/checks/ | jq '.checks[] | {name, status, last_ping, next_ping}'
```

注意：API key 是账号级密钥，**不要**写进脚本或仓库；本项目运行时不依赖 API，仅用于人工排查。
