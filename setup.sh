#!/usr/bin/env bash
# ==============================================================
# linux_env_setup — Ubuntu 24.04 / WSL2 & CentOS 服务器 开发环境配置
# 面向数字 IC 工程师（Verilog/SV、Python、Perl）
#
# 用法：
#   ./setup.sh                      # 全量安装（在线，Ubuntu）
#   ./setup.sh --offline            # 离线安装（从 bundle/ 目录读取）
#   ./setup.sh --verilator-source   # Verilator 从源码编译（v5.x）
#   ./setup.sh --only zsh,neovim    # 只运行指定模块（逗号分隔）
#   ./setup.sh --skip eda_tools     # 跳过指定模块
# ==============================================================

set -euo pipefail

# ============================================================
# 版本常量（所有版本号统一在此定义）
# ============================================================
readonly PYTHON_VERSION="3.12.10"
readonly NVIM_MIN_VERSION="0.11.2"   # LazyVim 最低要求；在线模式自动装最新稳定版
readonly VERIBLE_VERSION="0.0-3793-g4294133e"
readonly ZSH_VERSION_SRC="5.9"
readonly GH_VERSION="2.62.0"
readonly NVM_VERSION="0.40.3"        # nvm 版本，用于安装最新 LTS Node.js

# ============================================================
# 路径常量（基于脚本所在目录，支持从任意目录调用）
# ============================================================
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly BUNDLE_DIR="$SCRIPT_DIR/bundle"
readonly CONFIGS_DIR="$SCRIPT_DIR/configs"

# ============================================================
# 颜色常量
# ============================================================
readonly C_BLUE='\033[0;34m'
readonly C_GREEN='\033[0;32m'
readonly C_YELLOW='\033[0;33m'
readonly C_RED='\033[0;31m'
readonly C_RESET='\033[0m'

# ============================================================
# 全局状态（由 detect_env / parse_args 初始化）
# ============================================================
IS_OFFLINE=false        # --offline 参数触发
VERILATOR_FROM_SOURCE=false
ONLY_MODULES=()
SKIP_MODULES=()

OS_TYPE=""              # ubuntu | centos | unknown
HAS_SUDO=false          # 当前用户是否有 sudo 权限
CSH_MODE=false          # 登录 shell 是否为 csh/tcsh

BACKUP_DIR=""           # 由 init_backup_dir 初始化，全局唯一时间戳
FAILED_MODULES=()

# ============================================================
# 日志函数
# ============================================================
log_step() { echo -e "${C_BLUE}[*] $*${C_RESET}"; }
log_ok()   { echo -e "${C_GREEN}[OK] $*${C_RESET}"; }
log_warn() { echo -e "${C_YELLOW}[WARN] $*${C_RESET}"; }
log_err()  { echo -e "${C_RED}[ERROR] $*${C_RESET}" >&2; }

# ============================================================
# 环境探测
# ============================================================
detect_env() {
    # ---- OS 类型 ----
    if [[ -f /etc/os-release ]]; then
        local os_id
        os_id=$(. /etc/os-release && echo "${ID:-unknown}")
        case "$os_id" in
            ubuntu|debian)                      OS_TYPE="ubuntu" ;;
            centos|rhel|rocky|almalinux|fedora) OS_TYPE="centos" ;;
            *)                                  OS_TYPE="unknown" ;;
        esac
    else
        OS_TYPE="unknown"
    fi

    # ---- sudo 权限 ----
    # 先用非交互模式试（无密码 sudo），失败时检查用户所在组
    if sudo -n true 2>/dev/null; then
        HAS_SUDO=true
    elif groups 2>/dev/null | grep -qE '\b(sudo|wheel|admin)\b'; then
        # 用户在 sudo 组，只是需要输入密码
        HAS_SUDO=true
    fi

    # ---- csh/tcsh 检测：查 /etc/passwd 中该用户的登录 shell ----
    local login_shell=""
    login_shell=$(getent passwd "${USER:-$(id -un)}" 2>/dev/null | cut -d: -f7) || true
    if [[ -z "$login_shell" ]]; then
        # getent 不可用时直接读 /etc/passwd
        login_shell=$(grep "^${USER:-$(id -un)}:" /etc/passwd 2>/dev/null | cut -d: -f7) || true
    fi
    if [[ "$login_shell" == *"csh"* || "$login_shell" == *"tcsh"* ]]; then
        CSH_MODE=true
    fi

    echo ""
    echo "  环境探测结果："
    echo "    OS      : $OS_TYPE"
    echo "    sudo    : $HAS_SUDO"
    echo "    csh模式 : $CSH_MODE"
    echo "    离线模式: $IS_OFFLINE"
    echo ""
}

# ============================================================
# 公共工具函数
# ============================================================

init_backup_dir() {
    BACKUP_DIR="$HOME/.config_backup/$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$BACKUP_DIR"
    log_ok "备份目录：$BACKUP_DIR"
}

backup_file() {
    local target="$1"
    if [[ -e "$target" ]]; then
        cp -r "$target" "$BACKUP_DIR/$(basename "$target")"
        log_ok "已备份：$target → $BACKUP_DIR/"
    fi
}

install_config() {
    local src="$1"
    local dst="$2"
    backup_file "$dst"
    mkdir -p "$(dirname "$dst")"
    cp "$src" "$dst"
    log_ok "已安装：$(basename "$src") → $dst"
}

check_cmd() { command -v "$1" &>/dev/null; }

need_sudo() {
    if [[ "$HAS_SUDO" != "true" ]]; then
        log_warn "无 sudo 权限，跳过需要 root 的步骤"
        return 1
    fi
}

# 在线下载（curl 优先，次选 wget）
download() {
    local url="$1"
    local output="$2"
    if check_cmd curl; then
        curl -fsSL --retry 3 -o "$output" "$url"
    elif check_cmd wget; then
        wget -q --tries=3 -O "$output" "$url"
    else
        log_err "curl 和 wget 均不可用"
        return 1
    fi
}

# 获取文件：在线时下载，离线时从 bundle/ 读取
# 用法：fetch_file <url> <输出路径> [bundle内文件名（默认取url basename）]
fetch_file() {
    local url="$1"
    local output="$2"
    local bundle_filename="${3:-$(basename "$url")}"

    if [[ "$IS_OFFLINE" == "true" ]]; then
        local bundle_path="$BUNDLE_DIR/$bundle_filename"
        if [[ -f "$bundle_path" ]]; then
            cp "$bundle_path" "$output"
            return 0
        else
            log_err "离线模式缺少文件：$bundle_path"
            log_err "请先在有网络的机器执行：./scripts/bundle_prepare.sh"
            return 1
        fi
    else
        download "$url" "$output"
    fi
}

