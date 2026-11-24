#!/bin/bash
# SoftEther VPN Client 连接/断开控制脚本
# Version 1.0
# 用法:
#   ./vpn-ctl.sh                      # 列出所有账户
#   ./vpn-ctl.sh <账户名> connect     # 连接（简写 c）
#   ./vpn-ctl.sh <账户名> disconnect  # 断开（简写 d）

set -e

VPN_DIR="/opt/vpnclient"
VPN_IF="vpn_1"

# 需要走 VPN 的目标网段（可多个）
TARGET_NET=(
    "10.10.0.0/16"
)

# ===== 自动提权：非 root 时用 sudo 重新执行自己 =====
if [ "$(id -u)" -ne 0 ]; then
    # echo ">>> 当前非 root，使用 sudo 提权运行..."
    exec sudo "$0" "$@"
fi

# ===== 检查 VPN 后台服务，未运行则启动（所有操作前统一执行）=====
if pgrep -x "vpnclient" >/dev/null 2>&1; then
    echo ">>> VPN Client 服务已在运行"
else
    echo ">>> VPN Client 服务未运行，正在启动..."
    "$VPN_DIR/vpnclient" start
    sleep 1
fi

# 无参数：列出账户
if [ $# -eq 0 ]; then
    echo ">>> 当前 VPN 账户列表："
    "$VPN_DIR/vpncmd" localhost /CLIENT /CMD AccountList
    echo ""
    echo "用法："
    echo "  ./vpn-ctl.sh <账户名> connect|c      # 连接"
    echo "  ./vpn-ctl.sh <账户名> disconnect|d   # 断开"
    exit 0
fi

# 参数不足
if [ $# -lt 2 ]; then
    echo "错误：参数不足。"
    echo "用法：./vpn-ctl.sh <账户名> {connect|disconnect|c|d}"
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

        echo ">>> 通过 dhcpcd 获取 IP..."
        # dhcpcd "$VPN_IF" || true
        dhcpcd -C resolv.conf "$VPN_IF" || true

        echo ">>> 从默认路由中提取 VPN 网关..."
        VPN_DEFAULT_GW=$(ip route show default dev "$VPN_IF" 2>/dev/null | awk '/via/ {for(i=1;i<=NF;i++) if($i=="via") print $(i+1); exit}')

        if [ -z "$VPN_DEFAULT_GW" ]; then
            echo "错误：未能从 $VPN_IF 的默认路由中提取网关地址。"
            echo "当前默认路由："
            ip route show default || true
            exit 1
        fi
        echo "    提取到 VPN 网关: $VPN_DEFAULT_GW"

        echo ">>> 删除 DHCP 自动添加的默认路由..."
        ip route del default via "$VPN_DEFAULT_GW" dev "$VPN_IF" 2>/dev/null && \
            echo "    已删除默认路由 $VPN_DEFAULT_GW dev $VPN_IF" || \
            echo "    未找到该默认路由，跳过"

        echo ">>> 添加静态路由..."
        for net in "${TARGET_NET[@]}"; do
            if ip route show "$net" | grep -q "$net"; then
                echo "    [$net] 已存在，跳过"
            else
                ip route add "$net" via "$VPN_DEFAULT_GW" dev "$VPN_IF"
                echo "    [$net] 已添加 via $VPN_DEFAULT_GW dev $VPN_IF"
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
            # 断开时网关可能已不可知，用 ip route del 匹配目标网段和网卡即可
            ip route del "$net" dev "$VPN_IF" 2>/dev/null && \
                echo "    [$net] 已删除" || \
                echo "    [$net] 未找到，跳过"
        done

        echo ">>> 释放 dhcpcd 租约..."
        dhcpcd -k "$VPN_IF" 2>/dev/null || true

        echo ">>> 停止 VPN Client 后台服务..."
        "$VPN_DIR/vpnclient" stop || true

        echo ">>> 断开完成"
        ;;
esac

