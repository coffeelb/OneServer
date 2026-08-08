#!/bin/bash
#
# Docker 容器管理
#
# @command      docker
# @name         容器管理
# @self_name    容器列表与操作
# @group        container
# @order        60
# @requires     docker
# @privilege    root
# @requires_lib >= 1.28
# @args         [--action=<ls|start|stop|restart|logs|rm|autoupdate>] [--name=<名字>] [--lines=<行数>] [--confirm-rm=<名字>]
# @description  创建、查看、启停、日志、删除与自动更新状态
#

set -Eeuo pipefail
IFS=$'\n\t'
PATH='/usr/sbin:/usr/bin:/sbin:/bin'
export PATH
umask 027

source /opt/oneserver/lib/bootstrap.sh

# ==================================================================
# 本脚本只管**已有**容器：看、启停、看日志、删
# ==================================================================
#
# 建容器（粘 run 命令、补齐 -d/--name/--restart）在 `oneserver docker run` 里 ——
# 那部分的切词与校验逻辑跟这里的管理动作不是一类事，拆开维护。
#
# **容器本体没有第二份配置，dockerd 就是它们的唯一账本**，本工具不另记一份
# （不像 podman 那边有 Quadlet 文件可读）。

readonly NAME_RE='^[a-zA-Z0-9][a-zA-Z0-9_.-]{0,127}$'
readonly UNIT='docker.service'
readonly WATCHTOWER_LABEL='com.centurylinklabs.watchtower.enable'
readonly WATCHTOWER_UNIT='oneserver-watchtower'

# ------------------------------------------------------------------

require_docker() {
    probe::component_version docker
    [[ -n ${OS_PROBE_VALUE} ]] || os::die 3 '没有检测到 Docker。先 oneserver install docker'
    os::require_cmd docker

    # daemon 停着的话下面每一条命令都会以「Cannot connect to the Docker
    # daemon」失败 —— 那句话不会告诉人服务是停着的，只会让人去查网络与权限
    probe::service_active "${UNIT}"
    [[ ${OS_PROBE_VALUE} == active ]] \
        || os::die 3 "dockerd 没在跑（当前 ${OS_PROBE_VALUE:-未知}）—— Docker 的每条命令都要连它：systemctl start ${UNIT}"
    return 0
}

validate_name() {
    local name=${1}
    [[ ${name} =~ ${NAME_RE} ]] \
        || os::die 2 "容器名「${name}」不合法：以字母或数字开头，此后只收字母、数字、下划线、点与短横线"
    return 0
}

# 容器在不在。结果写进返回码，不打印（D135 同理：`$( )` 会吞掉 probe 的来源）
container_exists() {
    local name=${1} line
    os::query --timeout 20 -- docker ps -a --format '{{.Names}}'
    while IFS= read -r line; do
        [[ ${line} == "${name}" ]] && return 0
    done <<<"${OS_RUN_OUTPUT}"
    return 1
}

require_container() {
    local name=${1}
    container_exists "${name}" \
        || os::die 2 "没有叫 ${name} 的容器（oneserver docker ls 看看有哪些）"
    return 0
}

# 总览表的编号就是当前操作周期的选择符，避免把同一批容器再打印一遍。
DC_LIST_READY=0
DC_IDS=()
DC_NAMES=()
DC_IMAGES=()
DC_STATUS=()
DC_PORTS=()
DC_PROJECTS=()
DC_AUTOUPDATE=()
DC_RESTART=()

