#!/usr/bin/env bash
#
# OneServer 静态检查（F0.4）
#
# 二十项：
#   1. shellcheck 零告警
#   2. shfmt 格式一致（规则见 .editorconfig，shfmt 原生读取它）
#   3. `# shellcheck disable=` 审计 —— 每条必须带理由，总数不得超过阈值
#      （零告警不能靠满屏 disable 伪造）
#   4. 前端零副作用
#   5. 可执行位与 git 索引一致：该可执行的是 100755，不该的是 100644
#   6. `os::run` 等的 desc 是固定字符串，不含变量展开
#   7. 更新切换器自包含
#   8. 脚本层只调允许的前缀，不碰私有函数
#   9. docs/API.md 与 lib/ 一致，且没有接口缺签名行
#  10. 变更流水注释不超阈值（棘轮，只降不升）
#  11. 新增或删除公开接口时 lib/API_VERSION 必须跟着动
#  12. 规范的目录与实际小节一致
#  13. 二级菜单与 dispatch 分支一一对应（双向）
#  14. @privilege root-nolock 的脚本零系统副作用
#  15. 运行时路径不得硬编码，只出自 lib/paths.sh
#  16. `eval` 全项目零使用
#  17. lib 分层与装配：L0 只有赋值、模块之间不 source、不依赖 jq/python/perl
#  18. 命令脚本的文件头四件套齐全
#  19. 脚本元数据静态可判定的部分自洽
#  20. 公开接口的测试覆盖不倒退（棘轮，只降不升）
#
# 检查范围 = git 跟踪的全部 shell 脚本，无豁免。
#
# 用法：bash tests/lint.sh

set -Eeuo pipefail
IFS=$'\n\t'

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_ROOT
readonly MAX_DISABLES=19

# 变更流水注释的棘轮上限。**只降不升**：清理一批就把这个数往下调，
# 它记录的是「还欠多少」，不是「允许多少」。
readonly MAX_CHANGELOG_COMMENTS=0

# 没有任何 bats 用例提到的公开接口条数。同样是棘轮，含义同上 ——
# 「改 lib/ 必须补 bats 测试」这条规则在此之前没有执行者，欠账一度到 26。
# 现在是 0：新增接口不带用例当场红。
readonly MAX_UNCOVERED_API=0

# CI 钉死的 shellcheck 版本，**这里是唯一来源**（.github/workflows/lint.yml
# 从本文件读它）。不同版本对同一份代码的判断不同（0.9 报 SC2015，0.11 不报），
# 版本一漂，「本地绿」就不再等价于「CI 绿」。
readonly EXPECT_SHELLCHECK_VERSION='0.11.0'

# 运行时路径的字面量。单一来源是 lib/paths.sh（规范 §4.2），
# 出现在别处就意味着「改一个目录要改两个地方」，而第二处不会有人记得改。
readonly RUNTIME_PATHS='/opt/oneserver|/etc/oneserver|/var/log/oneserver|/var/backups/oneserver|/run/oneserver|/var/tmp/oneserver'

cd "${REPO_ROOT}"

fail_count=0

die() {
    printf 'lint: 错误: %s\n' "$*" >&2
    exit 1
}

section() {
    printf '\n=== %s ===\n' "$*"
}

report_fail() {
    printf 'lint: 不通过: %s\n' "$*" >&2
    fail_count=$((fail_count + 1))
}

require() {
    command -v "${1}" >/dev/null 2>&1 || die "缺少 ${1}。Debian/Ubuntu: apt-get install -y ${1}"
}

# --- 收集在检范围 ---

# CI 与开发机上用 git ls-files（自动尊重 .gitignore）；
# 测试机上跑的是 tar 同步过去的副本，没有 .git 也没装 git，退回 find。
list_candidates() {
    if command -v git >/dev/null 2>&1 && git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        git ls-files -- '*.sh' 'bin/*'
        return
    fi
    find . -type d -name .git -prune -o \
        -type f \( -name '*.sh' -o -path './bin/*' \) -print \
        | sed 's|^\./||' | sort
}

declare -a files=()
while IFS= read -r f; do
    files+=("${f}")
done < <(list_candidates)

