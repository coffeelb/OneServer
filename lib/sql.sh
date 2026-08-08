# lib/sql.sh —— L3 能力层：MySQL 方言的转义与执行
#
# **名字里的 SQL 不表示方言中立。** 下面的转义规则是 MySQL 家族的：标识符走
# 反引号、字符串走反斜杠转义表。PostgreSQL 两样都不同（标识符是双引号、
# 字符串是单引号翻倍），拿 `os::sql_ident` 去拼 PG 语句会拼出非法 SQL。
# 再有第二种方言时另开一组函数，不要在这几个里加分支 —— 调用方按名字选方言，
# 比让一个函数猜自己此刻面对的是谁可靠。
#
# 只依赖 L0–L2。**不依赖同层的 secure.sh** —— 凭据由调用方读好再传进来，
# 这个文件只管转义和执行。
#
# 这是 K9 的对症药：现状里库名、用户名、密码全部字符串拼进 SQL
# （`SHOW DATABASES LIKE '$db_name'`）。它没有用 eval，所以规范的
# 「禁止 eval」管不到，但同样是注入面 —— 需要一条独立条款。
#
# 标识符与字符串是**两套**转义规则，不能混用：
#   标识符（库名/表名/用户名）走反引号，内部反引号翻倍
#   字符串字面量走单引号，内部按 MySQL 的反斜杠转义表处理

# ==================================================================
# 转义 ——规范点名要过对抗性测试的两个函数
# ==================================================================

# os::sql_ident <标识符>   打印带反引号的安全标识符
#
# MySQL 的规则很简单：反引号内除反引号本身外一切字符都合法，
# 反引号写两遍表示一个。
#
# **不检查 NUL**：bash 的变量根本装不下 NUL（命令替换与 read 都会把它丢掉），
# 所以到这里的字符串一定不含 NUL。原本写的 `[[ ${id} == *$'\0'* ]]` 更糟 ——
# `$'\0'` 展开是空串，模式塌成 `**`，恒真，于是**所有输入都被拒绝**。
os::sql_ident() {
    local id=${1-}
    if [[ -z ${id} ]]; then
        ui::line error "SQL 标识符不能为空"
        return 2
    fi
    # 反引号用八进制码构造，不写字面量：写在单引号里 shellcheck 会当成命令替换
    # 报 SC2016，而加 disable 只是把它按下去，不如根本不出现这个字符
    local bt
    printf -v bt '\140'
    printf '%s%s%s\n' "${bt}" "${id//"${bt}"/"${bt}${bt}"}" "${bt}"
    return 0
}

