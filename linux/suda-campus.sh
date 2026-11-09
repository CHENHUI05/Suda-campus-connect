#!/usr/bin/env bash
# 苏州大学校园网自动连接（Linux 服务器版）
# 用法：./suda-campus.sh start | stop | connect | logout | status
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF="$SCRIPT_DIR/suda-campus.conf"
LOG="$SCRIPT_DIR/campus.log"

log() {
    local line
    line="$(date '+%Y-%m-%d %H:%M:%S') $*"
    echo "$line"
    echo "$line" >> "$LOG"
}

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || { echo "缺少命令：$1，请先安装后再运行。" >&2; exit 1; }
}

load_config() {
    [ -f "$CONF" ] || { echo "找不到配置文件 $CONF，请先执行：cp suda-campus.conf.example suda-campus.conf 并填写账号密码。" >&2; exit 1; }
    # shellcheck disable=SC1090
    source "$CONF"
    : "${USERNAME:?配置中 USERNAME 不能为空}"
    : "${PASSWORD:?配置中 PASSWORD 不能为空}"
    GATEWAY="${GATEWAY:-10.9.1.3}"
    INTERVAL="${INTERVAL:-30}"
}

# 获取校园网网卡的 IPv4 地址：指定 IFACE 时取该网卡，否则取通往网关的路由源地址
get_ip() {
    if [ -n "${IFACE:-}" ]; then
        ip -4 addr show "$IFACE" | awk '/inet /{print $2}' | cut -d/ -f1 | head -1
    else
        ip route get "$GATEWAY" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}'
    fi
}

# 调用 Dr.COM 网关，login / logout
gateway_request() {
    local action="$1" ip="$2"
    if [ "$action" = login ]; then
        curl -fsS -G --max-time 10 "http://${GATEWAY}:801/eportal/" \
            --data-urlencode "c=Portal" \
            --data-urlencode "a=login" \
            --data-urlencode "login_method=1" \
            --data-urlencode "user_account=,0,${USERNAME}" \
            --data-urlencode "user_password=${PASSWORD}" \
            --data-urlencode "wlan_user_ip=${ip}"
    else
        curl -fsS -G --max-time 10 "http://${GATEWAY}:801/eportal/" \
            --data-urlencode "c=Portal" \
            --data-urlencode "a=logout" \
            --data-urlencode "login_method=1" \
            --data-urlencode "wlan_user_ip=${ip}"
    fi
}

json_field() {
    # $1=响应内容 $2=字段名，取出字段对应的数字值；字段缺失时返回空串且不报错
    local value
    value="$(echo "$1" \
        | grep -oE "\"$2\"[[:space:]]*:[[:space:]]*\"[0-9]+\"" 2>/dev/null \
        | grep -oE '[0-9]+' 2>/dev/null \
        | head -1 || true)"
    echo "$value"
}

do_connect() {
    local ip resp result retcode
    ip="$(get_ip)"
    [ -n "$ip" ] || { log "失败：无法获取本机 IPv4，请检查网线/网络，或在配置中指定 IFACE。"; exit 1; }
    resp="$(gateway_request login "$ip")" || { log "失败：无法访问网关 $GATEWAY，请确认服务器在校内且未走代理/VPN。"; exit 1; }
    result="$(json_field "$resp" result)"
    retcode="$(json_field "$resp" ret_code)"
    if [ "$result" = "1" ]; then
        log "连接成功（$ip）。"
    elif [ "$result" = "0" ] && [ "$retcode" = "2" ]; then
        log "已经在线（$ip）。"
    else
        log "失败：登录被拒绝，请检查账号、密码、运营商后缀。原始响应已脱敏不记录。"
        exit 1
    fi
}

do_logout() {
    local ip resp result
    ip="$(get_ip)"
    [ -n "$ip" ] || { log "失败：无法获取本机 IPv4。"; exit 1; }
    resp="$(gateway_request logout "$ip")" || { log "失败：无法访问网关，请到学校门户确认登出。"; exit 1; }
    result="$(json_field "$resp" result)"
    if [ "$result" = "1" ]; then
        log "网关返回断开成功（$ip）。"
    else
        log "失败：网关未确认登出，请到学校门户手动确认。"
        exit 1
    fi
}

cron_job_line() { echo "*/${INTERVAL} * * * * $SCRIPT_DIR/suda-campus.sh connect >> $SCRIPT_DIR/campus.log 2>&1"; }
cron_boot_line() { echo "@reboot sleep 15 && $SCRIPT_DIR/suda-campus.sh connect >> $SCRIPT_DIR/campus.log 2>&1"; }

install_cron() {
    need_cmd crontab
    local tmp
    tmp="$(mktemp)"
    crontab -l 2>/dev/null | grep -v 'suda-campus.sh' > "$tmp" || true
    echo "$(cron_job_line)" >> "$tmp"
    echo "$(cron_boot_line)" >> "$tmp"
    crontab "$tmp"
    rm -f "$tmp"
}

remove_cron() {
    if ! command -v crontab >/dev/null 2>&1; then return 0; fi
    local tmp
    tmp="$(mktemp)"
    crontab -l 2>/dev/null | grep -v 'suda-campus.sh' > "$tmp" || true
    crontab "$tmp"
    rm -f "$tmp"
}

case "${1:-}" in
    start)
        need_cmd curl; need_cmd ip
        load_config
        install_cron
        log "自动连接已开启：每 $INTERVAL 分钟一次，开机后 15 秒自动连接。"
        do_connect
        ;;
    stop)
        need_cmd curl; need_cmd ip
        load_config
        remove_cron
        log "自动连接已停止，正在请求网关登出。"
        do_logout
        ;;
    connect)
        need_cmd curl; need_cmd ip
        load_config
        do_connect
        ;;
    logout)
        need_cmd curl; need_cmd ip
        load_config
        do_logout
        ;;
    status)
        load_config
        if command -v crontab >/dev/null 2>&1 && crontab -l 2>/dev/null | grep -q 'suda-campus.sh'; then
            echo "定时任务：已启用，每 $INTERVAL 分钟执行一次"
            crontab -l | grep 'suda-campus.sh'
        else
            echo "定时任务：未启用"
        fi
        echo "本机校园网 IP：$(get_ip || echo '未获取到')"
        ;;
    *)
        echo "用法：$0 {start|stop|connect|logout|status}"
        exit 1
        ;;
esac
