#!/bin/bash
#
# 服务器安全设置：SSH 加固 · 系统更新 · 自动安全更新 · 网络定位
#
# 防火墙**整体归 `oneserver firewall`** —— 装卸、启停、规则全在那一个命令里。
# 这里只在体检中报告 UFW 状态（只读）。分成两处的后果试过了：同一件事有两个
# 入口，用户得先猜自己要的在哪一边，而「装 ufw」「启用防火墙」两边各有一份
# 实现，改一处就漂一处。
#
# @command      safe
# @name         安全设置
# @group        security
# @order        10
# @privilege    root
# @requires_lib >= 1.26
# @provides     auto-updates
# @provides_unit ext:ssh.service
# @provides_unit ext:ssh.socket
# @provides_unit ext:unattended-upgrades.service
# @provides_unit ext:docker.service
# @args         [--action=<status|ssh|updates|network>] [--add-pubkey=<y|n>] [--user=<用户名>] [--pubkey=<公钥内容>] [--pubkey-file=<路径>] [--port=<端口>] [--password-auth=<keep|no|yes>] [--permit-root-login=<keep|prohibit-password|no|yes>] [--upgrade=<y|n>] [--auto-security=<y|n>] [--network-mode=<公网|内网>] [--confirm-internal=<y|n>] [--restart-docker=<y|n>]
# @description  SSH 加固、系统更新与网络定位
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
# ## 一、它管什么，不管什么
#
# 旧 safe.sh 是「一路回车走完三件事」：apt upgrade → 改 SSH → 配 UFW。
# 三件事各自都有道理，但捆在一条直线上的后果是：想只改 SSH 端口的人
# 得先陪着跑一遍 apt upgrade。
#
# 所以这里是四个动作，各自可单独执行：
#
#   safe status    体检：把「现在到底安不安全」一屏说清，并给出下一条命令
#   safe ssh       SSH 加固：端口 · 公钥 · 关密码登录 · root 登录策略
#   safe updates   系统更新 + 打开自动安全更新
#   safe network   网络定位：公网 / 内网，决定容器端口绑哪个地址
#
# **防火墙一件都不管**，装卸启停与规则全归 `oneserver firewall`。
# 本脚本仍有两处碰 UFW，都不是防火墙管理：
#   1. SSH 加固时确认当前 SSH 端口在放行清单里 —— 不确认的话，这条命令跑完
#      紧接着就是断开重连，到那一刻才发现被自己的防火墙挡住就晚了
#   2. status 里报一句防火墙开没开，并把该敲的命令打出来
#
# ## 二、为什么整份配置写 sshd_config.d/00-oneserver.conf
#
# 旧脚本用 `sed -i.bak` 就地改 /etc/ssh/sshd_config，还会遍历
# sshd_config.d/*.conf 把别人的 `PasswordAuthentication` 一个个改掉 ——
# 那是别的包（cloud-init、systemd-userdb）或用户自己的文件，改它就是
# 「工具悄悄替你改了你不知道的配置」，而且下次那个包升级就还原了。
#
# 现在的做法是只写自己的一个片段文件，删掉它即回到发行版默认。
# **文件名以 00- 开头是有意的**（模板里也写了理由）：sshd 的取值规则是
# 「第一次出现的值生效」，片段按文件名字典序读入 —— Ubuntu 云镜像自带的
# 50-cloud-init.conf 里写着 `PasswordAuthentication yes`，用 99- 命名的
# 加固片段会被它整个盖掉，而表现是「工具说已关闭密码登录，实际还开着」。
#
# ## 三、为什么改完必须问 `sshd -T`，而不是相信自己写了什么
#
# 同上：真正生效的值取决于哪个文件先被读到。写完文件就宣布成功，
# 等于把「我打算做什么」当成「系统现在是什么」。所以每次改完都：
#
#   sshd -t     语法过不过（不过就整个回滚，服务一步都不动）
#   sshd -T     有效值是不是我要的（不是就报出哪个文件在抢，并回滚）
#   probe::port_listening   端口真的在听吗（不在就回滚 + 恢复原样重启）
#
# ## 四、socket 激活：Ubuntu 上改 Port 是不生效的
#
# 在两台真机上实测：
#   Ubuntu 24.04   ssh.socket enabled  · ssh.service disabled
#   Debian 13      ssh.socket disabled · ssh.service enabled
#
# socket 激活时监听由 systemd 完成，端口写在 ssh.socket 的 ListenStream，
# sshd 拿到的是一个已经连上的 fd —— sshd_config 里的 `Port` 完全不起作用。
# 旧脚本的处理是把 ssh.socket 停掉禁用，换回 ssh.service：那是把发行版的
# 默认形态改掉，用户下次 apt 升级 openssh 时两边打架。
# 这里改成**顺着发行版**：socket 激活的机器写一个 ssh.socket 的 drop-in
# 覆盖 ListenStream，非 socket 的机器就只改 sshd_config。两条路都验证监听。
#
# ## 五、卸载时**不**还原 SSH 配置（所以不登记 file 资源）
#
# 规范要求安装类把创建的文件登记进 state 供 uninstall 反向执行。
# 这里有意不登记 00-oneserver.conf 与 ssh.socket 的 drop-in：卸载一个管理工具
# 就把 SSH 端口还原成 22、把密码登录打开，是**在卸载动作里降低安全性**，
# 而且很可能直接把人锁在门外（防火墙只放行了新端口）。
# 规范的「永不自动删除」一栏里，用户配置本来就在其中。
# status 会明确打出这两个文件在哪，要还原的人删掉它们即可。
#
# unattended-upgrades 不同：那是本工具装的一个包 + 一个新建的配置文件，
# 卸载它不降低任何东西的可用性，所以照章登记进 `auto-updates` 组件。

readonly SSHD_CONFIG='/etc/ssh/sshd_config'
readonly SSHD_DROPIN_DIR='/etc/ssh/sshd_config.d'
readonly SSHD_DROPIN='/etc/ssh/sshd_config.d/00-oneserver.conf'
readonly SOCKET_DROPIN_DIR='/etc/systemd/system/ssh.socket.d'
readonly SOCKET_DROPIN='/etc/systemd/system/ssh.socket.d/00-oneserver-port.conf'
readonly AUTO_UPGRADES_CONF='/etc/apt/apt.conf.d/20auto-upgrades'
readonly UFW_DEFAULTS='/etc/default/ufw'
# ufw 的输出在不同 locale 下措辞不同，而「这条规则是本次新增的还是本来就有」
# 只能靠输出文本判定（退出码两种情况都是 0）。所有 ufw 调用统一注入它
readonly UFW_ENV='LC_ALL=C'
readonly DAEMON_JSON='/etc/docker/daemon.json'
# 网络定位落在 state 的这个组件下 —— 两个容器引擎都读它决定端口绑哪个地址
readonly NETWORK_ID='network'
readonly DOCKER_ID='docker'
readonly AUTO_UPDATES_ID='auto-updates'

# ------------------------------------------------------------------
# 辅助
# ------------------------------------------------------------------

# ssh 服务的 unit 名。Debian/Ubuntu 是 ssh.service，别的发行版叫 sshd.service，
# 而两边都装了 sshd.service 作为别名 —— 认得出哪个是真的才敢去 restart 它。
#
# **用变量返回，不 printf + $( )**（D135）：子 shell 会把 probe 的
# OS_PROBE_SOURCE / OS_PROBE_AGE 一起吞掉。
safe_ssh_unit() {
    local __safe_out=${1}
    probe::unit_exists 'ssh.service'
    if [[ ${OS_PROBE_VALUE} == yes ]]; then
        printf -v "${__safe_out}" '%s' 'ssh.service'
        return 0
    fi
    printf -v "${__safe_out}" '%s' 'sshd.service'
    return 0
}

