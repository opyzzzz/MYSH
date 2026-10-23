#!/bin/sh
#==========================================================================
# SmartDNS 智能部署脚本 v7.7.1
# PID 文件路径 /var/run → /run (systemd 兼容)
# alt7: 修复 write_resolv 软链接 / OpenRC 守护 PID / 版本号解析 / 端口检测
#==========================================================================
set +e

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

log_info()  { printf "%b[INFO]%b %s\n" "$CYAN" "$NC" "$1"; }
log_ok()    { printf "%b[OK]%b %s\n" "$GREEN" "$NC" "$1"; }
log_err()   { printf "%b[ERROR]%b %s\n" "$RED" "$NC" "$1"; }
log_warn()  { printf "%b[WARN]%b %s\n" "$YELLOW" "$NC" "$1"; }
log_step()  { printf "\n%b>>> %s%b\n" "$BOLD$BLUE" "$1" "$NC"; }

[ "$(id -u)" -ne 0 ] && { log_err "需要 root 权限"; exit 1; }

SMARTDNS_BIN=""; SMARTDNS_VER=""; SMARTDNS_VER_NUM=0; SMARTDNS_SOURCE=""
STABLE_VER="${STABLE_VER:-Release48.3}"
IS_VER_NEW=false; PORT=53
OS_TYPE=""; OS_VER=""; INIT_TYPE=""; VIRT_TYPE=""; VIRT_IS_CONTAINER=false
NET_STACK=""; HAS_IPV4=true; HAS_IPV6=false
TAKEOVER_STRATEGY="standard"
RESOLV_IS_SYMLINK=false; RESOLV_IS_TMPFS=false; RESOLV_FS_TYPE=""
SYSTEMD_RESOLVED_RUNNING=false; CLOUD_INIT_EXISTS=false; CLOUD_INIT_MANAGES_DNS=false
TMPFILES_HAS_RESOLV=false
DEPLOY_LOG="/var/log/smartdns-deploy.log"
ARCH=""; PKG_MGR=""
INOTIFY_CMD=""; INOTIFY_ARGS=""
PID_FILE="/run/resolv-guard.pid"
GUARD_SCRIPT="/usr/local/bin/resolv-guard.sh"
SDNS_CMD="/usr/local/bin/sdns"

RESOLV_TEMPLATE="/etc/smartdns/resolv.smartdns"
RESOLV_BACKUP="/etc/resolv.conf.smartdns.bak"
RESOLV_FALLBACK="/etc/smartdns/resolv.fallback"

APT_UPDATED=false; BB=""
COLS=$(tput cols 2>/dev/null || echo 80)

detect_busybox() { if command -v busybox >/dev/null 2>&1; then BB="busybox"; fi; }

pkg_install() {
    local pkgs="$1" max_retry="${2:-3}" attempt=1
    while [ "$attempt" -le "$max_retry" ]; do
        case "$PKG_MGR" in
            apk) apk add --no-cache $pkgs 2>/dev/null && return 0 ;;
            apt)
                for i in $(seq 1 30); do fuser /var/lib/dpkg/lock-frontend 2>/dev/null && sleep 1 || break; done
                if ! $APT_UPDATED; then apt-get update -qq 2>/dev/null && APT_UPDATED=true; fi
                apt-get install -y -qq $pkgs 2>/dev/null && return 0 ;;
        esac
        attempt=$((attempt + 1)); [ "$attempt" -le "$max_retry" ] && sleep 2
    done
    return 1
}

github_download() {
    local url="$1" output="$2" attempt=1
    while [ "$attempt" -le 3 ]; do
        wget -q --timeout=30 --tries=1 -O "$output" "$url" 2>/dev/null && [ -s "$output" ] && return 0
        curl -sL --max-time 30 -o "$output" "$url" 2>/dev/null && [ -s "$output" ] && return 0
        attempt=$((attempt + 1)); [ "$attempt" -le 3 ] && sleep 3
    done
    return 1
}

get_arch() {
    case "$(uname -m)" in
        x86_64|amd64) echo "x86_64" ;; aarch64|arm64) echo "aarch64" ;;
        armv7l|armv7) echo "arm" ;; i386|i686) echo "x86" ;; *) echo "x86_64" ;;
    esac
}

# [修复3] 简化正则：只提取 Release 后的主版本号，去除 -i 和小数点干扰
get_version_number() {
    local ver_output=$("$1" -v 2>&1)
    echo "$ver_output" | grep -o 'Release[0-9]*' | grep -o '[0-9]*' | head -1
}

# [修复4] 补充 ss 检查；/proc 作为 fallback
port_in_use() {
    local port_hex=$(printf "%04X" "$1")
    if command -v ss >/dev/null 2>&1; then
        ss -tln 2>/dev/null | grep -q ":${1} " && return 0
    fi
    grep -q ":$port_hex " /proc/net/tcp /proc/net/tcp6 2>/dev/null && return 0
    return 1
}

check_ipv6_connectivity() {
    ip route get 2606:4700:4700::1111 >/dev/null 2>&1 || return 1
    if [ -n "$BB" ]; then
        $BB nslookup google.com 2001:4860:4860::8888 >/dev/null 2>&1 && return 0
        $BB nslookup google.com 2606:4700:4700::1111 >/dev/null 2>&1 && return 0
    else
        nslookup -timeout=3 google.com 2001:4860:4860::8888 >/dev/null 2>&1 && return 0
        nslookup -timeout=3 google.com 2606:4700:4700::1111 >/dev/null 2>&1 && return 0
    fi
    return 1
}

ensure_tools() {
    if ! command -v wget >/dev/null 2>&1 && ! command -v curl >/dev/null 2>&1; then pkg_install wget || { log_err "无法安装下载工具"; exit 1; }; fi
    detect_busybox
    if [ -z "$BB" ]; then case "$PKG_MGR" in apk) pkg_install busybox 2 ;; apt) pkg_install busybox 2 ;; esac; detect_busybox; fi
    if ! command -v inotifywait >/dev/null 2>&1 && ! command -v inotifyd >/dev/null 2>&1; then pkg_install inotify-tools 3; fi
}

dns_query() {
    local domain="$1" server="$2"
    if [ "$PORT" != "53" ]; then
        if [ -n "$BB" ]; then echo "跳过"; return 1; fi
        if ! command -v nslookup >/dev/null 2>&1; then echo "跳过"; return 1; fi
        nslookup -port="$PORT" "$domain" "$server" 2>&1 || nslookup -timeout=5 -port="$PORT" "$domain" "$server" 2>&1; return $?
    fi
    if [ -n "$BB" ]; then $BB nslookup "$domain" "$server" 2>&1 && return 0; return 1; fi
    if command -v nslookup >/dev/null 2>&1; then nslookup "$domain" "$server" 2>&1 && return 0; return 1; fi
    echo "跳过"; return 1
}

detect_inotify() {
    if command -v inotifywait >/dev/null 2>&1; then INOTIFY_CMD="inotifywait"; INOTIFY_ARGS="-m -e modify,close_write"; return 0; fi
    if command -v inotifyd >/dev/null 2>&1; then INOTIFY_CMD="inotifyd"; INOTIFY_ARGS="-"; return 0; fi
    log_warn "inotify 工具不可用，将使用轻量级轮询 (5秒间隔)"; return 1
}

safe_rc_add() { local service="$1" runlevel="${2:-default}"; if ! rc-update show 2>/dev/null | grep -q "$service.*$runlevel"; then rc-update add "$service" "$runlevel" 2>/dev/null; fi; }

# [修复1] 先删除软链接再写入，避免跟随软链接写到目标文件
write_resolv() {
    if [ -L /etc/resolv.conf ]; then
        rm -f /etc/resolv.conf
    fi
    cat "$RESOLV_TEMPLATE" > /etc/resolv.conf
}

