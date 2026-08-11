#!/bin/bash
#
# 数据库管理
#
# @command      mariadb
# @name         MariaDB
# @group        db
# @order        10
# @requires     mariadb
# @privilege    root
# @requires_lib >= 4.6
# @provides     db:<name>
# @args         [--action=<list|create|delete|backup|restore|allow-containers>] [--name=<库名>] [--user=<用户名>] [--allow-any-host=<y|n>] [--auto-password=<y|n>] [--file=<备份文件>] [--confirm-drop=<库名>] [--allow-containers=<y|n>]
# @description  创建、删除、备份、恢复数据库与关联账号
#

set -Eeuo pipefail
IFS=$'\n\t'
PATH='/usr/sbin:/usr/bin:/sbin:/bin'
export PATH
umask 027

source /opt/oneserver/lib/bootstrap.sh

# ------------------------------------------------------------------
# 这个脚本一次核销三条缺陷，每一条都对应下面一段具体写法
#
# ## K9 · SQL 全部字符串拼接
#
# 旧脚本：`execute_mysql "SHOW DATABASES LIKE '$db_name';"`，库名、用户名、
# 密码全部来自用户输入，未做任何转义直接进 SQL。这里**一律经 lib/sql.sh**：
# 标识符走 `os::sql_ident`（反引号 + 翻倍转义），值走 `os::sql_str`
# （按 MySQL 转义表处理）。两个函数都有真库用例守着（tests/lib/sql.bats
# 让 MariaDB 自己当裁判，把恶意输入原样存进去再读出来比对）。
#
# ## K3 · 账号默认 `'user'@'%'` + GRANT ALL
#
# 旧脚本把 `DB_USER_HOST` 写死成 `%`，注释说「适用于 Docker 或远程连接」——
# 那是作者自己的用法。与 K2（监听 0.0.0.0 默认 y）叠加，就得到
# 「数据库监听全网 + 账号可从任意主机连 + 无防火墙」的组合。
#
# 现在默认 `localhost`，`%` 要显式给 `--allow-any-host` 且默认 `n`。
# `GRANT ALL` 保留但**只授到单库**（`ON <db>.*`），不是全局权限 —— 一个
# 应用账号对自己的库有全权是正常的，对整个实例有全权不是。
#
# ## K12 · source secure.conf
#
# 旧脚本 `source "$SECURE_CONF"` 取 root 密码 —— source 一个配置文件等于
# 执行它，与写入端不转义叠加就是完整的 RCE 链条。
#
# 这里连取密码这一步都没有：**按 D121，oneserver 的所有脚本一律以 OS root
# 走 unix_socket 连库**。`os::sql_*` 不带 `--defaults-file` 时就是这条路。
#
# ## 旧的 db_user_mapping.conf 也没了
#
# 那是一份自己维护的「库 → 用户」注册表，而 state 就是干这个的。
# 改用组件标识 `db:<库名>`，`list` 直接读 state。
#
# **给 F6 的提醒**：`db:*` 不登记任何 pkg/file/divert/alt/unit 资源 ——
# 它没有这些东西，而它的实体（数据库本身）按规范属「永不自动删除」。
# 想删库只有一条路：`oneserver mariadb delete`，那里走 `os::destroy_confirm`。

readonly DB_DUMP_DIR="${OS_BACKUP_DIR}/db"

# 「允许容器访问」要动的两样东西。**与 install_mariadb.sh 是同两个常量**——
# 那边装的时候定监听地址，这边是装完之后按需放开给容器，改的是同一个文件、
# 同一个端口。
readonly MARIADB_CONF='/etc/mysql/mariadb.conf.d/50-server.cnf'
readonly MARIADB_UNIT='mariadb.service'
readonly MARIADB_PORT='3306'
# ufw 的措辞随 locale 变，而下面要按文本判定放行了没有（同 web.sh / ufw_manager）
readonly UFW_ENV='LC_ALL=C'

# 函数之间的返回通道。**不用 `printf` + `$( )`** —— os::info / os::ok / os::run
# 的提示都默认打到 stdout，会被一起吃进变量（D135 就是这么栽的）。
DB_DUMP_FILE=''

# 供 os::select 用的候选清单，由下面两个 load_* 填。
# 同样走全局数组而不是命令替换：user_databases 的结果在 OS_RUN_OUTPUT 里，
# 而 `$( )` 是子 shell，执行状态与查询失败都传不出来。
DB_CHOICES=()