# 这台机器是不是 socket 激活的 SSH
safe_socket_activated() {
    probe::unit_exists 'ssh.socket'
    [[ ${OS_PROBE_VALUE} == yes ]] || return 1
    probe::service_enabled 'ssh.socket'
    [[ ${OS_PROBE_VALUE} == enabled ]] && return 0
    probe::service_active 'ssh.socket'
    [[ ${OS_PROBE_VALUE} == active ]] && return 0
    return 1
}

# `PermitRootLogin` 的取值归一。
#
# **Debian 13 的 `sshd -T` 打的是 `without-password`**（容器实测），
# 那是 `prohibit-password` 在 openssh 6.x 时代的旧名字，两者语义完全相同。
# 不归一的话有两个后果：① 把当前有效值原样当成「用户想要的值」再写回配置时，
# 会被自己的取值校验拦下（第一次容器验收就是这么全线失败的）；
# ② 写 `prohibit-password` 之后读回 `without-password`，
# 「有效值核对」会判成没生效，然后**回滚一次本来完全正确的加固**。
safe_norm_rootlogin() {
    local __safe_out=${1} __safe_val=${2}
    [[ ${__safe_val} == without-password ]] && __safe_val='prohibit-password'
    printf -v "${__safe_out}" '%s' "${__safe_val}"
    return 0
}

safe_require_sshd() {
    probe::package_installed openssh-server
    if [[ ${OS_PROBE_VALUE} != yes ]]; then
        os::die 3 '没有检测到 openssh-server。装 SSH 服务端不是本工具的职责：apt-get install openssh-server'
    fi
    os::require_cmd sshd ssh-keygen systemctl

    # sshd 的特权分离目录。**没有它 `sshd -t` 会直接拒绝校验**：
    #   Missing privilege separation directory: /run/sshd
    # 而 /run/sshd 是 ssh.service 的 RuntimeDirectory —— **systemd 在服务停止时
    # 把它删掉**。也就是说，SSH 当前没在跑的机器（刚被中断打断、或用户先停了
    # 服务再来改配置），我们连自己写的配置能不能用都校验不了，
    # 于是每一次都以「sshd 拒绝了新配置」收场并回滚，而真正的原因在别处。
    # 容器验收的 SIGTERM 那一步与 socket 切换那一步都是这么撞上的。
    #
    # 它在 tmpfs 上、重启即消失、systemd 自己也会重建，因此不进变更清单、
    # 不进资源清单 —— 这不是一处需要撤销的副作用。
    if [[ ! -d /run/sshd ]]; then
        os::run '创建 sshd 特权分离目录' -- mkdir -p -m 0755 /run/sshd
    fi
    return 0
}

# 谁在抢这个配置项。改完发现有效值不是我们写的值时，用它把话说具体：
# 「PasswordAuthentication 没生效」帮不上忙，「50-cloud-init.conf 第 1 行
# 写着 PasswordAuthentication yes，它排在 00-oneserver.conf 前面」才是答案。
safe_who_wins() {
    local key=${1}
    os::query --timeout 5 -- \
        grep -rniE "^[[:space:]]*${key}[[:space:]]" "${SSHD_CONFIG}" "${SSHD_DROPIN_DIR}/" || true
    return 0
}

# ------------------------------------------------------------------
# safe status
# ------------------------------------------------------------------

action_status() {
    probe::ssh_port
    local port=${OS_PROBE_VALUE}
    local port_src
    port_src=$(probe::describe)

    local socket='no'
    safe_socket_activated && socket='yes'

    probe::sshd_effective passwordauthentication
    local pw=${OS_PROBE_VALUE:-未知}
    probe::sshd_effective kbdinteractiveauthentication
    local kbd=${OS_PROBE_VALUE:-未知}
    probe::sshd_effective pubkeyauthentication
    local pubkey=${OS_PROBE_VALUE:-未知}
    probe::sshd_effective permitrootlogin
    local rootlogin=${OS_PROBE_VALUE:-未知}

    # root 的公钥数。**不问用户看谁**：status 不该有交互点，
    # 而 root 是这个工具的运行身份，也是绝大多数 VPS 的登录身份
    probe::ssh_authkeys root
    local rootkeys=${OS_PROBE_VALUE}

    probe::ufw_active
    local ufw=${OS_PROBE_VALUE}

    probe::apt_upgrade_stats
    local upgradable security
    IFS=$'\t' read -r upgradable security <<<"${OS_PROBE_VALUE}"
    # 探测超时或 apt 不可用时值是空的。**空串不能直接进 (( ))** ——
    # 文件头是 `set -u`，算术里的空/非数字会当变量名解析，直接把脚本带走
    [[ ${upgradable} =~ ^[0-9]+$ ]] || upgradable=0
    [[ ${security} =~ ^[0-9]+$ ]] || security=0
    probe::auto_upgrades
    local auto=${OS_PROBE_VALUE}
    local auto_txt='未开启'
    [[ ${auto} =~ ^[1-9] ]] && auto_txt='已开启'
    probe::reboot_required
    local reboot=${OS_PROBE_VALUE:-no}

    local dropin='未使用'
    [[ -f ${SSHD_DROPIN} ]] && dropin=${SSHD_DROPIN}

    os::section 'SSH'
    os::kv '监听端口' "${port}" \
        'socket 激活' "${socket}" \
        '密码登录' "${pw}" \
        'PAM 交互式登录' "${kbd}" \
        '公钥登录' "${pubkey}" \
        'root 登录' "${rootlogin}" \
        'root 的公钥数' "${rootkeys}" \
        '本工具的配置片段' "${dropin}" \
        '数据来源' "${port_src}"

    os::section '防火墙与更新'
    os::kv 'UFW' "$([[ ${ufw} == yes ]] && printf '已启用' || printf '未启用')" \
        '可升级的包' "${upgradable}" \
        '其中安全更新' "${security}" \
        '自动安全更新' "${auto_txt}" \
        '需要重启' "${reboot}"

    # --- 待办：每一条都带上下一步该敲什么 ---
    #
    # 「体检报告只报数」等于把判断全推给用户。这里每条风险都跟一条可直接
    # 复制的命令，因为看得懂「passwordauthentication yes」意味着什么的人，
    # 本来也不需要这个工具
    local -i todo=0
    os::section '建议'
    if [[ ${pw} == yes ]]; then
        todo+=1
        if ((rootkeys > 0)); then
            os::warn '密码登录开着 —— 公网机器上被暴力破解的主要入口。已有公钥，可以关：oneserver safe ssh --password-auth=no'
        else
            os::warn '密码登录开着，而 root 还没有任何公钥。先装公钥：oneserver safe ssh --pubkey="ssh-ed25519 AAAA..." --password-auth=no'
        fi
    fi
    if [[ ${rootlogin} == yes && ${pw} == yes ]]; then
        todo+=1
        os::warn 'root 可以直接用密码登录，这是最坏的一档：oneserver safe ssh --permit-root-login=prohibit-password'
    fi
    if [[ ${ufw} != yes ]]; then
        todo+=1
        os::warn "防火墙没启用，所有监听中的端口都对公网开着：oneserver firewall enable"
    fi
    if ((security > 0)); then
        todo+=1
        os::warn "有 ${security} 个安全更新待安装：oneserver safe updates"
    fi
    if [[ ${auto_txt} == 未开启 ]]; then
        todo+=1
        os::info '没开自动安全更新 —— 装完就不用惦记的一件事：oneserver safe updates --auto-security=y'
    fi
    if [[ ${reboot} == yes ]]; then
        todo+=1
        os::warn '有更新要重启才生效：reboot'
    fi
    if ((todo == 0)); then
        os::ok '没有发现需要处理的项'
    fi

    os::output 0 port="${port}" socket_activated="${socket}" \
        password_auth="${pw}" permit_root_login="${rootlogin}" \
        pubkey_auth="${pubkey}" root_authkeys="${rootkeys}" \
        ufw_active="${ufw}" upgradable="${upgradable}" security_upgradable="${security}" \
        auto_updates="${auto_txt}" reboot_required="${reboot}" todo="${todo}"
    return 0
}

