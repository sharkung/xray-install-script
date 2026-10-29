#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

# Debian 13 amd64:Xray-core + VLESS + REALITY + Vision
# 使用 XTLS 官方安装脚本；通过独立 systemd drop-in 配置启动参数。

readonly CONFIG_DIR="/usr/local/etc/xray"
readonly CONFIG_FILE="${CONFIG_DIR}/config.json"
readonly DROPIN_DIR="/etc/systemd/system/xray.service.d"
readonly DROPIN_FILE="${DROPIN_DIR}/20-reality-config.conf"
readonly CLIENT_FILE="/root/xray-client.json"
readonly INFO_FILE="/root/xray-client-info.txt"
readonly LINK_FILE="/root/xray-vless.txt"
readonly QR_FILE="/root/xray-vless-qr.png"

INSTALLER=""
TMP_CONFIG=""
TMP_CLIENT=""
TMP_LINK=""
TMP_QR=""
BACKUP_DIR=""
CONFIG_CHANGED=0
HAD_CONFIG=0
HAD_DROPIN=0

die() {
    printf '错误：%s\n' "$*" >&2
    exit 1
}

cleanup() {
    local rc=$?
    trap - EXIT

    [[ -z "$INSTALLER" ]] || rm -f -- "$INSTALLER"
    [[ -z "$TMP_CONFIG" ]] || rm -f -- "$TMP_CONFIG"
    [[ -z "$TMP_CLIENT" ]] || rm -f -- "$TMP_CLIENT"
    [[ -z "$TMP_LINK" ]] || rm -f -- "$TMP_LINK"
    [[ -z "$TMP_QR" ]] || rm -f -- "$TMP_QR"

    # 仅在配置替换后、服务尚未成功启动时尝试恢复旧配置。
    if (( rc != 0 && CONFIG_CHANGED == 1 )); then
        echo "检测到配置阶段失败，正在尝试恢复原配置……" >&2

        if (( HAD_CONFIG == 1 )); then
            cp -a -- "${BACKUP_DIR}/config.json" "$CONFIG_FILE" || true
        else
            rm -f -- "$CONFIG_FILE"
        fi

        if (( HAD_DROPIN == 1 )); then
            cp -a -- "${BACKUP_DIR}/20-reality-config.conf" "$DROPIN_FILE" || true
        else
            rm -f -- "$DROPIN_FILE"
        fi

        systemctl daemon-reload || true
        systemctl restart xray || {
            echo "警告：恢复后 Xray 未能重启，请检查 systemctl status xray。" >&2
        }
        echo "原配置恢复尝试已完成。备份目录：${BACKUP_DIR}" >&2
    fi

    exit "$rc"
}
trap cleanup EXIT

[[ $EUID -eq 0 ]] || die "请使用 root 运行：sudo bash xray-debian13.sh"

[[ -r /etc/os-release ]] || die "找不到 /etc/os-release"
# shellcheck disable=SC1091
. /etc/os-release

[[ "${ID:-}" == "debian" && "${VERSION_ID:-}" == "13" ]] \
    || die "此脚本仅针对 Debian 13。"

[[ "$(dpkg --print-architecture)" == "amd64" ]] \
    || die "此脚本仅针对 amd64。"

command -v apt-get >/dev/null 2>&1 || die "找不到 apt-get"

echo "==> 安装必要工具"
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y \
    curl ca-certificates unzip python3 qrencode

echo
echo "==> 填写服务器参数"

read -r -p "服务器公网 IP 或域名: " SERVER_ADDRESS
[[ -n "$SERVER_ADDRESS" ]] || die "服务器地址不能为空"
[[ "$SERVER_ADDRESS" != *[[:space:]]* ]] || die "服务器地址不能包含空白字符"
[[ "$SERVER_ADDRESS" != *'/'* && "$SERVER_ADDRESS" != *'?'* && "$SERVER_ADDRESS" != *'#'* ]] \
    || die "服务器地址不能包含 /、? 或 #"

read -r -p "监听端口 [8443]: " SERVER_PORT
SERVER_PORT="${SERVER_PORT:-8443}"
[[ "$SERVER_PORT" =~ ^[0-9]+$ ]] \
    && (( SERVER_PORT >= 1 && SERVER_PORT <= 65535 )) \
    || die "端口必须在 1-65535 之间"

read -r -p "REALITY target 域名（例如 www.example.com): " TARGET_DOMAIN
[[ -n "$TARGET_DOMAIN" ]] || die "target 域名不能为空"
[[ "$TARGET_DOMAIN" != *[[:space:]]* ]] || die "target 域名不能包含空白字符"
[[ "$TARGET_DOMAIN" != *:* && "$TARGET_DOMAIN" != *'/'* && "$TARGET_DOMAIN" != *'?'* && "$TARGET_DOMAIN" != *'#'* ]] \
    || die "这里只填域名，不要附加端口或路径"
