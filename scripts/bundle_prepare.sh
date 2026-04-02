#!/usr/bin/env bash
# ==============================================================
# bundle_prepare.sh — 离线安装包打包脚本
#
# 在有网络的机器（WSL2 / Ubuntu）上执行：
#   ./scripts/bundle_prepare.sh
#
# 产出：
#   bundle/          — 所有组件（二进制、源码、插件）
#   linux_env_setup_bundle_YYYYMMDD.tar.gz  — 上传到 FTP 的单一文件
#
# 上传后在 CentOS 服务器执行：
#   ftp get linux_env_setup_bundle_YYYYMMDD.tar.gz
#   tar -xzf linux_env_setup_bundle_*.tar.gz
#   cd linux_env_setup
#   ./setup.sh --offline
# ==============================================================

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly BUNDLE_DIR="$SCRIPT_DIR/bundle"

# ============================================================
# 版本常量（与 setup.sh 保持一致）
# ============================================================
readonly PYTHON_VERSION="3.12.10"
# Neovim：打包时自动查询最新稳定版本号
readonly VERIBLE_VERSION="0.0-3793-g4294133e"
readonly ZSH_VERSION="5.9"
readonly FZF_VERSION="0.62.0"
readonly RG_VERSION="14.1.1"
readonly FD_VERSION="10.2.0"
readonly GH_VERSION="2.62.0"

# ============================================================
# 颜色与日志
# ============================================================
readonly C_BLUE='\033[0;34m'
readonly C_GREEN='\033[0;32m'
readonly C_YELLOW='\033[0;33m'
readonly C_RED='\033[0;31m'
readonly C_RESET='\033[0m'

log_step() { echo -e "${C_BLUE}[*] $*${C_RESET}"; }
log_ok()   { echo -e "${C_GREEN}[OK] $*${C_RESET}"; }
log_warn() { echo -e "${C_YELLOW}[WARN] $*${C_RESET}"; }
log_err()  { echo -e "${C_RED}[ERROR] $*${C_RESET}" >&2; }

# ============================================================
# 工具函数
# ============================================================
check_cmd() { command -v "$1" &>/dev/null; }

# 下载文件（带进度显示）
download() {
    local url="$1"
    local output="$2"
    echo "  → $(basename "$output")"
    if check_cmd curl; then
        curl -fL --retry 3 --progress-bar -o "$output" "$url"
    elif check_cmd wget; then
        wget -q --tries=3 --show-progress -O "$output" "$url"
    else
        log_err "需要 curl 或 wget"
        return 1
    fi
}

# 克隆并打包为 tarball（bundle/plugins/）
pack_git_repo() {
    local url="$1"
    local name="$2"
    local output="$BUNDLE_DIR/plugins/${name}.tar.gz"

    if [[ -f "$output" ]]; then
        log_ok "已存在，跳过：$name"
        return 0
    fi

    log_step "打包插件：$name"
    local tmp_dir
    tmp_dir=$(mktemp -d)
    git clone --depth=1 "$url" "$tmp_dir/$name" 2>/dev/null
    tar -czf "$output" -C "$tmp_dir" "$name"
    rm -rf "$tmp_dir"
    log_ok "  → plugins/${name}.tar.gz"
}

# 克隆整个仓库并打包（用于 pyenv 等较大的仓库）
pack_repo_as_bundle() {
    local url="$1"
    local name="$2"
    local output="$BUNDLE_DIR/${name}.tar.gz"

    if [[ -f "$output" ]]; then
        log_ok "已存在，跳过：$name"
        return 0
    fi

    log_step "打包仓库：$name"
    local tmp_dir
    tmp_dir=$(mktemp -d)
    git clone --depth=1 "$url" "$tmp_dir/$name" 2>/dev/null
    rm -rf "$tmp_dir/$name/.git"
    tar -czf "$output" -C "$tmp_dir" "$name"
    rm -rf "$tmp_dir"
    log_ok "  → ${name}.tar.gz ($(du -sh "$output" | cut -f1))"
}

