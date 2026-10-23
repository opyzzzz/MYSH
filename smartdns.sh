#!/bin/sh
#==========================================================================
# SmartDNS 智能部署脚本 v7.9.0
# 包管理器优先安装 | DoH 默认启用 + UDP 兜底 | 菜单可切换上游
# 完整支持 systemd / OpenRC | 适配 LXC 检测 | 显示崩溃与重启次数
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
IS_VER_NEW=false; PORT=53
OS_TYPE=""; OS_VER=""; INIT_TYPE=""; VIRT_TYPE=""; VIRT_IS_CONTAINER=false
NET_STACK=""; HAS_IPV4=true; HAS_IPV6=false
TAKEOVER_STRATEGY="standard"
SYSTEMD_RESOLVED_RUNNING=false; TMPFILES_HAS_RESOLV=false
DEPLOY_LOG="/var/log/smartdns-deploy.log"
ARCH=""; PKG_MGR=""
INOTIFY_CMD=""
PID_FILE="/run/resolv-guard.pid"
GUARD_SCRIPT="/usr/local/bin/resolv-guard.sh"
SDNS_CMD="/usr/local/bin/sdns"
UPSTREAM_MODE_FILE="/etc/smartdns/upstream-mode"
RESOLV_TEMPLATE="/etc/smartdns/resolv.smartdns"
RESOLV_FALLBACK="/etc/smartdns/resolv.fallback"
APT_UPDATED=false; BB=""

detect_busybox() { command -v busybox >/dev/null 2>&1 && BB="busybox"; }

pkg_install() {
    local pkgs="$1" max_retry="${2:-3}" attempt=1
    [ -z "$pkgs" ] && return 0
    while [ "$attempt" -le "$max_retry" ]; do
        case "$PKG_MGR" in
            apk) apk add --no-cache $pkgs 2>/dev/null && return 0 ;;
            apt)
                for i in $(seq 1 30); do fuser /var/lib/dpkg/lock-frontend 2>/dev/null && sleep 1 || break; done
                $APT_UPDATED || { apt-get update -qq 2>/dev/null && APT_UPDATED=true; }
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

get_version_number() {
    local ver_output=$("$1" -v 2>&1)
    echo "$ver_output" | grep -o 'Release[0-9]*' | grep -o '[0-9]*' | head -1
}

# LXC 适配：优先 fuser 查 UDP
port_in_use_udp() { fuser "$1/udp" >/dev/null 2>&1; }

check_ipv6_connectivity() {
    ip route get 2606:4700:4700::1111 >/dev/null 2>&1 || return 1
    if [ -n "$BB" ]; then
        $BB nslookup google.com 2001:4860:4860::8888 >/dev/null 2>&1 && return 0
    else
        nslookup -timeout=3 google.com 2001:4860:4860::8888 >/dev/null 2>&1 && return 0
    fi
    return 1
}

ensure_tools() {
    if ! command -v wget >/dev/null 2>&1 && ! command -v curl >/dev/null 2>&1; then
        pkg_install wget || pkg_install curl || { log_err "无法安装下载工具"; exit 1; }
    fi
    detect_busybox
    if [ -z "$BB" ] && [ "$PKG_MGR" = "apk" ]; then pkg_install busybox 2; detect_busybox; fi
    if ! command -v inotifywait >/dev/null 2>&1 && ! command -v inotifyd >/dev/null 2>&1; then
        pkg_install inotify-tools 2
    fi
    if ! command -v dig >/dev/null 2>&1; then
        case "$PKG_MGR" in apk) pkg_install bind-tools 2 ;; apt) pkg_install dnsutils 2 ;; esac
    fi
}

detect_inotify() {
    if command -v inotifywait >/dev/null 2>&1; then INOTIFY_CMD="inotifywait"; return 0; fi
    if command -v inotifyd >/dev/null 2>&1; then INOTIFY_CMD="inotifyd"; return 0; fi
    INOTIFY_CMD=""; return 1
}

safe_rc_add() {
    local service="$1" runlevel="${2:-default}"
    if ! rc-update show 2>/dev/null | grep -q "$service.*$runlevel"; then
        rc-update add "$service" "$runlevel" 2>/dev/null
    fi
}

