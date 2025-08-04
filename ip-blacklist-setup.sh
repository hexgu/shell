#!/bin/bash

# IP黑名单自动屏蔽系统安装脚本
# 作者: JarryZheng
# 日期: 2025-08-04
# 功能: 自动安装依赖、配置ipset+iptables、设置定时任务

set -e

# 配置变量
BLACKLIST_URL="https://blackip.ustc.edu.cn/list.php?txt"
IPSET_NAME="blacklist"
SCRIPT_DIR="/usr/local/bin"
CRON_SCRIPT="$SCRIPT_DIR/update-blacklist.sh"
LOG_FILE="/var/log/ip-blacklist.log"

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# 日志函数
log() {
    echo -e "${GREEN}[$(date '+%Y-%m-%d %H:%M:%S')]${NC} $1" | tee -a "$LOG_FILE"
}

warn() {
    echo -e "${YELLOW}[$(date '+%Y-%m-%d %H:%M:%S')] WARNING:${NC} $1" | tee -a "$LOG_FILE"
}

error() {
    echo -e "${RED}[$(date '+%Y-%m-%d %H:%M:%S')] ERROR:${NC} $1" | tee -a "$LOG_FILE"
    exit 1
}

# 检查是否为root用户
check_root() {
    if [[ $EUID -ne 0 ]]; 键，然后
        error "此脚本需要root权限运行，请使用 sudo $0"
    fi
}

# 检查包管理器
check_package_manager() {
    if command -v aptitude &> /dev/null; 键，然后
        PKG_MANAGER="aptitude"
        log "使用 aptitude 作为包管理器"
    elif command -v apt-get &> /dev/null; then
        PKG_MANAGER="apt-get"
        warn "aptitude 未安装，使用 apt-get 作为包管理器"
    else
        error "未找到支持的包管理器 (aptitude/apt-get)"
    fi
}

