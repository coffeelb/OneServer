# OneServer

[![构建状态](https://github.com/qichiyuhub/OneServer/actions/workflows/lint.yml/badge.svg)](https://github.com/qichiyuhub/OneServer/actions/workflows/lint.yml)
[![最新版本](https://img.shields.io/github/v/release/qichiyuhub/OneServer?display_name=tag&sort=semver)](https://github.com/qichiyuhub/OneServer/releases/latest)
[![许可证](https://img.shields.io/github/license/qichiyuhub/OneServer)](LICENSE)
[![Shell](https://img.shields.io/badge/Shell-Bash%204.3%2B-4EAA25?logo=gnu-bash&logoColor=white)](https://www.gnu.org/software/bash/)

简体中文 | [English](README.en.md)

## OneServer 是什么？

OneServer 是面向 Debian 和 Ubuntu 单机服务器的 Bash 运维工具，用于部署及维护 Web 服务、数据库、容器和基础安全配置。

- 安全优先：管理入口只在终端提供，Web 面板只读；凭据隔离存储，敏感内容不进入命令行和日志。
- 极低占用：核心无控制服务和数据库；不开启 Web 面板时，OneServer 自身无常驻后台进程或守护程序。
- 原生低依赖：纯 Bash，不引入第三方运行库，服务仍由 systemd、APT 和原生配置管理。
- 变更可控：支持真实状态预演、重复执行、全局互斥和原子替换；可撤销变更失败时自动回滚。
- 低侵入：项目创建的资源全程登记，组件卸载按记录清理，业务数据默认保留。
- 使用灵活：交互菜单适合日常运维，CLI 与 JSON 输出便于自动化和 AI 辅助运维。
- 状态直观：只读 Web 面板弥补终端不便集中查看组件、服务、端口、防火墙和日志的不足。

## 快速开始

```bash
curl -fsSL https://raw.githubusercontent.com/qichiyuhub/OneServer/main/install.sh | bash
```

`os` 是进入交互菜单的快捷命令。查看完整命令及参数：

```bash
oneserver --help
oneserver <命令> --help
```

## 环境要求

- Debian 或 Ubuntu
- systemd
- root 权限
- 可用的 APT 软件源和网络连接
- 从系统仓库安装 Podman：Debian 13、Ubuntu 24.04 或更新版本
- 旧版本系统：使用 Docker，或自行准备 Podman 4.4 及更高版本

## 功能描述

| 类别 | 功能 |
| --- | --- |
| Web 服务 | Caddy、PHP-FPM、Node.js、WordPress |
| 数据服务 | MariaDB、Valkey、数据库与账号管理 |
| 容器 | Docker、Podman、Compose、镜像、容器和数据卷管理 |
| 系统 | UFW、SSH 配置、安全加固、系统更新 |
| 运维 | 状态检查、故障诊断、凭据管理、备份恢复、只读 Web 面板 |

## 更新及卸载

更新可从终端交互菜单（`os`）的“脚本更新”入口执行，也可使用命令行。只读 Web 面板不执行更新或其他系统变更。

```bash
oneserver update check
oneserver update run

oneserver uninstall --id=<组件标识>
oneserver uninstall --all
```

组件需要逐个卸载；`--all` 仅卸载 OneServer 本身，不会批量卸载已安装组件。业务数据和备份不会自动删除。

## 所需依赖

- 系统基础：Bash 4.3 或更高版本、systemd、APT、dpkg、util-linux
- 安装器自动补齐：`curl`、`tar`、`coreutils`、`ca-certificates`
- 可选：`rclone`，仅远程备份需要

## 注意事项

- 变更前使用 `--dry-run` 检查执行内容。
- `--yes` 不会跳过删除、覆盖或清空操作的目标确认。
- 不要手工编辑 OneServer 的状态文件和凭据文件。
- 修改防火墙或 SSH 前，保留第二个 SSH 会话或服务商控制台。
- 恢复前校验备份并确认目标，避免覆盖错误的数据。
- 状态异常时运行 `oneserver doctor`，再查阅[应急手册](docs/OPERATIONS.md)。
- Web 面板监听所有网卡并启用 Basic Auth；应通过防火墙限制来源，并按需配置 HTTPS。

## 许可证

OneServer 使用 [MIT License](LICENSE)。第三方软件及素材适用各自许可证，详见[第三方声明](docs/THIRD_PARTY.md)。