write_resolv() {
    [ -L /etc/resolv.conf ] && rm -f /etc/resolv.conf
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
    grep -qE "docker|podman" /proc/1/cgroup 2>/dev/null && VIRT_TYPE="podman"
    grep -q "container=lxc" /proc/1/environ 2>/dev/null && VIRT_TYPE="lxc"
    [ -f /.dockerenv ] || [ -f /run/.containerenv ] && VIRT_TYPE="podman"
    case "$VIRT_TYPE" in podman|docker|lxc) VIRT_IS_CONTAINER=true ;; *) VIRT_IS_CONTAINER=false ;; esac
    log_info "虚拟化: $VIRT_TYPE (容器: $VIRT_IS_CONTAINER)"

    ARCH=$(get_arch); ensure_tools

    HAS_IPV4=true; ip route get 1.1.1.1 >/dev/null 2>&1 || HAS_IPV4=false
    check_ipv6_connectivity && HAS_IPV6=true || HAS_IPV6=false
    if [ "$HAS_IPV4" = true ] && [ "$HAS_IPV6" = true ]; then NET_STACK="双栈"
    elif [ "$HAS_IPV4" = true ]; then NET_STACK="纯IPv4"; else NET_STACK="纯IPv6"; fi
    log_info "网络栈: $NET_STACK (IPv4: $HAS_IPV4, IPv6: $HAS_IPV6)"

    TMPFILES_HAS_RESOLV=false
    if find /usr/lib/tmpfiles.d/ /etc/tmpfiles.d/ -maxdepth 1 -type f -exec grep -l "/etc/resolv.conf" {} \; 2>/dev/null | grep -q .; then
        TMPFILES_HAS_RESOLV=true; log_warn "tmpfiles.d 管理 resolv.conf"
    fi
    if command -v resolvectl >/dev/null 2>&1 && resolvectl status >/dev/null 2>&1; then
        SYSTEMD_RESOLVED_RUNNING=true; log_warn "systemd-resolved 运行中"
    fi

    if $SYSTEMD_RESOLVED_RUNNING; then TAKEOVER_STRATEGY="resolved"
    else TAKEOVER_STRATEGY="standard"; fi
    log_ok "接管策略: $TAKEOVER_STRATEGY"
}

#==================================================
# 模块1: 安装 SmartDNS（包管理器优先，GitHub 需验证）
#==================================================
module_install() {
    log_step "模块1: 安装 SmartDNS (包管理器优先)"

    # 清理可能覆盖包管理器版本的旧二进制
    rm -f /usr/local/bin/smartdns /usr/bin/smartdns.bak 2>/dev/null
    pkill -x smartdns 2>/dev/null; sleep 1

    log_info "尝试包管理器安装..."
    if pkg_install smartdns 3; then
        for p in /usr/sbin/smartdns /usr/bin/smartdns; do
            [ -x "$p" ] && { SMARTDNS_BIN="$p"; break; }
        done
        [ -z "$SMARTDNS_BIN" ] && SMARTDNS_BIN=$(command -v smartdns 2>/dev/null)
        [ -n "$SMARTDNS_BIN" ] && SMARTDNS_SOURCE="$PKG_MGR"
    fi

    # 备选：GitHub，必须通过前台启动测试
    if [ -z "$SMARTDNS_BIN" ]; then
        log_warn "包管理器安装失败，尝试 GitHub 下载（需通过启动测试）"
        URL="https://github.com/pymumu/smartdns/releases/latest/download/smartdns-${ARCH}"
        if github_download "$URL" /tmp/smartdns-test; then
            chmod +x /tmp/smartdns-test
            timeout 5 /tmp/smartdns-test -f -c /dev/null >/dev/null 2>&1
            rc=$?
            if [ "$rc" -eq 124 ] || [ "$rc" -eq 0 ]; then
                mv /tmp/smartdns-test /usr/local/bin/smartdns
                SMARTDNS_BIN="/usr/local/bin/smartdns"; SMARTDNS_SOURCE="GitHub"
            else
                log_err "GitHub 二进制启动测试失败 (rc=$rc)，放弃"
                rm -f /tmp/smartdns-test
            fi
        fi
    fi

    [ -z "$SMARTDNS_BIN" ] && { log_err "所有安装方式均失败"; exit 1; }

    SMARTDNS_VER=$("$SMARTDNS_BIN" -v 2>&1 | head -1)
    SMARTDNS_VER_NUM=$(get_version_number "$SMARTDNS_BIN")
    [ "$SMARTDNS_VER_NUM" -ge 42 ] 2>/dev/null && IS_VER_NEW=true || IS_VER_NEW=false
    log_info "版本: $SMARTDNS_VER (来源: $SMARTDNS_SOURCE)"
    [ "$SMARTDNS_SOURCE" = "apt" ] && log_info "Debian 源版本较老，配置将自动降级兼容"
}

#==================================================
# 模块2: 生成配置与 DNS 模板
#==================================================
module_config() {
    log_step "模块2: 生成配置与 DNS 模板"
    mkdir -p /etc/smartdns
    [ -f /etc/smartdns/smartdns.conf ] && cp /etc/smartdns/smartdns.conf "/etc/smartdns/smartdns.conf.bak.$(date +%Y%m%d-%H%M%S)" 2>/dev/null

    if [ "$HAS_IPV6" = true ] && [ "$HAS_IPV4" = true ]; then
        printf "nameserver 127.0.0.1\nnameserver ::1\noptions edns0 trust-ad\n" > "$RESOLV_TEMPLATE"
        printf "nameserver 1.1.1.1\nnameserver 8.8.8.8\nnameserver 2606:4700:4700::1111\nnameserver 2001:4860:4860::8888\n" > "$RESOLV_FALLBACK"
    elif [ "$HAS_IPV6" = true ]; then
        printf "nameserver ::1\noptions edns0 trust-ad\n" > "$RESOLV_TEMPLATE"
        printf "nameserver 2606:4700:4700::1111\nnameserver 2001:4860:4860::8888\n" > "$RESOLV_FALLBACK"
    else
        printf "nameserver 127.0.0.1\noptions edns0 trust-ad\n" > "$RESOLV_TEMPLATE"
        printf "nameserver 1.1.1.1\nnameserver 8.8.8.8\n" > "$RESOLV_FALLBACK"
    fi
    log_ok "DNS 模板已生成: $RESOLV_TEMPLATE"

    [ "$TAKEOVER_STRATEGY" = "resolved" ] && systemctl stop systemd-resolved 2>/dev/null

    PORT=53
    if port_in_use_udp 53; then
        log_warn "UDP 53 被占用"
        for p in 5353 5354; do
            if ! port_in_use_udp "$p"; then PORT="$p"; log_warn "使用备用端口: $PORT"; break; fi
        done
    else log_ok "UDP 53 可用"; fi

    MODE="doh_udp"
    [ -f "$UPSTREAM_MODE_FILE" ] && MODE=$(cat "$UPSTREAM_MODE_FILE" 2>/dev/null)
    [ -z "$MODE" ] && MODE="doh_udp"

    write_config "$MODE"
    log_ok "配置已生成: /etc/smartdns/smartdns.conf (上游模式: $MODE)"
}