# ------------------------------------------------------------------
# safe ssh
# ------------------------------------------------------------------

# 把一把公钥装进 <user>/.ssh/authorized_keys。
#
# 三件事按顺序：**先校验格式**（sshd 对认不出来的行是静默忽略，用户以为配好了，
# 关掉密码登录之后才发现登不上）· 已存在就不重复追加· 落地经
# os::install_file 换 inode（authorized_keys 正被 sshd 读，且 dry-run 必须零变更）。
safe_install_pubkey() {
    local user=${1} home=${2} key=${3}
    local ssh_dir="${home}/.ssh"
    local ak="${ssh_dir}/authorized_keys"

    local dir tmp
    dir=$(os::tmpdir) || os::die 1 '无法创建临时目录'
    tmp="${dir}/pubkey"
    printf '%s\n' "${key}" >"${tmp}"

    if ! os::query --timeout 10 -- ssh-keygen -l -f "${tmp}"; then
        os::die 2 '这不是一把 ssh-keygen 认得的公钥（复制时被换行截断是最常见的原因）'
    fi
    os::info "公钥指纹：${OS_RUN_OUTPUT%%$'\n'*}"

    if [[ -f ${ak} ]] && os::query --timeout 5 -- grep -qxF -- "${key}" "${ak}"; then
        os::ok "这把公钥已经在 ${ak} 里，未重复添加"
        return 0
    fi

    os::run '创建 .ssh 目录' -- mkdir -p "${ssh_dir}"
    os::run '设置 .ssh 目录权限' -- chmod 0700 "${ssh_dir}"

    local newak="${dir}/authorized_keys"
    if [[ -f ${ak} ]]; then
        os::run '取出现有的 authorized_keys' -- cp -- "${ak}" "${newak}"
    else
        : >"${newak}"
    fi
    # dry-run 下上面的 cp 被跳过，newak 是空的 —— 那样落地会「删掉」现有的钥匙。
    # 预演不真写文件，所以不会出事，但也不能让它打出「将写入 1 把公钥」这种
    # 与真实执行不符的话。到这一步就够了，直接声明预演到此为止
    if [[ ${OS_DRYRUN} -eq 1 ]]; then
        os::info "[dry-run] 将把公钥追加到 ${ak}"
        return 0
    fi
    printf '%s\n' "${key}" >>"${newak}"

    # 覆盖一个可能已有内容的文件 —— 先备份（规范第三类）。
    # os::backup_file 同时注册了「还原副本」的回滚动作
    os::backup_file "${ak}" || os::die 1 "备份 ${ak} 失败"
    os::install_file --mode 0600 "${newak}" "${ak}" || os::die 1 "写入 ${ak} 失败"
    os::run '设置 authorized_keys 属主' -- chown -R "${user}:" "${ssh_dir}"
    os::ok "公钥已加入 ${ak}"
    return 0
}

# 公钥问答的产物。SAFE_KEY_USER 永远有值（末尾那句 `ssh -p … <user>@` 要用它），
# SAFE_KEY 为空表示这次不装公钥。
SAFE_KEY_USER='root'
SAFE_KEY_HOME=''
SAFE_KEY=''

# 决定这次要不要问公钥、问谁，以及已经有公钥时还要不要再加一把。
#
# **必须排在登录方式定下来之后**：`--password-auth=no` 与
# `--permit-root-login=no|prohibit-password` 是「从此只能拿钥匙进门」，公钥是
# 它们的前提；而登录方式一个字没改时，公钥只是顺手做的一件事，不该拦住只想改
# 端口的人 —— 不分辨这两种情形，就是不管选什么都先过一遍三道公钥问题，其中
# 「给哪个用户」还会因为一个这次根本用不到的用户名不存在而以退出码 2 停下。
#
# 已有公钥的用户不再被盲问一句「要授权的公钥内容」：先把指纹列出来，再问要不要
# **再加一把**。用户看得见自己配过什么，才谈得上决定要不要更新。
safe_ask_pubkey() {
    local want_pw=${1} want_root=${2}

    # 这次改动要不要求「有钥匙才进得来」，以及是哪个选择要求的
    local -i need_key=0
    local why=''
    if [[ ${want_pw} == no ]]; then
        need_key=1
        why='关闭密码登录'
    fi
    if [[ ${want_root} == prohibit-password ]]; then
        need_key=1
        why="${why:+${why}、}root 仅允许密钥登录"
    elif [[ ${want_root} == no ]]; then
        need_key=1
        why="${why:+${why}、}禁止 root 登录"
    fi

    # 命令行直接把钥匙给了就不再问要不要 —— 否则 --non-interactive 下确认点
    # 取默认值 n，用户明明传了 --pubkey 却被静默丢掉
    local -i given=0
    if os::flag --arg pubkey || os::flag --arg pubkey-file; then
        given=1
    fi

    if [[ ${given} -eq 0 && ${need_key} -eq 0 ]]; then
        os::confirm --arg add-pubkey '顺便给某个用户装一把 SSH 公钥？' n || return 0
    fi

    # 禁用 root 登录时**不给默认值**：将来由谁负责登录必须由人指明，
    # 猜一个 root 出来，正好是这次要禁掉的那个
    if [[ ${want_root} == no ]]; then
        os::ask --arg user '禁用 root 之后由哪个用户负责登录' SAFE_KEY_USER
    else
        os::ask --arg user 'SSH 公钥要授权给哪个用户' SAFE_KEY_USER 'root'
    fi
    [[ ${SAFE_KEY_USER} =~ ^[a-z_][a-z0-9_-]*$ ]] \
        || os::die 2 "用户名「${SAFE_KEY_USER}」不合法"
    probe::user_home "${SAFE_KEY_USER}"
    SAFE_KEY_HOME=${OS_PROBE_VALUE}
    [[ -n ${SAFE_KEY_HOME} && -d ${SAFE_KEY_HOME} ]] \
        || os::die 2 "用户 ${SAFE_KEY_USER} 不存在，或它的 home 目录不在"

    # 现有的钥匙：数字之外还要指纹。「已有 2 把」回答不了用户真正想问的
    # 「里面有没有我手上这台机器的那把」，而那才是他决定要不要再加时依据的东西
    probe::ssh_authkeys "${SAFE_KEY_USER}"
    local -i have=${OS_PROBE_VALUE}
    if ((have > 0)); then
        os::info "用户 ${SAFE_KEY_USER} 的 authorized_keys 里已有 ${have} 把公钥："
        if os::query --timeout 5 -- ssh-keygen -lf "${SAFE_KEY_HOME}/.ssh/authorized_keys"; then
            local line
            while IFS= read -r line; do
                [[ -n ${line} ]] && os::info "    ${line}"
            done <<<"${OS_RUN_OUTPUT}"
        fi
    fi

    if [[ ${given} -eq 0 ]]; then
        if ((have > 0)); then
            # 已经有钥匙，这次改动的前提就已经满足 —— 默认不动它
            os::confirm --arg add-pubkey '再加一把公钥？（选否就沿用上面这些）' n || return 0
        elif [[ ${need_key} -eq 1 ]]; then
            # 一把都没有，而这次改动正是「从此只能拿钥匙进门」。这里不用
            # 「回车跳过」的措辞：跳过的真实结果是下面的锁门检查以退出码 2 停下
            os::warn "用户 ${SAFE_KEY_USER} 一把公钥都没有，而你选了「${why}」—— 现在必须装一把，否则这次改动会把你锁在门外"
        fi
    fi

    # 两条来源二选一。命令行同时给两个是矛盾指令，当场拒绝；
    # 交互下填了内容就不再问文件路径，少问一遍
    if os::flag --arg pubkey && os::flag --arg pubkey-file; then
        os::die 2 '--pubkey 与 --pubkey-file 只能给一个'
    fi
    os::ask --arg pubkey '要授权的公钥内容（ssh-ed25519 / ssh-rsa 开头的一整行，回车改从文件读）' SAFE_KEY ''
    if [[ -z ${SAFE_KEY} ]]; then
        local pubkey_file=''
        os::ask --arg pubkey-file '公钥文件路径（.pub 文件，回车跳过）' pubkey_file ''
        if [[ -n ${pubkey_file} ]]; then
            [[ -f ${pubkey_file} ]] || os::die 2 "公钥文件不存在：${pubkey_file}"
            IFS= read -r SAFE_KEY <"${pubkey_file}" || true
            [[ -n ${SAFE_KEY} ]] || os::die 2 "公钥文件是空的：${pubkey_file}"
        fi
    fi
    return 0
}

