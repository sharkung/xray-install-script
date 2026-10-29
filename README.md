# Xray 安装脚本（Debian 13 amd64）

此仓库提供面向 **Debian 13 amd64** 的 Xray 安装脚本，配置 **VLESS + REALITY + Vision**，并生成客户端 JSON、VLESS 分享链接和二维码 PNG。

> **重要：**脚本会下载并执行 XTLS 官方安装脚本、安装系统软件包、修改 Xray 主配置和 systemd drop-in，并重启 Xray 服务。请先阅读脚本，确认有 VPS 控制台或其他恢复途径，再运行。脚本不会替你修改云服务商安全组。

## 功能

- 检查系统为 Debian 13、架构为 amd64，并要求以 root 身份运行。
- 使用 XTLS 官方安装脚本安装/更新 Xray-core。
- 交互式输入服务器公网 IPv4/IPv6 或域名、监听端口、REALITY target 域名。
- 生成 UUID、REALITY 密钥和 16 位十六进制 short ID。
- 生成 VLESS + REALITY + Vision 服务端配置与客户端 Xray JSON。
- 在替换现有配置前验证新服务端配置；备份现有配置和 systemd drop-in。
- 重启并检查 `xray.service`；配置阶段失败时尝试恢复原配置。
- 生成 VLESS 分享链接与 PNG 二维码。

## 系统要求

- Debian GNU/Linux 13
- amd64（x86_64）
- root 权限
- 能访问 Debian 软件源和 XTLS 官方安装脚本地址
- VPS 云防火墙/安全组及系统防火墙允许所选 TCP 端口
- REALITY target 应是你确认可用、支持合适 TLS 握手的域名；不要盲目复制示例域名

## 安装与运行

在 VPS 上执行：

```bash
sudo apt-get update
sudo apt-get install -y ca-certificates curl
curl -fL --retry 3 \
  'https://raw.githubusercontent.com/sharkung/xray-install-script/refs/heads/main/xray-debian13.sh' \
  -o xray-debian13.sh
bash -n xray-debian13.sh
chmod 700 xray-debian13.sh
sudo bash ./xray-debian13.sh
```

脚本会要求输入：

1. **服务器公网 IP 或域名**：客户端实际连接的地址；IPv6 可直接填写，不要加方括号。
2. **监听端口**：默认 `8443`。选择其他端口时，确保它未被占用并在防火墙中放行 TCP。
3. **REALITY target 域名**：只填写域名，不包含协议、端口或路径。脚本使用该域名的 `:443` 作为 target，并把它写入服务端 `serverNames` 和客户端 SNI。
4. 输入大写 `YES` 确认继续。

## 生成文件

| 文件 | 用途 | 权限 |
|---|---|---:|
| `/usr/local/etc/xray/config.json` | Xray 服务端配置，包含 REALITY 私钥 | 由脚本按服务运行用户设置 |
| `/root/xray-client.json` | 完整 Xray 客户端 JSON | `600` |
| `/root/xray-client-info.txt` | 节点参数摘要 | `600` |
| `/root/xray-vless.txt` | 单行 `vless://` 分享链接 | `600` |
| `/root/xray-vless-qr.png` | 分享链接二维码 PNG | `600` |
| `/root/xray-backup.XXXXXX/` | 安装前备份目录（实际名称带随机后缀） | `700` |

这些文件包含或关联连接凭据。不要把客户端 JSON、分享链接、二维码、UUID、REALITY 私钥或 short ID 上传到公开仓库、截图或公开聊天中。分享链接和二维码等同于连接凭据，应按密码管理。

## 客户端导入

- **支持导入 Xray JSON 的客户端**：安全地把 `/root/xray-client.json` 复制到客户端设备后导入。该 JSON 包含本地 SOCKS 代理 `127.0.0.1:10808` 和 HTTP 代理 `127.0.0.1:10809`。
- **支持 VLESS 分享链接/二维码的客户端**：通过受保护的方式读取 `/root/xray-vless.txt`，或将 `/root/xray-vless-qr.png` 传到自己的设备后扫描。
- 不要把客户端 JSON 与服务端 `/usr/local/etc/xray/config.json` 混用；服务端配置包含 REALITY 私钥，客户端不应持有该私钥。

## 验证

```bash
systemctl is-active xray
systemctl status xray --no-pager -l
journalctl -u xray -n 80 --no-pager
/usr/local/bin/xray run -test -config /usr/local/etc/xray/config.json
file /root/xray-vless-qr.png
python3 -m json.tool /root/xray-client.json >/dev/null && echo '客户端 JSON 格式正确'
```

如果 Xray 二进制安装在其他位置，请用 `command -v xray` 或 `systemctl cat xray` 确认实际路径，再替换上面的 `/usr/local/bin/xray`。

检查监听端口（将 `8443` 换成实际端口）：

```bash
ss -lntp | grep ':8443'
```

还需在云服务商控制台确认安全组允许该端口的 **TCP 入站**；如果启用了 UFW/nftables 等防火墙，也要按自己的规则放行。脚本不会自动更改这些规则。

## 故障排查

```bash
systemctl status xray --no-pager -l
journalctl -u xray -n 100 --no-pager
systemctl cat xray
```

如果脚本在切换配置后启动失败，会尝试恢复安装前备份的配置和 drop-in，并尝试重启服务。请查看脚本输出中给出的备份目录；不要删除备份，直到确认服务正常。

如果服务能启动但客户端无法连接，依次核对：

- 客户端地址、端口、UUID 与分享链接是否来自同一次安装；
- 客户端 REALITY 的 SNI、`password`/公钥、short ID、指纹是否匹配；
- 云安全组与系统防火墙是否允许 TCP 端口；
- 服务器时间、DNS 解析和 REALITY target 的可达性；
- 服务日志是否报告端口占用或配置错误。

## 安全与限制

- 仅在你拥有或获授权管理的服务器上运行。
- 执行前建议先创建 VPS 快照，并确保有控制台或救援方式。
- 脚本会通过网络下载并执行官方安装器；请在运行前检查脚本和下载源。
- 该脚本会替换 `/usr/local/etc/xray/config.json` 的内容，并写入 `/etc/systemd/system/xray.service.d/20-reality-config.conf`。若你已有自定义 Xray 配置或其他 drop-in，请先自行备份并审阅。
- 不会自动调整云安全组、系统防火墙、BBR 或内核参数。
- 不承诺绕过网络限制、特定线路速度或任何 target 域名的可用性。

## 参考文档

- [Project X 官方文档](https://xtls.github.io/)
- [VLESS 入站配置](https://xtls.github.io/config/inbounds/vless.html)
- [VLESS 出站配置](https://xtls.github.io/config/outbounds/vless.html)
- [REALITY 配置](https://xtls.github.io/config/transports/reality.html)
- [Xray-install 官方仓库](https://github.com/XTLS/Xray-install)
