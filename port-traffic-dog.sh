#!/bin/bash

set -euo pipefail

readonly SCRIPT_VERSION="1.2.5"
readonly SCRIPT_NAME="端口流量�?
readonly SCRIPT_PATH="$(realpath "$0")"
readonly CONFIG_DIR="/etc/port-traffic-dog"
readonly CONFIG_FILE="$CONFIG_DIR/config.json"
readonly LOG_FILE="$CONFIG_DIR/logs/traffic.log"
readonly TRAFFIC_DATA_FILE="$CONFIG_DIR/traffic_data.json"

readonly RED='\033[0;31m'
readonly YELLOW='\033[0;33m'
readonly BLUE='\033[0;34m'
readonly GREEN='\033[0;32m'
readonly NC='\033[0m'
# 网络超时设置
readonly SHORT_CONNECT_TIMEOUT=5
readonly SHORT_MAX_TIMEOUT=7
readonly SCRIPT_URL="https://raw.githubusercontent.com/byby5555/realm-xwPF-active-standby/main/port-traffic-dog.sh"
readonly SHORTCUT_COMMAND="dog"

detect_system() {
    # Ubuntu优先检测：避免Debian系统误判
    if [ -f /etc/lsb-release ] && grep -q "Ubuntu" /etc/lsb-release 2>/dev/null; then
        echo "ubuntu"
        return
    fi

    if [ -f /etc/debian_version ]; then
        echo "debian"
        return
    fi

    echo "unknown"
}

install_missing_tools() {
    local missing_tools=("$@")
    local system_type=$(detect_system)
    local pkg_cmd
    case $system_type in
        "ubuntu") pkg_cmd="apt" ;;
        "debian") pkg_cmd="apt-get" ;;
        *)
            echo -e "${RED}不支持的系统类型: $system_type${NC}"
            echo "支持的系�? Ubuntu, Debian"
            echo "请手动安�? ${missing_tools[*]}"
            exit 1
            ;;
    esac

    echo -e "${YELLOW}检测到缺少工具: ${missing_tools[*]}${NC}"
    echo "正在自动安装..."

    $pkg_cmd update -qq
    for tool in "${missing_tools[@]}"; do
        case $tool in
            "nft") $pkg_cmd install -y nftables ;;
            "tc") $pkg_cmd install -y iproute2 ;;
            "ss") $pkg_cmd install -y iproute2 ;;
            "jq") $pkg_cmd install -y jq ;;
            "awk") $pkg_cmd install -y gawk ;;
            "bc") $pkg_cmd install -y bc ;;
            "cron")
                $pkg_cmd install -y cron
                systemctl enable cron 2>/dev/null || true
                systemctl start cron 2>/dev/null || true
                ;;
            *) $pkg_cmd install -y "$tool" ;;
        esac
    done

    echo -e "${GREEN}依赖工具安装完成${NC}"
}

