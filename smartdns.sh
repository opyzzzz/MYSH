#!/bin/sh
#==========================================================================
# SmartDNS 智能部署脚本 v7.9.3
# 增强层以实际启动测试判定（不依赖容器检测）| Type=simple | 完整双 init
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
IS_VER_NEW=false; ENHANCED_ENABLED=false; PORT=53
OS_TYPE=""; OS_VER=""; INIT_TYPE=""; VIRT_TYPE=""; VIRT_IS_CONTAINER=false
NET_STACK=""; HAS_IPV4=true; HAS_IPV6=false
TAKEOVER_STRATEGY="standard"
SYSTEMD_RESOLVED_RUNNING=false; TMPFILES_HAS_RESOLV=false
DEPLOY_LOG="/var/log/smartdns-deploy.log"
ARCH=""; PKG_MGR=""
PID_FILE="/run/resolv-guard.pid"
GUARD_SCRIPT="/usr/local/bin/resolv-guard.sh"
SDNS_CMD="/usr/local/bin/sdns"
UPSTREAM_MODE_FILE="/etc/smartdns/upstream-mode"
RESOLV_TEMPLATE="/etc/smartdns/resolv.smartdns"
RESOLV_FALLBACK="/etc/smartdns/resolv.fallback"
TEST_CONF="/tmp/smartdns-test.conf"
TEST_LOG="/tmp/smartdns-startup-test.log"
CANDIDATE_CONF="/tmp/smartdns-candidate.conf"
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

stop_smartdns_service() {
    case "$INIT_TYPE" in
        systemd) systemctl stop smartdns 2>/dev/null ;;
        openrc) rc-service smartdns stop 2>/dev/null ;;
    esac
    pkill -x smartdns 2>/dev/null
    sleep 1
}

start_smartdns_service() {
    case "$INIT_TYPE" in
        systemd) systemctl start smartdns 2>/dev/null ;;
        openrc) rc-service smartdns start 2>/dev/null ;;
        *) [ -n "$SMARTDNS_BIN" ] && "$SMARTDNS_BIN" -c /etc/smartdns/smartdns.conf & ;;
    esac
}

# 隔离环境：用指定二进制 + 指定配置在 15353 端口测试 10 秒
test_config_safe() {
    local bin="$1" conf="$2"
    [ -x "$bin" ] || { echo "二进制不可执行: $bin" > "$TEST_LOG"; return 1; }
    [ -f "$conf" ] || { echo "配置不存在: $conf" > "$TEST_LOG"; return 1; }

    stop_smartdns_service

    # 复制候选配置，强制 bind 到 15353
    sed 's/^bind .*/bind :15353/' "$conf" > "$TEST_CONF"

    timeout 10 "$bin" -f -c "$TEST_CONF" > "$TEST_LOG" 2>&1
    local rc=$?

    start_smartdns_service

    [ "$rc" -eq 124 ] || [ "$rc" -eq 0 ]
}

print_test_result() {
    local rc="$1"
    printf "  测试日志: %s\n" "$TEST_LOG"
    if [ "$rc" -eq 0 ]; then
        printf "%b  ✓ 配置存活 10 秒，可正常启动%b\n" "$GREEN" "$NC"
    else
        printf "%b  ✗ 测试失败，错误摘要:%b\n" "$RED" "$NC"
        tail -5 "$TEST_LOG" 2>/dev/null | sed 's/^/    /'
    fi
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
    log_info "Init: $INIT_TYPE"

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
    log_info "网络栈: $NET_STACK"

    if command -v resolvectl >/dev/null 2>&1 && resolvectl status >/dev/null 2>&1; then
        SYSTEMD_RESOLVED_RUNNING=true; log_warn "systemd-resolved 运行中"
    fi
    TMPFILES_HAS_RESOLV=false
    if find /usr/lib/tmpfiles.d/ /etc/tmpfiles.d/ -maxdepth 1 -type f -exec grep -l "/etc/resolv.conf" {} \; 2>/dev/null | grep -q .; then
        TMPFILES_HAS_RESOLV=true
    fi

    $SYSTEMD_RESOLVED_RUNNING && TAKEOVER_STRATEGY="resolved" || TAKEOVER_STRATEGY="standard"
    log_ok "接管策略: $TAKEOVER_STRATEGY"
}

