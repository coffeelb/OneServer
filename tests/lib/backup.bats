#!/usr/bin/env bats
#
# script/ops/backup.sh —— 备份
#
# 这里钉的是**「备份成功了却被判失败」这一类**：命令都跑对了，只是取值的一步
# 把值取错了，于是备份流程在最后一段自己把自己判死。两条都真实发生过，而且
# 现场都看不出问题——报错里打出来的两个哈希肉眼一模一样，被删的那份文件名
# 是空的。所以用例断言的是**取出来的值**，不是文案。
#
# 装配方式同 install_podman.bats：剥掉绝对路径的 bootstrap 装配与末行 main，
# 其余原样 source —— 文件顶上的 `IFS=$'\n\t'` 必须保留，两条 bug 里有一条
# 正是它引起的。

setup() {
    load "${BATS_TEST_DIRNAME}/../helper/load.sh"
    STUB="${BATS_TEST_TMPDIR}/backup-stub.sh"
    BACKUP="${OS_TEST_REPO_ROOT}/script/ops/backup.sh"
    sed -e '/^source \/opt\/oneserver\/lib\/bootstrap\.sh$/d' -e '$d' \
        "${BACKUP}" >"${STUB}"
    SUM='2737d8e6f83131c070f2ed21e3a9641abd1d5391f271c82032f9df2dca8e2da3'
}

backup_run() {
    run bash -c "
        source '${OS_TEST_REPO_ROOT}/lib/bootstrap.sh'
        source '${STUB}'
        $1
    "
}

@test "回读远端校验和：本地那份只取哈希列，不把文件名一起比进去" {
    local dir="${BATS_TEST_TMPDIR}/ar"
    local file="${dir}/20260811-192948.tar.gz"
    mkdir -p "${dir}"
    printf 'archive' >"${file}"
    # sha256sum 的输出格式是「哈希␣␣文件名」，分隔符是空格；而本脚本的 IFS 是
    # $'\n\t'，不含空格 —— read 不带 IFS=' ' 前缀的话整行都进第一个变量
    printf '%s  %s\n' "${SUM}" '20260811-192948.tar.gz' >"${file}.sha256"
    backup_run "
        BK_REMOTE=onedrive
        BK_REMOTE_DIR=oneserver/backups
        os::run() { OS_RUN_SKIPPED=0; return 0; }
        os::query() { OS_RUN_OUTPUT='${SUM}  20260811-192948.tar.gz'; OS_RUN_SKIPPED=0; return 0; }
        push_remote site test '${file}'
    "
    [ "${status}" -eq 0 ]
    [[ "${output}" != *'不一致'* ]]
}

@test "回读远端校验和：真不一致时照样要拦住" {
    local dir="${BATS_TEST_TMPDIR}/ar"
    local file="${dir}/20260811-192948.tar.gz"
    mkdir -p "${dir}"
    printf 'archive' >"${file}"
    printf '%s  %s\n' "${SUM}" '20260811-192948.tar.gz' >"${file}.sha256"
    backup_run "
        BK_REMOTE=onedrive
        BK_REMOTE_DIR=oneserver/backups
        os::run() { OS_RUN_SKIPPED=0; return 0; }
        os::query() { OS_RUN_OUTPUT='0000000000000000000000000000000000000000000000000000000000000000  20260811-192948.tar.gz'; OS_RUN_SKIPPED=0; return 0; }
        push_remote site test '${file}'
    "
    [ "${status}" -ne 0 ]
    [[ "${output}" == *'不一致'* ]]
}

@test "清理旧本地备份：删最旧的几份，删的名字里没有空项" {
    local root="${BATS_TEST_TMPDIR}/archives"
    local dir="${root}/site/test"
    mkdir -p "${dir}"
    local ts
    for ts in 20260809-010101 20260810-010101 20260811-010101; do
        printf 'archive' >"${dir}/${ts}.tar.gz"
        printf '%s  %s\n' "${SUM}" "${ts}.tar.gz" >"${dir}/${ts}.tar.gz.sha256"
    done
    backup_run "
        OS_ARCHIVE_DIR='${root}'
        prune_local site test 1
        printf 'CHANGE=%s\n' \"\${OS_ERR__CHANGES[*]-}\"
        printf 'LEFT=%s\n' \"\$(ls '${dir}' | tr '\n' ' ')\"
    "
    [ "${status}" -eq 0 ]
    # 留最新的那一份，另外两份连同校验和一起走
    [[ "${output}" == *'LEFT=20260811-010101.tar.gz 20260811-010101.tar.gz.sha256 '* ]]
    # 报给用户的份数必须是真删掉的份数
    [[ "${output}" == *'CHANGE=删除了 2 份 site:test 的旧本地备份'* ]]
}

@test "清理旧本地备份：份数没超过保留数就一份都不删" {
    local root="${BATS_TEST_TMPDIR}/archives"
    local dir="${root}/site/test"
    mkdir -p "${dir}"
    printf 'archive' >"${dir}/20260811-010101.tar.gz"
    backup_run "
        OS_ARCHIVE_DIR='${root}'
        prune_local site test 3
        printf 'CHANGE=[%s]\n' \"\${OS_ERR__CHANGES[*]-}\"
    "
    [ "${status}" -eq 0 ]
    [[ "${output}" == *'CHANGE=[]'* ]]
    [ -f "${dir}/20260811-010101.tar.gz" ]
}

@test "多个变量的 read 必须自带 IFS= 前缀" {
    # 文件级 IFS 是 $'\n\t'：不带前缀的 `read -r a b` 在空格分隔的输入上
    # 不会拆列，而是把整行塞进第一个变量 —— 不报错，只是值错，
    # 上面第一条用例里那个「两个哈希看着一样却判不一致」就是这么来的
    run grep -nE 'read[[:space:]]+-r[[:space:]]+[A-Za-z_][A-Za-z_0-9]*[[:space:]]+[A-Za-z_]' "${BACKUP}"
    local line
    while IFS= read -r line; do
        [ -n "${line}" ] || continue
        [[ "${line}" == *'IFS='* ]] || {
            printf '%s\n' "${BACKUP}:${line} 缺 IFS= 前缀" >&2
            return 1
        }
    done <<<"${output}"
}