check_dependencies() {
    local silent_mode=${1:-false}
    local missing_tools=()
    local required_tools=("nft" "tc" "ss" "jq" "awk" "bc" "unzip" "cron")

    for tool in "${required_tools[@]}"; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            missing_tools+=("$tool")
        fi
    done

    if [ ${#missing_tools[@]} -gt 0 ]; then
        install_missing_tools "${missing_tools[@]}"

        local still_missing=()
        for tool in "${missing_tools[@]}"; do
            if ! command -v "$tool" >/dev/null 2>&1; then
                still_missing+=("$tool")
            fi
        done

        if [ ${#still_missing[@]} -gt 0 ]; then
            echo -e "${RED}安装失败，仍缺少工具: ${still_missing[*]}${NC}"
            echo "请手动安装后重试"
            exit 1
        fi
    fi

    if [ "$silent_mode" != "true" ]; then
        echo -e "${GREEN}依赖检查通过${NC}"
    fi

    setup_script_permissions
    setup_cron_environment
    # 重启后恢复定时任�?
    local active_ports=($(get_active_ports 2>/dev/null || true))
    for port in "${active_ports[@]}"; do
        setup_port_auto_reset_cron "$port" >/dev/null 2>&1 || true
    done
}

setup_script_permissions() {
    if [ -f "$SCRIPT_PATH" ]; then
        chmod +x "$SCRIPT_PATH" 2>/dev/null || true
    fi

    if [ -f "/usr/local/bin/port-traffic-dog.sh" ]; then
        chmod +x "/usr/local/bin/port-traffic-dog.sh" 2>/dev/null || true
    fi
}

setup_cron_environment() {
    # cron环境PATH不完整，需要设置完整路�?
    local current_cron=$(crontab -l 2>/dev/null || true)
    if ! echo "$current_cron" | grep -q "^PATH=.*sbin"; then
        local temp_cron=$(mktemp)
        echo "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" > "$temp_cron"
        echo "$current_cron" | grep -v "^PATH=" >> "$temp_cron" || true
        crontab "$temp_cron" 2>/dev/null || true
        rm -f "$temp_cron"
    fi
}

check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}错误：此脚本需要root权限运行${NC}"
        exit 1
    fi
}

init_config() {
    mkdir -p "$CONFIG_DIR" "$(dirname "$LOG_FILE")"

    # 静默下载通知模块，避免影响主流程
    download_notification_modules >/dev/null 2>&1 || true

    if [ ! -f "$CONFIG_FILE" ]; then
        cat > "$CONFIG_FILE" << 'EOF'
{
  "global": {
    "billing_mode": "double"
  },
  "ports": {},
  "nftables": {
    "table_name": "port_traffic_monitor",
    "family": "inet"
  },
  "notifications": {
    "telegram": {
      "enabled": false,
      "bot_token": "",
      "chat_id": "",
      "server_name": "",
      "status_notifications": {
        "enabled": false,
        "interval": "1h"
      }
    },
    "email": {
      "enabled": false,
      "status": "coming_soon"
    },
    "wecom": {
      "enabled": false,
      "webhook_url": "",
      "server_name": "",
      "status_notifications": {
        "enabled": false,
        "interval": "1h"
      }
    }
  }
}
EOF
    fi

    init_nftables
    setup_exit_hooks
    restore_monitoring_if_needed
}

init_nftables() {
    local table_name=$(jq -r '.nftables.table_name' "$CONFIG_FILE")
    local family=$(jq -r '.nftables.family' "$CONFIG_FILE")
    # 使用inet family支持IPv4/IPv6双栈
    nft add table $family $table_name 2>/dev/null || true
    nft add chain $family $table_name input { type filter hook input priority 0\; } 2>/dev/null || true
    nft add chain $family $table_name output { type filter hook output priority 0\; } 2>/dev/null || true
    nft add chain $family $table_name forward { type filter hook forward priority 0\; } 2>/dev/null || true
}

get_network_interfaces() {
    local interfaces=()

    while IFS= read -r interface; do
        if [[ "$interface" != "lo" ]] && [[ "$interface" != "" ]]; then
            interfaces+=("$interface")
        fi
    done < <(ip link show | grep "state UP" | awk -F': ' '{print $2}' | cut -d'@' -f1)

    printf '%s\n' "${interfaces[@]}"
}

get_default_interface() {
    local default_interface=$(ip route | grep default | awk '{print $5}' | head -n1)

    if [ -n "$default_interface" ]; then
        echo "$default_interface"
        return
    fi

    local interfaces=($(get_network_interfaces))
    if [ ${#interfaces[@]} -gt 0 ]; then
        echo "${interfaces[0]}"
    else
        echo "eth0"
    fi
}

format_bytes() {
    local bytes=$1

    if ! [[ "$bytes" =~ ^[0-9]+$ ]]; then
        bytes=0
    fi

    if [ $bytes -ge 1073741824 ]; then
        local gb=$(echo "scale=2; $bytes / 1073741824" | bc)
        echo "${gb}GB"
    elif [ $bytes -ge 1048576 ]; then
        local mb=$(echo "scale=2; $bytes / 1048576" | bc)
        echo "${mb}MB"
    elif [ $bytes -ge 1024 ]; then
        local kb=$(echo "scale=2; $bytes / 1024" | bc)
        echo "${kb}KB"
    else
        echo "${bytes}B"
    fi
}

get_beijing_time() {
    TZ='Asia/Shanghai' date "$@"
}

update_config() {
    local jq_expression="$1"
    jq "$jq_expression" "$CONFIG_FILE" > "${CONFIG_FILE}.tmp"
    mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
}

show_port_list() {
    local active_ports=($(get_active_ports))
    if [ ${#active_ports[@]} -eq 0 ]; then
        echo "暂无监控端口"
        return 1
    fi

    echo "当前监控的端�?"
    for i in "${!active_ports[@]}"; do
        local port=${active_ports[$i]}
        local status_label=$(get_port_status_label "$port")
        echo "$((i+1)). 端口 $port $status_label"
    done
    return 0
}

parse_multi_choice_input() {
    local input="$1"
    local max_choice="$2"
    local -n result_array=$3

    IFS=',' read -ra CHOICES <<< "$input"
    result_array=()

    for choice in "${CHOICES[@]}"; do
        choice=$(echo "$choice" | tr -d ' ')
        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "$max_choice" ]; then
            result_array+=("$choice")
        else
            echo -e "${RED}无效选择: $choice${NC}"
        fi
    done
}

parse_comma_separated_input() {
    local input="$1"
    local -n result_array=$2

    IFS=',' read -ra result_array <<< "$input"

    for i in "${!result_array[@]}"; do
        result_array[$i]=$(echo "${result_array[$i]}" | tr -d ' ')
    done
}

parse_port_range_input() {
    local input="$1"
    local -n result_array=$2

    IFS=',' read -ra PARTS <<< "$input"
    result_array=()

    for part in "${PARTS[@]}"; do
        part=$(echo "$part" | tr -d ' ')

        if is_port_range "$part"; then
            # 端口段：100-200
            local start_port=$(echo "$part" | cut -d'-' -f1)
            local end_port=$(echo "$part" | cut -d'-' -f2)

            if [ "$start_port" -gt "$end_port" ]; then
                echo -e "${RED}错误：端口段 $part 起始端口大于结束端口${NC}"
                return 1
            fi

            if [ "$start_port" -lt 1 ] || [ "$start_port" -gt 65535 ] || [ "$end_port" -lt 1 ] || [ "$end_port" -gt 65535 ]; then
                echo -e "${RED}错误：端口段 $part 包含无效端口，必须在1-65535范围�?{NC}"
                return 1
            fi

            result_array+=("$part")

        elif [[ "$part" =~ ^[0-9]+$ ]]; then
            if [ "$part" -ge 1 ] && [ "$part" -le 65535 ]; then
                result_array+=("$part")
            else
                echo -e "${RED}错误：端口号 $part 无效，必须是1-65535之间的数�?{NC}"
                return 1
            fi
        else
            echo -e "${RED}错误：无效的端口格式 $part${NC}"
            return 1
        fi
    done

    return 0
}

expand_single_value_to_array() {
    local -n source_array=$1
    local target_size=$2

    if [ ${#source_array[@]} -eq 1 ]; then
        local single_value="${source_array[0]}"
        source_array=()
        for ((i=0; i<target_size; i++)); do
            source_array+=("$single_value")
        done
    fi
}


get_beijing_month_year() {
    local current_day=$(TZ='Asia/Shanghai' date +%d | sed 's/^0//')
    local current_month=$(TZ='Asia/Shanghai' date +%m | sed 's/^0//')
    local current_year=$(TZ='Asia/Shanghai' date +%Y)
    echo "$current_day $current_month $current_year"
}

get_nftables_counter_data() {
    local port=$1
    local table_name=$(jq -r '.nftables.table_name' "$CONFIG_FILE")
    local family=$(jq -r '.nftables.family' "$CONFIG_FILE")
    local billing_mode=$(jq -r ".ports.\"$port\".billing_mode // \"double\"" "$CONFIG_FILE")

    local input_bytes=0
    local output_bytes=0

    if is_port_range "$port"; then
        local port_safe=$(echo "$port" | tr '-' '_')
        if [ "$billing_mode" = "double" ]; then
            input_bytes=$(nft list counter $family $table_name "port_${port_safe}_in" 2>/dev/null | \
                grep -o 'bytes [0-9]*' | awk '{print $2}' || true)
        fi
        output_bytes=$(nft list counter $family $table_name "port_${port_safe}_out" 2>/dev/null | \
            grep -o 'bytes [0-9]*' | awk '{print $2}' || true)
    else
        if [ "$billing_mode" = "double" ]; then
            input_bytes=$(nft list counter $family $table_name "port_${port}_in" 2>/dev/null | \
                grep -o 'bytes [0-9]*' | awk '{print $2}' || true)
        fi
        output_bytes=$(nft list counter $family $table_name "port_${port}_out" 2>/dev/null | \
            grep -o 'bytes [0-9]*' | awk '{print $2}' || true)
    fi

    input_bytes=${input_bytes:-0}
    output_bytes=${output_bytes:-0}
    echo "$input_bytes $output_bytes"
}



save_traffic_data() {
    local temp_file=$(mktemp)
    local active_ports=($(get_active_ports 2>/dev/null || true))

    if [ ${#active_ports[@]} -eq 0 ]; then
        return 0
    fi

    echo '{}' > "$temp_file"

    for port in "${active_ports[@]}"; do
        local traffic_data=($(get_nftables_counter_data "$port"))
        local current_input=${traffic_data[0]}
        local current_output=${traffic_data[1]}

        # 只备份有意义的数�?
        if [ $current_input -gt 0 ] || [ $current_output -gt 0 ]; then
            jq ".\"$port\" = {\"input\": $current_input, \"output\": $current_output, \"backup_time\": \"$(get_beijing_time -Iseconds)\"}" \
                "$temp_file" > "${temp_file}.tmp" && mv "${temp_file}.tmp" "$temp_file"
        fi
    done

    if [ -s "$temp_file" ] && [ "$(jq 'keys | length' "$temp_file" 2>/dev/null)" != "0" ]; then
        mv "$temp_file" "$TRAFFIC_DATA_FILE"
    else
        rm -f "$temp_file"
    fi
}

setup_exit_hooks() {
    # 进程退出时自动保存数据，避免重启丢�?
    trap 'save_traffic_data_on_exit' EXIT
    trap 'save_traffic_data_on_exit; exit 1' INT TERM
}

save_traffic_data_on_exit() {
    save_traffic_data >/dev/null 2>&1
}

restore_monitoring_if_needed() {
    local active_ports=($(get_active_ports 2>/dev/null || true))

    if [ ${#active_ports[@]} -eq 0 ]; then
        return 0
    fi

    # 检查nftables规则是否存在，判断是否需要恢�?
    local table_name=$(jq -r '.nftables.table_name' "$CONFIG_FILE")
    local family=$(jq -r '.nftables.family' "$CONFIG_FILE")
    local need_restore=false

    for port in "${active_ports[@]}"; do
        if is_port_range "$port"; then
            local port_safe=$(echo "$port" | tr '-' '_')
            if ! nft list counter $family $table_name "port_${port_safe}_out" >/dev/null 2>&1; then
                need_restore=true
                break
            fi
        else
            if ! nft list counter $family $table_name "port_${port}_out" >/dev/null 2>&1; then
                need_restore=true
                break
            fi
        fi
    done

    if [ "$need_restore" = "true" ]; then
        restore_traffic_data_from_backup
        restore_all_monitoring_rules >/dev/null 2>&1 || true
    fi
}

restore_traffic_data_from_backup() {
    if [ ! -f "$TRAFFIC_DATA_FILE" ]; then
        return 0
    fi

    local table_name=$(jq -r '.nftables.table_name' "$CONFIG_FILE")
    local family=$(jq -r '.nftables.family' "$CONFIG_FILE")
    local backup_ports=($(jq -r 'keys[]' "$TRAFFIC_DATA_FILE" 2>/dev/null || true))

    for port in "${backup_ports[@]}"; do
        local backup_input=$(jq -r ".\"$port\".input // 0" "$TRAFFIC_DATA_FILE" 2>/dev/null || echo "0")
        local backup_output=$(jq -r ".\"$port\".output // 0" "$TRAFFIC_DATA_FILE" 2>/dev/null || echo "0")

        if [ $backup_input -gt 0 ] || [ $backup_output -gt 0 ]; then
            restore_counter_value "$port" "$backup_input" "$backup_output"
        fi
    done

    # 恢复完成后删除备份文�?
    rm -f "$TRAFFIC_DATA_FILE"
}

restore_counter_value() {
    local port=$1
    local target_input=$2
    local target_output=$3
    local table_name=$(jq -r '.nftables.table_name' "$CONFIG_FILE")
    local family=$(jq -r '.nftables.family' "$CONFIG_FILE")
    local billing_mode=$(jq -r ".ports.\"$port\".billing_mode // \"double\"" "$CONFIG_FILE")

    if is_port_range "$port"; then
        local port_safe=$(echo "$port" | tr '-' '_')
        if [ "$billing_mode" = "double" ]; then
            nft add counter $family $table_name "port_${port_safe}_in" { packets 0 bytes $target_input } 2>/dev/null || true
        fi
        nft add counter $family $table_name "port_${port_safe}_out" { packets 0 bytes $target_output } 2>/dev/null || true
    else
        if [ "$billing_mode" = "double" ]; then
            nft add counter $family $table_name "port_${port}_in" { packets 0 bytes $target_input } 2>/dev/null || true
        fi
        nft add counter $family $table_name "port_${port}_out" { packets 0 bytes $target_output } 2>/dev/null || true
    fi
}

restore_all_monitoring_rules() {
    local active_ports=($(get_active_ports))

    for port in "${active_ports[@]}"; do
        add_nftables_rules "$port"

        # 恢复配额限制
        local quota_enabled=$(jq -r ".ports.\"$port\".quota.enabled // false" "$CONFIG_FILE")
        local monthly_limit=$(jq -r ".ports.\"$port\".quota.monthly_limit // \"unlimited\"" "$CONFIG_FILE")
        if [ "$quota_enabled" = "true" ] && [ "$monthly_limit" != "unlimited" ]; then
            apply_nftables_quota "$port" "$monthly_limit"
        fi

        # 恢复带宽限制
        local limit_enabled=$(jq -r ".ports.\"$port\".bandwidth_limit.enabled // false" "$CONFIG_FILE")
        local rate_limit=$(jq -r ".ports.\"$port\".bandwidth_limit.rate // \"unlimited\"" "$CONFIG_FILE")
        if [ "$limit_enabled" = "true" ] && [ "$rate_limit" != "unlimited" ]; then
            local tc_limit=$(convert_bandwidth_to_tc "$rate_limit")
            if [ -n "$tc_limit" ]; then
                apply_tc_limit "$port" "$tc_limit"
            fi
        fi

        setup_port_auto_reset_cron "$port"
    done
}

calculate_total_traffic() {
    local input_bytes=$1
    local output_bytes=$2
    local billing_mode=${3:-"double"}
    case $billing_mode in
        "double")
            # 双向统计：input + output（计数器已在规则层面×2�?
            echo $((input_bytes + output_bytes))
            ;;
        "single"|*)
            # 单向统计：仅 output
            echo $output_bytes
            ;;
    esac
}


get_port_status_label() {
    local port=$1
    local port_config=$(jq -r ".ports.\"$port\"" "$CONFIG_FILE" 2>/dev/null)

    local remark=$(echo "$port_config" | jq -r '.remark // ""')
    local billing_mode=$(echo "$port_config" | jq -r '.billing_mode // "single"')
    local limit_enabled=$(echo "$port_config" | jq -r '.bandwidth_limit.enabled // false')
    local rate_limit=$(echo "$port_config" | jq -r '.bandwidth_limit.rate // "unlimited"')
    local quota_enabled=$(echo "$port_config" | jq -r '.quota.enabled // true')
    local monthly_limit=$(echo "$port_config" | jq -r '.quota.monthly_limit // "unlimited"')
    local reset_day_raw=$(echo "$port_config" | jq -r '.quota.reset_day')
    local reset_day="null"
    
    # 有流量限额时，获取重置日期（null表示用户取消了自动重置）
    if [ "$monthly_limit" != "unlimited" ] && [ "$reset_day_raw" != "null" ]; then
        reset_day="${reset_day_raw:-1}"  # 未配置时默认�?
    fi

    local status_tags=()

    if [ -n "$remark" ] && [ "$remark" != "null" ] && [ "$remark" != "" ]; then
        status_tags+=("[备注:$remark]")
    fi

    if [ "$quota_enabled" = "true" ]; then
        if [ "$monthly_limit" != "unlimited" ]; then
            local current_usage=$(get_port_monthly_usage "$port")
            local limit_bytes=$(parse_size_to_bytes "$monthly_limit")
            local usage_percent=$((current_usage * 100 / limit_bytes))

            local quota_display="$monthly_limit"
            if [ "$billing_mode" = "double" ]; then
                status_tags+=("[双向${quota_display}]")
            else
                status_tags+=("[单向${quota_display}]")
            fi
            
            # 只有配置了reset_day时才显示重置日期信息
            if [ "$reset_day" != "null" ]; then
                local time_info=($(get_beijing_month_year))
                local current_day=${time_info[0]}
                local current_month=${time_info[1]}
                local next_month=$current_month

                if [ $current_day -ge $reset_day ]; then
                    next_month=$((current_month + 1))
                    if [ $next_month -gt 12 ]; then
                        next_month=1
                    fi
                fi
                
                status_tags+=("[${next_month}�?{reset_day}日重置]")
            fi

            if [ $usage_percent -ge 100 ]; then
                status_tags+=("[已超限]")
            fi
        else
            if [ "$billing_mode" = "double" ]; then
                status_tags+=("[双向无限制]")
            else
                status_tags+=("[单向无限制]")
            fi
        fi
    fi

    if [ "$limit_enabled" = "true" ] && [ "$rate_limit" != "unlimited" ]; then
        status_tags+=("[限制带宽${rate_limit}]")
    fi

    if [ ${#status_tags[@]} -gt 0 ]; then
        printf '%s' "${status_tags[@]}"
        echo
    fi
}

get_port_monthly_usage() {
    local port=$1
    local traffic_data=($(get_nftables_counter_data "$port"))
    local input_bytes=${traffic_data[0]}
    local output_bytes=${traffic_data[1]}
    local billing_mode=$(jq -r ".ports.\"$port\".billing_mode // \"double\"" "$CONFIG_FILE")

    calculate_total_traffic "$input_bytes" "$output_bytes" "$billing_mode"
}

validate_bandwidth() {
    local input="$1"
    local lower_input=$(echo "$input" | tr '[:upper:]' '[:lower:]')

    if [[ "$input" == "0" ]]; then
        return 0
    elif [[ "$lower_input" =~ ^[0-9]+kbps$ ]] || [[ "$lower_input" =~ ^[0-9]+mbps$ ]] || [[ "$lower_input" =~ ^[0-9]+gbps$ ]]; then
        return 0
    else
        return 1
    fi
}

validate_quota() {
    local input="$1"
    local lower_input=$(echo "$input" | tr '[:upper:]' '[:lower:]')

    if [[ "$input" == "0" ]]; then
        return 0
    elif [[ "$lower_input" =~ ^[0-9]+(mb|gb|tb|m|g|t)$ ]]; then
        return 0
    else
        return 1
    fi
}

parse_size_to_bytes() {
    local size_str=$1
    local number=$(echo "$size_str" | grep -o '^[0-9]\+')
    local unit=$(echo "$size_str" | grep -o '[A-Za-z]\+$' | tr '[:lower:]' '[:upper:]')

    [ -z "$number" ] && echo "0" && return 1

    case $unit in
        "MB"|"M") echo $((number * 1048576)) ;;
        "GB"|"G") echo $((number * 1073741824)) ;;
        "TB"|"T") echo $((number * 1099511627776)) ;;
        *) echo "0" ;;
    esac
}


get_active_ports() {
    jq -r '.ports | keys[]' "$CONFIG_FILE" 2>/dev/null | sort -n
}

is_port_range() {
    local port=$1
    [[ "$port" =~ ^[0-9]+-[0-9]+$ ]]
}

generate_port_range_mark() {
    local port_range=$1
    local start_port=$(echo "$port_range" | cut -d'-' -f1)
    local end_port=$(echo "$port_range" | cut -d'-' -f2)
    # 确定性算法：避免不同端口段产生相同标�?
    echo $(( (start_port * 1000 + end_port) % 65536 ))
}

# burst速率突发计算
calculate_tc_burst() {
    local base_rate=$1
    local rate_bytes_per_sec=$((base_rate * 1000 / 8))
    local burst_by_formula=$((rate_bytes_per_sec / 20))  # 50ms缓冲
    local min_burst=$((2 * 1500))                        # 2个MTU最小�?

    if [ $burst_by_formula -gt $min_burst ]; then
        echo $burst_by_formula
    else
        echo $min_burst
    fi
}

format_tc_burst() {
    local burst_bytes=$1
    if [ $burst_bytes -lt 1024 ]; then
        echo "${burst_bytes}"
    elif [ $burst_bytes -lt 1048576 ]; then
        echo "$((burst_bytes / 1024))k"
    else
        echo "$((burst_bytes / 1048576))m"
    fi
}

parse_tc_rate_to_kbps() {
    local total_limit=$1
    if [[ "$total_limit" =~ gbit$ ]]; then
        local rate=$(echo "$total_limit" | sed 's/gbit$//')
        echo $((rate * 1000000))
    elif [[ "$total_limit" =~ mbit$ ]]; then
        local rate=$(echo "$total_limit" | sed 's/mbit$//')
        echo $((rate * 1000))
    else
        echo $(echo "$total_limit" | sed 's/kbit$//')
    fi
}

# 将用户输入的带宽�?Kbps/Mbps/Gbps)转换为TC格式(kbit/mbit/gbit)
convert_bandwidth_to_tc() {
    local rate="$1"
    local lower=$(echo "$rate" | tr '[:upper:]' '[:lower:]')
    if [[ "$lower" =~ kbps$ ]]; then
        echo "${lower/%kbps/kbit}"
    elif [[ "$lower" =~ mbps$ ]]; then
        echo "${lower/%mbps/mbit}"
    elif [[ "$lower" =~ gbps$ ]]; then
        echo "${lower/%gbps/gbit}"
    fi
}

generate_tc_class_id() {
    local port=$1
    if is_port_range "$port"; then
        # 端口段使�?x2000+标记避免与单端口冲突
        local mark_id=$(generate_port_range_mark "$port")
        echo "1:$(printf '%x' $((0x2000 + mark_id)))"
    else
        # 单端口使�?x1000+端口�?
        echo "1:$(printf '%x' $((0x1000 + port)))"
    fi
}

get_daily_total_traffic() {
    local total_bytes=0
    local ports=($(get_active_ports))
    for port in "${ports[@]}"; do
        local traffic_data=($(get_nftables_counter_data "$port"))
        local input_bytes=${traffic_data[0]}
        local output_bytes=${traffic_data[1]}
        local billing_mode=$(jq -r ".ports.\"$port\".billing_mode // \"double\"" "$CONFIG_FILE")
        local port_total=$(calculate_total_traffic "$input_bytes" "$output_bytes" "$billing_mode")
        total_bytes=$(( total_bytes + port_total ))
    done
    format_bytes $total_bytes
}

format_port_list() {
    local format_type="$1"
    local active_ports=($(get_active_ports))
    local result=""

    for port in "${active_ports[@]}"; do
        local traffic_data=($(get_nftables_counter_data "$port"))
        local input_bytes=${traffic_data[0]}
        local output_bytes=${traffic_data[1]}
        local billing_mode=$(jq -r ".ports.\"$port\".billing_mode // \"double\"" "$CONFIG_FILE")
        local total_bytes=$(calculate_total_traffic "$input_bytes" "$output_bytes" "$billing_mode")
        local total_formatted=$(format_bytes $total_bytes)
        local output_formatted=$(format_bytes $output_bytes)
        local status_label=$(get_port_status_label "$port")

        local input_formatted=$(format_bytes $input_bytes)


        if [ "$format_type" = "display" ]; then
            echo -e "端口:${GREEN}$port${NC} | 总流�?${GREEN}$total_formatted${NC} | 上行(入站): ${GREEN}$input_formatted${NC} | 下行(出站):${GREEN}$output_formatted${NC} | ${YELLOW}$status_label${NC}"
        elif [ "$format_type" = "markdown" ]; then
            result+="> 端口:**${port}** | 总流�?**${total_formatted}** | 上行:**${input_formatted}** | 下行:**${output_formatted}** | ${status_label}
"
        else
            result+="
端口:${port} | 总流�?${total_formatted} | 上行(入站): ${input_formatted} | 下行(出站):${output_formatted} | ${status_label}"
        fi
    done

    if [ "$format_type" = "message" ] || [ "$format_type" = "markdown" ]; then
        echo "$result"
    fi
}

# 显示主界�?
show_main_menu() {
    clear

    local active_ports=($(get_active_ports))
    local port_count=${#active_ports[@]}
    local daily_total=$(get_daily_total_traffic)

    echo -e "${BLUE}=== 端口流量�?v$SCRIPT_VERSION ===${NC}"
    echo -e "${GREEN}介绍主页:${NC}https://zywe.de | ${GREEN}项目开�?${NC}https://github.com/byby5555/realm-xwPF-active-standby"
    echo -e "${GREEN}一只轻巧的‘守护犬’，时刻守护你的端口流量 | 快捷命令: dog${NC}"
    echo

    echo -e "${GREEN}状�? 监控�?{NC} | ${BLUE}守护端口: ${port_count}�?{NC} | ${YELLOW}端口总流�? $daily_total${NC}"
    echo "────────────────────────────────────────────────────────"

    if [ $port_count -gt 0 ]; then
        format_port_list "display"
    else
        echo -e "${YELLOW}暂无监控端口${NC}"
    fi

    echo "────────────────────────────────────────────────────────"

    echo -e "${BLUE}1.${NC} 添加/删除端口监控     ${BLUE}2.${NC} 端口限制设置管理"
    echo -e "${BLUE}3.${NC} 流量重置管理          ${BLUE}4.${NC} 一键导�?导入配置"
    echo -e "${BLUE}5.${NC} 安装依赖(更新)脚本    ${BLUE}6.${NC} 卸载脚本"
    echo -e "${BLUE}7.${NC} 通知管理"
    echo -e "${BLUE}0.${NC} 退�?
    echo
    read -p "请选择操作 [0-7]: " choice

    case $choice in
        1) manage_port_monitoring ;;
        2) manage_traffic_limits ;;
        3) manage_traffic_reset ;;
        4) manage_configuration ;;
        5) install_update_script ;;
        6) uninstall_script ;;
        7) manage_notifications ;;
        0) exit 0 ;;
        *) echo -e "${RED}无效选择，请输入0-7${NC}"; sleep 1; show_main_menu ;;
    esac
}

