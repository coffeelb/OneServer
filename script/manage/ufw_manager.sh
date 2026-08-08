#!/bin/bash
#
# UFW 防火墙管理
#
# @command      firewall
# @name         防火墙
# @group        security
# @order        20
# @privilege    root
# @requires_lib >= 1.26
# @provides     firewall
# @provides_unit ext:ufw.service
# @args         [--action=<status|allow|delete|reload|enable|disable|restart|uninstall>] [--ports=<端口或规则序号列表>] [--proto=<both|tcp|udp>] [--from=<CIDR>] [--ambiguous=<num|port>] [--confirm-delete] [--confirm-delete-rules] [--confirm-enable] [--disable-firewall=<y|n>] [--confirm-uninstall-firewall=<确认串>]
# @description  增删规则、启停与重启防火墙、装卸 UFW
#

set -Eeuo pipefail
IFS=$'\n\t'
PATH='/usr/sbin:/usr/bin:/sbin:/bin'
export PATH
umask 027

source /opt/oneserver/lib/bootstrap.sh

# ------------------------------------------------------------------
# ufw 的输出在不同 locale 下措辞不同，而下面要靠文本判定结果。
# 所有调用统一注入 LC_ALL=C，别指望机器上的 locale 是什么。
readonly UFW_ENV='LC_ALL=C'

readonly UFW_UNIT='ufw.service'

# 装 ufw 的是本脚本，所以这份组件记录归它维护 —— uninstall 按这份清单
# 反向 purge，登记与卸载必须在同一个文件里，分居两处迟早对不上
readonly FIREWALL_ID='firewall'

# Docker 把自己的 DNAT/FORWARD 规则插在 UFW 的 INPUT 链之前，`docker run -p`
# 发布的端口因此完全绕过这份规则表 —— 用户看着 `default deny incoming`，
# 实际上被 -p 发布过的端口仍然全网可达。只在这台机器确实有 docker 时提示：
# 判据用 probe::component_version docker（lib/probe.sh 现成接口，认 dockerd
# 而不是 docker 命令，理由见该函数注释），没装则空字符串，不新增探测接口。
warn_docker_bypass() {
    probe::component_version docker
    [[ -n ${OS_PROBE_VALUE} ]] || return 0
    os::warn 'docker 发布的端口（-p）不经过 UFW 的 INPUT 链，这份规则表管不到它们。要收住这个口子，用 oneserver safe network 把容器端口绑定到指定地址（写的是 /etc/docker/daemon.json 的 "ip"）'
    return 0
}

# 上一次 ufw_apply 是否真的改变了系统状态（新增/真删掉了一条规则），
# 而不是命中「本来就是这样」。**调用方靠它决定要不要注册回滚、要不要重载**——
# 回滚一条「本来就存在」的规则会删掉用户自己加的东西；
# 全部规则都命中「已存在」时还去 reload 是一次没必要的 netfilter 重建。
OS_UFW_APPLY_CHANGED=0

