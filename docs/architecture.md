# 架构与实现说明

## 数据流

```
cron
 ├─ 00:05  backup.sh daily        ┐
 ├─ 00:30  update-databases.sh    │ 采集类任务：只写 logs/，不告警
 ├─ 00:45  rkhunter-scan.sh       │
 ├─ 01:02  clamav-scan.sh         ┘
 ├─ 09:00  agent.sh               完整巡检 → 判定 → 必要时发信
 └─ 21:00  agent.sh --crit-only   仅 CRIT 巡检 → 必要时发信
```

`agent.sh` 的职责边界很清晰：

1. **采集**：依次执行 `modules/*.sh`，每个模块只输出 `findings`（不负责发信）
2. **归纳**：合并成文本报告写入 `logs/YYYY-MM-DD-report.log`
3. **决策**：`lib/alert.sh` 分级 + 去重，`lib/judge.sh` 调 AI 过滤 WARN
4. **通知**：`lib/notify.sh` 生成 HTML 邮件（msmtp）

## findings 协议

模块与主流程之间只用一行一个的 TSV 通信（`|` 分隔）：

```
LEVEL|KEY|TITLE|DETAIL|SUGGEST
```

- `LEVEL`：`CRIT` / `WARN` / `INFO` / `OK`
- `KEY`：稳定的去重键（如 `disk:/`、`cert:example.com`、`svc:nginx`）；同一 KEY 在窗口期内只提醒一次
- `DETAIL`：一行证据（内部会把换行和 `|` 压平）
- `SUGGEST`：建议动作，直接展示在邮件里

### 新增一个检查模块

```bash
#!/bin/bash
# modules/14-my-check.sh
OPS_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "${OPS_ROOT}/config.env"
source "${OPS_ROOT}/lib/common.sh"

finding INFO "my:key" "正常项" "证据" ""
finding WARN "my:issue" "异常标题" "证据" "建议动作"
```

然后把模块名加入 `agent.sh` 的 `MODULES` 数组即可，无需改判定逻辑。

## 状态文件

`logs/.state/` 下均是可重建的运行状态（不入库）：

| 文件 | 用途 |
|---|---|
| `alerted.tsv` | 去重表：`key / 上次发送 epoch / 级别` |
| `kv.tsv` | 通用 KV：当前 AI 模型、磁盘基线、rkhunter 基线时间 |
| `judge-<date>.log` | AI 判定审计：候选模型、耗时、原始 JSON |
| `judge-items-<date>.tsv` | AI 给出的处理顺序 |
| `mail.log` / `heartbeat.log` | 发信与心跳结果 |

## 阈值与策略配置

全部集中在 `config.env`（模板见 `config.env.example`），代码里不写死阈值。
`config/backup.conf` 只描述"备份什么"，与"怎么判定"解耦。

## 已知取舍

- 依赖 cron 而非 systemd timer：更通用；代价是无法补跑，故引入外部心跳兜底
- AI 判定按模型名字含 `free` 动态选型：免费模型生命周期不可控，因此不写死、失败自动切换
- rkhunter 属性基线按周刷新：完全不刷新会因正常升级产生大量误报，每天刷新又会让入侵痕迹被"洗白"，周更 + 手动 `--propupd` 是折中
