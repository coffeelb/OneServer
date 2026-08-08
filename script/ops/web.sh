#!/bin/bash
#
# 只读 Web面板
#
# @command      web
# @name         面板与告警
# @group        monitor
# @order        40
# @privilege    root
# @requires_lib >= 1.26
# @provides     web
# @provides_unit own:oneserver-web-fast.service
# @provides_unit own:oneserver-web-fast.timer
# @provides_unit own:oneserver-web-slow.service
# @provides_unit own:oneserver-web-slow.timer
# @args         [--action=<enable|disable|status|report|telegram|refresh>] [--telegram-chat-id=<chat_id>] [--caddy-import=<y|n>] [--caddy-unimport=<y|n>]
# @description  开关只读面板，异常时 Telegram 通知
#

set -Eeuo pipefail
IFS=$'\n\t'
PATH='/usr/sbin:/usr/bin:/sbin:/bin'
export PATH
umask 027

source /opt/oneserver/lib/bootstrap.sh

# ==================================================================
# 为什么这个面板只读、但监听所有网卡
# ==================================================================
#
# 规范 §1 明确「不做操作型 Web 面板」。这里做的是它的补集：**只显示**，
# 页面上没有任何按钮能改服务器状态，连刷新按钮也只是重新拉取已落盘的
# 数据，不触发服务端探测。
#
# 只读不等于不用认证——那是两件独立的事。早期版本把面板锁在 127.0.0.1、
# 逼所有人开 SSH 隧道，图的是不用维护一套密码；但公网服务器上，你和它压根
# 不在一个局域网，隧道是唯一绕不开的路，对着一个只想看看状态的人这个门槛
# 不成立。所以监听所有网卡，用 basic_auth 挡：密码存进凭据库（键名
# web.basic_auth），要不要再套 HTTPS/域名/反代，跟这台机器上其他任何站点
# 一样走 oneserver caddy 自己决定，面板不替你做这个选择。
#
# 不去改用户的 Caddyfile：那是他的主配置，§11 也禁止就地修改。片段落在
# incoming/，最后那行 import 由人自己决定 —— enable 时问一句加不加，disable
# 时（且 incoming/ 已经空了）问一句去不去掉，两处都默认否。
#
# 唯一不问就动手的地方在 `oneserver caddy apply`：那条路是整份替换 Caddyfile，
# 不把 import 带过去的话，面板会因为一次无关的配置更新而静默 404。

readonly CADDY_INBOX='/etc/caddy/incoming'
readonly CADDY_SNIPPET="${CADDY_INBOX}/oneserver-web.caddy"
readonly CADDYFILE='/etc/caddy/Caddyfile'
readonly CADDY_ENV_FILE='/etc/caddy/oneserver.env'
readonly CADDY_UNIT='caddy.service'
readonly CADDY_LOG_DIR='/var/log/caddy'
readonly CADDY_IMPORT_LINE='import incoming/*.caddy'
# 认这一行的正则。容许行首缩进与行尾注释 —— 用户自己加过的那行未必长成
# CADDY_IMPORT_LINE 的样子，认不出来就会被当成「没有」而重复追加一行
readonly CADDY_IMPORT_RE='^[[:space:]]*import[[:space:]]+incoming/\*\.caddy[[:space:]]*(#.*)?$'
readonly WEB_PORT='8730'
readonly WEB_AUTH_KEY='web.basic_auth'
readonly COMPONENT='web'

readonly -a WEB_UNITS=(
    'oneserver-web-fast.timer'
    'oneserver-web-slow.timer'
)
# 采集产物。disable 时要清掉：留着的话，页面没了数据还在，而那份数据
# 会永远停在被关掉的那一刻——比没有更容易误导人
readonly -a WEB_FILES=(
    'index.html'
    'probe-fast.tsv'
    'probe-slow.tsv'
    'history.tsv'
    'alerts.tsv'
    'telegram-alerts.tsv'
    'components.tsv'
    'containers.tsv'
    'volumes.tsv'
    'container-updates.tsv'
    'firewall.tsv'
    'backups.tsv'
    'oneserver.jsonl'
    'report.html'
)

