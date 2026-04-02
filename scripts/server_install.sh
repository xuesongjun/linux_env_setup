#!/bin/bash
# ==============================================================
# server_install.sh — CentOS 服务器端一键取包安装脚本
#
# 使用前提：
#   1. FTP 已配置自动登录（ftp get 无需输入密码）
#   2. 本地已通过 scripts/bundle_prepare.sh 生成包并上传到 FTP 服务器
#
# 用法：
#   bash server_install.sh <包文件名>
#   bash server_install.sh linux_env_setup_bundle_20260402.tar.gz
#
# 或直接设置 BUNDLE_FILE 变量后运行：
#   BUNDLE_FILE=linux_env_setup_bundle_20260402.tar.gz bash server_install.sh
# ==============================================================

set -euo pipefail

# ---- 配置：包文件名（命令行参数或环境变量，均未提供时列出可用文件）----
BUNDLE_FILE="${1:-${BUNDLE_FILE:-}}"

# ============================================================
# 确定包文件名
# ============================================================
if [[ -z "$BUNDLE_FILE" ]]; then
    echo "用法：bash server_install.sh <包文件名>"
    echo ""
    echo "示例：bash server_install.sh linux_env_setup_bundle_20260402.tar.gz"
    echo ""
    echo "提示：可先用 ftp ls 查看 FTP 服务器上的可用文件"
    exit 1
fi

echo ""
echo "=================================================="
echo "  CentOS 服务器安装脚本"
echo "=================================================="
echo ""
echo "[1/4] 从 FTP 获取安装包：$BUNDLE_FILE"
ftp get "$BUNDLE_FILE"

echo ""
echo "[2/4] 解压安装包..."
tar -xzf "$BUNDLE_FILE"

# 进入解压目录（目录名为包名去掉 .tar.gz 后的前缀）
INSTALL_DIR="linux_env_setup"
if [[ ! -d "$INSTALL_DIR" ]]; then
    # 尝试从 tar 中获取顶层目录名
    INSTALL_DIR=$(tar -tzf "$BUNDLE_FILE" | head -1 | cut -d/ -f1)
fi

echo ""
echo "[3/4] 进入目录：$INSTALL_DIR"
cd "$INSTALL_DIR"

echo ""
echo "[4/4] 开始安装（离线模式）..."
bash setup.sh --offline

echo ""
echo "=================================================="
echo "  安装完成！运行验证脚本："
echo "    bash test_setup.sh"
echo "=================================================="