manage_port_monitoring() {
    echo -e "${BLUE}=== 端口监控管理 ===${NC}"
    echo "1. 添加端口监控"
    echo "2. 删除端口监控"
    echo "0. 返回主菜�?
    echo
    read -p "请选择操作 [0-2]: " choice

    case $choice in
        1) add_port_monitoring ;;
        2) remove_port_monitoring ;;
        0) show_main_menu ;;
        *) echo -e "${RED}无效选择${NC}"; sleep 1; manage_port_monitoring ;;
    esac
}

add_port_monitoring() {
    echo -e "${BLUE}=== 添加端口监控 ===${NC}"
    echo

    echo -e "${GREEN}当前系统端口使用情况:${NC}"
    printf "%-15s %-9s\n" "程序�? "端口"
    echo "────────────────────────────────────────────────────────"

    # 解析ss输出，聚合同程序的端�?
    declare -A program_ports
    while read line; do
        if [[ "$line" =~ LISTEN|UNCONN ]]; then
            local_addr=$(echo "$line" | awk '{print $5}')
            port=$(echo "$local_addr" | grep -o ':[0-9]*$' | cut -d':' -f2)
            program=$(echo "$line" | awk '{print $7}' | cut -d'"' -f2 2>/dev/null || echo "")

            if [ -n "$port" ] && [ -n "$program" ] && [ "$program" != "-" ]; then
                if [ -z "${program_ports[$program]:-}" ]; then
                    program_ports[$program]="$port"
                else
                    # 避免重复端口
                    if [[ ! "${program_ports[$program]}" =~ (^|.*\|)$port(\||$) ]]; then
                        program_ports[$program]="${program_ports[$program]}|$port"
                    fi
                fi
            fi
        fi
    done < <(ss -tulnp 2>/dev/null || true)

    if [ ${#program_ports[@]} -gt 0 ]; then
        for program in $(printf '%s\n' "${!program_ports[@]}" | sort); do
            ports="${program_ports[$program]}"
            printf "%-10s | %-9s\n" "$program" "$ports"
        done
    else
        echo "无活跃端�?
    fi

    echo "────────────────────────────────────────────────────────"
    echo

    read -p "请输入要监控的端口号（多端口使用逗号,分隔,端口段使�?分隔�? " port_input

    local PORTS=()
    parse_port_range_input "$port_input" PORTS
    local valid_ports=()

    for port in "${PORTS[@]}"; do
        if jq -e ".ports.\"$port\"" "$CONFIG_FILE" >/dev/null 2>&1; then
            echo -e "${YELLOW}端口 $port 已在监控列表中，跳过${NC}"
            continue
        fi

        valid_ports+=("$port")
    done

    if [ ${#valid_ports[@]} -eq 0 ]; then
        echo -e "${RED}没有有效的端口可添加${NC}"
        sleep 2
        manage_port_monitoring
        return
    fi

    echo
    echo -e "${GREEN}说明:${NC}"
    echo "1. 双向流量统计"
    echo "   总流�?= in*2 + out*2"
    echo
    echo "2. 单向流量统计"
    echo "   仅统计出站流量，总流�?= out"
    echo
    echo "请选择统计模式:"
    echo "1. 双向流量统计"
    echo "2. 单向流量统计"
    read -p "请选择(回车默认1) [1-2]: " billing_choice

    local billing_mode="double"
    case $billing_choice in
        1|"") billing_mode="double" ;;
        2) billing_mode="single" ;;
        *) billing_mode="double" ;;
    esac

    echo
    local port_list=$(IFS=','; echo "${valid_ports[*]}")
    while true; do
        echo "为端�?$port_list 设置流量配额（总量控制�?"
        echo "请输入配额值（0为无限制）（要带单位MB/GB/T�?"
        echo "(多端口分别配额使用逗号,分隔)(只输入一个值，应用到所有端�?:"
        read -p "流量配额(回车默认0): " quota_input

        if [ -z "$quota_input" ]; then
            quota_input="0"
        fi

        local QUOTAS=()
        parse_comma_separated_input "$quota_input" QUOTAS

        local all_valid=true
        for quota in "${QUOTAS[@]}"; do
            if [ "$quota" != "0" ] && ! validate_quota "$quota"; then
                echo -e "${RED}配额格式错误: $quota，请使用如：100MB, 1GB, 2T${NC}"
                all_valid=false
                break
            fi
        done

        if [ "$all_valid" = false ]; then
            echo "请重新输入配额�?
            continue
        fi

        expand_single_value_to_array QUOTAS ${#valid_ports[@]}
        if [ ${#QUOTAS[@]} -ne ${#valid_ports[@]} ]; then
            echo -e "${RED}配额值数量与端口数量不匹�?{NC}"
            continue
        fi

        break
    done

    echo
    echo -e "${BLUE}=== 规则备注配置 ===${NC}"
    echo "请输入当前规则备�?可选，直接回车跳过):"
    echo "(多端口排序分别备注使用逗号,分隔)(只输入一个值，应用到所有端�?:"
    read -p "备注: " remark_input

    local REMARKS=()
    if [ -n "$remark_input" ]; then
        parse_comma_separated_input "$remark_input" REMARKS

        expand_single_value_to_array REMARKS ${#valid_ports[@]}
        if [ ${#REMARKS[@]} -ne ${#valid_ports[@]} ]; then
            echo -e "${RED}备注数量与端口数量不匹配${NC}"
            sleep 2
            add_port_monitoring
            return
        fi
    fi

    local added_count=0
    for i in "${!valid_ports[@]}"; do
        local port="${valid_ports[$i]}"
        local quota=$(echo "${QUOTAS[$i]}" | tr -d ' ')
        local remark=""
        if [ ${#REMARKS[@]} -gt $i ]; then
            remark=$(echo "${REMARKS[$i]}" | tr -d ' ')
        fi

        local quota_enabled="true"
        local monthly_limit="unlimited"

        if [ "$quota" != "0" ] && [ -n "$quota" ]; then
            monthly_limit="$quota"
        fi

        # 只有设置了流量限额时才添加reset_day字段（默认为1�?
        local quota_config
        if [ "$monthly_limit" != "unlimited" ]; then
            quota_config="{
                \"enabled\": $quota_enabled,
                \"monthly_limit\": \"$monthly_limit\",
                \"reset_day\": 1
            }"
        else
            quota_config="{
                \"enabled\": $quota_enabled,
                \"monthly_limit\": \"$monthly_limit\"
            }"
        fi

        local port_config="{
            \"name\": \"端口$port\",
            \"enabled\": true,
            \"billing_mode\": \"$billing_mode\",
            \"bandwidth_limit\": {
                \"enabled\": false,
                \"rate\": \"unlimited\"
            },
            \"quota\": $quota_config,
            \"remark\": \"$remark\",
            \"created_at\": \"$(get_beijing_time -Iseconds)\"
        }"

        update_config ".ports.\"$port\" = $port_config"
        add_nftables_rules "$port"

        if [ "$monthly_limit" != "unlimited" ]; then
            apply_nftables_quota "$port" "$quota"
        fi

        echo -e "${GREEN}端口 $port 监控添加成功${NC}"
        setup_port_auto_reset_cron "$port"
        added_count=$((added_count + 1))
    done

    echo
    echo -e "${GREEN}成功添加 $added_count 个端口监�?{NC}"

    sleep 2
    manage_port_monitoring
}

remove_port_monitoring() {
    echo -e "${BLUE}=== 删除端口监控 ===${NC}"
    echo

    local active_ports=($(get_active_ports))

    if ! show_port_list; then
        sleep 2
        manage_port_monitoring
        return
    fi
    echo

    read -p "请选择要删除的端口（多端口使用逗号,分隔�? " choice_input

    local valid_choices=()
    local ports_to_delete=()
    parse_multi_choice_input "$choice_input" "${#active_ports[@]}" valid_choices

    for choice in "${valid_choices[@]}"; do
        local port=${active_ports[$((choice-1))]}
        ports_to_delete+=("$port")
    done

    if [ ${#ports_to_delete[@]} -eq 0 ]; then
        echo -e "${RED}没有有效的端口可删除${NC}"
        sleep 2
        remove_port_monitoring
        return
    fi

    echo
    echo "将删除以下端口的监控:"
    for port in "${ports_to_delete[@]}"; do
        echo "  端口 $port"
    done
    echo

    read -p "确认删除这些端口的监�? [y/N]: " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        local deleted_count=0
        for port in "${ports_to_delete[@]}"; do
            remove_nftables_rules "$port"
            remove_nftables_quota "$port"
            remove_tc_limit "$port"
            update_config "del(.ports.\"$port\")"

            # 清理历史记录
            local history_file="$CONFIG_DIR/reset_history.log"
            if [ -f "$history_file" ]; then
                grep -v "|$port|" "$history_file" > "${history_file}.tmp" 2>/dev/null || true
                mv "${history_file}.tmp" "$history_file" 2>/dev/null || true
            fi

            local notification_log="$CONFIG_DIR/logs/notification.log"
            if [ -f "$notification_log" ]; then
                grep -v "端口 $port " "$notification_log" > "${notification_log}.tmp" 2>/dev/null || true
                mv "${notification_log}.tmp" "$notification_log" 2>/dev/null || true
            fi

            remove_port_auto_reset_cron "$port"

            echo -e "${GREEN}端口 $port 监控及相关数据删除成�?{NC}"
            deleted_count=$((deleted_count + 1))
        done

        echo
        echo -e "${GREEN}成功删除 $deleted_count 个端口监�?{NC}"

        # 清理连接跟踪：确保现有连接不受限�?
        echo "正在清理网络状�?.."
        for port in "${ports_to_delete[@]}"; do
            if is_port_range "$port"; then
                local start_port=$(echo "$port" | cut -d'-' -f1)
                local end_port=$(echo "$port" | cut -d'-' -f2)
                echo "清理端口�?$port 连接状�?.."
                for ((p=start_port; p<=end_port; p++)); do
                    conntrack -D -p tcp --dport $p 2>/dev/null || true
                    conntrack -D -p udp --dport $p 2>/dev/null || true
                done
            else
                echo "清理端口 $port 连接状�?.."
                conntrack -D -p tcp --dport $port 2>/dev/null || true
                conntrack -D -p udp --dport $port 2>/dev/null || true
            fi
        done

        echo -e "${GREEN}网络状态已清理，现有连接的限制应该已解�?{NC}"
        echo -e "${YELLOW}提示：新建连接将不受任何限制${NC}"

        local remaining_ports=($(get_active_ports))
        if [ ${#remaining_ports[@]} -eq 0 ]; then
            echo -e "${YELLOW}所有端口已删除，自动重置功能已停用${NC}"
        fi
    else
        echo "取消删除"
    fi

    sleep 2
    manage_port_monitoring
}

add_nftables_rules() {
    local port=$1
    local table_name=$(jq -r '.nftables.table_name' "$CONFIG_FILE")
    local family=$(jq -r '.nftables.family' "$CONFIG_FILE")
    local billing_mode=$(jq -r ".ports.\"$port\".billing_mode // \"double\"" "$CONFIG_FILE")

    if is_port_range "$port"; then
        local port_safe=$(echo "$port" | tr '-' '_')
        local mark_id=$(generate_port_range_mark "$port")

        if [ "$billing_mode" = "double" ]; then
            # 双向模式：创�?in �?out 两个计数器，各绑定规则两次（×2�?
            nft list counter $family $table_name "port_${port_safe}_in" >/dev/null 2>&1 || \
                nft add counter $family $table_name "port_${port_safe}_in" 2>/dev/null || true
            nft list counter $family $table_name "port_${port_safe}_out" >/dev/null 2>&1 || \
                nft add counter $family $table_name "port_${port_safe}_out" 2>/dev/null || true

            # in 计数器：绑定 input 规则两次（in × 2�?
            nft add rule $family $table_name input tcp dport $port meta mark set $mark_id counter name "port_${port_safe}_in"
            nft add rule $family $table_name input udp dport $port meta mark set $mark_id counter name "port_${port_safe}_in"
            nft add rule $family $table_name forward tcp dport $port meta mark set $mark_id counter name "port_${port_safe}_in"
            nft add rule $family $table_name forward udp dport $port meta mark set $mark_id counter name "port_${port_safe}_in"
            nft add rule $family $table_name input tcp dport $port meta mark set $mark_id counter name "port_${port_safe}_in"
            nft add rule $family $table_name input udp dport $port meta mark set $mark_id counter name "port_${port_safe}_in"
            nft add rule $family $table_name forward tcp dport $port meta mark set $mark_id counter name "port_${port_safe}_in"
            nft add rule $family $table_name forward udp dport $port meta mark set $mark_id counter name "port_${port_safe}_in"

            # out 计数器：绑定 output 规则两次（out × 2�?
            nft add rule $family $table_name output tcp sport $port meta mark set $mark_id counter name "port_${port_safe}_out"
            nft add rule $family $table_name output udp sport $port meta mark set $mark_id counter name "port_${port_safe}_out"
            nft add rule $family $table_name forward tcp sport $port meta mark set $mark_id counter name "port_${port_safe}_out"
            nft add rule $family $table_name forward udp sport $port meta mark set $mark_id counter name "port_${port_safe}_out"
            nft add rule $family $table_name output tcp sport $port meta mark set $mark_id counter name "port_${port_safe}_out"
            nft add rule $family $table_name output udp sport $port meta mark set $mark_id counter name "port_${port_safe}_out"
            nft add rule $family $table_name forward tcp sport $port meta mark set $mark_id counter name "port_${port_safe}_out"
            nft add rule $family $table_name forward udp sport $port meta mark set $mark_id counter name "port_${port_safe}_out"
        else
            # 单向模式：只创建 out 计数器，绑定 output 规则一次（out × 1�?
            nft list counter $family $table_name "port_${port_safe}_out" >/dev/null 2>&1 || \
                nft add counter $family $table_name "port_${port_safe}_out" 2>/dev/null || true

            nft add rule $family $table_name output tcp sport $port meta mark set $mark_id counter name "port_${port_safe}_out"
            nft add rule $family $table_name output udp sport $port meta mark set $mark_id counter name "port_${port_safe}_out"
            nft add rule $family $table_name forward tcp sport $port meta mark set $mark_id counter name "port_${port_safe}_out"
            nft add rule $family $table_name forward udp sport $port meta mark set $mark_id counter name "port_${port_safe}_out"
        fi
    else
        if [ "$billing_mode" = "double" ]; then
            # 双向模式：创�?in �?out 两个计数�?
            nft list counter $family $table_name "port_${port}_in" >/dev/null 2>&1 || \
                nft add counter $family $table_name "port_${port}_in" 2>/dev/null || true
            nft list counter $family $table_name "port_${port}_out" >/dev/null 2>&1 || \
                nft add counter $family $table_name "port_${port}_out" 2>/dev/null || true

            # in 计数器：绑定 input 规则两次（in × 2�?
            nft add rule $family $table_name input tcp dport $port counter name "port_${port}_in"
            nft add rule $family $table_name input udp dport $port counter name "port_${port}_in"
            nft add rule $family $table_name forward tcp dport $port counter name "port_${port}_in"
            nft add rule $family $table_name forward udp dport $port counter name "port_${port}_in"
            nft add rule $family $table_name input tcp dport $port counter name "port_${port}_in"
            nft add rule $family $table_name input udp dport $port counter name "port_${port}_in"
            nft add rule $family $table_name forward tcp dport $port counter name "port_${port}_in"
            nft add rule $family $table_name forward udp dport $port counter name "port_${port}_in"

            # out 计数器：绑定 output 规则两次（out × 2�?
            nft add rule $family $table_name output tcp sport $port counter name "port_${port}_out"
            nft add rule $family $table_name output udp sport $port counter name "port_${port}_out"
            nft add rule $family $table_name forward tcp sport $port counter name "port_${port}_out"
            nft add rule $family $table_name forward udp sport $port counter name "port_${port}_out"
            nft add rule $family $table_name output tcp sport $port counter name "port_${port}_out"
            nft add rule $family $table_name output udp sport $port counter name "port_${port}_out"
            nft add rule $family $table_name forward tcp sport $port counter name "port_${port}_out"
            nft add rule $family $table_name forward udp sport $port counter name "port_${port}_out"
        else
            # 单向模式：只创建 out 计数器，绑定 output 规则一次（out × 1�?
            nft list counter $family $table_name "port_${port}_out" >/dev/null 2>&1 || \
                nft add counter $family $table_name "port_${port}_out" 2>/dev/null || true

            nft add rule $family $table_name output tcp sport $port counter name "port_${port}_out"
            nft add rule $family $table_name output udp sport $port counter name "port_${port}_out"
            nft add rule $family $table_name forward tcp sport $port counter name "port_${port}_out"
            nft add rule $family $table_name forward udp sport $port counter name "port_${port}_out"
        fi
    fi
}

remove_nftables_rules() {
    local port=$1
    local table_name=$(jq -r '.nftables.table_name' "$CONFIG_FILE")
    local family=$(jq -r '.nftables.family' "$CONFIG_FILE")

    if is_port_range "$port"; then
        local port_safe=$(echo "$port" | tr '-' '_')
        local search_pattern="port_${port_safe}_"
    else
        local search_pattern="port_${port}_"
    fi

    # 使用handle删除法：逐个删除匹配的规�?
    local deleted_count=0
    while true; do
        local handle=$(nft -a list table $family $table_name 2>/dev/null | \
            grep -E "(tcp|udp).*(dport|sport).*$search_pattern" | \
            head -n1 | \
            sed -n 's/.*# handle \([0-9]\+\)$/\1/p')

        if [ -z "$handle" ]; then
            break
        fi

        for chain in input output forward; do
            if nft delete rule $family $table_name $chain handle $handle 2>/dev/null; then
                deleted_count=$((deleted_count + 1))
                break
            fi
        done

        if [ $deleted_count -ge 150 ]; then
            break
        fi
    done

    # 删除计数�?
    if is_port_range "$port"; then
        local port_safe=$(echo "$port" | tr '-' '_')
        nft delete counter $family $table_name "port_${port_safe}_in" 2>/dev/null || true
        nft delete counter $family $table_name "port_${port_safe}_out" 2>/dev/null || true
    else
        nft delete counter $family $table_name "port_${port}_in" 2>/dev/null || true
        nft delete counter $family $table_name "port_${port}_out" 2>/dev/null || true
    fi
}

set_port_bandwidth_limit() {
    echo -e "${BLUE}设置端口带宽限制${NC}"
    echo

    local active_ports=($(get_active_ports))

    if ! show_port_list; then
        sleep 2
        manage_traffic_limits
        return
    fi
    echo

    read -p "请选择要限制的端口（多端口使用逗号,分隔�?[1-${#active_ports[@]}]: " choice_input

    local valid_choices=()
    local ports_to_limit=()
    parse_multi_choice_input "$choice_input" "${#active_ports[@]}" valid_choices

    for choice in "${valid_choices[@]}"; do
        local port=${active_ports[$((choice-1))]}
        ports_to_limit+=("$port")
    done

    if [ ${#ports_to_limit[@]} -eq 0 ]; then
        echo -e "${RED}没有有效的端口可设置限制${NC}"
        sleep 2
        set_port_bandwidth_limit
        return
    fi

    echo
    local port_list=$(IFS=','; echo "${ports_to_limit[*]}")
    echo "为端�?$port_list 设置带宽限制（速率控制�?"
    echo "请输入限制值（0为无限制）（要带单位Kbps/Mbps/Gbps�?"
    echo "(多端口排序分别限制使用逗号,分隔)(只输入一个值，应用到所有端�?:"
    read -p "带宽限制: " limit_input

    local LIMITS=()
    parse_comma_separated_input "$limit_input" LIMITS

    expand_single_value_to_array LIMITS ${#ports_to_limit[@]}
    if [ ${#LIMITS[@]} -ne ${#ports_to_limit[@]} ]; then
        echo -e "${RED}限制值数量与端口数量不匹�?{NC}"
        sleep 2
        set_port_bandwidth_limit
        return
    fi

    local success_count=0
    for i in "${!ports_to_limit[@]}"; do
        local port="${ports_to_limit[$i]}"
        local limit=$(echo "${LIMITS[$i]}" | tr -d ' ')

        if [ "$limit" = "0" ] || [ -z "$limit" ]; then
            remove_tc_limit "$port"
            update_config ".ports.\"$port\".bandwidth_limit.enabled = false |
                .ports.\"$port\".bandwidth_limit.rate = \"unlimited\""
            echo -e "${GREEN}端口 $port 带宽限制已移�?{NC}"
            success_count=$((success_count + 1))
            continue
        fi

        remove_tc_limit "$port"

        if ! validate_bandwidth "$limit"; then
            echo -e "${RED}端口 $port 格式错误，请使用如：500Kbps, 100Mbps, 1Gbps${NC}"
            continue
        fi

        # 转换为TC格式
        local tc_limit=$(convert_bandwidth_to_tc "$limit")

        apply_tc_limit "$port" "$tc_limit"

        update_config ".ports.\"$port\".bandwidth_limit.enabled = true |
            .ports.\"$port\".bandwidth_limit.rate = \"$limit\""

        echo -e "${GREEN}端口 $port 带宽限制设置成功: $limit${NC}"
        success_count=$((success_count + 1))
    done

    echo
    echo -e "${GREEN}成功设置 $success_count 个端口的带宽限制${NC}"
    sleep 3
    manage_traffic_limits
}

set_port_quota_limit() {
    echo -e "${BLUE}=== 设置端口流量配额 ===${NC}"
    echo

    local active_ports=($(get_active_ports))
    if ! show_port_list; then
        sleep 2
        manage_traffic_limits
        return
    fi
    echo

    read -p "请选择要设置配额的端口（多端口使用逗号,分隔�?[1-${#active_ports[@]}]: " choice_input

    local valid_choices=()
    local ports_to_quota=()
    parse_multi_choice_input "$choice_input" "${#active_ports[@]}" valid_choices

    for choice in "${valid_choices[@]}"; do
        local port=${active_ports[$((choice-1))]}
        ports_to_quota+=("$port")
    done

    if [ ${#ports_to_quota[@]} -eq 0 ]; then
        echo -e "${RED}没有有效的端口可设置配额${NC}"
        sleep 2
        set_port_quota_limit
        return
    fi

    echo
    local port_list=$(IFS=','; echo "${ports_to_quota[*]}")
    while true; do
        echo "为端�?$port_list 设置流量配额（总量控制�?"
        echo "请输入配额值（0为无限制）（要带单位MB/GB/T�?"
        echo "(多端口分别配额使用逗号,分隔)(只输入一个值，应用到所有端�?:"
        read -p "流量配额(回车默认0): " quota_input

        if [ -z "$quota_input" ]; then
            quota_input="0"
        fi

        local QUOTAS=()
        parse_comma_separated_input "$quota_input" QUOTAS

        local all_valid=true
        for quota in "${QUOTAS[@]}"; do
            if [ "$quota" != "0" ] && ! validate_quota "$quota"; then
                echo -e "${RED}配额格式错误: $quota，请使用如：100MB, 1GB, 2T${NC}"
                all_valid=false
                break
            fi
        done

        if [ "$all_valid" = false ]; then
            echo "请重新输入配额�?
            continue
        fi

        expand_single_value_to_array QUOTAS ${#ports_to_quota[@]}
        if [ ${#QUOTAS[@]} -ne ${#ports_to_quota[@]} ]; then
            echo -e "${RED}配额值数量与端口数量不匹�?{NC}"
            continue
        fi

        break
    done

    local success_count=0
    for i in "${!ports_to_quota[@]}"; do
        local port="${ports_to_quota[$i]}"
        local quota=$(echo "${QUOTAS[$i]}" | tr -d ' ')

        if [ "$quota" = "0" ] || [ -z "$quota" ]; then
            remove_nftables_quota "$port"
            # 设为无限额时删除reset_day字段并清除定时任�?
            jq ".ports.\"$port\".quota.enabled = true | 
                .ports.\"$port\".quota.monthly_limit = \"unlimited\" | 
                del(.ports.\"$port\".quota.reset_day)" "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
            remove_port_auto_reset_cron "$port"
            echo -e "${GREEN}端口 $port 流量配额设置为无限制${NC}"
            success_count=$((success_count + 1))
            continue
        fi

        remove_nftables_quota "$port"
        apply_nftables_quota "$port" "$quota"

        # 获取当前配额限制状�?
        local current_monthly_limit=$(jq -r ".ports.\"$port\".quota.monthly_limit // \"unlimited\"" "$CONFIG_FILE")
        
        # 从无限额改为有限额时默认添加reset_day=1
        if [ "$current_monthly_limit" = "unlimited" ]; then
            # 原来是无限额，现在设置为有限额，添加默认reset_day=1
            update_config ".ports.\"$port\".quota.enabled = true |
                .ports.\"$port\".quota.monthly_limit = \"$quota\" |
                .ports.\"$port\".quota.reset_day = 1"
        else
            # 原来就是有限额，只修改配额值，保持reset_day不变
            update_config ".ports.\"$port\".quota.enabled = true |
                .ports.\"$port\".quota.monthly_limit = \"$quota\""
        fi
        
        setup_port_auto_reset_cron "$port"
        echo -e "${GREEN}端口 $port 流量配额设置成功: $quota${NC}"
        success_count=$((success_count + 1))
    done

    echo
    echo -e "${GREEN}成功设置 $success_count 个端口的流量配额${NC}"
    sleep 3
    manage_traffic_limits
}

manage_traffic_limits() {
    echo -e "${BLUE}=== 端口限制设置管理 ===${NC}"
    echo "1. 设置端口带宽限制（速率控制�?
    echo "2. 设置端口流量配额（总量控制�?
    echo "3. 修改端口统计方式（双�?单向�?
    echo "0. 返回主菜�?
    echo
    read -p "请选择操作 [0-3]: " choice

    case $choice in
        1) set_port_bandwidth_limit ;;
        2) set_port_quota_limit ;;
        3) change_port_billing_mode ;;
        0) show_main_menu ;;
        *) echo -e "${RED}无效选择${NC}"; sleep 1; manage_traffic_limits ;;
    esac
}

# 修改端口计费模式（流量数据不丢失�?
change_port_billing_mode() {
    echo -e "${BLUE}=== 修改端口统计方式 ===${NC}"
    
    local active_ports=$(jq -r '.ports | keys[]' "$CONFIG_FILE" 2>/dev/null | sort -n)
    if [ -z "$active_ports" ]; then
        echo -e "${RED}没有正在监控的端�?{NC}"
        sleep 2
        manage_traffic_limits
        return
    fi
    
    echo -e "${YELLOW}当前监控的端口列表：${NC}"
    local port_list=()
    local idx=1
    for port in $active_ports; do
        local current_mode=$(jq -r ".ports.\"$port\".billing_mode // \"double\"" "$CONFIG_FILE")
        local mode_display=$([ "$current_mode" = "double" ] && echo "双向" || echo "单向")
        echo -e "  $idx. 端口 $port - 当前模式: ${BLUE}${mode_display}${NC}"
        port_list+=("$port")
        ((idx++))
    done
    echo "  0. 返回上级菜单"
    echo
    
    read -p "请选择要修改的端口 [0-$((idx-1))]: " port_choice
    
    if [ "$port_choice" = "0" ]; then
        manage_traffic_limits
        return
    fi
    
    if ! [[ "$port_choice" =~ ^[0-9]+$ ]] || [ "$port_choice" -lt 1 ] || [ "$port_choice" -gt ${#port_list[@]} ]; then
        echo -e "${RED}无效选择${NC}"
        sleep 1
        change_port_billing_mode
        return
    fi
    
    local target_port="${port_list[$((port_choice-1))]}"
    local current_mode=$(jq -r ".ports.\"$target_port\".billing_mode // \"double\"" "$CONFIG_FILE")
    local current_display=$([ "$current_mode" = "double" ] && echo "双向" || echo "单向")
    
    echo
    echo -e "端口 $target_port 当前统计方式: ${BLUE}$current_display${NC}"
    echo
    echo "1. 双向流量统计"
    echo "2. 单向流量统计"
    echo "0. 取消"
    echo
    read -p "请选择统计模式 [0-2]: " mode_choice
    
    local new_mode=""
    case $mode_choice in
        1) new_mode="double" ;;
        2) new_mode="single" ;;
        0|"") change_port_billing_mode; return ;;
        *) echo -e "${RED}无效选择${NC}"; sleep 1; change_port_billing_mode; return ;;
    esac
    
    local new_display=$([ "$new_mode" = "double" ] && echo "双向" || echo "单向")
    
    echo
    echo -e "${YELLOW}正在应用 $new_display 模式...${NC}"
    
    # 读取当前流量
    local traffic_data=($(get_nftables_counter_data "$target_port"))
    local saved_input=${traffic_data[0]:-0}
    local saved_output=${traffic_data[1]:-0}
    echo -e "  读取流量: 上行=$(format_bytes $saved_input), 下行=$(format_bytes $saved_output)"
    
    # 删除旧规�?
    remove_nftables_rules "$target_port"
    
    # 更新配置
    local tmp_file=$(mktemp)
    jq ".ports.\"$target_port\".billing_mode = \"$new_mode\"" "$CONFIG_FILE" > "$tmp_file"
    mv "$tmp_file" "$CONFIG_FILE"
    
    # 创建带初始值的计数器（复用灾备恢复函数�?
    restore_counter_value "$target_port" "$saved_input" "$saved_output"
    
    # 添加规则（计数器已存在，会被复用�?
    add_nftables_rules "$target_port"
    
    # 重新应用配额（apply_nftables_quota 会先删除旧配额对象再创建新的�?
    local quota_enabled=$(jq -r ".ports.\"$target_port\".quota.enabled // false" "$CONFIG_FILE")
    local quota_limit=$(jq -r ".ports.\"$target_port\".quota.monthly_limit // \"\"" "$CONFIG_FILE")
    if [ "$quota_enabled" = "true" ] && [ -n "$quota_limit" ] && [ "$quota_limit" != "null" ] && [ "$quota_limit" != "unlimited" ]; then
        apply_nftables_quota "$target_port" "$quota_limit"
    fi
    
    echo -e "${GREEN}�?已应�?$new_display 模式，流量数据已保留${NC}"
    sleep 2
    
    change_port_billing_mode
}

apply_nftables_quota() {
    local port=$1
    local quota_limit=$2
    local table_name=$(jq -r '.nftables.table_name' "$CONFIG_FILE")
    local family=$(jq -r '.nftables.family' "$CONFIG_FILE")
    local billing_mode=$(jq -r ".ports.\"$port\".billing_mode // \"double\"" "$CONFIG_FILE")

    local quota_bytes=$(parse_size_to_bytes "$quota_limit")

    # 使用当前流量作为配额初始值，避免重置后立即触发限�?
    local current_traffic=($(get_nftables_counter_data "$port"))
    local current_input=${current_traffic[0]}
    local current_output=${current_traffic[1]}
    local current_total=$(calculate_total_traffic "$current_input" "$current_output" "$billing_mode")

    if is_port_range "$port"; then
        local port_safe=$(echo "$port" | tr '-' '_')
        local quota_name="port_${port_safe}_quota"

        # 确保幂等：先删除现有配额对象（如果存在）
        nft delete quota $family $table_name $quota_name 2>/dev/null || true
        nft add quota $family $table_name $quota_name { over $quota_bytes bytes used $current_total bytes } 2>/dev/null || true

        if [ "$billing_mode" = "double" ]; then
            # 双向模式：配额规则与计数器一致，input×2 + output×2
            # input×2
            nft insert rule $family $table_name input tcp dport $port quota name "$quota_name" drop 2>/dev/null || true
            nft insert rule $family $table_name input udp dport $port quota name "$quota_name" drop 2>/dev/null || true
            nft insert rule $family $table_name forward tcp dport $port quota name "$quota_name" drop 2>/dev/null || true
            nft insert rule $family $table_name forward udp dport $port quota name "$quota_name" drop 2>/dev/null || true
            nft insert rule $family $table_name input tcp dport $port quota name "$quota_name" drop 2>/dev/null || true
            nft insert rule $family $table_name input udp dport $port quota name "$quota_name" drop 2>/dev/null || true
            nft insert rule $family $table_name forward tcp dport $port quota name "$quota_name" drop 2>/dev/null || true
            nft insert rule $family $table_name forward udp dport $port quota name "$quota_name" drop 2>/dev/null || true
            # output×2
            nft insert rule $family $table_name output tcp sport $port quota name "$quota_name" drop 2>/dev/null || true
            nft insert rule $family $table_name output udp sport $port quota name "$quota_name" drop 2>/dev/null || true
            nft insert rule $family $table_name forward tcp sport $port quota name "$quota_name" drop 2>/dev/null || true
            nft insert rule $family $table_name forward udp sport $port quota name "$quota_name" drop 2>/dev/null || true
            nft insert rule $family $table_name output tcp sport $port quota name "$quota_name" drop 2>/dev/null || true
            nft insert rule $family $table_name output udp sport $port quota name "$quota_name" drop 2>/dev/null || true
            nft insert rule $family $table_name forward tcp sport $port quota name "$quota_name" drop 2>/dev/null || true
            nft insert rule $family $table_name forward udp sport $port quota name "$quota_name" drop 2>/dev/null || true
        else
            # 单向模式：只绑定 output×1
            nft insert rule $family $table_name output tcp sport $port quota name "$quota_name" drop 2>/dev/null || true
            nft insert rule $family $table_name output udp sport $port quota name "$quota_name" drop 2>/dev/null || true
            nft insert rule $family $table_name forward tcp sport $port quota name "$quota_name" drop 2>/dev/null || true
            nft insert rule $family $table_name forward udp sport $port quota name "$quota_name" drop 2>/dev/null || true
        fi
    else
        local quota_name="port_${port}_quota"

        # 确保幂等：先删除现有配额对象（如果存在）
        nft delete quota $family $table_name $quota_name 2>/dev/null || true
        nft add quota $family $table_name $quota_name { over $quota_bytes bytes used $current_total bytes } 2>/dev/null || true

        if [ "$billing_mode" = "double" ]; then
            # 双向模式：配额规则与计数器一致，input×2 + output×2
            # input×2
            nft insert rule $family $table_name input tcp dport $port quota name "$quota_name" drop 2>/dev/null || true
            nft insert rule $family $table_name input udp dport $port quota name "$quota_name" drop 2>/dev/null || true
            nft insert rule $family $table_name forward tcp dport $port quota name "$quota_name" drop 2>/dev/null || true
            nft insert rule $family $table_name forward udp dport $port quota name "$quota_name" drop 2>/dev/null || true
            nft insert rule $family $table_name input tcp dport $port quota name "$quota_name" drop 2>/dev/null || true
            nft insert rule $family $table_name input udp dport $port quota name "$quota_name" drop 2>/dev/null || true
            nft insert rule $family $table_name forward tcp dport $port quota name "$quota_name" drop 2>/dev/null || true
            nft insert rule $family $table_name forward udp dport $port quota name "$quota_name" drop 2>/dev/null || true
            # output×2
            nft insert rule $family $table_name output tcp sport $port quota name "$quota_name" drop 2>/dev/null || true
            nft insert rule $family $table_name output udp sport $port quota name "$quota_name" drop 2>/dev/null || true
            nft insert rule $family $table_name forward tcp sport $port quota name "$quota_name" drop 2>/dev/null || true
            nft insert rule $family $table_name forward udp sport $port quota name "$quota_name" drop 2>/dev/null || true
            nft insert rule $family $table_name output tcp sport $port quota name "$quota_name" drop 2>/dev/null || true
            nft insert rule $family $table_name output udp sport $port quota name "$quota_name" drop 2>/dev/null || true
            nft insert rule $family $table_name forward tcp sport $port quota name "$quota_name" drop 2>/dev/null || true
            nft insert rule $family $table_name forward udp sport $port quota name "$quota_name" drop 2>/dev/null || true
        else
            # 单向模式：只绑定 output×1
            nft insert rule $family $table_name output tcp sport $port quota name "$quota_name" drop 2>/dev/null || true
            nft insert rule $family $table_name output udp sport $port quota name "$quota_name" drop 2>/dev/null || true
            nft insert rule $family $table_name forward tcp sport $port quota name "$quota_name" drop 2>/dev/null || true
            nft insert rule $family $table_name forward udp sport $port quota name "$quota_name" drop 2>/dev/null || true
        fi
    fi
}

# 删除nftables配额限制 - 使用handle删除�?
remove_nftables_quota() {
    local port=$1
    local table_name=$(jq -r '.nftables.table_name' "$CONFIG_FILE")
    local family=$(jq -r '.nftables.family' "$CONFIG_FILE")

    # 检查是否为端口�?
    if is_port_range "$port"; then
        local port_safe=$(echo "$port" | tr '-' '_')
        local quota_name="port_${port_safe}_quota"
    else
        local quota_name="port_${port}_quota"
    fi

    # 循环删除所有包含配额名称的规则 - 每次只获取一个handle
    local deleted_count=0
    while true; do
        # 每次只获取第一个匹配的配额规则handle
        local handle=$(nft -a list table $family $table_name 2>/dev/null | \
            grep "quota name \"$quota_name\"" | \
            head -n1 | \
            sed -n 's/.*# handle \([0-9]\+\)$/\1/p')

        if [ -z "$handle" ]; then
            break
        fi

        for chain in input output forward; do
            if nft delete rule $family $table_name $chain handle $handle 2>/dev/null; then
                deleted_count=$((deleted_count + 1))
                break
            fi
        done

        if [ $deleted_count -ge 150 ]; then
            break
        fi
    done

    nft delete quota $family $table_name "$quota_name" 2>/dev/null || true
}

apply_tc_limit() {
    local port=$1
    local total_limit=$2
    local interface=$(get_default_interface)

    tc qdisc add dev $interface root handle 1: htb default 30 2>/dev/null || true
    tc class add dev $interface parent 1: classid 1:1 htb rate 1000mbit 2>/dev/null || true

    local class_id=$(generate_tc_class_id "$port")
    tc class del dev $interface classid $class_id 2>/dev/null || true

    # 计算burst参数以优化性能
    local base_rate=$(parse_tc_rate_to_kbps "$total_limit")
    local burst_bytes=$(calculate_tc_burst "$base_rate")
    local burst_size=$(format_tc_burst "$burst_bytes")

    tc class add dev $interface parent 1:1 classid $class_id htb rate $total_limit ceil $total_limit burst $burst_size

    if is_port_range "$port"; then
        # 端口段：使用fw分类器根据标记分�?
        local mark_id=$(generate_port_range_mark "$port")
        tc filter add dev $interface protocol ip parent 1:0 prio 1 handle $mark_id fw flowid $class_id 2>/dev/null || true

    else
        # 单端口：使用u32精确匹配，避免优先级冲突
        local filter_prio=$((port % 1000 + 1))

        # TCP协议过滤�?
        tc filter add dev $interface protocol ip parent 1:0 prio $filter_prio u32 \
            match ip protocol 6 0xff match ip sport $port 0xffff flowid $class_id 2>/dev/null || true
        tc filter add dev $interface protocol ip parent 1:0 prio $filter_prio u32 \
            match ip protocol 6 0xff match ip dport $port 0xffff flowid $class_id 2>/dev/null || true

        # UDP协议过滤�?
        tc filter add dev $interface protocol ip parent 1:0 prio $((filter_prio + 1000)) u32 \
            match ip protocol 17 0xff match ip sport $port 0xffff flowid $class_id 2>/dev/null || true
        tc filter add dev $interface protocol ip parent 1:0 prio $((filter_prio + 1000)) u32 \
            match ip protocol 17 0xff match ip dport $port 0xffff flowid $class_id 2>/dev/null || true
    fi
}

# 删除TC带宽限制
remove_tc_limit() {
    local port=$1
    local interface=$(get_default_interface)

    local class_id=$(generate_tc_class_id "$port")

    if is_port_range "$port"; then
        # 端口段：删除基于标记的过滤器
        local mark_id=$(generate_port_range_mark "$port")
        local mark_hex=$(printf '0x%x' "$mark_id")
        
        # 十六进制handle删除
        tc filter del dev $interface protocol ip parent 1:0 prio 1 handle $mark_hex fw 2>/dev/null || true
        # 备选：十进制handle删除
        tc filter del dev $interface protocol ip parent 1:0 prio 1 handle $mark_id fw 2>/dev/null || true
    else
        # 单端口：删除u32精确匹配过滤�?
        local filter_prio=$((port % 1000 + 1))

        tc filter del dev $interface protocol ip parent 1:0 prio $filter_prio u32 \
            match ip protocol 6 0xff match ip sport $port 0xffff 2>/dev/null || true
        tc filter del dev $interface protocol ip parent 1:0 prio $filter_prio u32 \
            match ip protocol 6 0xff match ip dport $port 0xffff 2>/dev/null || true

        tc filter del dev $interface protocol ip parent 1:0 prio $((filter_prio + 1000)) u32 \
            match ip protocol 17 0xff match ip sport $port 0xffff 2>/dev/null || true
        tc filter del dev $interface protocol ip parent 1:0 prio $((filter_prio + 1000)) u32 \
            match ip protocol 17 0xff match ip dport $port 0xffff 2>/dev/null || true
    fi

    tc class del dev $interface classid $class_id 2>/dev/null || true
}

manage_traffic_reset() {
    echo -e "${BLUE}流量重置管理${NC}"
    echo "1. 重置流量月重置日设置"
    echo "2. 立即重置"
    echo "0. 返回主菜�?
    echo
    read -p "请选择操作 [0-2]: " choice

    case $choice in
        1) set_reset_day ;;
        2) immediate_reset ;;
        0) show_main_menu ;;
        *) echo -e "${RED}无效选择，请输入0-2${NC}"; sleep 1; manage_traffic_reset ;;
    esac
}

set_reset_day() {
    echo -e "${BLUE}=== 重置流量月重置日设置 ===${NC}"
    echo

    local active_ports=($(get_active_ports))

    if ! show_port_list; then
        sleep 2
        manage_traffic_reset
        return
    fi
    echo

    read -p "请选择要设置重置日期的端口（多端口使用逗号,分隔�?[1-${#active_ports[@]}]: " choice_input

    local valid_choices=()
    local ports_to_set=()
    parse_multi_choice_input "$choice_input" "${#active_ports[@]}" valid_choices

    for choice in "${valid_choices[@]}"; do
        local port=${active_ports[$((choice-1))]}
        ports_to_set+=("$port")
    done

    if [ ${#ports_to_set[@]} -eq 0 ]; then
        echo -e "${RED}没有有效的端口可设置${NC}"
        sleep 2
        set_reset_day
        return
    fi

    echo
    local port_list=$(IFS=','; echo "${ports_to_set[*]}")
    echo "为端�?$port_list 设置月重置日�?"
    echo "请输入月重置日（多端口使用逗号,分隔�?0代表不重�?:"
    echo "(只输入一个值，应用到所有端�?:"
    read -p "月重置日 [0-31]: " reset_day_input

    local RESET_DAYS=()
    parse_comma_separated_input "$reset_day_input" RESET_DAYS

    expand_single_value_to_array RESET_DAYS ${#ports_to_set[@]}
    if [ ${#RESET_DAYS[@]} -ne ${#ports_to_set[@]} ]; then
        echo -e "${RED}重置日期数量与端口数量不匹配${NC}"
        sleep 2
        set_reset_day
        return
    fi

    local success_count=0
    for i in "${!ports_to_set[@]}"; do
        local port="${ports_to_set[$i]}"
        local reset_day=$(echo "${RESET_DAYS[$i]}" | tr -d ' ')

        if ! [[ "$reset_day" =~ ^[0-9]+$ ]] || [ "$reset_day" -lt 0 ] || [ "$reset_day" -gt 31 ]; then
            echo -e "${RED}端口 $port 重置日期无效: $reset_day，必须是0-31之间的数�?{NC}"
            continue
        fi

        if [ "$reset_day" = "0" ]; then
            # 删除reset_day字段并移除定时任�?
            jq "del(.ports.\"$port\".quota.reset_day)" "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
            remove_port_auto_reset_cron "$port"
            echo -e "${GREEN}端口 $port 已取消自动重�?{NC}"
        else
            # 无流量配额的端口不需要自动重�?
            local monthly_limit=$(jq -r ".ports.\"$port\".quota.monthly_limit // \"unlimited\"" "$CONFIG_FILE")
            if [ "$monthly_limit" = "unlimited" ]; then
                echo -e "${YELLOW}端口 $port 未设置流量配额，请先通过「端口限制设置管理→设置端口流量配额」设置配额后再设置重置日${NC}"
                continue
            fi
            update_config ".ports.\"$port\".quota.reset_day = $reset_day"
            setup_port_auto_reset_cron "$port"
            echo -e "${GREEN}端口 $port 月重置日设置成功: 每月${reset_day}�?{NC}"
        fi
        
        success_count=$((success_count + 1))
    done

    echo
    echo -e "${GREEN}成功设置 $success_count 个端口的月重置日�?{NC}"

    sleep 2
    manage_traffic_reset
}

immediate_reset() {
    echo -e "${BLUE}=== 立即重置 ===${NC}"
    echo

    local active_ports=($(get_active_ports))

    if ! show_port_list; then
        sleep 2
        manage_traffic_reset
        return
    fi
    echo

    read -p "请选择要立即重置的端口（多端口使用逗号,分隔�?[1-${#active_ports[@]}]: " choice_input

    # 处理多选择输入
    local valid_choices=()
    local ports_to_reset=()
    parse_multi_choice_input "$choice_input" "${#active_ports[@]}" valid_choices

    for choice in "${valid_choices[@]}"; do
        local port=${active_ports[$((choice-1))]}
        ports_to_reset+=("$port")
    done

    if [ ${#ports_to_reset[@]} -eq 0 ]; then
        echo -e "${RED}没有有效的端口可重置${NC}"
        sleep 2
        immediate_reset
        return
    fi

    # 显示要重置的端口及其当前流量
    echo
    echo "将重置以下端口的流量统计:"
    local total_all_traffic=0
    for port in "${ports_to_reset[@]}"; do
        local traffic_data=($(get_nftables_counter_data "$port"))
        local input_bytes=${traffic_data[0]}
        local output_bytes=${traffic_data[1]}
        local billing_mode=$(jq -r ".ports.\"$port\".billing_mode // \"single\"" "$CONFIG_FILE")
        local total_bytes=$(calculate_total_traffic "$input_bytes" "$output_bytes" "$billing_mode")
        local total_formatted=$(format_bytes $total_bytes)

        echo "  端口 $port: $total_formatted"
        total_all_traffic=$((total_all_traffic + total_bytes))
    done

    echo
    echo "总计流量: $(format_bytes $total_all_traffic)"
    echo -e "${YELLOW}警告：重置后流量统计将清零，此操作不可撤销�?{NC}"
    read -p "确认重置选定端口的流量统�? [y/N]: " confirm

    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        local reset_count=0
        for port in "${ports_to_reset[@]}"; do
            # 获取当前流量用于记录
            local traffic_data=($(get_nftables_counter_data "$port"))
            local input_bytes=${traffic_data[0]}
            local output_bytes=${traffic_data[1]}
            local billing_mode=$(jq -r ".ports.\"$port\".billing_mode // \"single\"" "$CONFIG_FILE")
            local total_bytes=$(calculate_total_traffic "$input_bytes" "$output_bytes" "$billing_mode")

            reset_port_nftables_counters "$port"
            record_reset_history "$port" "$total_bytes"

            echo -e "${GREEN}端口 $port 流量统计重置成功${NC}"
            reset_count=$((reset_count + 1))
        done

        echo
        echo -e "${GREEN}成功重置 $reset_count 个端口的流量统计${NC}"
        echo "重置前总流�? $(format_bytes $total_all_traffic)"
    else
        echo "取消重置"
    fi

    sleep 3
    manage_traffic_reset
}

# 自动重置指定端口的流�?
auto_reset_port() {
    local port="$1"

    local traffic_data=($(get_nftables_counter_data "$port"))
    local input_bytes=${traffic_data[0]}
    local output_bytes=${traffic_data[1]}
    local billing_mode=$(jq -r ".ports.\"$port\".billing_mode // \"double\"" "$CONFIG_FILE")
    local total_bytes=$(calculate_total_traffic "$input_bytes" "$output_bytes" "$billing_mode")

    reset_port_nftables_counters "$port"
    record_reset_history "$port" "$total_bytes"

    log_notification "端口 $port 自动重置完成，重置前流量: $(format_bytes $total_bytes)"

    echo "端口 $port 自动重置完成"
}

# 重置端口nftables计数器和配额
reset_port_nftables_counters() {
    local port=$1
    local table_name=$(jq -r '.nftables.table_name' "$CONFIG_FILE")
    local family=$(jq -r '.nftables.family' "$CONFIG_FILE")

    if is_port_range "$port"; then
        local port_safe=$(echo "$port" | tr '-' '_')
        nft reset counter $family $table_name "port_${port_safe}_in" >/dev/null 2>&1 || true
        nft reset counter $family $table_name "port_${port_safe}_out" >/dev/null 2>&1 || true
        nft reset quota $family $table_name "port_${port_safe}_quota" >/dev/null 2>&1 || true
    else
        nft reset counter $family $table_name "port_${port}_in" >/dev/null 2>&1 || true
        nft reset counter $family $table_name "port_${port}_out" >/dev/null 2>&1 || true
        nft reset quota $family $table_name "port_${port}_quota" >/dev/null 2>&1 || true
    fi
}

record_reset_history() {
    local port=$1
    local traffic_bytes=$2
    local timestamp=$(get_beijing_time +%s)
    local history_file="$CONFIG_DIR/reset_history.log"

    mkdir -p "$(dirname "$history_file")"

    echo "$timestamp|$port|$traffic_bytes" >> "$history_file"

    # 限制历史记录条数，避免文件过�?
    if [ $(wc -l < "$history_file" 2>/dev/null || echo 0) -gt 100 ]; then
        tail -n 100 "$history_file" > "${history_file}.tmp"
        mv "${history_file}.tmp" "$history_file"
    fi
}

manage_configuration() {
    echo -e "${BLUE}=== 配置文件管理 ===${NC}"
    echo
    echo "请选择操作:"
    echo "1. 导出配置�?
    echo "2. 导入配置�?
    echo "0. 返回上级菜单"
    echo
    read -p "请输入选择 [0-2]: " choice

    case $choice in
        1) export_config ;;
        2) import_config ;;
        0) show_main_menu ;;
        *) echo -e "${RED}无效选择，请输入0-2${NC}"; sleep 1; manage_configuration ;;
    esac
}

export_config() {
    echo -e "${BLUE}=== 导出配置�?===${NC}"
    echo

    # 检查配置目录是否存�?
    if [ ! -d "$CONFIG_DIR" ]; then
        echo -e "${RED}错误：配置目录不存在${NC}"
        sleep 2
        manage_configuration
        return
    fi

    # 生成时间戳文件名
    local timestamp=$(get_beijing_time +%Y%m%d-%H%M%S)
    local backup_name="port-traffic-dog-config-${timestamp}.tar.gz"
    local backup_path="/root/${backup_name}"

    echo "正在导出配置�?.."
    echo "包含内容�?
    echo "  - 主配置文�?(config.json)"
    echo "  - 端口监控数据"
    echo "  - 通知配置"
    echo "  - 日志文件"
    echo

    # 创建临时目录用于打包
    local temp_dir=$(mktemp -d)
    local package_dir="$temp_dir/port-traffic-dog-config"

    # 复制配置目录到临时位�?
    cp -r "$CONFIG_DIR" "$package_dir"

    # 生成端口流量狗配置包信息文件
    cat > "$package_dir/package_info.txt" << EOF
===================
导出时间: $(get_beijing_time '+%Y-%m-%d %H:%M:%S')
脚本版本: $SCRIPT_VERSION
配置目录: $CONFIG_DIR
导出主机: $(hostname)
包含端口: $(jq -r '.ports | keys | join(", ")' "$CONFIG_FILE" 2>/dev/null || echo "�?)
EOF

    # 打包配置
    cd "$temp_dir"
    tar -czf "$backup_path" port-traffic-dog-config/ 2>/dev/null

    # 清理临时目录
    rm -rf "$temp_dir"

    if [ -f "$backup_path" ]; then
        local file_size=$(du -h "$backup_path" | cut -f1)
        echo -e "${GREEN}配置包导出成�?{NC}"
        echo
        echo "文件信息�?
        echo "  文件�? $backup_name"
        echo "  路径: $backup_path"
        echo "  大小: $file_size"
    else
        echo -e "${RED}配置包导出失�?{NC}"
    fi

    echo
    read -p "按回车键返回..."
    manage_configuration
}

# 导入配置�?
import_config() {
    echo -e "${BLUE}=== 导入配置�?===${NC}"
    echo

    echo "请输入配置包路径 (支持绝对路径或相对路�?:"
    echo "例如: /root/port-traffic-dog-config-20241227-143022.tar.gz"
    echo
    read -p "配置包路�? " package_path

    # 检查输入是否为�?
    if [ -z "$package_path" ]; then
        echo -e "${RED}错误：路径不能为�?{NC}"
        sleep 2
        import_config
        return
    fi

    # 检查文件是否存�?
    if [ ! -f "$package_path" ]; then
        echo -e "${RED}错误：配置包文件不存�?{NC}"
        echo "路径: $package_path"
        sleep 2
        import_config
        return
    fi

    # 检查文件格�?
    if [[ ! "$package_path" =~ \.tar\.gz$ ]]; then
        echo -e "${RED}错误：配置包必须�?.tar.gz 格式${NC}"
        sleep 2
        import_config
        return
    fi

    echo
    echo "正在验证配置�?.."

    # 创建临时目录用于解压验证
    local temp_dir=$(mktemp -d)

    # 解压到临时目录进行验�?
    cd "$temp_dir"
    if ! tar -tzf "$package_path" >/dev/null 2>&1; then
        echo -e "${RED}错误：配置包文件损坏或格式错�?{NC}"
        rm -rf "$temp_dir"
        sleep 2
        import_config
        return
    fi

    # 解压配置�?
    tar -xzf "$package_path" 2>/dev/null

    # 验证配置包结�?
    local config_dir_name=$(ls | head -n1)
    if [ ! -d "$config_dir_name" ]; then
        echo -e "${RED}错误：配置包结构异常${NC}"
        rm -rf "$temp_dir"
        sleep 2
        import_config
        return
    fi

    local extracted_config="$temp_dir/$config_dir_name"

    # 检查必要文�?
    if [ ! -f "$extracted_config/config.json" ]; then
        echo -e "${RED}错误：配置包中缺�?config.json 文件${NC}"
        rm -rf "$temp_dir"
        sleep 2
        import_config
        return
    fi

    # 显示端口流量狗配置包信息
    echo -e "${GREEN}配置包验证通过${NC}"
    echo

    if [ -f "$extracted_config/package_info.txt" ]; then
        echo -e "${GREEN}端口流量狗配置包信息�?{NC}"
        cat "$extracted_config/package_info.txt"
        echo
    fi

    # 显示将要导入的端�?
    local import_ports=$(jq -r '.ports | keys | join(", ")' "$extracted_config/config.json" 2>/dev/null || echo "�?)
    echo "包含端口: $import_ports"
    echo

    # 确认导入
    echo -e "${YELLOW}警告：导入配置将会：${NC}"
    echo "  1. 停止当前所有端口监�?
    echo "  2. 替换为新的配�?
    echo "  3. 重新应用监控规则"
    echo
    read -p "确认导入配置�? [y/N]: " confirm

    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo "取消导入"
        rm -rf "$temp_dir"
        sleep 1
        manage_configuration
        return
    fi

    echo
    echo "开始导入配�?.."

    # 1. 停止当前监控
    echo "正在停止当前端口监控..."
    local current_ports=($(get_active_ports 2>/dev/null || true))
    for port in "${current_ports[@]}"; do
        remove_nftables_rules "$port" 2>/dev/null || true
        remove_tc_limit "$port" 2>/dev/null || true
    done

    # 2. 替换配置
    echo "正在导入新配�?.."
    rm -rf "$CONFIG_DIR" 2>/dev/null || true
    mkdir -p "$(dirname "$CONFIG_DIR")"
    cp -r "$extracted_config" "$CONFIG_DIR"

    # 3. 重新应用规则
    echo "正在重新应用监控规则..."

    # 重新初始化nftables
    init_nftables

    # 为每个端口重新应用规�?
    local new_ports=($(get_active_ports))
    for port in "${new_ports[@]}"; do
        # 添加基础监控规则
        add_nftables_rules "$port"

        # 应用配额限制（如果有�?
        local quota_enabled=$(jq -r ".ports.\"$port\".quota.enabled // false" "$CONFIG_FILE")
        local monthly_limit=$(jq -r ".ports.\"$port\".quota.monthly_limit // \"unlimited\"" "$CONFIG_FILE")
        if [ "$quota_enabled" = "true" ] && [ "$monthly_limit" != "unlimited" ]; then
            apply_nftables_quota "$port" "$monthly_limit"
        fi

        # 应用带宽限制（如果有�?
        local limit_enabled=$(jq -r ".ports.\"$port\".bandwidth_limit.enabled // false" "$CONFIG_FILE")
        local rate_limit=$(jq -r ".ports.\"$port\".bandwidth_limit.rate // \"unlimited\"" "$CONFIG_FILE")
        if [ "$limit_enabled" = "true" ] && [ "$rate_limit" != "unlimited" ]; then
            local tc_limit=$(convert_bandwidth_to_tc "$rate_limit")
            if [ -n "$tc_limit" ]; then
                apply_tc_limit "$port" "$tc_limit"
            fi
        fi
    done

    echo "正在更新通知模块..."
    download_notification_modules >/dev/null 2>&1 || true

    rm -rf "$temp_dir"

    echo
    echo -e "${GREEN}配置导入完成${NC}"
    echo
    echo "导入结果�?
    echo "  导入端口�? ${#new_ports[@]} �?
    if [ ${#new_ports[@]} -gt 0 ]; then
        echo "  端口列表: $(IFS=','; echo "${new_ports[*]}")"
    fi
    echo
    echo -e "${YELLOW}提示�?{NC}"
    echo "  - 所有端口监控规则已重新应用"
    echo "  - 通知配置已恢�?
    echo "  - 历史数据已恢�?

    echo
    read -p "按回车键返回..."
    manage_configuration
}

# 统一下载函数
download_with_sources() {
    local url=$1
    local output_file=$2

    if curl -sL --connect-timeout $SHORT_CONNECT_TIMEOUT --max-time $SHORT_MAX_TIMEOUT "$url" -o "$output_file" 2>/dev/null; then
        if [ -s "$output_file" ]; then
            echo -e "${GREEN}下载成功${NC}"
            return 0
        fi
    fi

    echo -e "${RED}下载失败${NC}"
    return 1
}

# 下载通知模块
download_notification_modules() {
    local notifications_dir="$CONFIG_DIR/notifications"
    local temp_dir=$(mktemp -d)
    local repo_url="https://github.com/byby5555/realm-xwPF-active-standby/archive/refs/heads/main.zip"

    # 下载解压复制清理：每次都覆盖更新确保版本一�?
    if download_with_sources "$repo_url" "$temp_dir/repo.zip" &&
       (cd "$temp_dir" && unzip -q repo.zip) &&
       rm -rf "$notifications_dir" &&
       cp -r "$temp_dir/realm-xwPF-main/notifications" "$notifications_dir" &&
       chmod +x "$notifications_dir"/*.sh; then
        rm -rf "$temp_dir"
        return 0
    else
        rm -rf "$temp_dir"
        return 1
    fi
}

# 安装(更新)脚本
install_update_script() {
    echo -e "${BLUE}安装依赖(更新)脚本${NC}"
    echo "────────────────────────────────────────────────────────"

    echo -e "${YELLOW}正在检查系统依�?..${NC}"
    check_dependencies true

    echo -e "${YELLOW}正在下载最新版�?..${NC}"

    local temp_file=$(mktemp)

    if download_with_sources "$SCRIPT_URL" "$temp_file"; then
        if [ -s "$temp_file" ] && grep -q "端口流量�? "$temp_file" 2>/dev/null; then
            mv "$temp_file" "$SCRIPT_PATH"
            chmod +x "$SCRIPT_PATH"

            create_shortcut_command

            echo -e "${YELLOW}正在更新通知模块...${NC}"
            download_notification_modules >/dev/null 2>&1 || true

            echo -e "${GREEN}依赖检查完�?{NC}"
            echo -e "${GREEN}脚本更新完成${NC}"
            echo -e "${GREEN}通知模块已更�?{NC}"
        else
            echo -e "${RED} 下载文件验证失败${NC}"
            rm -f "$temp_file"
        fi
    else
        echo -e "${RED} 下载失败，请检查网络连�?{NC}"
        rm -f "$temp_file"
    fi

    echo "────────────────────────────────────────────────────────"
    read -p "按回车键返回..."
    show_main_menu
}

create_shortcut_command() {
    if [ ! -f "/usr/local/bin/$SHORTCUT_COMMAND" ]; then
        cat > "/usr/local/bin/$SHORTCUT_COMMAND" << EOF
#!/bin/bash
exec bash "$SCRIPT_PATH" "\$@"
EOF
        chmod +x "/usr/local/bin/$SHORTCUT_COMMAND" 2>/dev/null || true
        echo -e "${GREEN}快捷命令 '$SHORTCUT_COMMAND' 创建成功${NC}"
    fi
}

# 卸载脚本
uninstall_script() {
    echo -e "${BLUE}卸载脚本${NC}"
    echo "────────────────────────────────────────────────────────"

    echo -e "${YELLOW}将要删除以下内容:${NC}"
    echo "  - 脚本文件: $SCRIPT_PATH"
    echo "  - 快捷命令: /usr/local/bin/$SHORTCUT_COMMAND"
    echo "  - 配置目录: $CONFIG_DIR"
    echo "  - 所有nftables规则"
    echo "  - 所有TC限制规则"
    echo "  - 通知定时任务"
    echo
    echo -e "${RED}警告：此操作将完全删除端口流量狗及其所有数据！${NC}"
    read -p "确认卸载? [y/N]: " confirm

    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        echo -e "${YELLOW}正在卸载...${NC}"

        local active_ports=($(get_active_ports 2>/dev/null || true))
        for port in "${active_ports[@]}"; do
            remove_nftables_rules "$port" 2>/dev/null || true
            remove_tc_limit "$port" 2>/dev/null || true
        done

        local table_name=$(jq -r '.nftables.table_name' "$CONFIG_FILE" 2>/dev/null || echo "port_traffic_monitor")
        local family=$(jq -r '.nftables.family' "$CONFIG_FILE" 2>/dev/null || echo "inet")
        nft delete table $family $table_name >/dev/null 2>&1 || true

        remove_telegram_notification_cron 2>/dev/null || true
        remove_wecom_notification_cron 2>/dev/null || true

        rm -rf "$CONFIG_DIR" 2>/dev/null || true
        rm -f "/usr/local/bin/$SHORTCUT_COMMAND" 2>/dev/null || true
        rm -f "$SCRIPT_PATH" 2>/dev/null || true

        echo -e "${GREEN}卸载完成�?{NC}"
        echo -e "${YELLOW}感谢使用端口流量狗！${NC}"
        exit 0
    else
        echo "取消卸载"
        sleep 1
        show_main_menu
    fi
}

manage_notifications() {
    echo -e "${BLUE}=== 通知管理 ===${NC}"
    echo "1. Telegram机器人通知"
    echo "2. 邮箱通知 [敬请期待]"
    echo "3. 企业wx 机器人通知"
    echo "0. 返回主菜�?
    echo
    read -p "请选择操作 [0-3]: " choice

    case $choice in
        1) manage_telegram_notifications ;;
        2)
            echo -e "${YELLOW}预留的邮箱通知功能(画饼�?${NC}"
            sleep 2
            manage_notifications
            ;;
        3) manage_wecom_notifications ;;
        0) show_main_menu ;;
        *) echo -e "${RED}无效选择${NC}"; sleep 1; manage_notifications ;;
    esac
}

manage_telegram_notifications() {
    local telegram_script="$CONFIG_DIR/notifications/telegram.sh"

    if [ -f "$telegram_script" ]; then
        # 导出通知管理函数供模块使�?
        export_notification_functions
        source "$telegram_script"
        telegram_configure
        manage_notifications
    else
        echo -e "${RED}Telegram 通知模块不存�?{NC}"
        echo "请检查文�? $telegram_script"
        sleep 2
        manage_notifications
    fi
}

manage_wecom_notifications() {
    local wecom_script="$CONFIG_DIR/notifications/wecom.sh"

    if [ -f "$wecom_script" ]; then
        # 导出通知管理函数供模块使�?
        export_notification_functions
        source "$wecom_script"
        wecom_configure
        manage_notifications
    else
        echo -e "${RED}企业wx 通知模块不存�?{NC}"
        echo "请检查文�? $wecom_script"
        sleep 2
        manage_notifications
    fi
}

setup_telegram_notification_cron() {
    local script_path="$SCRIPT_PATH"
    local temp_cron=$(mktemp)

    crontab -l 2>/dev/null | grep -v "# 端口流量狗Telegram通知" > "$temp_cron" || true

    # 检查telegram通知是否启用
    local telegram_enabled=$(jq -r '.notifications.telegram.status_notifications.enabled // false' "$CONFIG_FILE")
    if [ "$telegram_enabled" = "true" ]; then
        local status_interval=$(jq -r '.notifications.telegram.status_notifications.interval' "$CONFIG_FILE")
        case "$status_interval" in
            "1m")  echo "* * * * * $script_path --send-telegram-status >/dev/null 2>&1  # 端口流量狗Telegram通知" >> "$temp_cron" ;;
            "15m") echo "*/15 * * * * $script_path --send-telegram-status >/dev/null 2>&1  # 端口流量狗Telegram通知" >> "$temp_cron" ;;
            "30m") echo "*/30 * * * * $script_path --send-telegram-status >/dev/null 2>&1  # 端口流量狗Telegram通知" >> "$temp_cron" ;;
            "1h")  echo "0 * * * * $script_path --send-telegram-status >/dev/null 2>&1  # 端口流量狗Telegram通知" >> "$temp_cron" ;;
            "2h")  echo "0 */2 * * * $script_path --send-telegram-status >/dev/null 2>&1  # 端口流量狗Telegram通知" >> "$temp_cron" ;;
            "6h")  echo "0 */6 * * * $script_path --send-telegram-status >/dev/null 2>&1  # 端口流量狗Telegram通知" >> "$temp_cron" ;;
            "12h") echo "0 */12 * * * $script_path --send-telegram-status >/dev/null 2>&1  # 端口流量狗Telegram通知" >> "$temp_cron" ;;
            "24h") echo "0 0 * * * $script_path --send-telegram-status >/dev/null 2>&1  # 端口流量狗Telegram通知" >> "$temp_cron" ;;
        esac
    fi

    crontab "$temp_cron"
    rm -f "$temp_cron"
}

setup_wecom_notification_cron() {
    local script_path="$SCRIPT_PATH"
    local temp_cron=$(mktemp)
    crontab -l 2>/dev/null | grep -v "# 端口流量狗企业wx 通知" > "$temp_cron" || true

    # 检查企业wx 通知是否启用
    local wecom_enabled=$(jq -r '.notifications.wecom.status_notifications.enabled // false' "$CONFIG_FILE")
    if [ "$wecom_enabled" = "true" ]; then
        local wecom_interval=$(jq -r '.notifications.wecom.status_notifications.interval' "$CONFIG_FILE")
        case "$wecom_interval" in
            "1m")  echo "* * * * * $script_path --send-wecom-status >/dev/null 2>&1  # 端口流量狗企业wx 通知" >> "$temp_cron" ;;
            "15m") echo "*/15 * * * * $script_path --send-wecom-status >/dev/null 2>&1  # 端口流量狗企业wx 通知" >> "$temp_cron" ;;
            "30m") echo "*/30 * * * * $script_path --send-wecom-status >/dev/null 2>&1  # 端口流量狗企业wx 通知" >> "$temp_cron" ;;
            "1h")  echo "0 * * * * $script_path --send-wecom-status >/dev/null 2>&1  # 端口流量狗企业wx 通知" >> "$temp_cron" ;;
            "2h")  echo "0 */2 * * * $script_path --send-wecom-status >/dev/null 2>&1  # 端口流量狗企业wx 通知" >> "$temp_cron" ;;
            "6h")  echo "0 */6 * * * $script_path --send-wecom-status >/dev/null 2>&1  # 端口流量狗企业wx 通知" >> "$temp_cron" ;;
            "12h") echo "0 */12 * * * $script_path --send-wecom-status >/dev/null 2>&1  # 端口流量狗企业wx 通知" >> "$temp_cron" ;;
            "24h") echo "0 0 * * * $script_path --send-wecom-status >/dev/null 2>&1  # 端口流量狗企业wx 通知" >> "$temp_cron" ;;
        esac
    fi

    crontab "$temp_cron"
    rm -f "$temp_cron"
}

# 通用间隔选择函数
select_notification_interval() {
    # 显示选择菜单到stderr，避免被变量捕获
    echo "请选择状态通知发送间�?" >&2
    echo "1. 1分钟   2. 15分钟  3. 30分钟  4. 1小时" >&2
    echo "5. 2小时   6. 6小时   7. 12小时  8. 24小时" >&2
    read -p "请选择(回车默认1小时) [1-8]: " interval_choice >&2

    # 默认1小时
    local interval="1h"
    case $interval_choice in
        1) interval="1m" ;;
        2) interval="15m" ;;
        3) interval="30m" ;;
        4|"") interval="1h" ;;
        5) interval="2h" ;;
        6) interval="6h" ;;
        7) interval="12h" ;;
        8) interval="24h" ;;
        *) interval="1h" ;;
    esac

    echo "$interval"
}

