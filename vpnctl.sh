#!/bin/bash
# SoftEther VPN Client 控制脚本
# Version 2.1
# 用法:
#   ./vpn-ctl.sh                                        # 列出账户
#   ./vpn-ctl.sh <账户名> connect|c                     # 连接
#   ./vpn-ctl.sh <账户名> disconnect|d                  # 断开
#   ./vpn-ctl.sh add <新连接名> <地址:端口> <Hub名>     # 新增连接（用户名/密码交互输入）
#   ./vpn-ctl.sh import <配置文件路径>                  # 导入连接设置
#   ./vpn-ctl.sh del <连接名>                           # 删除连接

set -e

SCRIPT_NAME="$(basename "$0")"

VPN_DIR="/opt/vpnclient"
VPN_IF="vpn_1"
NM_CON_NAME="vpn-dhcp-$VPN_IF"

TARGET_NET=(
    "10.10.0.0/16"
)

# ===== 自动提权 =====
if [ "$(id -u)" -ne 0 ]; then
    exec sudo "$0" "$@"
fi

# ===== 检查 VPN 后台服务 =====
if pgrep -x "vpnclient" >/dev/null 2>&1; then
    echo ">>> VPN Client 服务已在运行"
else
    echo ">>> VPN Client 服务未运行，正在启动..."
    "$VPN_DIR/vpnclient" start
    sleep 1
fi

