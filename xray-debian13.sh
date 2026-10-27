
#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

# Debian 13 amd64: Xray-core + VLESS + REALITY + Vision
# 使用 XTLS 官方安装脚本；不覆盖官方 service 主文件。

readonly CONFIG_DIR="/usr/local/etc/xray"
readonly CONFIG_FILE="${CONFIG_DIR}/config.json"
readonly DROPIN_DIR="/etc/systemd/system/xray.service.d"
readonly DROPIN_FILE="${DROPIN_DIR}/20-reality-config.conf"
readonly CLIENT_FILE="/root/xray-client.json"
readonly INFO_FILE="/root/xray-client-info.txt"

die() {
    echo "错误：$*" >&2
    exit 1
}

[[ $EUID -eq 0 ]] || die "请使用 root 运行：sudo bash xray-debian13.sh"

. /etc/os-release
[[ "${ID:-}" == "debian" && "${VERSION_ID:-}" == "13" ]] \
    || die "此脚本仅针对 Debian 13。"

[[ "$(dpkg --print-architecture)" == "amd64" ]] \
    || die "此脚本仅针对 amd64。"

command -v apt-get >/dev/null || die "找不到 apt-get"

echo "==> 安装必要工具"
apt-get update
apt-get install -y curl ca-certificates unzip python3

echo
echo "==> 填写服务器参数"

read -r -p "服务器公网 IP 或域名: " SERVER_ADDRESS
[[ -n "$SERVER_ADDRESS" ]] || die "服务器地址不能为空"
[[ "$SERVER_ADDRESS" != *[[:space:]]* ]] || die "地址不能包含空格"

read -r -p "监听端口 [8443]: " SERVER_PORT
SERVER_PORT="${SERVER_PORT:-8443}"
[[ "$SERVER_PORT" =~ ^[0-9]+$ ]] \
    && (( SERVER_PORT >= 1 && SERVER_PORT <= 65535 )) \
    || die "端口必须在 1-65535 之间"

read -r -p "REALITY target 域名（例如 www.example.com）: " TARGET_DOMAIN
[[ -n "$TARGET_DOMAIN" ]] || die "target 域名不能为空"
[[ "$TARGET_DOMAIN" != *[[:space:]]* ]] || die "域名不能包含空格"
[[ "$TARGET_DOMAIN" != *:* ]] || die "这里只填域名，不要附加端口"

TARGET_PORT=443
TARGET="${TARGET_DOMAIN}:${TARGET_PORT}"

echo
echo "服务器地址：${SERVER_ADDRESS}"
echo "监听端口：${SERVER_PORT}"
echo "REALITY target：${TARGET}"
echo
echo "注意：请确认目标域名可正常进行 TLS 握手，"
echo "并确认所选端口未被其他服务占用。"

read -r -p "确认继续安装？输入 YES: " CONFIRM
[[ "$CONFIRM" == "YES" ]] || die "用户取消安装"

echo
echo "==> 下载并执行 XTLS 官方安装脚本"

INSTALLER="$(mktemp)"
trap 'rm -f "$INSTALLER"' EXIT

curl -fL --retry 3 \
    https://github.com/XTLS/Xray-install/raw/main/install-release.sh \
    -o "$INSTALLER"

bash "$INSTALLER"

echo
echo "==> 定位 Xray 实际可执行文件"

XRAY_BIN=""

CANDIDATE="$(command -v xray 2>/dev/null || true)"
if [[ -n "$CANDIDATE" ]]; then
    CANDIDATE="$(readlink -f "$CANDIDATE" 2>/dev/null || true)"
    if [[ -n "$CANDIDATE" && -f "$CANDIDATE" && -x "$CANDIDATE" ]]; then
        XRAY_BIN="$CANDIDATE"
    fi
fi

if [[ -z "$XRAY_BIN" ]]; then
    for CANDIDATE in \
        /usr/local/bin/xray \
        /usr/local/bin/xray/xray \
        /usr/local/sbin/xray \
        /usr/bin/xray
    do
        if [[ -f "$CANDIDATE" && -x "$CANDIDATE" ]]; then
            XRAY_BIN="$(readlink -f "$CANDIDATE")"
            break
        fi
    done
fi