#==================================================
# 模块0: 环境检测
#==================================================
module_detect() {
    log_step "模块0: 环境检测"
    if [ -f /etc/alpine-release ]; then OS_TYPE="alpine"; OS_VER=$(cat /etc/alpine-release); PKG_MGR="apk"
    elif [ -f /etc/os-release ]; then . /etc/os-release 2>/dev/null; OS_TYPE="debian"; OS_VER="${VERSION_ID:-unknown}"; PKG_MGR="apt"
    else log_err "无法识别的系统"; exit 1; fi
    log_info "系统: $OS_TYPE $OS_VER"
    
    PID1=$(cat /proc/1/comm 2>/dev/null)
    if [ -d /run/systemd/system ]; then INIT_TYPE="systemd"
    elif [ "$PID1" = "openrc-init" ] || [ -f /sbin/openrc ]; then INIT_TYPE="openrc"
    else INIT_TYPE="none"; fi
    log_info "Init: $INIT_TYPE (PID1: $PID1)"
    
    VIRT_TYPE="kvm"
    if grep -qE "docker|podman" /proc/1/cgroup 2>/dev/null; then VIRT_TYPE="podman"; fi
    if grep -q "container=lxc" /proc/1/environ 2>/dev/null; then VIRT_TYPE="lxc"; fi
    if [ -f /.dockerenv ] || [ -f /run/.containerenv ]; then VIRT_TYPE="podman"; fi
    case "$VIRT_TYPE" in podman|docker|lxc) VIRT_IS_CONTAINER=true ;; *) VIRT_IS_CONTAINER=false ;; esac
    log_info "虚拟化: $VIRT_TYPE (容器: $VIRT_IS_CONTAINER)"
    
    ARCH=$(get_arch); ensure_tools
    
    HAS_IPV4=true; ip route get 1.1.1.1 >/dev/null 2>&1 || HAS_IPV4=false
    if check_ipv6_connectivity; then HAS_IPV6=true; else HAS_IPV6=false; fi
    if [ "$HAS_IPV4" = true ] && [ "$HAS_IPV6" = true ]; then NET_STACK="双栈"
    elif [ "$HAS_IPV4" = true ]; then NET_STACK="纯IPv4"; else NET_STACK="纯IPv6"; fi
    log_info "网络栈: $NET_STACK (IPv4: $HAS_IPV4, IPv6: $HAS_IPV6)"
    
    RESOLV_IS_SYMLINK=false; RESOLV_IS_TMPFS=false
    SYSTEMD_RESOLVED_RUNNING=false; CLOUD_INIT_EXISTS=false; CLOUD_INIT_MANAGES_DNS=false; TMPFILES_HAS_RESOLV=false
    if [ -L /etc/resolv.conf ]; then RESOLV_IS_SYMLINK=true; fi
    if [ -f /etc/resolv.conf ]; then RESOLV_FS_TYPE=$(df -T /etc/resolv.conf 2>/dev/null | tail -1 | awk '{print $2}'); [ "$RESOLV_FS_TYPE" = "tmpfs" ] && RESOLV_IS_TMPFS=true; fi
    log_info "resolv.conf: 软链接=$RESOLV_IS_SYMLINK, tmpfs=$RESOLV_IS_TMPFS"
    
    if command -v resolvectl >/dev/null 2>&1 && resolvectl status >/dev/null 2>&1; then SYSTEMD_RESOLVED_RUNNING=true; log_warn "systemd-resolved 运行中"; fi
    if command -v cloud-init >/dev/null 2>&1; then
        CLOUD_INIT_EXISTS=true
        [ -f /etc/cloud/cloud.cfg ] && grep -q "resolv_conf\|manage-resolv-conf" /etc/cloud/cloud.cfg 2>/dev/null && CLOUD_INIT_MANAGES_DNS=true
        for cfg in /etc/cloud/cloud.cfg.d/*; do [ -f "$cfg" ] || continue; grep -q "resolv_conf\|manage-resolv-conf" "$cfg" 2>/dev/null && CLOUD_INIT_MANAGES_DNS=true; done
        [ "$CLOUD_INIT_MANAGES_DNS" = true ] && log_warn "cloud-init 管理 DNS"
    fi
    if find /usr/lib/tmpfiles.d/ /etc/tmpfiles.d/ -maxdepth 1 -type f -exec grep -l "/etc/resolv.conf" {} \; 2>/dev/null | grep -q .; then TMPFILES_HAS_RESOLV=true; log_warn "tmpfiles.d 管理 resolv.conf"; fi
    
    if $SYSTEMD_RESOLVED_RUNNING; then TAKEOVER_STRATEGY="resolved"
    elif $VIRT_IS_CONTAINER && $RESOLV_IS_TMPFS; then TAKEOVER_STRATEGY="podman"
    elif $CLOUD_INIT_EXISTS && $CLOUD_INIT_MANAGES_DNS; then TAKEOVER_STRATEGY="cloudinit"
    else TAKEOVER_STRATEGY="standard"; fi
    log_ok "接管策略: $TAKEOVER_STRATEGY"
}

#==================================================
# 模块1: 安装 SmartDNS
#==================================================
module_install() {
    log_step "模块1: 安装 SmartDNS"
    STABLE_URL="https://github.com/pymumu/smartdns/releases/download/${STABLE_VER}/smartdns-${ARCH}"
    LATEST_URL="https://github.com/pymumu/smartdns/releases/latest/download/smartdns-${ARCH}"
    TEMP_BIN="/tmp/smartdns-$$"
    
    log_info "安装稳定版: ${STABLE_VER}"
    if github_download "$STABLE_URL" "$TEMP_BIN"; then
        chmod +x "$TEMP_BIN"; mv "$TEMP_BIN" /usr/bin/smartdns
        SMARTDNS_BIN="/usr/bin/smartdns"; SMARTDNS_SOURCE="GitHub"
        log_ok "稳定版安装成功"
    else
        log_warn "稳定版下载失败，尝试最新版..."
        if github_download "$LATEST_URL" "$TEMP_BIN"; then
            chmod +x "$TEMP_BIN"; mv "$TEMP_BIN" /usr/bin/smartdns
            SMARTDNS_BIN="/usr/bin/smartdns"; SMARTDNS_SOURCE="GitHub"
            log_ok "最新版安装成功"
        fi
    fi
    rm -f "$TEMP_BIN"
    
    if [ -z "$SMARTDNS_BIN" ]; then
        log_warn "GitHub 下载失败，尝试包管理器..."
        if pkg_install smartdns 3; then SMARTDNS_BIN="/usr/sbin/smartdns"; [ -x "$SMARTDNS_BIN" ] || SMARTDNS_BIN="/usr/bin/smartdns"; [ -x "$SMARTDNS_BIN" ] || SMARTDNS_BIN=$(which smartdns 2>/dev/null); [ -n "$SMARTDNS_BIN" ] && SMARTDNS_SOURCE="$PKG_MGR" && log_ok "包管理器安装成功"; fi
    fi
    if [ -z "$SMARTDNS_BIN" ] || [ ! -x "$SMARTDNS_BIN" ]; then log_err "所有安装方式均失败"; exit 1; fi
    SMARTDNS_VER=$("$SMARTDNS_BIN" -v 2>&1 | head -1); SMARTDNS_VER_NUM=$(get_version_number "$SMARTDNS_BIN")
    [ "$SMARTDNS_VER_NUM" -ge 42 ] 2>/dev/null && IS_VER_NEW=true || IS_VER_NEW=false
    log_info "版本: $SMARTDNS_VER (来源: $SMARTDNS_SOURCE)"
    [ "$IS_VER_NEW" = true ] && log_ok "支持 upstream-group 自动降级"
}

#==================================================
# 模块2: 生成配置与 DNS 模板
#==================================================
module_config() {
    log_step "模块2: 生成配置与 DNS 模板"
    mkdir -p /etc/smartdns
    [ -f /etc/smartdns/smartdns.conf ] && cp /etc/smartdns/smartdns.conf "/etc/smartdns/smartdns.conf.bak.$(date +%Y%m%d-%H%M%S)" 2>/dev/null
    
    if [ "$HAS_IPV6" = true ] && [ "$HAS_IPV4" = true ]; then
        cat > "$RESOLV_TEMPLATE" << EOF
nameserver 127.0.0.1
nameserver ::1
options edns0 trust-ad
EOF
        cat > "$RESOLV_FALLBACK" << EOF
nameserver 1.1.1.1
nameserver 8.8.8.8
nameserver 2606:4700:4700::1111
nameserver 2001:4860:4860::8888
EOF
    elif [ "$HAS_IPV6" = true ]; then
        cat > "$RESOLV_TEMPLATE" << EOF
nameserver ::1
options edns0 trust-ad
EOF
        cat > "$RESOLV_FALLBACK" << EOF
nameserver 2606:4700:4700::1111
nameserver 2001:4860:4860::8888
EOF
    else
        cat > "$RESOLV_TEMPLATE" << EOF
nameserver 127.0.0.1
options edns0 trust-ad
EOF
        cat > "$RESOLV_FALLBACK" << EOF
nameserver 1.1.1.1
nameserver 8.8.8.8
EOF
    fi
    log_ok "DNS 模板已生成: $RESOLV_TEMPLATE"
    
    [ "$TAKEOVER_STRATEGY" = "resolved" ] && systemctl stop systemd-resolved 2>/dev/null
    PORT=53
    if port_in_use 53; then log_warn "端口 53 被占用"; for p in 5353 5354; do if ! port_in_use "$p"; then PORT="$p"; log_warn "使用备用端口: $PORT"; break; fi; done
    else log_ok "端口 53 可用"; fi
    
    cat > /etc/smartdns/smartdns.conf << EOF
# SmartDNS 配置 v7.7.0-alt7
# 环境: $OS_TYPE $OS_VER | $VIRT_TYPE | $NET_STACK
# 版本: $SMARTDNS_VER | 来源: $SMARTDNS_SOURCE
# 策略: $TAKEOVER_STRATEGY | 时间: $(date '+%Y-%m-%d %H:%M:%S')
server-name smartdns
EOF
    
    if [ "$HAS_IPV6" = true ] && [ "$HAS_IPV4" = true ]; then echo "bind [::]:${PORT}" >> /etc/smartdns/smartdns.conf
    elif [ "$HAS_IPV4" = true ]; then echo "bind 0.0.0.0:${PORT}" >> /etc/smartdns/smartdns.conf
    else echo "bind [::]:${PORT}" >> /etc/smartdns/smartdns.conf; fi
    
    cat >> /etc/smartdns/smartdns.conf << EOF
cache-size 4096
prefetch-domain yes
serve-expired no
response-mode fastest-ip
rr-ttl 300
rr-ttl-min 0
log-level info
log-file /var/log/smartdns.log
log-size 1m
log-num 3
speed-check-mode tcp:443,tcp:853
alive-check-interval 300
alive-check-mode tcp:80
EOF
    
    [ "$HAS_IPV6" = false ] && echo "force-AAAA-SOA yes" >> /etc/smartdns/smartdns.conf
    [ "$IS_VER_NEW" = true ] && [ "$NET_STACK" = "双栈" ] && echo "dualstack-ip-selection yes" >> /etc/smartdns/smartdns.conf
    
    if [ "$IS_VER_NEW" = true ]; then
        log_info "配置 upstream-group (加密组 + UDP兜底组)"
        cat >> /etc/smartdns/smartdns.conf << 'EOF'

upstream-group secure
server-https https://dns.google/dns-query -group secure
server-https https://cloudflare-dns.com/dns-query -group secure
server-tls 8.8.8.8:853 -host-name dns.google -no-check-certificate -group secure
server-tls 1.1.1.1:853 -host-name cloudflare-dns.com -no-check-certificate -group secure
EOF
        [ "$HAS_IPV6" = true ] && cat >> /etc/smartdns/smartdns.conf << 'EOF'
server-https https://[2001:4860:4860::8888]/dns-query -group secure
server-https https://[2606:4700:4700::1111]/dns-query -group secure
server-tls 2001:4860:4860::8844:853 -host-name dns.google -no-check-certificate -group secure
server-tls 2606:4700:4700::1001:853 -host-name cloudflare-dns.com -no-check-certificate -group secure
EOF
        cat >> /etc/smartdns/smartdns.conf << 'EOF'

upstream-group fallback
server 8.8.8.8 -group fallback
server 1.1.1.1 -group fallback
EOF
        [ "$HAS_IPV6" = true ] && cat >> /etc/smartdns/smartdns.conf << 'EOF'
server 2001:4860:4860::8888 -group fallback
server 2606:4700:4700::1111 -group fallback
EOF
        cat >> /etc/smartdns/smartdns.conf << 'EOF'

fail-count 3
keepalive-fail-count 5
check-interval 600
EOF
    else
        log_warn "旧版降级: 仅 UDP 上游"
        [ "$HAS_IPV4" = true ] && cat >> /etc/smartdns/smartdns.conf << EOF
server 8.8.8.8
server 1.1.1.1
EOF
        [ "$HAS_IPV6" = true ] && cat >> /etc/smartdns/smartdns.conf << EOF
server 2001:4860:4860::8888
server 2606:4700:4700::1111
EOF
    fi
    log_ok "配置已生成: /etc/smartdns/smartdns.conf"
}

#==================================================
# 模块3: 接管系统 DNS
#==================================================
module_dns_takeover() {
    log_step "模块3: 接管系统 DNS (策略: $TAKEOVER_STRATEGY)"
    detect_inotify
    [ -z "$INOTIFY_CMD" ] && log_warn "inotify 工具不可用，将使用轻量级轮询 (5秒间隔)" || log_info "inotify 工具: $INOTIFY_CMD"
    
    # ── 备份原始 DNS（只一次）──
    if [ -f /etc/resolv.conf ] && [ ! -L /etc/resolv.conf ]; then
        [ ! -f /etc/resolv.conf.smartdns.orig ] && cp /etc/resolv.conf /etc/resolv.conf.smartdns.orig 2>/dev/null
    fi
    if [ -L /etc/resolv.conf ] && [ ! -f /etc/resolv.conf.smartdns.orig ]; then
        cat /etc/resolv.conf 2>/dev/null > /etc/resolv.conf.smartdns.orig 2>/dev/null
    fi
    
    # ── 从模板文件统一提取 DNS 值 ──
    local dns_list; local dns_yaml; local dns_list_grep
    if [ -f "$RESOLV_TEMPLATE" ]; then
        dns_list=$(grep "^nameserver" "$RESOLV_TEMPLATE" 2>/dev/null | awk '{print $2}' | tr '\n' ' ' | sed 's/ $//')
    fi
    if [ -z "$dns_list" ]; then
        if [ "$HAS_IPV4" = true ] && [ "$HAS_IPV6" = true ]; then dns_list="127.0.0.1 ::1"
        elif [ "$HAS_IPV6" = true ]; then dns_list="::1"
        else dns_list="127.0.0.1"; fi
    fi
    
    dns_yaml=""
    for ip in $dns_list; do
        if [ -z "$dns_yaml" ]; then dns_yaml="'$ip'"
        else dns_yaml="$dns_yaml, '$ip'"; fi
    done
    dns_list_grep=$(echo "$dns_list" | awk '{print $1}')
    
    BACKUP_LIST="/etc/smartdns/dns-config-backup.txt"
    > "$BACKUP_LIST"
    
    # 1. cloud-init
    if command -v cloud-init >/dev/null 2>&1; then
        mkdir -p /etc/cloud/cloud.cfg.d
        cat > /etc/cloud/cloud.cfg.d/99-smartdns-dns.cfg << EOF
manage-resolv-conf: true
resolv_conf:
  nameservers: [${dns_yaml}]
EOF
        echo "/etc/cloud/cloud.cfg.d/99-smartdns-dns.cfg:DELETE" >> "$BACKUP_LIST"
        log_info "cloud-init: DNS → ${dns_list}"
    fi
    
    # 2. systemd-resolved
    if [ "$INIT_TYPE" = "systemd" ] && command -v resolvectl >/dev/null 2>&1; then
        mkdir -p /etc/systemd/resolved.conf.d
        cat > /etc/systemd/resolved.conf.d/smartdns.conf << EOF
[Resolve]
DNS=${dns_list}
DNSStubListener=no
EOF
        echo "/etc/systemd/resolved.conf.d/smartdns.conf:DELETE" >> "$BACKUP_LIST"
        systemctl restart systemd-resolved 2>/dev/null
        
        if [ -L /etc/resolv.conf ]; then
            rm -f /etc/resolv.conf
            write_resolv
            log_info "systemd-resolved: stub 软链接已替换为静态文件"
        fi
        if [ "$TMPFILES_HAS_RESOLV" = true ]; then
            mkdir -p /etc/tmpfiles.d
            printf "# SmartDNS 接管\n" > /etc/tmpfiles.d/systemd-resolved.conf
            echo "/etc/tmpfiles.d/systemd-resolved.conf:DELETE" >> "$BACKUP_LIST"
        fi
        log_info "systemd-resolved: 上游 → ${dns_list}"
    fi
    
    # 3. dhclient
    if [ "$HAS_IPV4" = true ] && [ -f /etc/dhcp/dhclient.conf ]; then
        cp /etc/dhcp/dhclient.conf /etc/dhcp/dhclient.conf.smartdns.bak 2>/dev/null
        echo "/etc/dhcp/dhclient.conf:RESTORE:/etc/dhcp/dhclient.conf.smartdns.bak" >> "$BACKUP_LIST"
        if ! grep -q "supersede domain-name-servers 127.0.0.1" /etc/dhcp/dhclient.conf 2>/dev/null; then
            echo "supersede domain-name-servers 127.0.0.1;" >> /etc/dhcp/dhclient.conf
        fi
        log_info "dhclient: DNS → 127.0.0.1"
    fi
    
    # 4. udhcpc
    if [ -f /etc/udhcpc/udhcpc.conf ]; then
        cp /etc/udhcpc/udhcpc.conf /etc/udhcpc/udhcpc.conf.smartdns.bak 2>/dev/null
        echo "/etc/udhcpc/udhcpc.conf:RESTORE:/etc/udhcpc/udhcpc.conf.smartdns.bak" >> "$BACKUP_LIST"
        if grep -q "^RESOLV_CONF" /etc/udhcpc/udhcpc.conf 2>/dev/null; then
            sed -i 's/^RESOLV_CONF=.*/RESOLV_CONF="no"/' /etc/udhcpc/udhcpc.conf
        else
            echo 'RESOLV_CONF="no"' >> /etc/udhcpc/udhcpc.conf
        fi
        log_info "udhcpc: 不再写 resolv.conf"
    fi
    
    # 5. systemd-networkd
    if [ "$INIT_TYPE" = "systemd" ] && [ -d /etc/systemd/network ]; then
        for netconf in /etc/systemd/network/*.network; do
            [ -f "$netconf" ] || continue
            if grep -q "DNS=${dns_list_grep}" "$netconf" 2>/dev/null; then
                continue
            fi
            cp "$netconf" "${netconf}.smartdns.bak" 2>/dev/null
            echo "${netconf}:RESTORE:${netconf}.smartdns.bak" >> "$BACKUP_LIST"
            printf "\n[Network]\nDNS=%s\n" "$dns_list" >> "$netconf"
            log_info "systemd-networkd: DNS → ${dns_list}"
        done
    fi
    
    # 6. NetworkManager
    if command -v nmcli >/dev/null 2>&1; then
        local conn; conn=$(nmcli -t -f NAME con show --active 2>/dev/null | head -1)
        if [ -n "$conn" ]; then
            if [ "$HAS_IPV4" = true ]; then
                nmcli con mod "$conn" ipv4.dns 127.0.0.1 2>/dev/null
                nmcli con mod "$conn" ipv4.ignore-auto-dns yes 2>/dev/null
            fi
            if [ "$HAS_IPV6" = true ]; then
                nmcli con mod "$conn" ipv6.dns ::1 2>/dev/null
                nmcli con mod "$conn" ipv6.ignore-auto-dns yes 2>/dev/null
            fi
            printf "%s\n" "$conn" > /etc/smartdns/nm-conn.txt
            log_info "NetworkManager: DNS → ${dns_list}"
        fi
    fi
    
    # 7. Alpine ifupdown
    if [ -f /etc/network/interfaces ]; then
        if grep -q "iface.*inet dhcp" /etc/network/interfaces 2>/dev/null; then
            local iface4; iface4=$(grep "iface.*inet dhcp" /etc/network/interfaces | awk '{print $2}')
            if [ -n "$iface4" ] && ! grep -A5 "iface $iface4" /etc/network/interfaces | grep -q "dns-nameservers"; then
                [ ! -f /etc/network/interfaces.smartdns.bak ] && cp /etc/network/interfaces /etc/network/interfaces.smartdns.bak 2>/dev/null
                echo "/etc/network/interfaces:RESTORE:/etc/network/interfaces.smartdns.bak" >> "$BACKUP_LIST"
                printf "\n    dns-nameservers %s\n" "$dns_list" | \
                    sed -i "/iface $iface4 inet dhcp/r /dev/stdin" /etc/network/interfaces
                log_info "ifupdown: $iface4 DNS → ${dns_list}"
            fi
        fi
        if [ "$HAS_IPV6" = true ] && grep -q "iface.*inet6 dhcp" /etc/network/interfaces 2>/dev/null; then
            local iface6; iface6=$(grep "iface.*inet6 dhcp" /etc/network/interfaces | awk '{print $2}')
            if [ -n "$iface6" ] && ! grep -A5 "iface $iface6" /etc/network/interfaces | grep -q "dns-nameservers"; then
                [ ! -f /etc/network/interfaces.smartdns.bak ] && cp /etc/network/interfaces /etc/network/interfaces.smartdns.bak 2>/dev/null
                echo "/etc/network/interfaces:RESTORE:/etc/network/interfaces.smartdns.bak" >> "$BACKUP_LIST"
                printf "\n    dns-nameservers %s\n" "$dns_list" | \
                    sed -i "/iface $iface6 inet6 dhcp/r /dev/stdin" /etc/network/interfaces
                log_info "ifupdown: $iface6 DNS → ${dns_list}"
            fi
        fi
    fi
    
    # ── 写入当前 DNS ──
    if [ "$TAKEOVER_STRATEGY" != "resolved" ]; then write_resolv; fi
    cat "$RESOLV_TEMPLATE" > "$RESOLV_BACKUP"; chmod 644 "$RESOLV_BACKUP" 2>/dev/null
    
    # [修复1] 写入后验证非软链接
    if [ -L /etc/resolv.conf ]; then
        log_warn "resolv.conf 仍为软链接，尝试强制替换"
        rm -f /etc/resolv.conf
        write_resolv
        [ -L /etc/resolv.conf ] && log_err "软链接替换失败，请手动检查" || log_ok "软链接已替换为静态文件"
    fi
    
    # ═══════════════════════════════════════
    # 第二层：启动覆盖
    # ═══════════════════════════════════════
    
    if [ "$INIT_TYPE" = "openrc" ]; then
        log_info "创建 Alpine 启动覆盖脚本"; mkdir -p /etc/local.d
        cat > /etc/local.d/resolv-fix.start << LSTART
#!/bin/sh
sleep 5
for i in 1 2 3 4 5; do if cmp -s ${RESOLV_TEMPLATE} /etc/resolv.conf 2>/dev/null; then exit 0; fi; sleep 1; done
[ -L /etc/resolv.conf ] && rm -f /etc/resolv.conf
cat ${RESOLV_TEMPLATE} > /etc/resolv.conf
LSTART
        chmod +x /etc/local.d/resolv-fix.start; safe_rc_add local default; log_ok "local.d 启动脚本已创建"
    elif [ "$INIT_TYPE" = "systemd" ]; then
        log_info "创建 systemd oneshot 启动覆盖"
        cat > /etc/systemd/system/resolv-fix.service << SSTART
[Unit]
Description=DNS Resolv Fix
After=network-online.target cloud-init.service systemd-resolved.service
Wants=network-online.target
[Service]
Type=oneshot
ExecStart=/bin/sh -c 'sleep 5; for i in 1 2 3 4 5; do cmp -s ${RESOLV_TEMPLATE} /etc/resolv.conf 2>/dev/null && exit 0; sleep 1; done; [ -L /etc/resolv.conf ] && rm -f /etc/resolv.conf; cat ${RESOLV_TEMPLATE} > /etc/resolv.conf'
[Install]
WantedBy=multi-user.target
SSTART
        systemctl daemon-reload 2>/dev/null; systemctl enable resolv-fix.service 2>/dev/null; log_ok "systemd oneshot 服务已创建"
    fi
    
    # ═══════════════════════════════════════
    # 第三层：DNS 文件守护
    # ═══════════════════════════════════════
    
    log_info "部署 DNS 文件守护"
    # [修复1] 守护脚本 restore_dns 中同样处理软链接
    if [ "$INIT_TYPE" = "systemd" ]; then
        cat > "$GUARD_SCRIPT" << GUARD
#!/bin/sh
TARGET="/etc/resolv.conf"; TEMPLATE="${RESOLV_TEMPLATE}"
restore_dns() {
    [ -f "\$TEMPLATE" ] || return 0
    if [ -L "\$TARGET" ]; then rm -f "\$TARGET"; cat "\$TEMPLATE" > "\$TARGET" 2>/dev/null; return 0; fi
    ! cmp -s "\$TEMPLATE" "\$TARGET" 2>/dev/null && cat "\$TEMPLATE" > "\$TARGET" 2>/dev/null
}
if command -v inotifywait >/dev/null 2>&1; then while true; do inotifywait -m -e modify,close_write "\$TARGET" 2>/dev/null | while read -r path event file; do sleep 0.5; restore_dns; done; sleep 1; done
elif command -v inotifyd >/dev/null 2>&1; then while true; do inotifyd - "\$TARGET" 2>/dev/null | while read -r event file; do case "\$event" in w|m|c) sleep 0.5; restore_dns ;; esac; done; sleep 1; done
else while true; do sleep 5; restore_dns; done; fi
GUARD
    else
        # [修复2] 守护脚本内部不再写 PID 文件，由父 shell 捕获 $!
        cat > "$GUARD_SCRIPT" << GUARD
#!/bin/sh
TARGET="/etc/resolv.conf"; TEMPLATE="${RESOLV_TEMPLATE}"
restore_dns() {
    [ -f "\$TEMPLATE" ] || return 0
    if [ -L "\$TARGET" ]; then rm -f "\$TARGET"; cat "\$TEMPLATE" > "\$TARGET" 2>/dev/null; return 0; fi
    ! cmp -s "\$TEMPLATE" "\$TARGET" 2>/dev/null && cat "\$TEMPLATE" > "\$TARGET" 2>/dev/null
}
if command -v inotifywait >/dev/null 2>&1; then while true; do inotifywait -m -e modify,close_write "\$TARGET" 2>/dev/null | while read -r path event file; do sleep 0.5; restore_dns; done; sleep 1; done
elif command -v inotifyd >/dev/null 2>&1; then while true; do inotifyd - "\$TARGET" 2>/dev/null | while read -r event file; do case "\$event" in w|m|c) sleep 0.5; restore_dns ;; esac; done; sleep 1; done
else while true; do sleep 5; restore_dns; done; fi
GUARD
    fi
    chmod 700 "$GUARD_SCRIPT"
    
    [ -f "$PID_FILE" ] && { OLD_PID=$(cat "$PID_FILE" 2>/dev/null); [ -n "$OLD_PID" ] && kill "$OLD_PID" 2>/dev/null; rm -f "$PID_FILE"; }
    sleep 0.5
    
    if [ "$INIT_TYPE" = "systemd" ]; then
        cat > /etc/systemd/system/resolv-guard.service << 'GSTART'
[Unit]
Description=DNS Resolv Guard
After=smartdns.service resolv-fix.service
Requires=smartdns.service
[Service]
Type=simple
ExecStart=/usr/local/bin/resolv-guard.sh
Restart=always
RestartSec=3
[Install]
WantedBy=multi-user.target
GSTART
        systemctl daemon-reload 2>/dev/null; systemctl enable resolv-guard.service 2>/dev/null
    elif [ "$INIT_TYPE" = "openrc" ]; then
        mkdir -p /etc/local.d; cat > /etc/local.d/resolv-guard.start << 'OGSTART'
#!/bin/sh
/usr/local/bin/resolv-guard.sh &
echo $! > /run/resolv-guard.pid
OGSTART
        chmod +x /etc/local.d/resolv-guard.start
        # [修复2] 父 shell 捕获后台 PID
        "$GUARD_SCRIPT" &
        GUARD_PID=$!
        echo "$GUARD_PID" > "$PID_FILE"
        safe_rc_add local default
    else
        # [修复2] 父 shell 捕获后台 PID
        "$GUARD_SCRIPT" &
        GUARD_PID=$!
        echo "$GUARD_PID" > "$PID_FILE"
    fi
    
    # ── 验证 ──
    local issues; issues=0
    [ -L /etc/resolv.conf ] && { log_warn "resolv.conf 仍是软链接"; issues=$((issues+1)); }
    if [ -f /etc/cloud/cloud.cfg.d/99-smartdns-dns.cfg ]; then
        grep -q "nameservers:" /etc/cloud/cloud.cfg.d/99-smartdns-dns.cfg || issues=$((issues+1))
    fi
    if [ -f /etc/systemd/resolved.conf.d/smartdns.conf ]; then
        grep -q "DNS=" /etc/systemd/resolved.conf.d/smartdns.conf || issues=$((issues+1))
    fi
    [ $issues -eq 0 ] && log_ok "DNS 源头已全部指向 SmartDNS" || log_warn "发现 $issues 处可能未生效"
    
    log_ok "DNS 三重防护已部署 (工具: ${INOTIFY_CMD:-轮询})"
    log_ok "系统 DNS → $(head -1 "$RESOLV_TEMPLATE")"
}

#==================================================
# 模块4: 服务与守护
#==================================================
module_service() {
    log_step "模块4: 部署 SmartDNS 服务"
    pkill -x smartdns 2>/dev/null; sleep 1
    rm -rf /var/cache/smartdns/
    echo "" > /var/log/smartdns.log 2>/dev/null
    case "$INIT_TYPE" in
        systemd)
            cat > /etc/systemd/system/smartdns.service << 'SVC'
[Unit]
Description=SmartDNS (DoH+DoT+UDP)
After=network-online.target
Wants=network-online.target
[Service]
Type=forking
ExecStart=/usr/bin/smartdns -c /etc/smartdns/smartdns.conf
PIDFile=/run/smartdns.pid
ExecReload=/bin/kill -HUP $MAINPID
Restart=on-failure
RestartSec=3
WatchdogSec=30
[Install]
WantedBy=multi-user.target
SVC
            systemctl daemon-reload; systemctl enable smartdns.service 2>/dev/null; systemctl restart smartdns.service; sleep 2 ;;
        openrc)
            if [ ! -f /etc/init.d/smartdns ]; then
                cat > /etc/init.d/smartdns << OSVC
#!/sbin/openrc-run
name="SmartDNS"; command="/usr/bin/smartdns"; command_args="-c /etc/smartdns/smartdns.conf"; command_background=true; pidfile="/run/smartdns.pid"
depend() { need net; after firewall; }
OSVC
                chmod +x /etc/init.d/smartdns
            fi
            safe_rc_add smartdns default; rc-service smartdns start 2>/dev/null; sleep 2 ;;
        *) /usr/bin/smartdns -c /etc/smartdns/smartdns.conf & sleep 2 ;;
    esac
    
    [ "$INIT_TYPE" = "systemd" ] && systemctl start resolv-guard.service 2>/dev/null
    
    # [修复4] 启动后实际验证，失败时输出端口占用诊断
    if pgrep smartdns >/dev/null 2>&1; then
        log_ok "SmartDNS 已启动"
    else
        log_err "启动失败，日志:"
        tail -20 /var/log/smartdns.log 2>/dev/null
        log_warn "端口 ${PORT} 占用情况:"
        if command -v ss >/dev/null 2>&1; then
            ss -tlnp 2>/dev/null | grep ":${PORT}" || echo "  (ss 未发现端口 ${PORT} 监听)"
        elif command -v netstat >/dev/null 2>&1; then
            netstat -tlnp 2>/dev/null | grep ":${PORT}" || echo "  (netstat 未发现端口 ${PORT} 监听)"
        else
            echo "  (ss/netstat 均不可用)"
        fi
        exit 1
    fi
}

#==================================================
# 模块5: 验证与日志
#==================================================
module_verify() {
    log_step "模块5: 验证与日志"
    sleep 2; ALL_OK=true
    
    if [ "$HAS_IPV4" = true ]; then
        log_info "DNS 解析测试 (IPv4)..."
        for domain in google.com cloudflare.com; do
            RESULT=$(dns_query "$domain" 127.0.0.1 2>&1)
            if echo "$RESULT" | grep -q "Address"; then IP=$(echo "$RESULT" | grep "Address" | tail -1 | awk '{print $NF}'); log_ok "$domain → $IP"
            elif echo "$RESULT" | grep -q "跳过"; then log_info "$domain $(echo "$RESULT" | head -1)"
            else log_err "$domain 解析失败"; ALL_OK=false; fi
        done
    else log_info "跳过 IPv4 解析测试（纯 IPv6 环境）"; fi
    
    if [ "$HAS_IPV6" = true ]; then
        log_info "DNS 解析测试 (IPv6)..."
        RESULT=$(dns_query "ipv6.google.com" "::1" 2>&1)
        if echo "$RESULT" | grep -q "Address"; then IP=$(echo "$RESULT" | grep "Address" | tail -1 | awk '{print $NF}'); log_ok "ipv6.google.com → $IP"
        elif echo "$RESULT" | grep -q "跳过"; then log_info "ipv6.google.com $(echo "$RESULT" | head -1)"
        else log_warn "ipv6.google.com 解析失败"; fi
    fi
    
    if [ "$IS_VER_NEW" = true ] && command -v curl >/dev/null 2>&1; then
        echo ""; log_info "DoH 连通性测试..."
        if [ "$HAS_IPV4" = true ]; then
            for item in "Google|https://dns.google/dns-query" "Cloudflare|https://cloudflare-dns.com/dns-query"; do
                NAME="${item%%|*}"; URL="${item##*|}"
                RESULT=$(curl -s --max-time 5 -H "accept: application/dns-json" "${URL}?name=google.com&type=A" 2>&1)
                if echo "$RESULT" | grep -q '"Status":\s*0'; then log_ok "$NAME DoH (IPv4) 正常"; else log_warn "$NAME DoH (IPv4) 可能受限"; fi
            done
        fi
    fi
    
    { echo ""; echo "===== SmartDNS 部署日志 ====="; echo "时间: $(date)"; echo "系统: $OS_TYPE $OS_VER | $VIRT_TYPE | $NET_STACK"; echo "策略: $TAKEOVER_STRATEGY | 版本: $SMARTDNS_VER | 端口: $PORT"; echo "守护: ${INOTIFY_CMD:-轮询}"; echo "=============================="; } >> "$DEPLOY_LOG"
    
    echo ""
    printf "%b\n" "${GREEN}${BOLD}╔══════════════════════════════════════╗${NC}"
    [ "$ALL_OK" = true ] && printf "%b\n" "${GREEN}${BOLD}║ ✓ SmartDNS 部署成功                ║${NC}" || printf "%b\n" "${YELLOW}${BOLD}║ ⚠ 部分域名解析异常                 ║${NC}"
    printf "%b\n" "${GREEN}${BOLD}╚══════════════════════════════════════╝${NC}"
    echo ""; echo -e "${BOLD}部署摘要:${NC}"; echo -e "  系统: ${CYAN}$OS_TYPE $OS_VER ($VIRT_TYPE)${NC}"; echo -e "  端口: ${CYAN}127.0.0.1:${PORT}${NC}"
    echo -e "  上游: ${GREEN}Google + Cloudflare (DoH/DoT + UDP自动降级)${NC}"; echo -e "  守护: ${GREEN}${INOTIFY_CMD:-轮询} + 启动覆盖${NC}"
}

#==================================================
# 模块6: 卸载
#==================================================
module_uninstall() {
    echo ""; echo -e "${YELLOW}══════════════════════════════════════${NC}"
    echo -e "${YELLOW}  卸载 SmartDNS${NC}"
    echo -e "${YELLOW}══════════════════════════════════════${NC}"
    echo ""
    echo -e "  这将${RED}永久删除${NC}所有配置、日志和守护进程。"
    echo ""
    printf "  请输入 ${RED}yes${NC} 确认卸载: "
    read -r confirm
    case "$confirm" in yes|YES|Yes|y|Y) ;; *) echo ""; echo "  已取消"; return ;; esac
    
    echo ""
    echo -e "${BOLD}  正在卸载...${NC}"
    
    [ -z "$INIT_TYPE" ] && { if [ -d /run/systemd/system ]; then INIT_TYPE="systemd"; elif [ -f /sbin/openrc ]; then INIT_TYPE="openrc"; else INIT_TYPE="none"; fi; }
    
    case "$INIT_TYPE" in
        systemd)
            systemctl stop resolv-guard.service resolv-fix.service smartdns.service 2>/dev/null
            systemctl disable resolv-guard.service resolv-fix.service smartdns.service 2>/dev/null
            rm -f /etc/systemd/system/resolv-guard.service /etc/systemd/system/resolv-fix.service /etc/systemd/system/smartdns.service
            systemctl daemon-reload 2>/dev/null
            if [ -f /etc/systemd/resolved.conf.d/smartdns.conf ]; then
                rm -f /etc/systemd/resolved.conf.d/smartdns.conf
                systemctl restart systemd-resolved 2>/dev/null
            fi
            ;;
        openrc)
            rc-service smartdns stop 2>/dev/null; rc-update del smartdns 2>/dev/null
            rm -f /etc/init.d/smartdns /etc/local.d/resolv-fix.start /etc/local.d/resolv-guard.start
            ;;
    esac
    
    if [ -f "$PID_FILE" ]; then
        GUARD_PID=$(cat "$PID_FILE" 2>/dev/null)
        [ -n "$GUARD_PID" ] && { kill "$GUARD_PID" 2>/dev/null; sleep 0.5; kill -9 "$GUARD_PID" 2>/dev/null; }
        rm -f "$PID_FILE"
    fi
    pkill -x smartdns 2>/dev/null; sleep 0.5; pkill -9 -x smartdns 2>/dev/null; sleep 1
    
    if [ -f /etc/smartdns/dns-config-backup.txt ]; then
        while read -r line; do
            case "$line" in
                *:DELETE) rm -f "${line%%:DELETE}" ;;
                *:RESTORE:*)
                    src="${line##*:RESTORE:}"; dst="${line%%:RESTORE:*}"
                    [ -f "$src" ] && cp "$src" "$dst" && rm -f "$src"
                    ;;
            esac
        done < /etc/smartdns/dns-config-backup.txt
        rm -f /etc/smartdns/dns-config-backup.txt
    fi
    if [ -f /etc/smartdns/nm-conn.txt ] && command -v nmcli >/dev/null 2>&1; then
        CONN=$(cat /etc/smartdns/nm-conn.txt 2>/dev/null)
        [ -n "$CONN" ] && { nmcli con mod "$CONN" ipv4.ignore-auto-dns no 2>/dev/null; nmcli con mod "$CONN" ipv4.dns "" 2>/dev/null; }
        rm -f /etc/smartdns/nm-conn.txt
    fi
    
    rm -f "$GUARD_SCRIPT" "$RESOLV_BACKUP" "$SDNS_CMD" /etc/cloud/cloud.cfg.d/99-smartdns-dns.cfg
    [ -f /etc/tmpfiles.d/systemd-resolved.conf ] && grep -q "SmartDNS" /etc/tmpfiles.d/systemd-resolved.conf 2>/dev/null && rm -f /etc/tmpfiles.d/systemd-resolved.conf
    crontab -l 2>/dev/null | grep -q "resolv-check\|smartdns" && { crontab -l 2>/dev/null | grep -v "resolv-check\|smartdns" | crontab - 2>/dev/null; }
    
    if [ -f /etc/resolv.conf.smartdns.orig ]; then
        cat /etc/resolv.conf.smartdns.orig > /etc/resolv.conf; rm -f /etc/resolv.conf.smartdns.orig
    elif [ -f "$RESOLV_FALLBACK" ]; then cat "$RESOLV_FALLBACK" > /etc/resolv.conf
    else cat > /etc/resolv.conf << EOF
nameserver 1.1.1.1
nameserver 8.8.8.8
EOF
    fi
    log_ok "DNS 已恢复"
    
    rm -f /usr/bin/smartdns /usr/sbin/smartdns /usr/local/bin/smartdns
    rm -rf /etc/smartdns; rm -f /var/log/smartdns.log* "$DEPLOY_LOG"
    apt-get remove -y smartdns 2>/dev/null; apk del smartdns 2>/dev/null
    
    echo ""; echo -e "${BOLD}  清理报告:${NC}"; local clean; clean=true
    pgrep smartdns >/dev/null 2>&1 && { echo -e "    ${RED}⚠ SmartDNS 进程残留${NC}"; clean=false; }
    pgrep -f "resolv-guard" >/dev/null 2>&1 && { echo -e "    ${RED}⚠ 守护进程残留${NC}"; clean=false; }
    [ -f /usr/bin/smartdns ] && { echo -e "    ${RED}⚠ 二进制文件残留${NC}"; clean=false; }
    [ -d /etc/smartdns ] && { echo -e "    ${RED}⚠ 配置目录残留${NC}"; clean=false; }
    $clean && echo -e "    ${GREEN}✓ 清理完成，无残留${NC}"
    echo ""; echo -e "${GREEN}  卸载完成${NC}"
}

#==================================================
# 模块7: 三分区菜单
#==================================================
install_shortcut() {
    local script_path=$(readlink -f "$0" 2>/dev/null || echo "$0")
    [ "$script_path" != "$SDNS_CMD" ] && { cp "$script_path" "$SDNS_CMD" 2>/dev/null; chmod +x "$SDNS_CMD" 2>/dev/null; }
}

CACHE_TIME=0; CACHE_S_DOT=""; CACHE_G_DOT=""; CACHE_SYS_DNS=""
CACHE_DOH_G=""; CACHE_DOH_C=""; CACHE_DOT_G=""; CACHE_DOT_C=""
CACHE_UDP_G=""; CACHE_UDP_C=""

get_metrics() {
    local now=$(date +%s)
    if [ -n "$CACHE_S_DOT" ] && [ $((now - CACHE_TIME)) -lt 30 ]; then
        S_DOT="$CACHE_S_DOT"; G_DOT="$CACHE_G_DOT"; SYS_DNS="$CACHE_SYS_DNS"
        DOH_G="$CACHE_DOH_G"; DOH_C="$CACHE_DOH_C"; DOT_G="$CACHE_DOT_G"; DOT_C="$CACHE_DOT_C"
        UDP_G="$CACHE_UDP_G"; UDP_C="$CACHE_UDP_C"
        return
    fi
    
    pgrep smartdns >/dev/null 2>&1 && S_DOT="${GREEN}●${NC}" || S_DOT="${RED}●${NC}"
    pgrep -f resolv-guard >/dev/null 2>&1 && G_DOT="${GREEN}●${NC}" || G_DOT="${RED}●${NC}"
    SYS_DNS=$(grep "^nameserver" /etc/resolv.conf 2>/dev/null | awk '{print $2}' | tr '\n' ' ' | sed 's/ $//')
    [ -z "$SYS_DNS" ] && SYS_DNS="未配置"
    
    if [ -n "$BB" ]; then
        $BB nslookup google.com 8.8.8.8 >/dev/null 2>&1 && UDP_G="${GREEN}●${NC}" || UDP_G="${RED}●${NC}"
        $BB nslookup google.com 1.1.1.1 >/dev/null 2>&1 && UDP_C="${GREEN}●${NC}" || UDP_C="${RED}●${NC}"
    else
        nslookup -timeout=2 google.com 8.8.8.8 >/dev/null 2>&1 && UDP_G="${GREEN}●${NC}" || UDP_G="${RED}●${NC}"
        nslookup -timeout=2 google.com 1.1.1.1 >/dev/null 2>&1 && UDP_C="${GREEN}●${NC}" || UDP_C="${RED}●${NC}"
    fi
    
    LOG_SNIPPET=$(tail -200 /var/log/smartdns.log 2>/dev/null)
    
    if echo "$LOG_SNIPPET" | grep -q "add server.*type: https"; then
        DOH_G="${GREEN}●${NC}"; DOH_C="${GREEN}●${NC}"
    elif grep -q "server-https" /etc/smartdns/smartdns.conf 2>/dev/null; then
        DOH_G="${YELLOW}●${NC}"; DOH_C="${YELLOW}●${NC}"
    else
        DOH_G="${NC}○${NC}"; DOH_C="${NC}○${NC}"
    fi
    
    if echo "$LOG_SNIPPET" | grep -qE "add server (8\.8\.8\.8|8\.8\.4\.4):853.*type: tls"; then
        DOT_G="${GREEN}●${NC}"
    elif grep -q "server-tls.*8.8.8.8" /etc/smartdns/smartdns.conf 2>/dev/null; then
        DOT_G="${YELLOW}●${NC}"
    else
        DOT_G="${NC}○${NC}"
    fi
    
    if echo "$LOG_SNIPPET" | grep -qE "add server (1\.1\.1\.1|1\.0\.0\.1):853.*type: tls"; then
        DOT_C="${GREEN}●${NC}"
    elif grep -q "server-tls.*1.1.1.1" /etc/smartdns/smartdns.conf 2>/dev/null; then
        DOT_C="${YELLOW}●${NC}"
    else
        DOT_C="${NC}○${NC}"
    fi
    
    CACHE_TIME=$now; CACHE_S_DOT="$S_DOT"; CACHE_G_DOT="$G_DOT"; CACHE_SYS_DNS="$SYS_DNS"
    CACHE_DOH_G="$DOH_G"; CACHE_DOH_C="$DOH_C"; CACHE_DOT_G="$DOT_G"; CACHE_DOT_C="$DOT_C"
    CACHE_UDP_G="$UDP_G"; CACHE_UDP_C="$UDP_C"
}

show_menu() {
    get_metrics
    clear 2>/dev/null || echo ""
    printf "%b\n" "${BOLD}┌────────── 系统状态 ──────────┐${NC}"
    printf "  %b SmartDNS  %b 守护\n" "$S_DOT" "$G_DOT"
    printf "  系统 DNS:  %s\n" "$SYS_DNS"
    printf "%b\n" "${BOLD}├────────── 加密 DNS ──────────┤${NC}"
    printf "  DoH Google:     %b\n" "$DOH_G"
    printf "  DoH Cloudflare: %b\n" "$DOH_C"
    printf "  DoT Google:     %b\n" "$DOT_G"
    printf "  DoT Cloudflare: %b\n" "$DOT_C"
    printf "%b\n" "${BOLD}├────────── 常规 UDP ──────────┤${NC}"
    printf "  UDP 8.8.8.8:    %b\n" "$UDP_G"
    printf "  UDP 1.1.1.1:    %b\n" "$UDP_C"
    printf "%b\n" "${BOLD}├──────────────────────────────┤${NC}"
    printf "  1.DNS测试 2.日志 3.配置 4.编辑\n"
    printf "  5.重启   6.清缓存 7.版本 8.卸载\n"
    printf "  0.退出\n"
    printf "%b\n" "${BOLD}└──────────────────────────────┘${NC}"
}

do_log() { clear 2>/dev/null || echo ""; printf "%b\n" "${BOLD}── 日志 ──${NC}"; [ -f /var/log/smartdns.log ] && tail -20 /var/log/smartdns.log || echo "  日志文件不存在"; }

do_test() {
    clear 2>/dev/null || echo ""
    printf "%b\n" "${BOLD}── DNS 测试 ──${NC}"
    for domain in google.com cloudflare.com github.com; do
        printf "  %-20s" "$domain"
        if [ -n "$BB" ]; then RESULT=$($BB nslookup "$domain" 127.0.0.1 2>&1)
        else RESULT=$(nslookup "$domain" 127.0.0.1 2>&1); fi
        printf "%s" "$RESULT" | grep -q "Address" && printf "%b\n" "${GREEN}✓${NC}" || printf "%b\n" "${RED}✗${NC}"
    done
}

do_config() { clear 2>/dev/null || echo ""; printf "%b\n" "${BOLD}── 配置 ──${NC}"; [ -f /etc/smartdns/smartdns.conf ] && grep -v "^#\|^$" /etc/smartdns/smartdns.conf | head -25 || echo "  配置文件不存在"; }

do_edit() {
    if ! command -v nano >/dev/null 2>&1; then pkg_install nano 2 >/dev/null 2>&1; fi
    if command -v nano >/dev/null 2>&1; then nano /etc/smartdns/smartdns.conf
    else vi /etc/smartdns/smartdns.conf; fi
    printf "%b\n" "${YELLOW}  配置已修改，选 5 重启生效${NC}"
}

do_restart() {
    printf "  重启中... "
    case "$INIT_TYPE" in systemd) systemctl restart smartdns 2>/dev/null ;; openrc) rc-service smartdns restart 2>/dev/null ;; *) pkill -x smartdns 2>/dev/null; sleep 1; smartdns -c /etc/smartdns/smartdns.conf & ;; esac
    sleep 2; pgrep smartdns >/dev/null 2>&1 && printf "%b\n" "${GREEN}✓ 已重启${NC}" || printf "%b\n" "${RED}✗ 失败${NC}"
    CACHE_TIME=0
}

do_flush() { pkill -HUP -x smartdns 2>/dev/null && printf "%b\n" "${GREEN}✓ 缓存已清除${NC}" || printf "%b\n" "${RED}✗ 未运行${NC}"; }

do_update() {
    clear 2>/dev/null || echo ""; printf "%b\n" "${BOLD}── 版本管理 ──${NC}"
    if ! command -v curl >/dev/null 2>&1; then printf "%b\n" "${RED}  需要 curl${NC}"; return; fi
    
    CURRENT_TAG=$("$SMARTDNS_BIN" -v 2>&1 | grep 'Release' | head -1 | sed 's/.*\(Release[0-9.]*\).*/\1/')
    printf "  当前版本: %b\n" "${GREEN}${CURRENT_TAG:-未知}${NC}"
    
    LATEST_JSON=$(curl -sL --max-time 10 https://api.github.com/repos/pymumu/smartdns/releases/latest 2>/dev/null)
    LATEST_TAG=$(printf "%s" "$LATEST_JSON" | grep '"tag_name"' | head -1 | sed 's/.*": "//;s/"//')
    printf "  最新版本: %b\n" "${CYAN}${LATEST_TAG:-获取失败}${NC}"
    echo ""
    echo "  1. 升级到最新版"
    echo "  2. 回滚到备份版本"
    echo "  3. 手动指定版本"
    echo "  0. 返回"
    echo ""
    printf "  请选择 [0-3]: "; read -r choice
    
    case "$choice" in
        1) TARGET_TAG="$LATEST_TAG" ;;
        2) if [ -f /usr/bin/smartdns.bak ]; then
               cp /usr/bin/smartdns.bak /usr/bin/smartdns; chmod +x /usr/bin/smartdns
               do_restart; printf "%b\n" "${GREEN}✓ 已回滚${NC}"; return
           else printf "%b\n" "${RED}  无备份文件${NC}"; return; fi ;;
        3) printf "  版本号(如 Release48.1): "; read -r TARGET_TAG ;;
        0) return ;;
        *) echo "  无效选择"; return ;;
    esac
    
    [ -z "$TARGET_TAG" ] && { echo "  版本号不能为空"; return; }
    echo ""; echo "  下载 ${TARGET_TAG}..."
    ARCH=$(get_arch); URL="https://github.com/pymumu/smartdns/releases/download/${TARGET_TAG}/smartdns-${ARCH}"
    
    if github_download "$URL" "/tmp/smartdns-new"; then
        cp /usr/bin/smartdns /usr/bin/smartdns.bak 2>/dev/null
        mv /tmp/smartdns-new /usr/bin/smartdns; chmod +x /usr/bin/smartdns
        SMARTDNS_BIN="/usr/bin/smartdns"; do_restart
        printf "%b\n" "${GREEN}✓ 切换完成${NC}"
    else printf "%b\n" "${RED}✗ 下载失败${NC}"; fi
}

