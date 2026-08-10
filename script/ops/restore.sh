#!/bin/bash
#
# 从备份归档恢复
#
# @command      restore
# @name         恢复管理
# @group        backup
# @order        20
# @privilege    root
# @requires_lib >= 4.0
# @args         [--from=<local|remote|external>] [--target=<类型:名字>] [--file=<归档文件名>] [--mode=<all|db|files>] [--only=<归档内相对路径>] [--source=<路径[,路径]>] [--subdir=<来源内相对路径>] [--site-url=<地址>] [--strip-db-statements=<y|n>] [--confirm-restore=<类型:名字>]
# @description  从归档或外部备份恢复，覆盖前自动留副本
#

set -Eeuo pipefail
IFS=$'\n\t'
PATH='/usr/sbin:/usr/bin:/sbin:/bin'
export PATH
umask 027

source /opt/oneserver/lib/bootstrap.sh

# ==================================================================
# 这个脚本为什么长这样
# ==================================================================
#
# ## 一、恢复的依据是归档里的 manifest，不是 secure.conf，也不是文件名
#
# 旧脚本第一件事是 `source "$SECURE_CONF"` 取 `DB_NAME` / `DB_USER` / `DB_PASS`，
# 也就是说：**归档本身不知道自己是什么**，得靠这台机器上恰好还在的一份配置
# 才解释得了。于是换一台机器就用不了 —— 而「换一台机器」正是要恢复的场合。
#
# 现在每个归档根下有一个 `manifest`（`backup.sh` 写的），里面有类型、名字、
# 源路径、库名、归档内的根目录名。**restore 只读它**：从别人那儿拷来一个归档，
# 在一台干净机器上照样恢复得了。
#
# ## 二、K4 —— 全项目最严重的一条，在这里消失
#
# 旧脚本用 `eval` 拼 `sed` 去改 wp-config.php 里的密码：
#
#     run_command "sudo sed -i \"s/...'${db_pass_esc}'.../\" '$wp_config_path'"
#     ...
#     if eval "$command_str"; then
#
# 密码先明文进日志文件，再经 `eval` 进 shell —— 一个含 `$(...)` 的密码
# 就是 **root RCE**。而这一整段的目的是「让恢复出来的 wp-config 匹配当前环境」。
#
# **那个目的本身是对的，错的是实现方式。** 归档里的 wp-config.php 存的是
# 备份那一刻的数据库密码，而恢复只重建库里的数据 —— MySQL 账号的密码用的
# 还是活系统上那个。两边对不上，恢复完站点就连不上库，现场表现是白屏。
# 所以 `fixup_credentials` 仍然要改那几行，只是换了做法：
#
#   * 走 `os::replace_line`（同目录临时文件 + `mv` 换 inode），**没有 `eval`、
#     没有 `sed -i`**，密码不进 shell 命令行、不参与任何字符串求值。
#   * 密码经 `os::secure_load` 取出，**脱敏在读出来那一刻就登记了**，
#     此后它进不了日志、进不了 dry-run 预览。
#   * 只改 DB 那四行与缓存密码一行；盐不动 —— 盐只影响登录 cookie，
#     保留归档里的反而让已登录用户不掉线。
#
# 本机没有这份凭据时（换机器恢复）**不猜、不改**，原样保留并说清怎么办。
#
# ## 三、K8 的最后一处 —— 失败必须看得见
#
# 旧脚本的 `run_command` 把 stdout 与 stderr 整体重定向进日志文件，
# 失败时终端上只有一句「命令失败」，真正的错误躺在日志里。
# 现在错误一律经 `os::err` 走 stderr，调用栈才进日志。
#
# ## 四、覆盖之前一律先落副本
#
# 同 D140：人是会打对全名然后后悔的。
#   库   —— 先 mysqldump 一份到 $OS_BACKUP_DIR/pre-restore/
#   目录 —— 先整个 mv 到 $OS_BACKUP_DIR/pre-restore/，不是删
# **副本失败就中止**，不给「备份没成也照样覆盖」的可能。
#
# ## 五、`oneserver:self` 只解出来，不自动覆盖
#
# 它装的是 `/etc/oneserver` + state + secure.conf —— 而这三样正是**当前这个
# 进程正在使用**的东西。在自己运行的时候替换自己的 state 与凭据库，
# 是 K13 那一类问题（覆盖运行中的文件）。所以这里只解压到一个目录、
# 把清单打出来，由人对照着合并。这不是偷懒，是这件事本来就该有人看着。
#
# ## 六、外部导入（`--from=external`）为什么也在这个文件里
#
# 别处（宝塔、cPanel、另一台主机、手工 mysqldump）来的备份过不了上面三道门：
# 没有 `.sha256`、没有 `manifest`、更没有 schema 版本。但它要做的事
# **与恢复一字不差** —— 覆盖一个库、替换一个目录、校对 wp-config 里的凭据。
#
# 单独写一个 `import.sh` 意味着把 `snapshot_db` / `restore_db` /
# `stash_current` / `fixup_credentials` 复制一份 —— 而脚本之间不能互相 source
# （不变量 2），复制是唯一的实现方式。**这四个函数是全项目破坏力最大的地方，
# 不能有第二份。** 把它们提到 `lib/` 也不对：`lib/` 不该知道 WordPress 是什么。
#
# 所以外部导入是 `--from` 的第三个取值，与 local / remote 并列。两条路各有各的
# 前段（一条选归档校验读 manifest，一条选来源审查清单），**写入动作全部落回
# 同一批函数**。
#
# 三道门在这条路上换成了另外四条：来源由人当场指定而不是从远端列表里挑出来的、
# 解包前审查完整清单、解包只落 staging 不碰落点、覆盖前照旧强制留副本。
# 剩下的可信性由使用者负责，这句话会打进确认清单里。

readonly RS_PRE_DIR="${OS_BACKUP_DIR}/pre-restore"

# 函数之间的返回通道（D135）
RS_ENTRIES=''
RS_ARCHIVE=''
RS_MF_TYPE=''
RS_MF_NAME=''
RS_MF_SOURCE=''
RS_MF_ROOT=''
RS_MF_DB=''
RS_MF_CREATED=''
RS_MF_HOST=''
# 具体站点类型（wordpress …）。恢复后要不要校对凭据、怎么校对，全看它
RS_MF_SITE_TYPE=''

RS_REMOTE=''
RS_REMOTE_DIR=''

# 外部导入的落点与来源，同样是函数之间的返回通道
EX_DEST_DIR=''
EX_DEST_DB=''
# 落点是站点时才非空：具体站点类型与 state 实例名，决定要不要校对凭据
EX_SITE_TYPE=''
EX_SITE_NAME=''
EX_SRC_FILES=''
EX_SRC_SQL=''
# tar | zip | dir | file
EX_KIND=''
# 来源内的站点根（相对路径，无首尾斜杠）。空 = 整个来源就是根
EX_ROOT=''
EX_MEMBERS=''
EX_SIZE_KB=0
EX_SQL_HITS=''
EX_SQL_CHARSET=''
EX_STRIP=0

# ==================================================================
# manifest 字段校验 —— manifest 来自归档，归档可能来自别的机器或远端对象存储
# ==================================================================
#
# SHA256 只证明「归档没在传输中被改」，不证明「归档的作者是谁」（verify_archive
# 头注释与规范 §13 都点出了这一点）。一个被攻破的备份桶就能塞进一份 manifest
# 字段被动过手脚的归档，而 db_name / source_path / archive_root 这三个字段
# 此前直接决定了「以 root 身份执行什么」与「往哪个路径解包/覆盖」——
# 相当于把 shell 命令的一部分交给了归档的作者。

# valid_db_name <值>   与 db_manager.sh 的 valid_name 同一条规则：
# 只收小写字母数字下划线短横、以字母数字开头。任何引号/分号/管道/反引号
# 都落在这条规则之外，db_name 一旦通过校验就不可能再拼出一段新命令。
valid_db_name() {
    [[ ${1} =~ ^[a-z0-9][a-z0-9_-]*$ ]]
}

# valid_archive_root <值>   归档内的顶层目录名，只收单段路径
valid_archive_root() {
    [[ -n ${1} && ${1} != '.' && ${1} != '..' && ${1} != */* && ${1} =~ ^[A-Za-z0-9._-]+$ ]]
}

# valid_source_path <值>   本机要写入/挪走的绝对路径
#
# 白名单挡不住：站点目录允许自定义 --path（deploy_wordpress 只校验 `^/`），
# 合法值本来就可以是任意绝对路径。改用黑名单挡系统关键目录 —— 挡不住
# 全部攻击面，但「把 /etc/ssh 整个挪到 pre-restore 再用归档内容覆盖」
# 这类现实场景能被拦下。
valid_source_path() {
    local p=${1}
    [[ ${p} == /* ]] || return 1
    [[ ${p} != *'/../'* && ${p} != *'/..' ]] || return 1
    local bad
    for bad in /etc /usr /bin /sbin /lib /lib64 /boot /root /run /sys /proc /dev /var/lib "${OS_ROOT}"; do
        [[ ${p} == "${bad}" || ${p} == "${bad}/"* ]] && return 1
    done
    return 0
}

# ==================================================================
# 找归档
# ==================================================================

load_remote() {
    RS_REMOTE=$(os::state_get backup remote)
    RS_REMOTE_DIR=$(os::state_get backup remote_dir)
    [[ -n ${RS_REMOTE} && -n ${RS_REMOTE_DIR} ]]
}

# 本地有哪些「类型:名字」，一行一个
local_targets() {
    os::query --timeout 30 -- sh -c \
        "find '${OS_ARCHIVE_DIR}' -mindepth 3 -maxdepth 3 -name '*.tar.gz' -printf '%h\n' 2>/dev/null | sort -u" \
        || return 1
    local line out=''
    while IFS= read -r line; do
        [[ -n ${line} ]] || continue
        line=${line#"${OS_ARCHIVE_DIR}/"}
        out+="${line/\//:}"$'\n'
    done <<<"${OS_RUN_OUTPUT}"
    RS_ENTRIES=$(printf '%s' "${out}" | grep -v '^[[:space:]]*$' || true)
    [[ -n ${RS_ENTRIES} ]]
}

remote_targets() {
    load_remote || return 1
    os::require_cmd rclone
    os::query --timeout 300 -- sh -c \
        "rclone lsf '${RS_REMOTE}:${RS_REMOTE_DIR}' --dirs-only -R --max-depth 2 2>/dev/null | sort" \
        || return 1
    local line out=''
    while IFS= read -r line; do
        line=${line%/}
        # 只要「类型/名字」这一层，类型那一层自己不是目标
        [[ ${line} == */* ]] || continue
        out+="${line/\//:}"$'\n'
    done <<<"${OS_RUN_OUTPUT}"
    RS_ENTRIES=$(printf '%s' "${out}" | grep -v '^[[:space:]]*$' || true)
    [[ -n ${RS_ENTRIES} ]]
}