write_config() {
    local mode="$1"
    cat > /etc/smartdns/smartdns.conf << EOF
# SmartDNS 配置 v7.9.0 (包管理器兼容版)
# 环境: $OS_TYPE $OS_VER | $VIRT_TYPE | $NET_STACK
# 版本: $SMARTDNS_VER | 来源: $SMARTDNS_SOURCE
# 上游模式: $mode
server-name smartdns
bind :${PORT}
cache-size 4096
prefetch-domain yes
speed-check-mode tcp:443
EOF

    if [ "$HAS_IPV6" = false ]; then
        echo "force-AAAA-SOA yes" >> /etc/smartdns/smartdns.conf
    fi

    case "$mode" in
        doh_udp)
            cat >> /etc/smartdns/smartdns.conf << 'EOF'

# 加密上游（保守写法）
server-https https://dns.google/dns-query
server-https https://cloudflare-dns.com/dns-query

# UDP 兜底
server 8.8.8.8
server 1.1.1.1
EOF
            ;;
        udp_only)
            cat >> /etc/smartdns/smartdns.conf << 'EOF'

# 纯 UDP 上游
server 8.8.8.8
server 1.1.1.1
server 8.8.4.4
EOF
            ;;
    esac

    # 增强层：仅新版 + 非容器
    if [ "$IS_VER_NEW" = true ] && [ "$VIRT_IS_CONTAINER" = false ] && [ "$mode" = "doh_udp" ]; then
        cat >> /etc/smartdns/smartdns.conf << 'EOF'

upstream-group secure
server-https https://dns.google/dns-query -group secure
server-https https://cloudflare-dns.com/dns-query -group secure
upstream-group fallback
server 8.8.8.8 -group fallback
server 1.1.1.1 -group fallback
EOF
    fi
    echo "$mode" > "$UPSTREAM_MODE_FILE"
}