#==================================================
# 模块1: 安装 SmartDNS
#==================================================
module_install() {
    log_step "模块1: 安装 SmartDNS (包管理器优先)"

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

    if [ -z "$SMARTDNS_BIN" ]; then
        log_warn "包管理器失败，尝试 GitHub（隔离测试）"
        URL="https://github.com/pymumu/smartdns/releases/latest/download/smartdns-${ARCH}"
        if github_download "$URL" /tmp/smartdns-test; then
            chmod +x /tmp/smartdns-test
            # 用极简配置测试二进制本身
            printf "bind :15353\nserver 8.8.8.8\n" > /tmp/smartdns-min.conf
            if test_config_safe /tmp/smartdns-test /tmp/smartdns-min.conf; then
                mv /tmp/smartdns-test /usr/local/bin/smartdns
                SMARTDNS_BIN="/usr/local/bin/smartdns"; SMARTDNS_SOURCE="GitHub"
                print_test_result 0
            else
                print_test_result 1
                rm -f /tmp/smartdns-test
            fi
        fi
    fi

    [ -z "$SMARTDNS_BIN" ] && { log_err "所有安装方式均失败"; exit 1; }

    SMARTDNS_VER=$("$SMARTDNS_BIN" -v 2>&1 | head -1)
    SMARTDNS_VER_NUM=$(get_version_number "$SMARTDNS_BIN")
    [ "$SMARTDNS_VER_NUM" -ge 42 ] 2>/dev/null && IS_VER_NEW=true || IS_VER_NEW=false
    log_info "版本: $SMARTDNS_VER (来源: $SMARTDNS_SOURCE)"
}

#==================================================
# 模块2: 配置生成（增强层以实测判定）
#==================================================
generate_config() {
    local mode="$1" outfile="$2" bindport="$3" level="$4"
    cat > "$outfile" << EOF
# SmartDNS v7.9.3
# 环境: $OS_TYPE $OS_VER | $VIRT_TYPE | $NET_STACK
# 版本: $SMARTDNS_VER | 来源: $SMARTDNS_SOURCE | 模式: $mode | 层级: $level
server-name smartdns
bind :${bindport}
cache-size 4096
prefetch-domain yes
speed-check-mode tcp:443
EOF

    [ "$HAS_IPV6" = false ] && echo "force-AAAA-SOA yes" >> "$outfile"

    if [ "$mode" = "doh_udp" ]; then
        cat >> "$outfile" << 'EOF'

# 加密上游（保守写法）
server-https https://dns.google/dns-query
server-https https://cloudflare-dns.com/dns-query

# UDP 兜底
server 8.8.8.8
server 1.1.1.1
EOF
    else
        cat >> "$outfile" << 'EOF'

# 纯 UDP 上游
server 8.8.8.8
server 1.1.1.1
server 8.8.4.4
EOF
    fi

    # 增强层只在候选配置中加入
    if [ "$level" = "with_enhanced" ] && [ "$mode" = "doh_udp" ]; then
        cat >> "$outfile" << 'EOF'

# 增强层：分组 + 后备
upstream-group secure
server-https https://dns.google/dns-query -group secure
server-https https://cloudflare-dns.com/dns-query -group secure
upstream-group fallback
server 8.8.8.8 -group fallback
server 1.1.1.1 -group fallback
EOF
    fi
}