# 某个目标下有哪些归档，新的在前
local_archives() {
    local type=${1} name=${2}
    os::query --timeout 30 -- sh -c \
        "ls -1 '${OS_ARCHIVE_DIR}/${type}/${name}' 2>/dev/null | grep -E '^[0-9]{8}-[0-9]{6}\.tar\.gz$' | sort -r" \
        || return 1
    RS_ENTRIES=${OS_RUN_OUTPUT}
    [[ -n ${RS_ENTRIES} ]]
}

# 一份归档在选择列表里显示成什么样：`<时间戳>.tar.gz   YYYY-MM-DD HH:MM · 26 MB`
#
# 远端的大小要联网一份份问，太慢，所以只从文件名还原时间 —— 文件名本身就是
# 时间戳，这不是猜测。
archive_desc() {
    local from=${1} type=${2} name=${3} file=${4}
    local stamp=${file%.tar.gz}
    local when="${stamp:0:4}-${stamp:4:2}-${stamp:6:2} ${stamp:9:2}:${stamp:11:2}"
    if [[ ${from} != local ]]; then
        printf '%s' "${when}"
        return 0
    fi
    local f="${OS_ARCHIVE_DIR}/${type}/${name}/${file}"
    os::query --timeout 10 -- stat -c '%s' "${f}" || {
        printf '%s' "${when}"
        return 0
    }
    printf '%s · %s MB' "${when}" "$((OS_RUN_OUTPUT / 1048576))"
}

remote_archives() {
    local type=${1} name=${2}
    os::query --timeout 300 -- sh -c \
        "rclone lsf '${RS_REMOTE}:${RS_REMOTE_DIR}/${type}/${name}' --files-only 2>/dev/null | grep -E '^[0-9]{8}-[0-9]{6}\.tar\.gz$' | sort -r" \
        || return 1
    RS_ENTRIES=${OS_RUN_OUTPUT}
    [[ -n ${RS_ENTRIES} ]]
}

# ==================================================================
# 取回并校验
# ==================================================================

# **校验不通过就一个字节都不解。** 一个损坏或被改过的归档解到站点目录上，
# 造成的破坏比「这次恢复不了」大得多。
verify_archive() {
    local file=${1}
    if [[ ! -f ${file}.sha256 ]]; then
        os::err "缺少校验文件：${file}.sha256"
        os::info '本工具生成的归档旁边一定有一份同名 .sha256，从别处拷过来时要两个文件一起拷。'
        os::info '如果这本来就是别处（宝塔 / cPanel / 手工打包）来的备份，那条路是：'
        os::info '  oneserver restore --from=external'
        return 1
    fi
    # 两条都没有管道，直接走 argv——file 经参数传给 awk/sha256sum 而不是拼进
    # shell 脚本文本，不管它由 --file= 拼出的内容里有没有 shell 元字符都安全
    os::query --timeout 3600 -- awk "{print \$1}" "${file}.sha256" || return 1
    local expected=${OS_RUN_OUTPUT}
    os::query --timeout 3600 -- sha256sum "${file}" || return 1
    local actual=${OS_RUN_OUTPUT%%[[:space:]]*}
    if [[ -z ${expected} || ${expected} != "${actual}" ]]; then
        os::err "校验失败：归档已损坏或被改动（期望 ${expected:-空}，实得 ${actual}）"
        return 1
    fi
    os::ok '归档校验通过'
    return 0
}

# 把选中的归档准备到本地，路径放 RS_ARCHIVE
fetch_archive() {
    local from=${1} type=${2} name=${3} file=${4}
    if [[ ${from} == local ]]; then
        RS_ARCHIVE="${OS_ARCHIVE_DIR}/${type}/${name}/${file}"
        [[ -f ${RS_ARCHIVE} ]] || {
            os::err "本地没有这份归档：${RS_ARCHIVE}"
            return 1
        }
        return 0
    fi

    local dir src
    os::tmpdir dir || return 1
    src="${RS_REMOTE}:${RS_REMOTE_DIR}/${type}/${name}"
    os::info "从远端下载 ${file}"
    os::query --timeout 3600 -- rclone copy "${src}/${file}" "${dir}" || return 1
    os::query --timeout 300 -- rclone copy "${src}/${file}.sha256" "${dir}" || return 1
    RS_ARCHIVE="${dir}/${file}"
    [[ -f ${RS_ARCHIVE} ]] || {
        os::err '下载完成但文件不在，远端可能被改动过'
        return 1
    }
    return 0
}

# 只解 manifest 一个文件出来读。
#
# 归档可能有好几个 G，为了知道「这是什么」而整份解开是不必要的；
# 而且**在用户确认之前不该往磁盘上铺任何东西**。
read_manifest() {
    local file=${1}
    local dir
    os::tmpdir dir || return 1
    os::query --timeout 300 -- tar -xzf "${file}" -C "${dir}" manifest || {
        os::err '归档里没有 manifest —— 它不是 oneserver 生成的归档，或者版本太老'
        return 1
    }
    [[ -f ${dir}/manifest ]] || {
        os::err '归档里没有 manifest'
        return 1
    }

    local k v schema=''
    RS_MF_TYPE='' RS_MF_NAME='' RS_MF_SOURCE='' RS_MF_ROOT=''
    RS_MF_DB='' RS_MF_CREATED='' RS_MF_HOST='' RS_MF_SITE_TYPE=''
    while IFS='=' read -r k v; do
        case ${k} in
            schema) schema=${v} ;;
            type) RS_MF_TYPE=${v} ;;
            name) RS_MF_NAME=${v} ;;
            source_path) RS_MF_SOURCE=${v} ;;
            archive_root) RS_MF_ROOT=${v} ;;
            db_name) RS_MF_DB=${v} ;;
            created) RS_MF_CREATED=${v} ;;
            host) RS_MF_HOST=${v} ;;
            site_type) RS_MF_SITE_TYPE=${v} ;;
        esac
    done <"${dir}/manifest"

    # 版本比自己新的 manifest **拒绝处理**：字段含义可能已经变了，
    # 按旧理解去恢复比不恢复危险
    if [[ ${schema} =~ ^[0-9]+$ ]] && ((schema > 1)); then
        os::err "这份归档的 manifest 版本是 ${schema}，本机的 restore 只认到 1 —— 请先更新 oneserver"
        return 1
    fi
    [[ -n ${RS_MF_TYPE} ]] || {
        os::err 'manifest 里没有类型字段，归档不完整'
        return 1
    }

    # 三个字段此前直接拼进 shell 命令/路径操作：db_name 决定
    # mysqldump/mysql 命令行的一部分，source_path 决定 mv/tar 解到哪，
    # archive_root 决定归档内解哪个顶层目录。归档来自别的机器或远端对象
    # 存储，SHA256 只保证没被传输改动，不保证内容可信——一份被动过手脚的
    # manifest 不该有能力执行任意命令或覆盖 /etc 之类的系统目录。
    if [[ -n ${RS_MF_DB} ]] && ! valid_db_name "${RS_MF_DB}"; then
        os::err "manifest 里的 db_name「${RS_MF_DB}」不是合法的数据库名，拒绝处理（归档可能被篡改）"
        return 1
    fi
    if [[ -n ${RS_MF_ROOT} ]] && ! valid_archive_root "${RS_MF_ROOT}"; then
        os::err "manifest 里的 archive_root「${RS_MF_ROOT}」不是合法的单段目录名，拒绝处理（归档可能被篡改）"
        return 1
    fi
    if [[ -n ${RS_MF_SOURCE} ]] && ! valid_source_path "${RS_MF_SOURCE}"; then
        os::err "manifest 里的 source_path「${RS_MF_SOURCE}」不是可接受的路径（相对路径、路径穿越或系统目录），拒绝处理（归档可能被篡改）"
        return 1
    fi
    return 0
}

# ==================================================================
# 恢复
# ==================================================================

# 覆盖之前落副本。**副本失败就中止**（D140）。
snapshot_db() {
    local db=${1}
    local ts
    printf -v ts '%(%Y%m%d-%H%M%S)T' -1
    local out="${RS_PRE_DIR}/${db}-${ts}.sql.gz"
    os::run '创建恢复前副本目录' -- mkdir -p "${RS_PRE_DIR}"
    os::run '收紧恢复前副本目录权限' -- chmod 0700 "${RS_PRE_DIR}"
    os::info "先把当前的 ${db} 备一份"
    # 凭据零参与：D121，OS root 走 unix_socket
    # db/charset/out 经位置参数（"$1"/"$2"/"$3"）传给 sh -c，不拼进脚本文本——
    # read_manifest 已经把 db 校验成 [a-z0-9_-]，这里再加一层：不管校验是否
    # 有漏网之鱼，值都不会被当成 shell 语法解释。
    # shellcheck disable=SC2016  # 理由：$1/$2/$3 是内层 sh 的位置参数，故意不让外层展开
    os::run '备份恢复前的数据库' -- sh -c \
        'mysqldump --single-transaction --routines --triggers --events --quick --hex-blob --default-character-set="$1" "$2" | gzip > "$3"' \
        _ "${OS_DEFAULT_DB_CHARSET}" "${db}" "${out}" \
        || {
            os::err "当前数据库备份失败，恢复中止（不在没有退路的情况下覆盖数据）"
            return 1
        }
    os::ok "恢复前副本：${out}"
    return 0
}

# stash_current <当前路径> <副本名>   把将被覆盖的东西整个挪走，不是删（D140）
#
# 归档恢复与外部导入共用。**这是文件侧唯一的「让现有内容消失」的地方**，
# 只有一份，出错时人只要去 pre-restore 里找就行，不必先判断是哪条路径干的。
stash_current() {
    local live=${1} label=${2}
    os::run '创建恢复前副本目录' -- mkdir -p "${RS_PRE_DIR}"
    os::run '收紧恢复前副本目录权限' -- chmod 0700 "${RS_PRE_DIR}"
    [[ -e ${live} ]] || return 0
    os::run '移走当前内容作为恢复前副本' -- mv "${live}" "${RS_PRE_DIR}/${label}" || return 1
    os::ok "恢复前副本：${RS_PRE_DIR}/${label}"
    return 0
}