# ufw 的退出码不足以判断结果：加一条已存在的规则也返回 0，
# 删一条不存在的规则同样返回 0。**必须看输出文本**，所以这里用
# os::run_out 而不是 os::run —— 「有副作用且需要 stdout」正是它的格子（D9）。
ufw_apply() {
    local label=${1} mode=${2}
    shift 2
    OS_UFW_APPLY_CHANGED=0

    # **desc 必须是固定字符串**（规范最后一句，lint 有检查）。所以这里按
    # mode 分两支各写一个字面量，而不是把拼好的 label 传进去。
    # 丢的只是 desc 里的端口号 —— 审计日志记的是渲染后的整条命令
    # （`ufw allow 8080/tcp`），一个字都没少；屏幕上的 label 也照旧带端口号。
    #
    # 不写 out=$(os::run_out ...)：那是子 shell，OS_RUN_STATUS 与
    # OS_RUN_SKIPPED 都出不来。结果在 OS_RUN_OUTPUT 里。
    if [[ ${mode} == delete ]]; then
        os::run_out --allow-fail --env "${UFW_ENV}" '删除 UFW 规则' -- ufw "$@" || true
    else
        os::run_out --allow-fail --env "${UFW_ENV}" '放行 UFW 端口' -- ufw "$@" || true
    fi
    local out=${OS_RUN_OUTPUT}
    local -i rc=${OS_RUN_STATUS}

    # dry-run 下命令没跑，输出必然是空的 —— 不能拿它去判定结果，
    # 否则会打出「✓ 放行 8080/tcp」，让预演看起来像已经做完了（D15）。
    # 按「会改变」保守处理：dry-run 下游的 os::run（reload）本就会被各自的
    # dry-run 分支跳过，这里不拦不会造成真实副作用，拦了反而会让预演
    # 少打一行「将要 reload」。
    if [[ ${OS_RUN_SKIPPED} -eq 1 ]]; then
        OS_UFW_APPLY_CHANGED=1
        return 0
    fi

    if [[ ${mode} == delete ]]; then
        case ${out} in
            # ufw **未激活**时删一条存在的规则打的是「Rules updated」，
            # 只有激活状态下才打「Rule deleted」—— 同一个动作、同样的退出码 0，
            # 两种措辞。只认后者的话，刚装完还没 enable 的机器上，
            # 每一次成功的删除都会被报成失败（F4 回归时在干净容器里撞见）。
            *'Rule deleted'* | *'Rules updated'*)
                OS_UFW_APPLY_CHANGED=1
                os::ok "${label}"
                ;;
            *'Could not delete'* | *'not found'* | *'non-existent'*)
                os::info "${label}：规则不存在，已是目标状态"
                ;;
            *)
                os::err "${label} 失败"
                os::debug "ufw 输出：${out}"
                return 1
                ;;
        esac
        return 0
    fi

    if [[ ${rc} -ne 0 ]]; then
        os::err "${label} 失败"
        os::debug "ufw 输出：${out}"
        return 1
    fi
    case ${out} in
        *Skipping*) os::info "${label}：规则已存在，已是目标状态" ;;
        *)
            OS_UFW_APPLY_CHANGED=1
            os::ok "${label}"
            ;;
    esac
    return 0
}

