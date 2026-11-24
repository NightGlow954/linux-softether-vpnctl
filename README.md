# vpnctl.sh

一个用于在 Linux 上管理 [SoftEther VPN Client](https://www.softether.org/) 连接的 Bash 控制脚本，自用为主。

它对 `vpncmd` 的账户管理命令做了简单封装，并在连接成功后通过 NetworkManager + `ip route` 自动完成虚拟网卡配置：**只屏蔽 VPN 默认路由**，SoftEther 下发的其他路由照常接受，再按需为指定网段添加静态路由，实现分流。

## 功能特性

- 自动 `sudo` 提权，服务未启动时自动拉起 `vpnclient`
- 列出、新增、导入、删除 VPN 连接账户
- 一键连接 / 断开，自动配置 TAP 模式虚拟网卡并通过 DHCP 获取地址
- 连接后只屏蔽 DHCP 默认路由，SoftEther 下发的其他路由照常接受，实现分流
- 断开时自动清理静态路由、停用 NetworkManager 连接并停止后台服务

## 依赖环境

- Bash
- SoftEther VPN Client，默认安装于 `/opt/vpnclient`（脚本使用 `$VPN_DIR/vpnclient` 和 `$VPN_DIR/vpncmd`）
- NetworkManager 及其命令行工具 `nmcli`
- `iproute2`（`ip` 命令）
- `sudo`、`grep`、`awk`、`sed`、`tr`、`head`、`pgrep`

## 安装与使用

将脚本放到任意目录并赋予执行权限：

```bash
chmod +x vpnctl.sh
```

建议放到 `/usr/local/bin` 等 PATH 目录，或直接用相对/绝对路径调用。脚本会自动检测 root 权限并通过 `sudo` 重新执行自身。

## 命令用法

| 命令 | 说明 |
| --- | --- |
| `./vpnctl.sh` | 列出所有 VPN 账户，并显示帮助 |
| `./vpnctl.sh add <连接名> <地址:端口> <Hub名>` | 新建连接，交互式输入用户名和密码 |
| `./vpnctl.sh import <配置文件路径>` | 导入 SoftEther 连接设置文件 |
| `./vpnctl.sh del <连接名>` | 删除指定连接（`delete` 亦可） |
| `./vpnctl.sh <账户名> connect` | 连接账户并完成网卡、路由配置（`c` 亦可） |
| `./vpnctl.sh <账户名> disconnect` | 断开账户并清理路由、停止服务（`d` 亦可） |

示例：

```bash
# 新建连接
./vpnctl.sh add myvpn vpn.example.com:443 VPN

# 连接（自动配置路由）
./vpnctl.sh myvpn connect

# 断开
./vpnctl.sh myvpn disconnect
```

## 配置

使用前请根据实际环境修改脚本开头的变量：

```bash
VPN_DIR="/opt/vpnclient"        # SoftEther VPN Client 安装目录
VPN_IF="vpn_1"                  # 虚拟网卡名称
NM_CON_NAME="vpn-dhcp-$VPN_IF"  # NetworkManager 连接名
TARGET_NET=(                    # 需要走 VPN 的目标网段（分流路由）
    "10.10.0.0/16"
)
```

如需让全部流量走 VPN，可清空 `TARGET_NET` 并自行调整“屏蔽默认路由”相关逻辑；如需多网段分流，在 `TARGET_NET` 数组中继续添加即可。

## 连接流程说明

执行 `<账户名> connect` 时脚本会依次：

1. 调用 `vpncmd AccountConnect` 建立连接并等待隧道就绪
2. 清理该虚拟网卡上由 NetworkManager 自动生成的连接
3. 新建 TAP 模式 tun 连接，使用 DHCP 自动获取 IPv4、禁用 IPv6、开启自动连接
4. 从 DHCP 原始选项（`DHCP4.OPTION` 中的 `routers`）中提取 VPN 网关
5. 通过连接配置 `ipv4.never-default yes` **只屏蔽 DHCP 下发的默认路由**；SoftEther 下发的其他路由（网段路由）照常接受，并清理可能残留的默认路由
6. 为 `TARGET_NET` 中的每个网段添加经该网关的静态路由

> **为什么不用单纯的 `ip route del default`？** 因为 NetworkManager 会在 DHCP 续租（T1/T2）、连接重协商或配置重应用时把 DHCP 下发的默认路由重新写回，事后删除治标不治本。`ipv4.never-default yes` 从源头抑制了这种行为，同时保留 DHCP 下发的其他路由。
>
> 注意**不要用** `ipv4.ignore-auto-routes yes`：它会把 DHCP 下发的全部自动路由都丢弃，不符合“只忽略默认路由、接受其他路由”的需求。
>
> **网关提取**：屏蔽默认路由后，`IP4.GATEWAY` 在部分 NetworkManager 版本中会为空，因此脚本按 `DHCP4.OPTION` 中的 `routers` → NetworkManager/dhclient 租约文件 → 路由表 → 临时恢复默认路由后重取 的顺序依次尝试，取到后再恢复屏蔽。

### 路由策略

| 路由来源 | 处理方式 |
| --- | --- |
| DHCP 下发的默认路由（`0.0.0.0/0`） | 由 `ipv4.never-default yes` 屏蔽，不进入路由表，DHCP 续租时也不会写回 |
| SoftEther 下发的其他路由（网段路由） | 照常接受，由 NetworkManager 自动安装 |
| `TARGET_NET` 中配置的网段 | 脚本通过 `ip route add` 手动添加静态路由，下一跳为 DHCP 网关 |

连接完成后可用以下命令验证：

```bash
ip route show default dev vpn_1      # 应为空
ip route show dev vpn_1              # 可看到 SoftEther 下发的路由与手动添加的静态路由
nmcli -g DHCP4.OPTION device show vpn_1 | tr '|' '\n' | grep routers   # DHCP 网关
```

`disconnect` 则会反向清理静态路由、停用 NetworkManager 连接并停止 `vpnclient` 服务。

## 注意事项

- `add` 命令目前以明文方式回显密码输入，且密码会作为命令行参数传给 `vpncmd`；在共享主机或会被记录命令行参数的环境中请留意隐私风险。
- 脚本假设虚拟网卡名为 `vpn_1`，如你的环境不同请修改 `VPN_IF`。
- `disconnect` 会停止 `vpnclient` 后台服务，如果你希望服务常驻，可移除脚本末尾的 `vpnclient stop`。
- 本脚本面向个人 Linux 自用场景，未做多平台与异常场景的完整适配，使用前请按需调整。

## License

MIT.