module_config() {
    log_step "模块2: 生成配置与 DNS 模板"
    mkdir -p /etc/smartdns
    [ -f /etc/smartdns/smartdns.conf ] && cp /etc/smartdns/smartdns.conf "/etc/smartdns/smartdns.conf.bak.$(date +%Y%m%d-%H%M%S)" 2>/dev/null

    # DNS 模板
    if [ "$HAS_IPV6" = true ] && [ "$HAS_IPV4" = true ]; then
        printf "nameserver 127.0.0.1\nnameserver ::1\noptions edns0 trust-ad\n" > "$RESOLV_TEMPLATE"
        printf "nameserver 1.1.1.1\nnameserver 8.8.8.8\nnameserver 2606:4700:4700::1111\nnameserver 2001:4860:4860::8888\n" > "$RESOLV_FALLBACK"
    else
        printf "nameserver 127.0.0.1\noptions edns0 trust-ad\n" > "$RESOLV_TEMPLATE"
        printf "nameserver 1.1.1.1\nnameserver 8.8.8.8\n" > "$RESOLV_FALLBACK"
    fi
    log_ok "DNS 模板已生成"

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

    ENHANCED_ENABLED=false

    # 仅 doh_udp 模式才尝试增强层
    if [ "$MODE" = "doh_udp" ]; then
        log_info "生成含增强层的候选配置并实测..."
        generate_config "$MODE" "$CANDIDATE_CONF" "15353" "with_enhanced"

        if test_config_safe "$SMARTDNS_BIN" "$CANDIDATE_CONF"; then
            print_test_result 0
            log_ok "增强层测试通过，启用 upstream-group"
            generate_config "$MODE" "/etc/smartdns/smartdns.conf" "$PORT" "with_enhanced"
            ENHANCED_ENABLED=true
        else
            print_test_result 1
            log_warn "增强层不被当前二进制/环境支持，回退基础配置"
            generate_config "$MODE" "/etc/smartdns/smartdns.conf" "$PORT" "base_only"
        fi
    else
        generate_config "$MODE" "/etc/smartdns/smartdns.conf" "$PORT" "base_only"
    fi

    echo "$MODE" > "$UPSTREAM_MODE_FILE"
    log_ok "配置已生成 (模式: $MODE, 增强层: $ENHANCED_ENABLED)"
}