# 克隆仓库或从 bundle/plugins/ 解压 tarball
# 用法：clone_or_extract <git_url> <目标目录> <bundle内tarball文件名>
clone_or_extract() {
    local url="$1"
    local dest="$2"
    local bundle_tarball="$3"

    if [[ "$IS_OFFLINE" == "true" ]]; then
        local bundle_path="$BUNDLE_DIR/plugins/$bundle_tarball"
        if [[ ! -f "$bundle_path" ]]; then
            log_err "离线模式缺少插件包：$bundle_path"
            return 1
        fi
        local parent
        parent=$(dirname "$dest")
        local target_name
        target_name=$(basename "$dest")
        mkdir -p "$parent"
        # 解压，然后将顶层目录重命名为目标名
        local tmp_extract
        tmp_extract=$(mktemp -d)
        tar -xzf "$bundle_path" -C "$tmp_extract"
        local extracted_name
        extracted_name=$(ls "$tmp_extract" | head -1)
        mv "$tmp_extract/$extracted_name" "$dest"
        rm -rf "$tmp_extract"
    else
        git clone --depth=1 "$url" "$dest"
    fi
}

# 版本号比较：$1 >= $2 时返回 0
_version_gte() {
    printf '%s\n%s\n' "$2" "$1" | sort -V -C
}

# 从已安装的 nvim 提取版本号（如 "0.11.2"）
_nvim_installed_version() {
    local bin="$1"
    "$bin" --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+'
}