remove_telegram_notification_cron() {
    local temp_cron=$(mktemp)
    crontab -l 2>/dev/null | grep -v "# 端口流量狗Telegram通知" > "$temp_cron" || true
    crontab "$temp_cron"
    rm -f "$temp_cron"
}

remove_wecom_notification_cron() {
    local temp_cron=$(mktemp)
    crontab -l 2>/dev/null | grep -v "# 端口流量狗企业wx 通知" > "$temp_cron" || true
    crontab "$temp_cron"
    rm -f "$temp_cron"
}

export_notification_functions() {
    export -f setup_telegram_notification_cron
    export -f setup_wecom_notification_cron
    export -f select_notification_interval
}

setup_port_auto_reset_cron() {
    local port="$1"
    local script_path="$SCRIPT_PATH"
    local temp_cron=$(mktemp)

    # 保留现有任务，移除该端口的旧任务
    crontab -l 2>/dev/null | grep -v "端口流量狗自动重置端�?port" | grep -v "port-traffic-dog.*--reset-port $port" > "$temp_cron" || true

    local quota_enabled=$(jq -r ".ports.\"$port\".quota.enabled // true" "$CONFIG_FILE")
    local monthly_limit=$(jq -r ".ports.\"$port\".quota.monthly_limit // \"unlimited\"" "$CONFIG_FILE")
    local reset_day_raw=$(jq -r ".ports.\"$port\".quota.reset_day" "$CONFIG_FILE")
    
    # 只有quota启用、monthly_limit不是unlimited、且reset_day存在时才添加cron任务
    if [ "$quota_enabled" = "true" ] && [ "$monthly_limit" != "unlimited" ] && [ "$reset_day_raw" != "null" ]; then
        local reset_day="${reset_day_raw:-1}"
        echo "5 0 $reset_day * * $script_path --reset-port $port >/dev/null 2>&1  # 端口流量狗自动重置端�?port" >> "$temp_cron"
    fi

    crontab "$temp_cron"
    rm -f "$temp_cron"
}