# restore_db <库名> <sql 文件> [剥离库级语句]
#
# sql 文件可以是 `.sql` 或 `.sql.gz`；第三个参数为 1 时把 `USE` /
# `CREATE DATABASE` / `DROP DATABASE` 三类语句在管道里注释掉（外来 dump 才需要，
# 判断在 sql_scan，**用户的原文件一个字节不动**）。
restore_db() {
    local db=${1} sqlfile=${2} strip=${3:-0}
    snapshot_db "${db}" || return 1

    local ident
    ident=$(os::sql_ident "${db}")
    os::sql_exec '重建目标数据库' -- \
        "DROP DATABASE IF EXISTS ${ident}; CREATE DATABASE ${ident} CHARACTER SET ${OS_DEFAULT_DB_CHARSET} COLLATE ${OS_DEFAULT_DB_COLLATE};" \
        || return 1
    # 同 snapshot_db：位置参数传值，不拼进脚本文本。
    #
    # 用 bash -c 而不是 sh -c，是为了 `set -o pipefail`：sh 在 Debian 上是 dash，
    # 没有这个选项，于是解压中途失败时 mysql 照样以 0 退出 —— 现场是
    # 「导入成功了，但库里只有半份数据」，比直接失败危险得多。
    # shellcheck disable=SC2016  # 理由：$1..$4 是内层 bash 的位置参数，故意不让外层展开
    os::run '导入数据库转储' -- bash -c \
        'set -o pipefail; case "$3" in *.gz) gunzip -c -- "$3" ;; *) cat -- "$3" ;; esac | if [ "$4" = 1 ]; then sed -E "s@^(USE[[:space:]]|CREATE[[:space:]]+DATABASE|DROP[[:space:]]+DATABASE)@-- oneserver-import: \1@"; else cat; fi | mysql --default-character-set="$1" "$2"' \
        _ "${OS_DEFAULT_DB_CHARSET}" "${db}" "${sqlfile}" "${strip}" \
        || {
            os::err "导入失败。当前库已被清空，用上面那份恢复前副本可以回到原状"
            return 1
        }
    os::ok "数据库 ${db} 已恢复"
    return 0
}

# 恢复后校对凭据。**这是「恢复完站点反而挂了」的唯一成因。**
#
# 归档里的 wp-config.php 存的是**备份那一刻**的数据库密码，而恢复只重建了库
# 里的数据 —— MySQL 账号的密码用的还是活系统上那个。两边对不上，站点连不上库。
# 缓存密码同理，而且更隐蔽：连不上时 WordPress 每个请求都要等一次认证超时，
# 表现是「能打开但慢得没法用」，比白屏难查得多。
#
# **以活系统为准，不是以归档为准。** MySQL 里的账号、凭据库里的密码都是活的，
# 归档里那份是历史快照。让配置去迁就活系统，而不是把活账号的密码改回历史值
# —— 后者等于拿备份里的明文密码去覆盖现有账号。
#
# 盐**不动**：它只影响登录 cookie，保留归档里的反而让已登录用户不掉线。
fixup_credentials() {
    local site_type=${1} name=${2} source=${3}
    [[ ${site_type} == wordpress ]] || return 0

    local conf="${source}/wp-config.php"
    [[ -f ${conf} ]] || return 0

    local id="wordpress:${name}"
    # 与 deploy_wordpress.sh 用同一条规则算 key（§11：命名空间由框架统一
    # 生成，脚本不能各拼各的——两处算法不一样，恢复时就永远读不到密码）
    local secret_key
    secret_key="$(os::secure_ns "${id}").db_pass"
    local db db_user db_host pass=''
    db=$(os::state_get "${id}" db)
    db_user=$(os::state_get "${id}" db_user)
    db_host=$(os::state_get "${id}" db_host localhost)

    # 本机没有这份凭据 = 多半是换了台机器恢复。**这时不能瞎改** ——
    # 归档里那份配置至少与归档里的数据是一套的，改成半套反而更糟。
    if [[ -z ${db} || -z ${db_user} ]] || ! os::secure_load "${secret_key}" pass; then
        os::warn "本机凭据库里没有 ${id} 的数据库密码，wp-config.php 保持归档里的原样"
        os::info "它期望的账号在配置文件里：${conf}"
        os::info "要么在 MySQL 里按那份配置建好账号，要么先跑 oneserver deploy wordpress 再恢复"
        return 0
    fi

    os::section '校对站点配置里的凭据'
    os::record_change "改写 ${conf} 里的数据库与缓存凭据"
    os::replace_line --backup "${conf}" "^define\( *'DB_NAME'" \
        "define( 'DB_NAME', '${db}' );" || return 1
    os::replace_line "${conf}" "^define\( *'DB_USER'" \
        "define( 'DB_USER', '${db_user}' );" || return 1
    os::replace_line "${conf}" "^define\( *'DB_PASSWORD'" \
        "define( 'DB_PASSWORD', '${pass}' );" || return 1
    os::replace_line "${conf}" "^define\( *'DB_HOST'" \
        "define( 'DB_HOST', '${db_host}' );" || return 1
    os::ok "数据库凭据已对齐到本机当前值（库 ${db}，账号 ${db_user}@${db_host}）"

    # 缓存密码只在归档里本来就配了缓存时才校对 —— 没配过就不该凭空加上，
    # 那是在替用户做他没要求的决定。替换不中返回非零，这里当正常情况放过。
    local cpass=''
    if os::secure_load valkey.password cpass; then
        if os::replace_line "${conf}" "^define\( *'WP_REDIS_PASSWORD'" \
            "define( 'WP_REDIS_PASSWORD', '${cpass}' );"; then
            os::ok '缓存密码已对齐到本机当前值'
        fi
    fi
    return 0
}

# 恢复文件。
#
# `tar -x` 以 root 执行时默认还原归档里记录的属主与权限，所以
# **不需要 chown/chmod 那一串 find**：站点目录里的 www-data 归属是打包时
# 就记进去的。旧脚本那六条 `find -exec chmod` 是在补「打包时没保住属主」的洞，
# 而那个洞来自它用 `tar -cf` 之后又经过一次解包再打包。
restore_files() {
    local archive=${1} source=${2} root=${3} only=${4}

    [[ -n ${root} ]] || {
        os::err '这份归档里没有文件（只有数据库）'
        return 1
    }
    [[ -n ${source} ]] || {
        os::err 'manifest 里没有源路径，无法确定恢复到哪'
        return 1
    }

    local parent=${source%/*}
    [[ -n ${parent} ]] || parent='/'

    # **父目录在目标机器上可能根本不存在。** A 机的 /var/www 是部署 WordPress
    # 时建的，B 机是干净系统 —— 而「拿归档在另一台机器上重建站点」正是这个
    # 命令存在的理由。不建的话 `tar -C /var/www` 直接以 2 退出，**而数据库
    # 那一半已经恢复完了**，留下的是「库是新的、文件还是旧的（或者根本没有）」。
    #
    # 0755 而不是 umask 027 给的 0750：站点父目录必须让 www-data 进得去，
    # 0750 的表现是恢复报成功、浏览器 403（deploy_wordpress 那句
    # 「确保站点父目录可进入」防的是同一件事）。
    #
    # 归类「必须回滚」：只在本次确实不存在时才建，撤销用 rmdir 不是 rm -rf ——
    # 后面几步真失败时目录里已经有站点了，rmdir 会失败并把它留下，这是对的。
    if [[ ! -d ${parent} ]]; then
        os::run '创建站点父目录' -- mkdir -p "${parent}" || return 1
        os::defer rmdir -- "${parent}"
        os::run '确保站点父目录可进入' -- chmod 0755 "${parent}" || return 1
    fi

    local ts
    printf -v ts '%(%Y%m%d-%H%M%S)T' -1

    if [[ -z ${only} ]]; then
        stash_current "${source}" "${root}-${ts}" || return 1
        os::run '解出站点文件' -- tar -xzf "${archive}" -C "${parent}" "${root}" || return 1
        os::ok "文件已恢复到 ${source}"
        return 0
    fi

    # 只恢复归档内的某个子路径（典型场景：wp-content/uploads）
    local sub=${only#/}
    sub=${sub%/}
    local live="${source}/${sub}"

    # **先确认归档里真有这个子路径，再动现有的东西。** 反过来的话，一个拼错的
    # `--only` 会先把用户的 uploads 挪走，然后 tar 报「找不到」——现场是
    # 「恢复失败，而且媒体库不见了」
    os::query --timeout 600 -- tar -tzf "${archive}" "${root}/${sub}" || {
        os::err "归档里没有这个子路径：${sub}"
        return 1
    }
    stash_current "${live}" "${root}-${sub//\//_}-${ts}" || return 1
    os::run '创建子目录的父级' -- mkdir -p "${live%/*}"
    os::run '解出指定子路径' -- \
        tar -xzf "${archive}" -C "${parent}" "${root}/${sub}" || return 1
    os::ok "已恢复 ${live}"
    return 0
}

# `oneserver:self`：只解出来，不覆盖。理由见文件头第五点。
restore_self() {
    local archive=${1} root=${2}
    local ts
    printf -v ts '%(%Y%m%d-%H%M%S)T' -1
    local out="${RS_PRE_DIR}/oneserver-config-${ts}"
    os::run '创建解出目录' -- mkdir -p "${out}"
    os::run '收紧解出目录权限' -- chmod 0700 "${out}"
    os::run '解出 oneserver 配置' -- tar -xzf "${archive}" -C "${out}" "${root}" || return 1

    os::section '已解出，但没有覆盖任何东西'
    os::kv '解到' "${out}/${root}"
    os::info 'state 与 secure.conf 正被当前进程使用，在运行中替换它们属于 K13 那一类问题。'
    os::info '请人工对照后合并，例如：'
    os::info "  diff ${out}/${root}/secure.conf ${OS_SECURE_CONF}"
    os::info "  diff -r ${out}/${root}/state ${OS_STATE_DIR}"
    os::ok '恢复素材已就绪'
    os::output 0 extracted="${out}/${root}" changed=yes
    return 0
}

# ==================================================================
# 外部导入 —— 来源解析
# ==================================================================

# ex_split_source <spec>   一个 --source 吃两样东西：文件来源与 SQL 转储
#
# 整站迁移天生是「一个包 + 一份 dump」。拆成两条命令意味着两次打全名确认、
# 两个覆盖窗口，中间那段时间站点是「文件是新的、库还是旧的」。所以这里接受
# 逗号分隔，次序不限，同类给两份即拒绝。**代价是路径里不能含逗号。**
#
# 同时当 os::ask 的 --validate 用：填错在原地重问，而不是把前面填过的作废。
ex_split_source() {
    local spec=${1-} item
    [[ -n ${spec} ]] || return 1
    local -a items=()
    local IFS=','
    read -ra items <<<"${spec}"
    IFS=$'\n\t'

    EX_SRC_FILES='' EX_SRC_SQL='' EX_KIND=''
    for item in ${items[@]+"${items[@]}"}; do
        [[ -n ${item} ]] || continue
        if [[ ${item} != /* ]]; then
            os::err "来源要给绝对路径，收到「${item}」"
            return 1
        fi
        if [[ ! -e ${item} ]]; then
            os::err "来源不存在：${item}"
            return 1
        fi
        # 先判目录，不看名字：一个恰好叫 dump.sql 的目录不是转储
        if [[ -d ${item} ]]; then
            [[ -n ${item%/} ]] || {
                os::err '来源不能是根目录 /'
                return 1
            }
            [[ -z ${EX_SRC_FILES} ]] || {
                os::err '文件来源只能给一份'
                return 1
            }
            EX_SRC_FILES=${item%/}
            EX_KIND=dir
            continue
        fi
        case ${item} in
            *.sql | *.sql.gz)
                [[ -z ${EX_SRC_SQL} ]] || {
                    os::err 'SQL 转储只能给一份'
                    return 1
                }
                EX_SRC_SQL=${item}
                continue
                ;;
            # 明摆着是转储、只是压缩格式不认识。不落到下面的「当单个文件处理」——
            # 那会把一个 .sql.bz2 原样拷进站点目录，报成功，而库一个字节没变
            *.sql.*)
                os::err "转储只支持 .sql 与 .sql.gz，收到 ${item##*/}"
                os::info '先解开再导入，例如：bunzip2 / unxz / unzstd / 7z x'
                return 1
                ;;
        esac
        [[ -z ${EX_SRC_FILES} ]] || {
            os::err '文件来源只能给一份'
            return 1
        }
        EX_SRC_FILES=${item}
        case ${item} in
            *.tar.gz | *.tgz | *.tar) EX_KIND=tar ;;
            *.zip) EX_KIND=zip ;;
            # 明摆着是归档、只是压缩格式不认识。同 *.sql.* 那条：落到下面的
            # 「当单个文件处理」会把 .tar.zst 原样拷进站点目录、报成功，而站点是空的
            *.tar.* | *.txz | *.tbz | *.tbz2 | *.tzst)
                os::err "归档只支持 .tar / .tar.gz / .tgz / .zip，收到 ${item##*/}"
                os::info '先解开再导入，例如：unxz / bunzip2 / unzstd'
                return 1
                ;;
            *.rar | *.7z)
                os::err '不支持 .rar / .7z —— 解它们要装第三方运行时，本工具不引入运行时依赖'
                os::info '先在别处解开成目录，再把那个目录作为来源'
                return 1
                ;;
            # 认不出扩展名就是单个文件：用户要导入的就是这一个文件本身
            *) EX_KIND='file' ;;
        esac
    done
    [[ -n ${EX_SRC_FILES} || -n ${EX_SRC_SQL} ]]
}