# ============================================================
# 步骤 1：下载预编译静态链接二进制
# ============================================================
download_binaries() {
    log_step "步骤 1/6：下载预编译二进制..."
    mkdir -p "$BUNDLE_DIR"

    # ---- Starship（静态链接，兼容所有 Linux）----
    local starship_pkg="starship-x86_64-unknown-linux-musl.tar.gz"
    if [[ ! -f "$BUNDLE_DIR/$starship_pkg" ]]; then
        download \
            "https://github.com/starship/starship/releases/latest/download/$starship_pkg" \
            "$BUNDLE_DIR/$starship_pkg"
    else
        log_ok "已存在：$starship_pkg"
    fi

    # ---- Neovim AppImage（始终下载最新稳定版）----
    local nvim_pkg="nvim-linux-x86_64.appimage"
    # 通过 stable tag redirect 获取实际版本号，记录到 VERSIONS 文件
    local nvim_latest_ver=""
    nvim_latest_ver=$(curl -fsSI \
        "https://github.com/neovim/neovim/releases/download/stable/$nvim_pkg" \
        2>/dev/null | grep -i "^location:" | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | head -1 \
        || echo "stable")
    if [[ ! -f "$BUNDLE_DIR/$nvim_pkg" ]]; then
        download \
            "https://github.com/neovim/neovim/releases/download/stable/$nvim_pkg" \
            "$BUNDLE_DIR/$nvim_pkg"
    else
        log_ok "已存在：$nvim_pkg（$nvim_latest_ver）"
    fi
    # 记录版本到 VERSIONS 文件，供 setup.sh 离线版本检查使用
    echo "NEOVIM_VERSION=${nvim_latest_ver}" >> "$BUNDLE_DIR/VERSIONS"

    # ---- fzf ----
    local fzf_pkg="fzf-${FZF_VERSION}-linux_amd64.tar.gz"
    local fzf_bundle="fzf-linux_amd64.tar.gz"   # setup.sh 期待的文件名
    if [[ ! -f "$BUNDLE_DIR/$fzf_bundle" ]]; then
        download \
            "https://github.com/junegunn/fzf/releases/download/v${FZF_VERSION}/$fzf_pkg" \
            "$BUNDLE_DIR/$fzf_bundle"
    else
        log_ok "已存在：$fzf_bundle"
    fi

    # ---- ripgrep（静态链接）----
    local rg_pkg="ripgrep-${RG_VERSION}-x86_64-unknown-linux-musl.tar.gz"
    local rg_bundle="ripgrep-x86_64-unknown-linux-musl.tar.gz"
    if [[ ! -f "$BUNDLE_DIR/$rg_bundle" ]]; then
        download \
            "https://github.com/BurntSushi/ripgrep/releases/download/${RG_VERSION}/$rg_pkg" \
            "$BUNDLE_DIR/$rg_bundle"
    else
        log_ok "已存在：$rg_bundle"
    fi

    # ---- fd（静态链接）----
    local fd_pkg="fd-v${FD_VERSION}-x86_64-unknown-linux-musl.tar.gz"
    local fd_bundle="fd-x86_64-unknown-linux-musl.tar.gz"
    if [[ ! -f "$BUNDLE_DIR/$fd_bundle" ]]; then
        download \
            "https://github.com/sharkdp/fd/releases/download/v${FD_VERSION}/$fd_pkg" \
            "$BUNDLE_DIR/$fd_bundle"
    else
        log_ok "已存在：$fd_bundle"
    fi

    # ---- GitHub CLI (gh) ----
    local gh_pkg="gh_${GH_VERSION}_linux_amd64.tar.gz"
    if [[ ! -f "$BUNDLE_DIR/$gh_pkg" ]]; then
        download \
            "https://github.com/cli/cli/releases/download/v${GH_VERSION}/${gh_pkg}" \
            "$BUNDLE_DIR/$gh_pkg"
    else
        log_ok "已存在：$gh_pkg"
    fi

    # ---- Verible（静态链接）----
    local verible_pkg="verible-v${VERIBLE_VERSION}-linux-static-x86_64.tar.gz"
    if [[ ! -f "$BUNDLE_DIR/$verible_pkg" ]]; then
        download \
            "https://github.com/chipsalliance/verible/releases/download/v${VERIBLE_VERSION}/$verible_pkg" \
            "$BUNDLE_DIR/$verible_pkg"
    else
        log_ok "已存在：$verible_pkg"
    fi

    # ---- win32yank（WSL2 Neovim 剪贴板，仅 Windows 可执行文件）----
    local win32yank_pkg="win32yank-x64.zip"
    if [[ ! -f "$BUNDLE_DIR/$win32yank_pkg" ]]; then
        download \
            "https://github.com/equalsraf/win32yank/releases/latest/download/$win32yank_pkg" \
            "$BUNDLE_DIR/$win32yank_pkg"
    else
        log_ok "已存在：$win32yank_pkg"
    fi

    log_ok "步骤 1 完成"
}