#==================================================
# 模块3: 接管系统 DNS
#==================================================
module_dns_takeover() {
    log_step "模块3: 接管系统 DNS"
    if [ ! -f /etc/resolv.conf.smartdns.orig ]; then
        if [ -L /etc/resolv.conf ]; then cat /etc/resolv.conf > /etc/resolv.conf.smartdns.orig 2>/dev/null
        else cp /etc/resolv.conf /etc/resolv.conf.smartdns.orig 2>/dev/null; fi
    fi

    local dns_list
    dns_list=$(grep "^nameserver" "$RESOLV_TEMPLATE" 2>/dev/null | awk '{print $2}' | tr '\n' ' ' | sed 's/ $//')
    [ -z "$dns_list" ] && dns_list="127.0.0.1"

    BACKUP_LIST="/etc/smartdns/dns-config-backup.txt"
    > "$BACKUP_LIST"

    if [ "$INIT_TYPE" = "systemd" ] && command -v resolvectl >/dev/null 2>&1; then
        mkdir -p /etc/systemd/resolved.conf.d
        printf "[Resolve]\nDNS=%s\nDNSStubListener=no\n" "$dns_list" > /etc/systemd/resolved.conf.d/smartdns.conf
        echo "/etc/systemd/resolved.conf.d/smartdns.conf:DELETE" >> "$BACKUP_LIST"
        systemctl restart systemd-resolved 2>/dev/null
        [ -L /etc/resolv.conf ] && { rm -f /etc/resolv.conf; write_resolv; }
        if [ "$TMPFILES_HAS_RESOLV" = true ]; then
            mkdir -p /etc/tmpfiles.d
            printf "# SmartDNS\n" > /etc/tmpfiles.d/systemd-resolved.conf
            echo "/etc/tmpfiles.d/systemd-resolved.conf:DELETE" >> "$BACKUP_LIST"
        fi
    fi

    if [ -f /etc/dhcp/dhclient.conf ]; then
        cp /etc/dhcp/dhclient.conf /etc/dhcp/dhclient.conf.smartdns.bak 2>/dev/null
        echo "/etc/dhcp/dhclient.conf:RESTORE:/etc/dhcp/dhclient.conf.smartdns.bak" >> "$BACKUP_LIST"
        grep -q "supersede domain-name-servers 127.0.0.1" /etc/dhcp/dhclient.conf 2>/dev/null || \
            echo "supersede domain-name-servers 127.0.0.1;" >> /etc/dhcp/dhclient.conf
    fi

    if [ -f /etc/network/interfaces ]; then
        if grep -q "iface.*inet dhcp" /etc/network/interfaces 2>/dev/null; then
            local iface4; iface4=$(grep "iface.*inet dhcp" /etc/network/interfaces | awk '{print $2}')
            if [ -n "$iface4" ] && ! grep -A5 "iface $iface4" /etc/network/interfaces | grep -q "dns-nameservers"; then
                [ ! -f /etc/network/interfaces.smartdns.bak ] && cp /etc/network/interfaces /etc/network/interfaces.smartdns.bak 2>/dev/null
                echo "/etc/network/interfaces:RESTORE:/etc/network/interfaces.smartdns.bak" >> "$BACKUP_LIST"
                printf "\n    dns-nameservers %s\n" "$dns_list" | \
                    sed -i "/iface $iface4 inet dhcp/r /dev/stdin" /etc/network/interfaces
            fi
        fi
    fi

    [ "$TAKEOVER_STRATEGY" != "resolved" ] && write_resolv
    cat "$RESOLV_TEMPLATE" > /etc/resolv.conf.smartdns.bak

    if [ -L /etc/resolv.conf ]; then
        rm -f /etc/resolv.conf; write_resolv
    fi

    if [ "$INIT_TYPE" = "openrc" ]; then
        mkdir -p /etc/local.d
        cat > /etc/local.d/resolv-fix.start << LSTART
#!/bin/sh
sleep 5
[ -L /etc/resolv.conf ] && rm -f /etc/resolv.conf
cat ${RESOLV_TEMPLATE} > /etc/resolv.conf
LSTART
        chmod +x /etc/local.d/resolv-fix.start; safe_rc_add local default
    elif [ "$INIT_TYPE" = "systemd" ]; then
        cat > /etc/systemd/system/resolv-fix.service << SSTART
[Unit]
Description=DNS Resolv Fix
After=network-online.target
[Service]
Type=oneshot
ExecStart=/bin/sh -c 'sleep 5; [ -L /etc/resolv.conf ] && rm -f /etc/resolv.conf; cat ${RESOLV_TEMPLATE} > /etc/resolv.conf'
[Install]
WantedBy=multi-user.target
SSTART
        systemctl daemon-reload 2>/dev/null; systemctl enable resolv-fix.service 2>/dev/null
    fi

    cat > "$GUARD_SCRIPT" << GUARD
#!/bin/sh
TARGET="/etc/resolv.conf"; TEMPLATE="${RESOLV_TEMPLATE}"
restore_dns() {
    [ -f "\$TEMPLATE" ] || return 0
    if [ -L "\$TARGET" ]; then rm -f "\$TARGET"; cat "\$TEMPLATE" > "\$TARGET" 2>/dev/null; return 0; fi
    ! cmp -s "\$TEMPLATE" "\$TARGET" 2>/dev/null && cat "\$TEMPLATE" > "\$TARGET" 2>/dev/null
}
while true; do sleep 5; restore_dns; done
GUARD
    chmod 700 "$GUARD_SCRIPT"

    [ -f "$PID_FILE" ] && { kill $(cat "$PID_FILE" 2>/dev/null) 2>/dev/null; rm -f "$PID_FILE"; }

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
        systemctl daemon-reload 2>/dev/null; systemctl enable resolv-guard.service 2>/dev/null
    else
        "$GUARD_SCRIPT" &
        echo $! > "$PID_FILE"
    fi
    log_ok "DNS 接管完成"
}

#==================================================
# 模块4: 服务部署（Type=simple，无需 PID 文件）
#==================================================
module_service() {
    log_step "模块4: 部署 SmartDNS 服务"
    pkill -x smartdns 2>/dev/null; sleep 1

    local BIN="$SMARTDNS_BIN"
    [ -z "$BIN" ] && BIN=$(command -v smartdns 2>/dev/null)

    case "$INIT_TYPE" in
        systemd)
            cat > /etc/systemd/system/smartdns.service << SVC
