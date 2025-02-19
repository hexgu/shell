#!/usr/bin/env bash
set -euo pipefail

# 配置参数
SWAP_FILE="/swapfile"
MIN_SWAP_MB=2048
MAX_SWAP_MB=4096
SWAP_PRIORITY=100  # 设置Swap优先级

# 必须使用root权限运行
if [[ $EUID -ne 0 ]]; then
    echo "❌ 必须使用sudo或root权限运行此脚本" >&2
    exit 1
fi

# 计算物理内存（单位：字节）
mem_total=$(grep -i "memtotal" /proc/meminfo | awk '{print $2}')
mem_total_bytes=$((mem_total * 1024))
mem_gb=$((mem_total_bytes / (1024**3)))

# 智能计算推荐Swap大小
calculate_swap() {
    local calculated_mb
    if (( mem_gb < 2 )); then
        calculated_mb=$((mem_total * 2 / 1024))    # 内存2倍（转换为MB）
    elif (( mem_gb <= 8 )); then
        calculated_mb=$((mem_total / 1024))        # 等于内存大小
    elif (( mem_gb <= 64 )); then
        calculated_mb=$((mem_total / 2 / 1024))    # 内存的50%
    else
        calculated_mb=$MAX_SWAP_MB                 # 最大4GB
    fi

    # 应用最小/最大限制
    if (( calculated_mb < MIN_SWAP_MB )); then
        echo "$MIN_SWAP_MB"
    elif (( calculated_mb > MAX_SWAP_MB )); then
        echo "$MAX_SWAP_MB"
    else
        echo "$calculated_mb"
    fi
}

# 计算推荐的Swap大小
recommended_swap_mb=$(calculate_swap)

# 获取当前Swap信息
mapfile -t swap_list < <(swapon --show=name,size --bytes --noheadings 2>/dev/null || echo)
current_swap_total=0
swap_target=0

if [[ ${#swap_list[@]} -gt 0 ]]; then
    current_swap_total=$(printf '%s\n' "${swap_list[@]}" | awk '{sum+=$2} END{print sum}')
    swap_target=$(printf '%s\n' "${swap_list[@]}" | awk -v target="$SWAP_FILE" '$1 == target {print $2}')
fi

# 判断是否需要调整
needs_recreate() {
    # 情况1：不存在任何Swap
    [[ $current_swap_total -eq 0 ]] && return 0
    
    # 情况2：存在Swap但总大小不匹配
    [[ $current_swap_total -ne $((recommended_swap_mb * 1024**2)) ]] && return 0
    
    # 情况3：已存在Swap文件但大小不匹配
    [[ -n "$swap_target" && "$swap_target" -ne $((recommended_swap_mb * 1024**2)) ]] && return 0
    
    return 1
}

# 显示系统信息
echo "系统物理内存: ${mem_gb}GB"
echo "建议Swap大小: ${recommended_swap_mb}MB"

# 判断是否需要操作
if ! needs_recreate; then
    echo "✅ 当前Swap配置已符合最佳实践"
    exit 0
fi

# 交互确认
echo "⚠️ 当前Swap配置："
if [[ ${#swap_list[@]} -gt 0 ]]; then
    printf '%s\n' "${swap_list[@]}" | awk '{printf "  - %s: %dMB\n", $1, $2/1024/1024}'
else
    echo "  - 无Swap配置"
fi

read -p "是否调整Swap配置？(y/N) " -n 1 -r
echo
[[ $REPLY =~ ^[Yy]$ ]] || exit 0

# 执行Swap调整
echo "🛠  开始优化Swap配置..."
{
    # 禁用所有Swap
    swapoff -a 2>/dev/null || true
    
    # 清理旧Swap文件
    [[ -f "$SWAP_FILE" ]] && rm -f "$SWAP_FILE"
    
    # 创建新Swap文件
    dd if=/dev/zero of="$SWAP_FILE" bs=1M count="$recommended_swap_mb" status=progress
    chmod 600 "$SWAP_FILE"
    # 修改这里：移除了 -p 参数
    mkswap "$SWAP_FILE" >/dev/null
    
    # 启用新Swap并设置优先级
    swapon -p "$SWAP_PRIORITY" "$SWAP_FILE"
    
    # 更新fstab配置
    grep -v "^$SWAP_FILE" /etc/fstab > /etc/fstab.tmp
    echo "$SWAP_FILE none swap pri=$SWAP_PRIORITY 0 0" >> /etc/fstab.tmp
    mv /etc/fstab.tmp /etc/fstab
} || {
    echo "❌ 配置过程中发生错误，已回滚变更" >&2
    swapoff -a 2>/dev/null || true
    [[ -f "$SWAP_FILE" ]] && rm -f "$SWAP_FILE"
    exit 1
}

echo "🎉 Swap优化完成！新配置信息："
free -h