# ===== 新增连接 =====
if [ "$1" = "add" ]; then
    if [ $# -ne 4 ]; then
        echo "错误：新增连接需要 3 个参数，用户名和密码交互式输入。"
        echo "用法：$SCRIPT_NAME add <新连接名> <地址:端口> <Hub名>"
        echo "示例：$SCRIPT_NAME add myvpn vpn.example.com:443 VPN"
        exit 1
    fi

    NEW_NAME="$2"
    SERVER="$3"
    HUB="$4"

    echo ">>> 正在创建新连接: $NEW_NAME"
    echo "    服务器: $SERVER"
    echo "    Hub: $HUB"
    echo "    虚拟网卡: $VPN_IF"

    if "$VPN_DIR/vpncmd" localhost /CLIENT /CMD AccountList 2>/dev/null | grep -q "连接设置名.*$NEW_NAME"; then
        echo "错误：连接 \"$NEW_NAME\" 已存在。"
        exit 1
    fi

    read -r -p "用户名: " USERNAME
    if [ -z "$USERNAME" ]; then
        echo "错误：用户名不能为空。"
        exit 1
    fi

    #read -r -s -p "密码: " PASSWORD
    read -r -p "密码: " PASSWORD
    echo
    if [ -z "$PASSWORD" ]; then
        echo "错误：密码不能为空。"
        exit 1
    fi

    "$VPN_DIR/vpncmd" localhost /CLIENT /CMD \
        AccountCreate "$NEW_NAME" \
        /SERVER:"$SERVER" \
        /HUB:"$HUB" \
        /USERNAME:"$USERNAME" \
        /NICNAME:"$VPN_IF"

    "$VPN_DIR/vpncmd" localhost /CLIENT /CMD \
        AccountPasswordSet "$NEW_NAME" \
        /PASSWORD:"$PASSWORD" \
        /TYPE:standard

    unset PASSWORD

    # 关闭该账户连接时自动调整路由表
    #"$VPN_DIR/vpncmd" localhost /CLIENT /CMD \
    #    AccountDetailSet "$NEW_NAME" /NOTRACK

    #echo ">>> 连接 \"$NEW_NAME\" 创建完成（已设置 /NOTRACK）。"
    echo ">>> 连接 \"$NEW_NAME\" 创建完成。"
    echo "    使用以下命令连接："
    echo "    $SCRIPT_NAME $NEW_NAME connect"
    exit 0
fi

# ===== 导入连接设置 =====
if [ "$1" = "import" ]; then
    if [ $# -ne 2 ]; then
        echo "错误：导入需要 1 个参数。"
        echo "用法：$SCRIPT_NAME import <配置文件路径>"
        exit 1
    fi

    IMPORT_FILE="$2"

    if [ ! -f "$IMPORT_FILE" ]; then
        echo "错误：文件不存在: $IMPORT_FILE"
        exit 1
    fi

    echo ">>> 正在导入连接设置: $IMPORT_FILE"
    "$VPN_DIR/vpncmd" localhost /CLIENT /CMD AccountImport "$IMPORT_FILE"
    echo ">>> 导入完成。"
    exit 0
fi

# ===== 删除连接 =====
if [ "$1" = "del" ] || [ "$1" = "delete" ]; then
    if [ $# -ne 2 ]; then
        echo "错误：删除连接需要 1 个参数。"
        echo "用法：$SCRIPT_NAME del <连接名>"
        exit 1
    fi

    DEL_NAME="$2"

    if ! "$VPN_DIR/vpncmd" localhost /CLIENT /CMD AccountList 2>/dev/null | grep -q "连接设置名.*$DEL_NAME"; then
        echo "错误：连接 \"$DEL_NAME\" 不存在。"
        exit 1
    fi

    echo ">>> 正在删除连接: $DEL_NAME"
    "$VPN_DIR/vpncmd" localhost /CLIENT /CMD AccountDelete "$DEL_NAME"
    echo ">>> 连接 \"$DEL_NAME\" 已删除。"
    exit 0
fi

# ===== 无参数：列出账户 =====
if [ $# -eq 0 ]; then
    echo ">>> 当前 VPN 账户列表："
    "$VPN_DIR/vpncmd" localhost /CLIENT /CMD AccountList
    echo ""
    echo "用法："
    echo "  $SCRIPT_NAME <账户名> connect|c                    # 连接"
    echo "  $SCRIPT_NAME <账户名> disconnect|d                 # 断开"
    echo "  $SCRIPT_NAME add <名> <地址:端口> <Hub>             # 新增（用户名/密码交互输入）"
    echo "  $SCRIPT_NAME import <配置文件路径>                 # 导入"
    echo "  $SCRIPT_NAME del <连接名>                          # 删除"
    exit 0
fi

# ===== 参数检查（连接/断开） =====
if [ $# -lt 2 ]; then
    echo "错误：参数不足。"
    echo "用法：$SCRIPT_NAME <账户名> {connect|disconnect|c|d}"
    exit 1
fi

ACCOUNT_NAME="$1"
ACTION="$2"

case "$ACTION" in
    connect|c)
        echo ">>> 连接账户: $ACCOUNT_NAME"
        "$VPN_DIR/vpncmd" localhost /CLIENT /CMD AccountConnect "$ACCOUNT_NAME"

        echo ">>> 等待隧道建立..."
        sleep 3

        echo ">>> 通过 NetworkManager 获取 IP..."
        if nmcli -t -f NAME connection show | grep -qx "$NM_CON_NAME"; then
            nmcli connection delete "$NM_CON_NAME" &>/dev/null || true
        fi
        while IFS= read -r con; do
            [ -z "$con" ] && continue
            [ "$con" = "$NM_CON_NAME" ] && continue
            nmcli connection delete "$con" &>/dev/null || true
            echo "    已清理自动生成连接: $con"
        done < <(nmcli -t -f NAME,DEVICE connection show | awk -F: -v d="$VPN_IF" '$2==d {print $1}')

        # 连接可能已存在（上次运行创建过），避免 connection add 因重复而失败退出
        if ! nmcli connection show "$NM_CON_NAME" >/dev/null 2>&1; then
            nmcli connection add type tun con-name "$NM_CON_NAME" ifname "$VPN_IF"
        fi
        nmcli connection modify "$NM_CON_NAME" tun.mode tap
        # 关键：只屏蔽 DHCP 下发的默认路由，SoftEther 下发的其他路由照常接受。
        # 不用 ipv4.ignore-auto-routes yes —— 那会把所有自动路由都丢掉。
        # never-default 已足以阻止 DHCP 续租（T1/T2）时把默认路由加回来。
        nmcli connection modify "$NM_CON_NAME" \
            ipv4.method auto \
            ipv4.dhcp-timeout 120 \
            ipv4.never-default yes \
            ipv6.method disabled \
            connection.autoconnect yes \
            connection.autoconnect-retries 0

        # 等待 DHCP 完成后再操作路由，避免 DHCP 晚于脚本完成而补写默认路由
        if ! nmcli --wait 30 connection up "$NM_CON_NAME"; then
            echo "错误：激活 NetworkManager 连接 $NM_CON_NAME 失败，请检查 vpncmd 是否已成功建立隧道。"
            exit 1
        fi

        echo ">>> 等待 DHCP 完成..."
        sleep 2

        echo ">>> 从 DHCP 信息中提取 VPN 网关..."
        # 注意：设置 never-default 后，部分 NetworkManager 版本不再把 DHCP 网关
        # 登记到 IP4.GATEWAY，因此改从 DHCP 原始选项读取。
        # 实测：nmcli -g 输出为“单行、各项以 | 分隔”，必须先拆行再匹配，不能用行首锚定
        VPN_DEFAULT_GW=$(nmcli -g DHCP4.OPTION device show "$VPN_IF" 2>/dev/null \
            | tr '|' '\n' \
            | sed -n 's/^[[:space:]]*routers[[:space:]]*=[[:space:]]*\([^[:space:]/]*\).*/\1/p' \
            | head -n1)

        # 兜底 1：从 NetworkManager / dhclient 的租约文件读取
        if [ -z "$VPN_DEFAULT_GW" ]; then
            VPN_DEFAULT_GW=$(grep -h -m1 'option routers' \
                /var/lib/NetworkManager/*"$VPN_IF"*.lease \
                /var/lib/dhcp/dhclient-"$VPN_IF".lease \
                /var/lib/dhcp/dhclient.leases 2>/dev/null \
                | awk '{gsub(/;/,"",$3); print $3}')
        fi

        # 兜底 2：若默认路由仍存在，直接从路由表读取
        if [ -z "$VPN_DEFAULT_GW" ]; then
            VPN_DEFAULT_GW=$(ip route show default dev "$VPN_IF" 2>/dev/null \
                | awk '/via/ {for(i=1;i<=NF;i++) if($i=="via") print $(i+1); exit}')
        fi

        # 兜底 3：以上都取不到时，临时恢复 DHCP 默认路由，从路由表取到后再重新屏蔽。
        # 这样可兼容各类 NetworkManager 版本，无需依赖 IP4.GATEWAY 属性。
        if [ -z "$VPN_DEFAULT_GW" ]; then
            echo "    常规方式未取到网关，临时恢复 DHCP 默认路由后重试..."
            nmcli connection modify "$NM_CON_NAME" \
                ipv4.never-default no 2>/dev/null || true
            nmcli --wait 30 connection up "$NM_CON_NAME" 2>/dev/null || true
            sleep 2
            VPN_DEFAULT_GW=$(ip route show default dev "$VPN_IF" 2>/dev/null \
                | awk '/via/ {for(i=1;i<=NF;i++) if($i=="via") print $(i+1); exit}')
            nmcli connection modify "$NM_CON_NAME" \
                ipv4.never-default yes 2>/dev/null || true
            nmcli --wait 30 connection up "$NM_CON_NAME" 2>/dev/null || true
            sleep 1
        fi

        if [ -z "$VPN_DEFAULT_GW" ]; then
            echo "错误：未能提取 VPN 网关地址。以下是诊断信息："
            nmcli device show "$VPN_IF" 2>/dev/null | grep -E 'IP4|DHCP4' || true
            ip -4 addr show dev "$VPN_IF" || true
            ip route show default || true
            exit 1
        fi
        echo "    提取到 VPN 网关: $VPN_DEFAULT_GW"

        echo ">>> 清理可能残留的默认路由（正常情况下不应再出现）..."
        ip route del default via "$VPN_DEFAULT_GW" dev "$VPN_IF" 2>/dev/null && \
            echo "    已删除残留默认路由" || echo "    无默认路由，跳过"

        echo ">>> 添加静态路由..."
        for net in "${TARGET_NET[@]}"; do
            if ip route show "$net" 2>/dev/null | grep -q "$net"; then
                echo "    [$net] 已存在，跳过"
            else
                ip route add "$net" via "$VPN_DEFAULT_GW" dev "$VPN_IF"
                echo "    [$net] 已添加"
            fi
        done

        echo ">>> 连接完成。当前 $VPN_IF 状态："
        ip addr show "$VPN_IF" | grep -E "inet |state" || true
        echo ""
        echo ">>> 当前相关路由："
        ip route | grep -E "$VPN_IF|${TARGET_NET[*]// /|}" || true
        ;;

    disconnect|d)
        echo ">>> 断开账户: $ACCOUNT_NAME"
        "$VPN_DIR/vpncmd" localhost /CLIENT /CMD AccountDisconnect "$ACCOUNT_NAME" || true

        echo ">>> 清理静态路由..."
        for net in "${TARGET_NET[@]}"; do
            ip route del "$net" dev "$VPN_IF" 2>/dev/null && \
                echo "    [$net] 已删除" || echo "    [$net] 未找到，跳过"
        done

        echo ">>> 停用 NetworkManager 连接..."
        if nmcli -t -f NAME connection show | grep -qx "$NM_CON_NAME"; then
            nmcli connection down "$NM_CON_NAME" &>/dev/null || true
            echo "    已停用: $NM_CON_NAME"
        fi

        echo ">>> 停止 VPN Client 后台服务..."
        "$VPN_DIR/vpnclient" stop || true

        echo ">>> 断开完成"
        ;;
esac