remove_port_auto_reset_cron() {
    local port="$1"
    local temp_cron=$(mktemp)

    crontab -l 2>/dev/null | grep -v "端口流量狗自动重置端�?port" | grep -v "port-traffic-dog.*--reset-port $port" > "$temp_cron" || true

    crontab "$temp_cron"
    rm -f "$temp_cron"
}

# 格式化状态消息（HTML格式�?
format_status_message() {
    local server_name="${1:-$(hostname)}"  # 接受服务器名称参�?
    local timestamp=$(get_beijing_time '+%Y-%m-%d %H:%M:%S')
    local notification_icon="🔔"
    local active_ports=($(get_active_ports))
    local port_count=${#active_ports[@]}
    local daily_total=$(get_daily_total_traffic)

    local message="<b>${notification_icon} 端口流量�?v${SCRIPT_VERSION}</b> | �?${timestamp}
介绍主页:<code>https://zywe.de</code> | 项目开�?<code>https://github.com/byby5555/realm-xwPF-active-standby</code>
一只轻巧的'守护�?，时刻守护你的端口流�?| 快捷命令: dog
---
状�? 监控�?| 守护端口: ${port_count}�?| 端口总流�? ${daily_total}
────────────────────────────────────────
<pre>$(format_port_list "message")</pre>
────────────────────────────────────────
🔗 服务�? <i>${server_name}</i>"

    echo "$message"
}

# 格式化状态消息（纯文本text格式�?
format_text_status_message() {
    local server_name="${1:-$(hostname)}"
    local timestamp=$(get_beijing_time '+%Y-%m-%d %H:%M:%S')
    local notification_icon="🔔"
    local active_ports=($(get_active_ports))
    local port_count=${#active_ports[@]}
    local daily_total=$(get_daily_total_traffic)

    local message="${notification_icon} 端口流量�?v${SCRIPT_VERSION} | �?${timestamp}
介绍主页: https://zywe.de | 项目开�? https://github.com/byby5555/realm-xwPF-active-standby
一只轻巧的'守护�?，时刻守护你的端口流�?| 快捷命令: dog
---
状�? 监控�?| 守护端口: ${port_count}�?| 端口总流�? ${daily_total}
────────────────────────────────────────
$(format_port_list "message")
────────────────────────────────────────
🔗 服务�? ${server_name}"

    echo "$message"
}

# 格式化状态消息（Markdown格式�?
format_markdown_status_message() {
    local server_name="${1:-$(hostname)}"
    local timestamp=$(get_beijing_time '+%Y-%m-%d %H:%M:%S')
    local notification_icon="🔔"
    local active_ports=($(get_active_ports))
    local port_count=${#active_ports[@]}
    local daily_total=$(get_daily_total_traffic)

    local message="**${notification_icon} 端口流量�?v${SCRIPT_VERSION}** | �?${timestamp}
介绍主页: \`https://zywe.de\` | 项目开�? \`https://github.com/byby5555/realm-xwPF-active-standby\`
一只轻巧的'守护�?，时刻守护你的端口流�?| 快捷命令: dog
---
**状�?*: 监控�?| **守护端口**: ${port_count}�?| **端口总流�?*: ${daily_total}
────────────────────────────────────────
$(format_port_list "markdown")
────────────────────────────────────────
🔗 **服务�?*: ${server_name}"

    echo "$message"
}

# 记录通知日志
log_notification() {
    local message="$1"
    local timestamp=$(get_beijing_time '+%Y-%m-%d %H:%M:%S')
    local log_file="$CONFIG_DIR/logs/notification.log"

    mkdir -p "$(dirname "$log_file")"

    echo "[$timestamp] $message" >> "$log_file"

    # 日志轮转：防止日志文件过�?
    if [ -f "$log_file" ] && [ $(wc -l < "$log_file") -gt 1000 ]; then
        tail -n 500 "$log_file" > "${log_file}.tmp"
        mv "${log_file}.tmp" "$log_file"
    fi
}

# 通用状态通知发送函�?
send_status_notification() {
    local success_count=0
    local total_count=0

    # 发送Telegram通知
    local telegram_script="$CONFIG_DIR/notifications/telegram.sh"
    if [ -f "$telegram_script" ]; then
        source "$telegram_script"
        total_count=$((total_count + 1))
        if telegram_send_status_notification; then
            success_count=$((success_count + 1))
        fi
    fi

    # 发送企业wx 通知
    local wecom_script="$CONFIG_DIR/notifications/wecom.sh"
    if [ -f "$wecom_script" ]; then
        source "$wecom_script"
        total_count=$((total_count + 1))
        if wecom_send_status_notification; then
            success_count=$((success_count + 1))
        fi
    fi

    if [ $total_count -eq 0 ]; then
        log_notification "通知模块不存�?
        echo -e "${RED}通知模块不存�?{NC}"
        return 1
    elif [ $success_count -gt 0 ]; then
        echo -e "${GREEN}状态通知发送成�?($success_count/$total_count)${NC}"
        return 0
    else
        echo -e "${RED}状态通知发送失�?{NC}"
        return 1
    fi
}

main() {
    check_root

    # cron 快速路径：跳过重型初始化（依赖检查、通知模块下载、规则恢复等�?
    if [ $# -gt 0 ]; then
        case $1 in
            --reset-port)
                if [ $# -lt 2 ]; then
                    echo -e "${RED}错误�?-reset-port 需要指定端口号${NC}"
                    exit 1
                fi
                auto_reset_port "$2"
                exit 0
                ;;
            --send-telegram-status)
                local telegram_script="$CONFIG_DIR/notifications/telegram.sh"
                if [ -f "$telegram_script" ]; then
                    source "$telegram_script"
                    telegram_send_status_notification
                fi
                exit 0
                ;;
            --send-wecom-status)
                local wecom_script="$CONFIG_DIR/notifications/wecom.sh"
                if [ -f "$wecom_script" ]; then
                    source "$wecom_script"
                    wecom_send_status_notification
                fi
                exit 0
                ;;
            --send-status)
                send_status_notification
                exit 0
                ;;
        esac
    fi

    # 完整启动流程（交互式菜单和其余命令需要）
    check_dependencies
    init_config
    create_shortcut_command

    if [ $# -gt 0 ]; then
        case $1 in
            --check-deps)
                echo -e "${GREEN}依赖检查通过${NC}"
                exit 0
                ;;
            --version)
                echo -e "${BLUE}$SCRIPT_NAME v$SCRIPT_VERSION${NC}"
                echo -e "${GREEN}介绍主页:${NC} https://zywe.de"
                echo -e "${GREEN}项目开�?${NC} https://github.com/byby5555/realm-xwPF-active-standby"
                exit 0
                ;;
            --install)
                install_update_script
                exit 0
                ;;
            --uninstall)
                uninstall_script
                exit 0
                ;;
            *)
                echo -e "${YELLOW}用法: $0 [选项]${NC}"
                echo "选项:"
                echo "  --check-deps              检查依赖工�?
                echo "  --version                 显示版本信息"
                echo "  --install                 安装/更新脚本"
                echo "  --uninstall               卸载脚本"
                echo "  --send-status             发送所有启用的状态通知"
                echo "  --send-telegram-status    发送Telegram状态通知"
                echo "  --send-wecom-status       发送企业wx 状态通知"
                echo "  --reset-port PORT         重置指定端口流量"
                echo
                echo -e "${GREEN}快捷命令: $SHORTCUT_COMMAND${NC}"
                exit 1
                ;;
        esac
    fi

    show_main_menu
}

main "$@"
