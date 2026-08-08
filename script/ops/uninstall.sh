#!/bin/bash
#
# 卸载一个组件
#
# @command      uninstall
# @name         卸载应用
# @group        app
# @order        30
# @privilege    root
# @requires_lib >= 1.20
# @args         [--id=<组件标识>] [--all] [--purge] [--keep-pkg] [--confirm-uninstall=<组件标识|oneserver>]
# @description  按资源清单反向卸载应用；数据与备份永不自动删除
#

set -Eeuo pipefail
IFS=$'\n\t'
PATH='/usr/sbin:/usr/bin:/sbin:/bin'
export PATH
umask 027

source /opt/oneserver/lib/bootstrap.sh

# ==================================================================
# 这个脚本**不做任何探测、不猜、不按组件名写分支**
# ==================================================================
#
# 它只读 state 里的资源清单并逆序反向执行。这是那份清单存在的
# 全部理由 —— 十三个安装脚本这半年往里记的每一条 `pkg` / `file` / `divert` /
# `alt` / `unit`，兑现的地方就是这里。
#
# **反过来说：装的时候没记，到这里就卸不掉。** 这句话在 CLAUDE.md 的「五问」
# 里写着，在这里变成可执行的事实 —— 本文件里没有一处 `case ${type} in caddy)`。
#
# 顺序是规范定死的，一步都不能调换：
#
#     停止并禁用 unit → 移除 alt → 撤销 divert → 删除 file → purge pkg → 清凭据
#
#   先删 file 再移 alt：update-alternatives 会指向一个不存在的候选，
#                       /usr/bin/node 变成断链
#   先 purge pkg 再撤 divert：dpkg 带着分流记录卸载，留下一个谁也管不到的
#                       xxx.default
#   先清凭据再 purge：卸载过程本身可能要用它们（连库执行 DROP USER）
#
# ==================================================================
# 永不自动删除的东西
# ==================================================================
#
# 用户配置（/etc/caddy/Caddyfile、/etc/php/*/）· 数据与证书（/var/lib/caddy
# 里是 ACME 账户与私钥，删了要重新签发且可能撞上速率限制）· 数据库 ·
# 站点目录 · 备份归档。
#
# **它们不在资源清单里，所以这里根本没有删除它们的能力** —— 这不是靠自觉，
# 是靠规范里「只登记本项目创建的文件」那条规则从源头保证的。
# 本脚本只把它们的位置打出来，由人自己处置。

# ------------------------------------------------------------------

# ==================================================================
# 能卸的与不能卸的
# ==================================================================
#
# state 记的不只是「装过的软件」：`db:<库名>`（建过的库）、`wordpress:<名字>`
# （部署过的站点）、`backup-path:<名字>`（备份目标）、`network`（网络定位）
# 全都登记在同一份清单里。它们不是应用，也没有资源清单。
#
# **判据是资源清单空不空，不是类型白名单。** 这个脚本的全部能力来自那份清单
# （pkg / file / divert / alt / unit），清单空的组件卸下去只会划掉 state 里
# 一行，而实体还躺在磁盘上 —— 那不是卸载，是让用户以为自己清理干净了。
# 更糟的是记录没了之后，备份与恢复再也找不到那个库。
#
# 用类型白名单会两头不准：`firewall`、`auto-updates` 是真能 purge 的（有 pkg）
# 却不由 install_* 提供，而 `db:*` 顶着一个像应用的类型名却什么都卸不掉。
# 问清单，不问名字。
un_removable() {
    local id=${1} kind out
    for kind in pkg file divert alt; do
        out=$(os::state_resources "${id}" "${kind}")
        [[ -n ${out} ]] && return 0
    done
    out=$(os::state_units "${id}")
    [[ -n ${out} ]]
}

# 有可卸资源的组件，结果写 UN_CANDIDATES
UN_CANDIDATES=()
un_candidates() {
    UN_CANDIDATES=()
    local id
    while IFS= read -r id; do
        [[ -n ${id} ]] || continue
        un_removable "${id}" && UN_CANDIDATES+=("${id}")
    done < <(os::state_list)
    return 0
}