[Unit]
Description=SmartDNS Server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${BIN} -c /etc/smartdns/smartdns.conf -f
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=5

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
command="${BIN}"
command_args="-c /etc/smartdns/smartdns.conf -f"
command_background=true
pidfile="/run/smartdns.pid"
depend() { need net; }
OSVC
            chmod +x /etc/init.d/smartdns
            safe_rc_add smartdns default
            rc-service smartdns restart 2>/dev/null
            sleep 3
            ;;
        *)
            "$BIN" -c /etc/smartdns/smartdns.conf &
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
        log_err "启动或解析异常"
        [ "$INIT_TYPE" = "systemd" ] && journalctl -u smartdns --no-pager -n 15 2>/dev/null
        fuser "${PORT}/udp" 2>&1 || true
        exit 1
    fi
}

#==================================================
# 模块5: 验证
#==================================================
module_verify() {
    log_step "模块5: 验证"
    sleep 2
    if command -v dig >/dev/null 2>&1; then
        for d in google.com cloudflare.com; do
            IP=$(dig @127.0.0.1 "$d" +short +time=3 +tries=1 2>/dev/null | grep -E '^[0-9]' | head -1)
            [ -n "$IP" ] && log_ok "$d → $IP" || log_warn "$d 解析失败"
        done
    fi

    printf "\n%b部署摘要%b\n" "$BOLD" "$NC"
    printf "  版本: %s (来源: %s)\n" "$SMARTDNS_VER" "$SMARTDNS_SOURCE"
    printf "  模式: %s\n" "$(cat "$UPSTREAM_MODE_FILE" 2>/dev/null)"
    printf "  增强层: %s（实测判定）\n" "$ENHANCED_ENABLED"
    printf "  管理: %bsdns%b\n" "$GREEN" "$NC"
}

#==================================================
# 模块6: 卸载
#==================================================
module_uninstall() {
    printf "\n%b确认卸载？输入 yes: %b" "$YELLOW" "$NC"
    read -r confirm
    [ "$confirm" != "yes" ] && return

    [ -z "$INIT_TYPE" ] && { [ -d /run/systemd/system ] && INIT_TYPE="systemd" || INIT_TYPE="openrc"; }

    case "$INIT_TYPE" in
        systemd)
            systemctl stop resolv-guard.service resolv-fix.service smartdns.service 2>/dev/null
            systemctl disable resolv-guard.service resolv-fix.service smartdns.service 2>/dev/null
            rm -f /etc/systemd/system/{resolv-guard,resolv-fix,smartdns}.service
            systemctl daemon-reload 2>/dev/null
            ;;
        openrc)
            rc-service smartdns stop 2>/dev/null; rc-update del smartdns 2>/dev/null
            rm -f /etc/init.d/smartdns /etc/local.d/resolv-fix.start /etc/local.d/resolv-guard.start
            ;;
    esac

    pkill -x smartdns 2>/dev/null; sleep 0.5; pkill -9 -x smartdns 2>/dev/null
    rm -f "$GUARD_SCRIPT" "$SDNS_CMD" /etc/resolv.conf.smartdns.bak
    rm -rf /etc/smartdns
    [ -f /etc/resolv.conf.smartdns.orig ] && cat /etc/resolv.conf.smartdns.orig > /etc/resolv.conf && rm -f /etc/resolv.conf.smartdns.orig
    [ ! -s /etc/resolv.conf ] && printf "nameserver 1.1.1.1\nnameserver 8.8.8.8\n" > /etc/resolv.conf
    [ "$SMARTDNS_SOURCE" = "apt" ] && apt-get remove -y smartdns 2>/dev/null
    [ "$SMARTDNS_SOURCE" = "apk" ] && apk del smartdns 2>/dev/null
    printf "%b卸载完成%b\n" "$GREEN" "$NC"
}