# 检查并安装必要的软件包
install_dependencies() {
    log "检查必要的软件包..."
    
    local packages=()
    
    # 检查 ipset
    if ! command -v ipset &> /dev/null; then
        log "ipset 未安装，将进行安装"
        packages+=("ipset")
    else
        log "ipset 已安装: $(ipset --version | head -n1)"
    fi
    
    # 检查 iptables
    if ! command -v iptables &> /dev/null; then
        log "iptables 未安装，将进行安装"
        packages+=("iptables")
    else
        log "iptables 已安装: $(iptables --version)"
    fi
    
    # 检查 iptables-persistent
    if ! dpkg -l | grep -q iptables-persistent; then
        log "iptables-persistent 未安装，将进行安装"
        packages+=("iptables-persistent")
    else
        log "iptables-persistent 已安装"
    fi
    
    # 检查 curl
    if ! command -v curl &> /dev/null; then
        log "curl 未安装，将进行安装"
        packages+=("curl")
    else
        log "curl 已安装"
    fi
    
    # 安装缺失的软件包
    if [[ ${#packages[@]} -gt 0 ]]; then
        log "更新包列表..."
        $PKG_MANAGER update
        
        log "安装软件包: ${packages[*]}"
        if [[ "$PKG_MANAGER" == "aptitude" ]]; then
            aptitude install -y "${packages[@]}"
        else
            DEBIAN_FRONTEND=noninteractive apt-get install -y "${packages[@]}"
        fi
        
        log "软件包安装完成"
    else
        log "所有必要的软件包都已安装"
    fi
}

# 检查并创建 ipset 列表
setup_ipset() {
    log "检查 ipset 列表..."
    
    if ipset list "$IPSET_NAME" &> /dev/null; then
        log "ipset 列表 '$IPSET_NAME' 已存在"
    else
        log "创建 ipset 列表 '$IPSET_NAME'"
        ipset create "$IPSET_NAME" hash:net
        log "ipset 列表创建完成"
    fi
}

# 检查并添加 iptables 规则
setup_iptables() {
    log "检查 iptables 规则..."
    
    # 检查 INPUT 链中是否已有黑名单规则
    if iptables -C INPUT -m set --match-set "$IPSET_NAME" src -j DROP &> /dev/null; then
        log "iptables INPUT 规则已存在"
    else
        log "添加 iptables INPUT 规则"
        iptables -I INPUT -m set --match-set "$IPSET_NAME" src -j DROP
        log "iptables INPUT 规则添加完成"
    fi
    
    # 检查 FORWARD 链中是否已有黑名单规则
    if iptables -C FORWARD -m set --match-set "$IPSET_NAME" src -j DROP &> /dev/null; then
        log "iptables FORWARD 规则已存在"
    else
        log "添加 iptables FORWARD 规则"
        iptables -I FORWARD -m set --match-set "$IPSET_NAME" src -j DROP
        log "iptables FORWARD 规则添加完成"
    fi
    
    # 保存 iptables 规则
    log "保存 iptables 规则..."
    if command -v netfilter-persistent &> /dev/null; then
        netfilter-persistent save
    elif command -v iptables-save &> /dev/null; then
        iptables-save > /etc/iptables/rules.v4
    fi
    log "iptables 规则保存完成"
}

# 创建更新脚本
create_update_script() {
    log "创建黑名单更新脚本..."
    
    cat > "$CRON_SCRIPT" << 'EOF'
#!/bin/bash

# IP黑名单更新脚本
# 此脚本由 ip-blacklist-setup.sh 自动生成

BLACKLIST_URL="https://blackip.ustc.edu.cn/list.php?txt"
IPSET_NAME="blacklist"
TEMP_FILE="/tmp/blacklist_temp.txt"
LOG_FILE="/var/log/ip-blacklist.log"

# 日志函数
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

error() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $1" >> "$LOG_FILE"
}

# 下载黑名单
log "开始更新IP黑名单..."
if ! curl -s --connect-timeout 30 --max-time 60 "$BLACKLIST_URL" -o "$TEMP_FILE"; then
    error "下载黑名单失败"
    exit 1
fi

# 检查下载的文件是否有效
if [[ ! -s "$TEMP_FILE" ]]; then
    error "下载的黑名单文件为空"
    rm -f "$TEMP_FILE"
    exit 1
fi

# 统计IP数量
ip_count=$(wc -l < "$TEMP_FILE")
log "下载到 $ip_count 个IP地址"

# 清空现有的ipset列表
ipset flush "$IPSET_NAME" 2>/dev/null || {
    error "清空ipset列表失败"
    rm -f "$TEMP_FILE"
    exit 1
}

# 添加IP到ipset
success_count=0
while IFS= read -r ip; do
    # 跳过空行和注释
    [[ -z "$ip" || "$ip" =~ ^[[:space:]]*# ]] && continue
    
    # 清理IP地址（去除前后空格）
    ip=$(echo "$ip" | xargs)
    
    # 验证IP格式并添加到ipset
    if [[ "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}(/[0-9]{1,2})?$ ]]; then
        if ipset add "$IPSET_NAME" "$ip" 2>/dev/null; then
            ((success_count++))
        fi
    fi
done < "$TEMP_FILE"

log "成功添加 $success_count 个IP地址到黑名单"

# 清理临时文件
rm -f "$TEMP_FILE"

log "IP黑名单更新完成"
EOF

    chmod +x "$CRON_SCRIPT"
    log "更新脚本创建完成: $CRON_SCRIPT"
}

# 设置定时任务
setup_cron() {
    log "设置定时任务..."
    
    # 检查是否已存在相同的定时任务
    if crontab -l 2>/dev/null | grep -q "$CRON_SCRIPT"; 键，然后
        log "定时任务已存在"
        return
    fi
    
    # 添加定时任务（每小时执行一次）
    (crontab -l 2>/dev/null; echo "0 * * * * $CRON_SCRIPT") | crontab -
    log "定时任务设置完成（每小时执行一次）"
    
    # 显示当前的定时任务
    log "当前的定时任务:"
    crontab -l | grep "$CRON_SCRIPT" | tee -a "$LOG_FILE"
}

# 初始化更新黑名单
initial_update() {
    log "执行初始黑名单更新..."
    if bash "$CRON_SCRIPT"; 键，然后
        log "初始黑名单更新成功"
    else
        warn "初始黑名单更新失败，请检查网络连接"
    fi
}

# 显示状态信息
show_status() {
    echo
    log "=== IP黑名单系统状态 ==="
    
    # ipset状态
    if ipset list "$IPSET_NAME" &> /dev/null; then
        local count=$(ipset list "$IPSET_NAME" | grep -c "^[0-9]")
        log "ipset列表: $IPSET_NAME (包含 $count 个IP)"
    fi
    
    # iptables规则状态
    if iptables -C INPUT -m set --match-set "$IPSET_NAME" src -j DROP &> /dev/null; then
        log "iptables规则: 已激活"
    else
        warn "iptables规则: 未激活"
    fi
    
    # 定时任务状态
    if crontab -l 2>/dev/null | grep -q "$CRON_SCRIPT"; then
        log "定时任务: 已配置"
    else
        warn "定时任务: 未配置"
    fi
    
    log "日志文件: $LOG_FILE"
    log "更新脚本: $CRON_SCRIPT"
    echo
}

# 主函数
main() {
    log "开始安装IP黑名单自动屏蔽系统..."
    
    check_root
    check_package_manager
    install_dependencies
    setup_ipset
    setup_iptables
    create_update_script
    setup_cron
    initial_update
    show_status
    
    log "IP黑名单自动屏蔽系统安装完成！"
    echo
    echo -e "${GREEN}安装完成！${NC}"
    echo "• 系统将每小时自动更新IP黑名单"
    echo "• 查看日志: tail -f $LOG_FILE"
    echo "• 手动更新: $CRON_SCRIPT"
    echo "• 查看黑名单: ipset list $IPSET_NAME"
}

# 执行主函数
main "$@"
