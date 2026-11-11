# 安全说明

## 敏感文件不会入库

以下文件包含真实凭据/服务器信息，已被 `.gitignore` 忽略，**不要提交**：

| 文件 | 内容 |
|---|---|
| `config.env` | SMTP 口令、服务器 IP/主机名、站点列表 |
| `config/backup.conf` | 数据库名、备份目录、对象存储桶 |
| `logs/` | 运行日志（含访问日志、攻击 IP、内部路径） |

仓库只提供 `*.example` 模板。

## 凭据建议

- 数据库备份/探活使用 `/root/.my.cnf`（`chmod 600`）或 `--defaults-extra-file`，不要把密码写在脚本或命令行里（`ps` 可见）；
- 邮件口令建议使用邮箱的「客户端授权码」而非登录密码，并单独配置在 `/etc/msmtprc`；
- 本系统只会向 `MAIL_TO` 发信，不接收邮件，因此 SMTP 账号应无其他用途。

## 自查

提交前可运行：

```bash
git grep -nE 'password *=|PASS *=|BEGIN .*PRIVATE KEY|smtp.*=.*@' || true
```

## 报告问题

如发现本项目的安全问题，请通过仓库 Issue（不要公开贴出真实凭据）或私下联系维护者。
