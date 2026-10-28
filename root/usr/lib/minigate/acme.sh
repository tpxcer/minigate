#!/bin/sh
ACME_HOME="${MINIGATE_ACME_HOME:-/etc/minigate/acme/data}"
ACME_BIN="${ACME_HOME}/acme.sh"
CERT_DIR="${MINIGATE_CERT_DIR:-/etc/minigate/certs}"
LOGFILE="${MINIGATE_ACME_LOG:-/var/log/minigate-acme.log}"
PROXY_SCRIPT="${MINIGATE_PROXY_SCRIPT:-/usr/lib/minigate/proxy.sh}"
# 最近一次签发结果只放内存；证书本身的有效期由页面直接读取证书文件
STATE_FILE="${MINIGATE_ACME_STATE:-/var/run/minigate/acme.state}"
# 固定 acme.sh 版本并校验 GitHub 标签归档的 SHA-256，不再以 root 执行未校验的 master 分支
ACME_VERSION="3.1.6"
ACME_SHA256="0d3f9000ac44a6331314742a88c475f79134e24fc991997883652adc59efc486"
ACME_URL="https://github.com/acmesh-official/acme.sh/archive/refs/tags/${ACME_VERSION}.tar.gz"
# 证书剩余天数少于此值才强制重签，避免反复点击触发 Let's Encrypt 频率限制
RENEW_DAYS=30

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') [ACME] $*" >> "$LOGFILE"; }

# write_state 结果 域名 说明
write_state() {
    local tmp
    mkdir -p "$(dirname "$STATE_FILE")" 2>/dev/null || return 0
    tmp="${STATE_FILE}.$$"
    {
        printf 'result=%s\n' "$1"
        printf 'domain=%s\n' "$2"
        printf 'message=%s\n' "$3"
        printf 'time=%s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
    } > "$tmp" && mv -f "$tmp" "$STATE_FILE"
}

safe_dir() { echo "$1" | sed 's/\*/_wildcard_/g'; }

cert_path_for_domain() {
    echo "${CERT_DIR}/$(safe_dir "$1")/fullchain.pem"
}

cert_expiry() {
    openssl x509 -in "$1" -noout -enddate 2>/dev/null | cut -d= -f2
}

cert_is_valid() {
    local cert="$1"
    [ -f "$cert" ] && openssl x509 -checkend 0 -noout -in "$cert" >/dev/null 2>&1
}

cert_valid_for_days() {
    local cert="$1" days="$2"
    [ -f "$cert" ] && openssl x509 -checkend $((days * 86400)) -noout -in "$cert" >/dev/null 2>&1
}

keep_existing_cert_ok() {
    local domain="$1" reason="$2"
    local cert="$(cert_path_for_domain "$domain")"
    if cert_is_valid "$cert"; then
        log "失败: $reason；现有证书仍有效: $domain (过期: $(cert_expiry "$cert"))"
        write_state partial "$domain" "$reason；现有证书仍有效，已继续使用"
        [ -f "$PROXY_SCRIPT" ] && /bin/sh "$PROXY_SCRIPT" reload 2>/dev/null
        return 0
    fi
    return 1
}

# 只使用同一域名或其上级域名所在 DDNS 记录的令牌，不拿其他区域的令牌碰运气
find_token_for_domain() {
    local target="$1"
    local sections=$(uci -q show minigate | grep '=ddns$' | cut -d. -f2 | cut -d= -f1)
    for sec in $sections; do
        local d=$(uci -q get minigate.${sec}.domain)
        if [ "$d" = "$target" ]; then
            echo "$(uci -q get minigate.${sec}.cf_api_token)|$(uci -q get minigate.${sec}.cf_zone_id)"
            return 0
        fi
    done
    local parent=$(echo "$target" | sed 's/^\*\.//; s/^[^.]*\.//')
    local base=$(echo "$target" | sed 's/^\*\.//')
    for sec in $sections; do
        local d=$(uci -q get minigate.${sec}.domain)
        local db=$(echo "$d" | sed 's/^\*\.//')
        if [ "$db" = "$parent" ] || [ "$db" = "$base" ] || [ "$d" = "*.$parent" ]; then
            echo "$(uci -q get minigate.${sec}.cf_api_token)|$(uci -q get minigate.${sec}.cf_zone_id)"
            return 0
        fi
    done
    return 1
}

download_acme() {
    local output="$1"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --proto '=https' --tlsv1.2 --connect-timeout 10 --max-time 120 -o "$output" "$ACME_URL" 2>>"$LOGFILE" && return 0
    fi
    command -v wget >/dev/null 2>&1 && wget -qO "$output" "$ACME_URL" 2>>"$LOGFILE"
}

do_install() {
    if [ -x "$ACME_BIN" ] && [ -d "${ACME_HOME}/dnsapi" ]; then
        log "acme.sh 已安装"; return 0
    fi
    log "下载 acme.sh ${ACME_VERSION} ..."
    mkdir -p "$ACME_HOME" "$CERT_DIR"
    local work archive actual
    work=$(mktemp -d /tmp/minigate-acme.XXXXXX) || { log "无法创建临时目录"; return 1; }
    archive="${work}/acme.tar.gz"
    if ! download_acme "$archive"; then
        log "下载失败"; rm -rf "$work"; return 1
    fi
    actual=$(sha256sum "$archive" | awk '{print $1}')
    if [ "$actual" != "$ACME_SHA256" ]; then
        log "acme.sh 校验失败（SHA-256 不一致），已拒绝安装"
        rm -rf "$work"; return 1
    fi
    tar xzf "$archive" -C "$work" 2>>"$LOGFILE" || { log "解压失败"; rm -rf "$work"; return 1; }
    ( cd "${work}/acme.sh-${ACME_VERSION}" && ./acme.sh --install --home "$ACME_HOME" --no-cron --no-profile ) >> "$LOGFILE" 2>&1
    rm -rf "$work"
    if [ -x "$ACME_BIN" ] && [ -d "${ACME_HOME}/dnsapi" ]; then
        "$ACME_BIN" --home "$ACME_HOME" --set-default-ca --server letsencrypt >> "$LOGFILE" 2>&1
        log "安装成功"; return 0
    else
        log "安装失败"; return 1
    fi
}

