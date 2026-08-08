#!/bin/bash
#
# 创建容器
#
# @command      docker run
# @name         创建容器
# @group        container
# @order        70
# @requires     docker
# @privilege    root
# @requires_lib >= 1.20
# @args         --run-cmd=<整条 run 命令> [--name=<名字>] [--restart-policy=<always|unless-stopped|on-failure|no>] [--auto-update]
# @description  粘贴 docker run 命令，补齐参数后直接建容器
#

set -Eeuo pipefail
IFS=$'\n\t'
PATH='/usr/sbin:/usr/bin:/sbin:/bin'
export PATH
umask 027

source /opt/oneserver/lib/bootstrap.sh

# ==================================================================
# 一个容器 = dockerd 管的一条记录，没有第二份配置
# ==================================================================
#
# **与 `oneserver podman run` 是两套东西，不要照着它读。** podman 那边把
# `docker run` 翻译成 Quadlet 文件再交给 systemd，是因为裸 podman 容器
# 重启机器就没了、也没人盯着它。Docker 这些全由 dockerd 自己做：
# `--restart` 是引擎的能力，docker.service 开机自启，容器跟着回来。
#
# 于是这里**不翻译**，只补齐三样非有不可的东西，其余原样交给 docker：
#
#   `-d`        没有它命令会一直挂在前台，而这是个管理工具不是终端
#   `--name`    没有名字 docker 会随机取一个，此后 start/stop/logs 全找不着它
#   `--restart` docker 的默认是「不重启」—— 崩一次就再也不起来，且没有任何提示
#
# **认不出的 flag 一律透传**，这是与 podman 那边最大的区别，也是安全的：
# 那边认错一个 flag 会把它翻进错误的 Quadlet 段，容器行为跟着变；这边最坏
# 也只是 docker 自己报一句参数错误，语义不会被我们改写。
#
# **端口绑哪个地址不在这里管。** 它由 `/etc/docker/daemon.json` 的 `"ip"`
# 决定，`oneserver install docker` 与 `oneserver safe network` 设好 ——
# 一处设定，此后每一条 `docker run` 都算数，包括用户自己在终端里敲的、
# 以及 docker compose 起的。逐条命令去改写端口反而只能管住走这个入口的那些。
#
# **自动更新是标签驱动的，且只能在这里设**：Docker 没有 Quadlet 那样的
# 声明式配置文件可编辑，`docker update` 也不支持改标签，已存在的容器无法
# 原地切换 —— 想要自动更新，只能在创建时打上标签。运维需要重新配置一个
# 容器的自动更新时，只能删了重建（同改任何其他 run 参数一样）。

readonly NAME_RE='^[a-zA-Z0-9][a-zA-Z0-9_.-]{0,127}$'
readonly WATCHTOWER_LABEL='com.centurylinklabs.watchtower.enable=true'
readonly WATCHTOWER_UNIT='oneserver-watchtower'

# ------------------------------------------------------------------

require_docker() {
    probe::component_version docker
    [[ -n ${OS_PROBE_VALUE} ]] || os::die 3 '没有检测到 Docker。先 oneserver install docker'
    os::require_cmd docker

    # daemon 停着的话下面每一条命令都会以「Cannot connect to the Docker
    # daemon」失败 —— 那句话不会告诉人服务是停着的，只会让人去查网络与权限
    probe::service_active docker.service
    [[ ${OS_PROBE_VALUE} == active ]] \
        || os::die 3 "dockerd 没在跑（当前 ${OS_PROBE_VALUE:-未知}）—— Docker 的每条命令都要连它：systemctl start docker.service"
    return 0
}

validate_name() {
    local name=${1}
    [[ ${name} =~ ${NAME_RE} ]] \
        || os::die 2 "容器名「${name}」不合法：以字母或数字开头，此后只收字母、数字、下划线、点与短横线"
    return 0
}

container_exists() {
    local name=${1} line
    os::query --timeout 20 -- docker ps -a --format '{{.Names}}'
    while IFS= read -r line; do
        [[ ${line} == "${name}" ]] && return 0
    done <<<"${OS_RUN_OUTPUT}"
    return 1
}