[[ "$TARGET_DOMAIN" =~ ^[A-Za-z0-9.-]+$ ]] || die "target 域名格式不正确"

TARGET="${TARGET_DOMAIN}:443"

echo
printf '服务器地址：%s\n' "$SERVER_ADDRESS"
printf '监听端口：%s\n' "$SERVER_PORT"
printf 'REALITY target:%s\n' "$TARGET"
echo
echo "注意：请确认 target 域名支持合适的 TLS 握手，且监听端口未被占用。"
echo "本脚本会替换 Xray 主配置，并新增或更新独立 systemd drop-in。"

read -r -p "确认继续安装？输入 YES: " CONFIRM
[[ "$CONFIRM" == "YES" ]] || die "用户取消安装"

echo
echo "==> 下载并执行 XTLS 官方安装脚本"

INSTALLER="$(mktemp)"
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

printf 'Xray 二进制：%s\n' "$XRAY_BIN"
"$XRAY_BIN" version

echo
echo "==> 检查官方 systemd 服务"
systemctl cat xray >/dev/null 2>&1 \
    || die "官方安装后未找到 xray.service，请检查安装日志"

echo
echo "==> 生成 UUID 和 REALITY 密钥"

UUID="$("$XRAY_BIN" uuid)"
[[ -n "$UUID" ]] || die "UUID 生成失败"

KEY_OUTPUT="$("$XRAY_BIN" x25519)" || die "Xray REALITY 密钥生成失败"

# 支持常见 Xray 输出标签；若无法识别则停止，不继续生成不完整配置。
KEYS="$(
    printf '%s\n' "$KEY_OUTPUT" |
    python3 -c '
import re
import sys

fields = {}
for line in sys.stdin.read().splitlines():
    match = re.match(r"^\s*([^:]+):\s*(\S+)\s*$", line)
    if not match:
        continue
    label = re.sub(r"[^a-z]", "", match.group(1).lower())
    value = match.group(2)

    if label in ("privatekey", "private"):
        fields["private"] = value
    elif label in ("passwordpublickey", "publickey", "public", "password"):
        fields["public"] = value

if not fields.get("private") or not fields.get("public"):
    sys.exit(1)

print(fields["private"])
print(fields["public"])
'
)" || die "无法识别 xray x25519 输出格式；请单独检查 xray x25519 的输出标签"

PRIVATE_KEY="$(printf '%s\n' "$KEYS" | sed -n '1p')"
PUBLIC_KEY="$(printf '%s\n' "$KEYS" | sed -n '2p')"
[[ -n "$PRIVATE_KEY" && -n "$PUBLIC_KEY" ]] || die "REALITY 密钥解析失败"

SHORT_ID="$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')"
[[ "$SHORT_ID" =~ ^[0-9a-f]{16}$ ]] || die "shortId 生成失败"

echo "UUID 和密钥已生成；不会主动在终端显示密钥。"

echo
echo "==> 生成服务端和客户端配置"

install -d -m 755 "$CONFIG_DIR"
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
    "log": {"loglevel": "warning"},
    "inbounds": [{
        "listen": "0.0.0.0",
        "port": port,
        "protocol": "vless",
        "settings": {
            "clients": [{"id": uuid, "flow": "xtls-rprx-vision"}],
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
    }],
    "outbounds": [{"protocol": "freedom", "tag": "direct"}]
}