should_run() {
    local module="$1"
    if [[ ${#ONLY_MODULES[@]} -gt 0 ]]; then
        local m
        for m in "${ONLY_MODULES[@]}"; do
            [[ "$m" == "$module" ]] && return 0
        done
        return 1
    fi
    local s
    for s in "${SKIP_MODULES[@]}"; do
        [[ "$s" == "$module" ]] && return 1
    done
    return 0
}

# ============================================================
# 模块 1：基础依赖
# ============================================================
setup_prerequisites() {
    log_step "模块 1/9：基础依赖..."

    if [[ "$OS_TYPE" == "ubuntu" ]] && [[ "$HAS_SUDO" == "true" ]]; then
        # 超时 10 秒/源，避免单个慢源（如 nodesource）卡住整个 update
        sudo apt-get update -y \
            -o Acquire::http::Timeout=10 \
            -o Acquire::https::Timeout=10 \
            -o APT::Update::Error-Mode=any \
            || log_warn "apt-get update 部分源失败，继续安装"
        sudo apt-get upgrade -y

        # 生成 en_US.UTF-8 locale（WSL2 默认未生成，导致 setlocale 警告）
        if ! locale -a 2>/dev/null | grep -q "en_US.utf8"; then
            log_step "生成 en_US.UTF-8 locale..."
            sudo apt-get install -y locales
            sudo locale-gen en_US.UTF-8
            sudo update-locale LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8
            log_ok "locale 生成完成"
        else
            log_ok "en_US.UTF-8 locale 已存在"
        fi

        local packages=(
            git curl wget build-essential pkg-config
            libssl-dev zlib1g-dev libbz2-dev libreadline-dev
            libsqlite3-dev libffi-dev liblzma-dev libncurses-dev
            ca-certificates gnupg unzip xz-utils zip
            autoconf flex bison help2man
        )
        sudo apt-get install -y "${packages[@]}"
        log_ok "Ubuntu 基础依赖安装完成"

    elif [[ "$OS_TYPE" == "centos" ]] && [[ "$HAS_SUDO" == "true" ]]; then
        sudo yum install -y \
            git curl wget gcc gcc-c++ make pkgconfig \
            openssl-devel zlib-devel bzip2-devel readline-devel \
            sqlite-devel libffi-devel xz-devel ncurses-devel \
            ca-certificates unzip autoconf flex bison
        log_ok "CentOS 基础依赖安装完成"

    elif [[ "$HAS_SUDO" == "false" ]]; then
        log_warn "无 sudo 权限，跳过系统包安装"
        log_warn "请确认以下编译依赖已由管理员安装："
        log_warn "  gcc make zlib-devel bzip2-devel openssl-devel"
        log_warn "  readline-devel sqlite-devel libffi-devel xz-devel"
    fi
}

# ============================================================
# 模块 2：Zsh + 插件
# ============================================================
setup_zsh() {
    log_step "模块 2/9：配置 Zsh..."

    # ---- 确保 zsh 可用 ----
    local zsh_bin
    zsh_bin=$(command -v zsh 2>/dev/null || echo "")

    if [[ -z "$zsh_bin" ]]; then
        # 系统无 zsh，需要安装
        if [[ "$OS_TYPE" == "ubuntu" ]] && [[ "$HAS_SUDO" == "true" ]]; then
            sudo apt-get install -y zsh
            zsh_bin=$(command -v zsh)

        elif [[ "$OS_TYPE" == "centos" ]] && [[ "$HAS_SUDO" == "true" ]]; then
            sudo yum install -y zsh 2>/dev/null || true
            zsh_bin=$(command -v zsh 2>/dev/null || echo "")
            # yum 可能没有 zsh，降级到源码编译
            [[ -z "$zsh_bin" ]] && _compile_zsh && zsh_bin="$HOME/.local/bin/zsh"

        else
            # 无 sudo，从源码编译（CentOS 有编译工具）
            _compile_zsh
            zsh_bin="$HOME/.local/bin/zsh"
        fi
    else
        log_ok "系统 zsh 已存在：$zsh_bin"
    fi

    [[ -z "$zsh_bin" || ! -x "$zsh_bin" ]] && { log_err "zsh 安装失败"; return 1; }

    # ---- 设置默认 shell ----
    if [[ "$CSH_MODE" == "true" ]]; then
        # csh/tcsh 环境：在 .cshrc/.tcshrc 末尾追加 exec 切换
        _setup_csh_to_zsh "$zsh_bin"
    elif [[ "$SHELL" != "$zsh_bin" ]]; then
        if [[ "$HAS_SUDO" == "true" ]]; then
            # 确保 zsh 在 /etc/shells 中
            grep -q "$zsh_bin" /etc/shells 2>/dev/null || echo "$zsh_bin" | sudo tee -a /etc/shells
            chsh -s "$zsh_bin"
            log_ok "已将 zsh 设为默认 shell（下次登录生效）"
        else
            log_warn "无 sudo 权限，无法 chsh；请手动执行：chsh -s $zsh_bin"
        fi
    else
        log_ok "zsh 已是默认 shell"
    fi

    # ---- 安装插件 ----
    local plugin_dir="$HOME/.zsh"
    mkdir -p "$plugin_dir"

    local -A plugins=(
        ["zsh-autosuggestions"]="https://github.com/zsh-users/zsh-autosuggestions"
        ["zsh-syntax-highlighting"]="https://github.com/zsh-users/zsh-syntax-highlighting"
        ["zsh-completions"]="https://github.com/zsh-users/zsh-completions"
    )

    local name url
    for name in "${!plugins[@]}"; do
        url="${plugins[$name]}"
        if [[ -d "$plugin_dir/$name" ]]; then
            if [[ "$IS_OFFLINE" == "false" ]]; then
                git -C "$plugin_dir/$name" pull --ff-only 2>/dev/null \
                    || log_warn "$name 更新失败，保留现有版本"
            else
                log_ok "插件已存在（离线模式跳过更新）：$name"
            fi
        else
            clone_or_extract "$url" "$plugin_dir/$name" "${name}.tar.gz" || {
                log_warn "插件安装失败，跳过：$name"
                continue
            }
            log_ok "已安装插件：$name"
        fi
    done

    install_config "$CONFIGS_DIR/zshrc" "$HOME/.zshrc"
    log_ok "Zsh 配置完成"
}

# 从源码编译 zsh（CentOS 无 sudo 场景）
_compile_zsh() {
    log_step "从源码编译 zsh ${ZSH_VERSION_SRC}..."

    local zsh_tarball="zsh-${ZSH_VERSION_SRC}.tar.xz"
    local zsh_url="https://sourceforge.net/projects/zsh/files/zsh/${ZSH_VERSION_SRC}/${zsh_tarball}/download"
    local tmp_dir
    tmp_dir=$(mktemp -d)

    fetch_file "$zsh_url" "$tmp_dir/$zsh_tarball" "$zsh_tarball" || {
        rm -rf "$tmp_dir"
        return 1
    }

    tar -xJf "$tmp_dir/$zsh_tarball" -C "$tmp_dir"
    local zsh_src
    zsh_src=$(find "$tmp_dir" -maxdepth 1 -type d -name "zsh-*" | head -1)

    cd "$zsh_src"
    ./configure --prefix="$HOME/.local" \
        --enable-multibyte \
        --without-tcsetpgrp \
        --quiet
    make -j"$(nproc)" --silent
    make install --silent
    cd - >/dev/null
    rm -rf "$tmp_dir"

    log_ok "zsh 编译完成：$HOME/.local/bin/zsh"
}

# 在 csh/tcsh 配置文件中追加 exec zsh（幂等）
_setup_csh_to_zsh() {
    local zsh_bin="$1"
    local marker="# linux_env_setup: switch to zsh"

    # 优先 .tcshrc，次选 .cshrc
    local csh_config
    if [[ -f "$HOME/.tcshrc" ]]; then
        csh_config="$HOME/.tcshrc"
    else
        csh_config="$HOME/.cshrc"
    fi

    if grep -qF "$marker" "$csh_config" 2>/dev/null; then
        log_ok "csh → zsh 切换已配置（$csh_config）"
        return 0
    fi

    backup_file "$csh_config"

    # 用 printf 避免 heredoc 中 $ 扩展问题
    printf '\n%s\nif ( -x %s ) exec %s -l\n' \
        "$marker" "$zsh_bin" "$zsh_bin" >> "$csh_config"

    log_ok "已在 $csh_config 中添加 zsh 自动切换"
    log_warn "重新登录后 shell 将自动切换到 zsh"
}

# ============================================================
# 模块 3：Starship 提示符
# ============================================================
setup_starship() {
    log_step "模块 3/9：安装 Starship..."

    if check_cmd starship; then
        log_ok "Starship 已安装（$(starship --version)），跳过"
    else
        mkdir -p "$HOME/.local/bin"
        if [[ "$IS_OFFLINE" == "true" ]]; then
            # 离线：使用 bundle 中的静态链接二进制
            local bundle_path="$BUNDLE_DIR/starship-x86_64-unknown-linux-musl.tar.gz"
            if [[ ! -f "$bundle_path" ]]; then
                log_err "离线模式缺少 Starship 包：$bundle_path"
                return 1
            fi
            local tmp_dir
            tmp_dir=$(mktemp -d)
            tar -xzf "$bundle_path" -C "$tmp_dir"
            mv "$tmp_dir/starship" "$HOME/.local/bin/starship"
            chmod +x "$HOME/.local/bin/starship"
            rm -rf "$tmp_dir"
        else
            # 在线：官方安装脚本
            local install_script
            install_script=$(mktemp)
            if download "https://starship.rs/install.sh" "$install_script"; then
                chmod +x "$install_script"
                sh "$install_script" --yes --bin-dir "$HOME/.local/bin"
                rm -f "$install_script"
            else
                log_warn "无法下载 Starship，请手动安装：https://starship.rs"
                return 1
            fi
        fi
    fi

    install_config "$CONFIGS_DIR/starship.toml" "$HOME/.config/starship.toml"
    log_ok "Starship 配置完成"
}

# ============================================================
# 模块 4：fzf 模糊搜索
# ============================================================
setup_fzf() {
    log_step "模块 4/9：安装 fzf..."

    if [[ "$IS_OFFLINE" == "true" ]]; then
        # 离线：从 bundle 中解压预编译二进制
        local bundle_path="$BUNDLE_DIR/fzf-linux_amd64.tar.gz"
        if [[ ! -f "$bundle_path" ]]; then
            log_err "离线模式缺少 fzf 包：$bundle_path"
            return 1
        fi
        mkdir -p "$HOME/.local/bin"
        local tmp_dir
        tmp_dir=$(mktemp -d)
        tar -xzf "$bundle_path" -C "$tmp_dir"
        mv "$tmp_dir/fzf" "$HOME/.local/bin/fzf"
        chmod +x "$HOME/.local/bin/fzf"
        rm -rf "$tmp_dir"
        log_ok "fzf 安装完成（离线）"

        # 安装 fzf shell 集成脚本（从 bundle/plugins/fzf-shell.tar.gz）
        _install_fzf_shell_integration
    else
        # 在线：克隆仓库安装
        if [[ -d "$HOME/.fzf" ]]; then
            git -C "$HOME/.fzf" pull --ff-only 2>/dev/null \
                || log_warn "fzf 更新失败，保留现有版本"
        else
            git clone --depth=1 https://github.com/junegunn/fzf.git "$HOME/.fzf" || {
                log_err "克隆 fzf 失败"
                return 1
            }
        fi
        "$HOME/.fzf/install" --all --no-update-rc 2>/dev/null || true
    fi

    log_ok "fzf 配置完成"
}

# 安装 fzf 的 shell 集成脚本（.fzf.zsh 等），离线时从 bundle 获取
_install_fzf_shell_integration() {
    local bundle_path="$BUNDLE_DIR/plugins/fzf-shell.tar.gz"
    if [[ -f "$bundle_path" ]]; then
        local tmp_dir
        tmp_dir=$(mktemp -d)
        tar -xzf "$bundle_path" -C "$tmp_dir"
        [[ -f "$tmp_dir/fzf.zsh" ]]  && cp "$tmp_dir/fzf.zsh"  "$HOME/.fzf.zsh"
        [[ -f "$tmp_dir/fzf.bash" ]] && cp "$tmp_dir/fzf.bash" "$HOME/.fzf.bash"
        rm -rf "$tmp_dir"
        log_ok "fzf shell 集成脚本已安装"
    else
        log_warn "未找到 fzf shell 集成包，Ctrl+R/Ctrl+T 快捷键可能不可用"
    fi
}

# ============================================================
# 模块 5：开发工具（ripgrep / fd / git 配置）
# ============================================================
setup_dev_tools() {
    log_step "模块 5/9：配置开发工具..."

    mkdir -p "$HOME/.local/bin"

    # ---- ripgrep ----
    if check_cmd rg; then
        log_ok "ripgrep 已安装"
    elif [[ "$IS_OFFLINE" == "true" ]] || [[ "$HAS_SUDO" == "false" ]]; then
        _install_static_binary \
            "https://github.com/BurntSushi/ripgrep/releases/download/14.1.1/ripgrep-14.1.1-x86_64-unknown-linux-musl.tar.gz" \
            "ripgrep-x86_64-unknown-linux-musl.tar.gz" \
            "rg"
    else
        sudo apt-get install -y ripgrep 2>/dev/null \
            || sudo yum install -y ripgrep 2>/dev/null \
            || _install_static_binary \
                "https://github.com/BurntSushi/ripgrep/releases/download/14.1.1/ripgrep-14.1.1-x86_64-unknown-linux-musl.tar.gz" \
                "ripgrep-x86_64-unknown-linux-musl.tar.gz" \
                "rg"
    fi

    # ---- fd ----
    if check_cmd fd || check_cmd fdfind; then
        log_ok "fd 已安装"
    elif [[ "$IS_OFFLINE" == "true" ]] || [[ "$HAS_SUDO" == "false" ]]; then
        _install_static_binary \
            "https://github.com/sharkdp/fd/releases/download/v10.2.0/fd-v10.2.0-x86_64-unknown-linux-musl.tar.gz" \
            "fd-x86_64-unknown-linux-musl.tar.gz" \
            "fd"
    else
        sudo apt-get install -y fd-find 2>/dev/null \
            || sudo yum install -y fd-find 2>/dev/null \
            || _install_static_binary \
                "https://github.com/sharkdp/fd/releases/download/v10.2.0/fd-v10.2.0-x86_64-unknown-linux-musl.tar.gz" \
                "fd-x86_64-unknown-linux-musl.tar.gz" \
                "fd"
        # Ubuntu 包名为 fdfind，创建软链接
        local fdfind_bin
        fdfind_bin=$(command -v fdfind 2>/dev/null || true)
        if [[ -n "$fdfind_bin" ]] && ! check_cmd fd; then
            ln -sf "$fdfind_bin" "$HOME/.local/bin/fd"
        fi
    fi

    # ---- GitHub CLI (gh) ----
    if check_cmd gh; then
        log_ok "gh 已安装（$(gh --version | head -1)）"
    elif [[ "$OS_TYPE" == "ubuntu" ]] && [[ "$HAS_SUDO" == "true" ]] && [[ "$IS_OFFLINE" == "false" ]]; then
        # Ubuntu 在线：官方 apt 仓库
        log_step "安装 GitHub CLI (gh)..."
        local keyring="/usr/share/keyrings/githubcli-archive-keyring.gpg"
        curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
            | sudo dd of="$keyring" 2>/dev/null
        sudo chmod go+r "$keyring"
        echo "deb [arch=$(dpkg --print-architecture) signed-by=$keyring] https://cli.github.com/packages stable main" \
            | sudo tee /etc/apt/sources.list.d/github-cli.list >/dev/null
        sudo apt-get update -y -q
        sudo apt-get install -y gh
        log_ok "gh 安装完成（$(gh --version | head -1)）"
    else
        # CentOS / 无 sudo / 离线：预编译二进制
        local gh_pkg="gh_${GH_VERSION}_linux_amd64.tar.gz"
        local gh_url="https://github.com/cli/cli/releases/download/v${GH_VERSION}/${gh_pkg}"
        _install_static_binary "$gh_url" "$gh_pkg" "gh" \
            || log_warn "gh 安装失败，可手动下载：https://github.com/cli/cli/releases"
    fi

    # ---- win32yank（WSL2 Neovim 系统剪贴板集成）----
    if [[ -n "${WSL_DISTRO_NAME:-}" ]]; then
        if check_cmd win32yank.exe; then
            log_ok "win32yank 已安装"
        else
            log_step "安装 win32yank（Neovim WSL2 剪贴板支持）..."
            local zip_url="https://github.com/equalsraf/win32yank/releases/latest/download/win32yank-x64.zip"
            local tmp_zip
            tmp_zip=$(mktemp --suffix=.zip)
            if fetch_file "$zip_url" "$tmp_zip" "win32yank-x64.zip"; then
                local tmp_dir
                tmp_dir=$(mktemp -d)
                unzip -q "$tmp_zip" -d "$tmp_dir"
                cp "$tmp_dir/win32yank.exe" "$HOME/.local/bin/win32yank.exe"
                chmod +x "$HOME/.local/bin/win32yank.exe"
                rm -rf "$tmp_zip" "$tmp_dir"
                log_ok "win32yank 安装完成"
            else
                log_warn "win32yank 安装失败，Neovim 剪贴板功能不可用"
            fi
        fi
    fi

    # ---- git 全局配置（只在未设置时写入） ----
    [[ -z "$(git config --global core.editor 2>/dev/null)" ]] \
        && git config --global core.editor nvim
    [[ -z "$(git config --global init.defaultBranch 2>/dev/null)" ]] \
        && git config --global init.defaultBranch main
    [[ -z "$(git config --global pull.rebase 2>/dev/null)" ]] \
        && git config --global pull.rebase false

    log_ok "开发工具配置完成"
}

# 安装静态链接预编译二进制（从在线 URL 或 bundle/）
# 用法：_install_static_binary <url> <bundle文件名> <要安装的命令名>
_install_static_binary() {
    local url="$1"
    local bundle_filename="$2"
    local cmd_name="$3"

    local tmp_dir
    tmp_dir=$(mktemp -d)
    local tarball="$tmp_dir/$bundle_filename"

    fetch_file "$url" "$tarball" "$bundle_filename" || {
        rm -rf "$tmp_dir"
        return 1
    }

    tar -xzf "$tarball" -C "$tmp_dir"
    # 在解压目录中查找同名可执行文件
    local binary
    binary=$(find "$tmp_dir" -type f -name "$cmd_name" -not -name "*.1" | head -1)
    if [[ -z "$binary" ]]; then
        log_err "在包中未找到可执行文件：$cmd_name"
        rm -rf "$tmp_dir"
        return 1
    fi
    cp "$binary" "$HOME/.local/bin/$cmd_name"
    chmod +x "$HOME/.local/bin/$cmd_name"
    rm -rf "$tmp_dir"
    log_ok "已安装：$cmd_name → ~/.local/bin/"
}

# ============================================================
# 模块 6：Neovim + LazyVim + IC 配置
# ============================================================
setup_neovim() {
    log_step "模块 6/9：安装 Neovim..."

    local nvim_bin="$HOME/.local/bin/nvim"
    mkdir -p "$HOME/.local/bin"

    # ---- 安装 Neovim 二进制 ----
    # 在线模式：始终下载最新稳定版（stable tag）
    # 版本检查：已安装版本满足最低要求（>= NVIM_MIN_VERSION）则跳过
    local need_install=true
    if [[ -x "$nvim_bin" ]]; then
        local installed_ver
        installed_ver=$(_nvim_installed_version "$nvim_bin")
        if _version_gte "$installed_ver" "$NVIM_MIN_VERSION"; then
            log_ok "Neovim $installed_ver 已安装（满足 >= $NVIM_MIN_VERSION）"
            need_install=false
        else
            log_warn "Neovim $installed_ver 版本过旧（需要 >= $NVIM_MIN_VERSION），升级..."
        fi
    fi

    if [[ "$need_install" == "true" ]]; then
        # 在线：stable tag 始终指向最新稳定版，无需写死版本号
        # 离线：从 bundle/ 读取打包时的 AppImage
        local nvim_url="https://github.com/neovim/neovim/releases/download/stable/nvim-linux-x86_64.appimage"
        local tmp_appimage
        tmp_appimage=$(mktemp --suffix=.appimage)

        fetch_file "$nvim_url" "$tmp_appimage" "nvim-linux-x86_64.appimage" || return 1
        chmod +x "$tmp_appimage"

        # 尝试直接运行 AppImage（需要 FUSE）
        if "$tmp_appimage" --version &>/dev/null; then
            mv "$tmp_appimage" "$nvim_bin"
        else
            # FUSE 不可用（WSL2/CentOS 常见），改用解压模式
            log_warn "FUSE 不可用，切换到解压模式..."
            local extract_dir="$HOME/.local/nvim-appimage"
            rm -rf "$extract_dir"
            mkdir -p "$extract_dir"
            cd "$extract_dir"
            "$tmp_appimage" --appimage-extract &>/dev/null || true
            rm -f "$tmp_appimage"
            cd - >/dev/null
            local nvim_extracted="$extract_dir/squashfs-root/usr/bin/nvim"
            if [[ ! -x "$nvim_extracted" ]]; then
                log_err "Neovim 解压失败"
                return 1
            fi
            ln -sf "$nvim_extracted" "$nvim_bin"
        fi
        local new_ver
        new_ver=$(_nvim_installed_version "$nvim_bin" 2>/dev/null || echo "unknown")
        log_ok "Neovim v${new_ver} 安装完成"
    fi

    # ---- 安装 Node.js（通过 nvm，用户级安装，不需要 sudo 也不加 apt 外部源）----
    # 使用 nvm 而非 NodeSource：避免在 /etc/apt/sources.list.d/ 添加外部源，
    # 从而防止每次 apt-get update 都去连 deb.nodesource.com 导致卡顿
    _setup_node_via_nvm() {
        local nvm_dir="$HOME/.nvm"
        local nvm_init="$nvm_dir/nvm.sh"

        # 检查 nvm 是否已安装
        if [[ -s "$nvm_init" ]]; then
            source "$nvm_init" --no-use 2>/dev/null
            if command -v node &>/dev/null; then
                log_ok "Node.js 已安装（$(node --version)，via nvm）"
                return 0
            fi
        fi

        log_step "安装 nvm v${NVM_VERSION}..."
        local nvm_install_script
        nvm_install_script=$(mktemp)
        download \
            "https://raw.githubusercontent.com/nvm-sh/nvm/v${NVM_VERSION}/install.sh" \
            "$nvm_install_script" \
            || { log_warn "nvm 下载失败，跳过 Node.js 安装"; rm -f "$nvm_install_script"; return 1; }

        # PROFILE=/dev/null 阻止 nvm 安装脚本自动修改 .bashrc/.zshrc（我们手动管理）
        PROFILE=/dev/null bash "$nvm_install_script"
        rm -f "$nvm_install_script"

        # 加载 nvm 并安装最新 LTS
        export NVM_DIR="$nvm_dir"
        source "$nvm_init" --no-use 2>/dev/null
        log_step "安装 Node.js LTS（最新稳定版）..."
        nvm install --lts \
            && nvm use --lts \
            && nvm alias default 'lts/*' \
            && log_ok "Node.js 安装完成（$(node --version)）" \
            || log_warn "Node.js 安装失败，部分 LSP/npm 功能不可用"
    }

    if [[ "$IS_OFFLINE" == "false" ]]; then
        _setup_node_via_nvm
    else
        log_warn "离线模式：跳过 Node.js 安装（nvm 需要网络），部分 LSP 可能不可用"
    fi

    # ---- 安装 LazyVim 配置 ----
    local nvim_config="$HOME/.config/nvim"

    if [[ "$IS_OFFLINE" == "true" ]]; then
        _install_nvim_offline "$nvim_config"
    else
        _install_nvim_online "$nvim_config"
    fi

    # ---- 安装 IC 插件配置 ----
    local plugins_dir="$nvim_config/lua/plugins"
    mkdir -p "$plugins_dir"
    cp "$CONFIGS_DIR/nvim-ic.lua" "$plugins_dir/ic.lua"
    log_ok "IC 插件配置已安装 → $plugins_dir/ic.lua"

    log_ok "Neovim 配置完成（首次运行 nvim 时 LazyVim 将完成初始化）"
}

_install_nvim_online() {
    local nvim_config="$1"
    if [[ -d "$nvim_config" ]]; then
        if grep -q "LazyVim" "$nvim_config/lua/config/lazy.lua" 2>/dev/null; then
            log_ok "LazyVim 已安装"
            return 0
        else
            log_warn "检测到非 LazyVim 配置，备份并替换..."
            backup_file "$nvim_config"
            rm -rf "$nvim_config"
        fi
    fi
    git clone https://github.com/LazyVim/starter "$nvim_config" || return 1
    rm -rf "$nvim_config/.git"
}

_install_nvim_offline() {
    local nvim_config="$1"

    # 离线：从 bundle 解压预构建的配置和插件
    local config_bundle="$BUNDLE_DIR/nvim-config.tar.gz"
    local plugins_bundle="$BUNDLE_DIR/nvim-plugins.tar.gz"

    if [[ ! -f "$config_bundle" || ! -f "$plugins_bundle" ]]; then
        log_err "离线模式缺少 Neovim bundle 文件"
        log_err "  需要：$config_bundle"
        log_err "  需要：$plugins_bundle"
        return 1
    fi

    # 安装配置
    if [[ -d "$nvim_config" ]]; then
        backup_file "$nvim_config"
        rm -rf "$nvim_config"
    fi
    mkdir -p "$HOME/.config"
    local tmp_dir
    tmp_dir=$(mktemp -d)
    tar -xzf "$config_bundle" -C "$tmp_dir"
    # bundle 内顶层目录 → nvim
    local top_dir
    top_dir=$(ls "$tmp_dir" | head -1)
    mv "$tmp_dir/$top_dir" "$nvim_config"
    rm -rf "$tmp_dir"

    # 解压预安装的插件（lazy/ 目录）
    mkdir -p "$HOME/.local/share/nvim"
    tar -xzf "$plugins_bundle" -C "$HOME/.local/share/nvim"

    log_ok "Neovim 离线配置已恢复（插件无需重新下载）"
}

# ============================================================
# 模块 7：pyenv + Python
# ============================================================
setup_pyenv() {
    log_step "模块 7/9：安装 pyenv + Python ${PYTHON_VERSION}..."

    # ---- 安装 pyenv 本身 ----
    if [[ -d "$HOME/.pyenv" ]]; then
        if [[ "$IS_OFFLINE" == "false" ]]; then
            git -C "$HOME/.pyenv" pull --ff-only 2>/dev/null \
                || log_warn "pyenv 更新失败，保留现有版本"
        else
            log_ok "pyenv 已存在（离线模式跳过更新）"
        fi
    else
        if [[ "$IS_OFFLINE" == "true" ]]; then
            # 离线：从 bundle 解压 pyenv
            local pyenv_bundle="$BUNDLE_DIR/pyenv.tar.gz"
            if [[ ! -f "$pyenv_bundle" ]]; then
                log_err "离线模式缺少 pyenv 包：$pyenv_bundle"
                return 1
            fi
            local tmp_dir
            tmp_dir=$(mktemp -d)
            tar -xzf "$pyenv_bundle" -C "$tmp_dir"
            local top_dir
            top_dir=$(ls "$tmp_dir" | head -1)
            mv "$tmp_dir/$top_dir" "$HOME/.pyenv"
            rm -rf "$tmp_dir"
        else
            git clone https://github.com/pyenv/pyenv.git "$HOME/.pyenv" || return 1
        fi
    fi

    # 临时将 pyenv 加入 PATH
    export PYENV_ROOT="$HOME/.pyenv"
    export PATH="$PYENV_ROOT/bin:$PATH"
    eval "$(pyenv init -)"

    # ---- 离线模式：将 Python 源码包放入 pyenv cache ----
    if [[ "$IS_OFFLINE" == "true" ]]; then
        local py_bundle="$BUNDLE_DIR/Python-${PYTHON_VERSION}.tar.xz"
        if [[ -f "$py_bundle" ]]; then
            mkdir -p "$HOME/.pyenv/cache"
            cp "$py_bundle" "$HOME/.pyenv/cache/"
            log_ok "Python 源码包已放入 pyenv cache"
        else
            log_err "离线模式缺少 Python 源码包：$py_bundle"
            return 1
        fi
    fi

    # ---- 安装 Python ----
    if pyenv versions 2>/dev/null | grep -q "$PYTHON_VERSION"; then
        log_ok "Python $PYTHON_VERSION 已安装"
    else
        # 在线模式：提前用 curl 下载到 pyenv cache，显示进度条
        # pyenv install 检测到 cache 中有文件时直接跳过下载
        if [[ "$IS_OFFLINE" == "false" ]]; then
            local cache_dir="$HOME/.pyenv/cache"
            local cache_file="$cache_dir/Python-${PYTHON_VERSION}.tar.xz"
            mkdir -p "$cache_dir"
            if [[ ! -f "$cache_file" ]]; then
                log_step "下载 Python ${PYTHON_VERSION}（显示进度）..."
                curl -fL --progress-bar \
                    -o "$cache_file" \
                    "https://www.python.org/ftp/python/${PYTHON_VERSION}/Python-${PYTHON_VERSION}.tar.xz" \
                    || { log_warn "预下载失败，交由 pyenv 重试"; rm -f "$cache_file"; }
            else
                log_ok "Python 源码包已在 cache，跳过下载"
            fi
        fi

        log_step "编译安装 Python ${PYTHON_VERSION}（需要几分钟，显示编译过程）..."
        # -v 显示编译过程，让用户看到进度而非干等
        pyenv install -v "$PYTHON_VERSION" 2>&1 \
            | grep --line-buffered -E '^\+\+? |checking |make\[|gcc|clang|error:' \
            || { log_err "Python 安装失败"; return 1; }
    fi

    pyenv global "$PYTHON_VERSION"
    log_ok "pyenv 配置完成：全局 Python → $PYTHON_VERSION"
}

# ============================================================
# 模块 8：EDA 工具
# ============================================================
setup_eda_tools() {
    log_step "模块 8/9：安装 EDA 工具..."

    if [[ "$OS_TYPE" == "centos" ]]; then
        # CentOS 服务器：只安装 Verible（服务器已有商业 EDA 工具）
        log_step "CentOS 模式：只安装 Verible（lint/format/LSP）"
        _install_verible
        log_ok "EDA 工具安装完成（CentOS：仅 Verible）"
        return 0
    fi

    # ---- Ubuntu：完整 EDA 工具集 ----

    # 8a. Icarus Verilog
    log_step "8a. Icarus Verilog..."
    if check_cmd iverilog; then
        log_ok "已安装（$(iverilog -V 2>&1 | head -1)）"
    elif [[ "$HAS_SUDO" == "true" ]]; then
        sudo apt-get install -y iverilog
        log_ok "Icarus Verilog 安装完成"
    fi

    # 8b. Verilator
    log_step "8b. Verilator..."
    if check_cmd verilator; then
        log_ok "已安装（$(verilator --version)）"
    elif [[ "$VERILATOR_FROM_SOURCE" == "true" ]]; then
        _install_verilator_source
    elif [[ "$HAS_SUDO" == "true" ]]; then
        sudo apt-get install -y verilator
        log_ok "Verilator 安装完成（$(verilator --version)）"
    fi

    # 8c. Verible
    log_step "8c. Verible..."
    _install_verible

    # 8d. GTKWave
    log_step "8d. GTKWave..."
    if check_cmd gtkwave; then
        log_ok "已安装"
    elif [[ "$HAS_SUDO" == "true" ]]; then
        sudo apt-get install -y gtkwave
        log_ok "GTKWave 安装完成"
    fi

    log_ok "EDA 工具安装完成"
}

_install_verilator_source() {
    log_step "从源码编译 Verilator（需要 10-20 分钟）..."
    local build_dir
    build_dir=$(mktemp -d)
    git clone https://github.com/verilator/verilator.git "$build_dir/verilator" \
        --depth=1 --branch stable || { rm -rf "$build_dir"; return 1; }
    cd "$build_dir/verilator"
    autoconf
    ./configure --prefix="$HOME/.local"
    make -j"$(nproc)"
    make install
    cd - >/dev/null
    rm -rf "$build_dir"
    log_ok "Verilator 编译完成（$(verilator --version)）"
}

_install_verible() {
    if check_cmd verible-verilog-lint \
        && verible-verilog-lint --version 2>/dev/null | grep -q "${VERIBLE_VERSION}"; then
        log_ok "Verible ${VERIBLE_VERSION} 已安装"
        return 0
    fi

    local pkg_name="verible-v${VERIBLE_VERSION}-linux-static-x86_64.tar.gz"
    local url="https://github.com/chipsalliance/verible/releases/download/v${VERIBLE_VERSION}/${pkg_name}"
    local tmp_dir
    tmp_dir=$(mktemp -d)

    fetch_file "$url" "$tmp_dir/$pkg_name" "$pkg_name" || {
        log_warn "Verible 安装失败，请手动下载：https://github.com/chipsalliance/verible/releases"
        rm -rf "$tmp_dir"
        return 1
    }

    tar -xzf "$tmp_dir/$pkg_name" -C "$tmp_dir"
    local extracted_dir
    extracted_dir=$(find "$tmp_dir" -maxdepth 1 -type d -name "verible-*" | head -1)

    if [[ -z "$extracted_dir" ]]; then
        log_err "Verible 解压失败"
        rm -rf "$tmp_dir"
        return 1
    fi

    mkdir -p "$HOME/.local/bin"
    find "$extracted_dir/bin" -type f -executable | while read -r bin; do
        cp "$bin" "$HOME/.local/bin/"
    done

    rm -rf "$tmp_dir"
    log_ok "Verible 安装完成"
}

# 写入 Windows 侧 .wslconfig，开启镜像网络模式
# 三种情况：文件不存在、存在但无 [wsl2] 节、已有配置
_setup_wsl_mirrored_network() {
    # 获取 Windows 用户目录（.wslconfig 在 Windows 侧）
    local win_userprofile
    win_userprofile=$(powershell.exe -NoProfile -NonInteractive \
        -Command '$env:USERPROFILE' 2>/dev/null | tr -d '\r')
    if [[ -z "$win_userprofile" ]]; then
        log_warn "无法获取 Windows 用户目录，跳过 .wslconfig 配置"
        return 0
    fi

    local wslconfig
    wslconfig=$(wslpath -u "$win_userprofile/.wslconfig" 2>/dev/null) || {
        log_warn "wslpath 转换失败，跳过 .wslconfig 配置"
        return 0
    }

    # 已配置则跳过
    if grep -q "networkingMode=mirrored" "$wslconfig" 2>/dev/null; then
        log_ok "WSL2 镜像网络已配置（$wslconfig）"
        return 0
    fi

    log_step "配置 WSL2 镜像网络模式（~/.wslconfig）..."
    backup_file "$wslconfig"

    if [[ -f "$wslconfig" ]] && grep -q "^\[wsl2\]" "$wslconfig"; then
        # 文件存在且有 [wsl2] 节：在节内追加
        sed -i '/^\[wsl2\]/a networkingMode=mirrored' "$wslconfig"
    elif [[ -f "$wslconfig" ]]; then
        # 文件存在但无 [wsl2] 节：追加完整节
        printf '\n[wsl2]\nnetworkingMode=mirrored\n' >> "$wslconfig"
    else
        # 文件不存在：新建
        printf '[wsl2]\nnetworkingMode=mirrored\n' > "$wslconfig"
    fi

    log_ok ".wslconfig 已写入 networkingMode=mirrored"
    echo ""
    echo "  ┌─────────────────────────────────────────────────────┐"
    echo "  │  需要重启 WSL 才能生效                               │"
    echo "  │  重启后 localhost 代理（Clash 等）将直接可用          │"
    echo "  └─────────────────────────────────────────────────────┘"
    echo ""
    local answer=""
    read -rp "  现在重启 WSL？重启后当前终端会断开，需重新打开 [y/N] " answer
    if [[ "${answer,,}" == "y" ]]; then
        log_step "正在关闭 WSL..."
        powershell.exe /c "wsl --shutdown" 2>/dev/null || true
    else
        echo ""
        echo "  稍后在 PowerShell 中手动执行："
        echo "    wsl --shutdown"
        echo ""
    fi
}

# ============================================================
# 模块 9：WezTerm 配置（仅 Ubuntu/本地场景输出）
# ============================================================
setup_wezterm_config() {
    log_step "模块 9/9：WezTerm 配置..."

    if [[ "$OS_TYPE" == "centos" ]]; then
        log_warn "CentOS 服务器模式：跳过 WezTerm 配置（在本地 WSL2 上配置）"
        return 0
    fi

    # WSL2 镜像网络模式：自动写入 .wslconfig（解决 localhost 代理无法访问的问题）
    if [[ -n "${WSL_DISTRO_NAME:-}" ]]; then
        _setup_wsl_mirrored_network
    fi

    local wezterm_src="$CONFIGS_DIR/wezterm.lua"
    echo ""
    echo "================================================================"
    echo "  WezTerm 配置文件：$wezterm_src"
    echo ""
    echo "  Windows 侧安装（PowerShell）："
    local windows_path
    windows_path=$(wslpath -w "$wezterm_src" 2>/dev/null || echo "<请手动定位>")
    echo "    cp \"$windows_path\" \"\$env:USERPROFILE\\.wezterm.lua\""
    echo ""
    echo "  字体：Sarasa Term SC Nerd Font（需在 Windows 安装）"
    echo "================================================================"
}

# ============================================================
# 参数解析
# ============================================================
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --offline)           IS_OFFLINE=true;  shift ;;
            --verilator-source)  VERILATOR_FROM_SOURCE=true; shift ;;
            --only) IFS=',' read -ra ONLY_MODULES <<< "$2"; shift 2 ;;
            --skip) IFS=',' read -ra SKIP_MODULES <<< "$2"; shift 2 ;;
            -h|--help)
                cat <<'EOF'