# ------------------------------------------------------------------

# 库名与用户名的合法字符。收紧到这个集合不是因为转义不住 ——
# `os::sql_ident` 处理得了任何字符 —— 而是因为库名会出现在**文件名**
# （备份文件）和 **state 的实例标识**里，那两处各有各的语法。
# 与其在三套规则之间来回翻译，不如一开始就只收都认的那部分。
# **必须与 state 的组件标识规则一致**，所以直接问 state 自己。
#
# 库名会成为 `db:<库名>` 的实例部分，而 state 的实例名只收 `[a-z0-9]` 开头。
# 这里原来松一档（允许下划线开头、允许大写），后果不是「校验漏了」那么轻：
# 库建好了、账号建好了、密码也写进凭据库了，最后 os::state_set 才以
# 「组件标识不合法」失败 —— 而屏幕上照样打出「✓ 已创建」，state 里却什么都没有，
# 于是 uninstall 再也找不到它。两套规则各写一份，迟早就是这个下场。
#
# 额外再收一道 `.`：state 的实例名允许点，但库名会进备份文件名
# `<库名>-20260804-120000.sql.gz`，点会让恢复时的解析对不上。
valid_name() {
    [[ ${1} =~ ^[a-z0-9][a-z0-9_-]*$ ]] || return 1
    os::state_id_valid "db:${1}"
}

# 用户库列表，结果留在 OS_RUN_OUTPUT 里。系统库排除掉 ——
# 它们不是用户的东西，列出来只会让人误删。
#
# **这里一个字都不许往 stdout 打。** 原来多了一行 `printf '%s\n' "${OS_RUN_OUTPUT}"`
# （第一版留下的），`--output=json` 下就在 JSON 信封前面多出两行裸库名，
# 任何解析器都会当场报错 —— 而文本模式下看不出任何异常（
# json 模式整层静默，靠的是所有输出都走 os::* 语义函数）。
user_databases() {
    os::sql_query '列出用户数据库' -- \
        "SELECT schema_name FROM information_schema.schemata
         WHERE schema_name NOT IN ('information_schema','performance_schema','mysql','sys')
         ORDER BY schema_name;" || return 1
    return 0
}

db_exists() {
    local q
    q=$(os::sql_str "${1}")
    os::sql_query '检查数据库是否存在' -- "SHOW DATABASES LIKE ${q};" || return 1
    [[ -n ${OS_RUN_OUTPUT} ]]
}

user_exists() {
    local qu qh
    qu=$(os::sql_str "${1}")
    qh=$(os::sql_str "${2}")
    os::sql_query '检查账号是否存在' -- \
        "SELECT User FROM mysql.global_priv WHERE User = ${qu} AND Host = ${qh};" || return 1
    [[ -n ${OS_RUN_OUTPUT} ]]
}

# ------------------------------------------------------------------

# 备份目录里本工具产生的归档 → DB_CHOICES，新的在前
load_backup_choices() {
    DB_CHOICES=()
    os::query --timeout 10 -- sh -c \
        "ls -1t '${DB_DUMP_DIR}' 2>/dev/null | grep -E '[.]sql[.]gz\$'" || true
    local one
    local IFS=$'\n'
    for one in ${OS_RUN_OUTPUT}; do
        [[ -n ${one} ]] || continue
        DB_CHOICES+=("${one}")
    done
    return 0
}

# 总览表的编号就是当前操作周期的选择符，避免把同一批库再打印一遍。
# 与容器清单同一套：清单缓存进数组，总览按它渲染，动作按它把编号翻回库名 ——
# 序号与清单同源，才不会出现「看到的 3 号」与「删掉的 3 号」不是一个。
# 对删库这种不可逆动作，这条比别处更要紧。
DB_LIST_READY=0
DB_NAMES=()
DB_ACCOUNTS=()

load_db_rows() {
    DB_NAMES=()
    DB_ACCOUNTS=()
    DB_LIST_READY=1

    user_databases || os::die 1 '查询数据库列表失败'
    local name user host
    local IFS=$'\n'
    for name in ${OS_RUN_OUTPUT}; do
        [[ -n ${name} ]] || continue
        # 关联账号从 state 读。读不到不是错：用户手工建的库本来就不在 state 里
        user=$(os::state_get "db:${name}" user)
        host=$(os::state_get "db:${name}" host)
        DB_NAMES+=("${name}")
        if [[ -n ${user} ]]; then
            DB_ACCOUNTS+=("${user}@${host}")
        else
            DB_ACCOUNTS+=('（非本工具创建，无关联账号记录）')
        fi
    done
    return 0
}