# ------------------------------------------------------------------
# 切词
# ------------------------------------------------------------------

# 把一条命令行切成词，结果写进 DC_TOKENS。引号没闭合时返回 1。
#
# 认单引号（内部一律字面）、双引号（内部只有 `\"` `\\` 是转义）与反斜杠，
# 与 shell 一致。**不做变量展开、不做 glob**：粘进来的 `$HOME` 就是字面的
# `$HOME` —— 展开它等于替用户改写他的命令，而他多半是从一份文档里复制的。
#
# **不能把整条字符串交给 `sh -c`**，那是 eval 的另一种写法，全项目禁止（§10）。
# 也不用 `xargs`：它的引号规则与 shell 有出入，用它会让「粘进来的命令」
# 与「在终端里敲的同一条命令」有两种含义。
#
# 与 podman_create.sh 里那份是同一套规则的第二份实现。**出现第三个消费者
# 就该进 lib** —— 到那时「同一条命令在不同引擎下切出不同的词」才真正开始难查。
DC_TOKENS=()
tokenize() {
    local s=${1}
    local -i i n=${#s} started=0
    local cur='' ch quote=''
    DC_TOKENS=()
    for ((i = 0; i < n; i++)); do
        ch=${s:i:1}
        if [[ -n ${quote} ]]; then
            if [[ ${ch} == "${quote}" ]]; then
                quote=''
            elif [[ ${quote} == '"' && ${ch} == $'\\' ]]; then
                i+=1
                cur+=${s:i:1}
            else
                cur+=${ch}
            fi
            continue
        fi
        case ${ch} in
            "'" | '"')
                quote=${ch}
                started=1
                ;;
            $'\\')
                i+=1
                cur+=${s:i:1}
                started=1
                ;;
            # 换行与回车也算分隔：`--run-cmd=` 传进来的值可能带换行，
            # 从 Windows 终端粘来的还会带 `\r` —— 不当空白的话它会粘在词尾
            # 变成 `nginx:alpine\r`，然后镜像拉不到
            ' ' | $'\t' | $'\n' | $'\r')
                if ((started == 1)); then
                    DC_TOKENS+=("${cur}")
                    cur=''
                    started=0
                fi
                ;;
            *)
                cur+=${ch}
                started=1
                ;;
        esac
    done
    [[ -z ${quote} ]] || return 1
    ((started == 1)) && DC_TOKENS+=("${cur}")
    return 0
}

validate_run_cmd() {
    local v=${1}
    [[ -n ${v} ]] || return 1
    # 续行由 `os::ask --multiline` 接完，走到这里还挂着反斜杠只有一种可能：
    # 粘到一半断了。半条命令照样能跑出一个「像那么回事」的容器，所以要拒绝
    [[ ${v} != *\\ ]] || return 1
    return 0
}

# ------------------------------------------------------------------