client = {
    "log": {"loglevel": "warning"},
    "inbounds": [
        {
            "listen": "127.0.0.1",
            "port": 10808,
            "protocol": "socks",
            "settings": {"auth": "noauth", "udp": True}
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
                "vnext": [{
                    "address": server_address,
                    "port": port,
                    "users": [{
                        "id": uuid,
                        "encryption": "none",
                        "flow": "xtls-rprx-vision"
                    }]
                }]
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
        {"protocol": "freedom", "tag": "direct"},
        {"protocol": "blackhole", "tag": "block"}
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
"$XRAY_BIN" run -test -config "$TMP_CONFIG" \
    || die "服务端配置校验失败；现有服务端配置尚未替换"

echo
echo "==> 生成 VLESS 分享链接和二维码"

VLESS_LINK="$(
python3 - "$UUID" "$SERVER_ADDRESS" "$SERVER_PORT" \
    "$TARGET_DOMAIN" "$PUBLIC_KEY" "$SHORT_ID" <<'PY'
import ipaddress
import sys
from urllib.parse import urlencode, quote

uuid, address, port, sni, pbk, sid = sys.argv[1:]

# IPv6 节点地址必须使用方括号；普通 IPv4/域名不需要。
try:
    parsed = ipaddress.ip_address(address)
    if parsed.version == 6:
        address = f"[{address}]"
except ValueError:
    if ":" in address:
        raise SystemExit("服务器地址不是有效的 IPv4、IPv6 或域名")

params = urlencode({
    "encryption": "none",
    "flow": "xtls-rprx-vision",
    "security": "reality",
    "sni": sni,
    "fp": "chrome",
    "pbk": pbk,
    "sid": sid,
    "type": "raw",
    "spx": "/"
})
print(
    f"vless://{uuid}@{address}:{port}?{params}"
    f"#{quote('Debian13-REALITY-Vision', safe='')}"
)
PY
)" || die "VLESS 分享链接生成失败"

# 先写入临时文件，服务启动成功后再安装到最终路径。
TMP_LINK="$(mktemp /root/.xray-vless.XXXXXX.txt)"
TMP_QR="$(mktemp /root/.xray-vless-qr.XXXXXX.png)"
printf '%s\n' "$VLESS_LINK" > "$TMP_LINK"
chmod 600 "$TMP_LINK"

qrencode -t PNG -o "$TMP_QR" -s 8 -m 2 "$VLESS_LINK"
chmod 600 "$TMP_QR"

python3 - "$TMP_QR" <<'PY'
import sys
with open(sys.argv[1], "rb") as f:
    signature = f.read(8)
if signature != b"\x89PNG\r\n\x1a\n":
    raise SystemExit("二维码 PNG 文件头校验失败")
PY

echo
echo "==> 备份现有配置并安装新配置"

BACKUP_DIR="$(mktemp -d /root/xray-backup.XXXXXX)"
chmod 700 "$BACKUP_DIR"

if [[ -f "$CONFIG_FILE" ]]; then
    cp -a -- "$CONFIG_FILE" "${BACKUP_DIR}/config.json"
    HAD_CONFIG=1
fi

if [[ -f "$DROPIN_FILE" ]]; then
    cp -a -- "$DROPIN_FILE" "${BACKUP_DIR}/20-reality-config.conf"
    HAD_DROPIN=1
fi

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
    "$TMP_CONFIG" "${CONFIG_FILE}.new"
mv -f -- "${CONFIG_FILE}.new" "$CONFIG_FILE"
rm -f -- "$TMP_CONFIG"
TMP_CONFIG=""

CONFIG_CHANGED=1
install -d -m 755 "$DROPIN_DIR"

cat > "$DROPIN_FILE" <<EOF
[Service]
ExecStart=
ExecStart="${XRAY_BIN}" run -config "${CONFIG_FILE}"
EOF
chmod 644 "$DROPIN_FILE"

systemctl daemon-reload

echo
echo "==> 启动 Xray 服务"

systemctl enable xray || echo "警告：systemctl enable 失败，请检查服务状态。" >&2

if ! systemctl restart xray; then
    systemctl status xray --no-pager -l || true
    journalctl -u xray -n 60 --no-pager || true
    die "Xray 启动失败；脚本将尝试恢复旧配置"
fi

if ! systemctl is-active --quiet xray; then
    systemctl status xray --no-pager -l || true
    journalctl -u xray -n 60 --no-pager || true
    die "Xray 未处于 active 状态；脚本将尝试恢复旧配置"
fi

# 到这里服务端配置已成功启动，不再因后续文件输出问题自动回滚服务配置。
CONFIG_CHANGED=0

echo
echo "==> 保存客户端文件、分享链接和二维码"

install -o root -g root -m 600 "$TMP_CLIENT" "$CLIENT_FILE"
rm -f -- "$TMP_CLIENT"
TMP_CLIENT=""

install -o root -g root -m 600 "$TMP_LINK" "$LINK_FILE"
install -o root -g root -m 600 "$TMP_QR" "$QR_FILE"
rm -f -- "$TMP_LINK" "$TMP_QR"

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
VLESS 分享链接: ${LINK_FILE}
二维码图片: ${QR_FILE}

注意：不要公开分享服务器 REALITY 私钥或完整客户端配置。
EOF
chmod 600 "$INFO_FILE"

echo
echo "========================================"
echo "安装及启动完成"
echo "========================================"
systemctl --no-pager --full status xray || true
echo
printf '客户端 JSON:%s\n' "$CLIENT_FILE"
printf '节点信息：%s\n' "$INFO_FILE"
printf '分享链接：%s\n' "$LINK_FILE"
printf '二维码图片：%s\n' "$QR_FILE"
printf '备份目录：%s\n' "$BACKUP_DIR"
echo
echo "请确认 VPS 安全组和 Debian 防火墙已允许 TCP ${SERVER_PORT}。"
echo "二维码和分享链接包含节点连接凭据，请妥善保管。"