# 选一个已有的库：编号或库名都收。
#
# **清单没上屏时先列一遍**：`oneserver mariadb delete` 从命令行直接跑时总览
# 不会显示（它只在交互的动作清单里跑），让人对着一个看不见的清单输编号不行。
#
# 非交互下 os::ask 没有默认值就以 2 停下 —— 绝不替用户挑第一个来删，
# 编号打错也不会落回第一项。
select_database() {
    local __db_out=${1} __db_prompt=${2}
    [[ ${DB_LIST_READY} -eq 1 ]] || action_list
    [[ ${#DB_NAMES[@]} -gt 0 ]] || os::die 2 '没有用户创建的数据库'

    local __db_picked=''
    os::ask --arg name "${__db_prompt}（输入上方编号；命令行可传 --name）" __db_picked
    if [[ ${__db_picked} =~ ^[0-9]+$ ]]; then
        local -i __db_sel=$((__db_picked - 1))
        ((__db_sel >= 0 && __db_sel < ${#DB_NAMES[@]})) \
            || os::die 2 "没有编号为「${__db_picked}」的数据库"
        __db_picked=${DB_NAMES[__db_sel]}
    fi
    db_exists "${__db_picked}" || os::die 2 "数据库 ${__db_picked} 不存在"
    printf -v "${__db_out}" '%s' "${__db_picked}"
    return 0
}

action_list() {
    load_db_rows
    os::screen_heading '数据库'
    if [[ ${#DB_NAMES[@]} -eq 0 ]]; then
        os::info '没有用户创建的数据库'
        os::output 0 count=0
        return 0
    fi

    local -a cells=()
    local -i i
    for ((i = 0; i < ${#DB_NAMES[@]}; i++)); do
        cells+=("[$((i + 1))]" "${DB_NAMES[i]}" "${DB_ACCOUNTS[i]}")
        os::output_item name="${DB_NAMES[i]}" account="${DB_ACCOUNTS[i]}"
    done
    os::table '编号' '数据库' '关联账号' -- "${cells[@]}"
    os::output 0 count="${#DB_NAMES[@]}"
    return 0
}

action_create() {
    local name=''
    os::ask --validate valid_name --hint '只收小写字母、数字、下划线、短横，且以字母数字开头' --arg name '新数据库名称' name
    if db_exists "${name}"; then
        os::die 2 "数据库 ${name} 已存在"
    fi

    local user=''
    os::ask --validate valid_name --hint '只收小写字母、数字、下划线、短横，且以字母数字开头' --arg user '关联账号名' user "${name}"

    # K3 就在这里。默认 localhost，`%` 是降低安全性的选项 → 默认必须 n
    # 默认值取 L0 的 OS_DEFAULT_DB_USER_HOST（用户可在 conf 里改），
    # 不在脚本里写死 —— defaults.sh 里那一项本来就是为 K3 准备的
    local host=${OS_DEFAULT_DB_USER_HOST}
    if os::confirm --arg allow-any-host \
        '允许这个账号从任意主机连接（%）？默认只允许本机' n; then
        host='%'
        os::warn "补偿控制：账号权限只到 ${name} 这一个库；请确认 MariaDB 的 bind-address 与防火墙确实只对可信来源开放"
    fi

    if user_exists "${user}" "${host}"; then
        os::die 2 "账号 ${user}@${host} 已存在"
    fi

    # 密码：默认自动生成，同 install_redis / install_mariadb。
    # 没有 --password=<值> 这种参数 —— 凭据进 argv 就是 ps 可见
    local pass=''
    if os::confirm --arg auto-password '自动生成账号密码？（选否则手动输入）' y; then
        os::query --timeout 10 -- openssl rand -hex 16 || os::die 1 '生成密码失败'
        pass=${OS_RUN_OUTPUT}
        [[ ${#pass} -ge 16 ]] || os::die 1 '生成的密码长度异常，拒绝继续'
    else
        os::ask_secret --confirm "请输入 ${user} 的密码" pass
    fi

    # 凭据先落库再进 SQL：secure_set 会登记脱敏，之后任何日志/审计里都没有明文。
    # key 带命名空间—— K7 的教训是扁平 key 遇到第二个同类事物就静默覆盖
    local key="db.${name}.password"
    os::secure_set "${key}" "${pass}" || os::die 1 '保存账号密码失败'

    local qdb quser qhost qpass
    qdb=$(os::sql_ident "${name}")
    quser=$(os::sql_str "${user}")
    qhost=$(os::sql_str "${host}")
    qpass=$(os::sql_str "${pass}")

    os::record_change "创建了数据库 ${name} 与账号 ${user}@${host}"

    # 三步都失败可回滚：建库、建号、授权。任一步失败就把前面的撤掉 ——
    # 半个数据库比没有更麻烦，而这几样都是本次刚造出来的，撤销不会碰用户既有资产
    os::defer os::sql_exec --allow-fail '回滚：删除刚建的账号' -- \
        "DROP USER IF EXISTS ${quser}@${qhost};"
    os::defer os::sql_exec --allow-fail '回滚：删除刚建的数据库' -- \
        "DROP DATABASE IF EXISTS ${qdb};"

    os::sql_exec '创建数据库' -- \
        "CREATE DATABASE ${qdb} CHARACTER SET ${OS_DEFAULT_DB_CHARSET} COLLATE ${OS_DEFAULT_DB_COLLATE};"
    os::sql_exec '创建数据库账号' -- \
        "CREATE USER ${quser}@${qhost} IDENTIFIED BY ${qpass};"
    # GRANT ALL 但**只到这一个库**（ON <db>.*），不是全局权限
    os::sql_exec '授予单库权限' -- \
        "GRANT ALL PRIVILEGES ON ${qdb}.* TO ${quser}@${qhost}; FLUSH PRIVILEGES;"

    # `engine` 记的是这个库归哪个数据库引擎。现在只有一种取值，但它是**持久化
    # 数据**：代码随时能改，已经写进用户机器的记录改不了。将来多一个引擎时，
    # 没有这一键的存量记录只能靠猜，而猜错就是拿另一套工具去恢复这份备份。
    os::state_set "db:${name}" engine=mariadb user="${user}" host="${host}" \
        charset="${OS_DEFAULT_DB_CHARSET}" collate="${OS_DEFAULT_DB_COLLATE}"

    # dry-run 下三条 sql_exec + secure_set + state_set 全被各自的 dry-run
    # 分支跳过，一个字节都没写——不看 OS_DRYRUN 就往下打「已创建」+
    # changed=yes，是 D15 说的「会撒谎的 dry-run」（同 podman image/volume）
    if [[ ${OS_DRYRUN} -eq 1 ]]; then
        os::info "[dry-run] 将创建数据库 ${name} 与账号 ${user}@${host}"
        os::output 0 name="${name}" user="${user}" host="${host}" changed=dry-run
        return 0
    fi

    os::kv '数据库' "${name}" \
        '账号' "${user}@${host}" \
        '字符集' "${OS_DEFAULT_DB_CHARSET} / ${OS_DEFAULT_DB_COLLATE}" \
        '密码' "已存入凭据库，键名 ${key}"
    # **密码不打在屏幕上**（旧脚本会打，还提示「请妥善保存」）——
    # 终端会进滚动缓冲、进录屏、进贴到群里的截图。要取值：
    os::info "取密码：oneserver secure get ${key}"
    os::ok "数据库 ${name} 与账号 ${user}@${host} 已创建"
    os::output 0 name="${name}" user="${user}" host="${host}" changed=yes
    return 0
}

action_delete() {
    local name=''
    select_database name '要删除哪个数据库'

    local user host
    user=$(os::state_get "db:${name}" user)
    host=$(os::state_get "db:${name}" host)

    # 规范：不可逆操作**必须先落副本**。删库之前先 dump 一份，
    # 这是「确认了才删」之外的第二道 —— 人是会打对全名然后后悔的
    local dump=''
    if [[ ${OS_DRYRUN} -ne 1 ]]; then
        dump_database "${name}" || os::die 1 '删除前的备份失败，已中止（不会在没有副本的情况下删库）'
        dump=${DB_DUMP_FILE}
        os::ok "删除前已备份到 ${dump}"
    fi

    local -a items=("数据库 ${name}（含全部表与数据）")
    [[ -n ${user} ]] && items+=("账号 ${user}@${host}")
    [[ -n ${dump} ]] && items+=("（已先备份到 ${dump}，删除后可用 oneserver mariadb restore 恢复）")

    # 打全名确认，--yes 对它不生效，非交互下要 --force-destroy
    if ! os::destroy_confirm --arg confirm-drop "${name}" -- "${items[@]}"; then
        # 文案得跟事实对得上：删除前的副本在确认点之前就已经落盘（规范要求
        # 「不可逆操作必须先落副本」），放弃删除不会把它撤销掉
        if [[ -n ${dump} ]]; then
            os::info "已取消，数据库未删除（删除前的备份 ${dump} 仍保留）"
        else
            os::info '已取消，未删除任何东西'
        fi
        os::output 0 name="${name}" changed=no
        return 0
    fi

    local qdb
    qdb=$(os::sql_ident "${name}")
    os::record_change "删除了数据库 ${name}"
    os::sql_exec '删除数据库' -- "DROP DATABASE ${qdb};"

    if [[ -n ${user} ]]; then
        local quser qhost
        quser=$(os::sql_str "${user}")
        qhost=$(os::sql_str "${host}")
        os::record_change "删除了数据库账号 ${user}@${host}"
        os::sql_exec '删除数据库账号' -- \
            "DROP USER IF EXISTS ${quser}@${qhost}; FLUSH PRIVILEGES;"
    fi

    # 凭据与 state 一并清掉，否则下次建同名库会读到上一个的密码
    os::secure_del "db.${name}.password" || true
    os::state_del "db:${name}" || true

    os::ok "数据库 ${name} 已删除（副本保留在 ${dump:-无}）"
    os::output 0 name="${name}" backup="${dump}" changed=yes
    return 0
}

# mysqldump | gzip，结果路径写进 DB_DUMP_FILE。
#
# 用 `sh -c` 是因为这里要的是一条**管道**，而 os::run 只接一条命令。
# 进 `sh -c` 的每一个变量都必须是本脚本自己造的或过了白名单的：
# 库名经 shell_safe_name（只允许 [A-Za-z0-9_-]），路径由 DB_DUMP_DIR 与
# 时间戳拼成。**没有任何一段直接来自用户输入** —— 这是规范禁 eval 的同一条
# 思路：与其想清楚 sh 的引号规则，不如让不合规的东西根本进不来。
dump_database() {
    local name=${1}
    DB_DUMP_FILE=''
    shell_safe_name "${name}"

    os::run '创建数据库备份目录' -- mkdir -p "${DB_DUMP_DIR}"
    os::run '收紧备份目录权限' -- chmod 0700 "${DB_DUMP_DIR}"

    local ts
    printf -v ts '%(%Y%m%d-%H%M%S)T' -1
    local out="${DB_DUMP_DIR}/${name}-${ts}.sql.gz"

    # 写临时文件再 mv：中途失败留下的半截 .sql.gz 看起来是个正常备份，
    # 而它恢复出来的是半个数据库 —— 比没有备份更危险
    local tmp="${out}.partial"
    # charset/name/tmp 经位置参数（"$1"/"$2"/"$3"）传给 sh -c，不拼进脚本文本——
    # 同 restore.sh 的 snapshot_db：值不管校验是否有漏网之鱼，都不会被当成 shell 语法解释。
    # shellcheck disable=SC2016  # 理由：$1/$2/$3 是内层 sh 的位置参数，故意不让外层展开
    if ! os::run --allow-fail '导出数据库' -- sh -c \
        'mysqldump --single-transaction --routines --triggers --default-character-set="$1" "$2" | gzip -c > "$3"' \
        _ "${OS_DEFAULT_DB_CHARSET}" "${name}" "${tmp}"; then
        os::run --allow-fail '清理未完成的备份' -- rm -f "${tmp}"
        return 1
    fi
    os::run '就位备份文件' -- mv -f "${tmp}" "${out}"
    os::run '收紧备份文件权限' -- chmod 0600 "${out}"
    DB_DUMP_FILE=${out}
    return 0
}

# 库名进命令行前的白名单确认。valid_name 已经把库名限死在 [A-Za-z0-9_-]，
# 这里再确认一遍 —— 备份/恢复那两条管道靠的就是这个前提。
shell_safe_name() {
    valid_name "${1}" || os::die 2 "数据库名「${1}」不能安全地进入命令行"
    return 0
}

action_backup() {
    local name=''
    select_database name '要备份哪个数据库'

    if [[ ${OS_DRYRUN} -eq 1 ]]; then
        os::info "[dry-run] 将把 ${name} 备份到 ${DB_DUMP_DIR}/"
        os::output 0 name="${name}" changed=dry-run
        return 0
    fi

    dump_database "${name}" || os::die 1 "备份 ${name} 失败"
    local out=${DB_DUMP_FILE}
    os::kv '数据库' "${name}" '备份文件' "${out}"
    os::ok "已备份 ${name}"
    os::output 0 name="${name}" file="${out}" changed=yes
    return 0
}

action_restore() {
    load_backup_choices
    [[ ${#DB_CHOICES[@]} -gt 0 ]] \
        || os::die 2 "${DB_DUMP_DIR} 里没有备份文件（先跑 oneserver mariadb backup）"

    # 备份文件不在总览里（那一屏列的是库），所以这里自己列一份带编号的表 ——
    # 与其余「从清单里挑对象」的地方同一套写法：列表格 + 输编号
    local -a cells=()
    local -i i
    for ((i = 0; i < ${#DB_CHOICES[@]}; i++)); do
        cells+=("[$((i + 1))]" "${DB_CHOICES[i]}")
    done
    os::table '编号' '备份文件（新的在前）' -- "${cells[@]}"

    local file=''
    os::ask --arg file '从哪一份备份恢复（输入上方编号；命令行可传 --file）' file
    if [[ ${file} =~ ^[0-9]+$ ]]; then
        local -i sel=$((file - 1))
        ((sel >= 0 && sel < ${#DB_CHOICES[@]})) \
            || os::die 2 "没有编号为「${file}」的备份文件"
        file=${DB_CHOICES[sel]}
    fi

    # **只收文件名，不收路径**，而且必须匹配本工具自己产生的命名。
    #
    # 这不是为了省事：恢复要跑一条 `gunzip … | mysql …` 的管道，而管道只能
    # 经 `sh -c` 表达。用户给的任意路径进 `sh -c` 就是一条注入面，
    # 而把它限死成「DB_DUMP_DIR 里、由本工具按固定格式命名的那些文件」之后，
    # 进命令行的每一个字符都是本脚本自己造的（规范禁 eval 的同一条思路）。
    # 代价是不能恢复别处的 dump —— 外来转储走
    # `oneserver restore --from=external --target=db:<库名>`，那条路自带清单审查
    # 与库级语句预扫描，不该在这里再开一个口子。
    local base=${file##*/}
    if [[ ${base} != "${file}" ]]; then
        os::err "--file 只接受文件名，不接受路径。本工具的备份都在 ${DB_DUMP_DIR}/"
        os::die 2 "别处来的转储用：oneserver restore --from=external --target=db:<库名>"
    fi
    if [[ ! ${base} =~ ^[a-zA-Z0-9_][a-zA-Z0-9_-]*-[0-9]{8}-[0-9]{6}\.sql\.gz$ ]]; then
        os::die 2 "认不出的备份文件名：${base}（应形如 <库名>-20260803-120000.sql.gz）"
    fi
    local path="${DB_DUMP_DIR}/${base}"
    [[ -f ${path} ]] || os::die 2 "备份文件不存在：${path}"

    # 目标库名从文件名推：`<库名>-20260803-120000.sql.gz`
    local name=${base%%-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-*}
    valid_name "${name}" || os::die 2 "从文件名推出的库名不合法：${name}"
    shell_safe_name "${name}"

    db_exists "${name}" || os::die 2 "目标数据库 ${name} 不存在，请先 oneserver mariadb create --name=${name}"

    # 恢复会覆盖现有数据 —— 与删库同级，走 destroy_confirm。
    # 先把现状 dump 一份，恢复错了还能回去
    local pre=''
    if [[ ${OS_DRYRUN} -ne 1 ]]; then
        dump_database "${name}" || os::die 1 '恢复前的备份失败，已中止'
        pre=${DB_DUMP_FILE}
        os::ok "恢复前已备份当前内容到 ${pre}"
    fi

    if ! os::destroy_confirm --arg confirm-drop "${name}" -- "数据库 ${name} 的现有内容将被 ${base} 覆盖" "（已先备份到 ${pre:-无}）"; then
        os::info '已取消，未改动任何数据'
        os::output 0 name="${name}" changed=no
        return 0
    fi

    os::record_change "用 ${base} 覆盖了数据库 ${name}"
    # 用 os::run 不用 os::query：这是**有副作用**的，dry-run 必须跳过它。
    # （虽然上面 destroy_confirm 在 dry-run 下已经返回 1 提前走掉了，
    #  但正确性不该依赖「另一处恰好拦住了」——那种依赖在重构里最先断。）
    # 同 dump_database：值经位置参数传给 sh -c，不拼进脚本文本
    # shellcheck disable=SC2016  # 理由：$1/$2/$3 是内层 sh 的位置参数，故意不让外层展开
    os::run '恢复数据库' -- sh -c \
        'gunzip -c "$1" | mysql --default-character-set="$2" "$3"' \
        _ "${path}" "${OS_DEFAULT_DB_CHARSET}" "${name}" \
        || os::die 1 "恢复失败，恢复前的副本在 ${pre}"

    os::ok "已从 ${base} 恢复 ${name}"
    os::output 0 name="${name}" file="${path}" pre_backup="${pre}" changed=yes
    return 0
}

# ------------------------------------------------------------------

# ==================================================================
# 允许容器访问数据库
# ==================================================================
#
# 解决的是一件很具体的事：容器里的应用要连宿主的 MariaDB，而宿主默认只监听
# 127.0.0.1、防火墙也默认拒绝，于是每建一个容器都要单独跑一趟放行。
#
# **放行的是探测出来的真实容器网段**，不是拍一个私有段。旧脚本写死
# `10.0.0.0/8`：实测 podman 默认只用 `10.88.0.0/16`，而 docker 默认的
# `172.17.0.0/16` 根本不在那个范围里 —— 开得过宽，而且对 docker 无效。
#
# **幂等且可刷新**：以后新建了容器网络（`172.18.0.0/16` …），重跑一次这个动作
# 就把缺的补上，已有的不动。这正是「容器一多就记不清哪个网段放行过」的解法。
#
# **不走「只绑网桥网关」那条路**（更安全但不实用）：每个容器网络有自己的网关，
# 新建一个网络就要多绑一个地址并重启数据库，容器一多就是持续的维护负担。
# 这里统一绑 0.0.0.0，边界交给防火墙 —— 代价是数据库在公网网卡上也监听着，
# 所以下面对 UFW 的要求是硬的：没有真正挡得住的防火墙就不动手。

# 这个网段放行过没有。按「端口 + 来源」认，不做子串匹配
db_subnet_allowed() {
    local subnet=${1} line
    probe::ufw_rules
    while IFS= read -r line; do
        [[ ${line} =~ ^\[[[:space:]]*[0-9]+\][[:space:]]+${MARIADB_PORT}(/tcp)?[[:space:]]+ALLOW[[:space:]]+IN[[:space:]]+${subnet//./\\.}([[:space:]]|$) ]] \
            && return 0
    done <<<"${OS_PROBE_VALUE}"
    return 1
}

action_allow_containers() {
    probe::container_subnets
    local subnets=${OS_PROBE_VALUE}
    if [[ -z ${subnets} ]]; then
        os::info '没有探测到任何容器网络 —— docker 与 podman 都没装，或者都没有带网段的网络'
        os::info '装了容器引擎、建过容器之后再回来跑这一步'
        os::output 0 subnets='' changed=no
        return 0
    fi

    local -a nets=()
    mapfile -t nets <<<"${subnets}"

    os::section '将要放行的容器网段'
    local n
    local -a cells=()
    for n in "${nets[@]}"; do
        cells+=("${n}" "$(db_subnet_allowed "${n}" && printf '已放行' || printf '本次新增')")
    done
    os::table '网段' '状态' -- "${cells[@]}"
    os::info "放行之后，这些网段里的容器可以连宿主的 ${MARIADB_PORT} 端口；其余来源仍被防火墙拒绝"

    # §15：放宽访问来源必须在同一步落实补偿控制，落实不了就拒绝执行。
    # 这里的补偿控制有两条 —— 放行范围只到实际网段（不是 Anywhere），
    # 以及要求防火墙本身真的挡得住。后者用与 install_mariadb 同一条判据。
    probe::ufw_active
    [[ ${OS_PROBE_VALUE} == yes ]] \
        || os::die 3 '防火墙没启用，放行无从谈起（而数据库会因此对全网监听）。先执行 oneserver firewall enable'
    probe::ufw_default_incoming
    case ${OS_PROBE_VALUE} in
        deny | reject) ;;
        *) os::die 3 "防火墙默认入站是 ${OS_PROBE_VALUE}，此时「只放行容器网段」没有意义 —— 没被规则覆盖的来源同样进得来。先把默认入站改成 deny" ;;
    esac

    os::warn "数据库的监听地址会改成 0.0.0.0（容器要够得着），此后挡在外面的只有防火墙"
    os::confirm --arg allow-containers '确认放行以上网段？' n \
        || os::die 130 '已取消，未做任何改动'

    local -i added=0
    for n in "${nets[@]}"; do
        db_subnet_allowed "${n}" && continue
        os::record_change "在 UFW 里放行 ${MARIADB_PORT}/tcp，来源 ${n}"
        os::run --env "${UFW_ENV}" '放行一个容器网段' -- \
            ufw allow from "${n}" to any port "${MARIADB_PORT}" proto tcp || return 1
        added+=1
    done
    if ((added > 0)); then
        os::run --env "${UFW_ENV}" '重载 UFW 使规则生效' -- ufw reload || return 1
    fi

    # 监听地址：容器连的是网桥网关，只听 127.0.0.1 的话规则放行了也连不上
    os::replace_line --backup "${MARIADB_CONF}" \
        '^[[:space:]]*#?[[:space:]]*bind-address[[:space:]]*=' 'bind-address            = 0.0.0.0' \
        || os::die 1 "${MARIADB_CONF} 里找不到 bind-address 行"
    if [[ ${OS_REPLACE_CHANGED} -eq 1 ]]; then
        os::record_change '把 MariaDB 的监听地址改成 0.0.0.0'
        os::systemd_restart "${MARIADB_UNIT}" || os::die 1 'MariaDB 重启失败，监听地址可能未生效'
    fi

    # 记进 state，下次刷新时看得出上次放行到哪
    local IFS=' '
    os::state_set mariadb container_access="${nets[*]}" || true

    os::ok "已放行 ${added} 个新网段（共 ${#nets[@]} 个）；以后新建了容器网络，重跑这一步即可补上"
    os::info "容器里连数据库用宿主网关地址，例如 docker 默认是 172.17.0.1、podman 默认是 10.88.0.1"
    os::output 0 subnets="${nets[*]}" added="${added}" changed="$((added > 0)) "
    return 0
}

main() {
    # 装没装、跑没跑一律经 probe（D93）。
    #
    # **元数据里特意没有 `@requires mariadb`**：那一条查的是 state，而 state 里
    # 只有经 oneserver 装过的东西。用户自己 `apt install mariadb-server` 装的、
    # 或者像测试镜像那样随镜像来的，state 里一个字都没有 —— 于是 `db list`
    # 会以「缺少依赖组件：mariadb」拒绝执行，而机器上的数据库正跑得好好的。
    # 容器验收第一次跑就是这个现场。
    probe::service_active mariadb.service
    if [[ ${OS_PROBE_VALUE} != active ]]; then
        os::die 3 'MariaDB 未在运行。先 oneserver install mariadb，或 systemctl start mariadb'
    fi
    os::require_cmd mysql mysqldump gzip gunzip openssl

    # 位置参数优先；没给才走交互（--action=... 由 os::select 自己从命令行取）
    local action=${1-}
    if [[ -n ${action} ]]; then
        dispatch "${action}"
        return 0
    fi

    os::action_menu --overview action_list --arg action '操作' dispatch \
        'create=新建数据库与账号' 'delete=删除数据库' \
        'backup=备份数据库' 'restore=从备份恢复' 'allow-containers=允许容器访问数据库'
}

dispatch() {
    case ${1} in
        list) action_list ;;
        create) action_create ;;
        delete) action_delete ;;
        backup) action_backup ;;
        restore) action_restore ;;
        allow-containers) action_allow_containers ;;
        *) os::die 2 "未知操作「${1}」，可用：list create delete backup restore allow-containers" ;;
    esac
}

main "$@"