# 把 "80,443 8080" 这样的输入洗成端口数组，顺带剥掉 /tcp 之类的后缀
parse_ports() {
    local raw=${1//,/ }
    local -a out=()
    local p
    local IFS=' '
    for p in ${raw}; do
        p=${p%%/*}
        [[ ${p} =~ ^[0-9]+$ ]] || {
            os::die 2 "端口「${p}」不是数字"
        }
        ((p >= 1 && p <= 65535)) || os::die 2 "端口 ${p} 超出范围"
        out+=("${p}")
    done
    [[ ${#out[@]} -gt 0 ]] || os::die 2 "没有给出任何端口"
    printf '%s\n' "${out[@]}"
}

# 用空格把若干个词连起来。**文件头把 IFS 设成了 $'\n\t'**，所以 `${arr[*]}`
# 在这个脚本里是用换行连的 —— 打进 JSON 字段与屏幕消息里就是一串折行（D91）。
# 把 `local IFS=' '` 关在一个函数里，别让它漏到别的调用上。
ufw_join() {
    local IFS=' '
    printf '%s' "$*"
    return 0
}

# 在听、但不在放行清单里的端口，一行一个。
ufw_not_allowed() {
    local listening=${1}
    shift
    local -a allowed=("$@")
    local IFS=' '
    local p q found
    for p in ${listening}; do
        found=''
        for q in ${allowed[@]+"${allowed[@]}"}; do
            [[ ${p} == "${q}" ]] && found=1
        done
        [[ -n ${found} ]] || printf '%s\n' "${p}"
    done
    return 0
}

# ------------------------------------------------------------------

action_status() {
    probe::ufw_active
    local active=${OS_PROBE_VALUE}
    probe::ufw_rules
    local rules=${OS_PROBE_VALUE}

    os::section 'UFW 防火墙'
    os::kv '运行状态' "$([[ ${active} == yes ]] && printf '已激活' || printf '未运行')" \
        '数据来源' "$(probe::describe)"
    warn_docker_bypass
    if [[ ${OS_OUTPUT} == json ]]; then
        os::output 0 active="${active}"
        return 0
    fi
    printf '%s\n' "${rules}"
    return 0
}

action_reload() {
    os::record_change '重载了 UFW 规则'
    os::run --env "${UFW_ENV}" '重载 UFW 配置' -- ufw reload
    os::ok 'UFW 配置已重载'
    return 0
}

# 停用。**这是降低安全性的操作**（§15），所以默认答案是否，并且把后果说成
# 用户看得懂的话 —— 「ufw disable」四个字不会让任何人意识到机器随即全裸
action_disable() {
    probe::ufw_active
    if [[ ${OS_PROBE_VALUE} != yes ]]; then
        os::ok 'UFW 本来就没在跑，无需变更'
        os::output 0 active=no changed=no
        return 0
    fi

    probe::listening_ports
    os::warn "停用之后这些端口会立刻对公网开放：${OS_PROBE_VALUE:-（探测不到）}"
    os::confirm --arg disable-firewall '确认停用防火墙？' n \
        || os::die 130 '已取消，防火墙仍在运行'

    # 「禁止自动回滚」类：回滚 = 再把防火墙打开。规则还在 /etc/ufw 里，
    # 重新启用即恢复，所以停用本身不需要先备份什么
    os::record_change '停用了 UFW 防火墙'
    os::run --env "${UFW_ENV}" '停用 UFW' -- ufw disable
    os::ok 'UFW 已停用，规则仍保留在 /etc/ufw，重新启用即生效'
    os::output 0 active=no changed=yes
    return 0
}

# 重启。走 systemd 而不是 `ufw disable && ufw enable`：后者中间有一个真空窗口，
# 而且一旦第二条失败就把机器留在无防火墙状态
action_restart() {
    probe::unit_exists "${UFW_UNIT}"
    [[ ${OS_PROBE_VALUE} == yes ]] || os::die 3 "找不到 ${UFW_UNIT}，ufw 可能没装"

    os::systemd_restart "${UFW_UNIT}"

    probe::ufw_active
    local active=${OS_PROBE_VALUE}
    if [[ ${active} == yes ]]; then
        os::ok "${UFW_UNIT} 已重启，防火墙在运行"
    else
        # 重启一个 disabled 的 ufw 是合法操作，unit 会起来但规则不生效。
        # 报成功而不说这句，用户会以为防火墙已经在保护机器了
        os::warn "${UFW_UNIT} 已重启，但 ufw 仍是未启用状态 —— 规则一条都不生效，选「启用防火墙」才会真的挡"
    fi
    os::output 0 active="${active}" changed=yes
    return 0
}

# 卸载。**purge 会连 /etc/ufw 下的规则一起删掉**，那是用户自己攒的资产、
# 不可重建，所以走 os::destroy_confirm（打全名 + --force-destroy，`--yes` 无效）
# 而不是普通确认。停用排在 purge 之前：先把链撤干净，再删包。
action_uninstall() {
    probe::package_installed ufw
    if [[ ${OS_PROBE_VALUE} != yes ]]; then
        os::ok 'ufw 没有安装，无需变更'
        os::output 0 installed=no changed=no
        return 0
    fi

    probe::ufw_active
    local active=${OS_PROBE_VALUE}

    os::destroy_confirm --arg confirm-uninstall-firewall 'ufw' -- \
        '卸载 ufw 软件包（apt purge）' \
        '删除 /etc/ufw 下的全部规则与配置（purge 的一部分，不可恢复）' \
        "$([[ ${active} == yes ]] && printf '先停用防火墙，此后所有监听端口对公网开放' || printf '防火墙当前未启用，卸载不改变暴露面')"

    if [[ ${active} == yes ]]; then
        os::record_change '停用了 UFW 防火墙'
        os::run --env "${UFW_ENV}" '停用 UFW' -- ufw disable
    fi

    # 「禁止自动回滚」类：ufw 可能是用户自己装的，装回去也补不回被 purge 的规则
    os::record_change '卸载了 ufw 软件包'
    os::pkg_purge ufw || os::die 1 '卸载 ufw 失败'

    # state 记录的是系统事实（D125）：包没了，登记也就不再成立
    os::state_del "${FIREWALL_ID}"
    os::ok 'ufw 已卸载，规则与配置一并删除'
    os::output 0 installed=no changed=yes
    return 0
}

# 组装一次 ufw 调用的参数。--from 给了就走 proto/from/to 的完整写法，
# 那是原来「专家模式」唯一比标准写法多出来的能力（限制来源）。
ufw_args() {
    local verb=${1} port=${2} proto=${3} from=${4-}
    if [[ -n ${from} ]]; then
        printf '%s\n' "${verb}" proto "${proto}" from "${from}" to any port "${port}"
    else
        printf '%s\n' "${verb}" "${port}/${proto}"
    fi
    return 0
}

action_allow() {
    local ports_input='' proto='' from=''
    os::ask --arg ports '要放行的端口（多个用空格或逗号隔开）' ports_input
    os::select --arg proto '协议' proto 'both=TCP 与 UDP' 'tcp=仅 TCP' 'udp=仅 UDP'
    os::ask --arg from '限制来源 IP/CIDR（留空表示不限制）' from ''

    local -a ports=()
    mapfile -t ports < <(parse_ports "${ports_input}")

    local -a protos=()
    case ${proto} in
        tcp) protos=(tcp) ;;
        udp) protos=(udp) ;;
        *) protos=(tcp udp) ;;
    esac

    local port pr
    local -a args=()
    local -i any_changed=0
    for port in "${ports[@]}"; do
        for pr in "${protos[@]}"; do
            mapfile -t args < <(ufw_args allow "${port}" "${pr}" "${from}")
            ufw_apply "放行 ${port}/${pr}" allow "${args[@]}"
            # 加规则属「必须回滚」类，但仅限**本次真的新增**的那一条：
            # ufw_apply 已经能区分「新增」与「Skipping（已存在）」，命中后者
            # 说明这条规则是用户早就有的，回滚会把它删掉
            if [[ ${OS_UFW_APPLY_CHANGED} -eq 1 ]]; then
                # 经 os::run 而不是裸命令：回滚动作本身也是副作用，
                # 不该绕开审计日志与脱敏（§10）
                os::defer os::run --allow-fail '回滚：撤销本次新放行的规则' -- \
                    ufw delete allow "${port}/${pr}"
                any_changed=1
            fi
        done
    done

    if ((any_changed == 1)); then
        os::run --env "${UFW_ENV}" '重载 UFW 使规则生效' -- ufw reload
    else
        os::info '全部规则已存在，跳过 reload：没有变化就不必重建 netfilter 规则'
    fi
    os::ok "已处理 ${#ports[@]} 个端口"
    os::output 0 ports="$(ufw_join "${ports[@]}")" proto="${proto}"
    return 0
}

# 规则列表里最大的序号。列表形如 `[ 6] Anywhere  ALLOW FWD  10.88.0.0/16`
rules_max_index() {
    local line n max=0
    while IFS= read -r line; do
        [[ ${line} =~ ^\[[[:space:]]*([0-9]+)\] ]] || continue
        n=${BASH_REMATCH[1]}
        ((n > max)) && max=${n}
    done <<<"${1}"
    printf '%d' "${max}"
}

# 某个序号那一行的原文，没有就是空
rule_line() {
    local want=${1} line n
    while IFS= read -r line; do
        [[ ${line} =~ ^\[[[:space:]]*([0-9]+)\] ]] || continue
        n=${BASH_REMATCH[1]}
        [[ ${n} -eq ${want} ]] && {
            printf '%s' "${line}"
            return 0
        }
    done <<<"${2}"
    return 1
}

# 把用户输入拆成「序号」与「端口」两拨，结果写进调用方的 nums / ports。
#
# 判据是**落不落在当前列表的序号范围内**。两者都可能命中时（比如列表有 22 条，
# 而 22 又是个常见端口）**当场问，不猜** —— 猜错的两个方向都很糟：
# 当成端口会删掉一组本不该动的规则，当成序号会删掉列表里完全不相干的一行。
split_nums_and_ports() {
    local raw=${1//,/ } rules=${2}
    local -i max
    max=$(rules_max_index "${rules}")

    local p
    local -a maybe=()
    local IFS=' '
    for p in ${raw}; do
        p=${p%%/*}
        [[ ${p} =~ ^[0-9]+$ ]] || os::die 2 "「${p}」既不是端口也不是序号"
        if ((p >= 1 && p <= max)); then
            maybe+=("${p}")
            continue
        fi
        ((p >= 1 && p <= 65535)) || os::die 2 "端口 ${p} 超出范围"
        ports+=("${p}")
    done

    # 两可的值**一次问清，不逐个问**：逐个问就得给每个值一个参数名，
    # 而参数名是动态的话 @args 里声明不了，非交互下根本传不进来。
    if [[ ${#maybe[@]} -gt 0 ]]; then
        local answer=''
        for p in "${maybe[@]}"; do
            os::info "第 ${p} 条是：$(rule_line "${p}" "${rules}")"
        done
        # **必须 --required**：不加的话非交互下会默默取第一项，
        # 于是 `--ports=22` 在规则够多的机器上删掉的是第 22 条而不是端口 22，
        # 而且不会有任何提示。两可的值没有安全的默认答案。
        os::select --required --arg ambiguous "「${maybe[*]}」按哪种理解？" answer \
            'num=规则序号' 'port=端口号'
        for p in "${maybe[@]}"; do
            [[ ${answer} == num ]] && nums+=("${p}") || ports+=("${p}")
        done
    fi

    [[ ${#nums[@]} -gt 0 || ${#ports[@]} -gt 0 ]] || os::die 2 '没有给出任何端口或序号'
    return 0
}

# 按序号删。**必须从大到小** —— ufw 删掉一条之后，它后面的规则编号全部前移，
# 按输入顺序删的话第二条起就落到别的规则上了，而且删错了不会有任何提示。
delete_by_number() {
    local rules=${1}
    shift
    local -a sorted=()
    mapfile -t sorted < <(printf '%s\n' "$@" | sort -rn -u)

    probe::ssh_port
    local ssh_port=${OS_PROBE_VALUE}

    local n line
    local -a lines=()
    for n in "${sorted[@]}"; do
        line=$(rule_line "${n}" "${rules}") || os::die 2 "规则列表里没有第 ${n} 条"
        # 序号选中 SSH 那一行同样拒绝 —— 换条路进来不该换个结果
        if [[ -n ${ssh_port} && ${line} == *"${ssh_port}"* ]]; then
            os::die 2 "第 ${n} 条是当前 SSH 管理端口（${ssh_port}）的规则，拒绝删除"
        fi
        lines+=("${line}")
    done

    # 确认时显示整行原文。用户输的是数字，脑子里想的是规则 ——
    # 只回显数字的话，他核对不了自己有没有输错
    os::section '将删除这几条'
    for line in "${lines[@]}"; do
        os::info "    ${line}"
    done
    os::confirm --arg confirm-delete-rules '确认删除？' n || os::die 130 '已取消'

    for n in "${sorted[@]}"; do
        # 删规则属「禁止自动回滚」类：那条规则是不是本次会话加的、原来长什么样，
        # 框架都不知道，猜着加回去比不加更危险
        os::record_change "删除了 UFW 规则第 ${n} 条"
        os::run --env "${UFW_ENV}" '按序号删除 UFW 规则' -- ufw --force delete "${n}"
    done
    os::ok "已删除 ${#sorted[@]} 条规则"
    return 0
}

action_delete() {
    local ports_input='' proto='' from=''

    # 删之前先把现有规则原样打出来 —— 让用户看着真实清单做决定，
    # 而不是凭记忆输端口号
    probe::ufw_rules
    local rules=${OS_PROBE_VALUE}
    if [[ ${OS_OUTPUT} != json ]]; then
        os::section '当前规则'
        printf '%s\n' "${rules}"
    fi

    os::ask --arg ports '要删除的端口，或规则序号（多个用空格或逗号隔开）' ports_input

    # 输入里的序号先摘出来单独走一条路。**按端口删对没有端口的规则无能为力**：
    # `Anywhere ALLOW FWD 10.88.0.0/16` 这种转发规则压根没有端口可输，
    # route 规则的 tuple 也跟 `delete allow <口>/<协议>` 对不上 —— 列表里
    # 看得见却删不掉，是这个界面最没道理的地方。
    local -a nums=() ports=()
    split_nums_and_ports "${ports_input}" "${rules}"

    # 序号那一半：按序号删，**从大到小**。删掉一条之后它后面的编号会全部
    # 前移，按输入顺序删的话第二条起就删到别的规则上了。
    if [[ ${#nums[@]} -gt 0 ]]; then
        delete_by_number "${rules}" "${nums[@]}"
    fi
    [[ ${#ports[@]} -gt 0 ]] || {
        os::run --env "${UFW_ENV}" '重载 UFW 使变更生效' -- ufw reload
        os::output 0 rules="$(ufw_join "${nums[@]}")"
        return 0
    }

    os::select --arg proto '协议' proto 'both=TCP 与 UDP' 'tcp=仅 TCP' 'udp=仅 UDP'
    os::ask --arg from '当初限制的来源 IP/CIDR（留空表示未限制）' from ''

    # SSH 端口保护。删掉它就等于把自己锁在门外，而且是**在远程操作时**——
    # 这不是「危险」，是不可恢复。所以不给确认选项，直接拒绝。
    probe::ssh_port
    local ssh_port=${OS_PROBE_VALUE}
    local port
    for port in "${ports[@]}"; do
        if [[ ${port} == "${ssh_port}" ]]; then
            os::die 2 "端口 ${port} 是当前的 SSH 管理端口，拒绝删除（改端口请用「服务器安全设置」）"
        fi
    done

    os::confirm --arg confirm-delete "确认删除端口 ${ports[*]} 的规则？" n \
        || os::die 130 '已取消'

    local -a protos=()
    case ${proto} in
        tcp) protos=(tcp) ;;
        udp) protos=(udp) ;;
        *) protos=(tcp udp) ;;
    esac

    local pr
    local -a args=()
    local -i any_changed=0
    for port in "${ports[@]}"; do
        for pr in "${protos[@]}"; do
            mapfile -t args < <(ufw_args allow "${port}" "${pr}" "${from}")
            # 删规则属「禁止自动回滚」类：那条规则是不是本次会话加的、
            # 原来长什么样，框架都不知道，猜着加回去比不加更危险
            os::record_change "删除了 UFW 规则 ${port}/${pr}"
            ufw_apply "删除 ${port}/${pr}" delete delete "${args[@]}"
            [[ ${OS_UFW_APPLY_CHANGED} -eq 1 ]] && any_changed=1
        done
        # 旧版本可能加过不带协议的通用规则，一并清掉
        os::run_out --allow-fail --env "${UFW_ENV}" '清理端口的通用规则' \
            -- ufw delete allow "${port}" || true
        [[ ${OS_RUN_SKIPPED} -ne 1 && ${OS_RUN_OUTPUT} == *'Rule deleted'* ]] && any_changed=1
    done

    if ((any_changed == 1)); then
        os::run --env "${UFW_ENV}" '重载 UFW 使变更生效' -- ufw reload
    else
        os::info '没有规则被真的删掉，跳过 reload'
    fi
    os::ok "已处理 ${#ports[@]} 个端口"
    os::output 0 ports="$(ufw_join "${ports[@]}")" proto="${proto}"
    return 0
}

# 启用防火墙。**在 F4 批次 4 补上的**：此前这个脚本能加规则、能删规则、
# 能重载，唯独没有「把防火墙打开」——而规则加在一个没启用的 ufw 上，
# 一条都不生效。旧 safe.sh 里那段 UFW 配置就是干这件事的，移植时按边界
# 归到这里（安全设置那边只读它的状态，见 script/ops/safe.sh 的头部说明）。
#
# 三条硬要求：
#   1. **SSH 端口自动进放行清单**，不问 —— 启用一个不放行 SSH 的防火墙，
#      等于在远程操作时按下自毁按钮
#   2. **启用前把「正在听、但不在清单里」的端口指名道姓列出来**。
#      不列的话这就是一次盲操作，用户要等到某个服务连不上才知道关掉了什么
#   3. 先放行、再启用。顺序反了中间有一个窗口期是「全拒绝」
action_enable() {
    probe::ufw_active
    local active=${OS_PROBE_VALUE}

    probe::ssh_port
    local ssh_port=${OS_PROBE_VALUE}

    local ports_input=''
    os::ask --arg ports "除 SSH（${ssh_port}）外还要放行哪些 TCP 端口（回车跳过）" ports_input ''

    local -a ports=("${ssh_port}")
    if [[ -n ${ports_input//[[:space:]]/} ]]; then
        local -a extra=()
        mapfile -t extra < <(parse_ports "${ports_input}")
        ports+=("${extra[@]}")
    fi

    # 会被挡在门外的端口。probe::listening_ports 给的是「现在真的在听」的，
    # 与用户脑子里的「我装了什么」比，前者才是启用防火墙之后会断的那一批
    probe::listening_ports
    local -a blocked=()
    mapfile -t blocked < <(ufw_not_allowed "${OS_PROBE_VALUE}" "${ports[@]}")

    local p
    os::section '防火墙启用'
    os::kv '默认策略' '入站拒绝 · 出站允许' \
        '放行端口' "$(ufw_join "${ports[@]}")/tcp" \
        'SSH 端口' "${ssh_port}" \
        '当前状态' "$([[ ${active} == yes ]] && printf '已启用' || printf '未启用')"

    if [[ ${#blocked[@]} -gt 0 ]]; then
        os::warn "以下端口正在监听，但不在放行清单里 —— 启用后将无法从外部访问："
        for p in "${blocked[@]}"; do
            os::warn "    ${p}"
        done
        os::info "要放行就重来一次并带上：--ports=$(ufw_join "${blocked[@]}")"
    fi

    # 默认策略属「禁止自动回滚」类，同下面的启用：回滚 = 把入站策略改回允许，
    # 是在失败路径上降低安全性。之前这一步既不 defer 也不 record_change，
    # 出问题时变更清单里看不出策略已经改了
    os::record_change '设置了 UFW 默认入站策略为拒绝'
    os::run --env "${UFW_ENV}" '设置默认入站策略为拒绝' -- ufw default deny incoming
    os::run --env "${UFW_ENV}" '设置默认出站策略为允许' -- ufw default allow outgoing

    local -a args=()
    local -i any_changed=0
    for p in "${ports[@]}"; do
        mapfile -t args < <(ufw_args allow "${p}" tcp '')
        ufw_apply "放行 ${p}/tcp" allow "${args[@]}"
        if [[ ${OS_UFW_APPLY_CHANGED} -eq 1 ]]; then
            any_changed=1
            # SSH 端口永不注册回滚：即使这次是新增的，一旦后续步骤失败
            # （典型是 `ufw reload` 语法错误），回滚会当场删掉刚放行的 SSH
            # 规则——默认策略这时已经是 deny，当前 SSH 会话是已建立连接
            # 所以不断，但下一次连接就进不来了。这条底线比「回滚要精确」更高优先。
            if [[ ${p} != "${ssh_port}" ]]; then
                # 经 os::run 而不是裸命令：回滚动作本身也是副作用，
                # 不该绕开审计日志与脱敏（§10）
                os::defer os::run --allow-fail '回滚：撤销本次新放行的规则' -- \
                    ufw delete allow "${p}/tcp"
            fi
        fi
    done

    if [[ ${active} == yes ]]; then
        if ((any_changed == 1)); then
            os::run --env "${UFW_ENV}" '重载 UFW 使规则生效' -- ufw reload
            os::ok 'UFW 本来就是启用状态，规则已更新'
        else
            os::ok 'UFW 本来就是启用状态，规则已是目标状态，无需重载'
        fi
    else
        os::confirm --arg confirm-enable '现在启用防火墙？清单之外的入站连接将被拒绝' y \
            || os::die 130 '已取消，规则已写入但防火墙未启用'
        # 启用防火墙属「禁止自动回滚」类：回滚 = 关掉防火墙，
        # 那是在失败路径上降低安全性
        os::record_change '启用了 UFW 防火墙'
        os::run --env "${UFW_ENV}" '启用 UFW' -- ufw --force enable
        os::ok 'UFW 已启用，并已设置为开机自启'
        warn_docker_bypass
    fi

    os::output 0 ports="$(ufw_join "${ports[@]}")" ssh_port="${ssh_port}" active=yes
    return 0
}

# ------------------------------------------------------------------

main() {
    # ufw 不在则装。改走 os::pkg_install：直接 apt-get 会绕开 needrestart
    # 静默环境变量（Ubuntu 上无 TTY 时可能弹交互框，这条命令常跑在 cron 里）、
    # universe 源探测、`-qq`，装上的包也不会进 OS_PKG__INSTALLED —— 资源
    # 清单看不到它。os::pkg_install 自带幂等与临界区，不必再手写一遍。
    #
    # **装上了就登记**：uninstall 只认 state 里的资源清单，这一步不记账，
    # 本工具替用户装的这个包就再也卸不掉（§12）。
    # **本来就装着的不登记**：那是用户自己的东西，记一笔等于日后去 purge
    # 一个不属于自己的包 —— state 记的是「本工具装过什么」，不是「机器上有什么」。
    probe::package_installed ufw
    if [[ ${OS_PROBE_VALUE} != yes ]]; then
        os::pkg_install ufw
        probe::package_version ufw
        os::state_set "${FIREWALL_ID}" version="${OS_PROBE_VALUE}" method=apt
        local pkg
        while IFS= read -r pkg; do
            [[ -n ${pkg} ]] || continue
            os::state_resource_add "${FIREWALL_ID}" pkg "${pkg}"
        done < <(os::pkg_installed_names)
    fi

    # 位置参数优先；没给才走交互（--action=... 由 os::select 自己从命令行取）。
    # 不去碰 OS_ARG_MAP —— 那是框架内部的东西，脚本伸手进去就是越层了。
    local action=${1-}
    if [[ -n ${action} ]]; then
        dispatch "${action}"
        return 0
    fi

    # 日常动作在前，生命周期动作在后：放行端口每周都可能按，卸载 ufw 一辈子按一次。
    # 两类混排的话，最常用的那条每次都要在一串危险选项里找
    os::action_menu --overview action_status --arg action '操作' dispatch \
        'allow=放行端口' 'delete=删除规则' 'reload=重载配置' \
        'enable=启用防火墙' 'disable=停用防火墙' \
        'restart=重启防火墙' 'uninstall=卸载 ufw'
}

dispatch() {
    case ${1} in
        status) action_status ;;
        allow) action_allow ;;
        delete) action_delete ;;
        reload) action_reload ;;
        enable) action_enable ;;
        disable) action_disable ;;
        restart) action_restart ;;
        uninstall) action_uninstall ;;
        *) os::die 2 "未知操作「${1}」，可用：status allow delete reload enable disable restart uninstall" ;;
    esac
}

main "$@"
