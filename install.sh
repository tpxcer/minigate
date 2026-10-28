#!/bin/sh
set -e
D="$(cd "$(dirname "$0")" && pwd)"
echo ""; echo "==== MiniGate 安装 ===="; echo ""
[ "$(id -u)" = "0" ] || { echo "[!] 需要root"; exit 1; }

dependency_ready() {
    case "$1" in
        openssl-util)
            command -v openssl >/dev/null 2>&1 && openssl version >/dev/null 2>&1
            ;;
        luci-compat)
            # 页面基于 CBI，由 luci-compat 提供；模块已存在时不依赖包数据库记录
            [ -f "${MINIGATE_LUCI_DIR:-/usr/lib/lua/luci}/cbi.lua" ]
            ;;
        nginx-ssl)
            command -v nginx >/dev/null 2>&1
            ;;
        *)
            return 1
            ;;
    esac
}

install_dependencies() {
    local p
    if command -v opkg >/dev/null 2>&1; then
        PKG="opkg"
        for p in nginx-ssl curl jsonfilter nftables nginx-mod-stream openssl-util luci-compat; do
            dependency_ready "$p" && continue
            opkg list-installed 2>/dev/null | grep -q "^${p} " || { opkg update 2>/dev/null; opkg install "$p" 2>/dev/null; }
        done
    elif command -v apk >/dev/null 2>&1; then
        PKG="apk"
        for p in nginx-ssl curl jsonfilter nftables nginx-mod-stream openssl-util luci-compat; do
            dependency_ready "$p" && continue
            apk info -e "$p" >/dev/null 2>&1 || apk add "$p" 2>/dev/null
        done
    fi
}

# 检测包管理器 + 安装依赖（stream 用于同端口 HTTP/HTTPS 识别）
install_dependencies

# 旧版 init 脚本停止登录防护时不会结束 logread/tail 子进程，升级前先按进程树结束
stop_process_tree() {
    local child
    for child in $(pgrep -P "$1" 2>/dev/null); do
        stop_process_tree "$child"
    done
    kill "$1" 2>/dev/null || true
}
if command -v pgrep >/dev/null 2>&1; then
    for pid in $(pgrep -f '^/bin/sh /usr/lib/minigate/login_guard.sh run' 2>/dev/null); do
        stop_process_tree "$pid"
    done
fi

[ -f /etc/init.d/minigate ] && /etc/init.d/minigate stop 2>/dev/null || true

# 清理旧的独立 login-guard 部署（如有）
[ -f /etc/init.d/login-guard ] && {
    /etc/init.d/login-guard stop 2>/dev/null || true
    /etc/init.d/login-guard disable 2>/dev/null || true
    rm -f /etc/init.d/login-guard
    rm -f /usr/sbin/login-guard /usr/sbin/login-guard.sh
    # 迁移 bans.txt（如有）
    [ -f /etc/login-guard/bans.txt ] && {
        mkdir -p /etc/minigate/login-guard
        cp /etc/login-guard/bans.txt /etc/minigate/login-guard/bans.txt
    }
    echo "[*] 已清理旧的独立 login-guard"
}

# 旧版的事后地区扫描已由反代请求前准入取代：移除它的防火墙集合，避免继续全局封禁
remove_legacy_geofence() {
    local handle
    command -v nft >/dev/null 2>&1 || return 0
    for handle in $(nft -a list chain inet fw4 input 2>/dev/null |
        awk 'index($0, "@minigate_blocked") { for (i=1; i<=NF; i++) if ($i=="handle") print $(i+1) }'); do
        nft delete rule inet fw4 input handle "$handle" 2>/dev/null || true
    done
    nft delete set inet fw4 minigate_blocked 2>/dev/null || true
}
remove_legacy_geofence