# un_elsewhere <组件标识>   这类东西归哪条命令删；没有对应命令时为空
#
# 被挡下来时必须指路。只说「不能在这里卸」等于把人留在原地 —— 他要删的
# 那个东西是真实存在的，只是入口在别处
un_elsewhere() {
    case ${1} in
        db:*) printf 'oneserver mariadb delete --name=%s\n' "${1#*:}" ;;
        wordpress:*) printf 'oneserver site delete\n' ;;
        container:*) printf 'oneserver podman rm（或 docker rm）\n' ;;
        backup-path:*) printf 'oneserver backup remove\n' ;;
        network) printf 'oneserver network\n' ;;
        *) printf '\n' ;;
    esac
}

# 解析用户给的标识。多实例时**列出全部并要求指明完整标识**，
# 禁止猜测、禁止默认全卸——
# `uninstall php` 在装了 8.3 与 8.4 的机器上删掉哪个都是错的。
resolve_id() {
    local __un_out=${1} __un_want=${2}
    un_candidates
    local -a __un_all=(${UN_CANDIDATES[@]+"${UN_CANDIDATES[@]}"})

    if [[ ${#__un_all[@]} -eq 0 ]]; then
        os::die 2 'state 里没有可卸载的组件 —— 数据库、站点这类东西各有各的删除命令'
    fi

    # 完整标识直接命中
    local __un_i
    for __un_i in "${__un_all[@]}"; do
        if [[ ${__un_i} == "${__un_want}" ]]; then
            printf -v "${__un_out}" '%s' "${__un_want}"
            return 0
        fi
    done

    # 指名道姓要一个**登记在案、但没有任何可卸资源**的组件。不能沉默地当它
    # 不存在 —— 那会让用户以为记录丢了，转头去 state rebuild
    if os::state_has "${__un_want}"; then
        local __un_where
        __un_where=$(un_elsewhere "${__un_want}")
        [[ -n ${__un_where} ]] \
            && os::die 2 "「${__un_want}」没有可卸载的资源，它不归这里删。用：${__un_where}"
        os::die 2 "「${__un_want}」在 state 里没有登记任何资源 —— 卸载它只会划掉一行记录，实体不会消失"
    fi

    # 只给了 type：看看有几个**可卸的**实例
    local -a __un_hit=()
    local __un_one
    while IFS= read -r __un_one; do
        [[ -n ${__un_one} ]] || continue
        un_removable "${__un_one}" && __un_hit+=("${__un_one}")
    done < <(os::state_list "${__un_want}")
    if [[ ${#__un_hit[@]} -eq 1 ]]; then
        printf -v "${__un_out}" '%s' "${__un_hit[0]}"
        return 0
    fi
    # 一个 type 下有多个实例：**列出来让人挑**，而不是甩一句「请指明完整标识」。
    # 规范只要求「必须列出全部并要求指明完整标识，禁止猜测或默认全卸」——
    # 用编号选单挑一个，同样是明确指定了完整标识，而且不用人去背 `php:8.4`
    # 这种自己也未必记得的写法。
    if [[ ${#__un_hit[@]} -gt 1 ]]; then
        os::warn "「${__un_want}」下有 ${#__un_hit[@]} 个实例，挑一个"
        local __un_pick=''
        os::select --required --reask --arg id '要卸载哪一个' __un_pick "${__un_hit[@]}"
        printf -v "${__un_out}" '%s' "${__un_pick}"
        return 0
    fi

    # 名字对不上：也列出来让人挑，别让他退出去重来一遍
    os::warn "state 里没有「${__un_want}」"
    local __un_pick=''
    os::select --required --reask --arg id '已登记的组件，挑一个' __un_pick "${__un_all[@]}"
    printf -v "${__un_out}" '%s' "${__un_pick}"
    return 0
}

# 把某个组件的资源读进全局数组。**不做去重之外的任何加工** ——
# 清单里写的是什么就卸什么。
declare -a RES_UNIT=() RES_ALT=() RES_DIVERT=() RES_FILE=() RES_PKG=()
declare -a RES_KEEP=()

collect() {
    local id=${1}
    mapfile -t RES_UNIT < <(os::state_resources "${id}" unit)
    mapfile -t RES_ALT < <(os::state_resources "${id}" alt)
    mapfile -t RES_DIVERT < <(os::state_resources "${id}" divert)
    mapfile -t RES_FILE < <(os::state_resources "${id}" file)
    mapfile -t RES_PKG < <(os::state_resources "${id}" pkg)

    # 「永不自动删除」的那些：安装脚本把位置记在 state 里（`path` / `db`），
    # 卸载只负责把它们指给用户看
    local v
    RES_KEEP=()
    for v in $(os::state_resources "${id}" path); do
        [[ -n ${v} ]] && RES_KEEP+=("目录 ${v}")
    done
    for v in $(os::state_resources "${id}" db); do
        [[ -n ${v} ]] && RES_KEEP+=("数据库 ${v}")
    done
    return 0
}

# 该组件的凭据 key。按命名空间前缀扫，不逐条登记（规范最后一段）——
# 逐条登记漏一条的表现是「卸载完了密码还躺在 secure.conf 里」，
# 没有任何报错、没有任何人会发现。
declare -a RES_SECRET=()

collect_secrets() {
    local id=${1}
    local ns
    ns=$(os::secure_ns "${id}")
    RES_SECRET=()
    local k
    while IFS= read -r k; do
        [[ -n ${k} ]] || continue
        [[ ${k} == "${ns}."* ]] && RES_SECRET+=("${k}")
    done < <(os::secure_list)
    return 0
}

# ------------------------------------------------------------------

do_units() {
    local u
    for u in ${RES_UNIT[@]+"${RES_UNIT[@]}"}; do
        [[ -n ${u} ]] || continue
        # own: 删文件，ext: 只停止禁用—— 前缀不是可选的，
        # 判断该不该删文件全靠它，而删错的代价远大于留孤儿
        os::systemd_remove "${u}" || os::warn "处理 unit ${u} 时出错，继续"
    done
    return 0
}

do_alts() {
    local a link cand
    for a in ${RES_ALT[@]+"${RES_ALT[@]}"}; do
        [[ -n ${a} ]] || continue
        link=${a%%:*}
        cand=${a#*:}
        if [[ -z ${link} || -z ${cand} || ${link} == "${a}" ]]; then
            os::warn "alt 记录格式不对，跳过：${a}"
            continue
        fi
        os::run --allow-fail '移除 alternatives 候选' -- \
            update-alternatives --remove "${link}" "${cand}" || true
    done
    return 0
}

do_diverts() {
    local d
    for d in ${RES_DIVERT[@]+"${RES_DIVERT[@]}"}; do
        [[ -n ${d} ]] || continue
        os::run --allow-fail '撤销 dpkg 分流' -- \
            dpkg-divert --rename --remove "${d}" || true
    done
    return 0
}

do_files() {
    local f
    for f in ${RES_FILE[@]+"${RES_FILE[@]}"}; do
        [[ -n ${f} ]] || continue
        # 绝对路径才删。清单是本机 state 里的，但同样的道理：
        # 相对路径在这里没有意义，而 `rm -f` 一个相对路径删的是当前目录下的东西
        case ${f} in
            /*) ;;
            *)
                os::warn "file 记录不是绝对路径，跳过：${f}"
                continue
                ;;
        esac
        os::run --allow-fail '删除本工具创建的文件' -- rm -f -- "${f}" || true
    done
    return 0
}

do_pkgs() {
    [[ ${#RES_PKG[@]} -gt 0 ]] || return 0
    local -a pkgs=()
    local p
    for p in "${RES_PKG[@]}"; do
        [[ -n ${p} ]] && pkgs+=("${p}")
    done
    [[ ${#pkgs[@]} -gt 0 ]] || return 0

    os::pkg_purge "${pkgs[@]}" || os::warn '有包没能卸干净，详情看日志'
    return 0
}

do_secrets() {
    local k
    for k in ${RES_SECRET[@]+"${RES_SECRET[@]}"}; do
        [[ -n ${k} ]] || continue
        os::secure_del "${k}" || os::warn "删凭据 ${k} 失败"
    done
    return 0
}

# ==================================================================
# --all：卸载本工具自身（计划 6.5）
# ==================================================================
#
# 与卸组件是两件事，所以走一条单独的路径：**本工具自身不在 state 里**
# （state 记的是「本工具装过什么」，它自己不是自己的组件），
# 所以这一段是**唯一**允许出现硬编码路径的地方 —— 那几个路径由
# `install.sh` 写死地放下去，也只能由这里写死地收回来。
#
# 三件事必须说清楚：
#
#   1. **已装的组件不会被卸载**。而且一旦本工具没了，那份资源清单也就没了 ——
#      它们此后只能手工清。所以清单里逐个列出来，让人有机会先去卸组件
#   2. **备份归档永远保留**（`/var/backups/oneserver`）。它是「机器没了之后
#      还能恢复」的东西，删它与卸载工具是两个决定
#   3. `--purge` 才连 `/etc/oneserver` 与 `secure.conf` 一起删。**默认不删**：
#      secure.conf 里是这台机器上所有自动生成的密码，站点还在跑、库还在用，
#      删掉它等于把那些密码永久丢掉
#
# 自删是安全的：`rm -rf /opt/oneserver` 走的是 unlink，而 bash 持着已打开的
# fd，inode 要等进程退出才真正释放（危险的是**覆盖**，不是 unlink —— K13 是
# 前者）。lib 早已 source 进内存，后面不再有任何 source。

self_uninstall() {
    local purge=${1}

    local -a ids=()
    mapfile -t ids < <(os::state_list)

    local -a lines=()
    if [[ ${purge} -eq 1 ]]; then
        lines+=("程序目录 ${OS_ROOT} 整个（含 state 与凭据库）")
    else
        lines+=("程序目录 ${OS_ROOT} 里除 secure.conf 之外的一切（含 state 与 public 快照）")
    fi
    lines+=("入口 /usr/local/bin/oneserver 与 /usr/local/bin/os")
    lines+=("日志目录 ${OS_LOG_DIR}")
    lines+=('logrotate 配置 /etc/logrotate.d/oneserver')
    lines+=('bash 补全 /etc/bash_completion.d/oneserver')
    lines+=("本工具自带的 systemd unit（own:，如备份 timer）")
    if [[ ${purge} -eq 1 ]]; then
        lines+=("配置目录 ${OS_ETC_DIR}")
        lines+=("**凭据库 ${OS_SECURE_CONF} —— 里面是本机所有自动生成的密码**")
    fi

    os::section '卸载 OneServer 自身'
    os::kv '安装位置' "${OS_ROOT}" \
        '版本' "$(cat "${OS_VERSION_FILE}" 2>/dev/null || printf '未知')" \
        '已登记的组件' "${#ids[@]} 个" \
        '连配置与凭据一起删' "$([[ ${purge} -eq 1 ]] && printf '是（--purge）' || printf '否')"

    os::section '以下不会被删除'
    os::info "    备份归档 ${OS_BACKUP_DIR}"
    if [[ ${purge} -ne 1 ]]; then
        os::info "    配置 ${OS_ETC_DIR}"
        os::info "    凭据库 ${OS_SECURE_CONF}（站点还在用里面的密码；要一起删加 --purge）"
    fi
    if [[ ${#ids[@]} -gt 0 ]]; then
        local one
        for one in "${ids[@]}"; do
            os::info "    组件 ${one}（连同它装的包与文件）"
        done
        os::warn '这些组件不会被卸载，而本工具一旦没了，它们的资源清单也就没了 ——'
        os::warn "要让它们能被干净卸掉，先逐个：oneserver uninstall ${ids[0]}"
    fi

    # 同 main()：dry-run 下 destroy_confirm 必然返回 1，那是「预演」不是
    # 「用户放弃」，继续往下走才能让 --all --dry-run 预演出真实会执行的命令
    if ! os::destroy_confirm --arg confirm-uninstall 'oneserver' -- \
        ${lines[@]+"${lines[@]}"}; then
        if [[ ${OS_DRYRUN} -ne 1 ]]; then
            os::info '已取消，什么都没有动'
            os::output 130 removed=no
            return 130
        fi
        os::info '[dry-run] 继续预演下面每一步会执行的命令（内部命令自动跳过，不会真的执行）'
    fi

    # own: 的 unit 先停掉再删文件 —— 留一个指向已删除 ExecStart 的 timer，
    # 会让 systemd 每次触发都记一条失败，而那时已经没有工具能解释它是什么
    local u
    for u in $(os::state_units 'backup'); do
        if [[ ${u} == own:* ]]; then
            os::systemd_remove "${u}" || true
        fi
    done
    local unit
    for unit in "${OS_SYSTEMD_UNIT_DIR}"/oneserver-*.timer "${OS_SYSTEMD_UNIT_DIR}"/oneserver-*.service; do
        [[ -e ${unit} ]] || continue
        os::systemd_remove "own:${unit##*/}" || true
    done

    os::record_change '卸载了 OneServer 自身'
    os::run --allow-fail '删除入口链接' -- rm -f -- /usr/local/bin/oneserver /usr/local/bin/os || true
    os::run --allow-fail '删除 bash 补全' -- rm -f -- /etc/bash_completion.d/oneserver || true
    os::run --allow-fail '删除 logrotate 配置' -- rm -f -- /etc/logrotate.d/oneserver || true

    # **程序目录在前、日志目录在后**：反过来的话，删程序目录这一步已经没有
    # 日志可写了。删完程序目录本进程仍能跑完 —— `rm` 走的是 unlink，
    # bash 持着已打开的 fd，inode 要等进程退出才真正释放（危险的是覆盖，不是
    # unlink，K13 是前者）。最后那条删日志的命令自己写不进日志，框架静默降级
    if [[ ${purge} -eq 1 ]]; then
        os::run --allow-fail '删除配置目录' -- rm -rf -- "${OS_ETC_DIR}" || true
        os::run --allow-fail '删除程序目录' -- rm -rf -- "${OS_ROOT}" || true
    else
        # **凭据库必须留下**：`secure.conf` 就在 $OS_ROOT 里面，
        # 而里面是站点**此刻还在用**的数据库密码 —— 跟着程序目录一起删掉，
        # 等于「卸载一个管理工具」顺手让那些站点永久丢失自己的密码（K1 那一类）。
        # 用 find 排除它，而不是列一串要删的子目录：后者漏掉 .staging / .old
        # 这种更新期间留下的目录，而且每加一个运行时目录就要记得回来补一行
        os::run --allow-fail '删除程序目录（保留凭据库）' -- find "${OS_ROOT}" -mindepth 1 -maxdepth 1 ! -name secure.conf -exec rm -rf {} + || true
    fi
    os::run --allow-fail '删除日志目录' -- rm -rf -- "${OS_LOG_DIR}" || true

    if [[ ${OS_DRYRUN} -eq 1 ]]; then
        os::info '[dry-run] 将卸载 OneServer 自身'
        os::output 0 removed=no purge="${purge}" components="${#ids[@]}" changed=dry-run
        return 0
    fi

    os::ok 'OneServer 已卸载'
    os::info "备份归档仍在 ${OS_BACKUP_DIR}"
    if [[ ${purge} -ne 1 ]]; then
        os::info "配置仍在 ${OS_ETC_DIR}"
        os::info "凭据库仍在 ${OS_SECURE_CONF} —— 站点还在用里面的密码；确认不需要了再删"
    fi
    if [[ ${#ids[@]} -gt 0 ]]; then
        os::warn "${#ids[@]} 个组件仍装在系统上，需要手工清理"
    fi
    os::output 0 removed=yes purge="${purge}" components="${#ids[@]}"
    return 0
}

# ------------------------------------------------------------------

main() {
    local keep_pkg=0
    os::flag --arg keep-pkg && keep_pkg=1
    local purge=0
    os::flag --arg purge && purge=1

    # --all 走另一条路：卸的是本工具自身，不是某个组件。
    # **这一段必须排在问组件之前** —— 原来先无条件问一句「要卸载哪个组件」，
    # 于是 `uninstall --all` 也得先答一个跟它毫无关系的问题
    if os::flag --arg all; then
        self_uninstall "${purge}"
        return $?
    fi

    un_candidates
    [[ ${#UN_CANDIDATES[@]} -gt 0 ]] \
        || os::die 2 'state 里没有可卸载的组件 —— 数据库、站点这类东西各有各的删除命令'

    # 位置参数优先，没给就**从清单里挑**。
    # 不再问「完整标识」：那是让用户去猜一个只有 state 才知道的字符串，
    # 而他手上根本没有那份清单。`--id=php` 这种不完整的写法照旧能用，
    # 由 resolve_id 收敛（多个实例时同样弹清单）
    local want=${1-}
    if [[ -z ${want} ]]; then
        os::select --required --arg id '要卸载哪个组件' want "${UN_CANDIDATES[@]}"
    fi

    local id=''
    resolve_id id "${want}"

    collect "${id}"
    collect_secrets "${id}"

    if [[ ${keep_pkg} -eq 1 ]]; then
        RES_PKG=()
    fi

    # --- 清单（规范：具体路径、条目数，不接受概括）---
    local -a lines=()
    local x
    for x in ${RES_UNIT[@]+"${RES_UNIT[@]}"}; do
        [[ -n ${x} ]] || continue
        case ${x} in
            own:*) lines+=("systemd unit ${x#own:}（停止、禁用并删除 unit 文件）") ;;
            *) lines+=("systemd unit ${x#ext:}（只停止与禁用，不删文件）") ;;
        esac
    done
    for x in ${RES_ALT[@]+"${RES_ALT[@]}"}; do
        [[ -n ${x} ]] && lines+=("alternatives 候选 ${x%%:*} → ${x#*:}")
    done
    for x in ${RES_DIVERT[@]+"${RES_DIVERT[@]}"}; do
        [[ -n ${x} ]] && lines+=("dpkg 分流 ${x}（撤销）")
    done
    for x in ${RES_FILE[@]+"${RES_FILE[@]}"}; do
        [[ -n ${x} ]] && lines+=("文件 ${x}")
    done
    for x in ${RES_PKG[@]+"${RES_PKG[@]}"}; do
        [[ -n ${x} ]] && lines+=("软件包 ${x}（apt-get purge）")
    done
    for x in ${RES_SECRET[@]+"${RES_SECRET[@]}"}; do
        [[ -n ${x} ]] && lines+=("凭据 ${x}")
    done

    # 版本从 state 读，**不探测**（§3 不变量 8：卸载只读资源清单）。
    # 这一行纯粹是给人看的，而 probe::component_version 会真去跑
    # `caddy version` / `node --version` 这类外部命令：组件此刻正坏着的时候
    # 它要么超时拖住整个卸载，要么给出一个误导的版本号 —— 而卸载动作本身
    # 一个字节都不依赖它。安装时版本已经写进 state 了。
    os::section "卸载 ${id}"
    local shown_ver
    shown_ver=$(os::state_get "${id}" version)
    os::kv '组件标识' "${id}" \
        '当前版本' "${shown_ver:-未知}" \
        '待处理资源' "${#lines[@]} 项"

    if [[ ${#lines[@]} -eq 0 ]]; then
        os::warn "${id} 在 state 里没有登记任何资源 —— 只会把它从组件清单里划掉"
        os::warn '如果它是本工具装的，那说明当初的安装脚本漏记了资源'
    fi

    # --- 不会被删的，逐条指出位置 ---
    if [[ ${#RES_KEEP[@]} -gt 0 ]]; then
        os::section '以下不会被删除'
        for x in "${RES_KEEP[@]}"; do
            os::info "    ${x}"
        done
        os::info '数据、配置、证书与备份一律由你自己处置'
    fi

    # --- 确认：打全名，--yes 对它无效（规范第 3、4 条）---
    #
    # dry-run 下 os::destroy_confirm 打完清单必然返回 1（它压根不会真的问）——
    # 那不是「用户放弃」，是「预演」。两者当年被同一个 `if ! ...; then` 分支
    # 处理，于是 uninstall 这个最危险的命令反而是唯一一个 dry-run 什么都
    # 预演不出来、还以 130（「用户取消」）退出的命令（B-M1）。
    if ! os::destroy_confirm --arg confirm-uninstall "${id}" -- \
        ${lines[@]+"${lines[@]}"}; then
        if [[ ${OS_DRYRUN} -ne 1 ]]; then
            os::info '已取消，什么都没有动'
            os::output 130 id="${id}" removed=no
            return 130
        fi
        os::info '[dry-run] 继续预演下面每一步会执行的命令（内部命令自动跳过，不会真的执行）'
    fi

    # --- 逆序执行（顺序不可调换）---
    do_units
    do_alts
    do_diverts
    do_files
    do_pkgs
    # 凭据放在 purge 之后：卸载过程本身可能要用它们
    do_secrets

    # os::state_del 内部已有 dry-run 守卫，dry-run 下自己会打 [dry-run] 且不写盘
    os::state_del "${id}" || os::warn "从 state 里删除 ${id} 失败"

    if [[ ${OS_DRYRUN} -eq 1 ]]; then
        os::info "[dry-run] 将卸载 ${id}"
        os::output 0 id="${id}" removed=no resources="${#lines[@]}" changed=dry-run
        return 0
    fi

    os::ok "${id} 已卸载"
    if [[ ${#RES_KEEP[@]} -gt 0 ]]; then
        os::info '上面列出的数据与配置仍在原处'
    fi
    os::output 0 id="${id}" removed=yes resources="${#lines[@]}"
    return 0
}

main "$@"
