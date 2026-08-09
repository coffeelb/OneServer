#!/usr/bin/env bats
#
# packaging/updater.sh 的行为测试
#
# 切换器是全项目唯一允许违反规范的代码，代价是它必须完全自包含 —— 而这也
# 意味着**它的正确性没有任何框架能兜底**：lint 只查它有没有引用 lib，
# 查不出它换错了目录、回滚漏了一个、或者顺手删掉了用户的凭据库。
#
# 它干的又恰恰是最不能出错的事：替换自己脚下那棵树，失败时把系统退回上一版。
# 而这条路径在真实更新里几乎不走 —— 自检通常是过的，回滚分支只在
# 「新版本恰好坏了」的那一次执行，也就是最不该再出第二个问题的时刻。
#
# 所以这里不测「更新能不能成」，测的是**坏掉的时候会怎样**：自检不过、
# 暂存区残缺、没有可回滚的上一版。假的 bin/oneserver 用退出码驱动这些分支。

setup() {
    load "${BATS_TEST_DIRNAME}/../helper/load.sh"
    UPDATER="${OS_TEST_REPO_ROOT}/packaging/updater.sh"
    ROOT="${BATS_TEST_TMPDIR}/opt"
    STAGING="${ROOT}/.staging"
}

# 切换覆盖的五个顶层目录，与切换器的 TOP_ORDER 一致
os_tops() { printf '%s\n' lib templates packaging script bin; }

# 造一棵「已装好的」树：五个目录各放一个标记文件，外加运行时数据。
# 运行时数据是重点 —— 它们与被替换的目录同在一个父目录下，
# 而切换器绝不该碰它们（state 是卸载依据，secure.conf 是这台机器的全部密码）
os_mk_root() {
    local top
    while read -r top; do
        mkdir -p "${ROOT}/${top}"
        printf 'old\n' >"${ROOT}/${top}/mark"
    done < <(os_tops)
    printf '1.0.0\n' >"${ROOT}/VERSION"
    mkdir -p "${ROOT}/state"
    printf 'caddy\tinstalled\n' >"${ROOT}/state/components.tsv"
    printf 'db.password=s3cret\n' >"${ROOT}/secure.conf"
}

# 造暂存区。$1 = 假 oneserver 自检的退出码；$2… = 要故意漏掉的顶层目录
os_mk_staging() {
    local rc=${1}
    shift || true
    local skip=" $* " top
    while read -r top; do
        [[ ${skip} == *" ${top} "* ]] && continue
        mkdir -p "${STAGING}/${top}"
        printf 'new\n' >"${STAGING}/${top}/mark"
    done < <(os_tops)
    printf '2.0.0\n' >"${STAGING}/VERSION"
    if [[ -d "${STAGING}/bin" ]]; then
        printf '#!/bin/bash\nexit %s\n' "${rc}" >"${STAGING}/bin/oneserver"
        chmod 0755 "${STAGING}/bin/oneserver"
    fi
}

os_marks_are() {
    local want=${1} top
    while read -r top; do
        [[ "$(cat "${ROOT}/${top}/mark")" == "${want}" ]] || return 1
    done < <(os_tops)
    return 0
}

# --- 切换成功 -----------------------------------------------------

@test "switch: 五个顶层目录全部换成新版，VERSION 跟着走" {
    os_mk_root
    os_mk_staging 0
    run bash "${UPDATER}" switch --root="${ROOT}" --staging="${STAGING}" --version=2.0.0
    [ "${status}" -eq 0 ]
    os_marks_are new
    [ "$(cat "${ROOT}/VERSION")" = '2.0.0' ]
}

@test "switch: 成功之后不留 .old、.staging 与进行中标记" {
    os_mk_root
    os_mk_staging 0
    run bash "${UPDATER}" switch --root="${ROOT}" --staging="${STAGING}"
    [ "${status}" -eq 0 ]
    [ ! -e "${ROOT}/.old" ]
    [ ! -e "${ROOT}/.staging" ]
    [ ! -e "${ROOT}/.update-in-progress" ]
}

@test "switch: 运行时数据一个字节都不动" {
    os_mk_root
    os_mk_staging 0
    run bash "${UPDATER}" switch --root="${ROOT}" --staging="${STAGING}"
    [ "${status}" -eq 0 ]
    [ "$(cat "${ROOT}/state/components.tsv")" = "$(printf 'caddy\tinstalled')" ]
    [ "$(cat "${ROOT}/secure.conf")" = 'db.password=s3cret' ]
}