# ------------------------------------------------------------------
web_enabled() {
    probe::service_enabled 'oneserver-web-fast.timer'
    [[ ${OS_PROBE_VALUE} == enabled ]]
}

install_units() {
    local u
    for u in oneserver-web-fast.service oneserver-web-fast.timer \
        oneserver-web-slow.service oneserver-web-slow.timer; do
        os::systemd_install "${OS_UNIT_SRC_DIR}/${u}" own || return 1
    done
    os::systemd_daemon_reload || return 1
    return 0
}

write_caddy_snippet() {
    # 不能拿 incoming/ 是否存在当成 Caddy 是否安装：这是 caddy apply 的投放
    # 目录，不是包安装时必有的目录。此前 Caddy 明明已装、面板却被报成「未装
    # HTTP 服务」，片段、HTTP 风险警告与 import 指引一起消失。
    probe::component_version caddy
    [[ -n ${OS_PROBE_VALUE} ]] || return 0
    os::require_cmd caddy

    if [[ ! -d ${CADDY_INBOX} ]]; then
        # Caddy 进程以 caddy 用户运行，父目录没有执行权限时 import 会静默匹配
        # 0 个文件。目录只在本次新建时设权限，重复 enable 不产生变更。
        os::run '创建 Caddy 配置投放目录' -- mkdir -p "${CADDY_INBOX}"
        os::run '让 Caddy 用户能读投放目录' -- chown root:caddy "${CADDY_INBOX}"
        os::run '收紧 Caddy 投放目录权限' -- chmod 0750 "${CADDY_INBOX}"
    fi

    # 面板登录密码。**复用已有的**：反复走这条路径（比如 update 后重装
    # unit）不该每次都换一次密码，把已经记住密码的人全部踢出去。
    # 要换新密码：oneserver secure del web.basic_auth，再 disable/enable 一遍
    local pass='' hash=''
    if os::secure_load "${WEB_AUTH_KEY}" pass; then
        # 密码没换就沿用片段里已有的哈希。**bcrypt 每次加盐**，同一个密码
        # 每次算出的哈希都不一样 —— 照算的话片段内容每次都「变了」，
        # os::install_template 的幂等性被绕过，每次 enable 都要白重载一次
        # Caddy，而 enable 是 update 之后的例行动作。
        # 片段里有哈希 ⇒ 它就是这个密码的：哈希只在这里写，而密码只在
        # 凭据库里没有时才重新生成（那条路走下面的分支）。
        if [[ -r ${CADDY_SNIPPET} ]]; then
            # 用 `[$]` 而不是 `\$`：bcrypt 哈希以 `$2a$` 开头，写成 `\$`
            # 会被 shellcheck 当成一个没能展开的变量（字符类里没有这个歧义）。
            # 注意别让注释以 shellcheck 这个词开头 —— 那是它的指令前缀
            os::query -- sed -n \
                's/^[[:space:]]*admin[[:space:]]\{1,\}\([$]2[aby][$][^[:space:]]\{1,\}\).*/\1/p' \
                "${CADDY_SNIPPET}" || true
            hash=${OS_RUN_OUTPUT}
        fi
    else
        os::query --timeout 10 -- openssl rand -hex 16 || os::die 1 '生成面板密码失败'
        pass=${OS_RUN_OUTPUT}
        [[ ${#pass} -ge 16 ]] || os::die 1 '生成的密码长度异常，拒绝继续'
        os::secure_set "${WEB_AUTH_KEY}" "${pass}" || os::die 1 '保存面板密码失败'
    fi

    # Caddyfile 的 basic_auth 只认哈希，不认明文；密码经 stdin 送进 caddy，
    # 不进 argv（ps 对同机所有用户可见，同 D63）
    if [[ -z ${hash} ]]; then
        os::run_out --stdin-secret "${pass}" '生成面板密码哈希' -- caddy hash-password \
            || os::die 1 '生成密码哈希失败'
        hash=${OS_RUN_OUTPUT}
        # dry-run 下这条根本没跑，**拿不到哈希是必然的，不是故障**。此前这里
        # 一路走到下面那句 `os::die 1 密码哈希为空` —— 干净机器上（Caddy 已装、
        # 片段还没生成）敲一次 `web enable --dry-run` 就是「预演直接报错」。
        # §10：跳过副作用之后真实状态与推演状态已分叉，遇到依赖未满足**禁止**
        # 报错退出，必须声明预演到哪一步并以 0 结束。
        if [[ ${OS_RUN_SKIPPED} -eq 1 ]]; then
            os::info '[dry-run] 预演到此为止：密码哈希要由 caddy hash-password 现算，它已被跳过，后面的片段内容推演不出来'
            return 0
        fi
    fi
    [[ -n ${hash} ]] || os::die 1 '密码哈希为空，拒绝写入配置'

    os::install_template --mode 0644 \
        "${OS_TEMPLATE_DIR}/caddy-dashboard.conf" "${CADDY_SNIPPET}" \
        "PORT=${WEB_PORT}" "PUBLIC_DIR=${OS_PUBLIC_DIR}" "AUTH_HASH=${hash}" || return 1
    os::state_resource_add "${COMPONENT}" file "${CADDY_SNIPPET}" || true
    return 0
}

validate_caddyfile() {
    local -a env_args=()
    local line
    if [[ -r ${CADDY_ENV_FILE} ]]; then
        while IFS= read -r line || [[ -n ${line} ]]; do
            [[ ${line} == *=* && ${line} != '#'* ]] || continue
            env_args+=(--env "${line}")
        done <"${CADDY_ENV_FILE}"
    fi
    os::query --timeout 60 ${env_args[@]+"${env_args[@]}"} \
        -- caddy validate --config "${1}" --adapter caddyfile
}

fix_caddy_log_owner() {
    [[ -d ${CADDY_LOG_DIR} ]] || return 0
    os::query -- find "${CADDY_LOG_DIR}" ! -user caddy -print -quit || return 0
    [[ -n ${OS_RUN_OUTPUT} ]] || return 0
    os::run '把 Caddy 日志目录交还给服务用户' -- chown -R caddy:caddy "${CADDY_LOG_DIR}"
}

# offer_caddy_import <片段是否有变动>
#
# 已经 import 过的机器上，这个片段就是 Caddy 正在跑的配置的一部分 —— 改了它
# 而不热重载，Caddy 继续用内存里的旧配置，而命令已经报了「面板已启用」。
# 换密码时这一点最要命：`enable` 说完成了，实际拦人的还是上一个密码；
# 首次启用时更糟，片段刚生成、还没被读进去，8730 是**不带认证**开着的。
offer_caddy_import() {
    local snippet_changed=${1:-0}
    [[ -f ${CADDY_SNIPPET} && -f ${CADDYFILE} ]] || return 0
    if os::query --timeout 5 -- grep -qE "${CADDY_IMPORT_RE}" "${CADDYFILE}"; then
        if ((snippet_changed == 1)); then
            os::systemd_reload "${CADDY_UNIT}" \
                || os::die 1 '面板片段已更新，但 Caddy 热重载失败 —— 它仍在运行旧配置'
            os::ok 'Caddy 已热重载，面板配置生效'
        fi
        return 0
    fi

    os::confirm --arg caddy-import \
        '将面板片段加入 Caddyfile 并热重载 Caddy？' n || return 0

    # 先在同目录副本上加入 import 并校验。主配置只在候选文件通过校验后才
    # 替换；否则现有站点继续使用原配置。
    if [[ ${OS_DRYRUN} -eq 1 ]]; then
        os::replace_line --append-if-missing --backup "${CADDYFILE}" \
            "${CADDY_IMPORT_RE}" \
            "${CADDY_IMPORT_LINE}"
        ((OS_REPLACE_CHANGED == 1)) && os::systemd_reload "${CADDY_UNIT}"
        return 0
    fi

    local candidate="${CADDYFILE}.oneserver-web-import.$$"
    os::run '准备 Caddyfile 校验副本' -- cp -- "${CADDYFILE}" "${candidate}"
    os::defer rm -f -- "${candidate}"
    os::replace_line --append-if-missing "${candidate}" \
        "${CADDY_IMPORT_RE}" \
        "${CADDY_IMPORT_LINE}" || os::die 1 '生成 Caddyfile 候选配置失败'
    validate_caddyfile "${candidate}" || {
        os::err '加入面板片段后的 Caddyfile 未通过校验，原配置未改动'
        os::info "${OS_RUN_OUTPUT}"
        os::die 1 'Caddyfile 校验失败'
    }

    os::record_change "在 ${CADDYFILE} 中加入面板片段 import"
    os::install_file --backup --mode 0640 "${candidate}" "${CADDYFILE}" \
        || os::die 1 '写入 Caddyfile 失败'
    os::run '设置 Caddyfile 属主' -- chown root:caddy "${CADDYFILE}"
    fix_caddy_log_owner
    os::systemd_reload "${CADDY_UNIT}" \
        || os::die 1 'Caddyfile 已写入，但热重载失败；服务仍在运行旧配置'
    os::run '清理 Caddyfile 校验副本' -- rm -f -- "${candidate}"
    os::ok 'Caddy 已纳入面板配置并热重载'
    return 0
}

do_enable() {
    # 已启用时也要走一遍页面就位：`oneserver update` 换的是 templates/ 下的
    # 模板，public/index.html 是安装那次拷过去的副本，不重新放的话升级完
    # 面板还是旧版，而用户没有任何迹象能看出来。
    # install_template 本身幂等（内容一致就不写），所以这里重复跑无代价。
    if web_enabled; then
        install_units || return 1
        os::install_template --mode 0644 \
            "${OS_TEMPLATE_DIR}/dashboard.html" "${OS_PUBLIC_DIR}/index.html" || return 1
        local page_changed=${OS_TEMPLATE_CHANGED}
        write_caddy_snippet || return 1
        local snippet_changed=${OS_TEMPLATE_CHANGED}
        if ((page_changed == 1)); then
            os::ok '面板页面已更新到当前版本'
        elif ((snippet_changed == 1)); then
            os::ok 'Caddy 面板片段已补齐'
        else
            os::ok '面板已启用，无需变更'
        fi
        print_access
        offer_caddy_import "${snippet_changed}"
        return 0
    fi

    install_units || return 1

    os::install_template --mode 0644 \
        "${OS_TEMPLATE_DIR}/dashboard.html" "${OS_PUBLIC_DIR}/index.html" || return 1
    os::state_resource_add "${COMPONENT}" file "${OS_PUBLIC_DIR}/index.html" || true

    local u
    for u in "${WEB_UNITS[@]}"; do
        os::systemd_enable "${u}" --now own || return 1
    done

    write_caddy_snippet
    local snippet_changed=${OS_TEMPLATE_CHANGED}

    # 显式登记 unit，**不等框架在退出时自动登记**：首轮采集就在下面几行，
    # 而自动登记发生在命令退出的 EXIT 钩子里 —— 那时首轮早跑完了，采到的
    # 组件资源清单是空的，面板要等下一轮慢档（最长 5 分钟）才自愈。
    # os::state_unit_add 对重复项是幂等的，退出时再登记一次没有代价。
    local unit
    for unit in oneserver-web-fast.service oneserver-web-fast.timer \
        oneserver-web-slow.service oneserver-web-slow.timer; do
        os::state_unit_add "${COMPONENT}" "own:${unit}" || true
    done

    # 立刻采一轮：否则页面开出来是空的，而用户没法区分「还没采」和「坏了」
    os::run '采集首轮面板数据' -- \
        "${OS_SCRIPT_DIR}/ops/web_collect.sh" --tier=all --non-interactive || true

    os::state_set "${COMPONENT}" "port=${WEB_PORT}" || true
    os::ok '面板已启用'
    print_access
    offer_caddy_import "${snippet_changed}"
    return 0
}

# 关掉面板之后，主 Caddyfile 里那行 import 就指向一个空目录了。问一句要不要
# 一并去掉，**默认否**：那是用户的主配置，而 §12「永不自动删除用户配置」；
# 何况他可能只是想临时停掉面板，过两天再 enable 回来。
#
# **incoming/ 里还有别的片段就不问。** 那一行 import 管的是整个目录，不是面板
# 专属；用户自己往里放过东西的话，去掉它会连那些一起打掉 —— 那就成了「关个面板
# 顺手废了别的站点」。这一步排在片段删除之后，所以「还剩几个」是真实剩余数。
drop_caddy_import() {
    [[ -f ${CADDYFILE} ]] || return 0
    os::query --timeout 5 -- grep -qE "${CADDY_IMPORT_RE}" "${CADDYFILE}" || return 0

    os::query --timeout 5 -- find "${CADDY_INBOX}" -maxdepth 1 -name '*.caddy' -print -quit || true
    if [[ -n ${OS_RUN_OUTPUT} ]]; then
        os::info "${CADDYFILE} 里的 import 留着没动 —— ${CADDY_INBOX}/ 下还有别的片段在用它"
        return 0
    fi

    os::warn "${CADDY_INBOX}/ 已经空了，而 ${CADDYFILE} 里还留着一行 ${CADDY_IMPORT_LINE}"
    os::confirm --arg caddy-unimport '把这一行也从 Caddyfile 去掉？' n || {
        os::info "留着了。要自己去掉就删 ${CADDYFILE} 里的这一行，然后 oneserver caddy reload"
        return 0
    }

    # 先在临时副本上删，校验过了才换主配置 —— 同 offer_caddy_import 的方向，
    # 只是反着来。框架的替换接口只会替换或追加，删一行得自己滤
    local dir candidate line
    local -a keep=()
    dir=$(os::tmpdir) || os::die 1 '无法创建临时目录'
    candidate="${dir}/Caddyfile.no-import"
    while IFS= read -r line || [[ -n ${line} ]]; do
        [[ ${line} =~ ${CADDY_IMPORT_RE} ]] && continue
        keep+=("${line}")
    done <"${CADDYFILE}"
    printf '%s\n' ${keep[@]+"${keep[@]}"} >"${candidate}"

    validate_caddyfile "${candidate}" || {
        os::err '去掉 import 之后的 Caddyfile 没通过校验，主配置一个字都没动'
        os::info "${OS_RUN_OUTPUT}"
        return 1
    }

    os::record_change "从 ${CADDYFILE} 去掉了面板片段的 import"
    os::install_file --backup --mode 0640 "${candidate}" "${CADDYFILE}" \
        || os::die 1 "写入 ${CADDYFILE} 失败"
    os::run '设置 Caddyfile 属主' -- chown root:caddy "${CADDYFILE}"
    fix_caddy_log_owner
    os::systemd_reload "${CADDY_UNIT}" \
        || os::die 1 "${CADDYFILE} 已更新，但热重载失败；服务仍在运行旧配置"
    os::ok "已从 ${CADDYFILE} 去掉 import 并热重载"
    return 0
}

do_disable() {
    local u
    for u in "${WEB_UNITS[@]}"; do
        os::systemd_remove "own:${u}" || true
    done
    os::systemd_remove 'own:oneserver-web-fast.service' || true
    os::systemd_remove 'own:oneserver-web-slow.service' || true

    local f
    for f in "${WEB_FILES[@]}"; do
        [[ -e "${OS_PUBLIC_DIR}/${f}" ]] || continue
        os::run '移除面板数据文件' -- rm -f -- "${OS_PUBLIC_DIR}/${f}" || true
    done
    if [[ -e ${CADDY_SNIPPET} ]]; then
        os::run '移除 Caddy 片段' -- rm -f -- "${CADDY_SNIPPET}" || true
    fi
    drop_caddy_import

    os::secure_del "${WEB_AUTH_KEY}" || true
    os::secure_del 'web.telegram_token' || true
    os::secure_del 'web.telegram_chat_id' || true
    os::state_del "${COMPONENT}" || true
    os::ok '面板已关闭'
    return 0
}

print_access() {
    os::kv '数据目录' "${OS_PUBLIC_DIR}"
    if [[ -f ${CADDY_SNIPPET} ]]; then
        os::box '如何查看' -- \
            "Caddy 片段已生成：${CADDY_SNIPPET}" \
            '让它生效：在 /etc/caddy/Caddyfile 顶层加一行 import incoming/*.caddy' \
            '然后 oneserver caddy reload' \
            "浏览器打开 http://<这台机器的地址>:${WEB_PORT}，用户名 admin" \
            '取密码：oneserver secure get web.basic_auth' \
            '安全提示：面板使用 HTTP 明文传输，请经 HTTPS 反代访问，不要直接暴露到公网。'
    else
        os::box '如何查看（未装 Caddy）' -- \
            '页面与数据已就位，但这台机器上没有 HTTP 服务' \
            "取回：scp -r <这台机器>:${OS_PUBLIC_DIR} ./os-panel" \
            '本地起任意静态服务再打开 index.html' \
            '直接双击打不开：浏览器不允许 file:// 页面读同目录的数据文件'
    fi
    return 0
}

# 离线报告 —— 把当前数据内嵌进页面，生成一个自包含的 HTML
#
# 用途：没装 Caddy（或不想开 HTTP）的机器上，scp 走这**一个文件**双击就能看。
# 在线模式下页面 fetch 同目录的数据文件，而浏览器不允许 file:// 页面读同目录
# 文件 —— 所以直接把 public/ 拷回本地双击 index.html 是打不开的，必须内嵌。
#
# 转义只做两步、且顺序不能反：先 `&` 后 `<`。反过来的话第一步产生的
# `&lt;` 会被第二步的 `&` 替换二次编码成 `&amp;lt;`，页面上就会显示出实体源码。
do_report() {
    local out="${OS_PUBLIC_DIR}/report.html"
    local html
    html=$(<"${OS_TEMPLATE_DIR}/dashboard.html") || {
        os::die 1 '读不到面板模板'
    }

    local blocks='' f body
    for f in "${WEB_FILES[@]}"; do
        [[ ${f} == index.html || ${f} == report.html ]] && continue
        [[ -r "${OS_PUBLIC_DIR}/${f}" ]] || continue
        body=$(<"${OS_PUBLIC_DIR}/${f}") || body=''
        body=${body//&/&amp;}
        body=${body//</&lt;}
        blocks+="<script type=\"text/plain\" data-file=\"${f}\">${body}</script>"$'\n'
    done

    if [[ -z ${blocks} ]]; then
        os::die 1 '还没有采集数据，先运行 oneserver web --action=refresh'
    fi

    # **插在主脚本之前，不是 </body> 之前**：HTML 是流式解析的，主脚本执行时
    # 排在它后面的 <script type="text/plain"> 还没进 DOM，querySelectorAll
    # 一个都找不到 —— 现场表现是报告页悄悄回退成在线模式，双击打开时
    # 因为 fetch 不到同目录文件而整页空白。
    os::write_public 'report.html' "${html/<script>/${blocks}<script>}" || return 1
    os::ok '离线报告已生成'
    os::kv '文件' "${out}"
    os::box '怎么看' -- \
        "取回：scp <这台机器>:${out} ." \
        '双击打开即可，不需要任何服务' \
        '注意：里面的数据是生成那一刻的快照，不会自动更新'
    return 0
}

do_status() {
    local u
    for u in "${WEB_UNITS[@]}"; do
        probe::service_enabled "${u}"
        local en=${OS_PROBE_VALUE}
        probe::service_active "${u}"
        os::kv "${u}" "${en} / ${OS_PROBE_VALUE}"
        probe::timer_next "${u}"
        [[ -n ${OS_PROBE_VALUE} ]] && os::kv '  下次触发' "${OS_PROBE_VALUE}"
    done

    # 页面本身是启用时装的静态文件，**不该报「N 秒前」**：那会让人以为它
    # 也在被刷新，于是把一个正常的旧时间戳当成故障
    if [[ -f "${OS_PUBLIC_DIR}/index.html" ]]; then
        # 装出去的是模板的副本，`oneserver update` 只换模板不换副本。
        # 比一下，不然升级完面板还是旧版而没有任何迹象
        if os::query --timeout 5 -- \
            cmp -s "${OS_TEMPLATE_DIR}/dashboard.html" "${OS_PUBLIC_DIR}/index.html"; then
            os::kv '面板页面' '已就位（与当前版本一致）'
        else
            os::warn '面板页面与当前版本不一致，跑 oneserver web --action=enable 更新'
        fi
    else
        os::warn '面板页面缺失，跑 oneserver web --action=enable 重装'
    fi

    # 采集产物才有新鲜度。阈值取采集周期的 3 倍：偶尔错过一轮是正常的，
    # 连着错过三轮就说明 timer 或采集本身出了问题。
    #
    # **components.tsv / containers.tsv / backups.tsv 不看时间**：
    # `os::write_public` 内容没变就不重写（避免换 inode 让正在读的客户端拿到
    # 半截），而这三份数据只在装卸组件、容器起停、跑备份时才变。拿 mtime 判断
    # 它们，一台稳定运行的机器上会天天报「已过期」——一个每天误报的检查，
    # 等于没有检查。
    local f now mtime age limit
    printf -v now '%(%s)T' -1
    for f in "${WEB_FILES[@]}"; do
        case ${f} in
            index.html | report.html) continue ;;
            components.tsv | containers.tsv | backups.tsv)
                if [[ -f "${OS_PUBLIC_DIR}/${f}" ]]; then
                    os::kv "${f}" '已就位（内容变了才重写）'
                else
                    os::warn "${f}：缺失"
                fi
                continue
                ;;
            probe-slow.tsv | firewall.tsv) limit=900 ;;
            history.tsv) limit=90 ;;
            *) limit=30 ;;
        esac
        if [[ ! -f "${OS_PUBLIC_DIR}/${f}" ]]; then
            os::warn "${f}：缺失"
            continue
        fi
        mtime=$(stat -c %Y -- "${OS_PUBLIC_DIR}/${f}" 2>/dev/null || printf '0')
        age=$((now - mtime))
        if [[ ${age} -gt ${limit} ]]; then
            os::warn "${f}：${age} 秒前（已过期，采集器可能没在跑）"
        else
            os::kv "${f}" "${age} 秒前"
        fi
    done

    if [[ -f ${CADDY_SNIPPET} ]]; then
        os::kv 'Caddy 片段' "${CADDY_SNIPPET}"
    fi
    return 0
}

