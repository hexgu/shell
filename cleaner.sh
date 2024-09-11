#!/bin/bash


if [[ $EUID -ne 0 ]]; then
   echo "此脚本必须以root权限运行" >&2
   exit 1
fi

get_used_space() {
    df -P / | awk 'NR==2 {print $3}'
}

calculate_cleared_space() {
    local start=$1
    local end=$2
    echo $((start - end))
}

start_space=$(get_used_space)

# 检查是否安装了 aptitude
if command -v aptitude >/dev/null 2>&1; then
    echo "使用 aptitude 作为包管理器"
    PKG_MANAGER="aptitude"
    CLEAN_CMD="aptitude clean"
    PKG_UPDATE_CMD="aptitude update"
    INSTALL_CMD="aptitude install -y"
    PURGE_CMD="aptitude purge -y"
else
    echo "aptitude 未安装，使用 apt 作为包管理器"
    PKG_MANAGER="apt"
    CLEAN_CMD="apt-get autoremove -y && apt-get clean"
    PKG_UPDATE_CMD="apt-get update"
    INSTALL_CMD="apt-get install -y"
    PURGE_CMD="apt-get purge -y"
fi

echo "正在更新依赖..."
$PKG_UPDATE_CMD >/dev/null 2>&1
if ! dpkg -s deborphan >/dev/null 2>&1; then
    $INSTALL_CMD deborphan >/dev/null 2>&1
fi

echo "正在删除未使用的内核..."
space_before=$(get_used_space)
current_kernel=$(uname -r)
kernel_packages=$(dpkg --list | awk '/^ii  linux-(image|headers)-[0-9]+/ && $2!~/'$current_kernel'/ {print $2}')
if [ -n "$kernel_packages" ]; then
    echo "找到旧内核，正在删除：$kernel_packages"
    $PURGE_CMD $kernel_packages >/dev/null 2>&1
    update-grub >/dev/null 2>&1
else
    echo "没有旧内核需要删除。"
fi
space_after=$(get_used_space)
cleared=$(calculate_cleared_space $space_before $space_after)
echo "删除旧内核清理了 $((cleared / 1024))M 空间"

echo "正在清理系统日志文件..."
space_before=$(get_used_space)
find /var/log -type f -name "*.log" -exec truncate -s 0 {} + 2>/dev/null
find /root -type f -name "*.log" -exec truncate -s 0 {} + 2>/dev/null
find /home -type f -name "*.log" -exec truncate -s 0 {} + 2>/dev/null
space_after=$(get_used_space)
cleared=$(calculate_cleared_space $space_before $space_after)
echo "清理日志文件节省了 $((cleared / 1024))M 空间"

echo "正在清理缓存目录..."
space_before=$(get_used_space)
find /tmp /var/tmp -type f -atime +1 -delete 2>/dev/null
find /home /root -maxdepth 2 -type d -name .cache -exec rm -rf {}/* \; 2>/dev/null
space_after=$(get_used_space)
cleared=$(calculate_cleared_space $space_before $space_after)
echo "清理缓存目录节省了 $((cleared / 1024))M 空间"

if command -v docker >/dev/null 2>&1; then
    echo "正在清理Docker镜像、容器和卷..."
    space_before=$(get_used_space)
    docker system prune -af --volumes >/dev/null 2>&1
    space_after=$(get_used_space)
    cleared=$(calculate_cleared_space $space_before $space_after)
    echo "清理Docker节省了 $((cleared / 1024))M 空间"
fi

echo "正在清理孤立包..."
space_before=$(get_used_space)
deborphan --guess-all | xargs -r $PURGE_CMD >/dev/null 2>&1
space_after=$(get_used_space)
cleared=$(calculate_cleared_space $space_before $space_after)
echo "清理孤立包节省了 $((cleared / 1024))M 空间"

echo "正在清理包管理器缓存..."
space_before=$(get_used_space)
$CLEAN_CMD >/dev/null 2>&1
space_after=$(get_used_space)
cleared=$(calculate_cleared_space $space_before $space_after)
echo "清理包管理器缓存节省了 $((cleared / 1024))M 空间"

end_space=$(get_used_space)
total_cleared=$(calculate_cleared_space $start_space $end_space)
echo "系统清理完成，总共清理了 $((total_cleared / 1024))M 空间！"