[[ -n "$XRAY_BIN" && -x "$XRAY_BIN" ]] \
    || die "安装后没有找到可执行的 Xray，请检查官方安装日志"

echo "Xray 二进制：$XRAY_BIN"
"$XRAY_BIN" version

echo
echo "==> 检查官方 systemd 服务"

systemctl cat xray >/dev/null 2>&1 \
    || die "官方安装后未找到 xray.service，请先检查安装日志"

echo
echo "==> 生成新的 UUID 和 REALITY 密钥"

UUID="$("$XRAY_BIN" uuid)"
KEY_OUTPUT="$("$XRAY_BIN" x25519)"

# 兼容官方命令输出中的常见标签格式。
PRIVATE_KEY="$(
    printf '%s\n' "$KEY_OUTPUT" |
    sed -nE 's/^[[:space:]]*PrivateKey:[[:space:]]*//p' |
    head -n 1
)"

PUBLIC_KEY="$(
    printf '%s\n' "$KEY_OUTPUT" |
    sed -nE 's/^[[:space:]]*Password \(PublicKey\):[[:space:]]*//p' |
    head -n 1
)"

[[ -n "$PRIVATE_KEY" && -n "$PUBLIC_KEY" ]] || {
    echo "无法从 xray x25519 输出识别密钥字段。" >&2
    echo "请检查以下命令的输出格式：" >&2
    echo "$XRAY_BIN x25519" >&2
    exit 1
}

SHORT_ID="$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')"
[[ "$SHORT_ID" =~ ^[0-9a-f]{16}$ ]] || die "shortId 生成失败"

echo "UUID 和密钥已生成（不在终端输出私钥）"

echo
echo "==> 生成服务端配置"

mkdir -p "$CONFIG_DIR"
chmod 755 "$CONFIG_DIR"

TMP_CONFIG="$(mktemp "${CONFIG_DIR}/.config.XXXXXX.json")"
TMP_CLIENT="$(mktemp /root/.xray-client.XXXXXX.json)"

export UUID SERVER_PORT TARGET TARGET_DOMAIN PRIVATE_KEY SHORT_ID
export SERVER_ADDRESS PUBLIC_KEY

python3 - "$TMP_CONFIG" "$TMP_CLIENT" <<'PY'
import json
import os
import sys

server_path, client_path = sys.argv[1:3]

uuid = os.environ["UUID"]
port = int(os.environ["SERVER_PORT"])
target = os.environ["TARGET"]
target_domain = os.environ["TARGET_DOMAIN"]
private_key = os.environ["PRIVATE_KEY"]
short_id = os.environ["SHORT_ID"]
server_address = os.environ["SERVER_ADDRESS"]
public_key = os.environ["PUBLIC_KEY"]

server = {
    "log": {
        "loglevel": "warning"
    },
    "inbounds": [
        {
            "listen": "0.0.0.0",
            "port": port,
            "protocol": "vless",
            "settings": {
                "clients": [
                    {
                        "id": uuid,
                        "flow": "xtls-rprx-vision"
                    }
                ],
                "decryption": "none"
            },
            "streamSettings": {
                "network": "raw",
                "security": "reality",
                "realitySettings": {
                    "show": False,
                    "target": target,
                    "xver": 0,
                    "serverNames": [target_domain],
                    "privateKey": private_key,
                    "shortIds": [short_id]
                }
            }
        }
    ],
    "outbounds": [
        {
            "protocol": "freedom",
            "tag": "direct"
        }
    ]
}

client = {
    "log": {
        "loglevel": "warning"
    },
    "inbounds": [
        {
            "listen": "127.0.0.1",
            "port": 10808,
            "protocol": "socks",
            "settings": {
                "auth": "noauth",
                "udp": True
            }
        },
        {
            "listen": "127.0.0.1",
            "port": 10809,
            "protocol": "http",
            "settings": {}
        }
    ],
    "outbounds": [
        {
            "protocol": "vless",
            "tag": "proxy",
            "settings": {
                "vnext": [
                    {
                        "address": server_address,
                        "port": port,
                        "users": [
                            {
                                "id": uuid,
                                "encryption": "none",
                                "flow": "xtls-rprx-vision"
                            }
                        ]
                    }
                ]
            },
            "streamSettings": {
                "network": "raw",
                "security": "reality",
                "realitySettings": {
                    "serverName": target_domain,
                    "fingerprint": "chrome",
                    "password": public_key,
                    "shortId": short_id,
                    "spiderX": "/"
                }
            }
        },
        {
            "protocol": "freedom",
            "tag": "direct"
        },
        {
            "protocol": "blackhole",
            "tag": "block"
        }
    ]
}