# os::sql_str <值>   打印带单引号的安全字符串字面量
#
# 按 MySQL 默认模式（未开 NO_BACKSLASH_ESCAPES）的转义表处理。
# 顺序要紧：反斜杠必须第一个换，否则后面新产生的转义符会被二次转义。
os::sql_str() {
    local v=${1-}
    v=${v//\\/\\\\}
    v=${v//\'/\\\'}
    v=${v//\"/\\\"}
    v=${v//$'\n'/\\n}
    v=${v//$'\r'/\\r}
    v=${v//$'\x1a'/\\Z}
    printf "'%s'\n" "${v}"
    return 0
}

# ==================================================================
# 凭据传递 ——规范的第一优先通道
# ==================================================================

# os::sql_defaults_file <用户> <密码> [主机]   打印临时配置文件路径
#
# `mysql -p"$pass"` 会让密码出现在 ps 里，对同机任何用户可见 ——
# 比日志泄漏严重。MySQL 系工具都支持 --defaults-extra-file，
# 这是三条合规通道里的第一优先。
#
# 文件落在 os::tmpdir（/run 上的 tmpfs，0700 目录 + 0600 文件），
# **永远不落盘**，且随进程退出自动清理。
#
# 值必须加双引号并转义，不能裸写 `password=${pass}`。选项文件不是「等号右边
# 原样取走」：`#` 在行中任意位置开始注释、首尾空白被吃掉、反斜杠按转义表
# （`\s` `\t` `\n` …）解释。实测（my_print_defaults）：
#     password=abc#def ghi   →  --password=abc
# 密码被截成前三个字符，而且**不报任何错**，现场表现是「密码明明是对的却连不上」。
# 加引号后只剩反斜杠与双引号要转义，`#` 与空格都进得去。
os::sql_defaults_file() {
    local user=${1-} pass=${2-} host=${3:-localhost}
    local dir
    dir=$(os::tmpdir) || return 1
    local f="${dir}/my.cnf"

    local u=${user} p=${pass} h=${host}
    u=${u//\\/\\\\} && u=${u//\"/\\\"}
    p=${p//\\/\\\\} && p=${p//\"/\\\"}
    h=${h//\\/\\\\} && h=${h//\"/\\\"}

    local prev_umask
    prev_umask=$(umask)
    umask 077
    {
        printf '[client]\n'
        printf 'user="%s"\n' "${u}"
        printf 'password="%s"\n' "${p}"
        printf 'host="%s"\n' "${h}"
        printf 'default-character-set=%s\n' "${OS_DEFAULT_DB_CHARSET}"
    } >"${f}"
    umask "${prev_umask}"
    chmod 0600 "${f}" 2>/dev/null || true

    log::secret_add "${pass}" || true
    printf '%s\n' "${f}"
    return 0
}

# ==================================================================
# 执行
# ==================================================================

# os::sql_exec [--defaults-file <路径>] [--allow-fail] <desc> -- <SQL>
#
# SQL 语句本身经 stdin 送进 mysql，不进 argv：语句里可能带刚转义好的
# 字符串字面量，那是用户数据，同样不该被 ps 看见。
os::sql_exec() {
    local defaults='' desc='' allow_fail=''
    while [[ $# -gt 0 ]]; do
        case ${1} in
            --defaults-file)
                defaults=${2}
                shift 2
                ;;
            --allow-fail)
                allow_fail='--allow-fail'
                shift
                ;;
            --)
                shift
                break
                ;;
            *)
                if [[ -z ${desc} ]]; then
                    desc=${1}
                fi
                shift
                ;;
        esac
    done
    if [[ $# -eq 0 ]]; then
        ui::line error "os::sql_exec 缺少 -- 之后的 SQL"
        return 2
    fi
    local sql=$*

    local -a cmd=(mysql)
    if [[ -n ${defaults} ]]; then
        cmd+=("--defaults-extra-file=${defaults}")
    fi
    # 连接字符集必须显式给。MariaDB 10.11（Ubuntu 24.04）的客户端默认不是
    # utf8mb4，即使库是 utf8mb4，4 字节字符（emoji、部分生僻字）在传输途中
    # 就会被换成 ?，而且**不报错** —— 库里存下的是问号，没人会发现。
    cmd+=("--default-character-set=${OS_DEFAULT_DB_CHARSET}")
    cmd+=(--batch --skip-column-names)

    # SQL 经 stdin 送进 mysql，不进 argv：语句里可能带刚转义好的字符串
    # 字面量，那是用户数据，同样不该被 ps / /proc/<pid>/cmdline 看见。
    # 用 --stdin 而非 --stdin-secret：库名/表名/子句是明文数据不是凭据，
    # 整段登记进脱敏表会把排查证据也打成 ***；凭据部分应由调用方经
    # os::sql_str 转义后随 SQL 一起传入，密码本身仍应先经 log::secret_add
    # 登记（os::secure_set 等已经这么做）。
    os::run ${allow_fail:+"${allow_fail}"} --stdin "${sql}" "${desc}" -- "${cmd[@]}"
}

# os::sql_query [--defaults-file <路径>] [--timeout <秒>] <desc> -- <SQL>
#
# 结果在 OS_RUN_OUTPUT 里，**不打印**。别写 `r=$(os::sql_query ...)` ——
# 那是子 shell，退出码与 dry-run 跳过标志都拿不到（见 exec.sh 头部说明）。
#
# **底层是 `os::query` 而不是 `os::run_out`，dry-run 下照常执行**（规范里
# 执行函数那张表：只读 → os::query）。原来走 run_out，于是 SELECT 在 dry-run 下被
# 当成副作用跳过、`OS_RUN_OUTPUT` 是空串 —— 而调用方拿它判「已经是目标状态
# 了吗」。空串会被读成「什么都没有，需要改」，**预演于是报出一堆根本不会
# 发生的变更**；换个写法（判「有没有」）又会反过来报「无事可做」。
# 两种错法都不报错，都只是预演在撒谎（同 D118 那两条）。
#
# 超时给得比 probe 宽：数据库在负载下响应慢是常态，3 秒会把正常查询判成挂了。
os::sql_query() {
    local defaults='' desc=''
    local -i timeout=${OS_DEFAULT_SQL_TIMEOUT}
    while [[ $# -gt 0 ]]; do
        case ${1} in
            --defaults-file)
                defaults=${2}
                shift 2
                ;;
            --timeout)
                timeout=${2}
                shift 2
                ;;
            --)
                shift
                break
                ;;
            *)
                if [[ -z ${desc} ]]; then
                    desc=${1}
                fi
                shift
                ;;
        esac
    done
    if [[ $# -eq 0 ]]; then
        ui::line error "os::sql_query 缺少 -- 之后的 SQL"
        return 2
    fi
    local sql=$*

    local -a cmd=(mysql)
    if [[ -n ${defaults} ]]; then
        cmd+=("--defaults-extra-file=${defaults}")
    fi
    # 连接字符集必须显式给。MariaDB 10.11（Ubuntu 24.04）的客户端默认不是
    # utf8mb4，即使库是 utf8mb4，4 字节字符（emoji、部分生僻字）在传输途中
    # 就会被换成 ?，而且**不报错** —— 库里存下的是问号，没人会发现。
    cmd+=("--default-character-set=${OS_DEFAULT_DB_CHARSET}")
    cmd+=(--batch --skip-column-names)

    # 只读不进审计，但 desc 仍然要留下来 —— 排查时
    # 「当时查的是什么」比「查到了什么」更难事后重建
    log::write debug "SQL 查询：${desc}" framework
    # 同 os::sql_exec：SQL 经 stdin，不进 argv
    os::query --timeout "${timeout}" --stdin "${sql}" -- "${cmd[@]}"
}