# 写 sshd 配置。返回后读 SAFE_SSHD_CHANGED 知道有没有真的改动。
SAFE_SSHD_CHANGED=0

safe_apply_sshd() {
    local port=${1} pw=${2} rootlogin=${3}
    SAFE_SSHD_CHANGED=0

    # 主配置有没有 Include 片段目录（两台真机实测都在第 12 行）。
    # 没有的话说明用户自己重写过 sshd_config，我们不去替他重排文件结构，
    # 退回到逐行改主配置
    if os::query --timeout 5 -- \
        grep -qE '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/' "${SSHD_CONFIG}"; then

        local -i existed=0
        [[ -f ${SSHD_DROPIN} ]] && existed=1

        os::run '创建 sshd 配置片段目录' -- mkdir -p "${SSHD_DROPIN_DIR}"
        os::install_template --backup --mode 0600 \
            "${OS_TEMPLATE_DIR}/sshd-oneserver.conf" "${SSHD_DROPIN}" \
            PORT="${port}" \
            PUBKEY_AUTH='yes' \
            PASSWORD_AUTH="${pw}" \
            KBD_INTERACTIVE="${pw}" \
            PERMIT_ROOT_LOGIN="${rootlogin}" \
            || os::die 1 "写入 ${SSHD_DROPIN} 失败"
        SAFE_SSHD_CHANGED=${OS_TEMPLATE_CHANGED}

        # 本次新建的文件，撤销 = 删掉它（规范第一类）。
        # **只在原来不存在时注册**：文件本来就有的话，删掉等于把用户上一次的
        # 加固一起抹了 —— 那种情况由 --backup 注册的「还原副本」负责
        if [[ ${existed} -eq 0 && ${SAFE_SSHD_CHANGED} -eq 1 ]]; then
            os::defer rm -f -- "${SSHD_DROPIN}"
        fi
    else
        os::warn "${SSHD_CONFIG} 里没有 Include 片段目录，改主配置本身（已先备份）"
        local -i changed=0
        local kv key val
        # 注释掉的默认行（`#Port 22`）也要匹配，这样替换发生在**原来的位置**，
        # 而不是在文件末尾追加一行 —— 追加的那行会输给前面已经生效的值
        for kv in "Port ${port}" \
            'PubkeyAuthentication yes' \
            "PasswordAuthentication ${pw}" \
            "KbdInteractiveAuthentication ${pw}" \
            "PermitRootLogin ${rootlogin}"; do
            key=${kv%% *}
            val=${kv#* }
            os::replace_line --backup --append-if-missing "${SSHD_CONFIG}" \
                "^[#[:space:]]*${key}[[:space:]]" "${key} ${val}" \
                || os::die 1 "改写 ${SSHD_CONFIG} 的 ${key} 失败"
            [[ ${OS_REPLACE_CHANGED} -eq 1 ]] && changed=1
        done
        SAFE_SSHD_CHANGED=${changed}
    fi
    return 0
}

# ssh.socket 的端口 drop-in。**ListenStream= 那行空值不是笔误**：
# systemd 的列表型指令要先赋空值清掉 unit 自带的两条（v4 + v6），
# 不清的话新端口是**追加**的，机器会同时听在 22 和新端口上 ——
# 而用户以为 22 已经关了。
#
# **地址必须显式写 `0.0.0.0:<port>` 与 `[::]:<port>` 两条，禁止裸端口号**
# （两台真机实测踩过）：给 `ListenStream=` 一个裸端口号时，systemd 会自己拆成
# v4/v6 两个 socket 去配对——这条自动配对路径在**短时间内连续多次重配置同一个
# 运行中的 socket unit**（改端口来回试、菜单里连续操作）时会进入一种卡死状态：
# 新端口只绑上 IPv6，IPv4 静默拿不到监听，`ss`/`systemctl status` 都显示
# 「在监听」不报任何错，而且**已经卡死后，restart、甚至恢复成上一份能用的
# drop-in 再 restart 都救不回来**——唯一能救回来的是删掉 drop-in 整个回到
# 原厂配置。原厂 unit 自己就是显式写死两条地址（非裸端口），从未观测到同样问题；
# 让本工具写的 drop-in 与原厂格式一致，从根上不再依赖那条会卡死的自动配对路径。
safe_apply_socket_port() {
    local port=${1}
    local -i existed=0
    [[ -f ${SOCKET_DROPIN} ]] && existed=1

    local dir tmp
    dir=$(os::tmpdir) || os::die 1 '无法创建临时目录'
    tmp="${dir}/00-oneserver-port.conf"
    {
        printf '# 由 oneserver safe ssh 生成。删掉本文件即回到 ssh.socket 自带的端口。\n'
        printf '[Socket]\n'
        printf 'ListenStream=\n'
        printf 'ListenStream=0.0.0.0:%s\n' "${port}"
        printf 'ListenStream=[::]:%s\n' "${port}"
    } >"${tmp}"

    # `--backup` 不能省，且理由比别处更硬：**第二次改端口时**（existed=1）
    # 这里覆盖的是上一版 drop-in，而下面那条 `os::defer os::systemd_restart
    # ssh.socket` 会在失败回滚时重启 socket —— 没有副本可还原的话，重启用的
    # 是**已经换成新端口、且回滚没能改回去**的配置：工具报「已回滚」，
    # ssh.socket 实际听在新端口上。新端口没在安全组放行就是一次锁死，
    # 而当前会话还连着，要到断开重连才发现。sshd 那条等价路径（上面
    # safe_apply_sshd）一直是 --backup，这里跟它对齐。
    os::run '创建 ssh.socket 的 drop-in 目录' -- mkdir -p "${SOCKET_DROPIN_DIR}"
    os::install_file --backup --mode 0644 "${tmp}" "${SOCKET_DROPIN}" \
        || os::die 1 "写入 ${SOCKET_DROPIN} 失败"
    if [[ ${existed} -eq 0 && ${OS_TEMPLATE_CHANGED} -eq 1 ]]; then
        os::defer rm -f -- "${SOCKET_DROPIN}"
    fi
    os::systemd_daemon_reload
    return 0
}

# 上一次 safe_ufw_allow 是否真的新增了一条规则。
#
# **不能只看退出码**：ufw 对一条已存在的规则同样返回 0，只在输出里多打一句
# 「Skipping」。分不出「本次新增」与「用户早就有的」，注册的回滚就会去删掉
# 用户自己的规则。判据与 ufw_manager.sh 的 ufw_apply 一致。
SAFE_UFW_CHANGED=0

safe_ufw_allow() {
    local port=${1}
    SAFE_UFW_CHANGED=0

    # 有副作用且要读 stdout —— os::run_out 正是它的格子（D9），
    # 不能为了拿输出改用只读的 os::query 绕开 dry-run
    os::run_out --allow-fail --env "${UFW_ENV}" '放行 UFW 端口' -- \
        ufw allow "${port}/tcp" || true

    # dry-run 下命令没跑，输出必然是空的 —— 拿它去判定会打出「✓ 已放行」，
    # 让预演看起来像已经做完了（D15）。按「会改变」保守处理
    if [[ ${OS_RUN_SKIPPED} -eq 1 ]]; then
        SAFE_UFW_CHANGED=1
        return 0
    fi
    if [[ ${OS_RUN_STATUS} -ne 0 ]]; then
        os::err "放行 ${port}/tcp 失败"
        os::debug "ufw 输出：${OS_RUN_OUTPUT}"
        return 1
    fi
    case ${OS_RUN_OUTPUT} in
        *Skipping*) os::info "${port}/tcp 已在放行清单里，未重复添加" ;;
        *)
            SAFE_UFW_CHANGED=1
            os::ok "UFW 已放行 ${port}/tcp"
            ;;
    esac
    return 0
}