# --- 自检不过就地回滚 ---------------------------------------------
#
# 规范承诺「自检失败就地回滚并以非零码退出」。这是整条更新链上唯一
# 「系统已经被改过了」的失败分支，它没走对的后果是机器停在半新半旧的状态。

@test "switch: 自检不过时全部退回上一版并以非零码退出" {
    os_mk_root
    os_mk_staging 1
    run bash "${UPDATER}" switch --root="${ROOT}" --staging="${STAGING}" --version=2.0.0
    [ "${status}" -ne 0 ]
    os_marks_are old
    [ "$(cat "${ROOT}/VERSION")" = '1.0.0' ]
}

@test "switch: 回滚之后同样不留 .old 与进行中标记" {
    os_mk_root
    os_mk_staging 1
    run bash "${UPDATER}" switch --root="${ROOT}" --staging="${STAGING}"
    [ "${status}" -ne 0 ]
    [ ! -e "${ROOT}/.old" ]
    [ ! -e "${ROOT}/.update-in-progress" ]
}

@test "switch: 回滚不碰运行时数据" {
    os_mk_root
    os_mk_staging 1
    run bash "${UPDATER}" switch --root="${ROOT}" --staging="${STAGING}"
    [ "${status}" -ne 0 ]
    [ "$(cat "${ROOT}/secure.conf")" = 'db.password=s3cret' ]
    [ -f "${ROOT}/state/components.tsv" ]
}

# --- 暂存区残缺：一步都不许迈 -------------------------------------

@test "switch: 暂存区缺一个顶层目录就什么都不换" {
    os_mk_root
    os_mk_staging 0 script
    run bash "${UPDATER}" switch --root="${ROOT}" --staging="${STAGING}"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *script* ]]
    os_marks_are old
    [ ! -e "${ROOT}/.old" ]
    [ ! -e "${ROOT}/.update-in-progress" ]
}

@test "switch: 暂存区缺 VERSION 同样拒绝动手" {
    os_mk_root
    os_mk_staging 0
    rm -f "${STAGING}/VERSION"
    run bash "${UPDATER}" switch --root="${ROOT}" --staging="${STAGING}"
    [ "${status}" -ne 0 ]
    os_marks_are old
}

@test "switch: 暂存区根本不在时以退出码 2 拒绝" {
    os_mk_root
    run bash "${UPDATER}" switch --root="${ROOT}" --staging="${ROOT}/nope"
    [ "${status}" -eq 2 ]
    os_marks_are old
}

# --- rollback 子命令 ----------------------------------------------

@test "rollback: 把 .old 里的上一版放回去" {
    os_mk_root
    os_mk_staging 0
    # 先切过去，再手工把上一版摆回 .old —— 切换成功后 .old 会被清掉，
    # 而 `oneserver update rollback` 面对的正是「上一次切换留下的 .old」
    run bash "${UPDATER}" switch --root="${ROOT}" --staging="${STAGING}"
    [ "${status}" -eq 0 ]
    local top
    mkdir -p "${ROOT}/.old"
    while read -r top; do
        mkdir -p "${ROOT}/.old/${top}"
        printf 'old\n' >"${ROOT}/.old/${top}/mark"
    done < <(os_tops)
    printf '1.0.0\n' >"${ROOT}/.old/VERSION"

    run bash "${UPDATER}" rollback --root="${ROOT}"
    [ "${status}" -eq 0 ]
    os_marks_are old
    [ "$(cat "${ROOT}/VERSION")" = '1.0.0' ]
    [ ! -e "${ROOT}/.old" ]
    [ ! -e "${ROOT}/.update-in-progress" ]
}

@test "rollback: 没有上一版时以退出码 2 拒绝，不动现有的树" {
    os_mk_root
    run bash "${UPDATER}" rollback --root="${ROOT}"
    [ "${status}" -eq 2 ]
    os_marks_are old
}

# --- 参数 ---------------------------------------------------------

@test "参数: 根目录不存在时以退出码 2 拒绝" {
    run bash "${UPDATER}" switch --root="${BATS_TEST_TMPDIR}/nowhere" --staging="${BATS_TEST_TMPDIR}/s"
    [ "${status}" -eq 2 ]
}

@test "参数: 不认识的参数以退出码 2 拒绝" {
    os_mk_root
    run bash "${UPDATER}" switch --root="${ROOT}" --wat=1
    [ "${status}" -eq 2 ]
}

@test "参数: 不认识的动作以退出码 2 拒绝并打出用法" {
    os_mk_root
    run bash "${UPDATER}" frobnicate --root="${ROOT}"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *用法* ]]
}