# 告警**由面板的定时采集驱动**：web_notify.sh 挂在 oneserver-web-fast.service
# 的 ExecStartPost 上，读的是 web_collect 生成的 alerts.tsv。面板没启用时这条
# 链一次都不会跑 —— 配好令牌却收不到任何消息，而屏幕上刚打过一个 ✓。
# 所以这里必须当场把话说清，不能等用户过几天来问「为什么没告警」
do_telegram() {
    local token='' chat=''
    os::require_cmd curl
    os::ask_secret '请输入 Telegram Bot Token' token
    os::ask --match '^-?[0-9]+$' --hint 'Telegram 数字 chat ID' --arg telegram-chat-id \
        '请输入 Telegram chat ID' chat
    os::secure_set 'web.telegram_token' "${token}" || os::die 1 '保存 Telegram Token 失败'
    os::secure_set 'web.telegram_chat_id' "${chat}" || os::die 1 '保存 Telegram chat ID 失败'
    os::ok 'Telegram 通知已配置；首次采集只建立基线，之后新增告警与恢复才会发送'

    # 判据是 fast 那个 timer：web_notify 挂在它的 service 上，slow 那条不发通知
    probe::service_active "${WEB_UNITS[0]}"
    if [[ ${OS_PROBE_VALUE} != active ]]; then
        os::warn "${WEB_UNITS[0]} 没在跑，告警不会被触发 —— 先选「启用面板」"
    fi
    return 0
}

do_refresh() {
    os::run '刷新面板数据' -- \
        "${OS_SCRIPT_DIR}/ops/web_collect.sh" --tier=all --non-interactive \
        || os::die 1 '刷新面板数据失败'
    os::ok '面板数据已刷新'
}

dispatch() {
    case ${1} in
        status) do_status ;;
        enable) do_enable ;;
        disable) do_disable ;;
        report) do_report ;;
        telegram) do_telegram ;;
        refresh) do_refresh ;;
        *) os::die 2 "未知操作「${1}」，可用：status enable disable report telegram refresh" ;;
    esac
}

main() {
    # 告警排在启停之后、离线报告之前：它是这一屏里第二常用的东西（配一次，
    # 之后出事全靠它），从前排在第四位，用户得先扫过两个不相干的选项才看到
    os::action_menu --overview do_status --arg action '操作' dispatch \
        'enable=启用面板' 'disable=关闭面板' \
        'telegram=配置 Telegram 告警通知' \
        'refresh=刷新面板数据' 'report=生成离线报告'
}

main "$@"