用法：
  ./setup.sh                       全量安装（在线，Ubuntu）
  ./setup.sh --offline             离线安装（从 bundle/ 目录读取）
  ./setup.sh --verilator-source    Verilator 源码编译（v5.x）
  ./setup.sh --only zsh,neovim     只运行指定模块
  ./setup.sh --skip eda_tools      跳过指定模块

模块列表：
  prerequisites, zsh, starship, fzf, dev_tools,
  neovim, pyenv, eda_tools, wezterm_config
EOF
                exit 0 ;;
            *) log_err "未知参数：$1"; exit 1 ;;
        esac
    done
}

# ============================================================
# 主函数
# ============================================================
main() {
    parse_args "$@"

    echo ""
    echo "=================================================="
    echo "  Linux 开发环境配置脚本"
    echo "  Ubuntu 24.04 / WSL2 & CentOS 服务器"
    echo "=================================================="

    detect_env

    # 代理可达性检查：若代理设置了但实际连不上，安装期间临时禁用
    # 避免 apt-get / curl 等工具因代理不可用而卡住
    if [[ -n "${HTTP_PROXY:-}" ]]; then
        local proxy_host proxy_port
        proxy_host=$(echo "$HTTP_PROXY" | sed 's|https\?://||' | cut -d: -f1)
        proxy_port=$(echo "$HTTP_PROXY" | sed 's|https\?://||' | cut -d: -f2 | cut -d/ -f1)
        if timeout 3 bash -c ">/dev/tcp/$proxy_host/$proxy_port" 2>/dev/null; then
            log_ok "代理可用：$HTTP_PROXY"
        else
            log_warn "代理 $HTTP_PROXY 无法连接，安装期间临时禁用代理（使用直连）"
            unset HTTP_PROXY HTTPS_PROXY ALL_PROXY http_proxy https_proxy all_proxy
        fi
    fi

    # sudo 凭据缓存：提前验证一次，后台每 60 秒刷新，避免安装中途反复问密码
    if [[ "$HAS_SUDO" == "true" ]]; then
        log_step "请输入 sudo 密码（整个安装过程只需输入一次）..."
        sudo -v
        # 后台保活：每 60 秒刷新 sudo 时间戳，直到脚本退出
        ( while kill -0 $$ 2>/dev/null; do sudo -n -v 2>/dev/null; sleep 60; done ) &
        local sudo_keepalive_pid=$!
        # 脚本退出时结束后台保活进程
        trap "kill $sudo_keepalive_pid 2>/dev/null; exit" INT TERM EXIT
    fi

    # 离线模式检查 bundle 目录
    if [[ "$IS_OFFLINE" == "true" ]] && [[ ! -d "$BUNDLE_DIR" ]]; then
        log_err "离线模式需要 bundle/ 目录：$BUNDLE_DIR"
        log_err "请先在有网络的机器执行：./scripts/bundle_prepare.sh"
        exit 1
    fi

    init_backup_dir
    mkdir -p "$HOME/.local/bin"
    export PATH="$HOME/.local/bin:$PATH"

    local modules=(
        prerequisites zsh starship fzf dev_tools
        neovim pyenv eda_tools wezterm_config
    )

    local module
    for module in "${modules[@]}"; do
        if should_run "$module"; then
            echo ""
            if ! "setup_$module"; then
                log_err "模块 $module 执行失败"
                FAILED_MODULES+=("$module")
            fi
        else
            log_warn "跳过：$module"
        fi
    done

    echo ""
    echo "=================================================="
    if [[ ${#FAILED_MODULES[@]} -eq 0 ]]; then
        log_ok "全部模块执行完成！"
    else
        log_warn "以下模块失败，请手动处理："
        local m; for m in "${FAILED_MODULES[@]}"; do echo "  - $m"; done
    fi
    echo ""
    echo "后续步骤："
    if [[ "$CSH_MODE" == "true" ]]; then
        echo "  1. 重新登录（csh 将自动切换到 zsh）"
    else
        echo "  1. 重新登录或执行 exec zsh"
    fi
    echo "  2. 首次运行 nvim 等待 LazyVim 初始化"
    echo "  3. 运行 ./test_setup.sh 验证安装结果"

    # WSL2：提示安装 Nerd Font，否则 Neovim/LazyVim 图标显示乱码
    if [[ -n "${WSL_DISTRO_NAME:-}" ]]; then
        echo ""
        echo "================================================================"
        echo "  ★  Nerd Font 提醒（WSL2 必读）"
        echo ""
        echo "  Neovim / LazyVim 使用 Nerd Font 图标字符（如  ）。"
        echo "  若 Windows Terminal 未安装对应字体，图标将显示为方框或乱码。"
        echo ""
        echo "  推荐字体：JetBrainsMono Nerd Font"
        echo ""
        echo "  自动安装（推荐）："
        echo "    在 Windows 侧运行 windows_env_setup 项目的 setup.py"
        echo "    python setup.py     # 包含自动下载并安装 Nerd Font"
        echo ""
        echo "  手动安装："
        echo "    https://github.com/ryanoasis/nerd-fonts/releases"
        echo "    → 下载 JetBrainsMono.zip，解压后右键字体文件 → 为所有用户安装"
        echo "    → Windows Terminal 设置 > 配置文件 > 默认值 > 外观 > 字体"
        echo "      选择 JetBrainsMono Nerd Font"
        echo "================================================================"
    fi
    echo "=================================================="
}

main "$@"