action_ssh() {
    safe_require_sshd

    probe::ssh_port
    local cur_port=${OS_PROBE_VALUE}
    probe::port_families "${cur_port}"
    local want_families=${OS_PROBE_VALUE}

    # 先问「要做什么」（登录方式）并把目标值定下来，再据此决定公钥要不要问、
    # 问谁 —— 关密码登录、限制 root 登录都要求先有公钥，公钥问题（含「给哪个
    # 用户」）整体排在选择之后，用户才看得出这几步是有因果关系的
    local port_in='' password_auth='' permit_root=''
    os::select --arg password-auth '密码登录' password_auth \
        'keep=保持现状' 'no=关闭密码登录' 'yes=开启密码登录'
    os::select --arg permit-root-login 'root 登录方式' permit_root \
        'keep=保持现状' 'prohibit-password=仅允许密钥' 'no=禁止 root 登录' 'yes=允许密码登录'

    # --- 目标值：keep 就沿用**当前有效值**，不是沿用配置文件里写了什么 ---
    #
    # 解析排在公钥问答之前：`keep` 落到哪一档决定了这次要不要公钥，
    # 而那是下面每一个公钥问题的前提
    probe::sshd_effective passwordauthentication
    local want_pw=${OS_PROBE_VALUE:-yes}
    probe::sshd_effective permitrootlogin
    local want_root=${OS_PROBE_VALUE:-prohibit-password}
    [[ ${password_auth} != keep ]] && want_pw=${password_auth}
    [[ ${permit_root} != keep ]] && want_root=${permit_root}
    safe_norm_rootlogin want_root "${want_root}"

    case ${want_pw} in
        yes | no) ;;
        *) os::die 2 "--password-auth 只认 keep/no/yes，当前有效值是「${want_pw}」" ;;
    esac
    case ${want_root} in
        yes | no | prohibit-password | forced-commands-only) ;;
        *) os::die 2 "--permit-root-login 的值「${want_root}」不是 sshd 认得的" ;;
    esac
    if [[ ${permit_root} == keep ]]; then
        os::debug "沿用当前有效的 root 登录策略：${want_root}"
    fi

    safe_ask_pubkey "${want_pw}" "${want_root}"

    os::ask --arg port "SSH 端口（当前 ${cur_port}，回车不改）" port_in ''
    local new_port=${cur_port}
    if [[ -n ${port_in} ]]; then
        [[ ${port_in} =~ ^[0-9]+$ ]] || os::die 2 "端口要是数字，收到「${port_in}」"
        ((port_in >= 1 && port_in <= 65535)) || os::die 2 "端口 ${port_in} 超出 1-65535"
        new_port=${port_in}
    fi
    if [[ ${new_port} != "${cur_port}" ]]; then
        probe::port_listening "${new_port}"
        [[ ${OS_PROBE_VALUE} == yes ]] \
            && os::die 2 "端口 ${new_port} 上已经有别的服务在听，换一个"
    fi

    # --- 先装公钥，再谈关密码登录。顺序反了就是「先拆梯子再上楼」 ---
    if [[ -n ${SAFE_KEY} ]]; then
        safe_install_pubkey "${SAFE_KEY_USER}" "${SAFE_KEY_HOME}" "${SAFE_KEY}"
    fi

    # --- 锁门检查：会把所有路一起断掉的两条不给确认选项，直接拒绝 ---
    #
    # 「危险但你确认就放行」在这里不成立：被锁在门外是**不可恢复**的
    # （云控制台的 VNC 不是每家都有，有的也不是人人会用），
    # 而代价只是先跑一条装公钥的命令
    if [[ ${want_pw} == no ]]; then
        probe::ssh_authkeys "${SAFE_KEY_USER}"
        local nkeys=${OS_PROBE_VALUE}
        ((nkeys > 0)) || os::die 2 \
            "用户 ${SAFE_KEY_USER} 一把公钥都没有，关掉密码登录就再也登不进来。先装公钥：oneserver safe ssh --user=${SAFE_KEY_USER} --pubkey=\"ssh-ed25519 AAAA...\""
        os::ok "用户 ${SAFE_KEY_USER} 有 ${nkeys} 把公钥，可以关密码登录"
    fi
    if [[ ${want_root} == no ]]; then
        [[ ${SAFE_KEY_USER} != root ]] || os::die 2 \
            '要禁用 root 登录，得先指明将来谁负责登录：oneserver safe ssh --user=<普通用户> --pubkey=... --permit-root-login=no（那个用户还要能 sudo）'
        probe::ssh_authkeys "${SAFE_KEY_USER}"
        ((OS_PROBE_VALUE > 0)) || os::die 2 \
            "禁用 root 登录之前，用户 ${SAFE_KEY_USER} 必须先有公钥 —— 否则两条路一起断了"
    fi
    # `prohibit-password` 同样是「从此只能拿钥匙进门」，只不过只约束 root。
    # **这一档此前完全没有检查**：选「仅允许密钥」而 root 一把公钥都没有，配置
    # 照写、服务照重启，root 这条路当场断掉，脚本一声不吭。
    # 这里是告警而不是拒绝：密码登录还开着的话别的用户仍进得来，硬拒绝会拦掉
    # 「先给普通用户配钥匙、root 只留给控制台」这种完全合理的用法；两条路一起
    # 关的情形由上面 want_pw == no 那条拦下
    if [[ ${want_root} == prohibit-password ]]; then
        probe::ssh_authkeys root
        ((OS_PROBE_VALUE > 0)) \
            || os::warn 'root 一把公钥都没有 —— 改完之后 root 就只剩一个没有钥匙的钥匙孔，再也登不进来（密码登录还开着，别的用户不受影响）'
    fi

    # --- 别让防火墙把自己挡在门外：先放行，再改 ---
    #
    # **不改端口时这一步也要做。** 当前 SSH 端口未必在放行清单里 —— 端口可能是
    # 在防火墙启用之后才改的，规则也可能被人删过 —— 而这条命令跑完往往紧接着
    # 就是断开重连，到那一刻才发现被自己的防火墙挡住就晚了。
    # ufw 加一条已存在的规则是幂等的，本来就放行着的话只多打一行「未重复添加」。
    # 启用防火墙不在这里做，那是 `safe firewall`
    probe::ufw_active
    if [[ ${OS_PROBE_VALUE} == yes ]]; then
        # SSH 端口**永不注册回滚**：防火墙此刻是启用着的，回滚删掉刚放行的规则
        # 之后，当前会话因为是已建立连接所以不断，下一次连接就进不来了
        safe_ufw_allow "${new_port}" \
            || os::die 1 "无法在 UFW 上放行 ${new_port}/tcp，SSH 配置一个字都没改"
        if [[ ${SAFE_UFW_CHANGED} -eq 1 ]]; then
            os::run --env "${UFW_ENV}" '重载 UFW 使放行生效' -- ufw reload
        fi
        if [[ ${new_port} != "${cur_port}" ]]; then
            os::info "旧端口 ${cur_port} 的规则保留着 —— 等你用新端口连上之后再删：oneserver firewall delete --ports=${cur_port} --proto=tcp --confirm-delete"
        fi
    else
        os::warn '这台机器没有启用防火墙，所有监听中的端口都对公网开着：oneserver safe firewall'
    fi
    if [[ ${new_port} != "${cur_port}" ]]; then
        os::warn "云服务器在机器外面还有一层安全组：${new_port} 要在厂商控制台放行，否则改完就连不上"
    fi

    # --- 万一后面哪一步失败，最后要把服务恢复成配置回滚后的样子 ---
    #
    # 回滚栈是**逆序**执行的，所以这一条要在动任何配置之前注册 ——
    # 它会在所有文件都还原之后才跑
    local ssh_unit=''
    safe_ssh_unit ssh_unit
    if safe_socket_activated; then
        os::defer os::systemd_restart 'ssh.socket'
    else
        os::defer os::systemd_restart "${ssh_unit}"
    fi

    safe_apply_sshd "${new_port}" "${want_pw}" "${want_root}"

    # dry-run 到此为止：文件没写、服务没重启，**再往下的每一句问的都是旧系统**——
    # `sshd -t` 校验的会是没改过的那份配置，「有效值是不是我要的」答案必然是否。
    # 拿旧系统的答案当预演结果，正是规范说的「会撒谎的 dry-run」
    if [[ ${OS_DRYRUN} -eq 1 ]]; then
        os::info '[dry-run] 后续步骤无法预演（校验、有效值核对、端口监听都要等配置真的写下去之后才问得出来）'
        os::output 0 port="${new_port}" password_auth="${want_pw}" \
            permit_root_login="${want_root}" user="${SAFE_KEY_USER}" changed=dry-run
        return 0
    fi

    # --- 语法：不过就一步都不往下走 ---
    #
    # 走 `sh -c` 是为了拿到 stderr：os::query 把 stderr 丢进 /dev/null，
    # 而 sshd -t 的报错全在 stderr 上，没有它用户只知道「校验失败」
    if ! os::query --timeout 10 -- sh -c 'sshd -t 2>&1'; then
        os::err 'sshd 拒绝了新配置，服务一步都没动'
        os::err "${OS_RUN_OUTPUT}"
        os::die 1 'sshd -t 未通过，正在回滚配置'
    fi
    os::ok 'sshd 语法校验通过'

    # --- 有效值核对：写了什么不算数，sshd 读到什么才算 ---
    local key want got
    for key in passwordauthentication permitrootlogin; do
        case ${key} in
            passwordauthentication) want=${want_pw} ;;
            *) want=${want_root} ;;
        esac
        probe::sshd_effective "${key}"
        got=${OS_PROBE_VALUE}
        # 读回来的可能是 without-password 这个旧名字，与我们写下去的
        # prohibit-password 是同一件事 —— 不归一就会回滚一次正确的加固
        [[ ${key} == permitrootlogin ]] && safe_norm_rootlogin got "${got}"
        if [[ ${got,,} != "${want,,}" ]]; then
            os::err "${key} 的有效值是「${got}」而不是「${want}」—— 有别的配置文件排在前面"
            safe_who_wins "${key}"
            os::err "${OS_RUN_OUTPUT}"
            os::die 1 "${key} 未能生效，正在回滚"
        fi
    done
    os::ok "有效配置已核对：密码登录=${want_pw}，root 登录=${want_root}"

    # --- 端口切换与验证 ---
    if [[ ${new_port} != "${cur_port}" ]] && safe_socket_activated; then
        safe_apply_socket_port "${new_port}"
        os::systemd_restart 'ssh.socket'
    elif [[ ${SAFE_SSHD_CHANGED} -eq 1 ]]; then
        if safe_socket_activated; then
            # socket 激活时 sshd 是每连接一个进程，配置改了下次连接就生效，
            # 但重启一下 socket 更干净（不影响已建立的连接）
            os::systemd_restart 'ssh.socket'
        else
            os::systemd_restart "${ssh_unit}"
        fi
    else
        os::ok 'SSH 配置已是目标状态，未重启服务'
    fi

    if [[ ${SAFE_SSHD_CHANGED} -eq 1 || ${new_port} != "${cur_port}" ]]; then
        # systemd 起监听有几十毫秒的延迟，一次就判会误判。
        # 五次一秒的轮询，比 `sleep 3` 既快又稳
        local -i attempt=0
        local listening='no'
        while ((attempt < 5)); do
            attempt+=1
            probe::port_listening "${new_port}"
            if [[ ${OS_PROBE_VALUE} == yes ]]; then
                listening='yes'
                break
            fi
            os::debug "第 ${attempt} 次没探到 ${new_port} 在监听，等 1 秒再看"
            os::query --timeout 3 -- sleep 1 || true
        done
        if [[ ${listening} != yes ]]; then
            os::err "SSH 没有在 ${new_port} 端口监听"
            os::query --timeout 10 -- journalctl -u "${ssh_unit}" --no-pager -n 20
            os::err "${OS_RUN_OUTPUT}"
            os::die 1 '端口未生效，正在回滚配置并恢复服务'
        fi

        # 「在监听」不等于「改动前能连的方式现在还能连」——只看 yes/no 接不住
        # 只掉了一半地址族的情况（比如只剩 IPv6，最常见的 IPv4 连接被直接拒绝）。
        # 按地址族比对，改动后不能比改动前少
        probe::port_families "${new_port}"
        local got_families=${OS_PROBE_VALUE} fam
        for fam in ${want_families}; do
            [[ " ${got_families} " == *" ${fam} "* ]] && continue
            os::err "新端口 ${new_port} 只监听在「${got_families:-无}」，比改动前的「${want_families}」少了 ${fam}"
            os::query --timeout 10 -- journalctl -u "${ssh_unit}" --no-pager -n 20
            os::err "${OS_RUN_OUTPUT}"
            os::die 1 '监听地址族不完整，正在回滚配置并恢复服务'
        done
        os::ok "SSH 正在监听 ${new_port}"
    fi

    # --- 最后一句永远是「别关这个窗口」---
    os::section '下一步'
    if [[ -n ${SSH_CONNECTION-} ]]; then
        os::warn '不要关闭当前这个 SSH 会话！先另开一个终端验证新配置：'
    else
        os::info '另开一个终端验证：'
    fi
    os::info "  ssh -p ${new_port} ${SAFE_KEY_USER}@<服务器 IP>"
    os::info '连上了再关掉旧窗口。连不上的话，当前窗口还在，能改回来。'

    os::output 0 port="${new_port}" password_auth="${want_pw}" \
        permit_root_login="${want_root}" user="${SAFE_KEY_USER}" \
        changed="$([[ ${SAFE_SSHD_CHANGED} -eq 1 ]] && printf yes || printf no)"
    return 0
}