# ============================================================
# 步骤 2：下载源码包（zsh、Python）
# ============================================================
download_sources() {
    log_step "步骤 2/6：下载源码包..."

    # ---- zsh 源码 ----
    local zsh_pkg="zsh-${ZSH_VERSION}.tar.xz"
    if [[ ! -f "$BUNDLE_DIR/$zsh_pkg" ]]; then
        download \
            "https://sourceforge.net/projects/zsh/files/zsh/${ZSH_VERSION}/${zsh_pkg}/download" \
            "$BUNDLE_DIR/$zsh_pkg"
    else
        log_ok "已存在：$zsh_pkg"
    fi

    # ---- Python 源码（pyenv cache 格式）----
    local py_pkg="Python-${PYTHON_VERSION}.tar.xz"
    if [[ ! -f "$BUNDLE_DIR/$py_pkg" ]]; then
        download \
            "https://www.python.org/ftp/python/${PYTHON_VERSION}/${py_pkg}" \
            "$BUNDLE_DIR/$py_pkg"
    else
        log_ok "已存在：$py_pkg"
    fi

    log_ok "步骤 2 完成"
}

# ============================================================
# 步骤 3：打包 Git 插件仓库
# ============================================================
pack_plugins() {
    log_step "步骤 3/6：打包 Git 插件..."
    mkdir -p "$BUNDLE_DIR/plugins"

    # Zsh 插件
    pack_git_repo "https://github.com/zsh-users/zsh-autosuggestions"   "zsh-autosuggestions"
    pack_git_repo "https://github.com/zsh-users/zsh-syntax-highlighting" "zsh-syntax-highlighting"
    pack_git_repo "https://github.com/zsh-users/zsh-completions"         "zsh-completions"

    # pyenv
    pack_repo_as_bundle "https://github.com/pyenv/pyenv.git" "pyenv"

    # fzf shell 集成脚本（从 fzf 仓库提取）
    _pack_fzf_shell_scripts

    log_ok "步骤 3 完成"
}

_pack_fzf_shell_scripts() {
    local output="$BUNDLE_DIR/plugins/fzf-shell.tar.gz"
    if [[ -f "$output" ]]; then
        log_ok "已存在：fzf-shell.tar.gz"
        return 0
    fi

    log_step "提取 fzf shell 集成脚本..."
    local tmp_dir
    tmp_dir=$(mktemp -d)
    git clone --depth=1 https://github.com/junegunn/fzf.git "$tmp_dir/fzf" 2>/dev/null

    mkdir -p "$tmp_dir/fzf-shell"
    # 运行 fzf install 生成 .fzf.zsh 和 .fzf.bash
    HOME="$tmp_dir/home" \
        bash "$tmp_dir/fzf/install" --all --no-update-rc &>/dev/null || true

    [[ -f "$tmp_dir/home/.fzf.zsh" ]]  && cp "$tmp_dir/home/.fzf.zsh"  "$tmp_dir/fzf-shell/fzf.zsh"
    [[ -f "$tmp_dir/home/.fzf.bash" ]] && cp "$tmp_dir/home/.fzf.bash" "$tmp_dir/fzf-shell/fzf.bash"

    tar -czf "$output" -C "$tmp_dir" "fzf-shell"
    rm -rf "$tmp_dir"
    log_ok "  → plugins/fzf-shell.tar.gz"
}

