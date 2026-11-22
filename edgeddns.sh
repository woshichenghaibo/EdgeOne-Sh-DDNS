#!/bin/sh
# /root/edgeddns.sh
# EdgeOne 国际站源站组 IPv6 DDNS（BusyBox 兼容）

# ================= 配置区 =================
SECRET_ID="IKIDaTuCJLBoEUXN0Xt30mOft8ILF2qXF7oK"
SECRET_KEY="IQM7nKfokU6b2KWYjlfSArLekeO5iBVj"
ZONE_ID="zone-"
ORIGIN_ID="og-"          # 注意，对应 API 的 OriginId / GroupId
GROUP_ID="og-"
IP_CHECK_URL="https://api64.ipify.org"
LOG_FILE="/root/edgeddns.log"
STATE_FILE="/root/edgeddns.lastip"
DOMAIN="teo.intl.tencentcloudapi.com"

umask 077

log() {
    printf '%s %s\n' "$(date '+%F %T')" "$1" >> "$LOG_FILE"
}

fail() {
    log "[ERROR] $1"
    printf '[ERROR] %s\n' "$1" >&2
    exit 1
}

digest_hex() {
    local output hex
    output=$(openssl dgst -sha256 "$@") || return 1
    hex=${output##* }
    [ "${#hex}" -eq 64 ] || return 1
    case "$hex" in *[!0-9a-fA-F]*) return 1 ;; esac
    printf '%s' "$hex"
}

sign_v3() {
    local payload="$1" timestamp="$2" date_utc="$3"
    local payload_hash canonical_request canonical_hash scope string_to_sign
    local k_date k_service k_signing signature

    payload_hash=$(printf '%s' "$payload" | digest_hex) || return 1
    canonical_request=$(printf 'POST\n/\n\ncontent-type:application/json\nhost:%s\nx-tc-action:modifyorigingroup\n\ncontent-type;host;x-tc-action\n%s' "$DOMAIN" "$payload_hash") || return 1
    canonical_hash=$(printf '%s' "$canonical_request" | digest_hex) || return 1
    scope="${date_utc}/teo/tc3_request"
    string_to_sign=$(printf 'TC3-HMAC-SHA256\n%s\n%s\n%s' "$timestamp" "$scope" "$canonical_hash") || return 1

    k_date=$(printf '%s' "$date_utc" | digest_hex -hmac "TC3${SECRET_KEY}") || return 1
    k_service=$(printf '%s' "teo" | digest_hex -mac HMAC -macopt "hexkey:${k_date}") || return 1
    k_signing=$(printf '%s' "tc3_request" | digest_hex -mac HMAC -macopt "hexkey:${k_service}") || return 1
    signature=$(printf '%s' "$string_to_sign" | digest_hex -mac HMAC -macopt "hexkey:${k_signing}") || return 1

    printf 'TC3-HMAC-SHA256 Credential=%s/%s, SignedHeaders=content-type;host;x-tc-action, Signature=%s' "$SECRET_ID" "$scope" "$signature"
}

api_request() {
    local payload="$1" timestamp date_utc token date_values

    date_values=$(date -u '+%s %Y-%m-%d') || return 1
    set -- $date_values
    [ "$#" -eq 2 ] || return 1
    timestamp="$1"
    date_utc="$2"

    token=$(sign_v3 "$payload" "$timestamp" "$date_utc") || return 1

    curl -fsS --connect-timeout 15 --max-time 30 \
        -H "Host: $DOMAIN" \
        -H "Content-Type: application/json" \
        -H "Authorization: $token" \
        -H "X-TC-Version: 2022-09-01" \
        -H "X-TC-Timestamp: $timestamp" \
        -H "X-TC-Action: ModifyOriginGroup" \
        --data-binary "$payload" \
        "https://$DOMAIN/"
}

for cmd in curl openssl jsonfilter; do
    command -v "$cmd" >/dev/null 2>&1 || fail "缺少命令: $cmd"
done

case "$SECRET_ID:$SECRET_KEY" in
    *填写*|:*|*:) fail "请填写新的 SecretId 和 SecretKey" ;;
esac
case "$ZONE_ID:$GROUP_ID" in
    *填写*|:*|*:) fail "请填写 ZoneId 和源站组 GroupId" ;;
    *[!a-zA-Z0-9_:-]*) fail "ZoneId 或 GroupId 含有非法字符" ;;
esac

CURRENT_IPV6=$(curl -fsS -6 --connect-timeout 10 --max-time 30 "$IP_CHECK_URL") \
    || fail "获取 IPv6 失败"

case "$CURRENT_IPV6" in
    ''|*[!0-9a-fA-F:]*) fail "获取到的地址不是有效的 IPv6 格式" ;;
    *:*) ;;
    *) fail "获取到的地址不是 IPv6" ;;
esac
[ "${#CURRENT_IPV6}" -le 39 ] || fail "获取到的 IPv6 地址过长"

LAST_IPV6=""
if [ -f "$STATE_FILE" ]; then
    LAST_IPV6=$(cat "$STATE_FILE") || fail "无法读取状态文件"
fi
[ "$CURRENT_IPV6" = "$LAST_IPV6" ] && exit 0

PAYLOAD=$(printf '{"ZoneId":"%s","GroupId":"%s","Records":[{"Record":"%s","Type":"IP_DOMAIN"}]}' \
    "$ZONE_ID" "$GROUP_ID" "$CURRENT_IPV6")

RESULT=$(api_request "$PAYLOAD") || fail "签名生成或 API 请求失败"
REQUEST_ID=$(jsonfilter -s "$RESULT" -e '@.Response.RequestId') \
    || fail "无法解析 API 响应: $RESULT"
ERROR=$(jsonfilter -s "$RESULT" -e '@.Response.Error' 2>/dev/null) || ERROR=""

if [ -n "$ERROR" ] || [ -z "$REQUEST_ID" ]; then
    fail "更新失败: $RESULT"
fi

printf '%s\n' "$CURRENT_IPV6" > "$STATE_FILE" || fail "更新成功，但无法写入状态文件"
log "[OK] 源站组已更新为 $CURRENT_IPV6 (RequestId: $REQUEST_ID)"