module_menu() {
    install_shortcut
    if [ $# -gt 0 ]; then
        case "$1" in
            s|status) get_metrics; printf "DNS:%b 守护:%b\n" "$S_DOT" "$G_DOT"; return ;;
            l|log) do_log; return ;; t|test) do_test; return ;;
            c|config) do_config; return ;; e|edit) do_edit; return ;; r|restart) do_restart; return ;;
            f|flush) do_flush; return ;; u|update) do_update; return ;; uninstall) module_uninstall; return ;;
            *) echo "用法: sdns [s|l|t|c|e|r|f|u|uninstall]"; return ;;
        esac
    fi
    while true; do
        show_menu
        printf "请选择 [0-8]: "; read -r choice 2>/dev/null || { echo ""; break; }
        case "$choice" in
            1) do_test ;; 2) do_log ;; 3) do_config ;; 4) do_edit ;;
            5) do_restart ;; 6) do_flush ;; 7) do_update ;; 8) module_uninstall; break ;;
            0) break ;;
        esac
        [ "$choice" != "0" ] && [ "$choice" != "8" ] && { printf "按回车返回..."; read -r _ 2>/dev/null || break; }
    done
}

main() {
    if [ "$(readlink -f "$0" 2>/dev/null || echo "$0")" = "$SDNS_CMD" ]; then
        [ -f /etc/smartdns/smartdns.conf ] && PORT=$(grep "^bind" /etc/smartdns/smartdns.conf | grep -o '[0-9]*$' | head -1); [ -z "$PORT" ] && PORT=53
        [ -f /etc/alpine-release ] && OS_TYPE="alpine"; [ -d /run/systemd/system ] && INIT_TYPE="systemd"
        detect_busybox; detect_inotify; module_menu "$@"; exit 0
    fi
    for arg in "$@"; do case "$arg" in --uninstall|-u) module_uninstall; exit 0 ;; esac; done
    
    echo ""; printf "%b\n" "${BOLD}SmartDNS 智能部署 v7.7.0-alt7${NC}"; echo "上游: Google + Cloudflare (DoH/DoT/UDP)"; echo "环境: Alpine/Debian (LXC/KVM/Podman)"; echo ""
    module_detect; module_install; module_config; module_dns_takeover; module_service; module_verify
    echo ""; printf "%b\n" "管理命令: ${GREEN}sdns${NC}"; echo "  sdns t  测试  sdns l  日志  sdns c  配置  sdns u  版本管理"; echo "  sdns    菜单"
    module_menu
}

main "$@"