# ============================================================
# 步骤 4：预安装 Neovim 插件
# ============================================================
preinstall_nvim_plugins() {
    log_step "步骤 4/6：预安装 Neovim 插件（需要几分钟）..."

    local config_bundle="$BUNDLE_DIR/nvim-config.tar.gz"
    local plugins_bundle="$BUNDLE_DIR/nvim-plugins.tar.gz"

    if [[ -f "$config_bundle" && -f "$plugins_bundle" ]]; then
        log_ok "Neovim bundle 已存在，跳过（删除后可重新生成）"
        return 0
    fi

    # 检查 nvim 是否可用
    local nvim_bin
    nvim_bin=$(command -v nvim 2>/dev/null \
        || echo "$HOME/.local/bin/nvim")
    if [[ ! -x "$nvim_bin" ]]; then
        log_warn "nvim 未安装，跳过插件预安装"
        log_warn "  首次在服务器运行 nvim 时需要网络连接来安装插件"
        log_warn "  或先在 WSL2 运行 ./setup.sh 安装 nvim 后重新执行此脚本"
        return 0
    fi

    log_step "使用临时环境安装 LazyVim 插件..."

    # 创建隔离的临时 XDG 环境，避免影响本机配置
    local tmp_xdg
    tmp_xdg=$(mktemp -d)
    local tmp_config="$tmp_xdg/config"
    local tmp_data="$tmp_xdg/data"
    local tmp_state="$tmp_xdg/state"
    local tmp_cache="$tmp_xdg/cache"
    mkdir -p "$tmp_config" "$tmp_data" "$tmp_state" "$tmp_cache"

    # 克隆 LazyVim starter 到临时配置目录
    git clone https://github.com/LazyVim/starter "$tmp_config/nvim" 2>/dev/null
    rm -rf "$tmp_config/nvim/.git"

    # 注入 IC 插件配置
    mkdir -p "$tmp_config/nvim/lua/plugins"
    cp "$SCRIPT_DIR/configs/nvim-ic.lua" "$tmp_config/nvim/lua/plugins/ic.lua"

    # 在隔离环境中运行 nvim headless 安装插件
    log_step "安装 LazyVim 插件（headless）..."
    XDG_CONFIG_HOME="$tmp_config" \
    XDG_DATA_HOME="$tmp_data" \
    XDG_STATE_HOME="$tmp_state" \
    XDG_CACHE_HOME="$tmp_cache" \
        "$nvim_bin" --headless \
            "+Lazy! sync" \
            "+sleep 10" \
            "+qa" 2>&1 | grep -v "^$" | tail -20 || true

    log_ok "插件安装完成，开始打包..."

    # 打包配置
    tar -czf "$config_bundle" -C "$tmp_config" "nvim"
    log_ok "  → nvim-config.tar.gz ($(du -sh "$config_bundle" | cut -f1))"

    # 打包插件数据（lazy/ 目录）
    if [[ -d "$tmp_data/nvim" ]]; then
        tar -czf "$plugins_bundle" -C "$tmp_data" "nvim"
        log_ok "  → nvim-plugins.tar.gz ($(du -sh "$plugins_bundle" | cut -f1))"
    else
        log_warn "插件数据目录为空，可能安装失败"
        log_warn "检查 nvim 输出，或手动运行：nvim --headless '+Lazy! sync' +qa"
    fi

    rm -rf "$tmp_xdg"
    log_ok "步骤 4 完成"
}