# ------------------------------------------------------------------
# safe updates
# ------------------------------------------------------------------

action_updates() {
    # 先刷索引再数数：拿着三个月前的索引报「0 个可升级」，
    # 是这条命令最容易给出的错误结论
    os::pkg_refresh || os::warn '刷新软件包索引失败，下面的数字来自现有索引'

    probe::apt_upgrade_stats
    local upgradable security
    IFS=$'\t' read -r upgradable security <<<"${OS_PROBE_VALUE}"
    [[ ${upgradable} =~ ^[0-9]+$ ]] || upgradable=0
    [[ ${security} =~ ^[0-9]+$ ]] || security=0

    os::section '系统更新'
    os::kv '可升级的包' "${upgradable}" \
        '其中安全更新' "${security}" \
        '数据来源' "$(probe::describe)"

    if ((upgradable > 0)); then
        if os::confirm --arg upgrade "现在升级这 ${upgradable} 个包？" y; then
            # apt 装的东西属「禁止自动回滚」类（规范第二类）：
            # 降级回旧版本比留在新版本破坏更大
            os::record_change 'apt 升级了已安装的软件包'
            os::critical_begin '升级软件包'
            os::run --env 'DEBIAN_FRONTEND=noninteractive' --env 'NEEDRESTART_MODE=a' \
                '升级已安装的软件包' -- apt-get upgrade -y -qq
            os::critical_end
            # dry-run 下 os::run 被跳过，一个包都没升——不看 OS_RUN_SKIPPED
            # 就打「已升级」，是 D15 说的「会撒谎的 dry-run」
            if [[ ${OS_RUN_SKIPPED} -eq 1 ]]; then
                os::info "[dry-run] 将升级 ${upgradable} 个包"
            else
                os::ok '软件包已升级'
            fi
        else
            os::info '已跳过升级'
        fi
    else
        os::ok '没有可升级的包，已是目标状态'
    fi

    # --- 自动安全更新 ---
    #
    # **这是这条命令里最值钱的一项。** 手工升级依赖人记得来跑，
    # 而绝大多数被入侵的机器，用的都是一个几个月前就有补丁的漏洞。
    if os::confirm --arg auto-security '开启自动安全更新（每天自动装安全补丁）？' y; then
        os::pkg_install unattended-upgrades || os::die 1 '安装 unattended-upgrades 失败'

        local -i conf_existed=0
        [[ -f ${AUTO_UPGRADES_CONF} ]] && conf_existed=1
        os::install_template --backup "${OS_TEMPLATE_DIR}/20auto-upgrades" "${AUTO_UPGRADES_CONF}" \
            || os::die 1 "写入 ${AUTO_UPGRADES_CONF} 失败"

        os::systemd_enable --now 'unattended-upgrades.service' ext

        # state：装了什么就记什么，卸载时才有原料。
        # **只记本次真正装上的包**（规范两层过滤），也只在文件是本次新建时
        # 才把它记成 file —— Ubuntu 出厂就带着这个文件（实测值就是 1;1），
        # 把它记成「我们创建的」会让卸载删掉发行版自己的配置
        probe::package_version unattended-upgrades
        os::state_set "${AUTO_UPDATES_ID}" version="${OS_PROBE_VALUE}" method=apt
        local pkg
        while IFS= read -r pkg; do
            [[ -n ${pkg} ]] || continue
            os::state_resource_add "${AUTO_UPDATES_ID}" pkg "${pkg}"
        done < <(os::pkg_installed_names)
        if [[ ${conf_existed} -eq 0 ]]; then
            os::state_resource_add "${AUTO_UPDATES_ID}" file "${AUTO_UPGRADES_CONF}"
        fi

        if [[ ${OS_TEMPLATE_CHANGED} -eq 0 ]]; then
            os::ok '自动安全更新已是开启状态'
        else
            os::ok "自动安全更新已开启（配置在 ${AUTO_UPGRADES_CONF}）"
        fi
        os::info '看它都干了什么：less /var/log/unattended-upgrades/unattended-upgrades.log'
    else
        os::info '已跳过自动安全更新'
    fi

    probe::reboot_required
    if [[ ${OS_PROBE_VALUE} == yes ]]; then
        os::warn '有更新要重启才生效。挑个合适的时间：reboot'
    fi

    probe::apt_upgrade_stats
    local upgradable_now
    IFS=$'\t' read -r upgradable_now _ <<<"${OS_PROBE_VALUE}"
    os::output 0 upgradable="${upgradable_now:-0}" security="${security}"
    return 0
}

