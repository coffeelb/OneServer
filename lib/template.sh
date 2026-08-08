# lib/template.sh —— L3 能力层：把 templates/ 里的模板落到目标路径
#
# 只依赖 L0–L2。**不依赖同层的 secure.sh / state.sh / sql.sh / systemd.sh / probe.sh。**
#
#   os::install_template [--backup] [--mode <八进制>] <模板> <目标> [KEY=VALUE...]
#   os::install_file     [--backup] [--mode <八进制>] <源文件> <目标>
#
# --- 为什么必须有这个模块 ---
#
# 规范要求「替换文件必须写临时文件 + `mv` 换 inode」，而「把一整份配置
# 从模板落到目标路径」这条路上此前**没有任何合规入口**：
#
#   * `printf ... > 目标`         就地截断，正是规范禁的（K13 的形态）
#   * 写 os::tmpdir 再 mv         tmpdir 在 /run（tmpfs），跨文件系统的 mv 是
#                                 「复制 + 删除」不是原子替换；而且 os::tmpdir
#                                 在 dry-run 下照样建目录，违反规范零变更
#   * os::replace_line            它按正则改**行**，改不了整份文件
#
# 老脚本 update_phpconf.sh 与 caddy-manager.sh 走的都是 wget + `sed -i` + `mv`
# 的写法（K15）。模板改为随分发落地之后，缺的就只剩这个函数。
#
# --- 为什么是新的 L3 模块，而不是塞进 errors.sh ---
#
# errors.sh 已经有 backup_file / replace_line / tmpdir，看着是它的地盘。但这个
# 函数在 dry-run 下必须置 `OS_DRYRUN_TAINTED`（规范的分叉声明靠它），
# 而那是 exec.sh 的 `exec::_taint` —— 两者同属 L2，规则 2 禁止同层互相依赖。
# 放到 L3 就同时够得着 exec.sh 与 errors.sh，一个字的规则都不用改。
#
# 这与 D59（log.sh 下沉 L1）D62（exec.sh 下沉 L2）是同一条经验：
# **写不下去说明切分错了，改切分，别在代码里绕。**

# 上一次 os::install_template / os::install_file 是否（将要）改动目标文件。
#
# 调用方靠它决定「要不要重启服务 / 要不要跑校验」——**幂等的关键**：
# 内容没变还去重启一次 FPM，第二次执行就不是「零变更」了。
OS_TEMPLATE_CHANGED=0