# ex_db_exists <库名>   手工建的库也该能当落点，但得先确认它真的存在 ——
# 否则一个拼错的库名会让数据灌进一个刚被 restore_db 建出来的空库，而且返回成功
ex_db_exists() {
    local quoted
    quoted=$(os::sql_str "${1}")
    os::sql_query '查询数据库是否存在' -- "SHOW DATABASES LIKE ${quoted}" || return 1
    [[ -n ${OS_RUN_OUTPUT} ]]
}

# ex_resolve_dest <类型:名字>   落点复用与 backup 同一套标识，不引入新词
#
# `path:` 后面以 `/` 开头就是直接路径，否则是 `backup add` 登记过的别名 ——
# 判据是一个字符，不是一个新概念。直接路径这一形态顺带解决了「只迁 wp-content」：
# `--target=path:/var/www/blog/wp-content`，不必再发明一个「落到站点内哪一层」的参数。
#
# 同样当 --validate 用。
ex_resolve_dest() {
    local spec=${1-}
    EX_DEST_DIR='' EX_DEST_DB='' EX_SITE_TYPE='' EX_SITE_NAME=''
    if [[ ${spec} != *:* ]]; then
        os::err "落点要写成 <类型>:<名字>，收到「${spec}」"
        os::info 'site:<站点名> 整站 · db:<库名> 只灌库 · path:<别名或绝对路径> 任意目录或文件'
        return 1
    fi
    local type=${spec%%:*} name=${spec#*:}
    [[ -n ${name} ]] || {
        os::err '落点缺少名字'
        return 1
    }

    case ${type} in
        site)
            local -a types=()
            local t
            local IFS=$', \t\n'
            read -ra types <<<"${OS_DEFAULT_BACKUP_SITE_TYPES}"
            IFS=$'\n\t'
            for t in ${types[@]+"${types[@]}"}; do
                [[ -n ${t} ]] || continue
                os::state_has "${t}:${name}" || continue
                EX_SITE_TYPE=${t}
                break
            done
            [[ -n ${EX_SITE_TYPE} ]] || {
                os::err "state 里没有站点「${name}」"
                os::info '先 oneserver deploy wordpress 部署一个空站，或改用 path:<绝对路径>'
                return 1
            }
            EX_SITE_NAME=${name}
            EX_DEST_DIR=$(os::state_get "${EX_SITE_TYPE}:${name}" path)
            EX_DEST_DB=$(os::state_get "${EX_SITE_TYPE}:${name}" db)
            [[ -n ${EX_DEST_DIR} ]] || {
                os::err "state 里的 ${EX_SITE_TYPE}:${name} 没有 path 键，定不出落点目录"
                return 1
            }
            ;;
        db)
            valid_db_name "${name}" || {
                os::err "数据库名「${name}」不合法（只收小写字母数字与 _ -，以字母数字开头）"
                return 1
            }
            os::require_cmd mysql
            ex_db_exists "${name}" || {
                os::err "数据库 ${name} 不存在"
                os::info "先建库：oneserver mariadb create --name=${name}"
                return 1
            }
            EX_DEST_DB=${name}
            ;;
        path)
            if [[ ${name} == /* ]]; then
                EX_DEST_DIR=${name%/}
            else
                os::state_has "backup-path:${name}" || {
                    os::err "没有登记过路径别名「${name}」"
                    os::info '要么先 oneserver backup add 登记，要么直接给绝对路径'
                    return 1
                }
                EX_DEST_DIR=$(os::state_get "backup-path:${name}" source)
            fi
            [[ -n ${EX_DEST_DIR} ]] || {
                os::err '解析不出落点路径'
                return 1
            }
            ;;
        *)
            os::err "未知的落点类型「${type}」，可用：site db path"
            return 1
            ;;
    esac

    # 落点是本机将被覆盖的路径，与 manifest 的 source_path 同一条规则：
    # 挡掉相对路径、路径穿越与系统关键目录
    if [[ -n ${EX_DEST_DIR} ]] && ! valid_source_path "${EX_DEST_DIR}"; then
        os::err "落点路径不可接受：${EX_DEST_DIR}（相对路径、路径穿越，或系统关键目录）"
        return 1
    fi
    return 0
}

# ==================================================================
# 外部导入 —— 解包前的审查
# ==================================================================

# ex_read_members   读来源清单：不解包、不落盘
#
# 几个 G 的 .tar.gz 要完整解压一遍才列得出清单，慢。但**用户确认之前不往磁盘上
# 铺任何东西**优先于快 —— 解错地方的代价比多等两分钟大得多。
ex_read_members() {
    EX_MEMBERS='' EX_SIZE_KB=0
    case ${EX_KIND} in
        tar)
            os::query --timeout 3600 -- tar -tvf "${EX_SRC_FILES}" || {
                os::err "读不出归档清单：${EX_SRC_FILES}（不是 tar 包，或者已损坏）"
                return 1
            }
            # `tar -tv` 一行是「权限 属主/组 大小 日期 时间 名字」。名字可能带空格，
            # 所以按「前五列之后全是名字」取，不按第 6 列取；符号链接的 ` -> 目标`
            # 在这里去掉，它不是路径的一部分（链接本身另有 ex_audit_symlinks 管）。
            local raw=${OS_RUN_OUTPUT}
            local size rest name names='' total=0
            local IFS=$' \t'
            while read -r _ _ size rest; do
                [[ ${size} =~ ^[0-9]+$ ]] || continue
                total=$((total + size))
                # rest 是「日期 时间 名字」
                name=${rest#* }
                name=${name#* }
                name=${name%% -> *}
                name=${name#./}
                name=${name%/}
                [[ -n ${name} ]] && names+="${name}"$'\n'
            done <<<"${raw}"
            IFS=$'\n\t'
            EX_SIZE_KB=$((total / 1024))
            EX_MEMBERS=${names}
            ;;
        zip)
            # zip 的清单在中央目录里，读它不用解压，所以这里不心疼两次调用
            os::pkg_install unzip || return 1
            os::require_cmd unzip
            os::query --timeout 600 -- unzip -Z1 "${EX_SRC_FILES}" || {
                os::err "读不出 zip 清单：${EX_SRC_FILES}（不是 zip 包，或者已损坏）"
                return 1
            }
            local m names=''
            while IFS= read -r m; do
                m=${m#./}
                m=${m%/}
                [[ -n ${m} ]] && names+="${m}"$'\n'
            done <<<"${OS_RUN_OUTPUT}"
            EX_MEMBERS=${names}
            # `unzip -Zt` 形如「42 files, 1234567 bytes uncompressed, …」
            os::query --timeout 600 -- unzip -Zt "${EX_SRC_FILES}" || return 1
            local b=${OS_RUN_OUTPUT#*, }
            b=${b%% bytes*}
            [[ ${b} =~ ^[0-9]+$ ]] && EX_SIZE_KB=$((b / 1024))
            ;;
        dir)
            os::query --timeout 600 -- find "${EX_SRC_FILES}" -mindepth 1 -printf '%P\n' || {
                os::err "读不出目录内容：${EX_SRC_FILES}"
                return 1
            }
            EX_MEMBERS=${OS_RUN_OUTPUT}
            probe::dir_size_kb "${EX_SRC_FILES}"
            [[ ${OS_PROBE_VALUE} =~ ^[0-9]+$ ]] && EX_SIZE_KB=${OS_PROBE_VALUE}
            ;;
    esac
    [[ -n ${EX_MEMBERS} ]] || {
        os::err '来源里是空的'
        return 1
    }
    return 0
}

# ex_audit_members   解包前审查清单，一个字节都不解
#
# GNU tar 默认会剥掉前导 `/` 也会拒绝 `..`，unzip 不会（zip slip）。
# **不指望解包工具替我们把关**，两种包同一条规则。
ex_audit_members() {
    local m sql='' bad=''
    local -i n=0
    while IFS= read -r m; do
        [[ -n ${m} ]] || continue
        if [[ ${m} == /* || ${m} == ../* || ${m} == */../* || ${m} == */.. || ${m} == '..' ]]; then
            n=$((n + 1))
            [[ ${n} -le 5 ]] && bad+="${m}"$'\n'
            continue
        fi
        case ${m} in
            *.sql | *.sql.gz) [[ -n ${sql} ]] || sql=${m} ;;
        esac
    done <<<"${EX_MEMBERS}"

    if [[ ${n} -gt 0 ]]; then
        os::err "来源里有 ${n} 个条目带绝对路径或 .. 路径段，拒绝导入（路径穿越 / zip slip）"
        while IFS= read -r m; do
            [[ -n ${m} ]] && os::info "  ${m}"
        done <<<"${bad}"
        return 1
    fi

    # 站点目录下的 .sql 是能被公网直接下载的 —— 里面有全站数据
    [[ -z ${sql} ]] || {
        os::warn "来源里含 SQL 转储：${sql}"
        os::info '它会跟着解到落点目录里。要灌库请把它单独指给 --source（逗号分隔），'
        os::info '并在导入后删掉解出来的那一份。'
    }
    return 0
}

