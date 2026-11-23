# AGENTS.md — ops-agent（服务器巡检 / 告警 agent）

先读根 `../AGENTS.md` 全局硬规则；本文件是项目深上下文。

## 基本信息
| 项 | 值 |
|---|---|
| 类型 | Bash + cron + msmtp（零外部依赖，可选 ClamAV/rkhunter/fail2ban/acme/qshell/opencode） |
| 本地路径 | `（本机工作目录，略）` |
| git | 本地单一远端 `gitee`=gitee `Yeahlo/ops-agent`；**生产只跟 gitee**（见下方"部署链路"） |
| 生产部署 | `root@<生产服务器IP>:<生产部署目录>`（`config.env` 私有，勿动/勿回显） |

## 部署链路
- 本地 `gitee`  → Gitee `Yeahlo/ops-agent`
- 生产 `origin` → Gitee `Yeahlo/ops-agent`

**发布只推 gitee 一个远端**：
```bash
git push gitee main
ssh aoyo 'cd <生产部署目录> && git pull && bash agent.sh --dry-run'
```

- 生产若出现 `git status` dirty，说明有人直接改过文件（绕过 git）。**先 `git stash` 再 `pull`，
  确认 `git diff stash@{0}` 无差异后 `git stash drop`**，不要直接 checkout/clean。
- 排查：本地 `git remote -v`、`git ls-remote --heads gitee`；
  生产 `git log --oneline -1`、`git status -sb`。

## 结构
- `agent.sh`：入口（采集→分级→AI 判定→只在"必须处理"时发邮件）。
- `modules/01..13`：软件更新/EOL、病毒、漏洞、磁盘、访问日志、错误日志、备份、证书、服务、资源、安全、HTTP 探活等。
- `lib/`：`common.sh` `alert.sh` `judge.sh` `notify.sh`。
- `scripts/`：`backup.sh` `clamav-scan.sh` `heartbeat-test.sh` `log-rotate.sh` `mysql-guard.sh` `rkhunter-scan.sh` `update-databases.sh`。
- 配置：`config.env`（私有）、`config/backup.conf`（私有）——**均被 .gitignore，禁止提交/回显密钥**。

## 命令 / 验证
- 干跑：`bash agent.sh --dry-run`（改完模块必先跑）。
- 真实巡检：`bash agent.sh`（只读检查 + 按配置备份；会写 `logs/`、`BACKUP_DIR`）。
- 语法检查：`bash -n modules/*.sh lib/*.sh agent.sh`；有 shellcheck 就 `shellcheck`。

## 规则（重点）
- 改 `modules/`、`lib/`、`scripts/`、`agent.sh`：本地 `bash -n` + `--dry-run` → push → 用户确认 → 服务器 `git pull` → `--dry-run` 复验。
- **绝不**在对话里输出 `config.env` / `config/backup.conf` 的 SMTP、密钥、HEARTBEAT_URL 等。
- 这是"管理 agent"，它对生产只做**只读巡检**与**备份落盘**（既定 cron 行为）；**AI 不得借它去执行写库/改文件/重启**。
- 生产 `config.env` 属用户私有配置，需修改时由用户执行，AI 只给建议。