section "在检范围"
if [[ ${#files[@]} -eq 0 ]]; then
    printf '\nlint: 在检范围为空，无事可做\n'
    exit 0
fi
printf '在检 %d 个文件\n' "${#files[@]}"

# --- 1. shellcheck ---

section "shellcheck"
require shellcheck
# 版本不符只提示不失败：装得到哪个版本由发行版仓库决定，不由改代码的人决定。
# 但它必须被说出来 —— 否则本地一片绿、CI 一片红，而没人知道差别在哪
sc_ver=$(shellcheck --version | sed -n 's/^version: //p')
[[ ${sc_ver} == "${EXPECT_SHELLCHECK_VERSION}" ]] \
    || printf '注意：本机 shellcheck %s，CI 用的是 %s —— 本地通过不代表 CI 通过\n' \
        "${sc_ver:-未知}" "${EXPECT_SHELLCHECK_VERSION}"
if shellcheck "${files[@]}"; then
    printf '零告警\n'
else
    report_fail "shellcheck 有告警"
fi

# --- 2. shfmt ---

# 不传任何格式化开关：shfmt 一旦收到开关就整个忽略 .editorconfig，
# 于是规则会有两个来源。裸调它，.editorconfig 就是唯一真相源。
section "shfmt"
require shfmt
if shfmt -d "${files[@]}"; then
    printf '格式一致\n'
else
    report_fail "shfmt 有差异，跑 make fmt 修正"
fi

# --- 3. disable 审计 ---

section "shellcheck disable 审计"
disable_total=0
for f in "${files[@]}"; do
    while IFS= read -r hit; do
        [[ -n "${hit}" ]] || continue
        disable_total=$((disable_total + 1))
        # 期望形如：# shellcheck disable=SC2029  # 理由：……
        [[ "${hit}" == *"理由"* ]] \
            || report_fail "${f}:${hit%%:*} 的 disable 没写理由"
        # 正则只认「独占一行的注释指令」——这既是 shellcheck 唯一认的写法，
        # 也让本脚本自己的这行 grep 与上下文注释不会被算成一条 disable。
    done < <(grep -nE '^[[:space:]]*#[[:space:]]*shellcheck[[:space:]]+disable=' "${f}" || true)
done

printf 'disable 共 %d 条（阈值 %d）\n' "${disable_total}" "${MAX_DISABLES}"
[[ "${disable_total}" -le "${MAX_DISABLES}" ]] \
    || report_fail "disable 超过阈值 ${MAX_DISABLES}，需要人工说明而不是继续加"

# --- 4. 前端零副作用---

section "前端约束"
declare -a frontends=()
for f in "${files[@]}"; do
    [[ "${f}" == bin/* ]] && frontends+=("${f}")
done
if [[ ${#frontends[@]} -eq 0 ]]; then
    printf '没有前端文件\n'
else
    for f in "${frontends[@]}"; do
        while IFS= read -r hit; do
            [[ -n "${hit}" ]] || continue
            report_fail "${f}:${hit%%:*} 前端只做路由/渲染/探测，不得有副作用：${hit#*:}"
        done < <(grep -nE '(^|[^[:alnum:]_:])os::(run|run_out|state_set|state_del|state_unit_add|secure_set|secure_del|systemd_)' "${f}" || true)
    done
    printf '检查了 %d 个前端文件\n' "${#frontends[@]}"
fi

# --- 5. 可执行位---
#
# bin/ 的前端与带 @command 的脚本都要被 exec 直接派发。漏了执行位的
# 表现是「这条命令莫名其妙不存在」，而它是提交时就能查出来的事。
#
# 反向同样要查：清单的权限取自 git 索引（packaging/make-manifest.sh），
# 被误设成 100755 的 lib 文件会把那个多余的执行位一路带到用户机器上。
# 唯一该可执行的非命令文件是切换器 —— update.sh 明确要求它 `-x`。
#
# 认 git 索引里的模式而不是工作区的：Windows 上的文件系统没有执行位这回事，
# 只看 `-x` 的话本地永远通过、CI 永远失败。

section "可执行位"
has_git=0
if command -v git >/dev/null 2>&1 && git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    has_git=1
fi

exec_checked=0
for f in "${files[@]}"; do
    need=-1
    case "${f}" in
        bin/*) need=1 ;;
        # script/ 下没有被 source 的文件 —— 每一个都由 exec 或 systemd 直接跑。
        # 只查带 @command 的那些会漏掉内部步骤脚本，而漏了执行位的表现是
        # 「Failed at step EXEC … Permission denied」，采集器每轮都挂。
        script/*) need=1 ;;
        lib/* | templates/*) need=0 ;;
        packaging/*) grep -q '^# os-contract: updater' "${f}" && need=1 || need=0 ;;
    esac
    [[ "${need}" -ge 0 ]] || continue
    exec_checked=$((exec_checked + 1))
    if [[ "${has_git}" -eq 1 ]]; then
        mode="$(git ls-files -s -- "${f}" | cut -d' ' -f1)"
        if [[ "${need}" -eq 1 ]]; then
            [[ "${mode}" == "100755" ]] \
                || report_fail "${f} 在 git 索引里的模式是 ${mode:-未跟踪}，应为 100755（git update-index --chmod=+x ${f}）"
        else
            [[ "${mode}" == "100644" ]] \
                || report_fail "${f} 在 git 索引里的模式是 ${mode:-未跟踪}，它不该可执行，应为 100644（git update-index --chmod=-x ${f}）"
        fi
    elif [[ "${need}" -eq 1 ]]; then
        [[ -x "${f}" ]] || report_fail "${f} 没有执行位"
    fi
done
printf '检查了 %d 个文件的执行位\n' "${exec_checked}"

# --- 6. desc 不含变量展开---
#
# 规范：**禁止把凭据写进 `<desc>`**，判据是「desc 参数禁止包含任何变量展开」——
# 比「检查变量名像不像凭据」严格，也才是可判定的（D47 要的就是这种检查）。
#
# **只查 script/** 与 bin/**。** `lib/**` 不在规范的管辖内 ——规范明写
# 「本节是唯一约束 lib/** 的条款」。框架自己拼的 desc（`os::systemd_restart`
# 的「重启 <unit>」）里放的是 unit 名与文件名，且脚本传进来的值本就要过
# log::redact；把这条施加到 lib 上只会让日志变成「重启服务」这种查不出所以然的话。
#
# 判定方式：从函数名之后逐个词扫，跳过带值的选项（--env / --secret-val /
# --stdin-secret / --timeout）与不带值的 --allow-fail，遇到的第一个词就是 desc。
# 遇到 `--` 说明这一行根本没给 desc（多行写法里 desc 在上一行），跳过。
#
# 是启发式：desc 由变量拼成再传进来（`ufw_apply "$label" ...` 那种）它看不见。
# 但**直接写在调用点上的**那种——也就是实际会发生的那种——它抓得住。

section "desc 固定字符串"
desc_checked=0
for f in "${files[@]}"; do
    case "${f}" in
        script/* | bin/* | templates/script.skeleton.sh) ;;
        *) continue ;;
    esac
    desc_checked=$((desc_checked + 1))
    while IFS= read -r hit; do
        [[ -n "${hit}" ]] || continue
        lineno="${hit%%:*}"
        text="${hit#*:}"
        text="${text%\\}"
        # 只取函数名之后的部分
        rest="${text#*os::}"
        rest="${rest#run_out}"
        rest="${rest#run}"
        rest="${rest#retry}"
        rest="${rest#sql_exec}"
        rest="${rest#sql_query}"
        IFS=' ' read -r -a words <<<"${rest}"

        desc=""
        i=0
        n=${#words[@]}
        while [[ "${i}" -lt "${n}" ]]; do
            w="${words[i]}"
            case "${w}" in
                '')
                    i=$((i + 1))
                    continue
                    ;;
                --env | --secret-val | --stdin-secret | --timeout)
                    i=$((i + 2)) # 跳过选项连同它的值
                    continue
                    ;;
                --allow-fail)
                    i=$((i + 1))
                    continue
                    ;;
                --) break ;; # 这一行没给 desc（多行写法里它在上一行）
            esac
            if [[ "${w}" =~ ^[0-9]+$ ]]; then
                i=$((i + 1)) # os::retry 打头的次数不是 desc
                continue
            fi
            # 把被空格拆开的引号串拼回去：desc 多半是 '重启 xxx' 这种带空格的，
            # 逐词看只会看到开头那半截，恰好漏掉后半截里的变量
            desc="${w}"
            quote=""
            case "${w}" in
                \"*) quote='"' ;;
                \'*) quote="'" ;;
            esac
            if [[ -n "${quote}" ]]; then
                while [[ ! ("${#desc}" -gt 1 && "${desc: -1}" == "${quote}") && $((i + 1)) -lt "${n}" ]]; do
                    i=$((i + 1))
                    desc="${desc} ${words[i]}"
                done
            fi
            break
        done

        [[ -n "${desc}" && "${desc}" == *'$'* ]] \
            && report_fail "${f}:${lineno} desc 含变量展开，必须是固定字符串：${desc}"
    done < <(grep -nE '(^|[^[:alnum:]_:])os::(run|run_out|retry|sql_exec|sql_query)[[:space:]]' "${f}" | grep -vE '^[0-9]+:[[:space:]]*#' || true)
done
printf '检查了 %d 个脚本与前端文件\n' "${desc_checked}"

# --- 7. 切换器必须自包含---
#
# 切换器是全项目唯一允许违反规范的代码，代价是它必须**完全**自包含：
# 不 source 任何 lib、不调 os::* / ui::* / log::* / probe::*、不用 eval。
#
# 为什么要机器来查：它替换的正是自己脚下的那棵树，一旦引用了 lib 里的东西，
# 就会在「旧函数 + 新布局」这个未定义的组合里跑 —— 而这类问题**不会在
# 正常更新里暴露**，只在新旧接口恰好不兼容的那一次暴露，也就是最不该出问题的
# 那一次。靠人记着这条规则是不够的。
#
# 认的是文件里的 `# os-contract: updater` 标记，不是路径：将来切换器换个位置，
# 这条检查跟着它走。

section "切换器自包含"
updater_checked=0
for f in "${files[@]}"; do
    grep -q '^# os-contract: updater' "${f}" 2>/dev/null || continue
    updater_checked=$((updater_checked + 1))
    # **先编号再滤注释**，不能反过来：`grep -vn | grep -n` 会重新编号，
    # 报出来的行号指向的是「去掉注释之后的第几行」——而人是拿着这个数字
    # 去翻文件的（同 desc 那项的写法）
    while IFS= read -r hit; do
        [[ -n "${hit}" ]] || continue
        report_fail "${f}:${hit%%:*} 切换器里不允许出现这一行（规范自包含）：$(printf '%s' "${hit#*:}" | head -c 60)"
    done < <(grep -nE '(^|[^[:alnum:]_])(source|\.)[[:space:]]+[^ ]|os::|ui::|log::|probe::|(^|[^_[:alnum:]])eval[[:space:]]' "${f}" \
        | grep -vE '^[0-9]+:[[:space:]]*#' \
        || true)
done
if [[ "${updater_checked}" -eq 0 ]]; then
    report_fail "没找到带 '# os-contract: updater' 标记的切换器 —— 它是规范的硬要求"
else
    printf '检查了 %d 个切换器\n' "${updater_checked}"
fi

# --- 8. 脚本层只能调 os:: 与 probe:: ---
#
# 分层规则靠人自觉是守不住的：doctor.sh 已经调到了 registry::_meta ——
# 一个只该被前端加载的模块里的私有函数，而在这条检查存在之前，
# 没有任何机制会发现它。
#
# 白名单而不是黑名单：新增一个 lib 模块时，黑名单需要有人记得同步，
# 白名单默认拒绝，忘了改的后果是「新接口用不了」而不是「越层没人管」。

section "脚本层调用前缀"
prefix_checked=0
for f in "${files[@]}"; do
    case "${f}" in
        script/* | bin/*) ;;
        *) continue ;;
    esac
    prefix_checked=$((prefix_checked + 1))
    # 前端是框架的一部分而非消费者，白名单更宽：registry:: 由它显式 source，
    # log:: 用来记录路由决策 —— 那是框架事件，不是给用户看的消息
    allow='os|probe'
    [[ "${f}" == bin/* ]] && allow='os|probe|registry|log'
    # **先按整行取号再滤注释，最后才抠出违规的那个词**。用 `grep -o` 直接取词
    # 会丢掉行内容，注释就再也滤不掉 —— doctor.sh 里一句「与 registry::_meta
    # 同一套解析」的注释因此被报成越层调用。这条检查同样只看整行是不是注释，
    # 行尾注释里的调用抓不到，与第 6 项一样属启发式。
    while IFS= read -r hit; do
        [[ -n "${hit}" ]] || continue
        lineno=${hit%%:*}
        body=${hit#*:}
        call=$(printf '%s' "${body}" | grep -oE "\b[a-z_]+::[a-z_0-9]+" | head -1)
        # 私有优先报：`::_` 开头或名字里带 `__`，跨模块一律禁止
        if [[ "${call}" == *::_* || "${call}" == *__* ]]; then
            report_fail "${f}:${lineno} 不得调用框架私有函数：${call}"
        else
            report_fail "${f}:${lineno} 脚本层不得调用该接口：${call}"
        fi
    done < <(grep -nE "\b[a-z_]+::[a-z_0-9]+" "${f}" \
        | grep -vE '^[0-9]+:[[:space:]]*#' \
        | grep -E ":.*\b[a-z_]+::" \
        | grep -vE ":[^:]*\b(${allow})::[a-z_0-9]+" \
        || true)
    # 允许前缀里的私有函数（如 probe::_probe）单独再扫一遍
    while IFS= read -r hit; do
        [[ -n "${hit}" ]] || continue
        lineno=${hit%%:*}
        call=$(printf '%s' "${hit#*:}" | grep -oE "\b(${allow})::_[a-z_0-9]*|\b(${allow})::[a-z_0-9]*__[a-z_0-9]*" | head -1)
        [[ -n "${call}" ]] || continue
        report_fail "${f}:${lineno} 不得调用框架私有函数：${call}"
    done < <(grep -nE "\b(${allow})::_[a-z_0-9]*|\b(${allow})::[a-z_0-9]*__[a-z_0-9]*" "${f}" \
        | grep -vE '^[0-9]+:[[:space:]]*#' \
        || true)
done
printf '检查了 %d 个脚本与前端文件\n' "${prefix_checked}"

# --- 9. docs/API.md 与 lib/ 一致 ---
#
# 接口参考是生成的，这条检查是它「不可能过期」的全部依据：
# 少了它，生成器就只是一次性工具，文件照样会在下一次加函数时开始说谎。

# 生成到临时文件再比对，**绝不覆盖工作区里的那份**：检查跑到一半被 Ctrl-C
# 时，「先覆盖真文件、比完再拷回来」会把 docs/API.md 留在覆盖后的状态，
# 而备份还在 mktemp 里。检查工具不该有把工作区改坏的可能。
section "接口参考"
if [[ ! -f "${REPO_ROOT}/docs/API.md" ]]; then
    report_fail "docs/API.md 不存在，跑 make api 生成"
else
    api_tmp=$(mktemp)
    if bash "${REPO_ROOT}/packaging/make-api.sh" "${api_tmp}" >/dev/null 2>&1; then
        if diff -q "${api_tmp}" "${REPO_ROOT}/docs/API.md" >/dev/null 2>&1; then
            printf '与 lib/ 一致\n'
        else
            report_fail "docs/API.md 已过期，跑 make api 重新生成"
        fi
    else
        report_fail "make-api.sh 执行失败"
    fi
    rm -f "${api_tmp}"
fi
if grep -q '缺签名行' "${REPO_ROOT}/docs/API.md" 2>/dev/null; then
    report_fail "有公开接口缺签名行（函数头首行须为 '# <函数名> <参数>   <说明>'）"
fi

# --- 10. 变更流水注释棘轮 ---
#
# 「X 是某年某月某日移植 Y 时补的」这类注释解释的是一个已经不存在的代码库，
# 而历史由 git 保存。规范早就禁止写变更流水，但没有执行者，于是它一直在长。
#
# 做成棘轮而不是硬禁：存量里有「实测（某日）：某个上游 URL 返回 404」这种
# 给经验结论标注时间的写法，值不值得留要一条条看。棘轮不判断对错，只保证
# 总量单调下降 —— 新代码想加这类注释直接失败，清理一批就把阈值往下调。
#
# 认日期而不是认「移植 / 补的」这类词：日期是可精确判定的，词是启发式的。

section "变更流水注释"
changelog_total=0
while IFS= read -r hit; do
    [[ -n "${hit}" ]] || continue
    changelog_total=$((changelog_total + 1))
done < <(grep -rnE '^[[:space:]]*#.*20[0-9]{2}-[0-9]{2}-[0-9]{2}' "${files[@]}" 2>/dev/null || true)
printf '共 %d 条（阈值 %d）\n' "${changelog_total}" "${MAX_CHANGELOG_COMMENTS}"
[[ "${changelog_total}" -le "${MAX_CHANGELOG_COMMENTS}" ]] \
    || report_fail "变更流水注释超过阈值 ${MAX_CHANGELOG_COMMENTS} —— 历史归 git，不要写进注释"

# --- 11. 接口变了就得动 lib/API_VERSION ---
#
# 脚本用 `@requires_lib >= X.Y` 声明自己要的最低框架版本，框架在动手之前比对。
# 但「加了函数忘了升版」没有任何东西拦得住 —— 规范写着规则，执行者不存在，
# 于是它会烂。后果不是立刻可见的：某台机器上框架还是旧的，脚本一路跑到
# 调用新函数那一行才炸，而那时包可能已经装了、配置可能已经改了。
#
# docs/API.md 是从 lib/ 生成且已入库的，所以「接口有没有变」看它的 diff 就够，
# 不必在这里重新解析一遍 lib/。
#
# 盖不住的：改签名、改返回语义这类**语义**变化 —— 函数名没动，diff 看不出来。
# 那部分仍然只能靠 review。这条只保证最常犯的那种（新增/删除）不会漏。

section "lib API 版本"
if ! command -v git >/dev/null 2>&1 || ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    printf '跳过（不在 git 工作区）\n'
elif ! git cat-file -e HEAD:docs/API.md 2>/dev/null; then
    printf '跳过（上一个提交里还没有 docs/API.md）\n'
else
    api_ver_now=$(cat "${REPO_ROOT}/lib/API_VERSION" 2>/dev/null || printf '')
    api_ver_head=$(git show HEAD:lib/API_VERSION 2>/dev/null || printf '')
    fn_now=$(grep -oE '^- .(os|probe)::[a-z_0-9]+' "${REPO_ROOT}/docs/API.md" 2>/dev/null | sed 's/^- .//' | sort)
    fn_head=$(git show HEAD:docs/API.md 2>/dev/null | grep -oE '^- .(os|probe)::[a-z_0-9]+' | sed 's/^- .//' | sort)

    added=$(comm -13 <(printf '%s\n' "${fn_head}") <(printf '%s\n' "${fn_now}") | tr -d ' ')
    removed=$(comm -23 <(printf '%s\n' "${fn_head}") <(printf '%s\n' "${fn_now}") | tr -d ' ')

    if [[ -z "${api_ver_now}" ]]; then
        report_fail "lib/API_VERSION 读不到"
    elif [[ -n "${added}" && "${api_ver_now}" == "${api_ver_head}" ]]; then
        report_fail "新增了公开接口但 lib/API_VERSION 仍是 ${api_ver_now}，次版本要 +1：$(printf '%s' "${added}" | tr '\n' ' ')"
    elif [[ -n "${removed}" && "${api_ver_now%%.*}" == "${api_ver_head%%.*}" ]]; then
        report_fail "删除了公开接口但 lib/API_VERSION 主版本仍是 ${api_ver_now%%.*}，主版本要 +1：$(printf '%s' "${removed}" | tr '\n' ' ')"
    elif [[ -n "${added}" || -n "${removed}" ]]; then
        printf '接口有变动，版本已从 %s 提到 %s\n' "${api_ver_head}" "${api_ver_now}"
    else
        printf '接口无变动（%s）\n' "${api_ver_now}"
    fi
fi

# --- 12. 规范目录与实际小节一致 ---
#
# 目录是章节列表的第二份拷贝，加一节忘了改它就开始说谎 —— 而它现在是
# CLAUDE.md 让人「照目录检索」的依据，说谎的后果是有人以为某节不存在。
# 有了这条检查，第二份拷贝才允许存在。

section "规范目录"
spec="${REPO_ROOT}/docs/TECHNICAL_SPEC.md"
if [[ ! -f "${spec}" ]]; then
    printf '跳过（docs/TECHNICAL_SPEC.md 不在，可能被 .gitignore 排除）\n'
else
    # 目录行形如 `| [7](#7--组件标识) | … |`，取出编号
    toc_nums=$(grep -oE '^\| \[[0-9]+\]' "${spec}" | grep -oE '[0-9]+' | sort -n | tr '\n' ' ')
    head_nums=$(grep -oE '^## [0-9]+ ' "${spec}" | grep -oE '[0-9]+' | sort -n | tr '\n' ' ')
    if [[ "${toc_nums}" == "${head_nums}" ]]; then
        printf '目录与小节一致（%d 节）\n' "$(printf '%s' "${head_nums}" | wc -w)"
    else
        report_fail "规范目录与实际小节对不上：目录 [${toc_nums%% }] 实际 [${head_nums%% }]"
    fi
fi

# --- 13. 二级菜单与 dispatch 双向对应 ---
#
# 菜单项与 dispatch 是同一份清单的两处拷贝，靠字符串对上。改动作名时只改了
# 一处，菜单照样列出来，选中才报「未知操作」—— 而这条路径没有任何自动检查
# 走得到：shellcheck 看不出，bats 不进交互菜单，lint 其余各项也管不着。
# 真实踩过：`forward` 改名成 `network`，dispatch 改了菜单没改。
#
# **两个方向都查**：反向漏掉的那种（dispatch 有分支、菜单没列）不会报错，
# 它的表现是一条只有读过源码的人才知道存在的命令 —— CLI 敲得中、菜单里
# 永远看不见。要么补进菜单，要么删掉，不该以「没人知道」的状态留着。
#
# 菜单语句按**续行符**收集，不按空行断句：`sed '/os::action_menu/,/^$/p'`
# 在菜单项之间出现一个空行时会把后面的项全部漏掉，而且是静默漏掉。

section "菜单与 dispatch"

# 收集从 os::action_menu 起、直到不以 `\` 结尾的那一行为止的完整语句
menu_stmt() {
    local file=${1} line collecting=0
    while IFS= read -r line; do
        if [[ ${collecting} -eq 0 ]]; then
            [[ ${line} == *'os::action_menu'* ]] || continue
            collecting=1
        fi
        printf '%s\n' "${line}"
        [[ ${line} == *\\ ]] || collecting=0
    done <"${file}"
}

menu_checked=0
for f in "${files[@]}"; do
    # 两个都要有才是「带二级菜单的脚本」。只看 os::action_menu 的话，
    # 本文件自己的注释里提到它就会被算进来，然后拿注释里的示例当菜单项报错
    grep -q 'os::action_menu' "${f}" 2>/dev/null || continue
    grep -q '^dispatch()' "${f}" 2>/dev/null || continue
    menu_checked=$((menu_checked + 1))
    # 菜单项形如 'run=立即备份'，取 `=` 左边的动作名。`--overview action_ls`
    # 也是一个可从 CLI 调用、但交互时已经直接展示的 dispatch 动作；把函数名的
    # action_/do_ 前缀去掉后合进菜单集合，才能同时守住「不能漏入口」与「总览
    # 不必占一个重复菜单项」。
    # `|| true`：grep 找不到就返回 1，而 `var=$(...)` 会把它变成整条脚本的
    # 退出状态 —— set -e 下这里会静默死掉，连「检查了几个」都印不出来
    menu_acts=$(menu_stmt "${f}" | grep -oE "'[a-z][a-z0-9-]*=" | tr -d "'=" || true)
    overview_fn=$(menu_stmt "${f}" | sed -nE 's/.*--overview[[:space:]]+([a-z_][a-z_0-9]*).*/\1/p' | head -n1)
    case "${overview_fn}" in
        action_*) menu_acts+=$'\n'"${overview_fn#action_}" ;;
        do_*) menu_acts+=$'\n'"${overview_fn#do_}" ;;
        '') ;;
        *) report_fail "${f}：--overview 函数 ${overview_fn} 必须以 action_ 或 do_ 开头，才能对应 dispatch 动作" ;;
    esac
    menu_acts=$(printf '%s\n' "${menu_acts}" | sed '/^$/d' | sort -u)
    # dispatch 的 case 分支形如 `run) …` 或 `a | b) …`
    disp_acts=$(sed -n '/^dispatch()/,/^}/p' "${f}" \
        | grep -oE '^[[:space:]]+[a-z][a-z0-9|* -]*\)' | tr -d ' )' \
        | tr '|' '\n' | sort -u || true)
    while IFS= read -r act; do
        [[ -n "${act}" ]] || continue
        printf '%s\n' "${disp_acts}" | grep -qx -- "${act}" \
            || report_fail "${f}：菜单项「${act}」在 dispatch 里没有对应分支"
    done <<<"${menu_acts}"
    while IFS= read -r act; do
        [[ -n "${act}" ]] || continue
        printf '%s\n' "${menu_acts}" | grep -qx -- "${act}" \
            || report_fail "${f}：dispatch 分支「${act}」不在菜单里，菜单用户看不到它"
    done <<<"${disp_acts}"
done
printf '检查了 %d 个带二级菜单的脚本\n' "${menu_checked}"

# --- 14. root-nolock 必须零系统副作用 ---
#
# 这一档是为「每十秒采一次的定时器」开的：它需要 root 才探得到 systemctl /
# ufw / sshd -T，但持全局锁会随机挡住用户敲的真实命令，所以放它不取锁。
# 代价是它与真实变更并发运行 —— 一旦有人往这类脚本里塞副作用，那个副作用
# 就是在**没有互斥**的情况下发生的，正是单一全局锁要防的事。
#
# 只允许 os::query 的只读查询与 probe::。os::run 与 os::run_out 都有副作用，
# 两个都要拦 —— `` 在 `run` 与 `_` 之间不成立，所以必须分别列出。
section "root-nolock 零副作用"
nolock_checked=0
for f in "${files[@]}"; do
    grep -qE '^#[[:space:]]*@privilege[[:space:]]+root-nolock' "${f}" 2>/dev/null || continue
    nolock_checked=$((nolock_checked + 1))
    while IFS= read -r hit; do
        [[ -n "${hit}" ]] || continue
        report_fail "${f}：@privilege root-nolock 不得调用 ${hit}"
    done < <(grep -oE '\bos::(run|run_out|state_set|state_del|state_resource_add|state_resource_del|state_unit_add|install_template|secure_set|secure_del|destroy_confirm)\b' "${f}" \
        | sort -u || true)
done
printf '检查了 %d 个 root-nolock 脚本\n' "${nolock_checked}"

# --- 15. 运行时路径不硬编码 ---
#
# 规范：路径的单一来源是 `lib/paths.sh`。第二处路径字面量不会跟着第一处改，
# 而它们分歧的那一刻不会有任何报错 —— 只是程序开始往一个没人维护的目录写东西。
# 真实存在过：`DB_BACKUP_DIR='/var/backups/oneserver/db'` 连同 `OS_BACKUP_DIR_MODE`
# 定义的 0700 一起绕过去了。
#
# **只查赋值右值与 `for … in` 列表**，不查命令参数位置。判据要可判定：路径
# 存进变量、或被循环遍历，就是拿它当路径用；而命令参数上的字面量多是给人看的
# 文本（`os::die '…模板留在 /etc/oneserver/templates/'`），desc 更是被第 6 项
# 强制成固定字符串、根本不许用变量。这样划分之后，`source /opt/oneserver/lib/
# bootstrap.sh` 这行规范逐字规定的引导语句自动落在范围之外，一条特例都不用写。
#
# lib/paths.sh 是来源，它自己当然要写字面量。

section "运行时路径"
hardpath_re="^[[:space:]]*(readonly[[:space:]]+|local[[:space:]]+|declare[[:space:]]+-[a-zA-Z]+[[:space:]]+)?[A-Za-z_][A-Za-z_0-9]*=[\"']?(${RUNTIME_PATHS})"
hardpath_re="${hardpath_re}|^[[:space:]]*for[[:space:]]+[A-Za-z_][A-Za-z_0-9]*[[:space:]]+in[[:space:]].*(${RUNTIME_PATHS})"
path_checked=0
for f in "${files[@]}"; do
    case "${f}" in
        lib/paths.sh) continue ;;
        script/* | bin/* | lib/*) ;;
        *) continue ;;
    esac
    path_checked=$((path_checked + 1))
    while IFS= read -r hit; do
        [[ -n "${hit}" ]] || continue
        report_fail "${f}:${hit%%:*} 硬编码了运行时路径，改用 lib/paths.sh 里的变量：$(printf '%s' "${hit#*:}" | head -c 60)"
    done < <(grep -nE "${hardpath_re}" "${f}" | grep -vE '^[0-9]+:[[:space:]]*#' || true)
done
printf '检查了 %d 个文件\n' "${path_checked}"

# --- 16. eval 全项目零使用 ---
#
# 规范对 `eval` 的措辞是「全项目当前零使用，不留例外；确需时先改本文件说明
# 理由」。第 7 项只在切换器里拦它，其余六十多个文件不在任何检查之内 ——
# 而「零使用」这个状态一旦破了一次，规范那句话就再也不是事实。
#
# 范围是**会落到用户机器上以 root 跑的代码**，不含 tests/：检查器自己必然
# 要写出它所检查的那个词（本节的 grep 模式就是），把它算成违规只能靠给
# 自己开特例，而特例一旦存在就会被下一个人用来豁免别的东西。

section "eval"
eval_hits=0
for f in "${files[@]}"; do
    case "${f}" in
        bin/* | lib/* | script/* | packaging/* | templates/* | install.sh) ;;
        *) continue ;;
    esac
    while IFS= read -r hit; do
        [[ -n "${hit}" ]] || continue
        eval_hits=$((eval_hits + 1))
        report_fail "${f}:${hit%%:*} 用了 eval —— 规范要求全项目零使用，确需时先改规范说明理由"
    done < <(grep -nE '(^|[^_[:alnum:]])eval[[:space:]]' "${f}" | grep -vE '^[0-9]+:[[:space:]]*#' || true)
done
printf '全项目 %d 处\n' "${eval_hits}"

# --- 17. lib 分层与装配 ---
#
# 三条规矩，坏掉的方式各不相同，但都不会当场报错：
#
#   * L0（paths/defaults/theme）只有变量赋值。它们在 bootstrap 最早期被 source，
#     那时日志与 trap 都还没起来 —— 在这里执行命令，失败了连一行记录都没有。
#   * lib 模块之间不互相 source（不变量 2）。装配只有一处，顺序才是显式的；
#     而 tests/helper/load.sh 正是照着 bootstrap 的顺序装的，模块一旦自己
#     source 别人，测试装配的就是一个现实中不存在的加载顺序。
#   * lib 不依赖 jq/python/perl。零运行时依赖是产品边界，不是偏好。

section "lib 分层"
layer_checked=0
for f in "${files[@]}"; do
    [[ "${f}" == lib/*.sh ]] || continue
    layer_checked=$((layer_checked + 1))

    case "${f}" in
        lib/paths.sh | lib/defaults.sh | lib/theme.sh)
            while IFS= read -r hit; do
                [[ -n "${hit}" ]] || continue
                report_fail "${f}:${hit%%:*} L0 只允许变量赋值，不得有函数、条件或命令调用：$(printf '%s' "${hit#*:}" | head -c 60)"
            done < <(grep -nE '^[[:space:]]*[a-z_]+\(\)|^[[:space:]]*(if|case|for|while)[[:space:]]|\$\(|`' "${f}" \
                | grep -vE '^[0-9]+:[[:space:]]*#' || true)
            ;;
    esac

    # bootstrap 是唯一的装配点，source 是它的职责
    if [[ "${f}" != lib/bootstrap.sh ]]; then
        while IFS= read -r hit; do
            [[ -n "${hit}" ]] || continue
            report_fail "${f}:${hit%%:*} lib 模块之间禁止互相 source，装配只在 bootstrap.sh 里做"
        done < <(grep -nE '^[[:space:]]*(source|\.)[[:space:]]+' "${f}" | grep -vE '^[0-9]+:[[:space:]]*#' || true)
    fi

    while IFS= read -r hit; do
        [[ -n "${hit}" ]] || continue
        report_fail "${f}:${hit%%:*} lib 不得依赖 jq/python/perl（零运行时依赖是产品边界）"
    done < <(grep -nE '(^|[^-_[:alnum:]])(jq|python3?|perl)([^-_[:alnum:]]|$)' "${f}" \
        | grep -vE '^[0-9]+:[[:space:]]*#' || true)
done
printf '检查了 %d 个 lib 模块\n' "${layer_checked}"

# --- 18. 命令脚本的文件头 ---
#
# 规范逐字规定：严格 Bash 设置、受限 PATH、`umask 027`，随后 source
# bootstrap.sh，全文件仅一次。少一样的后果都不在本地显形：
# 少 `umask 027` 时落地的文件对同机其他用户可读；少受限 PATH 时以 root
# 跑的是 PATH 上先找到的那个同名程序；source 两次会让 trap 与全局状态
# 重新初始化一遍，而第一次的记录就此丢失。

section "命令脚本文件头"
head_checked=0
for f in "${files[@]}"; do
    [[ "${f}" == script/* ]] || continue
    grep -qE '^#[[:space:]]*@command[[:space:]]' "${f}" || continue
    head_checked=$((head_checked + 1))
    grep -qx 'set -Eeuo pipefail' "${f}" || report_fail "${f} 缺 'set -Eeuo pipefail'"
    grep -qx "PATH='/usr/sbin:/usr/bin:/sbin:/bin'" "${f}" || report_fail "${f} 缺受限 PATH"
    grep -qx 'umask 027' "${f}" || report_fail "${f} 缺 'umask 027'"
    n_boot=$(grep -c '^source /opt/oneserver/lib/bootstrap\.sh$' "${f}" || true)
    [[ "${n_boot}" -eq 1 ]] \
        || report_fail "${f} source bootstrap.sh ${n_boot} 次，规范要求全文件恰好一次"
done
printf '检查了 %d 个命令脚本\n' "${head_checked}"

# --- 19. 元数据自洽 ---
#
# `doctor --selftest` 查的是**装到机器上的那一份**，消费者是切换器：它要在
# 回滚窗口还开着的时候判断「这一版能不能用」。这里查的是**提交进仓库的那一份**，
# 消费者是写代码的人。同一类判断放在两个时刻，因为两边都无法替代对方 ——
# 一个 @order 撞车如果要等到装上去才发现，那台机器上的菜单已经是坏的了。
#
# **@order 的唯一性是组内的，不是全局的。** 它只决定排序（菜单编号按屏重排
# 1..N，不上屏），组与组之间互不相干；要求全局唯一的代价是加一个脚本得先
# 全仓找一个没被占的号，还得落在正确的号段里 —— 那是把「排序」和「标识」
# 两件事塞进同一个整数造成的。
#
# 只查静态可判定的：编号与命令名撞车、@group 的取值不存在、@requires_lib
# 声明的框架版本比仓库里的还新（那条脚本装上去必然一跑就退出）、
# @provides_unit 少了 own:/ext: 前缀（卸载时决定删文件还是只停服务），以及
# @args 与所有交互调用的 --arg 名字集合不一致。最后一项必须双向检查：只比
# 数量会被复用名字、分支与循环蒙混，而漏声明会让帮助/补全与非交互契约分裂。

section "脚本元数据"
meta_checked=0
lib_api_version=$(tr -d ' \t\n\r' <"${REPO_ROOT}/lib/API_VERSION" 2>/dev/null || printf '')
[[ -n "${lib_api_version}" ]] || report_fail 'lib/API_VERSION 读不到'
declare -a meta_orders=() meta_commands=()
meta_group=''
for f in "${files[@]}"; do
    [[ "${f}" == script/* ]] || continue
    grep -qE '^#[[:space:]]*@command[[:space:]]' "${f}" || continue
    meta_checked=$((meta_checked + 1))

    # 元数据必须整段落在**前 40 行**内 —— registry::_meta 只读那么多（规范 §6）。
    # 下面各项检查读的是整份文件，所以写在 41 行之后的字段这里条条都过，装到机器上
    # 才发现少了半截：@command 掉出窗口是「这条命令莫名其妙不存在」，@order 掉出去
    # 是 doctor --selftest 报「@order 缺失」。头注释写长一点就会把它们挤出去，
    # 只有专门查一次行号才拦得住。
    # 只看**文件头那一段注释**（`set -Eeuo` 之前）：正文里解释某个字段的注释也以
    # `# @order …` 开头，连它一起数就会把 doctor.sh 这类脚本误报成元数据超窗
    meta_code=$(grep -nE '^set -Eeuo' "${f}" | head -n1 | cut -d: -f1)
    meta_last=$(head -n "$((${meta_code:-41} - 1))" "${f}" \
        | grep -nE '^#[[:space:]]*@[a-z_]+[[:space:]]' | tail -n1 | cut -d: -f1)
    if [[ -n "${meta_last}" ]] && ((meta_last > 40)); then
        report_fail "${f}：元数据写到了第 ${meta_last} 行，超出 registry 只读的前 40 行——把长说明挪到 source 之后"
    fi

    while IFS= read -r v; do
        [[ -n "${v}" ]] || continue
        meta_commands+=("${v}")
    done < <(sed -nE 's/^#[[:space:]]*@command[[:space:]]+(.+[^[:space:]])[[:space:]]*$/\1/p' "${f}")
    # @group 先读出来：@order 的唯一性是**组内**的，撞不撞车要连着组一起看
    meta_group=$(sed -nE 's/^#[[:space:]]*@group[[:space:]]+([a-z0-9-]+).*$/\1/p' "${f}" | head -n1)
    while IFS= read -r v; do
        [[ -n "${v}" ]] || continue
        meta_orders+=("${meta_group}/${v}")
    done < <(sed -nE 's/^#[[:space:]]*@order[[:space:]]+([0-9]+).*$/\1/p' "${f}")

    while IFS= read -r v; do
        [[ -n "${v}" ]] || continue
        # groups.conf 按 `|` 切字段，id 后面允许有对齐用的空格
        grep -qE "^${v}[[:space:]]*\|" "${REPO_ROOT}/templates/groups.conf" \
            || report_fail "${f} 的 @group「${v}」不在 templates/groups.conf 里"
    done < <(sed -nE 's/^#[[:space:]]*@group[[:space:]]+([a-z0-9-]+).*$/\1/p' "${f}")

    while IFS= read -r v; do
        [[ -n "${v}" ]] || continue
        case "${v}" in
            own:* | ext:*) ;;
            *) report_fail "${f} 的 @provides_unit「${v}」缺 own:/ext: 前缀（卸载时据此决定删文件还是只停服务）" ;;
        esac
    done < <(sed -nE 's/^#[[:space:]]*@provides_unit[[:space:]]+(.+[^[:space:]])[[:space:]]*$/\1/p' "${f}")

    while IFS= read -r v; do
        [[ -n "${v}" ]] || continue
        # 排序取最大值，若最大的不是仓库里这版就说明脚本要的比现有的新
        newest=$(printf '%s\n%s\n' "${v}" "${lib_api_version}" | sort -V | tail -1)
        [[ "${newest}" == "${lib_api_version}" ]] \
            || report_fail "${f} 要求 lib API >= ${v}，而 lib/API_VERSION 是 ${lib_api_version}"
    done < <(sed -nE 's/^#[[:space:]]*@requires_lib[[:space:]]+>=[[:space:]]*([0-9]+\.[0-9]+).*$/\1/p' "${f}")

    declared_args=$(sed -nE 's/^#[[:space:]]*@args[[:space:]]+(.+)$/\1/p' "${f}" \
        | grep -oE -- '--[a-z][a-z0-9-]*' | sed 's/^--//' | sort -u || true)
    interaction_args=$(grep -vE '^[[:space:]]*#' "${f}" \
        | grep -oE -- "--arg[[:space:]]+['\"]?[a-z][a-z0-9-]*" \
        | sed -E 's/^--arg[[:space:]]+//; s/["'\'']//g' | sort -u || true)
    while IFS= read -r v; do
        [[ -n ${v} ]] || continue
        printf '%s\n' "${interaction_args}" | grep -qx -- "${v}" \
            || report_fail "${f} 的 @args 声明了 --${v}，但没有同名交互调用"
    done <<<"${declared_args}"
    while IFS= read -r v; do
        [[ -n ${v} ]] || continue
        printf '%s\n' "${declared_args}" | grep -qx -- "${v}" \
            || report_fail "${f} 的交互调用使用 --arg ${v}，但 @args 没有声明 --${v}"
    done <<<"${interaction_args}"
done

# --- @description 要塞得进菜单的说明列 ---
#
# 它同时喂 `--help` 与菜单第二列。写成一整句的后果是菜单里每一条都以 `…` 收尾，
# 既没说清这条命令干什么，又把一屏搞得全是省略号 —— 说明列的意义当场归零。
#
# 阈值 48 从最窄的那一屏推出来：`安装与部署` 的标签列宽 20（`MariaDB（MySQL）安装`），
# 框宽 80 时说明列只剩 49 格。按**显示宽度**算，所以借 lib/ui.sh 的 ui::width——
# 一个中文字占两格，按字符数算会漏掉一半。
desc_max=48
while IFS= read -r f; do
    [[ "${f}" == script/* ]] || continue
    grep -qE '^#[[:space:]]*@command[[:space:]]' "${f}" || continue
    while IFS= read -r v; do
        [[ -n "${v}" ]] || continue
        w=$(
            # shellcheck source=/dev/null
            source "${REPO_ROOT}/lib/theme.sh"
            # shellcheck source=/dev/null
            source "${REPO_ROOT}/lib/ui.sh"
            ui::width "${v}"
        )
        ((w <= desc_max)) \
            || report_fail "${f} 的 @description 宽 ${w} 格，超过 ${desc_max}——菜单里会被截断成省略号"
    done < <(sed -nE 's/^#[[:space:]]*@description[[:space:]]+(.+[^[:space:]])[[:space:]]*$/\1/p' "${f}")
done < <(printf '%s\n' "${files[@]}")

if [[ ${#meta_orders[@]} -gt 0 ]]; then
    while IFS= read -r dup; do
        [[ -n "${dup}" ]] || continue
        report_fail "@order「${dup#*/}」在分组「${dup%%/*}」里被多个脚本用了，组内先后就成了扫描顺序决定的"
    done < <(printf '%s\n' "${meta_orders[@]}" | sort | uniq -d)
fi
if [[ ${#meta_commands[@]} -gt 0 ]]; then
    while IFS= read -r dup; do
        [[ -n "${dup}" ]] || continue
        report_fail "@command「${dup}」被多个脚本用了，路由会取到哪一个不确定"
    done < <(printf '%s\n' "${meta_commands[@]}" | sort | uniq -d)
fi
printf '检查了 %d 个脚本的元数据\n' "${meta_checked}"

# --- 20. 公开接口的测试覆盖棘轮 ---
#
# 规范写着「改动 lib/ 必须补对应 bats 测试」，而在这条检查之前它没有执行者，
# 于是欠账只增不减 —— 加上这条检查的那天，125 个公开接口里有 26 个在
# tests/lib/ 下连名字都搜不到，其中包括 os::flag（每个脚本解析参数的入口）
# 与 probe:: 全族（它们的输出直接进 public/ 快照和只读面板）。
#
# 阈值记的是「还欠多少」，不是「允许多少」。现在是 0。
#
# 判据是「函数名在 tests/ 下出现过」，不是「被真正断言过」。它拦得住
# 「加了接口没人碰」，拦不住「提到了但没验证」—— 后者只能靠 review，
# 而前者正是现在漏掉的那 26 个的形态。
#
# 函数清单取自 docs/API.md：第 9 项已经保证它与 lib/ 一致，再解析一遍 lib/
# 就是第二个解析器，两个解析器迟早对同一份代码给出不同答案。

section "接口测试覆盖"
if [[ ! -f "${REPO_ROOT}/docs/API.md" ]]; then
    printf '跳过（docs/API.md 不在）\n'
else
    uncovered=0
    api_total=0
    while IFS= read -r fn; do
        [[ -n "${fn}" ]] || continue
        api_total=$((api_total + 1))
        # 只搜 bats 用例目录：本文件的注释里就写着 os::query 这类名字，
        # 把 tests/ 整个搜一遍会让它们凭注释「被覆盖」
        grep -rqF -- "${fn}" "${REPO_ROOT}/tests/lib/" 2>/dev/null && continue
        uncovered=$((uncovered + 1))
        printf '  未覆盖：%s\n' "${fn}"
    done < <(grep -oE '^- .(os|probe)::[a-z_0-9]+' "${REPO_ROOT}/docs/API.md" | sed 's/^- .//')
    printf '%d 个公开接口，%d 个没有任何用例提到（阈值 %d）\n' \
        "${api_total}" "${uncovered}" "${MAX_UNCOVERED_API}"
    [[ "${uncovered}" -le "${MAX_UNCOVERED_API}" ]] \
        || report_fail "未覆盖接口超过阈值 ${MAX_UNCOVERED_API} —— 新增接口要带 bats 用例"
fi

# --- 结论 ---

section "结论"
if [[ "${fail_count}" -eq 0 ]]; then
    printf '全部通过\n'
    exit 0
fi
printf '%d 项不通过\n' "${fail_count}" >&2
exit 1
