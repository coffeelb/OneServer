# lib/paths.sh —— L0 常量层：路径的单一来源
#
# L0 零依赖，只有变量赋值。本文件里不得出现函数、条件、命令调用。
# 本文件被 source，不直接执行，因此没有 shebang，也不需要执行位。
#
# 两条不显然的约定：
#
# 1. 不用 `readonly`。lib 模块会被 bootstrap.sh 与单元测试分别 source，
#    `readonly` 让第二次 source 直接报错并被 set -e 带走。规范没有要求
#    readonly，而「重复 source 会炸」是实打实的坑。
#
# 2. **不引入 /etc/oneserver/paths.conf**（D25）。路径可覆盖是为「将来做 deb
#    打包」而设，而 deb 打包在明确不做的列表里。为不存在的需求引入一个 root
#    读取的配置文件，等于凭空增加攻击面。
#
# 这个文件的存在是为了消灭现状里的四种命名（CORE_DIR / ONESERVER_DIR /
# oneserver_DIR / CONFIG_DIR，全都指同一个目录）。

# shellcheck disable=SC2034  # 理由：L0 常量文件的全部变量都由别的模块消费，本文件内必然「未使用」

# --- 程序目录 ---

OS_ROOT='/opt/oneserver'
OS_BIN_DIR="${OS_ROOT}/bin"
OS_LIB_DIR="${OS_ROOT}/lib"
OS_SCRIPT_DIR="${OS_ROOT}/script"
OS_TEMPLATE_DIR="${OS_ROOT}/templates"

# --- 数据目录 ---

OS_STATE_DIR="${OS_ROOT}/state"

# 组件清单。行式格式（D39），一行一个「组件标识 + 键 + 值」三元组。
# `.bak` 是上一版，全文件不可读时回退它。
OS_STATE_FILE="${OS_STATE_DIR}/components.tsv"
OS_STATE_BAK="${OS_STATE_FILE}.bak"
OS_STATE_FILE_MODE='0640'

# 非 root 可读的只读数据（probe 快照等，D44）。唯一放宽到 0755 的目录，
# 因此权限值写在这里，而不是散在写它的模块里。
#
# **在 tmpfs 上，不在 OS_ROOT 下**：这里每一项都是「此刻的快照」，重启之后
# 上一秒的内存占用、容器状态、监听端口全部作废，采集器几秒内重建。实测面板
# 每天往盘上写 676 MB，买的全是一个没人需要的持久性。挂在 /run 下而不是自己
# 挂一个 tmpfs：/run 本来就是 tmpfs，不用新增挂载点，也没有「挂载失败就静默
# 落到盘上」这种查不出来的退路。
#
# 与 /run/oneserver 平级而不是它的子目录：那个是 0750（里面有凭据临时文件），
# 跑 Caddy 的用户连遍历都进不去。
OS_PUBLIC_DIR='/run/oneserver-public'
OS_PUBLIC_DIR_MODE='0755'

# probe 快照：root 跑任何命令时框架顺手落一份，非 root 时读它（D44）。
# 放在 public 里就是为了让非 root 读得到 —— 这也是它必须 0644 且**永不含凭据**的原因。
OS_PROBE_SNAPSHOT="${OS_PUBLIC_DIR}/probe.tsv"

# --- 凭据 ---

OS_SECURE_CONF="${OS_ROOT}/secure.conf"
OS_SECURE_CONF_MODE='0600'

# --- 系统目录 ---

OS_LOCAL_BIN_DIR='/usr/local/bin'
OS_LOG_DIR='/var/log/oneserver'
OS_LOG_DIR_MODE='0750'

# 三个落点各有分工，别在 log.sh 里另起一套命名：
#   主日志   人读的时间线，全部命令混在一起
#   JSONL    机器读的同一条时间线，供只读面板（`oneserver web`）读取
#   审计     os::run 自动产生，定位是**事故追溯**，不是防篡改审计
OS_LOG_MAIN="${OS_LOG_DIR}/oneserver.log"
OS_LOG_JSONL="${OS_LOG_DIR}/oneserver.jsonl"
OS_AUDIT_LOG="${OS_LOG_DIR}/audit.log"

OS_BACKUP_DIR='/var/backups/oneserver'
OS_BACKUP_DIR_MODE='0700'

