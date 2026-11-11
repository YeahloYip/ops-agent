# ops-agent

轻量级 Linux 服务器巡检与告警系统（Bash + cron）。

> 每日采集 → 分级 → AI 判定 → **只在"必须人工处理"时发邮件**；日常报告只落盘，不打扰。

## 特性

- **13 个检查模块**：软件更新/EOL、ClamAV、rkhunter、磁盘与 inode、访问日志、错误日志、备份有效性、证书与续签、DNS 解析、资源（负载/内存/swap）、服务存活与探活、安全事件、HTTP 探活
- **只在需要时告警**：CRIT 直接发信；WARN 交给 AI 判定是否"24 小时内必须处理"，其余只落盘
- **告警去重**：CRIT 24h / WARN 3 天 / 静态问题 7 天，避免同一问题天天轰炸
- **AI 判定可切换**：从 opencode 的免费模型中动态挑选，失败自动切换下一个，模型下线无需改代码
- **两次巡检**：09:00 完整巡检；21:00 仅 CRIT（缩短磁盘满/服务挂/证书失效等关键问题的发现延迟）
- **零外部依赖**（除可选组件）：纯 Bash + cron + msmtp；对象存储、AI 判定、心跳均可关闭
- **外部心跳**：可接 healthchecks.io，cron 挂了/机器挂了会反向告警

## 快速开始

```bash
# 1. 放到服务器
git clone <本仓库> /opt/ops-agent && cd /opt/ops-agent
chmod +x agent.sh modules/*.sh scripts/*.sh

# 2. 本地配置（私有，勿提交）
cp config.env.example config.env
cp config/backup.conf.example config/backup.conf
chmod 600 config.env config/backup.conf
$EDITOR config.env config/backup.conf     # 填 SMTP、站点、路径、阈值

# 3. 依赖
#   必需：bash 4+、cron、curl、jq、msmtp（/etc/msmtprc 配好账户）、/root/.my.cnf（MySQL 备份与探活）
#   可选：
#     - clamscan/freshclam、rkhunter、fail2ban：安全扫描
#     - acme.sh：证书续签检查
#     - qshell：七牛 Kodo 对象存储备份
#       安装与授权：https://developer.qiniu.com/kodo/1302/qshell
#       详见 config/backup.conf.example 注释；不启用则保持 QINIU_ENABLED=false
#     - opencode：AI 判定（https://opencode.ai）
#     - healthchecks.io：外部心跳（见下文）

# 4. 先干跑，确认输出无误
bash agent.sh --dry-run

# 5. 配 cron（示例见 cron.example）
crontab -e

# 6. 可选：配置外部心跳（cron 掉线会反向告警），见 docs/heartbeat.md
cp config.env.example 中的 HEARTBEAT_URL → config.env，然后：
bash scripts/heartbeat-test.sh
```

## 判定流程

```
13 个检查模块 → findings（CRIT / WARN / INFO / OK）
      │
      ├─ CRIT  → 直接发邮件（P0，规则决定，不经 AI）
      ├─ WARN  → AI 判定（opencode 免费模型）
      │           ├─ notify=true  → 发邮件（P1）
      │           └─ notify=false → 不发信，只记报告
      └─ INFO/OK → 只记报告
      │
      └─ 去重：CRIT 24h / 普通 WARN 3 天 / 静态问题（sshd、EOL、端口）7 天
```

- **AI 只能升级不能降级**：CRIT 永远发信；AI 仅用于过滤 WARN 噪音。
- **AI 不可用时回退**：`JUDGE_FALLBACK_NOTIFY=true` 则 WARN 也发；或 `JUDGE_FALLBACK_WARN_MIN` 达到数量阈值才发（默认保守：只发 CRIT）。
- **模型动态切换**：每天从 `opencode models` 里筛名字含 `free` 的模型，按偏好排序逐个尝试；成功的模型记入 `logs/.state/kv.tsv` 下次优先使用。

## 目录结构

```
ops-agent/
├── agent.sh                  # 入口：采集→报告→判定→发信
├── config.env.example        # 配置模板（复制为 config.env）
├── config/backup.conf.example# 备份清单模板（复制为 config/backup.conf）
├── lib/
│   ├── common.sh             # finding 输出、状态读写
│   ├── notify.sh             # HTML 邮件（msmtp）
│   ├── alert.sh              # 分级、去重窗口、发送判定
│   └── judge.sh              # AI 判定（免费模型，自动切换）
├── modules/                  # 13 个检查模块
├── scripts/                  # 备份 / 病毒扫描 / rootkit / 基线更新 / 日志轮转
├── docs/                     # architecture.md / heartbeat.md
├── cron.example              # crontab 示例（已错峰）
├── logs/                     # 运行数据（不入库）
├── LICENSE
└── SECURITY.md
```

## 检查模块