# os::install_template [--backup] [--mode <八进制>] <模板> <目标> [KEY=VALUE...]
#
# 占位符语法是 `%%KEY%%`（templates/www.conf 里的 `%%PHP_VERSION%%` 就是它）。
# 渲染完仍有残留占位符时**拒绝写入**：把一行 `listen = /run/php/php%%PHP_VERSION%%-fpm.sock`
# 写进 pool 配置，服务起不来，而错误信息里根本看不出是模板没渲染。
#
# `--backup` 只在内容确实要变时才落副本。理由同 OS_TEMPLATE_CHANGED：
# 第二次执行若还往 $OS_BACKUP_DIR 里多塞一份，那就是新的变更。
os::install_template() {
    local backup=0 mode=''
    while [[ ${1-} == --* ]]; do
        case ${1} in
            --backup)
                backup=1
                shift
                ;;
            --mode)
                mode=${2-}
                shift 2
                ;;
            --)
                shift
                break
                ;;
            *)
                ui::line --err error "os::install_template 未知选项 ${1}"
                return 2
                ;;
        esac
    done

    local tpl=${1-} target=${2-}
    OS_TEMPLATE_CHANGED=0
    if [[ -z ${tpl} || -z ${target} ]]; then
        ui::line --err error 'os::install_template 用法：[--backup] [--mode <八进制>] <模板> <目标> [KEY=VALUE...]'
        return 2
    fi
    shift 2

    # --- 用户覆盖：/etc/oneserver/templates/<同名文件> 优先 ---
    #
    # 分发目录 templates/ 会被 `oneserver update` **整个目录换掉**（切换器的
    # TOP_ORDER 里就有它）——在那儿改的东西下次更新一声不响就没了。
    # /etc 不在分发范围内，用户的定制放那儿才活得过更新（同 D51 对 conf 的安排）。
    #
    # **命中时明说**，不静默替换：一份「我明明改了模板却没生效」和一份
    # 「我忘了 /etc 下还压着一份旧的」同样难查，区别只在有没有这一行。
    local __os_tpl_override="${OS_ETC_DIR}/templates/${tpl##*/}"
    if [[ -f ${__os_tpl_override} ]]; then
        ui::line info "用 ${__os_tpl_override}（覆盖了分发自带的模板）"
        tpl=${__os_tpl_override}
    fi

    if [[ ! -f ${tpl} ]]; then
        ui::line --err error "模板不存在：${tpl}"
        return 1
    fi

    # --- 渲染 ---
    local -a lines=()
    local line kv key val
    while IFS= read -r line || [[ -n ${line} ]]; do
        for kv in "$@"; do
            key=${kv%%=*}
            val=${kv#*=}
            line=${line//"%%${key}%%"/${val}}
        done
        lines+=("${line}")
    done <"${tpl}"

    local rendered=''
    printf -v rendered '%s\n' ${lines[@]+"${lines[@]}"}

    if [[ ${rendered} =~ %%[A-Za-z_][A-Za-z0-9_]*%% ]]; then
        ui::line --err error "模板 ${tpl##*/} 里的 ${BASH_REMATCH[0]} 没有对应的替换值"
        return 1
    fi

    # --- 已是目标状态就不写---
    #
    # 两边都走「逐行读 + 补一个换行」这条同样的归一化路径再比。直接比原始字节
    # 的话，模板文件末尾没有换行、目标文件有，会永远判成「不一样」——
    # 于是每次执行都重写、都重启服务，幂等当场失效。
    if [[ -f ${target} ]]; then
        local -a cur=()
        while IFS= read -r line || [[ -n ${line} ]]; do
            cur+=("${line}")
        done <"${target}"
        local current=''
        printf -v current '%s\n' ${cur[@]+"${cur[@]}"}
        if [[ ${current} == "${rendered}" ]]; then
            log::write info "已是目标状态，未改动 ${target}" framework
            return 0
        fi
    fi

    # shellcheck disable=SC2034  # 理由：本模块的输出变量，由脚本层读（决定要不要重启服务）
    OS_TEMPLATE_CHANGED=1

    if [[ ${OS_DRYRUN} -eq 1 ]]; then
        # 跳过了有副作用的一步，后面的探测结果与真实系统已经分叉
        exec::_taint
        ui::line muted "[dry-run] 将用模板 ${tpl##*/} 写入 ${target}"
        log::write info "[dry-run] 跳过写入：${target}" framework
        return 0
    fi

    if [[ ${backup} -eq 1 ]]; then
        os::backup_file "${target}" || return 1
    fi

    template::_place "${target}" "${mode}" --content "${rendered}" || return 1
    ui::line info "已写入 ${target}"
    log::write info "已用模板 ${tpl} 写入 ${target}" framework
    return 0
}

# os::install_file [--backup] [--mode <八进制>] <源文件> <目标>
#
# 把一个**现成的文件**放到目标路径。与 os::install_template 的唯一区别是
# 内容从哪来，以及**按字节比对而不是逐行**：install_caddy 要放的是一个
# 16 MB 的 ELF 二进制，逐行读会把它读成一堆含 \0 的「行」，比对必然判成
# 「不一样」，每次执行都重装一遍（幂等失效），大文件上还慢得离谱。
#
# 禁止 `install -m 755 src dst`：GNU install 以 O_TRUNC 写原 inode，
# 而这里替换的往往正是一个**正在运行**的程序（K13 的形态）。
os::install_file() {
    local backup=0 mode=''
    while [[ ${1-} == --* ]]; do
        case ${1} in
            --backup)
                backup=1
                shift
                ;;
            --mode)
                mode=${2-}
                shift 2
                ;;
            --)
                shift
                break
                ;;
            *)
                ui::line --err error "os::install_file 未知选项 ${1}"
                return 2
                ;;
        esac
    done

    local src=${1-} target=${2-}
    OS_TEMPLATE_CHANGED=0
    if [[ -z ${src} || -z ${target} ]]; then
        ui::line --err error 'os::install_file 用法：[--backup] [--mode <八进制>] <源文件> <目标>'
        return 2
    fi
    if [[ ! -f ${src} ]]; then
        ui::line --err error "源文件不存在：${src}"
        return 1
    fi

    if [[ -f ${target} ]] && cmp -s -- "${src}" "${target}"; then
        log::write info "已是目标状态，未改动 ${target}" framework
        return 0
    fi

    # shellcheck disable=SC2034  # 理由：本模块的输出变量，由脚本层读（决定要不要重启服务）
    OS_TEMPLATE_CHANGED=1

    if [[ ${OS_DRYRUN} -eq 1 ]]; then
        exec::_taint
        ui::line muted "[dry-run] 将把 ${src##*/} 放到 ${target}"
        log::write info "[dry-run] 跳过放置：${target}" framework
        return 0
    fi

    if [[ ${backup} -eq 1 ]]; then
        os::backup_file "${target}" || return 1
    fi

    template::_place "${target}" "${mode}" --from "${src}" || return 1
    ui::line info "已写入 ${target}"
    log::write info "已把 ${src} 放到 ${target}" framework
    return 0
}

