#!/usr/bin/env bash
# =============================================================================
# sdns - SmartDNS 一键部署管理脚本 (Debian 12/13)
# 架构: 单文件 + 函数模块化 + 依赖管理 + 状态检测
# =============================================================================

set -euo pipefail

# ---------- 全局变量 ----------
readonly SCRIPT_NAME="sdns"
readonly SCRIPT_PATH="${BASH_SOURCE[0]}"
readonly INSTALL_BIN="/usr/local/bin/sdns"
readonly SMARTDNS_CONF="/etc/smartdns/smartdns.conf"
readonly SMARTDNS_LOG_DIR="/var/log/smartdns"
readonly SMARTDNS_LOG="/var/log/smartdns/smartdns.log"
readonly RESOLV_BAK="/etc/resolv.conf.sdns.bak"
readonly LOGROTATE_CONF="/etc/logrotate.d/smartdns"
readonly DEFAULT_VERSION="48.4"
readonly WORK_DIR="/tmp/sdns-build"
readonly SYSTEMD_OVERRIDE_DIR="/etc/systemd/system/smartdns.service.d"

# 依赖声明: 命令名:包名:必需性
readonly DEPENDENCIES=(
    "curl:curl:required"
    "dig:bind9-dnsutils:optional"
)

# ---------- 颜色输出 ----------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# =============================================================================
# 公共函数
# =============================================================================

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "请以 root 权限运行此脚本 (sudo sdns)"
        exit 1
    fi
}

check_debian12() {
    if [[ ! -f /etc/debian_version ]]; then
        log_error "此脚本仅支持 Debian 系统"
        exit 1
    fi
    local ver
    ver=$(cat /etc/debian_version | cut -d. -f1)
    if [[ "$ver" != "12" ]]; then
        log_warn "当前 Debian 版本为 $ver，脚本针对 Debian 12 优化，继续可能存在问题"
        local ans=""
        read -rp "是否继续? [y/N]: " ans || true
        if [[ "${ans,,}" != "y" ]]; then
            exit 1
        fi
    fi
}

detect_arch() {
    local arch
    arch=$(uname -m)
    case "$arch" in
        x86_64)  echo "x86_64" ;;
        aarch64) echo "aarch64" ;;
        armv7l)  echo "arm" ;;
        *)       log_error "不支持的架构: $arch"; exit 1 ;;
    esac
}

# =============================================================================
# 依赖管理模块
# =============================================================================

check_command() {
    command -v "$1" &>/dev/null
}

detect_missing_deps() {
    local entry cmd pkg req
    for entry in "${DEPENDENCIES[@]}"; do
        IFS=':' read -r cmd pkg req <<< "$entry"
        if ! check_command "$cmd"; then
            echo "${cmd}:${pkg}:${req}"
        fi
    done
}

