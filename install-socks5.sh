#!/usr/bin/env bash
set -Eeuo pipefail

# sing-box SOCKS5 一键安装脚本
# 支持 Alpine Linux (OpenRC) 和 Ubuntu (systemd)
# 默认端口：10999
# 支持 TCP 和 UDP

PORT=10999
CONFIG_DIR=/etc/sing-box
CONFIG_FILE="${CONFIG_DIR}/config.json"
BIN_DIR=/usr/local/bin
BIN="${BIN_DIR}/sing-box"
SERVICE_NAME=sing-box

say()  { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[-]\033[0m %s\n' "$*" >&2; exit 1; }

[[ "$(id -u)" -eq 0 ]] || die "请使用 root 权限运行此脚本。"

# 检测操作系统
if [[ -r /etc/os-release ]]; then
    . /etc/os-release
else
    die "无法识别操作系统。"
fi

case "${ID:-}" in
    alpine)
        OS=alpine
        ;;
    ubuntu)
        OS=ubuntu
        ;;
    *)
        die "暂不支持此系统：${ID:-unknown}。仅支持 Alpine Linux 和 Ubuntu。"
        ;;
esac

ARCH="$(uname -m)"
case "$ARCH" in
    x86_64|amd64) ARCH=amd64 ;;
    aarch64|arm64) ARCH=arm64 ;;
    *) die "暂不支持 CPU 架构：$ARCH" ;;
esac

say "系统：$PRETTY_NAME"
say "架构：$ARCH"

# 检查是否已有配置，避免重复覆盖
if [[ -e "$CONFIG_FILE" ]]; then
    warn "发现现有配置：$CONFIG_FILE"
    read -r -p "是否备份现有配置并重新安装？[y/N] " answer
    case "$answer" in
        y|Y|yes|YES)
            cp -p "$CONFIG_FILE" \
                "${CONFIG_FILE}.backup.$(date +%Y%m%d%H%M%S)"
            ;;
        *)
            die "已取消，未修改现有配置。"
            ;;
    esac
fi

# 检查并安装依赖
say "安装必要依赖……"

if [[ "$OS" == alpine ]]; then
    apk add --no-cache curl tar ca-certificates
else
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y curl tar ca-certificates
fi

# 检查端口是否已经被占用
if command -v ss >/dev/null 2>&1; then
    if ss -H -lntu | awk '{print $5}' |
        grep -Eq "(^|[.:])${PORT}$"; then
        die "端口 $PORT 已被占用，请先检查现有服务。"
    fi
fi

# 获取 sing-box 最新稳定版信息
say "获取 sing-box 官方发行版本……"

API_URL="https://api.github.com/repos/SagerNet/sing-box/releases/latest"

RELEASE_JSON="$(curl -fsSL --retry 3 "$API_URL")" ||
    die "无法获取 GitHub Release 信息，请检查网络。"

# 从 GitHub Release 的 assets 中选择对应架构的 musl 或 Linux 压缩包
ASSET_URL="$(
    printf '%s' "$RELEASE_JSON" |
    grep -oE '"browser_download_url"[[:space:]]*:[[:space:]]*"[^"]+"' |
    sed -E 's/^[^"]*"([^"]+)"$/\1/' |
    grep -E "/sing-box-[^/]+-linux-${ARCH}(-musl)?\.tar\.gz$" |
    head -n 1 || true
)"

[[ -n "$ASSET_URL" ]] ||
    die "没有找到适用于 Linux ${ARCH} 的官方压缩包。"

say "下载：$ASSET_URL"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

curl -fL --retry 3 "$ASSET_URL" -o "$TMP_DIR/sing-box.tar.gz"
tar -xzf "$TMP_DIR/sing-box.tar.gz" -C "$TMP_DIR"

NEW_BIN="$(find "$TMP_DIR" -type f -name sing-box -perm /111 | head -n 1)"
[[ -n "$NEW_BIN" ]] || die "压缩包中没有找到可执行文件。"

install -d -m 755 "$BIN_DIR"
install -m 755 "$NEW_BIN" "$BIN"

say "已安装：$("$BIN" version | head -n 1)"