# os::write_public <文件名> <内容>   把只读产物原子写入 public/，0644
#
# 给分档采集器落 tsv 用。与 os::install_template 的区别是内容**动态生成**
# 而不是来自 templates/ 下的模板文件，模板接口表达不了。
#
# 三件事和别处不一样，都是「每十秒跑一次」逼出来的：
#   1. 内容没变就不写 —— 否则每轮都换一次 inode，正在读的客户端会拿到半截。
#   2. 成功时**不打印**，只记 debug 日志 —— 每十秒刷一行会把日志淹掉。
#      成功回执归调用方说，不归 template::_place：那三个调用方里只有这一个
#      是按周期跑的，写在共用底层就等于强加给它。
#   3. `mkdir` 不带 `-p`（同 probe::snapshot_flush 的理由）：这函数可能在
#      uninstall 刚删完 $OS_ROOT 之后被调到，带 -p 会把整棵目录树建回来，
#      现场表现是「卸载说成功了，可目录还在」。
os::write_public() {
    local name=${1-} content=${2-}
    if [[ -z ${name} ]]; then
        ui::line --err error 'os::write_public 用法：<文件名> <内容>'
        return 2
    fi
    # 只收单层文件名：public/ 是唯一放宽到 0755 的目录，允许 `..` 或子路径
    # 等于把这个放宽扩散到任意位置
    if [[ ${name} == */* || ${name} == .* ]]; then
        ui::line --err error "os::write_public 只接受单层文件名：${name}"
        return 2
    fi

    local target="${OS_PUBLIC_DIR}/${name}"
    if [[ -f ${target} ]] && [[ $(cat -- "${target}" 2>/dev/null) == "${content}" ]]; then
        return 0
    fi

    if [[ ${OS_DRYRUN} -eq 1 ]]; then
        exec::_taint
        ui::line muted "[dry-run] 将写入 ${target}"
        return 0
    fi

    mkdir "${OS_PUBLIC_DIR}" 2>/dev/null || true
    [[ -d ${OS_PUBLIC_DIR} ]] || return 1
    chmod "${OS_PUBLIC_DIR_MODE}" "${OS_PUBLIC_DIR}" 2>/dev/null || true

    template::_place "${target}" 0644 --content "${content}" || return 1
    log::write debug "已写入公开产物 ${target}" framework
    return 0
}

# template::_place <目标> <mode> <--content <内容> | --from <源文件>>
#
# 三个入口共用的落地动作。**临时文件与目标同目录** + `mv` 换 inode：
# 同目录是硬要求 —— 跨文件系统的 `mv` 是「复制 + 删除」，中途断电就是半截文件。
# 权限与属主随原文件走，否则一个 0600 的配置替换完会变成 umask 决定的 0640。
# 整段在不可中断区段内：写到一半被 Ctrl-C，落地的就是半个文件。
#
# **成功不打印**：三个调用方里 os::write_public 每十秒跑一次，把回执写在这里
# 就等于强加给它 —— 它的注释明说不打印，而底层照打，屏幕与 journald 每十秒
# 各多一行。失败仍在这里报：那是三个调用方都要的。
#
# 这是本模块内部的第二个使用点才提取出来的，不是先验的抽象。
#
# 内容走**函数参数**而不是管道或 here-string：here-string 会补一个换行，
# 而去掉它又会连带吃掉模板本来就有的末尾空行 —— 下一次比对判成「不一样」，
# 每次执行都重写，幂等当场失效。函数参数不经 exec、不进 ps，
# 凭据类内容也安全（规范管的是**外部命令**的 argv）。
#
# **临时文件名必须由 mktemp 生成，不能拼 `$$`。** 目标目录常常是**非 root
# 可写**的（站点根属 www-data、/etc/caddy/incoming 属 caddy 组），而 PID 只有
# 三万多个取值、可以喷洒预置。攻击者事先把 `<目标>.os-place.<pid>` 建成指向
# /etc 下某个文件的符号链接，`>` 就跟过去以 root 覆写它，随后那条符号链接还被
# `mv` 搬到目标路径上，此后每一次写入都落在攻击者选的位置。mktemp 走
# O_EXCL|O_CREAT，路径已存在就失败，这条路整个不成立。
template::_place() {
    local target=${1} mode=${2} kind=${3} payload=${4-}
    local tmp
    if ! tmp=$(mktemp "${target}.os-place.XXXXXXXX" 2>/dev/null); then
        ui::line --err error "无法在 ${target%/*} 下创建临时文件"
        return 1
    fi
    local -i rc=0

    os::critical_begin '文件落地'
    if [[ ${kind} == --content ]]; then
        if ! printf '%s' "${payload}" 2>/dev/null >"${tmp}"; then
            rc=1
        fi
    else
        if ! cp -- "${payload}" "${tmp}" 2>/dev/null; then
            rc=1
        fi
    fi

    if [[ ${rc} -eq 0 ]]; then
        if [[ -e ${target} ]]; then
            chmod --reference="${target}" -- "${tmp}" 2>/dev/null || true
            chown --reference="${target}" -- "${tmp}" 2>/dev/null || true
        elif [[ -n ${mode} ]]; then
            chmod "${mode}" -- "${tmp}" 2>/dev/null || true
        fi
        if ! mv -f -- "${tmp}" "${target}" 2>/dev/null; then
            rc=1
        fi
    fi
    if [[ ${rc} -ne 0 ]]; then
        rm -f -- "${tmp}" 2>/dev/null || true
    fi
    os::critical_end

    if [[ ${rc} -ne 0 ]]; then
        ui::line --err error "写入 ${target} 失败"
        return 1
    fi
    return 0
}