# ============================================================
# 步骤 5：完整性校验
# ============================================================
verify_bundle() {
    log_step "步骤 5/6：完整性校验..."

    local required_files=(
        "starship-x86_64-unknown-linux-musl.tar.gz"
        "nvim-linux-x86_64.appimage"
        "fzf-linux_amd64.tar.gz"
        "ripgrep-x86_64-unknown-linux-musl.tar.gz"
        "fd-x86_64-unknown-linux-musl.tar.gz"
        "verible-v${VERIBLE_VERSION}-linux-static-x86_64.tar.gz"
        "gh_${GH_VERSION}_linux_amd64.tar.gz"
        "zsh-${ZSH_VERSION}.tar.xz"
        "Python-${PYTHON_VERSION}.tar.xz"
        "pyenv.tar.gz"
        "plugins/zsh-autosuggestions.tar.gz"
        "plugins/zsh-syntax-highlighting.tar.gz"
        "plugins/zsh-completions.tar.gz"
        "plugins/fzf-shell.tar.gz"
    )

    local optional_files=(
        "nvim-config.tar.gz"
        "nvim-plugins.tar.gz"
    )

    local missing=0
    local f
    for f in "${required_files[@]}"; do
        if [[ -f "$BUNDLE_DIR/$f" ]]; then
            printf "  %-55s %s\n" "$f" "$(du -sh "$BUNDLE_DIR/$f" | cut -f1)"
        else
            echo -e "  ${C_RED}[缺失]${C_RESET} $f"
            (( missing++ ))
        fi
    done

    echo ""
    echo "  可选文件（Neovim 离线插件）："
    for f in "${optional_files[@]}"; do
        if [[ -f "$BUNDLE_DIR/$f" ]]; then
            printf "  %-55s %s\n" "$f" "$(du -sh "$BUNDLE_DIR/$f" | cut -f1)"
        else
            echo -e "  ${C_YELLOW}[未生成]${C_RESET} $f（服务器首次运行 nvim 时需要网络）"
        fi
    done

    if [[ $missing -gt 0 ]]; then
        log_err "有 $missing 个必需文件缺失，请检查下载是否成功"
        return 1
    fi

    log_ok "步骤 5 完成：所有必需文件已就绪"
}

# ============================================================
# 步骤 6：打包为单一 tar.gz（供 FTP 上传）
# ============================================================
create_ftp_package() {
    log_step "步骤 6/6：创建 FTP 上传包..."

    local date_tag
    date_tag=$(date +%Y%m%d)
    local output_name="linux_env_setup_bundle_${date_tag}.tar.gz"
    local output_path="$(dirname "$SCRIPT_DIR")/$output_name"
    # 如果上层目录不可写，就放在项目目录旁
    [[ ! -w "$(dirname "$SCRIPT_DIR")" ]] && output_path="$SCRIPT_DIR/../$output_name"

    log_step "打包中（可能需要 1-3 分钟）..."

    # 将整个项目（含 bundle/）打包，排除不必要内容
    tar -czf "$output_path" \
        -C "$(dirname "$SCRIPT_DIR")" \
        --exclude="$(basename "$SCRIPT_DIR")/.git" \
        --exclude="$(basename "$SCRIPT_DIR")/research.md" \
        "$(basename "$SCRIPT_DIR")"

    local size
    size=$(du -sh "$output_path" | cut -f1)
    echo ""
    echo "================================================================"
    log_ok "打包完成！"
    echo ""
    echo "  文件：$output_path"
    echo "  大小：$size"
    echo ""
    echo "  上传到 FTP 中间服务器后，在 CentOS 服务器执行："
    echo ""
    echo "    ftp get $output_name"
    echo "    tar -xzf $output_name"
    echo "    cd linux_env_setup"
    echo "    ./setup.sh --offline"
    echo ""
    echo "  或使用 scripts/server_install.sh 一键完成取包+安装"
    echo "================================================================"
}

# ============================================================
# 主函数
# ============================================================
main() {
    echo ""
    echo "=================================================="
    echo "  Bundle 打包脚本（在有网络的机器上运行）"
    echo "=================================================="
    echo ""

    if [[ ! -d "$SCRIPT_DIR/configs" ]]; then
        log_err "请在项目根目录下运行：./scripts/bundle_prepare.sh"
        exit 1
    fi

    download_binaries
    echo ""
    download_sources
    echo ""
    pack_plugins
    echo ""
    preinstall_nvim_plugins
    echo ""
    verify_bundle
    echo ""
    create_ftp_package
}

main "$@"
