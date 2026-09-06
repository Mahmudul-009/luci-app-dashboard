#!/bin/sh

# ============================================================
# OpenWrt Network Monitor - Single File Prototype
# ============================================================

CONFIG="network_monitor"
DATA="/tmp/network-monitor"
HISTORY="$DATA/history.log"
ISP_LOG="$DATA/isp_scores.csv"
REPORT_DIR="$DATA/reports"

mkdir -p "$DATA" "$REPORT_DIR"

log() {
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$HISTORY" >/dev/null
}

wan_iface() {
    ubus call network.interface.wan status 2>/dev/null | jsonfilter -e '@.l3_device' 2>/dev/null
}

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "Missing required command: $1"
        return 1
    }
}

human_bytes() {
    numfmt --to=iec "$1" 2>/dev/null || echo "$1 B"
}

get_lan_iface() {
    local iface
    iface="$(ubus call network.interface.lan status 2>/dev/null | jsonfilter -e '@.l3_device' 2>/dev/null)"
    [ -n "$iface" ] || iface="br-lan"
    echo "$iface"
}

top_users() {
    echo "=========================================="
    echo "         TOP BANDWIDTH USERS"
    echo "=========================================="

    if command -v nlbw >/dev/null 2>&1; then
        echo "(Using nlbw host table when available)"
        nlbw -c list -g ip,mac,rx,tx 2>/dev/null | head -n 15
        return 0
    fi

    echo "(Fallback: interface-level counters)"
    printf "%-18s %-15s %-15s\n" "DEVICE" "RX" "TX"
    echo "------------------------------------------------"

    for dev in /sys/class/net/*; do
        local name rx tx rv tv
        name="$(basename "$dev")"
        case "$name" in
            br-*|lan*|eth*|wlan*|phy*|wwan*)
                ;;
            *)
                continue
                ;;
        esac

        rx="/sys/class/net/$name/statistics/rx_bytes"
        tx="/sys/class/net/$name/statistics/tx_bytes"
        [ -f "$rx" ] || continue
        [ -f "$tx" ] || continue

        rv="$(cat "$rx" 2>/dev/null)"
        tv="$(cat "$tx" 2>/dev/null)"
        printf "%-18s %-15s %-15s\n" "$name" "$(human_bytes "$rv")" "$(human_bytes "$tv")"
    done
}

priority_set() {
    local device profile section
    device="$1"
    profile="$2"

    [ -n "$device" ] || {
        echo "Usage: $0 priority-set <MAC_OR_IP> <gaming|browsing|download|normal>"
        return 1
    }
    [ -n "$profile" ] || profile="normal"

    case "$profile" in
        gaming|browsing|download|normal) ;;
        *)
            echo "Invalid profile: $profile"
            return 1
            ;;
    esac

    section="$(echo "$device" | tr ':./' '___')"
    uci -q get "$CONFIG.$section" >/dev/null || uci set "$CONFIG.$section=priority"
    uci set "$CONFIG.$section.device=$device"
    uci set "$CONFIG.$section.profile=$profile"
    uci set "$CONFIG.$section.updated=$(date +%s)"
    uci commit "$CONFIG"
    log "Priority profile set: $device => $profile"
    echo "Saved priority profile. Apply QoS/SQM rules separately."
}

priority_list() {
    echo "=========================================="
    echo "        PRIORITY DEVICE PROFILES"
    echo "=========================================="
    uci -q show "$CONFIG" 2>/dev/null | grep "=priority\|\.device=\|\.profile=" || echo "No priority profiles found."
}

parental_add() {
    local device from to block_domains section
    device="$1"
    from="$2"
    to="$3"
    block_domains="$4"

    [ -n "$device" ] || {
        echo "Usage: $0 parental-add <MAC_OR_IP> <HH:MM> <HH:MM> <domain1,domain2,...>"
        return 1
    }
    [ -n "$from" ] || from="21:00"
    [ -n "$to" ] || to="06:00"
    [ -n "$block_domains" ] || block_domains="youtube.com,facebook.com,tiktok.com"

    section="pc_$(echo "$device" | tr ':./' '___')"
    uci -q get "$CONFIG.$section" >/dev/null || uci set "$CONFIG.$section=parental"
    uci set "$CONFIG.$section.device=$device"
    uci set "$CONFIG.$section.start=$from"
    uci set "$CONFIG.$section.stop=$to"
    uci set "$CONFIG.$section.domains=$block_domains"
    uci set "$CONFIG.$section.enabled='1'"
    uci commit "$CONFIG"
    log "Parental rule added: $device $from-$to domains=$block_domains"
    echo "Parental rule saved (prototype). Firewall/DNS enforcement hook required."
}

parental_list() {
    echo "=========================================="
    echo "            PARENTAL CONTROL"
    echo "=========================================="
    uci -q show "$CONFIG" 2>/dev/null | grep "=parental\|\.device=\|\.start=\|\.stop=\|\.domains=\|\.enabled=" || echo "No parental rules found."
}

report_generate() {
    local ts txt csv pdf
    ts="$(date '+%Y%m%d-%H%M%S')"
    txt="$REPORT_DIR/report-$ts.txt"
    csv="$REPORT_DIR/report-$ts.csv"
    pdf="$REPORT_DIR/report-$ts.pdf"

    {
        echo "OpenWrt Network Monitor Report"
        echo "Generated: $(date)"
        echo
        echo "WAN Interface: $(wan_iface)"
        echo "LAN Interface: $(get_lan_iface)"
        echo
        echo "[Top Users]"
        top_users
        echo
        echo "[Priority Profiles]"
        priority_list
        echo
        echo "[Parental Rules]"
        parental_list
        echo
        echo "[Recent ISP Scores]"
        tail -n 10 "$ISP_LOG" 2>/dev/null || echo "No ISP scores yet."
    } >"$txt"

    {
        echo "metric,value"
        echo "generated_at,$(date '+%Y-%m-%d %H:%M:%S')"
        echo "wan_iface,$(wan_iface)"
        echo "lan_iface,$(get_lan_iface)"
    } >"$csv"

    if command -v wkhtmltopdf >/dev/null 2>&1; then
        sed 's/$/<br>/' "$txt" | wkhtmltopdf -q - "$pdf" >/dev/null 2>&1 && {
            log "PDF report created: $pdf"
            echo "PDF report: $pdf"
        }
    fi

    log "Reports created: $txt and $csv"
    echo "Text report: $txt"
    echo "CSV report:  $csv"
}

app_usage() {
    echo "=========================================="
    echo "     APP / DOMAIN TRAFFIC USAGE"
    echo "=========================================="

    if command -v nlbw >/dev/null 2>&1; then
        echo "(Host traffic from nlbw; app-level mapping requires DNS/DPI source)"
        nlbw -c list -g ip,rx,tx 2>/dev/null | head -n 20
        echo
    fi

    if [ -f /tmp/dnsmasq.log ]; then
        echo "(Top queried domains from dnsmasq log)"
        awk '/query\[[A-Z]+\] /{print $NF}' /tmp/dnsmasq.log | \
            sed 's/\.$//' | \
            awk -F. 'NF>=2{print $(NF-1)"."$NF}' | \
            sort | uniq -c | sort -nr | head -n 15
    else
        echo "No dnsmasq query log found. Enable dnsmasq logging for domain insight."
    fi
}

isp_test() {
    local host count out loss avg jitter score timestamp
    host="${1:-1.1.1.1}"
    count="${2:-10}"

    need_cmd ping || return 1
    out="$(ping -c "$count" -W 2 "$host" 2>/dev/null)"
    [ -n "$out" ] || {
        echo "Ping test failed for host: $host"
        return 1
    }

    loss="$(echo "$out" | awk -F',' '/packet loss/ {gsub(/ /,"",$3); gsub(/%packetloss/,"",$3); print $3}')"
    avg="$(echo "$out" | awk -F'/' '/min\/avg\/max/ {print $5}')"
    jitter="$(echo "$out" | awk -F'/' '/min\/avg\/max/ {print $7}')"
    [ -n "$loss" ] || loss=100
    [ -n "$avg" ] || avg=999
    [ -n "$jitter" ] || jitter=999

    score="$(awk -v l="$loss" -v a="$avg" -v j="$jitter" 'BEGIN{
        s=100-(l*1.2)-(a*0.25)-(j*0.8);
        if (s<0) s=0;
        printf "%.1f", s
    }')"

    timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
    [ -f "$ISP_LOG" ] || echo "timestamp,host,loss_percent,avg_ms,jitter_ms,score" >"$ISP_LOG"
    echo "$timestamp,$host,$loss,$avg,$jitter,$score" >>"$ISP_LOG"

    echo "Host:   $host"
    echo "Loss:   ${loss}%"
    echo "Avg:    ${avg} ms"
    echo "Jitter: ${jitter} ms"
    echo "Score:  $score / 100"
    echo "Log:    $ISP_LOG"
    log "ISP test host=$host loss=$loss avg=$avg jitter=$jitter score=$score"
}

bufferbloat_test() {
    local host load_cmd idle loaded grade delta
    host="${1:-1.1.1.1}"
    load_cmd="${2:-wget -q -O /dev/null http://speedtest.tele2.net/10MB.zip}"

    need_cmd ping || return 1

    idle="$(ping -c 5 -W 2 "$host" 2>/dev/null | awk -F'/' '/min\/avg\/max/ {print $5}')"
    [ -n "$idle" ] || {
        echo "Unable to collect idle latency."
        return 1
    }

    sh -c "$load_cmd" >/dev/null 2>&1 &
    local load_pid="$!"
    sleep 1
    loaded="$(ping -c 5 -W 2 "$host" 2>/dev/null | awk -F'/' '/min\/avg\/max/ {print $5}')"
    kill "$load_pid" >/dev/null 2>&1
    wait "$load_pid" 2>/dev/null

    [ -n "$loaded" ] || loaded="$idle"
    delta="$(awk -v i="$idle" -v l="$loaded" 'BEGIN{printf "%.2f", (l-i)}')"

    grade="$(awk -v d="$delta" 'BEGIN{
        if (d<5) print "A";
        else if (d<15) print "B";
        else if (d<30) print "C";
        else if (d<60) print "D";
        else print "F";
    }')"

    echo "Idle latency:      $idle ms"
    echo "Under-load latency:$loaded ms"
    echo "Delta:             $delta ms"
    echo "Bufferbloat grade: $grade"
    log "Bufferbloat test host=$host idle=$idle loaded=$loaded delta=$delta grade=$grade"
}

show_help() {
    cat <<'EOF'
OpenWrt Network Monitor Prototype

Usage:
  network-monitor.sh top-users
  network-monitor.sh priority-set <MAC_OR_IP> <gaming|browsing|download|normal>
  network-monitor.sh priority-list
  network-monitor.sh parental-add <MAC_OR_IP> <HH:MM> <HH:MM> <domain1,domain2,...>
  network-monitor.sh parental-list
  network-monitor.sh report
  network-monitor.sh app-usage
  network-monitor.sh isp-test [host] [count]
  network-monitor.sh bufferbloat [host] [load_command]
  network-monitor.sh help
EOF
}

cmd="$1"
shift 2>/dev/null || true

case "$cmd" in
    top-users) top_users ;;
    priority-set) priority_set "$@" ;;
    priority-list) priority_list ;;
    parental-add) parental_add "$@" ;;
    parental-list) parental_list ;;
    report) report_generate ;;
    app-usage) app_usage ;;
    isp-test) isp_test "$@" ;;
    bufferbloat) bufferbloat_test "$@" ;;
    help|"") show_help ;;
    *)
        echo "Unknown command: $cmd"
        show_help
        exit 1
        ;;
esac