#==================================================
# 菜单
#==================================================
install_shortcut() {
    local sp=$(readlink -f "$0" 2>/dev/null || echo "$0")
    [ "$sp" != "$SDNS_CMD" ] && { cp "$sp" "$SDNS_CMD" 2>/dev/null; chmod +x "$SDNS_CMD" 2>/dev/null; }
}

CACHE_TIME=0; CACHE_S=""

get_metrics() {
    local now=$(date +%s)
    [ -n "$CACHE_S" ] && [ $((now - CACHE_TIME)) -lt 15 ] && return
    pgrep -x smartdns >/dev/null 2>&1 && S_DOT="${GREEN}●${NC}" || S_DOT="${RED}●${NC}"
    RESTART_N=$(systemctl show smartdns -p NRestarts --value 2>/dev/null || echo "0")
    CRASH_N=$(journalctl -u smartdns --no-pager 2>/dev/null | grep -c "signal 6")
    CACHE_S="$S_DOT"; CACHE_TIME=$now
}

show_menu() {
    get_metrics
    clear 2>/dev/null || echo ""
    printf "%b┌──── SmartDNS v7.9.3 ────┐%b\n" "$BOLD" "$NC"
    printf "  状态: %b  重启: %s  崩溃: %s\n" "$S_DOT" "$RESTART_N" "$CRASH_N"
    printf "  版本: %s\n" "$SMARTDNS_VER"
    printf "  增强层: %s\n" "$ENHANCED_ENABLED"
    printf "%b├──────────────────────────┤%b\n" "$BOLD" "$NC"
    printf "  1.测试 2.日志 3.配置 4.编辑\n"
    printf "  5.重启 6.清缓存 7.版本 8.卸载\n"
    printf "  9.切换上游 0.退出\n"
    printf "%b└──────────────────────────┘%b\n" "$BOLD" "$NC"
}

do_test() {
    for d in google.com cloudflare.com github.com; do
        printf "  %-18s" "$d"
        dig @127.0.0.1 "$d" +short +time=3 +tries=1 2>/dev/null | grep -qE '^[0-9]' && \
            printf "%b✓%b\n" "$GREEN" "$NC" || printf "%b✗%b\n" "$RED" "$NC"
    done
}

do_log() { journalctl -u smartdns --no-pager -n 30 2>/dev/null || tail -30 /var/log/smartdns.log 2>/dev/null; }
do_config() { [ -f /etc/smartdns/smartdns.conf ] && grep -v "^#\|^$" /etc/smartdns/smartdns.conf || echo "无配置"; }

do_restart() {
    case "$INIT_TYPE" in
        systemd) systemctl restart smartdns ;;
        openrc) rc-service smartdns restart ;;
        *) pkill -x smartdns; sleep 1; "$SMARTDNS_BIN" -c /etc/smartdns/smartdns.conf & ;;
    esac
    sleep 2; pgrep -x smartdns >/dev/null && printf "%b✓%b\n" "$GREEN" "$NC" || printf "%b✗%b\n" "$RED" "$NC"
    CACHE_TIME=0
}

do_switch_upstream() {
    printf "  1.DoH+UDP  2.纯UDP  0.返回: "; read -r c
    case "$c" in 1) MODE="doh_udp" ;; 2) MODE="udp_only" ;; *) return ;; esac
    PORT=$(grep "^bind" /etc/smartdns/smartdns.conf | grep -o '[0-9]*$' | head -1); [ -z "$PORT" ] && PORT=53
    # 切换模式也走实测流程
    if [ "$MODE" = "doh_udp" ]; then
        generate_config "$MODE" "$CANDIDATE_CONF" "15353" "with_enhanced"
        if test_config_safe "$SMARTDNS_BIN" "$CANDIDATE_CONF"; then
            generate_config "$MODE" "/etc/smartdns/smartdns.conf" "$PORT" "with_enhanced"
            ENHANCED_ENABLED=true
        else
            generate_config "$MODE" "/etc/smartdns/smartdns.conf" "$PORT" "base_only"
            ENHANCED_ENABLED=false
        fi
    else
        generate_config "$MODE" "/etc/smartdns/smartdns.conf" "$PORT" "base_only"
        ENHANCED_ENABLED=false
    fi
    echo "$MODE" > "$UPSTREAM_MODE_FILE"
    do_restart
}