install_deps() {
    local missing_required=()
    local missing_optional=()
    local line cmd pkg req

    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        IFS=':' read -r cmd pkg req <<< "$line"
        if [[ "$req" == "required" ]]; then
            missing_required+=("$pkg")
        else
            missing_optional+=("$pkg")
        fi
    done < <(detect_missing_deps)

    if [[ ${#missing_optional[@]} -gt 0 ]]; then
        log_warn "可选依赖未安装: ${missing_optional[*]} (不影响核心功能，安装后可获得更精确的解析检测)"
    fi

    if [[ ${#missing_required[@]} -eq 0 ]]; then
        log_info "必需依赖已满足"
        return 0
    fi

    log_warn "检测到缺失的必需依赖: ${missing_required[*]}"
    log_info "正在通过 apt 安装..."

    if ! DEBIAN_FRONTEND=noninteractive apt-get update -qq 2>/dev/null; then
        log_warn "apt update 失败，尝试使用已有缓存继续安装"
    fi

    if ! DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${missing_required[@]}" 2>/dev/null; then
        log_error "依赖安装失败，请手动执行: apt-get install -y ${missing_required[*]}"
        return 1
    fi

    local pkg_name
    for pkg_name in "${missing_required[@]}"; do
        local cmd_name=""
        local entry
        for entry in "${DEPENDENCIES[@]}"; do
            if [[ "${entry}" == *":${pkg_name}:"* ]]; then
                IFS=':' read -r cmd_name _ _ <<< "$entry"
                break
            fi
        done
        if [[ -n "$cmd_name" ]] && ! check_command "$cmd_name"; then
            log_error "依赖 $pkg_name 安装后命令 $cmd_name 仍不可用"
            return 1
        fi
    done

    log_info "必需依赖安装完成"
    return 0
}

ensure_dependencies() {
    log_info "检查脚本运行依赖..."
    if ! install_deps; then
        log_error "依赖检查未通过，脚本退出"
        exit 1
    fi
}

# =============================================================================
# 状态检测模块
# =============================================================================

check_service_status() {
    if ! systemctl list-unit-files smartdns.service &>/dev/null; then
        echo "not-installed"
        return
    fi
    systemctl is-active smartdns 2>/dev/null || echo "inactive"
}

check_port_listen() {
    if ss -lnptu 2>/dev/null | grep -q ':53 '; then
        echo "yes"
    else
        echo "no"
    fi
}

check_dns_resolve() {
    if command -v dig &>/dev/null; then
        local result
        result=$(dig @127.0.0.1 baidu.com +short +time=2 +tries=1 2>/dev/null | head -1 || true)
        [[ -n "$result" ]] && echo "yes" || echo "no"
    else
        getent hosts baidu.com &>/dev/null && echo "yes" || echo "no"
    fi
}

check_resolv_config() {
    grep -q 'nameserver 127.0.0.1' /etc/resolv.conf 2>/dev/null && echo "yes" || echo "no"
}

get_uptime() {
    local active_since
    active_since=$(systemctl show smartdns --property=ActiveEnterTimestamp 2>/dev/null | cut -d= -f2 || true)
    if [[ -z "$active_since" || "$active_since" == "n/a" ]]; then
        echo "未知"
        return
    fi
    local since_epoch now_epoch diff
    since_epoch=$(date -d "$active_since" +%s 2>/dev/null || echo 0)
    now_epoch=$(date +%s)
    diff=$((now_epoch - since_epoch))
    if [[ $diff -lt 0 ]]; then
        echo "未知"
    elif [[ $diff -lt 3600 ]]; then
        echo "$((diff / 60))分钟"
    elif [[ $diff -lt 86400 ]]; then
        echo "$((diff / 3600))小时$(( (diff % 3600) / 60 ))分钟"
    else
        echo "$((diff / 86400))天$(( (diff % 86400) / 3600 ))小时"
    fi
}

check_recent_errors() {
    [[ -f "$SMARTDNS_LOG" ]] || { echo "0"; return; }
    tail -n 200 "$SMARTDNS_LOG" 2>/dev/null | grep -ci 'error\|fail' 2>/dev/null || echo "0"
}

status_summary() {
    local svc port dns resolv uptime
    svc=$(check_service_status)

    if [[ "$svc" == "not-installed" ]]; then
        echo -e " 状态: ${YELLOW}未安装${NC}"
        return
    fi

    port=$(check_port_listen)
    dns=$(check_dns_resolve)
    resolv=$(check_resolv_config)
    uptime=$(get_uptime)

    local svc_display svc_color
    case "$svc" in
        active)   svc_display="运行中"; svc_color="$GREEN" ;;
        failed)   svc_display="失败";   svc_color="$RED" ;;
        *)        svc_display="$svc";   svc_color="$YELLOW" ;;
    esac

    local port_display dns_display resolv_display
    [[ "$port" == "yes" ]] && port_display="${GREEN}✓${NC}" || port_display="${RED}✗${NC}"
    [[ "$dns" == "yes" ]] && dns_display="${GREEN}✓${NC}" || dns_display="${RED}✗${NC}"
    [[ "$resolv" == "yes" ]] && resolv_display="${GREEN}✓${NC}" || resolv_display="${RED}✗${NC}"

    echo -e " 状态: ${svc_color}${svc_display}${NC} | 53端口:${port_display} | 解析:${dns_display} | 接管:${resolv_display}"
    echo -e " 运行时长: ${uptime}"
}

show_detail_status() {
    echo ""
    echo "=========================================="
    echo "       SmartDNS 详细状态"
    echo "=========================================="

    local svc
    svc=$(check_service_status)

    if [[ "$svc" == "not-installed" ]]; then
        log_warn "SmartDNS 尚未安装"
        echo "=========================================="
        return
    fi

    echo " 服务状态: $svc"
    echo " 运行时长: $(get_uptime)"

    local pid
    pid=$(systemctl show smartdns --property=MainPID 2>/dev/null | cut -d= -f2 || echo "N/A")
    echo " 主进程 PID: $pid"
    echo ""

    echo " 监听端口:"
    ss -lnptu 2>/dev/null | grep ':53 ' | head -3 || echo "   (无 53 端口监听)"
    echo ""

    echo " resolv.conf:"
    grep 'nameserver' /etc/resolv.conf 2>/dev/null | head -3 || echo "   (无法读取)"
    echo ""

    echo " DNS 解析测试:"
    if command -v dig &>/dev/null; then
        local dig_result dig_time
        dig_result=$(dig @127.0.0.1 baidu.com +short +time=2 +tries=1 2>/dev/null | head -1 || true)
        dig_time=$(dig @127.0.0.1 baidu.com +time=2 +tries=1 2>/dev/null | grep -oP 'Query time: \K[0-9]+' || echo "?")
        if [[ -n "$dig_result" ]]; then
            echo "   baidu.com -> $dig_result (${dig_time}ms)"
        else
            echo "   ${RED}解析失败${NC}"
        fi
    else
        if getent hosts baidu.com &>/dev/null; then
            echo "   baidu.com -> 解析成功 (getent)"
        else
            echo "   ${RED}解析失败${NC}"
        fi
        log_warn "安装 bind9-dnsutils 可获得更精确的解析检测"
    fi
    echo ""

    echo "------------------------------------------"
    local err_count
    err_count=$(check_recent_errors)
    echo " 最近 200 行日志错误数: $err_count"
    if [[ "$err_count" -gt 0 ]] && [[ -f "$SMARTDNS_LOG" ]]; then
        echo " 最近错误示例:"
        tail -n 200 "$SMARTDNS_LOG" 2>/dev/null | grep -i 'error\|fail' | tail -3 | sed 's/^/   /'
    fi
    echo "=========================================="
}

# =============================================================================
# 端口处理模块
# =============================================================================

check_port53() {
    ss -lnptu 2>/dev/null | grep -q ':53 '
}

handle_port53() {
    log_info "检查 53 端口占用情况..."
    if ! check_port53; then
        log_info "53 端口空闲，无需处理"
        return 0
    fi

    # 优先通过 systemctl 判断 systemd-resolved 服务状态，避免 ss 进程名截断问题
    if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
        log_warn "检测到 systemd-resolved 占用 53 端口，正在停止并禁用..."
        systemctl disable --now systemd-resolved 2>/dev/null || true
        sleep 1
        if check_port53; then
            log_error "停止 systemd-resolved 后 53 端口仍被占用"
            ss -lnptu | grep ':53 '
            return 1
        fi
        log_info "systemd-resolved 已停止，53 端口释放"
    else
        log_error "53 端口被其他进程占用:"
        ss -lnptu | grep ':53 '
        log_error "请手动处理后再运行安装"
        return 1
    fi
}

# =============================================================================
# 安装模块
# =============================================================================

install_smartdns() {
    local version="$1"
    local arch
    arch=$(detect_arch)
    local pkg_name="smartdns.${version}.${arch}-linux-all.tar.gz"
    local download_url="https://github.com/pymumu/smartdns/releases/download/Release${version}/${pkg_name}"

    log_info "准备安装 SmartDNS 版本: $version (架构: $arch)"
    handle_port53 || return 1

    rm -rf "$WORK_DIR"
    mkdir -p "$WORK_DIR"
    cd "$WORK_DIR"

    log_info "下载: $download_url"
    if ! curl -fL --retry 3 -o "$pkg_name" "$download_url"; then
        log_error "下载失败，请检查版本号 $version 是否存在"
        cd /; rm -rf "$WORK_DIR"
        return 1
    fi

    tar zxf "$pkg_name"
    cd smartdns
    chmod +x ./install
    log_info "执行 SmartDNS 安装程序..."
    ./install -i

    cd /; rm -rf "$WORK_DIR"

    mkdir -p "$SYSTEMD_OVERRIDE_DIR"
    cat > "${SYSTEMD_OVERRIDE_DIR}/restart.conf" <<'EOF'
[Service]
Restart=on-failure
RestartSec=5
EOF

    systemctl daemon-reload
    log_info "SmartDNS $version 安装完成，已配置自动重启"
}

# =============================================================================
# 配置模块
# =============================================================================

generate_config() {
    log_info "生成 SmartDNS 配置..."
    mkdir -p "$SMARTDNS_LOG_DIR"

    cat > "$SMARTDNS_CONF" <<'EOF'
# ============================================
# SmartDNS 配置 - 由 sdns 脚本生成
# ============================================

log-level info
log-file /var/log/smartdns/smartdns.log
log-size 10M
log-num 2

cache-size 32768
cache-persist yes
prefetch-domain yes
serve-expired yes
serve-expired-ttl 259200
serve-expired-reply-ttl 30
rr-ttl-min 600

speed-check-mode ping,tcp:80,tcp:443

server-tls 8.8.8.8:853 -group encrypted
server-tls 1.1.1.1:853 -group encrypted
server-https https://dns.google/dns-query -group encrypted
server-https https://cloudflare-dns.com/dns-query -group encrypted

server 223.5.5.5 -group domestic -exclude-default-group
server 119.29.29.29 -group domestic -exclude-default-group

server 223.5.5.5 -bootstrap-dns
EOF

    log_info "配置已写入: $SMARTDNS_CONF"
}

# =============================================================================
# 接管模块
# =============================================================================

takeover_dns() {
    log_info "接管系统 DNS..."

    if [[ ! -f "$RESOLV_BAK" ]]; then
        # -L 跟随符号链接复制实际内容
        cp -L /etc/resolv.conf "$RESOLV_BAK" 2>/dev/null || cp /etc/resolv.conf "$RESOLV_BAK"
        log_info "已备份 /etc/resolv.conf -> $RESOLV_BAK"
    else
        log_warn "备份已存在，跳过: $RESOLV_BAK"
    fi

    # 若为符号链接（Debian 13 常见），先移除再写入普通文件
    if [[ -L /etc/resolv.conf ]]; then
        rm -f /etc/resolv.conf
    fi
    echo "nameserver 127.0.0.1" > /etc/resolv.conf

    systemctl daemon-reload
    systemctl enable smartdns
    systemctl restart smartdns

    sleep 1
    if systemctl is-active --quiet smartdns; then
        log_info "SmartDNS 已启动并接管系统 DNS"
    else
        log_error "SmartDNS 启动失败，请检查: journalctl -u smartdns -n 20"
        return 1
    fi
}

# =============================================================================
# 日志轮转模块
# =============================================================================

setup_logrotate() {
    log_info "配置日志轮转 (保留 30 天)..."
    cat > "$LOGROTATE_CONF" <<'EOF'
/var/log/smartdns/*.log {
    daily
    rotate 30
    missingok
    notifempty
    compress
    delaycompress
    copytruncate
    create 644 root root
}
EOF
    log_info "logrotate 配置已写入: $LOGROTATE_CONF"
}

# =============================================================================
# 卸载模块
# =============================================================================

uninstall_all() {
    log_warn "即将卸载 SmartDNS 并恢复系统 DNS"
    local ans=""
    read -rp "确认卸载? [y/N]: " ans || true
    if [[ "${ans,,}" != "y" ]]; then
        return 0
    fi

    systemctl stop smartdns 2>/dev/null || true
    systemctl disable smartdns 2>/dev/null || true

    if [[ -f /usr/sbin/smartdns ]]; then
        /usr/sbin/smartdns -u 2>/dev/null || true
    fi
    if [[ -f /usr/lib/smartdns/install ]]; then
        /usr/lib/smartdns/install -u 2>/dev/null || true
    fi
    rm -f /usr/sbin/smartdns /usr/bin/smartdns 2>/dev/null || true
    rm -f /etc/systemd/system/smartdns.service /lib/systemd/system/smartdns.service 2>/dev/null || true
    rm -rf "$SYSTEMD_OVERRIDE_DIR"
    systemctl daemon-reload

    if [[ -f "$RESOLV_BAK" ]]; then
        # 若目标仍为符号链接，先移除再复制，避免写入链接目标
        if [[ -L /etc/resolv.conf ]]; then
            rm -f /etc/resolv.conf
        fi
        cp "$RESOLV_BAK" /etc/resolv.conf
        rm -f "$RESOLV_BAK"
        log_info "已恢复 /etc/resolv.conf"
    else
        if [[ -L /etc/resolv.conf ]]; then
            rm -f /etc/resolv.conf
        fi
        echo "nameserver 223.5.5.5" > /etc/resolv.conf
        log_warn "未找到备份，已写入兜底 DNS 223.5.5.5"
    fi

    systemctl enable --now systemd-resolved 2>/dev/null || true

    rm -f "$LOGROTATE_CONF"
    rm -rf /etc/smartdns "$SMARTDNS_LOG_DIR"

    if [[ -f "$INSTALL_BIN" ]]; then
        rm -f "$INSTALL_BIN"
        log_info "已移除 $INSTALL_BIN"
    fi

    log_info "卸载完成"
    exit 0
}

# =============================================================================
# 快捷命令安装
# =============================================================================

install_self() {
    if [[ "$SCRIPT_PATH" != "$INSTALL_BIN" ]]; then
        cp "$SCRIPT_PATH" "$INSTALL_BIN"
        chmod +x "$INSTALL_BIN"
        log_info "快捷命令已安装: 输入 sdns 即可运行菜单"
    fi
}

# =============================================================================
# 菜单
# =============================================================================

main_menu() {
    check_root

    while true; do
        echo ""
        echo "=========================================="
        echo "       SDNS - SmartDNS 管理菜单"
        echo "=========================================="
        status_summary
        echo "------------------------------------------"
        echo "  1. 安装 SmartDNS (默认版本 $DEFAULT_VERSION)"
        echo "  2. 安装 SmartDNS (指定版本)"
        echo "  3. 重新生成配置 (不重装)"
        echo "  4. 重启 SmartDNS"
        echo "  5. 查看详细状态"
        echo "  6. 卸载 SmartDNS 并恢复系统 DNS"
        echo "  0. 退出"
        echo "=========================================="
        read -rp "请选择 [0-6]: " choice || true

        case "$choice" in
            1)
                install_self
                install_smartdns "$DEFAULT_VERSION" || { log_error "安装失败"; continue; }
                generate_config
                takeover_dns
                setup_logrotate
                log_info "全部完成! 快捷命令: sdns"
                ;;
            2)
                local ver=""
                read -rp "请输入 SmartDNS 版本号 (如 48.4): " ver || true
                if [[ -z "$ver" ]]; then
                    log_error "版本号不能为空"
                    continue
                fi
                install_self
                install_smartdns "$ver" || { log_error "安装失败"; continue; }
                generate_config
                takeover_dns
                setup_logrotate
                log_info "全部完成! 快捷命令: sdns"
                ;;
            3)
                if [[ ! -f "$SMARTDNS_CONF" ]]; then
                    log_error "SmartDNS 尚未安装，请先执行安装"
                    continue
                fi
                generate_config
                setup_logrotate
                systemctl restart smartdns 2>/dev/null || true
                log_info "配置已重新生成并重启服务"
                ;;
            4)
                systemctl restart smartdns 2>/dev/null && log_info "已重启" || log_error "重启失败"
                ;;
            5)
                show_detail_status
                ;;
            6)
                uninstall_all
                ;;
            0)
                exit 0
                ;;
            *)
                log_warn "无效选项"
                ;;
        esac
    done
}

# ---------- 入口 ----------
check_debian12
ensure_dependencies
main_menu