for path, data in ((server_path, server), (client_path, client)):
    with open(path, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)
        f.write("\n")
PY

chmod 600 "$TMP_CONFIG" "$TMP_CLIENT"

echo
echo "==> 校验服务端配置"

if ! "$XRAY_BIN" run -test -config "$TMP_CONFIG"; then
    rm -f "$TMP_CONFIG" "$TMP_CLIENT"
    die "服务端配置校验失败；未替换现有配置"
fi

echo
echo "==> 安装服务端配置并设置权限"

SERVICE_USER="$(systemctl show -p User --value xray)"
SERVICE_GROUP="$(systemctl show -p Group --value xray)"

if [[ -z "$SERVICE_USER" || "$SERVICE_USER" == "root" ]]; then
    chown root:root "$TMP_CONFIG"
    chmod 600 "$TMP_CONFIG"
else
    [[ -n "$SERVICE_GROUP" ]] || SERVICE_GROUP="$(id -gn "$SERVICE_USER")"
    getent group "$SERVICE_GROUP" >/dev/null \
        || die "systemd 服务组不存在：$SERVICE_GROUP"
    chown "root:${SERVICE_GROUP}" "$TMP_CONFIG"
    chmod 640 "$TMP_CONFIG"
fi

install -o "$(stat -c '%U' "$TMP_CONFIG")" \
    -g "$(stat -c '%G' "$TMP_CONFIG")" \
    -m "$(stat -c '%a' "$TMP_CONFIG")" \
    "$TMP_CONFIG" "$CONFIG_FILE"

rm -f "$TMP_CONFIG"

echo
echo "==> 修复服务启动路径（新增独立 drop-in）"

mkdir -p "$DROPIN_DIR"

cat > "$DROPIN_FILE" <<EOF
[Service]
ExecStart=
ExecStart=${XRAY_BIN} run -config ${CONFIG_FILE}
EOF

chmod 644 "$DROPIN_FILE"

systemctl daemon-reload

echo
echo "==> 启动 Xray 服务"

if ! systemctl enable xray; then
    echo "警告：systemctl enable 失败，请检查服务状态。" >&2
fi

if ! systemctl restart xray; then
    systemctl status xray --no-pager -l || true
    journalctl -u xray -n 60 --no-pager || true
    die "Xray 启动失败，请根据日志排查"
fi

if ! systemctl is-active --quiet xray; then
    systemctl status xray --no-pager -l || true
    journalctl -u xray -n 60 --no-pager || true
    die "Xray 未处于 active 状态"
fi

echo
echo "==> 保存客户端配置"

install -o root -g root -m 600 "$TMP_CLIENT" "$CLIENT_FILE"
rm -f "$TMP_CLIENT"

cat > "$INFO_FILE" <<EOF
Xray VLESS + REALITY + Vision

服务器地址: ${SERVER_ADDRESS}
服务器端口: ${SERVER_PORT}
UUID: ${UUID}
传输方式: raw
安全方式: reality
SNI: ${TARGET_DOMAIN}
指纹: chrome
Short ID: ${SHORT_ID}

客户端 JSON: ${CLIENT_FILE}
注意：REALITY 私钥不应分享；客户端文件也属于敏感配置。
EOF

chmod 600 "$INFO_FILE"

echo
echo "========================================"
echo "安装及启动完成"
echo "========================================"
echo "服务状态："
systemctl --no-pager --full status xray || true
echo
echo "客户端配置：$CLIENT_FILE"
echo "节点信息：  $INFO_FILE"
echo
echo "请安全地取出客户端 JSON，并导入支持当前 Xray-core"
echo "配置格式的客户端。不要公开分享服务器私钥。"
echo
echo "请确认 VPS 防火墙和 Debian 防火墙已允许 TCP ${SERVER_PORT}。"