do_issue() {
    local domain="$1"
    local email=$(uci -q get minigate.acme.email)
    local staging=$(uci -q get minigate.acme.staging)
    local key_type=$(uci -q get minigate.acme.key_type)

    if [ -z "$domain" ]; then
        local fs=$(uci -q show minigate | grep '=ddns$' | head -1 | cut -d. -f2 | cut -d= -f1)
        [ -n "$fs" ] && domain=$(uci -q get minigate.${fs}.domain)
    fi
    [ -z "$domain" ] && { log "未指定域名"; write_state error "" "未指定域名"; return 1; }

    local ti=$(find_token_for_domain "$domain")
    local token=$(echo "$ti" | cut -d'|' -f1)
    local zone_id=$(echo "$ti" | cut -d'|' -f2)
    [ -z "$token" ] && { log "无API令牌"; write_state error "$domain" "没有找到该域名对应的 Cloudflare 令牌"; return 1; }

    local safe=$(safe_dir "$domain")
    local cert="${CERT_DIR}/${safe}/fullchain.pem"
    mkdir -p "${CERT_DIR}/${safe}"
    if ! do_install; then
        keep_existing_cert_ok "$domain" "acme.sh 安装失败" && return 0
        write_state error "$domain" "acme.sh 安装失败"
        return 1
    fi

    local force=""
    if cert_valid_for_days "$cert" "$RENEW_DAYS" && [ "$staging" != "1" ] && ! cert_is_staging "$cert"; then
        log "跳过: $domain 证书剩余超过 ${RENEW_DAYS} 天 (过期: $(cert_expiry "$cert"))"
        write_state ok "$domain" "证书剩余超过 ${RENEW_DAYS} 天，未重复签发"
        return 0
    fi
    [ -f "$cert" ] && force="--force"

    export CF_Token="$token"
    [ -n "$zone_id" ] && export CF_Zone_ID="$zone_id"

    local kl="ec-256"
    case "$key_type" in ec-256|ec-384) kl="$key_type";; rsa-2048) kl="2048";; rsa-4096) kl="4096";; esac
    local sf="--server letsencrypt"
    [ "$staging" = "1" ] && sf="--staging --server letsencrypt"

    log "签发: $domain (staging=$staging)"
    write_state issuing "$domain" "正在签发"

    "$ACME_BIN" --home "$ACME_HOME" --issue --dns dns_cf $sf -d "$domain" --keylength "$kl" \
        ${email:+--accountemail "$email"} \
        --cert-file "${CERT_DIR}/${safe}/cert.pem" --key-file "${CERT_DIR}/${safe}/key.pem" \
        --fullchain-file "$cert" $force >> "$LOGFILE" 2>&1
    local ret=$?

    if [ $ret -eq 0 ] && [ -f "$cert" ]; then
        log "成功: $domain (过期: $(cert_expiry "$cert"))"
        if [ "$staging" = "1" ]; then
            write_state ok "$domain" "已签发测试证书（浏览器不信任），正式使用请关闭测试模式后重新签发"
        else
            write_state ok "$domain" "签发成功"
        fi
        if echo "$domain" | grep -q '^\*\.'; then
            local base=$(echo "$domain" | sed 's/^\*\.//')
            [ ! -e "${CERT_DIR}/${base}" ] && ln -sf "${safe}" "${CERT_DIR}/${base}"
        fi
        [ -f "$PROXY_SCRIPT" ] && /bin/sh "$PROXY_SCRIPT" reload 2>/dev/null
        return 0
    else
        keep_existing_cert_ok "$domain" "签发失败 (exit=$ret)" && return 0
        log "失败 (exit=$ret)"
        write_state error "$domain" "签发失败 (exit=$ret)，请查看 ACME 日志"
        return 1
    fi
}

cert_is_staging() {
    openssl x509 -in "$1" -noout -issuer 2>/dev/null | grep -qi 'staging\|fake'
}

certs_fingerprint() {
    cat "$CERT_DIR"/*/fullchain.pem 2>/dev/null | md5sum | cut -d' ' -f1
}

do_renew() {
    local before
    do_install || return 1
    before=$(certs_fingerprint)
    log "续期..."
    "$ACME_BIN" --home "$ACME_HOME" --renew-all --server letsencrypt >> "$LOGFILE" 2>&1
    log "完成"
    # acme.sh 只替换证书文件，运行中的 Nginx 必须重载才会使用新证书。
    [ "$(certs_fingerprint)" = "$before" ] && return 0
    log "证书已更新，重载反向代理"
    [ -f "$PROXY_SCRIPT" ] && /bin/sh "$PROXY_SCRIPT" reload 2>/dev/null
    return 0
}

if [ "${MINIGATE_ACME_LIBRARY_ONLY:-0}" = "1" ]; then
    return 0 2>/dev/null || exit 0
fi

case "${1:-issue}" in install) do_install;; issue) do_issue "$2";; renew) do_renew;; *) echo "用法: $0 {install|issue [域名]|renew}";; esac