# 归档目录的布局是 `<type>/<name>/<时间戳>.tar.gz`，**分层而不是把三段拼进
# 文件名**。拼名字的写法（`site-my-blog-20260803-040000.tar.gz`）拆不回来 ——
# 站点名里合法地带着 `-`。分层之后「某个目标有哪些归档」就是列一个目录，
# 保留策略里一条正则都不需要。远端用同一套布局，两边可以直接对照。
#
# 这个布局与归档内的 manifest 一起构成对外承诺：改它 = 已有归档恢复不了。
OS_ARCHIVE_DIR="${OS_BACKUP_DIR}/archives"

# --- 自有 systemd unit 的源文件目录（`own:` 的源在 packaging/systemd/）---
OS_UNIT_SRC_DIR="${OS_ROOT}/packaging/systemd"

# 锁放 /run 不放 /tmp（D23 / K5）：root 用 `>` 打开 /tmp 下的路径会跟随符号链接。
# 单一全局锁，不分域（D27）——apt 本就被 dpkg 串行化，分域只会引入锁顺序问题。
OS_RUN_DIR='/run/oneserver'
OS_RUN_DIR_MODE='0750'
OS_LOCK_FILE="${OS_RUN_DIR}/oneserver.lock"

# 二级菜单选「返回主菜单」时留下的记号，菜单读到就跳过「按回车返回菜单」。
# 放 /run：它是一次派发的瞬时状态，重启即消失，永远不该留在磁盘上。
#
# **按菜单进程 PID 分文件**：这是 root 工具，同时开两个 SSH 会话是常态，而共用
# 一个路径时 A 选「返回上一层」写下的记号会被 B 的派发读走并删掉 —— B 那一条
# 命令跑完就直接跳回列表，用户来不及看输出。OS_FROM_MENU 由菜单置成自己的 PID
# 并导出，子进程继承同一个值，因此两边算出同一个路径。
#
# **非数字一律剔掉**：这个变量来自环境，而框架拿它拼路径再 `: >` 截断。
# 原样代入的话 `OS_FROM_MENU=../../etc/xxx` 就是一条穿出 /run/oneserver 的
# 路径穿越，被截断的是攻击者点名的那个文件。L0 只许赋值，所以用参数展开
# 过滤而不是写判断。
OS_FROM_MENU_ID="${OS_FROM_MENU:-0}"
OS_FROM_MENU_ID="${OS_FROM_MENU_ID//[!0-9]/}"
OS_MENU_BACK_FLAG="${OS_RUN_DIR}/.menu-back.${OS_FROM_MENU_ID:-0}"

# 临时目录放 /run 而不是 /tmp 或 /opt：/run 是 tmpfs，凭据临时文件
# （`--defaults-extra-file` 那种 0600 文件）**永远不落盘**，重启即消失。
# 目录本身 0750 且属主 root，也顺带避开了 K5 的软链问题。
OS_TMP_ROOT="${OS_RUN_DIR}/tmp"

# 要**现场执行**的临时文件放这里，不能放上面那个：systemd 给 /run 挂 noexec，
# 下载的二进制在 tmpfs 上 chmod +x 之后依然是 Permission denied（退出码 126）。
# 在磁盘上，因此**禁止放凭据** —— 凭据仍然只走 OS_TMP_ROOT。
OS_TMP_EXEC_ROOT='/var/tmp/oneserver'

# --- 用户可覆盖的配置 ---
#
# 这两个文件都是**可选**的，缺失是正常状态。加载与校验在 bootstrap.sh（L4），
# 不在这里——校验需要条件判断与命令调用，L0 不允许。

OS_ETC_DIR='/etc/oneserver'
OS_CONF_FILE="${OS_ETC_DIR}/oneserver.conf"
# 名字是 OS_CONF_THEME 而不是 OS_THEME_CONF：规范禁止脚本引用任何
# `OS_THEME_*` 变量，而那条是 [CI] 强制的静态检查。一个叫 OS_THEME_CONF 的
# **路径**会让那条检查要么误伤、要么得为它开个特例 —— 两者都不该为一个命名付。
OS_CONF_THEME="${OS_ETC_DIR}/theme.conf"

# --- 版本与注册表 ---

OS_VERSION_FILE="${OS_ROOT}/VERSION"
OS_API_VERSION_FILE="${OS_LIB_DIR}/API_VERSION"
OS_GROUPS_CONF="${OS_TEMPLATE_DIR}/groups.conf"