do_update() {
    printf "  1.apt升级 2.GitHub最新(隔离测试) 3.指定版本 4.apt重装 0.返回: "; read -r c
    case "$c" in
        1) apt-get update -qq; apt-get install -y --only-upgrade smartdns; do_restart; return ;;
        2) URL="https://github.com/pymumu/smartdns/releases/latest/download/smartdns-${ARCH}" ;;
        3) printf "版本(如 Release47.1): "; read -r TAG; URL="https://github.com/pymumu/smartdns/releases/download/${TAG}/smartdns-${ARCH}" ;;
        4) apt-get install -y --reinstall smartdns; do_restart; return ;;
        *) return ;;
    esac
    [ -z "$URL" ] && return
    github_download "$URL" /tmp/smartdns-new && chmod +x /tmp/smartdns-new
    printf "bind :15353\nserver 8.8.8.8\n" > /tmp/smartdns-min.conf
    if test_config_safe /tmp/smartdns-new /tmp/smartdns-min.conf; then
        [ ! -f "/etc/smartdns/smartdns.bin.bak" ] && cp "$SMARTDNS_BIN" "/etc/smartdns/smartdns.bin.bak"
        mv /tmp/smartdns-new "$SMARTDNS_BIN"; chmod +x "$SMARTDNS_BIN"
        SMARTDNS_VER=$("$SMARTDNS_BIN" -v | head -1)
        SMARTDNS_VER_NUM=$(get_version_number "$SMARTDNS_BIN")
        [ "$SMARTDNS_VER_NUM" -ge 42 ] && IS_VER_NEW=true || IS_VER_NEW=false
        do_restart
    else
        rm -f /tmp/smartdns-new
        printf "%b测试失败，保持当前版本%b\n" "$YELLOW" "$NC"
    fi
}

module_menu() {
    install_shortcut
    if [ $# -gt 0 ]; then
        case "$1" in
            t|test) do_test ;; l|log) do_log ;; c|config) do_config ;; r|restart) do_restart ;; uninstall) module_uninstall ;;
        esac
        return
    fi
    while true; do
        show_menu
        printf "选择 [0-9]: "; read -r c 2>/dev/null || break
        case "$c" in
            1) do_test ;; 2) do_log ;; 3) do_config ;; 5) do_restart ;; 8) module_uninstall; break ;;
            9) do_switch_upstream ;; 0) break ;;
        esac
        [ "$c" != "0" ] && [ "$c" != "8" ] && { printf "回车返回..."; read -r _ 2>/dev/null; }
    done
}

main() {
    if [ "$(readlink -f "$0" 2>/dev/null || echo "$0")" = "$SDNS_CMD" ]; then
        [ -f /etc/alpine-release ] && OS_TYPE="alpine"
        [ -d /run/systemd/system ] && INIT_TYPE="systemd" || INIT_TYPE="openrc"
        [ -f /etc/smartdns/smartdns.conf ] && PORT=$(grep "^bind" /etc/smartdns/smartdns.conf | grep -o '[0-9]*$' | head -1)
        [ -z "$PORT" ] && PORT=53
        SMARTDNS_BIN=$(command -v smartdns 2>/dev/null)
        PKG_MGR="apt"; [ -f /etc/alpine-release ] && PKG_MGR="apk"
        detect_busybox; module_menu "$@"; exit 0
    fi
    for arg in "$@"; do case "$arg" in --uninstall|-u) module_uninstall; exit 0 ;; esac; done

    printf "%bSmartDNS v7.9.3%b\n" "$BOLD$BLUE" "$NC"
    printf "增强层以实测判定 | Type=simple | 完整双 init\n\n"
    module_detect; module_install; module_config; module_dns_takeover; module_service; module_verify
    module_menu
}

main "$@"