# ------------------------------------------------------------------

# 网络定位。**这台机器的容器端口对谁开放，只在这里定一次。**
#
# 它同时决定两件必须一致的事，而这正是它存在的理由 —— 分成两个开关的话，
# 用户每建一个容器都要想「绑哪个地址」还要再去改一次防火墙，两边对不上时
# 现场表现是「端口明明发布了却连不上」，而两处看起来都是对的：
#
#            容器端口绑定           ufw 转发策略
#   公网     127.0.0.1（只本机）    DROP
#   内网     0.0.0.0（局域网可达）  ACCEPT
#
# **两个引擎落实这张表的方式不同，而这不是实现细节，是安全边界本身：**
#
#   podman —— 绑定地址在建容器时写进 Quadlet（`oneserver podman run` 补的），
#             防火墙那一半由下面的 DEFAULT_FORWARD_POLICY 兜底。
#   docker —— 绑定地址写进 `/etc/docker/daemon.json` 的 `"ip"`，此后每一条
#             `docker run` 都算数。**防火墙那一半对它完全不成立** ——
#             dockerd 启动时把自己的跳转插在 FORWARD 链最前面，发布出去的
#             端口在 ufw 的任何规则之前就被 ACCEPT 了。把 Docker 的防护
#             寄托在 ufw 上，得到的是一个看起来两边都对、实际毫无防护的状态。
#
# 为什么防火墙那一半是 DEFAULT_FORWARD_POLICY 而不是按网桥或网段放行：
# 网桥不止一个也不固定 —— 默认网络是 podman0，`podman network create` 与
# compose 项目各自建网络会得到 podman1、podman2…，网桥名还能自定义；网段同理
# （默认 10.88.0.0/16，新建的从 default_subnet_pool 里分）。写死网桥或网段的
# 规则，用户建第二个网络那天就失效，**而失效是静默的**。
#
# 容器端口走的是转发不是入站：包一进来就被 DNAT 成容器地址，不再是本机地址，
# 于是走 FORWARD 链。所以 `ufw allow <端口>` 那种入站规则对容器一个字都不管用。
action_network() {
    local current
    current=$(os::state_get "${NETWORK_ID}" mode '')

    os::section '网络定位'
    probe::ufw_active
    os::kv '当前定位' "${current:-（未设置，按公网处理）}" \
        'UFW' "$([[ ${OS_PROBE_VALUE} == yes ]] && printf '已启用' || printf '未启用')" \
        '转发策略' "$(forward_policy)"

    local mode=''
    os::select --arg network-mode '这台机器怎么用？' mode \
        '公网=公网服务器 —— 容器端口只绑本机，一律走 Caddy 反代' \
        '内网=内网机器 —— 容器端口直接对局域网开放'

    if [[ ${mode} == 内网 ]]; then
        os::warn '内网定位会放开 ufw 的转发策略 —— 等于让本机转发它能路由的一切，不只是容器'
        if ! os::confirm --arg confirm-internal '确认这台机器在可信内网？' n; then
            os::info '已取消，定位未改变'
            os::output 0 mode="${current}" changed=no
            return 0
        fi
    fi

    local want_policy='DROP'
    [[ ${mode} == 内网 ]] && want_policy='ACCEPT'
    apply_forward_policy "${want_policy}"
    apply_docker_bind_ip "${mode}"

    os::state_set "${NETWORK_ID}" mode="${mode}" forward_policy="${want_policy}"
    os::ok "网络定位：${mode}"
    if [[ ${mode} == 内网 ]]; then
        os::info '此后新建容器发布的端口直接对局域网可达，不用再动防火墙'
    else
        os::info '此后新建容器发布的端口只绑 127.0.0.1，对外请用 oneserver caddy 反代'
    fi

    [[ ${mode} == 公网 ]] && list_forward_rules
    list_mismatched_containers "${mode}"
    os::output 0 mode="${mode}" policy="${want_policy}" changed=yes
    return 0
}