#==================================================
# 模块3: 接管系统 DNS
#==================================================
module_dns_takeover() {
    log_step "模块3: 接管系统 DNS (策略: $TAKEOVER_STRATEGY)"
    detect_inotify
    [ -z "$INOTIFY_CMD" ] && log_warn "inotify 不可用，使用 5 秒轮询" || log_info "inotify: $INOTIFY_CMD"

    if [ ! -f /etc/resolv.conf.smartdns.orig ]; then
        if [ -L /etc/resolv.conf ]; then cat /etc/resolv.conf > /etc/resolv.conf.smartdns.orig 2>/dev/null
        else cp /etc/resolv.conf /etc/resolv.conf.smartdns.orig 2>/dev/null; fi
    fi

    local dns_list; local dns_yaml; local dns_list_grep
    dns_list=$(grep "^nameserver" "$RESOLV_TEMPLATE" 2>/dev/null | awk '{print $2}' | tr '\n' ' ' | sed 's/ $//')
    [ -z "$dns_list" ] && { [ "$HAS_IPV4" = true ] && dns_list="127.0.0.1" || dns_list="::1"; }
    dns_yaml=""
    for ip in $dns_list; do
        [ -z "$dns_yaml" ] && dns_yaml="'$ip'" || dns_yaml="$dns_yaml, '$ip'"
    done
    dns_list_grep=$(echo "$dns_list" | awk '{print $1}')

    BACKUP_LIST="/etc/smartdns/dns-config-backup.txt"
    > "$BACKUP_LIST"

    # 1. systemd-resolved
    if [ "$INIT_TYPE" = "systemd" ] && command -v resolvectl >/dev/null 2>&1; then
        mkdir -p /etc/systemd/resolved.conf.d
        cat > /etc/systemd/resolved.conf.d/smartdns.conf << EOF
[Resolve]
DNS=${dns_list}
DNSStubListener=no
EOF
        echo "/etc/systemd/resolved.conf.d/smartdns.conf:DELETE" >> "$BACKUP_LIST"
        systemctl restart systemd-resolved 2>/dev/null
        [ -L /etc/resolv.conf ] && { rm -f /etc/resolv.conf; write_resolv; }
        if [ "$TMPFILES_HAS_RESOLV" = true ]; then
            mkdir -p /etc/tmpfiles.d
            printf "# SmartDNS 接管\n" > /etc/tmpfiles.d/systemd-resolved.conf
            echo "/etc/tmpfiles.d/systemd-resolved.conf:DELETE" >> "$BACKUP_LIST"
        fi
        log_info "systemd-resolved: 上游 → ${dns_list}"
    fi

    # 2. dhclient
    if [ "$HAS_IPV4" = true ] && [ -f /etc/dhcp/dhclient.conf ]; then
        cp /etc/dhcp/dhclient.conf /etc/dhcp/dhclient.conf.smartdns.bak 2>/dev/null
        echo "/etc/dhcp/dhclient.conf:RESTORE:/etc/dhcp/dhclient.conf.smartdns.bak" >> "$BACKUP_LIST"
        grep -q "supersede domain-name-servers 127.0.0.1" /etc/dhcp/dhclient.conf 2>/dev/null || \
            echo "supersede domain-name-servers 127.0.0.1;" >> /etc/dhcp/dhclient.conf
        log_info "dhclient: DNS → 127.0.0.1"
    fi

    # 3. udhcpc
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

    # 4. systemd-networkd
    if [ "$INIT_TYPE" = "systemd" ] && [ -d /etc/systemd/network ]; then
        for netconf in /etc/systemd/network/*.network; do
            [ -f "$netconf" ] || continue
            grep -q "DNS=${dns_list_grep}" "$netconf" 2>/dev/null && continue
            cp "$netconf" "${netconf}.smartdns.bak" 2>/dev/null
            echo "${netconf}:RESTORE:${netconf}.smartdns.bak" >> "$BACKUP_LIST"
            printf "\n[Network]\nDNS=%s\n" "$dns_list" >> "$netconf"
            log_info "systemd-networkd: DNS → ${dns_list}"
        done
    fi

    # 5. NetworkManager
    if command -v nmcli >/dev/null 2>&1; then
        local conn; conn=$(nmcli -t -f NAME con show --active 2>/dev/null | head -1)
        if [ -n "$conn" ]; then
            [ "$HAS_IPV4" = true ] && {
                nmcli con mod "$conn" ipv4.dns 127.0.0.1 2>/dev/null
                nmcli con mod "$conn" ipv4.ignore-auto-dns yes 2>/dev/null
            }
            [ "$HAS_IPV6" = true ] && {
                nmcli con mod "$conn" ipv6.dns ::1 2>/dev/null
                nmcli con mod "$conn" ipv6.ignore-auto-dns yes 2>/dev/null
            }
            printf "%s\n" "$conn" > /etc/smartdns/nm-conn.txt
            log_info "NetworkManager: DNS → ${dns_list}"
        fi
    fi

    # 6. Alpine ifupdown
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

    [ "$TAKEOVER_STRATEGY" != "resolved" ] && write_resolv
    cat "$RESOLV_TEMPLATE" > /etc/resolv.conf.smartdns.bak; chmod 644 /etc/resolv.conf.smartdns.bak 2>/dev/null

    if [ -L /etc/resolv.conf ]; then
        log_warn "resolv.conf 仍为软链接，强制替换"
        rm -f /etc/resolv.conf
        write_resolv
    fi

    # 第二层：启动覆盖
    if [ "$INIT_TYPE" = "openrc" ]; then
        mkdir -p /etc/local.d
        cat > /etc/local.d/resolv-fix.start << LSTART
#!/bin/sh
sleep 5
for i in 1 2 3 4 5; do cmp -s ${RESOLV_TEMPLATE} /etc/resolv.conf 2>/dev/null && exit 0; sleep 1; done
[ -L /etc/resolv.conf ] && rm -f /etc/resolv.conf
cat ${RESOLV_TEMPLATE} > /etc/resolv.conf
LSTART
        chmod +x /etc/local.d/resolv-fix.start
        safe_rc_add local default
        log_ok "local.d 启动覆盖已创建"
    elif [ "$INIT_TYPE" = "systemd" ]; then
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
        systemctl daemon-reload 2>/dev/null
        systemctl enable resolv-fix.service 2>/dev/null
        log_ok "systemd oneshot 启动覆盖已创建"
    fi

    # 第三层：文件守护
    cat > "$GUARD_SCRIPT" << GUARD
#!/bin/sh
TARGET="/etc/resolv.conf"; TEMPLATE="${RESOLV_TEMPLATE}"
restore_dns() {
    [ -f "\$TEMPLATE" ] || return 0
    if [ -L "\$TARGET" ]; then rm -f "\$TARGET"; cat "\$TEMPLATE" > "\$TARGET" 2>/dev/null; return 0; fi
    ! cmp -s "\$TEMPLATE" "\$TARGET" 2>/dev/null && cat "\$TEMPLATE" > "\$TARGET" 2>/dev/null
}
if command -v inotifywait >/dev/null 2>&1; then
    while true; do inotifywait -m -e modify,close_write "\$TARGET" 2>/dev/null | while read -r path event file; do sleep 0.5; restore_dns; done; sleep 1; done
elif command -v inotifyd >/dev/null 2>&1; then
    while true; do inotifyd - "\$TARGET" 2>/dev/null | while read -r event file; do case "\$event" in w|m|c) sleep 0.5; restore_dns ;; esac; done; sleep 1; done
else
    while true; do sleep 5; restore_dns; done
fi
GUARD
    chmod 700 "$GUARD_SCRIPT"

    [ -f "$PID_FILE" ] && { OLD_PID=$(cat "$PID_FILE" 2>/dev/null); [ -n "$OLD_PID" ] && kill "$OLD_PID" 2>/dev/null; rm -f "$PID_FILE"; }
    sleep 0.5

    if [ "$INIT_TYPE" = "systemd" ]; then
        cat > /etc/systemd/system/resolv-guard.service << 'GSTART'
[Unit]
Description=DNS Resolv Guard
After=smartdns.service resolv-fix.service
[Service]
Type=simple
ExecStart=/usr/local/bin/resolv-guard.sh
Restart=always
RestartSec=5
[Install]
WantedBy=multi-user.target
GSTART
        systemctl daemon-reload 2>/dev/null
        systemctl enable resolv-guard.service 2>/dev/null
    elif [ "$INIT_TYPE" = "openrc" ]; then
        mkdir -p /etc/local.d
        cat > /etc/local.d/resolv-guard.start << 'OGSTART'
#!/bin/sh
/usr/local/bin/resolv-guard.sh &
echo $! > /run/resolv-guard.pid
OGSTART
        chmod +x /etc/local.d/resolv-guard.start
        "$GUARD_SCRIPT" &
        echo $! > "$PID_FILE"
        safe_rc_add local default
    else
        "$GUARD_SCRIPT" &
        echo $! > "$PID_FILE"
    fi

    local issues=0
    [ -L /etc/resolv.conf ] && { log_warn "resolv.conf 仍是软链接"; issues=$((issues+1)); }
    [ -f /etc/systemd/resolved.conf.d/smartdns.conf ] && ! grep -q "DNS=" /etc/systemd/resolved.conf.d/smartdns.conf && issues=$((issues+1))
    [ $issues -eq 0 ] && log_ok "DNS 源头已全部指向 SmartDNS" || log_warn "发现 $issues 处可能未生效"
    log_ok "DNS 三重防护已部署"
}

#==================================================
# 模块4: 服务部署
#==================================================
module_service() {
    log_step "模块4: 部署 SmartDNS 服务"
    pkill -x smartdns 2>/dev/null; sleep 1
    rm -rf /var/cache/smartdns/ 2>/dev/null

    case "$INIT_TYPE" in
        systemd)
            cat > /etc/systemd/system/smartdns.service << SVC
[Unit]
Description=SmartDNS Server
After=network-online.target
Wants=network-online.target
[Service]
Type=forking
ExecStart=${SMARTDNS_BIN} -c /etc/smartdns/smartdns.conf -p /run/smartdns.pid
PIDFile=/run/smartdns.pid
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=5
# 注意：不设置 WatchdogSec，SmartDNS 不发送 WATCHDOG=1
[Install]
WantedBy=multi-user.target
SVC
            systemctl daemon-reload
            systemctl enable smartdns 2>/dev/null
            systemctl restart smartdns
            sleep 3
            ;;
        openrc)
            cat > /etc/init.d/smartdns << OSVC
#!/sbin/openrc-run
name="SmartDNS"
command="${SMARTDNS_BIN}"
command_args="-c /etc/smartdns/smartdns.conf -p /run/smartdns.pid"
command_background=true
pidfile="/run/smartdns.pid"
depend() { need net; after firewall; }
OSVC
            chmod +x /etc/init.d/smartdns
            safe_rc_add smartdns default
            rc-service smartdns restart 2>/dev/null
            sleep 3
            ;;
        *)
            "$SMARTDNS_BIN" -c /etc/smartdns/smartdns.conf &
            sleep 3
            ;;
    esac

    [ "$INIT_TYPE" = "systemd" ] && systemctl start resolv-guard.service 2>/dev/null

    local ok=true
    pgrep -x smartdns >/dev/null 2>&1 || ok=false
    if $ok && command -v dig >/dev/null 2>&1; then
        dig @127.0.0.1 google.com +short +time=3 +tries=1 2>/dev/null | grep -qE '^[0-9]' || ok=false
    fi
    if $ok; then
        log_ok "SmartDNS 已启动并正常解析"
    else
        log_err "启动或解析异常，诊断："
        [ "$INIT_TYPE" = "systemd" ] && journalctl -u smartdns --no-pager -n 20 2>/dev/null
        log_warn "端口 ${PORT} 占用："
        command -v ss >/dev/null 2>&1 && { ss -tlnp 2>/dev/null | grep ":${PORT}" || echo "  (ss 无输出)"; }
        fuser "${PORT}/udp" 2>&1 || echo "  (UDP 端口未占用)"
        exit 1
    fi
}

#==================================================
# 模块5: 验证
#==================================================
module_verify() {
    log_step "模块5: 验证"
    sleep 2
    if [ "$HAS_IPV4" = true ] && command -v dig >/dev/null 2>&1; then
        for d in google.com cloudflare.com; do
            IP=$(dig @127.0.0.1 "$d" +short +time=3 +tries=1 2>/dev/null | grep -E '^[0-9]' | head -1)
            [ -n "$IP" ] && log_ok "$d → $IP" || log_warn "$d 解析失败"
        done
    fi

    { echo ""; echo "===== SmartDNS 部署日志 ====="; echo "时间: $(date)"; echo "系统: $OS_TYPE $OS_VER | $VIRT_TYPE | $NET_STACK"; echo "版本: $SMARTDNS_VER ($SMARTDNS_SOURCE) | 端口: $PORT"; echo "模式: $(cat "$UPSTREAM_MODE_FILE" 2>/dev/null)"; echo "=============================="; } >> "$DEPLOY_LOG"

    printf "\n%b部署摘要%b\n" "$BOLD" "$NC"
    printf "  系统: %s %s (%s)\n" "$OS_TYPE" "$OS_VER" "$VIRT_TYPE"
    printf "  版本: %s (来源: %s)\n" "$SMARTDNS_VER" "$SMARTDNS_SOURCE"
    printf "  模式: %s\n" "$(cat "$UPSTREAM_MODE_FILE" 2>/dev/null)"
    printf "  管理: %bsdns%b 进入菜单\n" "$GREEN" "$NC"
}

#==================================================
# 模块6: 卸载
#==================================================
module_uninstall() {
    printf "\n%b确认卸载 SmartDNS？输入 yes: %b" "$YELLOW" "$NC"
    read -r confirm
    case "$confirm" in yes|YES|Yes|y|Y) ;; *) echo "已取消"; return ;; esac

    [ -z "$INIT_TYPE" ] && { [ -d /run/systemd/system ] && INIT_TYPE="systemd" || INIT_TYPE="openrc"; }

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

    [ -f "$PID_FILE" ] && { GUARD_PID=$(cat "$PID_FILE" 2>/dev/null); [ -n "$GUARD_PID" ] && { kill "$GUARD_PID" 2>/dev/null; sleep 0.5; kill -9 "$GUARD_PID" 2>/dev/null; }; rm -f "$PID_FILE"; }
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
    fi
    if [ -f /etc/smartdns/nm-conn.txt ] && command -v nmcli >/dev/null 2>&1; then
        CONN=$(cat /etc/smartdns/nm-conn.txt 2>/dev/null)
        [ -n "$CONN" ] && { nmcli con mod "$CONN" ipv4.ignore-auto-dns no 2>/dev/null; nmcli con mod "$CONN" ipv4.dns "" 2>/dev/null; }
    fi

    rm -f "$GUARD_SCRIPT" "$SDNS_CMD" /etc/resolv.conf.smartdns.bak
    [ -f /etc/tmpfiles.d/systemd-resolved.conf ] && grep -q "SmartDNS" /etc/tmpfiles.d/systemd-resolved.conf 2>/dev/null && rm -f /etc/tmpfiles.d/systemd-resolved.conf
    crontab -l 2>/dev/null | grep -q "resolv-check\|smartdns" && crontab -l 2>/dev/null | grep -v "resolv-check\|smartdns" | crontab - 2>/dev/null

    if [ -f /etc/resolv.conf.smartdns.orig ]; then
        cat /etc/resolv.conf.smartdns.orig > /etc/resolv.conf; rm -f /etc/resolv.conf.smartdns.orig
    elif [ -f "$RESOLV_FALLBACK" ]; then cat "$RESOLV_FALLBACK" > /etc/resolv.conf
    else printf "nameserver 1.1.1.1\nnameserver 8.8.8.8\n" > /etc/resolv.conf
    fi
    log_ok "DNS 已恢复"

    rm -f /usr/bin/smartdns /usr/sbin/smartdns /usr/local/bin/smartdns
    rm -rf /etc/smartdns; rm -f /var/log/smartdns.log* "$DEPLOY_LOG" /run/smartdns.pid
    [ "$SMARTDNS_SOURCE" = "apt" ] && apt-get remove -y smartdns 2>/dev/null
    [ "$SMARTDNS_SOURCE" = "apk" ] && apk del smartdns 2>/dev/null

    printf "%b卸载完成%b\n" "$GREEN" "$NC"
}

#==================================================
# 模块7: 菜单（LXC 适配 + 崩溃显示）
#==================================================
install_shortcut() {
    local sp=$(readlink -f "$0" 2>/dev/null || echo "$0")
    [ "$sp" != "$SDNS_CMD" ] && { cp "$sp" "$SDNS_CMD" 2>/dev/null; chmod +x "$SDNS_CMD" 2>/dev/null; }
}

CACHE_TIME=0
CACHE_S=""; CACHE_G=""; CACHE_SYS=""; CACHE_MODE=""; CACHE_RESTART=""; CACHE_CRASH=""

get_metrics() {
    local now=$(date +%s)
    [ -n "$CACHE_S" ] && [ $((now - CACHE_TIME)) -lt 15 ] && return

    pgrep -x smartdns >/dev/null 2>&1 && S_DOT="${GREEN}●${NC}" || S_DOT="${RED}●${NC}"
    pgrep -f resolv-guard >/dev/null 2>&1 && G_DOT="${GREEN}●${NC}" || G_DOT="${RED}●${NC}"
    SYS_DNS=$(grep "^nameserver" /etc/resolv.conf 2>/dev/null | awk '{print $2}' | tr '\n' ' ' | sed 's/ $//')
    [ -z "$SYS_DNS" ] && SYS_DNS="未配置"
    MODE=$(cat "$UPSTREAM_MODE_FILE" 2>/dev/null || echo "doh_udp")
    RESTART_N=$(systemctl show smartdns -p NRestarts --value 2>/dev/null || echo "0")
    CRASH_N=0
    [ "$INIT_TYPE" = "systemd" ] && CRASH_N=$(journalctl -u smartdns --no-pager 2>/dev/null | grep -c "signal 6")
    [ -f /var/log/smartdns.log ] && CRASH_N=$((CRASH_N + $(grep -c "signal 6" /var/log/smartdns.log 2>/dev/null)))

    CACHE_S="$S_DOT"; CACHE_G="$G_DOT"; CACHE_SYS="$SYS_DNS"
    CACHE_MODE="$MODE"; CACHE_RESTART="$RESTART_N"; CACHE_CRASH="$CRASH_N"
    CACHE_TIME=$now
}

show_menu() {
    get_metrics
    clear 2>/dev/null || echo ""
    printf "%b┌────────── 系统状态 ──────────┐%b\n" "$BOLD" "$NC"
    printf "  SmartDNS: %b    守护: %b\n" "$S_DOT" "$G_DOT"
    printf "  系统 DNS: %s\n" "$SYS_DNS"
    printf "  上游模式: %s\n" "$MODE"
    printf "  自动重启: %s 次    崩溃(signal 6): %s 次\n" "$RESTART_N" "$CRASH_N"
    printf "%b├──────────────────────────────┤%b\n" "$BOLD" "$NC"
    printf "  1.测试 2.日志 3.配置 4.编辑\n"
    printf "  5.重启 6.清缓存 7.版本 8.卸载\n"
    printf "  9.切换上游 0.退出\n"
    printf "%b└──────────────────────────────┘%b\n" "$BOLD" "$NC"
}

do_test() {
    clear 2>/dev/null || echo ""
    printf "%b── DNS 测试 ──%b\n" "$BOLD" "$NC"
    if ! command -v dig >/dev/null 2>&1; then
        printf "%b  dig 不可用，请安装 dnsutils/bind-tools%b\n" "$YELLOW" "$NC"; return
    fi
    for d in google.com cloudflare.com github.com; do
        printf "  %-18s" "$d"
        dig @127.0.0.1 "$d" +short +time=3 +tries=1 2>/dev/null | grep -qE '^[0-9]' && \
            printf "%b✓%b\n" "$GREEN" "$NC" || printf "%b✗%b\n" "$RED" "$NC"
    done
}

do_log() {
    clear 2>/dev/null || echo ""
    if [ -f /var/log/smartdns.log ]; then tail -30 /var/log/smartdns.log
    elif [ "$INIT_TYPE" = "systemd" ]; then journalctl -u smartdns --no-pager -n 30 2>/dev/null
    else echo "无日志"; fi
}

do_config() { clear 2>/dev/null || echo ""; [ -f /etc/smartdns/smartdns.conf ] && grep -v "^#\|^$" /etc/smartdns/smartdns.conf || echo "配置不存在"; }

do_edit() {
    command -v nano >/dev/null 2>&1 || pkg_install nano 2 >/dev/null 2>&1
    command -v nano >/dev/null 2>&1 && nano /etc/smartdns/smartdns.conf || vi /etc/smartdns/smartdns.conf
    printf "%b修改后选 5 重启生效%b\n" "$YELLOW" "$NC"
}

do_restart() {
    printf "  重启中..."
    case "$INIT_TYPE" in
        systemd) systemctl restart smartdns 2>/dev/null ;;
        openrc) rc-service smartdns restart 2>/dev/null ;;
        *) pkill -x smartdns 2>/dev/null; sleep 1; "$SMARTDNS_BIN" -c /etc/smartdns/smartdns.conf & ;;
    esac
    sleep 2
    pgrep -x smartdns >/dev/null 2>&1 && printf " %b✓%b\n" "$GREEN" "$NC" || printf " %b✗%b\n" "$RED" "$NC"
    CACHE_TIME=0
}

do_flush() { pkill -HUP -x smartdns 2>/dev/null && printf "%b✓ 缓存已清除%b\n" "$GREEN" "$NC" || printf "%b✗ 未运行%b\n" "$RED" "$NC"; }

do_switch_upstream() {
    clear 2>/dev/null || echo ""
    printf "%b── 切换上游 ──%b\n" "$BOLD" "$NC"
    printf "  当前: %s\n\n" "$(cat "$UPSTREAM_MODE_FILE" 2>/dev/null)"
    printf "  1. DoH + UDP 兜底（推荐）\n"
    printf "  2. 纯 UDP（最稳定，兼容旧版）\n"
    printf "  0. 返回\n\n"
    printf "  选择: "; read -r c
    case "$c" in
        1) MODE="doh_udp" ;;
        2) MODE="udp_only" ;;
        *) return ;;
    esac
    # 读取当前端口
    PORT=$(grep "^bind" /etc/smartdns/smartdns.conf 2>/dev/null | grep -o '[0-9]*$' | head -1)
    [ -z "$PORT" ] && PORT=53
    write_config "$MODE"
    do_restart
    log_ok "已切换为 $MODE"
}

do_update() {
    clear 2>/dev/null || echo ""
    printf "%b── 版本管理 ──%b\n" "$BOLD" "$NC"
    CURRENT_TAG=$("$SMARTDNS_BIN" -v 2>&1 | grep 'Release' | head -1 | sed 's/.*\(Release[0-9.]*\).*/\1/')
    printf "  当前版本: %b%s%b\n" "$GREEN" "${CURRENT_TAG:-未知}" "$NC"
    printf "  安装来源: %s\n\n" "$SMARTDNS_SOURCE"

    printf "  1. 包管理器升级（apt/apk）\n"
    printf "  2. 从 GitHub 下载最新版（需通过启动测试）\n"
    printf "  3. 手动指定 GitHub 版本\n"
    printf "  0. 返回\n\n"
    printf "  选择: "; read -r choice

    case "$choice" in
        1)
            case "$PKG_MGR" in
                apt) apt-get update -qq 2>/dev/null; apt-get install -y --only-upgrade smartdns 2>/dev/null ;;
                apk) apk upgrade smartdns 2>/dev/null ;;
            esac
            do_restart
            return
            ;;
        2) TARGET_TAG="" ;;
        3) printf "  版本号(如 Release48.3): "; read -r TARGET_TAG ;;
        *) return ;;
    esac

    ARCH=$(get_arch)
    if [ -n "$TARGET_TAG" ]; then
        URL="https://github.com/pymumu/smartdns/releases/download/${TARGET_TAG}/smartdns-${ARCH}"
    else
        URL="https://github.com/pymumu/smartdns/releases/latest/download/smartdns-${ARCH}"
    fi

    printf "  下载并测试..."
    if github_download "$URL" /tmp/smartdns-new; then
        chmod +x /tmp/smartdns-new
        timeout 5 /tmp/smartdns-new -f -c /dev/null >/dev/null 2>&1
        rc=$?
        if [ "$rc" -eq 124 ] || [ "$rc" -eq 0 ]; then
            cp "$SMARTDNS_BIN" "${SMARTDNS_BIN}.bak" 2>/dev/null
            mv /tmp/smartdns-new "$SMARTDNS_BIN"
            chmod +x "$SMARTDNS_BIN"
            do_restart
            printf "%b✓ 切换完成%b\n" "$GREEN" "$NC"
        else
            printf "%b✗ 启动测试失败 (rc=%s)，已放弃%b\n" "$RED" "$rc" "$NC"
            rm -f /tmp/smartdns-new
        fi
    else
        printf "%b✗ 下载失败%b\n" "$RED" "$NC"
    fi
}

