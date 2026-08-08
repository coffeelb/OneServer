#!/bin/bash
#
# 从备份归档恢复
#
# @command      restore
# @name         恢复管理
# @group        backup
# @order        20
# @privilege    root
# @requires_lib >= 1.14
# @args         [--target=<类型:名字>] [--file=<归档文件名>] [--from=<local|remote>] [--mode=<all|db|files>] [--only=<归档内相对路径>] [--confirm-restore=<类型:名字>]
# @description  挑一份归档，校验后恢复；恢复前自动留副本
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
    dir=$(os::tmpdir) || return 1
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
    dir=$(os::tmpdir) || return 1
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

restore_db() {
    local db=${1} sqlfile=${2}
    snapshot_db "${db}" || return 1

    local ident
    ident=$(os::sql_ident "${db}")
    os::sql_exec '重建目标数据库' -- \
        "DROP DATABASE IF EXISTS ${ident}; CREATE DATABASE ${ident} CHARACTER SET ${OS_DEFAULT_DB_CHARSET} COLLATE ${OS_DEFAULT_DB_COLLATE};" \
        || return 1
    # 同 snapshot_db：位置参数传值，不拼进脚本文本
    # shellcheck disable=SC2016  # 理由：$1/$2/$3 是内层 sh 的位置参数，故意不让外层展开
    os::run '导入数据库转储' -- sh -c \
        'mysql --default-character-set="$1" "$2" < "$3"' \
        _ "${OS_DEFAULT_DB_CHARSET}" "${db}" "${sqlfile}" \
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
    os::run '创建恢复前副本目录' -- mkdir -p "${RS_PRE_DIR}"
    os::run '收紧恢复前副本目录权限' -- chmod 0700 "${RS_PRE_DIR}"

    if [[ -z ${only} ]]; then
        # 整目录：先把现有的整个挪走，不是删（D140 的同一条理由）
        if [[ -e ${source} ]]; then
            os::run '移走当前目录作为恢复前副本' -- \
                mv "${source}" "${RS_PRE_DIR}/${root}-${ts}" || return 1
            os::ok "恢复前副本：${RS_PRE_DIR}/${root}-${ts}"
        fi
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
    if [[ -e ${live} ]]; then
        os::run '移走当前子目录作为恢复前副本' -- \
            mv "${live}" "${RS_PRE_DIR}/${root}-${sub//\//_}-${ts}" || return 1
        os::ok "恢复前副本：${RS_PRE_DIR}/${root}-${sub//\//_}-${ts}"
    fi
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

main() {
    os::require_cmd tar gzip sha256sum find

    local from=''
    os::select --arg from '从哪里恢复' from 'local=本地归档' 'remote=rclone 远端'
    case ${from} in
        local | remote) ;;
        *) os::die 2 "--from 只能是 local 或 remote，收到「${from}」" ;;
    esac

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
    local mode=''
    os::select --arg mode '恢复什么' mode 'all=数据库与文件' 'db=仅数据库' 'files=仅文件'
    case ${mode} in
        all | db | files) ;;
        *) os::die 2 "--mode 只能是 all / db / files，收到「${mode}」" ;;
    esac
    [[ ${mode} == db && -z ${RS_MF_DB} ]] && os::die 2 '这份归档里没有数据库'
    [[ ${mode} == files && -z ${RS_MF_ROOT} ]] && os::die 2 '这份归档里没有文件'

    local only=''
    if [[ ${mode} != db ]]; then
        os::ask --arg only '只恢复归档内的某个子路径（留空 = 整份，例：wp-content/uploads）' only ''
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
        dir=$(os::tmpdir) || os::die 1 '无法创建临时目录'
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

    os::ok "恢复完成：${target}（${mode}）"
    os::info "恢复前的副本留在 ${RS_PRE_DIR}，确认站点正常后可以自行清理"
    os::output 0 target="${target}" mode="${mode}" archive="${file}" changed=yes
    return 0
}

main "$@"
