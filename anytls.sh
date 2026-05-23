#!/bin/bash

# 定义全局变量
CONFIG_FILE="/etc/sing-box/config.json"
INFO_FILE="/root/.sb_info.json"
TLS_DIR="/etc/sing-box/anytls/tls"
SERVICE_NAME="sing-box"

# 定义颜色代码 (修复了引号转义问题)
RED='\033[0;31m'
GREEN='\033[0;32m'
RESET_COLOR='\033[0m'

# 检查是否以 Root 权限运行
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}错误: 需要 Root 权限才能运行此脚本。${RESET_COLOR}"
    exit 1
fi

# -------------------------------------------------------------------
# 函数定义
# -------------------------------------------------------------------

function dep() {
    echo -e "${GREEN}正在安装依赖和 Sing-box...${RESET_COLOR}"
    rm -f /etc/sing-box/client_info.json
    apt update -y
    apt install -y curl jq net-tools openssl
    curl -fsSL https://sing-box.app/install.sh | sh -s -- --beta
    echo -e "${GREEN}依赖和 Sing-box 安装完成。${RESET_COLOR}"
}

function chk() {
    [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

function occ() {
    netstat -tuln | grep -q ":$1 "
}

function ip() {
    local i=$(curl -s4 ifconfig.me)
    [[ -z "$i" ]] && i=$(curl -s6 ifconfig.me)
    echo "$i"
}

function gen() {
    mkdir -p "$TLS_DIR"
    echo -e "${GREEN}正在生成 TLS 证书 (CN=$1)...${RESET_COLOR}"
    openssl req -x509 -nodes -newkey ec:<(openssl ecparam -name prime256v1) \
        -keyout "$TLS_DIR/server.key" -out "$TLS_DIR/server.crt" \
        -subj "/CN=$1" -days 3650 2>/dev/null
    echo -e "${GREEN}TLS 证书生成完成。${RESET_COLOR}"
}

function inst() {
    dep
    echo -e "${GREEN}请选择配置模式:${RESET_COLOR}"
    echo -e "${GREEN}1. 仅 AnyReality${RESET_COLOR}"
    echo -e "${GREEN}2. 仅 AnyTLS${RESET_COLOR}"
    echo -e "${GREEN}3. 双协议 (AnyReality + AnyTLS)${RESET_COLOR}"
    read -p "选择: " m

    local inbound_config="[]"
    local client_info="{}"

    if [[ "$m" == "1" || "$m" == "3" ]]; then
        echo -e "\n${GREEN}正在配置 AnyReality...${RESET_COLOR}"
        local reality_port reality_password reality_sni reality_private_key reality_public_key reality_short_id

        while :; do
            read -p "请输入 AnyReality 端口 (默认: 1443): " reality_port
            reality_port=${reality_port:-1443}
            chk "$reality_port" || { echo -e "${RED}错误: 端口号不合法。${RESET_COLOR}"; continue; }
            occ "$reality_port" && { echo -e "${RED}错误: 端口 $reality_port 已被占用。${RESET_COLOR}"; continue; }
            break
        done

        read -p "请输入 AnyReality 密码 (默认: 随机生成): " reality_password
        [[ -z "$reality_password" ]] && reality_password=$(openssl rand -hex 16)

        read -p "请输入 Reality 域名 (默认: genshin.hoyoverse.com): " reality_sni
        reality_sni=${reality_sni:-genshin.hoyoverse.com}

        local keypair=$(/usr/bin/sing-box generate reality-keypair)
        reality_private_key=$(echo "$keypair" | grep Private | awk '{print $2}')
        reality_public_key=$(echo "$keypair" | grep Public | awk '{print $2}')
        reality_short_id=$(openssl rand -hex 8)

        # 使用更稳健的方式构建 JSON，避免 Bash 解析括号冲突
        local reality_inbound_json=$(jq -n \
            --arg p "$reality_port" \
            --arg w "$reality_password" \
            --arg s "$reality_sni" \
            --arg k "$reality_private_key" \
            --arg id "$reality_short_id" \
            '{
                type: "anytls",
                listen: "::",
                listen_port: ($p|tonumber),
                users: [{name: "user", password: $w}],
                padding_scheme: ["stop=8","0=30-30","1=100-400","2=400-500,c,500-1000,c,500-1000,c,500-1000,c,500-1000","3=9-9,500-1000","4=500-1000","5=500-1000","6=500-1000","7=500-1000"],
                tls: {
                    enabled: true,
                    server_name: $s,
                    reality: {
                        enabled: true,
                        handshake: {server: $s, server_port: 443},
                        private_key: $k,
                        short_id: [$id]
                    }
                }
            }')
        inbound_config=$(echo "$inbound_config" | jq --argjson new "$reality_inbound_json" '. + [$new]')
        client_info=$(echo "$client_info" | jq --arg p "$reality_port" --arg w "$reality_password" --arg s "$reality_sni" --arg pk "$reality_public_key" --arg id "$reality_short_id" '. + {reality:{port:$p,pwd:$w,sni:$s,pk:$pk,id:$id}}')
    fi

    if [[ "$m" == "2" || "$m" == "3" ]]; then
        echo -e "\n${GREEN}正在配置 AnyTLS...${RESET_COLOR}"
        local anytls_port anytls_password anytls_sni

        while :; do
            read -p "请输入 AnyTLS 端口 (默认: 2026): " anytls_port
            anytls_port=${anytls_port:-2026}
            chk "$anytls_port" || { echo -e "${RED}错误: 端口号不合法。${RESET_COLOR}"; continue; }
            [[ "$m" == "3" && "$anytls_port" == "$reality_port" ]] && { echo -e "${RED}错误: 端口重复。${RESET_COLOR}"; continue; }
            occ "$anytls_port" && { echo -e "${RED}错误: 端口 $anytls_port 已被占用。${RESET_COLOR}"; continue; }
            break
        done

        read -p "请输入 AnyTLS 密码 (默认: 随机生成): " anytls_password
        [[ -z "$anytls_password" ]] && anytls_password=$(openssl rand -hex 16)

        read -p "请输入 TLS 域名 (默认: genshin.hoyoverse.com): " anytls_sni
        anytls_sni=${anytls_sni:-genshin.hoyoverse.com}

        gen "$anytls_sni"

        local anytls_inbound_json=$(jq -n \
            --arg p "$anytls_port" \
            --arg w "$anytls_password" \
            --arg cert "$TLS_DIR/server.crt" \
            --arg key "$TLS_DIR/server.key" \
            '{
                type: "anytls",
                listen: "::",
                listen_port: ($p|tonumber),
                users: [{password: $w}],
                padding_scheme: ["stop=6","0=23-23","1=50-200","2=330-400,c,500-600,c,700-750,c,780-790,c,800-1200","3=1-1,2800-998","4=670-1800","5=340-600"],
                tls: {
                    enabled: true,
                    certificate_path: $cert,
                    key_path: $key
                }
            }')
        inbound_config=$(echo "$inbound_config" | jq --argjson new "$anytls_inbound_json" '. + [$new]')
        client_info=$(echo "$client_info" | jq --arg p "$anytls_port" --arg w "$anytls_password" --arg s "$anytls_sni" '. + {anytls:{port:$p,pwd:$w,sni:$s}}')
    fi

    echo "$client_info" > "$INFO_FILE"
    jq -n --argjson ib "$inbound_config" '{log: {level: "info", timestamp: true}, inbounds: $ib}' > "$CONFIG_FILE"

    systemctl daemon-reload
    systemctl enable "$SERVICE_NAME"
    systemctl restart "$SERVICE_NAME"
    echo -e "${GREEN}Sing-box 服务已配置并启动。${RESET_COLOR}"
    link
}

function link() {
    [[ ! -f "$INFO_FILE" ]] && { echo -e "${RED}错误: 配置文件不存在。${RESET_COLOR}"; return 1; }
    local server_ip=$(ip)
    if jq -e .reality "$INFO_FILE" >/dev/null; then
        local p=$(jq -r .reality.port "$INFO_FILE")
        local w=$(jq -r .reality.pwd "$INFO_FILE")
        local s=$(jq -r .reality.sni "$INFO_FILE")
        local k=$(jq -r .reality.pk "$INFO_FILE")
        local d=$(jq -r .reality.id "$INFO_FILE")
        echo -e "\n${GREEN}[AnyReality]:${RESET_COLOR} anytls://${w}@${server_ip}:${p}/?sni=${s}&fp=chrome&pbk=${k}&sid=${d}#AnyReality_${server_ip}"
    fi
    if jq -e .anytls "$INFO_FILE" >/dev/null; then
        local p=$(jq -r .anytls.port "$INFO_FILE")
        local w=$(jq -r .anytls.pwd "$INFO_FILE")
        local s=$(jq -r .anytls.sni "$INFO_FILE")
        echo -e "\n${GREEN}[AnyTLS]:${RESET_COLOR} anytls://${w}@${server_ip}:${p}/?sni=${s}&insecure=1#AnyTLS_${server_ip}"
    fi
    echo ""
}

function uninst() {
    echo -e "${GREEN}正在卸载...${RESET_COLOR}"
    systemctl stop "$SERVICE_NAME"
    systemctl disable "$SERVICE_NAME"
    rm -f "/etc/systemd/system/$SERVICE_NAME.service" "/usr/bin/$SERVICE_NAME" "/usr/local/bin/$SERVICE_NAME" "$INFO_FILE"
    rm -rf "/etc/$SERVICE_NAME" "/etc/sing-box/anytls"
    systemctl daemon-reload
    echo -e "${GREEN}卸载完成。${RESET_COLOR}"
}

function menu() {
    echo -e "\n${GREEN}Sing-box 管理菜单${RESET_COLOR}"
    echo -e "1. 安装 2. 管理 3. 链接 4. 状态 5. 日志 6. 卸载 0. 退出"
    read -p "选择: " choice
    case "$choice" in
        1) inst ;;
        2) read -p "1.启动 2.停止 3.重启: " a; [[ $a == 1 ]] && systemctl start "$SERVICE_NAME"; [[ $a == 2 ]] && systemctl stop "$SERVICE_NAME"; [[ $a == 3 ]] && systemctl restart "$SERVICE_NAME" ;;
        3) link ;;
        4) systemctl status "$SERVICE_NAME" ;;
        5) journalctl -u "$SERVICE_NAME" -e ;;
        6) uninst ;;
        0) exit 0 ;;
        *) echo -e "${RED}无效选择${RESET_COLOR}" ;;
    esac
}

while :; do menu; done