# 交互式输入 SOCKS5 用户名
while true; do
    read -r -p "请输入 SOCKS5 用户名（3-64 个字符，仅限字母、数字、._-）： " USERNAME
    if [[ "$USERNAME" =~ ^[A-Za-z0-9._-]{3,64}$ ]]; then
        break
    fi
    warn "用户名格式不正确。"
done

# 交互式输入密码，不回显
while true; do
    read -r -s -p "请输入 SOCKS5 密码（至少 16 个字符）： " PASSWORD
    printf '\n'
    [[ ${#PASSWORD} -ge 16 ]] && break
    warn "密码至少需要 16 个字符，请重新输入。"
done

while true; do
    read -r -s -p "请再次输入密码： " PASSWORD2
    printf '\n'
    [[ "$PASSWORD" == "$PASSWORD2" ]] && break
    warn "两次密码不一致，请重新输入。"
done

# 生成 JSON 配置时使用 Python 正确转义字符串
if ! command -v python3 >/dev/null 2>&1; then
    if [[ "$OS" == alpine ]]; then
        apk add --no-cache python3
    else
        apt-get install -y python3
    fi
fi

install -d -m 700 "$CONFIG_DIR"

USERNAME="$USERNAME" PASSWORD="$PASSWORD" PORT="$PORT" \
python3 - "$CONFIG_FILE" <<'PY'
import json
import os
import sys

path = sys.argv[1]

config = {
    "log": {
        "level": "info"
    },
    "inbounds": [
        {
            "type": "socks",
            "tag": "socks-in",
            "listen": "0.0.0.0",
            "listen_port": int(os.environ["PORT"]),
            "users": [
                {
                    "username": os.environ["USERNAME"],
                    "password": os.environ["PASSWORD"]
                }
            ]
        }
    ],
    "outbounds": [
        {
            "type": "direct",
            "tag": "direct"
        }
    ]
}

with open(path, "w", encoding="utf-8") as f:
    json.dump(config, f, indent=2)
    f.write("\n")

os.chmod(path, 0o600)
PY

unset PASSWORD PASSWORD2

# 创建对应系统的服务
if [[ "$OS" == alpine ]]; then
    say "配置 OpenRC 服务……"

    cat > /etc/init.d/sing-box <<'EOF'
#!/sbin/openrc-run

description="sing-box SOCKS5 Proxy"
command="/usr/local/bin/sing-box"
command_args="run -c /etc/sing-box/config.json"
command_background="yes"
pidfile="/run/${RC_SVCNAME}.pid"
output_log="/var/log/sing-box.log"
error_log="/var/log/sing-box.err"

depend() {
    need net
}
EOF

    chmod 755 /etc/init.d/sing-box
else
    say "配置 systemd 服务……"

    cat > /etc/systemd/system/sing-box.service <<'EOF'
[Unit]
Description=sing-box SOCKS5 Proxy
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/sing-box run -c /etc/sing-box/config.json
Restart=on-failure
RestartSec=3
User=root
LimitNOFILE=1048576
NoNewPrivileges=true
ProtectHome=true
ProtectSystem=full
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF
fi

# 检查配置
say "检查 sing-box 配置……"
"$BIN" check -c "$CONFIG_FILE" ||
    die "配置检查失败，请检查 $CONFIG_FILE"

# 启动服务并设置开机启动
if [[ "$OS" == alpine ]]; then
    rc-update add sing-box default
    rc-service sing-box restart || rc-service sing-box start
else
    systemctl daemon-reload
    systemctl enable --now sing-box
fi

# 检查服务状态
say "检查服务状态……"

if [[ "$OS" == alpine ]]; then
    rc-service sing-box status ||
        die "服务启动失败，请查看 /var/log/sing-box.err"
else
    systemctl --no-pager --full status sing-box ||
        die "服务启动失败，请使用 journalctl -u sing-box 查看日志"
fi

say "安装完成！"
printf '\n'
printf 'SOCKS5 地址：服务器公网 IP:%s\n' "$PORT"
printf '用户名：%s\n' "$USERNAME"
printf '密码：已设置（不会显示）\n'
printf 'TCP/UDP：SOCKS 入站已配置；UDP 需实际测试\n'
printf '\n'
printf '请在云服务商防火墙中按需放行 TCP 和 UDP 端口 %s。\n' "$PORT"
printf '建议仅允许可信客户端 IP 访问代理端口。\n'