# ex_depth <相对路径>   路径有几段
ex_depth() {
    local p=${1} n=1
    while [[ ${p} == */* ]]; do
        p=${p#*/}
        n=$((n + 1))
    done
    printf '%s' "${n}"
}

# ex_locate_root <--subdir 的值>   来源里哪一层才是要导入的内容
#
# 按标志文件定位，不猜层数。判据：同一目录下 `wp-config.php`、`wp-includes/`、
# `wp-admin/` **至少中两项** —— 只要一项的话，一个恰好叫 wp-admin 的普通目录
# 就能把根定到错的地方。
#
# 取最浅的候选；**同深度出现多个才拒绝**。只有一个最浅候选时不该多问一句。
#
# 一项都不命中**不是错误**：只迁 wp-content 的包本来就没有标志文件，
# 那时整个来源就是根，落到哪里由 --target 决定。
ex_locate_root() {
    local want=${1-}
    EX_ROOT=''

    if [[ -n ${want} ]]; then
        local w=${want#/}
        w=${w%/}
        if [[ -z ${w} || ${w} == *..* ]]; then
            os::err "--subdir 只收来源内的相对路径，收到「${want}」"
            return 1
        fi
        local m found=''
        while IFS= read -r m; do
            [[ ${m} == "${w}" || ${m} == "${w}/"* ]] || continue
            found=1
            break
        done <<<"${EX_MEMBERS}"
        [[ -n ${found} ]] || {
            os::err "来源里没有这个子路径：${w}"
            return 1
        }
        EX_ROOT=${w}
        return 0
    fi

    # 先用 case 把绝大多数条目挡在外面：十万个文件里带标志名的通常只有几百个，
    # 剩下的才做字符串切分。前缀一律以 `/` 结尾，段数因此等于其中 `/` 的个数。
    #
    # 来源根目录记成 `.` 而不是空串：**bash 的关联数组不接受空下标**
    # （`bad array subscript`），而「站点根就在来源根目录」恰恰是最常见的一种包。
    # 清单里的条目都已经去掉了前导 `./`，所以 `.` 不可能与真实前缀撞上。
    local m p mark
    local -A marks=() cnt=()
    while IFS= read -r m; do
        case ${m} in
            wp-config.php)
                mark='wp-config.php'
                p='.'
                ;;
            */wp-config.php)
                mark='wp-config.php'
                p=${m%wp-config.php}
                ;;
            wp-includes | wp-includes/*)
                mark='wp-includes'
                p='.'
                ;;
            */wp-includes | */wp-includes/*)
                mark='wp-includes'
                p="${m%%/wp-includes*}/"
                ;;
            wp-admin | wp-admin/*)
                mark='wp-admin'
                p='.'
                ;;
            */wp-admin | */wp-admin/*)
                mark='wp-admin'
                p="${m%%/wp-admin*}/"
                ;;
            *) continue ;;
        esac
        [[ -z ${marks["${p}|${mark}"]:-} ]] || continue
        marks["${p}|${mark}"]=1
        cnt["${p}"]=$((${cnt["${p}"]:-0} + 1))
    done <<<"${EX_MEMBERS}"

    # 键展开必须写成 `"${!cnt[@]}"`：`${!cnt[@]+…}` 会被 bash 当成**间接引用**
    # 而不是「数组为空时给个默认」，现场表现是循环一次都不进、每份包都被判成
    # 「没有标志文件」。数组空时用 ${#} 先挡一道，不依赖 set -u 的版本行为。
    local d t bd=-1
    local -a ties=()
    if [[ ${#cnt[@]} -gt 0 ]]; then
        for p in "${!cnt[@]}"; do
            [[ ${cnt["${p}"]} -ge 2 ]] || continue
            d=0
            t=${p}
            [[ ${t} == . ]] && t=''
            while [[ ${t} == */* ]]; do
                t=${t#*/}
                d=$((d + 1))
            done
            if [[ ${bd} -lt 0 || ${d} -lt ${bd} ]]; then
                bd=${d}
                ties=("${p}")
            elif [[ ${d} -eq ${bd} ]]; then
                ties+=("${p}")
            fi
        done
    fi

    if [[ ${bd} -lt 0 ]]; then
        if [[ -n ${EX_SITE_TYPE} ]]; then
            os::warn '来源里没有 WordPress 标志文件，整份内容将按普通目录覆盖站点目录'
            os::info '只迁 wp-content 之类的部分内容时，落点应当写成 path:<那个子目录的绝对路径>'
        fi
        return 0
    fi

    if [[ ${#ties[@]} -gt 1 ]]; then
        os::err '来源里有多个同样深的站点根，无法替你选：'
        for t in "${ties[@]}"; do
            [[ ${t} == . ]] && t='（来源根目录）'
            os::info "  ${t}"
        done
        os::info '用 --subdir=<其中一个> 指定'
        return 1
    fi
    [[ ${ties[0]} == . ]] || EX_ROOT=${ties[0]%/}
    return 0
}

# ex_check_space   解包会在落点所在文件系统上多占一份来源的大小
ex_check_space() {
    [[ ${EX_SIZE_KB} -gt 0 ]] || return 0
    local parent=${EX_DEST_DIR%/*}
    [[ -n ${parent} ]] || parent='/'
    [[ -d ${parent} ]] || return 0
    probe::disk_free_kb "${parent}"
    [[ ${OS_PROBE_VALUE} =~ ^[0-9]+$ ]] || return 0
    local -i free=${OS_PROBE_VALUE}
    local -i need=$((EX_SIZE_KB + EX_SIZE_KB / 10))
    if ((free < need)); then
        os::err "空间不够：${parent} 可用 $((free / 1024)) MB，解包需要约 $((need / 1024)) MB"
        return 1
    fi
    return 0
}

# ==================================================================
# 外部导入 —— SQL 转储
# ==================================================================

# sql_scan <转储文件>   看清楚这份 dump 会往哪个库写、按什么字符集写
#
# dump 里的 `USE 老库` 会把数据写进另一个库，而 `mysql` 仍以 0 退出 ——
# **静默灌错库比失败危险得多。**
#
# 但命中不等于拒绝：phpMyAdmin、宝塔、`mysqldump --databases` 导出的 dump
# 几乎都带 `CREATE DATABASE` + `USE`。一律拒绝等于这个功能对大多数真实迁移
# 不可用，用户只能回去手工编辑几个 G 的文本。所以这里只负责**看见并说清**，
# 剥不剥由调用方问用户，而剥离发生在导入管道里，**原文件一个字节不动**。
sql_scan() {
    local f=${1}
    EX_SQL_HITS='' EX_SQL_CHARSET=''
    os::require_cmd zgrep

    # 一遍扫完两件事：库级语句与字符集声明。
    #
    # **用 zgrep 而不是 `gunzip -c | grep`** —— 后者要一条管道，而管道只能经
    # `sh -c` 表达，那是一条不必要的注入面（也是一条要写理由的 disable）。
    # zgrep 对 `.sql` 与 `.sql.gz` 一视同仁，一条命令、一个 argv。
    #
    # 正则全部锚在行首的完整语句形态：mysqldump 的 INSERT 把换行转义成了 `\n`，
    # 数据行不可能以这几个词开头 —— 正文里写着「USE …」不会被误判成语句。
    local -i rc=0
    os::query --timeout 3600 -- zgrep -n -E \
        '^(USE[[:space:]]|CREATE[[:space:]]+DATABASE|DROP[[:space:]]+DATABASE|(/\*![0-9]+ )?SET NAMES)' \
        "${f}" || rc=$?
    # zgrep 的 1 是「一条都没匹配上」，那是正常结果；2 才是真读不了
    if [[ ${rc} -gt 1 ]]; then
        os::err "读不出转储内容：${f}"
        return 1
    fi

    local line hits=''
    local -i n=0
    while IFS= read -r line; do
        [[ -n ${line} ]] || continue
        if [[ ${line} == *'SET NAMES'* ]]; then
            [[ -z ${EX_SQL_CHARSET} ]] || continue
            EX_SQL_CHARSET=${line#*'SET NAMES '}
            EX_SQL_CHARSET=${EX_SQL_CHARSET%%[^A-Za-z0-9_]*}
            continue
        fi
        n=$((n + 1))
        [[ ${n} -le 20 ]] && hits+="${line}"$'\n'
    done <<<"${OS_RUN_OUTPUT}"
    [[ ${n} -le 20 ]] || hits+="…（还有 $((n - 20)) 条同类语句）"$'\n'
    EX_SQL_HITS=${hits}
    return 0
}

# ex_read_prefix <wp-config 路径>   读出 $table_prefix，读不到就打印空串
ex_read_prefix() {
    local line
    while IFS= read -r line; do
        [[ ${line} =~ \$table_prefix[[:space:]]*=[[:space:]]*[\'\"]([A-Za-z0-9_]+)[\'\"] ]] || continue
        printf '%s' "${BASH_REMATCH[1]}"
        return 0
    done <"${1}"
    return 0
}

# ex_check_prefix <wp-config 路径> <库名>
#
# **导入之后最容易撞、又最看不出原因的一件事。**
#
# 外来站点的表前缀常常不是 `wp_`。三种组合会撞上：只灌了库而文件是本机的、
# 来源包里没有 wp-config 于是沿用了本机那份、有人手工换过 wp-config。
# 撞上之后 WordPress 连得上库、却一张表都认不出 —— 表现是**跳回安装向导**。
# 用户看到的是「导入成功了，然后站点要我重新安装一遍」，几乎不可能想到是前缀。
#
# 所以这里主动核对，并且把库里真实存在的前缀列出来：只说一句「对不上」
# 等于把问题原样丢回给用户。
ex_check_prefix() {
    local conf=${1} db=${2}
    [[ -f ${conf} ]] || return 0
    local prefix
    prefix=$(ex_read_prefix "${conf}")
    [[ -n ${prefix} ]] || return 0

    # 一次查完：既判断有没有 `<前缀>options`，也拿到库里实际的前缀。
    # LIKE 用 `%options` 而不是 `<前缀>options` —— 后者里的 `_` 在 LIKE 里
    # 是通配符，`wp_options` 会连 `wpXoptions` 一起匹上，白白放过真正的不匹配。
    os::sql_query '核对站点表前缀' -- \
        "SHOW TABLES FROM $(os::sql_ident "${db}") LIKE '%options'" || return 0
    local t found='' others=''
    while IFS= read -r t; do
        [[ -n ${t} ]] || continue
        if [[ ${t} == "${prefix}options" ]]; then
            found=1
            break
        fi
        others+="  库里实际有 ${t}（前缀是 ${t%options}）"$'\n'
    done <<<"${OS_RUN_OUTPUT}"
    [[ -z ${found} ]] || return 0

    os::warn "站点配置里的表前缀是「${prefix}」，但库 ${db} 里没有 ${prefix}options 这张表"
    if [[ -n ${others} ]]; then
        while IFS= read -r t; do
            [[ -n ${t} ]] && os::info "${t}"
        done <<<"${others}"
        os::info "改法：编辑 ${conf}，把 \$table_prefix 改成上面那个前缀，再刷新站点"
    else
        os::info "库 ${db} 里连一张 %options 表都没有 —— 这份转储可能不是 WordPress 的，或者没真正导进去"
    fi
    os::warn '不处理的话，打开站点会是 WordPress 的安装向导，而不是你的站'
    return 0
}

# post_restore_hints <站点类型> <站点目录>   恢复/导入完之后该看哪几项
#
# **不自动重启服务、不自动清缓存**：PHP-FPM 上跑着的可能不止这一个站，
# 替用户重启一个正在服务别人的进程不是本命令该做的决定。只把该看的列出来。
post_restore_hints() {
    local site_type=${1}
    [[ ${site_type} == wordpress ]] || return 0
    os::section '接下来自己检查这几项'
    os::info '1. 用浏览器打开站点，别只看这里报的成功'
    os::info '2. 打开后是 WordPress 安装向导 → 表前缀对不上，照上面的提示改 wp-config.php'
    os::info '3. 白屏或 500 → journalctl -u caddy -n 50，以及对应的 php*-fpm 服务日志；'
    os::info '   老站点跑在比本机更旧的 PHP 上时也会白屏，先确认版本对不对得上'
    os::info '4. 图片、样式丢失 → 库里还留着旧域名。WP-CLI：wp search-replace 旧地址 新地址 --all-tables --precise'
    os::info '5. 域名还没指到这台机器 → oneserver caddy'
    os::info '6. 全部确认正常之后再清理恢复前副本，不要提前删'
    return 0
}

# set_site_url <wp-config 路径> <库名> <新地址>
#
# siteurl / home 存在 `<前缀>options` 两行里。**表前缀不写死 `wp_`** ——
# 外来站点常改过它，猜一个前缀去 UPDATE，命中的可能是别的站点的表。
set_site_url() {
    local conf=${1} db=${2} url=${3}
    url=${url%/}

    [[ -f ${conf} ]] || {
        os::err "找不到 ${conf}，读不出表前缀，siteurl / home 未改动"
        return 1
    }
    local prefix
    prefix=$(ex_read_prefix "${conf}")
    if [[ -z ${prefix} ]]; then
        os::err "从 ${conf} 里读不出 \$table_prefix，siteurl / home 未改动"
        os::info '手工改：登录数据库，UPDATE <前缀>options SET option_value=... WHERE option_name IN ('"'"'siteurl'"'"','"'"'home'"'"')'
        return 1
    fi

    local table val
    table="$(os::sql_ident "${db}").$(os::sql_ident "${prefix}options")"
    val=$(os::sql_str "${url}")

    os::sql_query '读取当前站点地址' -- \
        "SELECT option_name, option_value FROM ${table} WHERE option_name IN ('siteurl','home');" \
        || return 1
    os::info "改前：${OS_RUN_OUTPUT//$'\n'/ · }"

    os::record_change "把 ${db} 的 siteurl / home 改成 ${url}"
    os::sql_exec '改写站点地址' -- \
        "UPDATE ${table} SET option_value = ${val} WHERE option_name IN ('siteurl','home');" \
        || return 1
    os::ok "siteurl / home 已改为 ${url}"

    # **只有这两行。** 文章正文、主题与插件设置里的绝对 URL 不会跟着变，而它们
    # 大多躺在序列化字符串里（`s:23:"http://旧域名/x"`）—— 用正则替换会让长度与
    # 声明对不上，整条设置作废。那正是 wp search-replace 存在的理由，本工具不自造。
    os::warn '只改了 siteurl 与 home，文章正文与插件设置里的旧域名不受影响'
    os::info '要全库替换请用 WP-CLI：wp search-replace 旧地址 新地址 --all-tables --precise'
    return 0
}

# ==================================================================
# 外部导入 —— 落地
# ==================================================================

# ex_unpack <staging>   把来源解到暂存目录
#
# 不用 `--strip-components` 直落落点：那时旧目录已经被挪去 pre-restore 了，
# 解到一半失败的现场是「半个新站点，旧的在别处」。而且 unzip 根本没有这个选项，
# 直落等于要写两条危险写入路径。**解到隔壁再整个改名**让两种包共用一条路，
# 失败时落点一个字节没动。
ex_unpack() {
    local staging=${1}
    local raw="${staging}.raw"

    case ${EX_KIND} in
        tar | zip)
            local -a cmd=()
            if [[ ${EX_KIND} == tar ]]; then
                # --no-same-owner：归档里记的是**源机的**数字 uid，本机的同号
                # 用户可能是另一个人。解出来先归 root，属主由 ex_apply_ownership
                # 按落点类型定。
                cmd=(tar -xf "${EX_SRC_FILES}" --no-same-owner -C)
            else
                cmd=(unzip -q -o "${EX_SRC_FILES}" -d)
            fi
            if [[ -z ${EX_ROOT} ]]; then
                os::run '解出来源' -- "${cmd[@]}" "${staging}" || return 1
            else
                # tar 不会替你建 -C 的目录（unzip -d 会），少这一步整包必挂。
                # 0700 与 staging 同：解包中途 /var/www 下不该有一份 web 可读的站点副本
                os::run '创建解包目录' -- mkdir -m 0700 -p "${raw}" || return 1
                # 先登记再解 —— 解到一半失败时 raw 里已经有半个站点了
                os::defer rm -rf -- "${raw}"
                os::run '解出来源' -- "${cmd[@]}" "${raw}" || return 1
                # staging 此刻还是空的，腾掉它再把站点根整个改名过来 —— 比逐项 mv
                # 少一个「点开头的文件被 * 漏掉」的坑（.htaccess / .user.ini）
                os::run '腾出暂存目录' -- rmdir "${staging}" || return 1
                os::run '取出来源里的站点根' -- mv -- "${raw}/${EX_ROOT}" "${staging}" || return 1
                os::run '清理解包残留' -- rm -rf -- "${raw}" || return 1
            fi
            ;;
        dir)
            # 结尾的 `/.` 才会把点开头的文件一起拷过去
            os::run '拷入来源' -- \
                cp -a "${EX_SRC_FILES}/${EX_ROOT:+${EX_ROOT}/}." "${staging}/" || return 1
            ;;
    esac
    return 0
}

# ex_link_target_escapes <staging> <链接绝对路径> <链接目标>   目标落在 staging 外面吗
#
# 直接拒绝一切带 `..` 的目标要简单得多，但站点内部的相对链接
# （`wp-content/uploads/x -> ../y`）是合法的 —— 一刀切会把正常备份挡在门外，
# 而迁移这件事用户往往只有一次机会。所以这里逐段规范化，真算一遍它落在哪。
ex_link_target_escapes() {
    local staging=${1} link=${2} target=${3}
    [[ ${target} != /* ]] || return 0
    local -a segs=() out=()
    local seg path
    local IFS='/'
    read -ra segs <<<"${link%/*}/${target}"
    IFS=$'\n\t'
    for seg in ${segs[@]+"${segs[@]}"}; do
        case ${seg} in
            '' | .) ;;
            ..)
                # 已经在根上还要往上：无论后面接什么都出界了
                [[ ${#out[@]} -gt 0 ]] || return 0
                unset 'out[-1]'
                ;;
            *) out+=("${seg}") ;;
        esac
    done
    IFS='/'
    path="/${out[*]}"
    IFS=$'\n\t'
    [[ ${path} != "${staging}" && ${path} != "${staging}/"* ]]
}

# ex_audit_symlinks <staging>   解包后再查一遍符号链接
#
# 清单审查挡的是「写到 staging 外面去」，这里挡的是「留在 staging 里、但指向
# 外面」—— 一个 `wp-content/x.php -> /etc/shadow` 搬进站点目录之后，
# PHP 就能读它。
ex_audit_symlinks() {
    local staging=${1}
    os::query --timeout 600 -- find "${staging}" -type l -printf '%p -> %l\n' || return 0
    [[ -n ${OS_RUN_OUTPUT} ]] || return 0

    local line p t bad=''
    local -i n=0
    while IFS= read -r line; do
        [[ -n ${line} ]] || continue
        p=${line%% -> *}
        t=${line#* -> }
        ex_link_target_escapes "${staging}" "${p}" "${t}" || continue
        n=$((n + 1))
        [[ ${n} -le 5 ]] && bad+="${line#"${staging}/"}"$'\n'
    done <<<"${OS_RUN_OUTPUT}"

    [[ ${n} -gt 0 ]] || return 0
    os::err "来源里有 ${n} 个指向自身之外的符号链接，拒绝导入"
    while IFS= read -r line; do
        [[ -n ${line} ]] && os::info "  ${line}"
    done <<<"${bad}"
    return 1
}

# ex_apply_ownership <staging>   属主与权限
#
# 解出来的东西现在归 root。往下分两条：
#   site 落点 —— 站点的权限模型由本工具定义，套 deploy_wordpress 那一套
#   path 落点 —— 任意路径可能是任何东西，替用户猜属主是在做他没要求的决定，
#                保持 root:root 并说清楚
#
# `chown -Rh` 的 `-h` 是硬要求：来源里可以有符号链接，跟着链接改属主等于改到
# 链接指向的地方去 —— 那可能是站点之外的文件。
ex_apply_ownership() {
    local staging=${1}
    if [[ -z ${EX_SITE_TYPE} ]]; then
        os::run '设置导入内容属主' -- chown -Rh root:root "${staging}" || return 1
        os::info '导入内容的属主是 root:root，需要别的属主请自行 chown'
        # 权限位保留来源里的：那是来源带来的事实，改它是替用户做决定。
        # 但世界可写必须说一声，它是实打实的风险。
        os::query --timeout 600 -- find "${staging}" -perm -0002 -printf '%P\n' || return 0
        [[ -n ${OS_RUN_OUTPUT} ]] || return 0
        local -i n=0
        local line
        while IFS= read -r line; do
            [[ -n ${line} ]] && n=$((n + 1))
        done <<<"${OS_RUN_OUTPUT}"
        os::warn "来源里有 ${n} 个任何人都可写的文件或目录，权限位按原样保留了"
        os::info "要收紧：chmod -R o-w ${EX_DEST_DIR}"
        return 0
    fi

    os::run '设置站点目录属主' -- chown -Rh www-data:www-data "${staging}" || return 1
    os::run '设置目录权限' -- find "${staging}" -type d -exec chmod 0755 {} + || return 1
    os::run '设置文件权限' -- \
        find "${staging}" -type f -not -name wp-config.php -exec chmod 0644 {} + || return 1
    if [[ -d ${staging}/wp-content ]]; then
        os::run '放宽 wp-content 目录权限' -- \
            find "${staging}/wp-content" -type d -exec chmod 0775 {} + || return 1
        os::run '放宽 wp-content 文件权限' -- \
            find "${staging}/wp-content" -type f -exec chmod 0664 {} + || return 1
    fi
    [[ -f ${staging}/wp-config.php ]] \
        && { os::run '收紧 wp-config.php 权限' -- chmod 0640 "${staging}/wp-config.php" || return 1; }
    return 0
}

# ex_keep_wp_config <staging>
#
# 不少备份出于安全不含 wp-config.php。整目录换过去之后站点就没有配置文件了，
# 现场是白屏 —— 而本机 deploy 出来的那份恰好是对的（库、账号、密码都是本机的）。
ex_keep_wp_config() {
    local staging=${1}
    [[ -n ${EX_SITE_TYPE} ]] || return 0
    [[ ! -f ${staging}/wp-config.php ]] || return 0

    if [[ -f ${EX_DEST_DIR}/wp-config.php ]]; then
        os::run '沿用本机现有的 wp-config.php' -- \
            cp -a "${EX_DEST_DIR}/wp-config.php" "${staging}/wp-config.php" || return 1
        os::ok '来源里没有 wp-config.php，沿用本机站点目录里的那份'
        return 0
    fi
    os::err '来源里没有 wp-config.php，本机站点目录里也没有 —— 导入后站点起不来'
    os::info "先跑 oneserver deploy wordpress 生成一份，再导入"
    return 1
}

# import_files   外部来源的文件落地。顺序见函数体，失败点与退路见文件头第六点。
import_files() {
    local ts
    printf -v ts '%(%Y%m%d-%H%M%S)T' -1
    local parent=${EX_DEST_DIR%/*}
    [[ -n ${parent} ]] || parent='/'
    local base=${EX_DEST_DIR##*/}

    # 落点父目录在本机可能根本不存在（path: 指向一个全新的位置）。
    # 0755 而不是 umask 027 给的 0750：站点父目录必须让 www-data 进得去。
    # 归「必须回滚」：撤销用 rmdir 不是 rm -rf —— 后面真失败时目录里已经有内容了，
    # rmdir 会失败并把它留下，这是对的。
    if [[ ! -d ${parent} ]]; then
        os::run '创建落点父目录' -- mkdir -p "${parent}" || return 1
        os::defer rmdir -- "${parent}"
        os::run '确保落点父目录可进入' -- chmod 0755 "${parent}" || return 1
    fi

    # 单个文件：没有清单、没有站点根，直接换掉
    if [[ ${EX_KIND} == file ]]; then
        stash_current "${EX_DEST_DIR}" "${base}-${ts}" || return 1
        os::run '放入文件' -- cp -a "${EX_SRC_FILES}" "${EX_DEST_DIR}" || return 1
        os::ok "已导入 ${EX_DEST_DIR}"
        return 0
    fi

    # staging 必须与落点同一个文件系统，最后那步 mv 才是改名而不是拷贝
    local staging="${parent}/.oneserver-import-${ts}"
    os::run '创建暂存目录' -- mkdir -p "${staging}" || return 1
    os::defer rm -rf -- "${staging}"
    os::run '收紧暂存目录权限' -- chmod 0700 "${staging}" || return 1

    ex_unpack "${staging}" || return 1
    ex_audit_symlinks "${staging}" || return 1
    ex_apply_ownership "${staging}" || return 1
    ex_keep_wp_config "${staging}" || return 1

    stash_current "${EX_DEST_DIR}" "${base}-${ts}" || return 1
    os::run '就位导入的内容' -- mv "${staging}" "${EX_DEST_DIR}" || return 1
    os::ok "文件已导入 ${EX_DEST_DIR}"
    return 0
}

# ex_preview <落点标识>   动手之前把结论摆出来
ex_preview() {
    local target=${1}
    os::section '这次要导入什么'

    local -a kv=()
    [[ -n ${EX_SRC_FILES} ]] && kv+=('文件来源' "${EX_SRC_FILES}")
    if [[ -n ${EX_SRC_FILES} && ${EX_KIND} != file ]]; then
        kv+=('来源内的根' "${EX_ROOT:-（整份来源）}" '解包后约' "$((EX_SIZE_KB / 1024)) MB")
    fi
    [[ -n ${EX_SRC_SQL} ]] && kv+=('SQL 转储' "${EX_SRC_SQL}")
    kv+=('落点' "${target}")
    [[ -n ${EX_DEST_DIR} ]] && kv+=('落点目录' "${EX_DEST_DIR}")
    [[ -n ${EX_DEST_DB} ]] && kv+=('落点数据库' "${EX_DEST_DB}")
    os::kv "${kv[@]}"

    # 路径打错一个字母就会静静地建出一个新目录，导入「成功」而站点纹丝不动。
    # 在确认之前把这件事说出来，是唯一能拦住它的时机。
    if [[ -n ${EX_DEST_DIR} && ! -e ${EX_DEST_DIR} ]]; then
        os::warn "落点 ${EX_DEST_DIR} 当前不存在，导入时会新建它 —— 路径没写错吧？"
    fi

    if [[ -n ${EX_SRC_FILES} && ${EX_KIND} != file ]]; then
        local m rel tops='' prefix=''
        local -i n=0
        local -A seen=()
        [[ -n ${EX_ROOT} ]] && prefix="${EX_ROOT}/"
        while IFS= read -r m; do
            [[ -z ${prefix} || ${m} == "${prefix}"* ]] || continue
            rel=${m#"${prefix}"}
            rel=${rel%%/*}
            # 空下标是 bash 关联数组的硬错误，先挡住再查重
            [[ -n ${rel} ]] || continue
            [[ -z ${seen["${rel}"]:-} ]] || continue
            seen["${rel}"]=1
            n=$((n + 1))
            [[ ${n} -le 12 ]] && tops+="${rel} · "
        done <<<"${EX_MEMBERS}"
        os::kv '将解出' "${tops% · }（共 ${n} 个顶层项）"
    fi

    if [[ -n ${EX_SRC_SQL} ]]; then
        if [[ -z ${EX_SQL_CHARSET} ]]; then
            os::warn "转储里没有字符集声明，将按 ${OS_DEFAULT_DB_CHARSET} 导入"
            os::info '原库是 gbk / latin1 的话先用 iconv 转成 UTF-8，否则导进来是乱码'
        elif [[ ${EX_SQL_CHARSET} != "${OS_DEFAULT_DB_CHARSET}" ]]; then
            os::info "转储声明的字符集是 ${EX_SQL_CHARSET}，本机默认是 ${OS_DEFAULT_DB_CHARSET}"
            os::info '按转储声明的走（mysql 会执行 dump 里的 SET NAMES），这里只是说明一声'
        fi
    fi

    if [[ -n ${EX_SQL_HITS} ]]; then
        os::warn '转储里有库级语句，它们会让数据写进转储自己指定的库，而 mysql 仍以 0 退出：'
        local line
        while IFS= read -r line; do
            [[ -n ${line} ]] && os::info "  ${line}"
        done <<<"${EX_SQL_HITS}"
    fi
    return 0
}

# import_external   `--from=external` 的完整流程
import_external() {
    local spec=''
    os::ask --validate ex_split_source \
        --hint '压缩包 .tar/.tar.gz/.tgz/.zip · 已解开的目录 · 单个文件 · 转储 .sql/.sql.gz；两者可用逗号一次给全' \
        --arg source '外部备份的路径' spec ''

    local target=''
    os::ask --validate ex_resolve_dest \
        --hint 'site:<站点名> 整站 · db:<库名> 只灌库 · path:<别名或绝对路径> 任意目录或文件' \
        --arg target '导入到哪里' target ''

    # 来源与落点要配得上
    [[ -z ${EX_SRC_SQL} || -n ${EX_DEST_DB} ]] \
        || os::die 2 "落点 ${target} 上没有数据库，SQL 转储无处可灌"
    [[ -z ${EX_SRC_FILES} || -n ${EX_DEST_DIR} ]] \
        || os::die 2 "落点 ${target} 只有数据库，文件来源无处可放"

    # 单个文件落到一个已经存在的目录上：现有做法会把整个目录挪进 pre-restore、
    # 再放一个文件进去，而用户十有八九想的是「放进这个目录里」。
    # **这种破坏性歧义不猜**，让他把话说全。
    if [[ ${EX_KIND} == 'file' && -d ${EX_DEST_DIR} ]]; then
        os::err "落点 ${EX_DEST_DIR} 是一个已存在的目录，而来源是单个文件"
        os::die 2 "把落点写成完整的目标文件路径，例如：--target=path:${EX_DEST_DIR}/${EX_SRC_FILES##*/}"
    fi

    if [[ -n ${EX_SRC_FILES} && ${EX_KIND} != 'file' ]]; then
        # 先把来源读出来、审查完，再问子路径 —— 反过来的话，一个根本读不开的
        # 压缩包会让用户先白答一道题
        ex_read_members || os::die 1 '读不出来源清单，未做任何改动'
        ex_audit_members || os::die 1 '来源清单未通过审查，未做任何改动'
        local subdir=''
        os::ask --arg subdir \
            '来源里哪一层是要导入的内容？（多数情况直接回车，让它自己找）' subdir ''
        ex_locate_root "${subdir}" || os::die 2 '定位不出要导入的内容，未做任何改动'
        ex_check_space || os::die 1 '空间不够，未做任何改动'
    fi

    [[ -z ${EX_SRC_SQL} ]] || sql_scan "${EX_SRC_SQL}" || os::die 1 '读不出 SQL 转储，未做任何改动'

    local site_url=''
    if [[ -n ${EX_SITE_TYPE} ]]; then
        os::ask --match '^$|^https?://[^[:space:]]+$' \
            --hint '换服务器不换域名就留空 —— 转储里带来的地址本来就是对的' \
            --arg site-url '站点的新域名（留空 = 不动 siteurl / home）' site_url ''
    fi

    ex_preview "${target}"

    if [[ -n ${EX_SQL_HITS} ]]; then
        if os::confirm --arg strip-db-statements \
            '把上面这些语句剥离后导入？（只在导入管道里跳过，不改动你的原文件）' n; then
            EX_STRIP=1
        else
            os::die 2 '已停止，未做任何改动。留着这些语句导入，数据会进转储里写的那个库'
        fi
    fi

    local -a items=()
    [[ -n ${EX_SRC_SQL} ]] \
        && items+=("数据库 ${EX_DEST_DB} 的现有内容将被 ${EX_SRC_SQL##*/} 覆盖（会先自动备一份）")
    [[ -n ${EX_SRC_FILES} ]] \
        && items+=("${EX_DEST_DIR} 将被 ${EX_SRC_FILES##*/} 的内容替换（会先整个挪到 ${RS_PRE_DIR}）")
    [[ -n ${site_url} ]] \
        && items+=("${EX_DEST_DB} 里的 siteurl 与 home 将改为 ${site_url}")
    # 三道门在这条路上不存在，这件事必须让人在按下确认之前看见
    items+=('这份备份没有 sha256、没有 manifest —— 它是否完整、是否被人动过，只有你自己知道')

    if ! os::destroy_confirm --arg confirm-restore "${target}" -- "${items[@]}"; then
        os::info '已取消，未做任何改动'
        os::output 0 changed=no
        return 0
    fi

    os::critical_begin '导入外部备份'
    local rc=0
    if [[ -n ${EX_SRC_SQL} ]]; then
        restore_db "${EX_DEST_DB}" "${EX_SRC_SQL}" "${EX_STRIP}" || rc=1
    fi
    if [[ ${rc} -eq 0 && -n ${EX_SRC_FILES} ]]; then
        import_files || rc=1
    fi
    # 凭据以活系统为准：外来 wp-config 里是源站的库名账号密码，本机是另一套
    if [[ ${rc} -eq 0 && -n ${EX_SITE_TYPE} && -n ${EX_SRC_FILES} ]]; then
        fixup_credentials "${EX_SITE_TYPE}" "${EX_SITE_NAME}" "${EX_DEST_DIR}" || rc=1
    fi
    if [[ ${rc} -eq 0 && -n ${site_url} ]]; then
        set_site_url "${EX_DEST_DIR}/wp-config.php" "${EX_DEST_DB}" "${site_url}" || rc=1
    fi
    os::critical_end

    if [[ ${rc} -ne 0 ]]; then
        os::output 1 target="${target}"
        os::die 1 "导入未完成。覆盖前的副本在 ${RS_PRE_DIR}"
    fi

    # 灌过库的站点一律核对前缀。**这一步不能因为「导入成功了」就省掉** ——
    # 前缀对不上时前面每一步都会报成功，只有打开站点才看得出来
    [[ -z ${EX_SITE_TYPE} || -z ${EX_SRC_SQL} ]] \
        || ex_check_prefix "${EX_DEST_DIR}/wp-config.php" "${EX_DEST_DB}"

    os::ok "导入完成：${target}"
    os::info "覆盖前的副本留在 ${RS_PRE_DIR}，确认站点正常后可以自行清理"
    post_restore_hints "${EX_SITE_TYPE}"
    os::output 0 target="${target}" source="${EX_SRC_FILES:-${EX_SRC_SQL}}" changed=yes
    return 0
}

# ==================================================================

main() {
    os::require_cmd tar gzip sha256sum find

    local from=''
    os::select --arg from '从哪里恢复' from \
        'local=本地归档' 'remote=rclone 远端' 'external=外部文件（别的面板或主机迁来的备份）'
    case ${from} in
        local | remote | external) ;;
        *) os::die 2 "--from 只能是 local / remote / external，收到「${from}」" ;;
    esac

    # 外来备份过不了下面那三道门（sha256 / manifest / schema），走自己的前段；
    # 写入动作仍然落回同一批函数，理由见文件头第六点
    if [[ ${from} == external ]]; then
        import_external
        return $?
    fi

    # --- 1. 选目标 ---
    if [[ ${from} == remote ]]; then
        load_remote || os::die 3 '还没有配置远端，先跑 oneserver backup remote'
        remote_targets || os::die 3 "远端 ${RS_REMOTE}:${RS_REMOTE_DIR} 下没有任何归档"
    else
        local_targets || os::die 3 "本地没有任何归档（${OS_ARCHIVE_DIR}）"
    fi

    local -a targets=()
    mapfile -t targets <<<"${RS_ENTRIES}"
    local target=''
    os::select --arg target '恢复哪个目标' target "${targets[@]}"

    local ok=''
    local t
    for t in "${targets[@]}"; do
        [[ ${t} == "${target}" ]] && ok=1
    done
    [[ -n ${ok} ]] || {
        local IFS=' '
        os::die 2 "没有这个目标：${target}（可用：${targets[*]}）"
    }
    local type=${target%%:*} name=${target#*:}

    # --- 2. 选归档 ---
    if [[ ${from} == remote ]]; then
        remote_archives "${type}" "${name}" || os::die 3 "远端 ${target} 下没有归档"
    else
        local_archives "${type}" "${name}" || os::die 3 "本地 ${target} 下没有归档"
    fi
    local -a archives=()
    mapfile -t archives <<<"${RS_ENTRIES}"

    # **把每一份都列出来，带上时间与大小。** 原来只问一句「共 N 份」再给个
    # 默认值，另外几份长什么样、多大、什么时候的，用户一个都看不见。
    #
    # 顺带说清「为什么只有这么几份」：份数是保留策略的结果，不是 bug ——
    # 备了十次却只看到两份的人，第一反应必然是工具出错了。
    local keep
    keep=$(os::state_get backup local_keep "${OS_DEFAULT_BACKUP_LOCAL_KEEP}")
    [[ ${from} == remote ]] \
        && keep=$(os::state_get backup remote_keep "${OS_DEFAULT_BACKUP_REMOTE_KEEP}")
    os::info "共 ${#archives[@]} 份（保留策略是 ${keep} 份，更早的已按策略清理）"

    local -a choices=()
    local t desc
    for t in "${archives[@]}"; do
        desc=$(archive_desc "${from}" "${type}" "${name}" "${t}")
        choices+=("${t}=${desc}")
    done
    # 选项天然只收清单里的值，填错原地重问；非交互下取第一项，也就是最新那份
    local file=''
    os::select --arg file '恢复哪一份（最新的在最前）' file "${choices[@]}"

    # --- 3. 取回 + 校验 + 读 manifest ---
    fetch_archive "${from}" "${type}" "${name}" "${file}" || os::die 1 '取回归档失败'
    verify_archive "${RS_ARCHIVE}" || os::die 1 '归档校验未通过，未做任何改动'
    read_manifest "${RS_ARCHIVE}" || os::die 1 '读不出归档的 manifest，未做任何改动'

    os::section '这份归档是什么'
    os::kv '目标' "${RS_MF_TYPE}:${RS_MF_NAME}" \
        '生成于' "${RS_MF_CREATED}" \
        '来自主机' "${RS_MF_HOST}" \
        '源路径' "${RS_MF_SOURCE:-（无文件）}" \
        '数据库' "${RS_MF_DB:-（无）}"

    # 归档的自我声明与「用户挑的是哪个目录」不一致时停下：多半是目录被人手工
    # 挪过归档，按 manifest 恢复会写到一个用户没预期的地方
    if [[ ${RS_MF_TYPE} != "${type}" || ${RS_MF_NAME} != "${name}" ]]; then
        os::warn "归档自称是 ${RS_MF_TYPE}:${RS_MF_NAME}，而它躺在 ${target} 下"
        os::info '以 manifest 为准继续，源路径见上'
    fi

    # --- 4. oneserver:self 走单独一条路 ---
    if [[ ${RS_MF_TYPE} == oneserver ]]; then
        restore_self "${RS_ARCHIVE}" "${RS_MF_ROOT}"
        return 0
    fi

    # --- 5. 选模式 ---
    #
    # **选项按这份归档里真有什么来给。** 原来三个选项固定摆着，而一份只有库的
    # 归档选「仅文件」的下场是当场报错退出 —— 把一个工具自己知道不成立的选择
    # 摆到人面前，等他选错再纠正他。
    local -a modes=()
    [[ -n ${RS_MF_DB} && -n ${RS_MF_ROOT} ]] && modes+=('all=数据库与文件')
    [[ -n ${RS_MF_DB} ]] && modes+=('db=仅数据库')
    [[ -n ${RS_MF_ROOT} ]] && modes+=('files=仅文件')
    [[ ${#modes[@]} -gt 0 ]] || os::die 3 '这份归档里既没有数据库也没有文件，内容不完整'
    [[ ${#modes[@]} -gt 1 ]] || os::info '这份归档里只有一种内容，下面这一项是唯一选择'

    local mode=''
    # os::select 天然只收清单里的值：填错原地重问，命令行给错的值以 2 停下。
    # 因此这里不需要再补一遍「mode 是不是合法」的判断。
    os::select --arg mode '恢复什么' mode "${modes[@]}"

    local only=''
    if [[ ${mode} != db ]]; then
        os::ask --arg only '只恢复归档内的某个子路径（留空 = 整份，例：wp-content/uploads）' only ''
    fi
    # 库整份回到备份那一刻、文件只回一段，两边讲的就不是同一个时间点的事了。
    # 典型后果：文章在库里存在，附件却还是现在这份（或者反过来）。
    if [[ ${mode} == all && -n ${only} ]]; then
        os::warn "数据库会整份恢复，而文件只恢复 ${only} 这一段 —— 两边可能对不上"
        os::info '只想回滚一部分文件、不动数据库的话，选「仅文件」（--mode=files）'
    fi

    # --- 6. 确认。覆盖是不可逆的，走规范那一套 ---
    local -a items=()
    if [[ ${mode} == all || ${mode} == db ]] && [[ -n ${RS_MF_DB} ]]; then
        items+=("数据库 ${RS_MF_DB} 的当前内容（会先自动备一份）")
    fi
    if [[ ${mode} == all || ${mode} == files ]] && [[ -n ${RS_MF_ROOT} ]]; then
        if [[ -n ${only} ]]; then
            items+=("目录 ${RS_MF_SOURCE}/${only#/}（会先整个挪到 ${RS_PRE_DIR}）")
        else
            items+=("目录 ${RS_MF_SOURCE}（会先整个挪到 ${RS_PRE_DIR}）")
        fi
    fi
    [[ ${#items[@]} -gt 0 ]] || os::die 2 '这个模式下没有任何可恢复的内容'

    if ! os::destroy_confirm --arg confirm-restore "${target}" -- "${items[@]}"; then
        os::info '已取消，未做任何改动'
        os::output 0 changed=no
        return 0
    fi

    # --- 7. 解出内容并恢复 ---
    os::critical_begin '恢复数据'
    local rc=0
    if [[ ${mode} == all || ${mode} == db ]] && [[ -n ${RS_MF_DB} ]]; then
        local dir
        os::tmpdir dir || os::die 1 '无法创建临时目录'
        os::query --timeout 3600 -- tar -xzf "${RS_ARCHIVE}" -C "${dir}" database.sql \
            || os::die 1 '归档里取不出 database.sql'
        restore_db "${RS_MF_DB}" "${dir}/database.sql" || rc=1
    fi
    if [[ ${rc} -eq 0 && (${mode} == all || ${mode} == files) ]] && [[ -n ${RS_MF_ROOT} ]]; then
        restore_files "${RS_ARCHIVE}" "${RS_MF_SOURCE}" "${RS_MF_ROOT}" "${only}" || rc=1
        # 只在整份恢复时校对：`--only` 恢复的是子目录，配置文件没被覆盖
        if [[ ${rc} -eq 0 && -z ${only} ]]; then
            fixup_credentials "${RS_MF_SITE_TYPE}" "${RS_MF_NAME}" "${RS_MF_SOURCE}" || rc=1
        fi
    fi
    os::critical_end

    if [[ ${rc} -ne 0 ]]; then
        os::output 1 target="${target}" mode="${mode}"
        os::die 1 "恢复未完成。恢复前副本在 ${RS_PRE_DIR}"
    fi

    # 库来自归档、而文件这次没恢复（--mode=db）时，站点目录里的 wp-config
    # 仍是本机的那份，它的表前缀未必与归档里的库对得上
    [[ ${mode} != db || -z ${RS_MF_SITE_TYPE} || -z ${RS_MF_SOURCE} ]] \
        || ex_check_prefix "${RS_MF_SOURCE}/wp-config.php" "${RS_MF_DB}"

    os::ok "恢复完成：${target}（${mode}）"
    os::info "恢复前的副本留在 ${RS_PRE_DIR}，确认站点正常后可以自行清理"
    post_restore_hints "${RS_MF_SITE_TYPE}"
    os::output 0 target="${target}" mode="${mode}" archive="${file}" changed=yes
    return 0
}

main "$@"