# 转发策略只是**兜底**：显式的 `ufw route allow` 规则排在它前面，命中即放行，
# 默认策略根本轮不到。所以公网定位光把 DEFAULT_FORWARD_POLICY 设成 DROP 不够 ——
# 已有的 ALLOW FWD 规则会让容器端口照样可达，而界面上写着「只绑本机」。
# 不列出来的话，这句话就是假的。
#
# **只列不删**：删防火墙规则不可逆，而且这些规则未必都是入站放行 ——
# 「From 是容器网段」的那条是容器出网，删了所有容器连不上网。哪条该留只有人知道。
list_forward_rules() {
    probe::ufw_rules
    [[ -n ${OS_PROBE_VALUE} ]] || return 0

    local line
    local -a fwd=()
    while IFS= read -r line; do
        [[ ${line} == *'ALLOW FWD'* ]] || continue
        fwd+=("${line}")
    done <<<"${OS_PROBE_VALUE}"
    [[ ${#fwd[@]} -gt 0 ]] || return 0

    os::warn '下列转发放行规则会绕过上面的转发策略 —— 命中它们的容器端口仍然可达：'
    for line in "${fwd[@]}"; do
        os::info "    ${line}"
    done
    os::info '读法是「目标 ALLOW FWD 来源」：来源为容器网段的那条是容器出网，删了容器断网；'
    os::info '目标为容器网段的那条才是外部进容器的放行'
    os::info '要关掉用 oneserver firewall 删，本命令不替你删'
    return 0
}

# /etc/default/ufw 里当前的转发策略，读不到按发行版默认的 DROP 算
forward_policy() {
    local p='DROP'
    if os::query --timeout 5 -- grep -oE '^DEFAULT_FORWARD_POLICY="[A-Z]+"' "${UFW_DEFAULTS}"; then
        p=${OS_RUN_OUTPUT#*\"}
        p=${p%\"}
    fi
    printf '%s' "${p}"
}

apply_forward_policy() {
    local want=${1}
    # 系统事实只出自 probe::（§3），不绕开它自己判 command -v
    probe::package_installed ufw
    if [[ ${OS_PROBE_VALUE} != yes ]]; then
        os::info '本机没有 ufw，转发不受限制，只记录定位'
        return 0
    fi
    [[ $(forward_policy) == "${want}" ]] && return 0

    # 「先备份再改」类：/etc/default/ufw 是发行版的 conffile，不可重建
    os::record_change "把 ${UFW_DEFAULTS} 的 DEFAULT_FORWARD_POLICY 改成 ${want}"
    os::replace_line --backup "${UFW_DEFAULTS}" '^DEFAULT_FORWARD_POLICY=' \
        "DEFAULT_FORWARD_POLICY=\"${want}\"" \
        || os::die 1 "${UFW_DEFAULTS} 里找不到 DEFAULT_FORWARD_POLICY 行，配置文件可能已被大改"

    # 未启用时 reload 是空操作：ufw 打「Firewall not enabled (skipping reload)」
    # 并返回 0 —— 那时说「已生效」是假话
    probe::ufw_active
    if [[ ${OS_PROBE_VALUE} == yes ]]; then
        os::run --env "${UFW_ENV}" '重载 UFW 使转发策略生效' -- ufw reload
    else
        os::warn "UFW 当前未启用，转发策略要等启用后才生效（oneserver firewall）"
    fi
    return 0
}

# Docker 那一半的定位。**它与 ufw 那一半不是同一个机制**，理由见上面表格下的
# 说明：防火墙管不住 Docker 发布的端口，能管住的只有绑定地址本身。
#
# 只动**本工具放下的那一份** daemon.json（安装时登记在 docker 组件的 file
# 清单里）。用户自己的配置不覆盖（§12），那时只能明说这一半没落实 ——
# 装作落实了才是真正危险的。
apply_docker_bind_ip() {
    local mode=${1}

    probe::component_version docker
    [[ -n ${OS_PROBE_VALUE} ]] || return 0

    # 与 install_docker.sh 是同一张表
    local bind_ip='127.0.0.1'
    [[ ${mode} == 内网 ]] && bind_ip='0.0.0.0'

    local f
    local -i owns=1 created=0
    if [[ -f ${DAEMON_JSON} ]]; then
        owns=0
        while IFS= read -r f; do
            if [[ ${f} == "${DAEMON_JSON}" ]]; then
                owns=1
                break
            fi
        done < <(os::state_resources "${DOCKER_ID}" file)
    else
        created=1
    fi

    if ((owns == 0)); then
        os::warn "${DAEMON_JSON} 是你自己的配置，本命令不改它 —— Docker 这一半的定位没有落实"
        os::info "要落实：在里面写 \"ip\": \"${bind_ip}\"，然后 systemctl restart docker"
        return 0
    fi

    if ! os::install_template --backup --mode 0644 \
        "${OS_TEMPLATE_DIR}/docker-daemon.json" "${DAEMON_JSON}" "BIND_IP=${bind_ip}"; then
        os::warn "写入 ${DAEMON_JSON} 失败 —— Docker 这一半的定位没有落实"
        return 0
    fi
    ((created == 1)) && os::state_resource_add "${DOCKER_ID}" file "${DAEMON_JSON}"
    [[ ${OS_TEMPLATE_CHANGED} -eq 1 ]] || return 0

    # 不重启就是「写进去了但没生效」，而界面上看不出这个区别。
    # 有容器在跑时才问：那时重启是一次真实的服务中断
    probe::docker_running
    local running=${OS_PROBE_VALUE:-0}
    [[ ${running} =~ ^[0-9]+$ ]] || running=0
    local -i do_restart=1
    if ((running > 0)); then
        os::warn "重启 dockerd 会中断正在跑的 ${running} 个容器（带重启策略的会自己起回来）"
        os::confirm --arg restart-docker '现在重启 dockerd 让新的绑定地址生效' y || do_restart=0
    fi
    if ((do_restart == 1)); then
        os::systemd_restart docker.service
        os::ok "Docker 新建容器的端口默认绑 ${bind_ip}"
    else
        os::warn "${DAEMON_JSON} 已写入但尚未生效 —— dockerd 重启之前，新建容器仍按旧的默认地址绑"
    fi
    return 0
}

# 已有容器的绑定地址是**建的时候就定死的**，改定位不会追溯 —— podman 写在
# Quadlet 里，Docker 写在容器自身的配置里。不列出来的话，用户以为切完就生效了，
# 而那几个容器还是老样子。
# **只列不改**：改绑定要重建容器，那是实打实的服务中断，得由人挑时间。
list_mismatched_containers() {
    local mode=${1}
    probe::podman_ports
    check_ports_against_mode "${mode}" 'oneserver podman'
    probe::docker_ports
    check_ports_against_mode "${mode}" 'oneserver docker'
    return 0
}

# 读 OS_PROBE_VALUE 里的「名字<制表符>映射」，挑出与定位不符的那些。
# 两个引擎的探测输出是同一种格式，所以判断只写一遍
check_ports_against_mode() {
    local mode=${1} how=${2}
    [[ -n ${OS_PROBE_VALUE} ]] || return 0

    local line name ports
    local -a bad=()
    while IFS=$'\t' read -r name ports; do
        [[ -n ${name} && -n ${ports} ]] || continue
        if [[ ${mode} == 内网 && ${ports} == *'127.0.0.1:'* ]]; then
            bad+=("${name}  ${ports}  —— 绑在本机，局域网连不上")
        elif [[ ${mode} == 公网 && ${ports} == *'0.0.0.0:'* ]]; then
            bad+=("${name}  ${ports}  —— 绑在 0.0.0.0，对外暴露")
        fi
    done <<<"${OS_PROBE_VALUE}"

    [[ ${#bad[@]} -gt 0 ]] || return 0
    os::warn "下列容器的端口绑定与新定位不符（绑定地址在建容器时定死，本命令不会改它）："
    for line in "${bad[@]}"; do
        os::info "    ${line}"
    done
    os::info "要让它们跟上，用 ${how} 删掉后按同一条 run 命令重建"
    return 0
}

main() {
    local action=${1-}
    if [[ -n ${action} ]]; then
        dispatch "${action}"
        return 0
    fi

    # `status` 在这里占一项而不是只当总览：体检要跑一整轮探测（sshd 有效配置、
    # apt 统计、公钥数），改完一项想复看结果时，得有个地方能主动再跑一次
    os::action_menu --overview action_status --arg action '操作' dispatch \
        'ssh=SSH 加固' 'updates=系统更新与自动安全更新' \
        'network=网络定位（公网 / 内网）' 'status=重新体检'
}

dispatch() {
    case ${1} in
        status) action_status ;;
        ssh) action_ssh ;;
        updates) action_updates ;;
        network) action_network ;;
        *) os::die 2 "未知操作「${1}」，可用：status ssh updates network" ;;
    esac
}

main "$@"