mkdir -p /usr/lib/minigate
mkdir -p /etc/minigate/acme /etc/minigate/certs /etc/minigate/nginx/sites /etc/minigate/nginx/streams /etc/minigate/login-guard
rm -f /usr/lib/minigate/after_commit.sh /usr/lib/minigate/geofence.sh
cp "$D"/root/usr/lib/minigate/*.sh /usr/lib/minigate/; chmod +x /usr/lib/minigate/*.sh
cp -R "$D"/root/usr/lib/minigate/geo /usr/lib/minigate/
cp "$D"/root/etc/init.d/minigate /etc/init.d/; chmod +x /etc/init.d/minigate
# 登录防护的封禁集合和规则随防火墙每次重载自动加载
mkdir -p /usr/share/nftables.d/table-pre /usr/share/nftables.d/chain-pre/input
cp "$D"/root/usr/share/nftables.d/table-pre/20-minigate-login-guard.nft /usr/share/nftables.d/table-pre/
cp "$D"/root/usr/share/nftables.d/chain-pre/input/20-minigate-login-guard.nft /usr/share/nftables.d/chain-pre/input/

# 配置：保留旧的，但确保有 login_guard 区段
if [ -f /etc/config/minigate ]; then
    echo "[*] 保留现有配置"
    grep -q "config login_guard" /etc/config/minigate || cat >> /etc/config/minigate <<EOF

config login_guard 'login_guard'
	option enabled '0'
	option threshold '3'
	option window '600'
	option bantime '43200'
EOF
else
    cp "$D"/root/etc/config/minigate /etc/config/
fi

# v1.3.11 起由每条 HTTPS 规则的监听端口直接承担 HTTP 跳转。
uci -q delete minigate.global.http_redirect_port 2>/dev/null || true

# 旧版地区扫描的允许省份迁移到请求前准入（按名称前缀匹配地区代码）
migrate_legacy_geofence() {
    local allowed codes name code
    [ "$(uci -q get minigate.global.geo_enabled)" = "1" ] || return 0
    [ "$(uci -q get minigate.global.access_enabled)" = "1" ] && return 0
    allowed=$(uci -q get minigate.global.geo_allowed)
    codes=""
    for name in $(echo "$allowed" | tr ',' ' '); do
        code=$(awk -v name="$name" 'index($2, name) == 1 { print $1; exit }' "$D"/root/usr/lib/minigate/geo/regions.txt)
        [ -n "$code" ] && codes="$codes $code"
    done
    [ -n "$codes" ] || return 0
    uci -q delete minigate.global.access_regions
    for code in $codes; do uci -q add_list minigate.global.access_regions="$code"; done
    uci -q set minigate.global.access_enabled=1
    echo "[*] 已将旧版地区限制迁移为反代请求前准入:$codes"
}
migrate_legacy_geofence
uci -q delete minigate.global.geo_enabled 2>/dev/null || true
uci -q delete minigate.global.geo_allowed 2>/dev/null || true
uci -q delete minigate.global.blocked_ips 2>/dev/null || true

# 运行状态已移到 /var/run/minigate，清掉旧版写在配置文件里的状态字段
for sec in $(uci -q -X show minigate 2>/dev/null | grep '=ddns$' | cut -d. -f2 | cut -d= -f1); do
    for opt in status status_msg last_ip last_ip6 last_update next_sync; do
        uci -q delete "minigate.${sec}.${opt}" 2>/dev/null || true
    done
done
for opt in status last_domain last_issue cert_expiry last_error; do
    uci -q delete "minigate.acme.${opt}" 2>/dev/null || true
done
uci -q commit minigate 2>/dev/null || true

mkdir -p /usr/lib/lua/luci/controller
mkdir -p /usr/lib/lua/luci/model/cbi/minigate
mkdir -p /usr/lib/lua/luci/view/minigate
cp "$D"/luasrc/controller/minigate.lua /usr/lib/lua/luci/controller/
cp "$D"/luasrc/model/cbi/minigate/*.lua /usr/lib/lua/luci/model/cbi/minigate/
cp "$D"/luasrc/view/minigate/*.htm /usr/lib/lua/luci/view/minigate/
rm -rf /tmp/luci-indexcache* /tmp/luci-modulecache 2>/dev/null
/etc/init.d/minigate enable 2>/dev/null
/etc/init.d/minigate start 9>&- 2>/dev/null || true
echo ""; echo "==== 安装完成 ===="
echo "LuCI -> 服务 -> MiniGate"
echo "登录防护 tab 默认关闭，到 LuCI 启用即可。"
echo ""