# 建容器：粘命令 → 切词 → 补齐必需的几样 → 校验挂载 → 跑 → 确认真的在跑
main() {
    require_docker

    local cmdline=''
    os::ask --arg run-cmd --multiline --validate validate_run_cmd \
        '粘贴完整的 run 命令（带 \ 换行的多行命令直接整段粘）' cmdline ''

    tokenize "${cmdline}" || os::die 2 '命令里的引号没有闭合'
    [[ ${#DC_TOKENS[@]} -gt 0 ]] || os::die 2 '没有收到命令'

    # `sudo docker run …` 是从文档里复制时最常见的形态。本命令已经是 root，
    # 把 sudo 原样传下去只会多一层进程，还会让 --env 之类的行为变得不一样
    local -i start=0
    [[ ${DC_TOKENS[start]} == sudo ]] && start=$((start + 1))
    case ${DC_TOKENS[start]-} in
        docker | podman) start=$((start + 1)) ;;
        *) os::die 2 "命令要以 docker run 开头，收到「${DC_TOKENS[start]-}」" ;;
    esac
    [[ ${DC_TOKENS[start]-} == run ]] \
        || os::die 2 "只收 run 命令，收到「${DC_TOKENS[start]-}」—— 别的操作请用本命令的其他动作或直接敲 docker"
    start=$((start + 1))

    local -a args=("${DC_TOKENS[@]:start}")
    [[ ${#args[@]} -gt 0 ]] || os::die 2 'run 后面什么都没有，至少要给出镜像'

    # --- 扫一遍，看这三样在不在 ---
    #
    # **只扫不改**：这里判断的是 flag 在不在，不解析它的值，所以不需要一张
    # 「哪个 flag 吃下一个词」的表。代价是理论上有个词恰好是 `--name` 的
    # **值**时会误判 —— 那时我们不会再补一个 --name，docker 自己会报重复参数，
    # 而不是安静地做错事。为这个概率去维护一张 flag 表不划算。
    local -i has_detach=0 has_name=0 has_restart=0
    local name='' policy='' t
    local -i k
    for ((k = 0; k < ${#args[@]}; k++)); do
        t=${args[k]}
        case ${t} in
            -d | --detach) has_detach=1 ;;
            --name)
                has_name=1
                name=${args[k + 1]-}
                ;;
            --name=*)
                has_name=1
                name=${t#--name=}
                ;;
            --restart)
                has_restart=1
                policy=${args[k + 1]-}
                ;;
            --restart=*)
                has_restart=1
                policy=${t#--restart=}
                ;;
        esac
    done

    if ((has_name == 1)); then
        [[ -n ${name} ]] || os::die 2 '--name 后面没有值'
    else
        os::ask --arg name '这条命令没写 --name，容器叫什么' name ''
        [[ -n ${name} ]] || os::die 2 '要给出容器名字：--name=web'
    fi
    validate_name "${name}"
    container_exists "${name}" \
        && os::die 2 "已经有一个叫 ${name} 的容器。改配置就先删了重建：oneserver docker rm --name=${name}"

    if ((has_restart == 0)); then
        # 默认必须问：docker 不写 --restart 就是 `no`，容器崩一次就永远
        # 停在那儿，而 `docker ps` 的默认视图连它都不列
        os::select --arg restart-policy '这条命令没写 --restart，失败后怎么办' policy \
            'always=总是重启（开机也拉起）' 'unless-stopped=除非手动停过，否则重启' \
            'on-failure=仅异常退出时重启' 'no=不自动重启'
    fi

    # --- 自动更新：标签驱动，只能在这里打 ---
    #
    # Watchtower 用 `--label-enable` 起的，只更新带这个标签的容器；没装
    # Watchtower 时打了标签也没有任何东西会去动它，这里如实提醒
    local -i autoupdate=0
    os::flag --arg auto-update && autoupdate=1
    if ((autoupdate == 1)); then
        # **不能塞进 `args`**：`args` 是用户原样给的词，镜像名混在里面，
        # 镜像名之后的一切 docker 都当成容器自己的命令 —— 加在 `args` 末尾
        # 等于把 `--label ...` 当参数传给了容器里的入口脚本（撞过一次：
        # nginx 的 entrypoint 报 `illegal option --`）。跟 -d/--name/--restart
        # 一样落进 cmd，在镜像名之前，才稳当是 docker 自己的 flag
        if ! container_exists "${WATCHTOWER_UNIT}"; then
            os::warn "没有检测到 ${WATCHTOWER_UNIT} 容器 —— 标签打了但不会生效：oneserver install docker --watchtower=y"
        fi
    fi

    # --- 端口：只提醒，不改写 ---
    #
    # 不写宿主 IP 的映射绑到哪儿由 daemon.json 的 "ip" 决定（安装时按网络定位
    # 设好）。显式写了 IP 的**原样不动** —— 那是当场做的决定。
    # 但公网定位下写死 0.0.0.0 意味着直接暴露在公网，而 **ufw 拦不住它**，
    # 所以这一句必须说出来。
    local netmode
    netmode=$(os::state_get network mode '')
    [[ -n ${netmode} ]] || netmode='公网'

    local pval
    for ((k = 0; k < ${#args[@]}; k++)); do
        pval=''
        case ${args[k]} in
            -p | --publish) pval=${args[k + 1]-} ;;
            --publish=*) pval=${args[k]#--publish=} ;;
        esac
        [[ -n ${pval} ]] || continue
        case ${pval} in
            0.0.0.0:* | '[::]:'*)
                [[ ${netmode} == 公网 ]] \
                    && os::warn "端口映射 ${pval} 写死了对全网监听，而这台机器是公网定位 —— Docker 发布的端口绕过 ufw，防火墙拦不住它"
                ;;
            # 三段式写死了宿主 IP，那是当场做的决定，原样不动
            *:*:*) ;;
            *:*) os::info "端口映射 ${pval} 没写宿主 IP，按 dockerd 的默认绑定地址走（oneserver install docker 里显示的那个）" ;;
            *) os::info "端口映射 ${pval} 只给了容器端口，宿主端口由 docker 随机分配" ;;
        esac
    done

    # --- 跑 ---
    local -a cmd=(run)
    ((has_detach == 1)) || cmd+=(-d)
    ((has_name == 1)) || cmd+=(--name "${name}")
    ((has_restart == 1)) || cmd+=(--restart "${policy}")
    ((autoupdate == 1)) && cmd+=(--label "${WATCHTOWER_LABEL}")
    cmd+=("${args[@]}")

    # 容器是本次创建的、撤销干净且安全 —— 属「必须回滚」类，注册回滚。
    # 后面那道「它真的在跑吗」的校验不通过时，不该留一个半死的容器在那儿
    os::record_change "创建了容器 ${name}"
    os::run '创建并启动容器' -- docker "${cmd[@]}" \
        || os::die 1 "docker run 失败，容器 ${name} 没有建起来（详情看日志）"
    os::defer docker rm -f -- "${name}"

    # --- 确认它真的在跑 ---
    #
    # `docker run -d` 返回 0 只说明容器**建起来了**，不说明它还活着：
    # 配置错、镜像的 entrypoint 立刻退出、挂载进去的文件不对 —— 这些都让它
    # 在一秒内变成 Exited(1)，而命令本身是成功的。不查这一下，本工具就会
    # 报告「容器已就绪」，而实际上什么都没跑起来
    if [[ ${OS_DRYRUN} -eq 1 ]]; then
        os::info '[dry-run] 容器没有真的创建，后续状态无从确认'
        os::output 0 name="${name}" changed=dry-run
        return 0
    fi

    os::query --timeout 20 -- docker inspect -f '{{.State.Status}}' "${name}"
    local status=${OS_RUN_OUTPUT}
    if [[ ${status} != running ]]; then
        os::err "容器 ${name} 建起来了，但现在的状态是 ${status:-未知}，下面是它最后几行日志："
        # 容器日志绝大多数走 stderr（nginx、postgres 都是），而 os::query
        # 丢弃 stderr —— 不合流的话这里会打出一片空白，正好在最需要它的时候。
        # `name` 已过 NAME_RE 校验（只有字母数字与 . _ -），插值不构成注入面
        os::query --timeout 20 -- sh -c "docker logs --tail 20 ${name} 2>&1"
        [[ -n ${OS_RUN_OUTPUT} ]] && os::info "${OS_RUN_OUTPUT}"
        # 退出码 1 会让框架回放回滚栈，撤掉这次刚创建的容器
        os::die 1 '容器没能跑起来，已自动撤销。照日志改完命令再来一次'
    fi

    os::section '容器已就绪'
    os::kv '名字' "${name}" \
        '重启策略' "${policy:-（命令里自带）}" \
        '状态' "${status}" \
        '自动更新' "$([[ ${autoupdate} -eq 1 ]] && printf '开' || printf '关')"
    os::info "看日志与管理：oneserver docker logs --name=${name}"
    os::output 0 name="${name}" status="${status}" auto_update="${autoupdate}" changed=yes
    return 0
}

main "$@"
