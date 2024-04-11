#!/bin/bash

# 定义update_os函数
update_os() {
    echo "Updating OS to newer version..."
    
    # 安装Qt相关的开发包
    echo "Installing Qt development packages..."
    sudo apt-get install -y qtbase5-dev qtchooser qt5-qmake qtbase5-dev-tools
    
    # 检查上一条命令是否成功执行
    if [ $? -ne 0 ]; then
        echo "Failed to install Qt development packages. Exiting..."
        exit 1
    fi
    
    echo "Qt development packages installed successfully."
    
    # 在这里添加文件拷贝命令
    # 例子: sudo cp /path/to/source /path/to/destination
    echo "Copying necessary files..."
    # 确保替换下面的路径为你实际的文件路径
    # sudo cp /path/to/source /path/to/destination
    cd /home/pi/magnetox-os-update
    cp auto-uuid/*  ~/auto-uuid/
    chmod +x ~/auto-uuid/*.sh
    chmod +x ~/auto-uuid/MagnetoWifiHelper
    cp config/* ~/printer_data/config/
    cp KlipperScreen/* ~/KlipperScreen/panels/
    echo "Files copied successfully."

    echo "OS and applications have been updated."
}

# 第一步: 从URL获取版本号
current_version=$(curl -s http://127.0.0.1:8880/get_os_version | jq -r '.version')
echo "Current version from URL: $current_version"

# 第二步: 从文件读取版本号
file_version=$(cat version.txt)
echo "Version from file: $file_version"

# 提取具体的版本号字符串，例如v1.1.0或v1.1.1
version_from_url=$(echo $current_version | grep -o 'v[0-9]\+\.[0-9]\+\.[0-9]\+')
version_from_file=$(echo $file_version | grep -o 'v[0-9]\+\.[0-9]\+\.[0-9]\+')

# 第三步: 对比两个版本号
if [ "$(printf '%s\n' "$version_from_url" "$version_from_file" | sort -V | head -n 1)" == "$version_from_url" ]; then
    if [ "$version_from_url" == "$version_from_file" ]; then
        echo "Both versions are equal."
    else
        echo "$version_from_url is older than $version_from_file."
        # 当前版本较旧，需要更新
        update_os
    fi
else
    echo "$version_from_file is older than $version_from_url."
fi