short_cell() {
    local text=${1-}
    local -i limit=${2:-32}
    if ((${#text} > limit)); then
        printf '%s…\n' "${text:0:limit-1}"
    else
        printf '%s\n' "${text}"
    fi
    return 0
}

load_container_rows() {
    os::query --timeout 20 -- \
        docker ps -a --format "{{.ID}}\t{{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}\t{{.Label \"com.docker.compose.project\"}}\t{{.Label \"${WATCHTOWER_LABEL}\"}}"
    local list=${OS_RUN_OUTPUT}

    DC_IDS=()
    DC_NAMES=()
    DC_IMAGES=()
    DC_STATUS=()
    DC_PORTS=()
    DC_PROJECTS=()
    DC_AUTOUPDATE=()
    DC_RESTART=()
    DC_LIST_READY=1

    local line line_safe id name image status ports project autoupdate restart
    local IFS=$'\n'
    for line in ${list}; do
        [[ -n ${line} ]] || continue
        line_safe=${line//$'\t'/$'\x01'}
        IFS=$'\x01' read -r id name image status ports project autoupdate <<<"${line_safe}"
        os::query --timeout 10 -- docker inspect -f '{{.HostConfig.RestartPolicy.Name}}' "${name}"
        restart=${OS_RUN_OUTPUT:-no}
        DC_IDS+=("${id}")
        DC_NAMES+=("${name}")
        DC_IMAGES+=("${image}")
        DC_STATUS+=("${status}")
        DC_PORTS+=("${ports}")
        DC_PROJECTS+=("${project}")
        DC_AUTOUPDATE+=("${autoupdate}")
        DC_RESTART+=("${restart}")
    done
    return 0
}

select_container() {
    local __dc_out=${1} prompt=${2}
    if [[ ${DC_LIST_READY} -ne 1 ]]; then
        action_ls
    fi
    [[ ${#DC_NAMES[@]} -gt 0 ]] || os::die 2 '没有 Docker 容器可选'

    local picked=''
    os::ask --arg name "${prompt}（输入上方编号；命令行可传 --name）" picked
    if [[ ${picked} =~ ^[0-9]+$ ]]; then
        local -i selected=$((picked - 1))
        ((selected >= 0 && selected < ${#DC_NAMES[@]})) \
            || os::die 2 "没有编号为「${picked}」的容器"
        picked=${DC_NAMES[selected]}
    fi
    validate_name "${picked}"
    printf -v "${__dc_out}" '%s' "${picked}"
    return 0
}

# ------------------------------------------------------------------

action_ls() {
    require_docker

    load_container_rows
    os::screen_heading '当前容器'
    if [[ ${#DC_NAMES[@]} -eq 0 ]]; then
        os::info '一个都没有。建一个：oneserver docker run'
        os::output 0 count=0
        return 0
    fi

    local -a cells=()
    local restart_label autoupdate_label
    local -i i any_autoupdate=0
    for ((i = 0; i < ${#DC_NAMES[@]}; i++)); do
        restart_label="${DC_RESTART[i]}"
        [[ ${restart_label} == no ]] && restart_label='—'
        [[ ${restart_label} != '—' ]] && restart_label="✔ ${restart_label}"
        autoupdate_label='—'
        if [[ ${DC_AUTOUPDATE[i]} == true ]]; then
            autoupdate_label='✔ 已标记'
            any_autoupdate=1
        fi
        cells+=("[$((i + 1))]" "${DC_IDS[i]:0:12}" "${DC_NAMES[i]}"
            "$(short_cell "${DC_IMAGES[i]}" 34)" "$(short_cell "${DC_STATUS[i]}" 18)"
            "${restart_label}" "${autoupdate_label}")
        os::output_item "id=${DC_IDS[i]}" "name=${DC_NAMES[i]}" "image=${DC_IMAGES[i]}" \
            "status=${DC_STATUS[i]}" "ports=${DC_PORTS[i]}" "restart=${DC_RESTART[i]}" \
            "compose_project=${DC_PROJECTS[i]}" "auto_update=${DC_AUTOUPDATE[i]}"
    done
    os::table '编号' 'ID' '名称' '镜像' '状态' '自启' '自动更新标记' -- "${cells[@]}"
    if ((any_autoupdate == 1)) && ! container_exists "${WATCHTOWER_UNIT}"; then
        os::warn "有容器打了自动更新标签，但没检测到 ${WATCHTOWER_UNIT} 容器在跑，标签不会生效：oneserver install docker --watchtower=y"
    fi
    os::output 0 count="${#DC_NAMES[@]}"
    return 0
}

# start / stop / restart 共用一段：它们的区别只有一个动词
action_power() {
    local verb=${1}
    require_docker

    local name='' prompt=''
    case ${verb} in
        start) prompt='选择要启动的容器' ;;
        stop) prompt='选择要停止的容器' ;;
        restart) prompt='选择要重启的容器' ;;
    esac
    select_container name "${prompt}"
    require_container "${name}"

    # 启停一个可能是用户既有资产的容器，属「禁止自动回滚」类：它原来是开是关，
    # 这里并不知道，猜着还原比不还原破坏更大。只记进变更清单。
    #
    # 三个动词各写一条 desc 而不是拼字符串：规范要求 desc 是固定字符串 [CI]，
    # 拼出来的 desc 在日志与审计里就成了模板，grep 不到具体某一次操作
    os::record_change "对容器 ${name} 执行了 ${verb}"
    local -i rc=0
    case ${verb} in
        start) os::run '启动容器' -- docker start "${name}" || rc=$? ;;
        stop) os::run '停止容器' -- docker stop "${name}" || rc=$? ;;
        restart) os::run '重启容器' -- docker restart "${name}" || rc=$? ;;
    esac
    ((rc == 0)) || os::die 1 "docker ${verb} ${name} 失败（详情看日志）"

    local status='dry-run'
    if [[ ${OS_DRYRUN} -ne 1 ]]; then
        os::query --timeout 20 -- docker inspect -f '{{.State.Status}}' "${name}"
        status=${OS_RUN_OUTPUT}
    fi
    os::ok "${name}：${status}"
    os::output 0 name="${name}" action="${verb}" status="${status}"
    return 0
}

action_logs() {
    require_docker
    local name='' lines=''
    select_container name '选择要查看日志的容器'
    os::ask --arg lines '显示最近多少行' lines '50'
    [[ ${lines} =~ ^[0-9]+$ ]] || os::die 2 "--lines 要是正整数，收到「${lines}」"
    require_container "${name}"

    # `docker logs` 把容器的 stderr 原样打在自己的 stderr 上，而 os::query
    # 只取 stdout —— 不合流的话，nginx、postgres 这些把日志全写 stderr 的镜像
    # 在这里会打出一片空白。`name` 已过 NAME_RE 校验（只有字母数字与 . _ -）、
    # `lines` 已确认是纯数字，所以这两处插值不构成注入面
    os::query --timeout 30 -- sh -c "docker logs --tail ${lines} ${name} 2>&1"
    os::section "${name} 最近 ${lines} 行"
    os::info "${OS_RUN_OUTPUT}"
    os::info "要实时跟：docker logs -f ${name}"
    os::output 0 name="${name}" lines="${lines}"
    return 0
}

action_rm() {
    require_docker
    local name=''
    select_container name '选择要删除的容器'
    require_container "${name}"

    # 删容器不可逆：容器里没写进卷的东西删了就没了。
    # 但**卷本身不删** —— 那是数据，规范禁止自动删除
    if ! os::destroy_confirm --arg confirm-rm "${name}" -- \
        "容器 ${name}（正在跑的会被强制停止）" \
        '容器内未写入卷的数据（卷本身不会被删）'; then
        os::info '已取消，什么都没有动'
        os::output 130 name="${name}" removed=no
        return 130
    fi

    os::record_change "删除了容器 ${name}"
    os::run '删除容器' -- docker rm -f -- "${name}" \
        || os::die 1 "删除容器 ${name} 失败（详情看日志）"

    os::ok "容器 ${name} 已删除"
    os::info '它用过的卷与镜像都还在：oneserver docker volume（卷）· oneserver docker image（镜像）'
    os::output 0 name="${name}" removed=yes
    return 0
}

# 只读展示 + 引导，不做假装能做到的「原地切换」：docker 不支持给已有容器
# 改标签，`docker update` 只管资源限制与重启策略，不管 label。想改只能删了
# 重建（同改任何其他 run 参数一样），这里把现状说清楚、把重建的路指明白
action_autoupdate() {
    require_docker
    local name=''
    select_container name '选择要查看自动更新状态的容器'
    require_container "${name}"

    os::query --timeout 10 -- \
        docker inspect -f "{{index .Config.Labels \"${WATCHTOWER_LABEL}\"}}" "${name}"
    local label=${OS_RUN_OUTPUT}
    local status='关'
    [[ ${label} == true ]] && status='开'

    os::section "${name} 的自动更新"
    os::kv '当前状态' "${status}"
    os::info 'docker 不支持给已有容器原地改标签，只能删了重建 —— 这是 Docker 本身的限制，不是本工具的'
    if [[ ${status} == 开 ]]; then
        os::info "要关闭：oneserver docker rm --name=${name} 后用 oneserver docker run 重建（不勾选 --auto-update）"
    else
        os::info "要开启：oneserver docker rm --name=${name} 后用 oneserver docker run 重建（勾选 --auto-update）"
    fi
    os::output 0 name="${name}" auto_update="$([[ ${status} == 开 ]] && printf true || printf false)"
    return 0
}

# ------------------------------------------------------------------

main() {
    local action=${1-}
    if [[ -n ${action} ]]; then
        dispatch "${action}"
        return 0
    fi

    os::action_menu --overview action_ls --arg action '操作' dispatch \
        'start=启动' 'stop=停止' 'restart=重启' \
        'logs=查看日志' 'rm=删除容器' 'autoupdate=查看自动更新'
}

dispatch() {
    case ${1} in
        ls) action_ls ;;
        start) action_power start ;;
        stop) action_power stop ;;
        restart) action_power restart ;;
        logs) action_logs ;;
        rm) action_rm ;;
        autoupdate) action_autoupdate ;;
        *) os::die 2 "未知操作「${1}」，可用：ls start stop restart logs rm autoupdate" ;;
    esac
}

main "$@"