| 模块 | 内容 | 告警条件 |
|---|---|---|
| 01-software-update | 安全更新、EOL、apt 索引 | 有安全更新→CRIT；EOL→WARN |
| 02-virus-scan | ClamAV 结果 | 感染→CRIT；未扫描→WARN |
| 03-vulnerability | rkhunter、SSH 配置、端口暴露 | rootkit→CRIT；弱配置/数据库端口公网→WARN |
| 04-disk-space | 磁盘、inode、日增长 | ≥90%→CRIT；≥85% 或日增 5%→WARN |
| 05-access-log | 当日请求/403/5xx 统计 | 5xx 超阈值→WARN |
| 06-error-log | error_log（剔除 WAF 噪音） | 后端连接失败/真实错误多→WARN |
| 07-backup | 备份新鲜度、gzip 完整性、体积、云端回读 | 缺失/损坏/未更新→CRIT |
| 08-cert-renewal | 证书到期、acme 续签计划、线上与磁盘一致性 | 过期/≤7 天/未 reload→CRIT |
| 09-active-sites | 域名解析 | 解析异常→WARN |
| 10-system-resources | 负载、内存、swap、TOP 进程 | 负载/内存超限→CRIT 或 WARN |
| 11-service-health | 服务存活、nginx -t、MySQL、PHP socket | 服务挂→CRIT |
| 12-security-events | SSH 爆破、fail2ban 封禁、WAF 拦截量 | 爆破/封禁超阈值→WARN |
| 13-http-probe | 各站点 HTTPS 探活 | 5xx/连不上→CRIT；慢→WARN |

## 使用方式

```bash
bash agent.sh                # 正常巡检（仅在需要处理时发信）
bash agent.sh --dry-run      # 只跑检查并输出结论，不发信（改完先跑这个）
bash agent.sh --report-only  # 生成报告，不做判定
bash agent.sh --crit-only    # 只发 P0（不跑 AI、不发 WARN），报告存 logs/YYYY-MM-DD-report-crit.log
bash agent.sh --force        # 强制发一封（验证邮件链路）

bash scripts/backup.sh daily|weekly|monthly|file|all
bash scripts/clamav-scan.sh
bash scripts/rkhunter-scan.sh
bash scripts/update-databases.sh [--propupd]
bash scripts/log-rotate.sh
bash scripts/heartbeat-test.sh [--fail]   # 手动测试心跳（见 docs/heartbeat.md）
```

## 定时任务

见 `cron.example`。要点：

- 09:00 完整巡检、21:00 仅 CRIT 巡检
- 备份任务错峰（daily 00:05 / weekly 周一 00:15 / monthly 1 日 00:25 / file 1 日 00:35），避免数据库备份与文件打包抢 IO
- `update-databases.sh` 默认每 7 天才刷新一次 rkhunter 属性基线（`PROPUPDATE_INTERVAL_DAYS`），避免把每天的文件变更写成"可信基线"

## 邮件

- 主题：`[需处理][P0] <主机名> - <一句话结论>`（RFC 2047 编码，中文不乱码）
- 正文：问题表格（级别/问题/证据/建议动作）＋ AI 建议处理顺序 ＋ 已抑制项说明 ＋ 报告路径
- 只有 P0（规则）与 AI 判定需要处理的 P1（WARN）才会发送
- 发送记录：`logs/.state/mail.log`

## 外部心跳（cron 掉线检测）

所有检查都在同一台机器上，若 cron/系统整体异常导致 agent 根本没跑，本地无法自证。
因此支持外部 dead-man 心跳：每次巡检结束向 healthchecks.io 报活，超时未报则由对方反向告警。

**启用步骤**（详细图文说明见 [docs/heartbeat.md](docs/heartbeat.md)）：

1. 注册 <https://healthchecks.io/>（免费），**Create Check**：
   - Period = **12 hours**（对应 09:00 / 21:00 两次巡检）、Grace = **2 hours**
   - Channels 勾选 **Email**（否则掉线不会通知你）
2. 复制 Check 页面的 ping URL（形如 `https://hc-ping.com/<uuid>`）
3. 填入 `config.env`（私有文件，勿提交）：

   ```bash
   HEARTBEAT_ENABLED=true
   HEARTBEAT_URL="https://hc-ping.com/<uuid>"
   ```

4. 手动验证一次：`bash scripts/heartbeat-test.sh`，回面板确认 **Last Ping / Up**
5. 运行时的行为：

   | 场景 | 动作 | 面板 |
   |---|---|---|
   | 巡检正常（无 CRIT） | `GET <url>` | Up |
   | 巡检发现 CRIT | `GET <url>/fail` | Down（同时项目自己也会发邮件） |
   | 超 Period+Grace 无 ping | — | 反向告警：cron 挂了 / 机器挂了 / 脚本崩溃 |

- `--dry-run` / `--report-only` 不 ping，避免调试时掩盖真实故障；ping 结果记录在 `logs/.state/heartbeat.log`
- 未配置 `HEARTBEAT_URL` 或 `HEARTBEAT_ENABLED=false` 时自动跳过，不影响巡检
- 免费计划 20 个 Check 足够本项目使用；换用其他支持「GET 即存活」的服务也可，只需改 `HEARTBEAT_URL`

## 排查

```bash
tail -50 logs/$(date +%F)-report.log      # 今日完整报告（含结论/抑制原因）
cat logs/.state/judge-$(date +%F).log     # AI 审计：候选模型、耗时、原始 JSON
cat logs/.state/kv.tsv                    # 当前使用的模型、磁盘基线、rkhunter 基线时间
cat logs/.state/alerted.tsv               # 去重表（key / 上次发送 epoch / 级别）
```

## 安全

- 真实凭据只存在于本地的 `config.env` / `config/backup.conf` / `/root/.my.cnf`，均不入库（见 `SECURITY.md`）
- 数据库口令不放在命令行（`ps` 可见），统一走 `/root/.my.cnf`
- 邮件只发不收，建议 SMTP 使用无其他用途的账号与授权码

## 许可

MIT，详见 `LICENSE`。