module_menu() {
    install_shortcut
    if [ $# -gt 0 ]; then
        case "$1" in
            s|status) get_metrics; printf "DNS:%b 守护:%b 重启:%s 崩溃:%s\n" "$S_DOT" "$G_DOT" "$RESTART_N" "$CRASH_N"; return ;;
            l|log) do_log; return ;; t|test) do_test; return ;;
            c|config) do_config; return ;; e|edit) do_edit; return ;; r|restart) do_restart; return ;;
            f|flush) do_flush; return ;; u|update) do_update; return ;; uninstall) module_uninstall; return ;;
            *) echo "用法: sdns [s|l|t|c|e|r|f|u|uninstall]"; return ;;
        esac
    fi
    while true; do
        show_menu
        printf "选择 [0-9]: "; read -r choice 2>/dev/null || break
        case "$choice" in
            1) do_test ;; 2) do_log ;; 3) do_config ;; 4) do_edit ;;
            5) do_restart ;; 6) do_flush ;; 7) do_update ;; 8) module_uninstall; break ;;
            9) do_switch_upstream ;; 0) break ;;
        esac
        [ "$choice" != "0" ] && [ "$choice" != "8" ] && { printf "回车返回..."; read -r _ 2>/dev/null || break; }
    done
}

main() {
    if [ "$(readlink -f "$0" 2>/dev/null || echo "$0")" = "$SDNS_CMD" ]; then
        [ -f /etc/alpine-release ] && OS_TYPE="alpine"
        [ -d /run/systemd/system ] && INIT_TYPE="systemd" || INIT_TYPE="openrc"
        [ -f /etc/smartdns/smartdns.conf ] && PORT=$(grep "^bind" /etc/smartdns/smartdns.conf | grep -o '[0-9]*$' | head -1)
        [ -z "$PORT" ] && PORT=53
        SMARTDNS_BIN=$(command -v smartdns 2>/dev/null)
        [ -z "$SMARTDNS_BIN" ] && SMARTDNS_BIN="/usr/sbin/smartdns"
        PKG_MGR="apt"; [ -f /etc/alpine-release ] && PKG_MGR="apk"
        detect_busybox; detect_inotify
        module_menu "$@"; exit 0
    fi
    for arg in "$@"; do case "$arg" in --uninstall|-u) module_uninstall; exit 0 ;; esac; done

    printf "%bSmartDNS 智能部署 v7.9.0%b\n" "$BOLD$BLUE" "$NC"
    printf "包管理器优先 | DoH 默认 + UDP 兜底 | systemd/OpenRC 双支持\n\n"
    module_detect; module_install; module_config; module_dns_takeover; module_service; module_verify
    printf "\n管理命令: %bsdns%b （菜单含崩溃/重启计数与上游切换）\n" "$GREEN" "$NC"
    module_menu
}

main "$@"
