#!/usr/bin/env bash
# ==============================================================
# linux_env_setup — Ubuntu 24.04 / WSL2 开发环境一键配置脚本
# 面向数字 IC 工程师（Verilog/SV、Python、Perl）
#
# 用法：
#   ./setup.sh                      # 全量安装（Verilator 用 apt）
#   ./setup.sh --verilator-source   # Verilator 从源码编译（v5.x）
#   ./setup.sh --only zsh,neovim    # 只运行指定模块（逗号分隔）
#   ./setup.sh --skip eda_tools     # 跳过指定模块
# ==============================================================

set -euo pipefail

# ============================================================
# 版本常量（所有版本号统一在此定义）
# ============================================================
readonly PYTHON_VERSION="3.12.10"
readonly NEOVIM_VERSION="0.10.4"
readonly VERIBLE_VERSION="0.0-3793-g4294133e"

# ============================================================
# 颜色常量
# ============================================================
readonly C_BLUE='\033[0;34m'
readonly C_GREEN='\033[0;32m'
readonly C_YELLOW='\033[0;33m'
readonly C_RED='\033[0;31m'
readonly C_RESET='\033[0m'

# ============================================================
# 全局状态
# ============================================================
VERILATOR_FROM_SOURCE=false
ONLY_MODULES=()
SKIP_MODULES=()
BACKUP_DIR=""          # 由 init_backup_dir 初始化，全局唯一
FAILED_MODULES=()      # 记录失败的模块名

# ============================================================
# 日志函数
# ============================================================
log_step() { echo -e "${C_BLUE}[*] $*${C_RESET}"; }
log_ok()   { echo -e "${C_GREEN}[OK] $*${C_RESET}"; }
log_warn() { echo -e "${C_YELLOW}[WARN] $*${C_RESET}"; }
log_err()  { echo -e "${C_RED}[ERROR] $*${C_RESET}" >&2; }

# ============================================================
# 公共工具函数
# ============================================================

# 初始化本次运行的备份目录（全局唯一时间戳）
init_backup_dir() {
    BACKUP_DIR="$HOME/.config_backup/$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$BACKUP_DIR"
    log_ok "备份目录：$BACKUP_DIR"
}

# 备份文件或目录到 $BACKUP_DIR
backup_file() {
    local target="$1"
    if [[ -e "$target" ]]; then
        local rel_name
        rel_name=$(basename "$target")
        cp -r "$target" "$BACKUP_DIR/$rel_name"
        log_ok "已备份：$target → $BACKUP_DIR/$rel_name"
    fi
}

# 备份后安装配置文件
install_config() {
    local src="$1"
    local dst="$2"
    local dst_dir
    dst_dir=$(dirname "$dst")

    backup_file "$dst"
    mkdir -p "$dst_dir"
    cp "$src" "$dst"
    log_ok "已安装：$src → $dst"
}

# 检查命令是否存在
check_cmd() {
    command -v "$1" &>/dev/null
}

# 检查 sudo 是否可用
need_sudo() {
    if ! sudo -n true 2>/dev/null; then
        log_err "需要 sudo 权限，请确保当前用户可以执行 sudo"
        return 1
    fi
}

# 下载文件（优先用 curl，失败时用 wget）
download() {
    local url="$1"
    local output="$2"
    if check_cmd curl; then
        curl -fsSL --retry 3 -o "$output" "$url"
    elif check_cmd wget; then
        wget -q --tries=3 -O "$output" "$url"
    else
        log_err "curl 和 wget 均不可用，无法下载：$url"
        return 1
    fi
}

# 检查某模块是否应该执行
should_run() {
    local module="$1"
    # 如果指定了 --only，只跑 only 列表里的
    if [[ ${#ONLY_MODULES[@]} -gt 0 ]]; then
        local m
        for m in "${ONLY_MODULES[@]}"; do
            [[ "$m" == "$module" ]] && return 0
        done
        return 1
    fi
    # 如果指定了 --skip，跳过 skip 列表里的
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
    log_step "模块 1/9：安装基础依赖..."
    need_sudo || return 1

    sudo apt-get update -y
    sudo apt-get upgrade -y

    # 编译工具与常用依赖
    local packages=(
        git curl wget build-essential pkg-config
        libssl-dev zlib1g-dev libbz2-dev libreadline-dev
        libsqlite3-dev libffi-dev liblzma-dev libncurses-dev
        ca-certificates gnupg unzip xz-utils
        # Verilator 源码编译依赖（提前安装，按需可跳过）
        autoconf flex bison help2man
    )
    sudo apt-get install -y "${packages[@]}"
    log_ok "基础依赖安装完成"
}

# ============================================================
# 模块 2：Zsh + 插件
# ============================================================
setup_zsh() {
    log_step "模块 2/9：配置 Zsh..."
    need_sudo || return 1

    # 安装 zsh
    if ! check_cmd zsh; then
        sudo apt-get install -y zsh
    else
        log_ok "zsh 已安装，跳过"
    fi

    # 设置为默认 shell（若已是 zsh 则跳过）
    if [[ "$SHELL" != "$(which zsh)" ]]; then
        chsh -s "$(which zsh)"
        log_ok "已将 zsh 设为默认 shell（下次登录生效）"
    else
        log_ok "zsh 已是默认 shell"
    fi

    # 克隆插件到 ~/.zsh/（不依赖 Oh My Zsh）
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
            log_ok "插件已存在，更新：$name"
            git -C "$plugin_dir/$name" pull --ff-only 2>/dev/null || log_warn "$name 更新失败，保留现有版本"
        else
            log_step "克隆插件：$name"
            git clone --depth=1 "$url" "$plugin_dir/$name" || {
                log_warn "克隆 $name 失败，跳过"
                continue
            }
        fi
    done

    # 安装 zshrc 配置
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    install_config "$script_dir/configs/zshrc" "$HOME/.zshrc"

    log_ok "Zsh 配置完成"
}

# ============================================================
# 模块 3：Starship 提示符
# ============================================================
setup_starship() {
    log_step "模块 3/9：安装 Starship..."

    if check_cmd starship; then
        log_ok "Starship 已安装（$(starship --version)），跳过"
    else
        # 官方安装脚本，安装到 ~/.local/bin（无需 sudo）
        local install_script
        install_script=$(mktemp)
        if download "https://starship.rs/install.sh" "$install_script"; then
            chmod +x "$install_script"
            sh "$install_script" --yes --bin-dir "$HOME/.local/bin"
            rm -f "$install_script"
        else
            log_warn "无法下载 Starship 安装脚本，请手动安装：https://starship.rs"
            return 1
        fi
    fi

    # 安装配置
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    install_config "$script_dir/configs/starship.toml" "$HOME/.config/starship.toml"

    log_ok "Starship 配置完成"
}

# ============================================================
# 模块 4：fzf 模糊搜索
# ============================================================
setup_fzf() {
    log_step "模块 4/9：安装 fzf..."

    if [[ -d "$HOME/.fzf" ]]; then
        log_ok "fzf 已存在，更新..."
        git -C "$HOME/.fzf" pull --ff-only 2>/dev/null || log_warn "fzf 更新失败，保留现有版本"
    else
        git clone --depth=1 https://github.com/junegunn/fzf.git "$HOME/.fzf" || {
            log_err "克隆 fzf 失败"
            return 1
        }
    fi

    # --all：启用 shell 集成（Ctrl+R / Ctrl+T / Alt+C）
    "$HOME/.fzf/install" --all --no-update-rc 2>/dev/null || true

    log_ok "fzf 配置完成"
}

# ============================================================
# 模块 5：开发工具（ripgrep / fd / git 配置）
# ============================================================
setup_dev_tools() {
    log_step "模块 5/9：配置开发工具..."
    need_sudo || return 1

    # ripgrep
    if ! check_cmd rg; then
        sudo apt-get install -y ripgrep
    else
        log_ok "ripgrep 已安装"
    fi

    # fd（Ubuntu 包名 fd-find，命令名 fdfind）
    if ! check_cmd fd && ! check_cmd fdfind; then
        sudo apt-get install -y fd-find
    else
        log_ok "fd 已安装"
    fi

    # Ubuntu 下 fd 命令名为 fdfind，创建软链接
    local fd_bin
    fd_bin=$(command -v fdfind 2>/dev/null || true)
    if [[ -n "$fd_bin" ]] && ! check_cmd fd; then
        mkdir -p "$HOME/.local/bin"
        ln -sf "$fd_bin" "$HOME/.local/bin/fd"
        log_ok "已创建 fd 软链接 → $fd_bin"
    fi

    # git 全局配置（只在未设置时写入，避免覆盖用户自定义）
    if [[ -z "$(git config --global core.editor 2>/dev/null)" ]]; then
        git config --global core.editor nvim
    fi
    if [[ -z "$(git config --global init.defaultBranch 2>/dev/null)" ]]; then
        git config --global init.defaultBranch main
    fi
    if [[ -z "$(git config --global pull.rebase 2>/dev/null)" ]]; then
        git config --global pull.rebase false
    fi

    log_ok "开发工具配置完成"
}

# ============================================================
# 模块 6：Neovim + LazyVim + LSP 配置
# ============================================================
setup_neovim() {
    log_step "模块 6/9：安装 Neovim..."

    local nvim_bin="$HOME/.local/bin/nvim"
    local nvim_appimage="$HOME/.local/bin/nvim.appimage"
    local nvim_url="https://github.com/neovim/neovim/releases/download/v${NEOVIM_VERSION}/nvim-linux-x86_64.appimage"

    mkdir -p "$HOME/.local/bin"

    # 检查是否已安装且版本匹配
    if [[ -x "$nvim_bin" ]] && "$nvim_bin" --version 2>/dev/null | grep -q "$NEOVIM_VERSION"; then
        log_ok "Neovim $NEOVIM_VERSION 已安装"
    else
        log_step "下载 Neovim v${NEOVIM_VERSION} AppImage..."
        if download "$nvim_url" "$nvim_appimage"; then
            chmod +x "$nvim_appimage"

            # 尝试解压 AppImage（部分 WSL2 环境不支持 FUSE，直接解压更可靠）
            if "$nvim_appimage" --appimage-extract &>/dev/null; then
                # FUSE 可用，直接用 AppImage
                mv "$nvim_appimage" "$nvim_bin"
            else
                # FUSE 不可用（常见于 WSL2），解压后使用
                log_warn "FUSE 不可用，改用解压模式"
                rm -f "$nvim_appimage"
                local extract_dir="$HOME/.local/nvim-extract"
                mkdir -p "$extract_dir"
                # 重新下载并解压
                local tmp_appimage
                tmp_appimage=$(mktemp --suffix=.appimage)
                download "$nvim_url" "$tmp_appimage"
                chmod +x "$tmp_appimage"
                cd "$extract_dir"
                "$tmp_appimage" --appimage-extract &>/dev/null || true
                rm -f "$tmp_appimage"
                # squashfs-root/usr/bin/nvim
                if [[ -x "$extract_dir/squashfs-root/usr/bin/nvim" ]]; then
                    ln -sf "$extract_dir/squashfs-root/usr/bin/nvim" "$nvim_bin"
                else
                    log_err "Neovim 解压失败，请手动安装"
                    return 1
                fi
                cd - >/dev/null
            fi
            log_ok "Neovim v${NEOVIM_VERSION} 安装完成"
        else
            log_warn "无法下载 Neovim，请手动安装：https://github.com/neovim/neovim/releases"
            return 1
        fi
    fi

    # 安装 nodejs（LSP 依赖）
    need_sudo || return 1
    if ! check_cmd node; then
        log_step "安装 Node.js（LSP 依赖）..."
        # 使用 NodeSource 仓库安装 LTS 版本
        local node_setup
        node_setup=$(mktemp)
        if download "https://deb.nodesource.com/setup_lts.x" "$node_setup"; then
            sudo bash "$node_setup"
            rm -f "$node_setup"
            sudo apt-get install -y nodejs
        else
            log_warn "NodeSource 下载失败，尝试 apt 安装..."
            sudo apt-get install -y nodejs npm || log_warn "Node.js 安装失败，部分 LSP 可能无法使用"
        fi
    else
        log_ok "Node.js 已安装（$(node --version)）"
    fi

    # 安装/更新 LazyVim starter
    local nvim_config="$HOME/.config/nvim"
    if [[ -d "$nvim_config" ]]; then
        # 检查是否已是 LazyVim
        if grep -q "LazyVim" "$nvim_config/lua/config/lazy.lua" 2>/dev/null; then
            log_ok "LazyVim 已安装，跳过克隆"
        else
            log_warn "检测到非 LazyVim 的 Neovim 配置，备份并替换..."
            backup_file "$nvim_config"
            rm -rf "$nvim_config"
            git clone https://github.com/LazyVim/starter "$nvim_config"
            rm -rf "$nvim_config/.git"
        fi
    else
        log_step "克隆 LazyVim starter..."
        git clone https://github.com/LazyVim/starter "$nvim_config" || {
            log_err "克隆 LazyVim 失败"
            return 1
        }
        rm -rf "$nvim_config/.git"
    fi

    # 安装自定义插件配置（Verilog/SV + Verible LSP + Python）
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local plugins_dir="$nvim_config/lua/plugins"
    mkdir -p "$plugins_dir"

    # 安装 IC 工具专用插件配置
    cp "$script_dir/configs/nvim-ic.lua" "$plugins_dir/ic.lua"
    log_ok "已安装 Neovim IC 插件配置 → $plugins_dir/ic.lua"

    log_ok "Neovim 配置完成（首次运行 nvim 时 LazyVim 将自动安装插件）"
}

# ============================================================
# 模块 7：pyenv + Python
# ============================================================
setup_pyenv() {
    log_step "模块 7/9：安装 pyenv + Python ${PYTHON_VERSION}..."

    if [[ -d "$HOME/.pyenv" ]]; then
        log_ok "pyenv 已存在，更新..."
        git -C "$HOME/.pyenv" pull --ff-only 2>/dev/null || log_warn "pyenv 更新失败，保留现有版本"
    else
        git clone https://github.com/pyenv/pyenv.git "$HOME/.pyenv" || {
            log_err "克隆 pyenv 失败"
            return 1
        }
    fi

    # 临时将 pyenv 加入 PATH，用于本次脚本执行
    export PYENV_ROOT="$HOME/.pyenv"
    export PATH="$PYENV_ROOT/bin:$PATH"
    eval "$(pyenv init -)"

    # 安装 Python（已安装则跳过）
    if pyenv versions | grep -q "$PYTHON_VERSION"; then
        log_ok "Python $PYTHON_VERSION 已安装"
    else
        log_step "编译安装 Python ${PYTHON_VERSION}（需要几分钟）..."
        pyenv install "$PYTHON_VERSION" || {
            log_err "Python $PYTHON_VERSION 安装失败"
            return 1
        }
    fi

    pyenv global "$PYTHON_VERSION"
    log_ok "pyenv 配置完成，全局 Python → $PYTHON_VERSION"
}

# ============================================================
# 模块 8：EDA 工具
# ============================================================
setup_eda_tools() {
    log_step "模块 8/9：安装 EDA 工具..."
    need_sudo || return 1

    # ---- 8a. Icarus Verilog ----
    log_step "8a. 安装 Icarus Verilog..."
    if check_cmd iverilog; then
        log_ok "Icarus Verilog 已安装（$(iverilog -V 2>&1 | head -1)）"
    else
        sudo apt-get install -y iverilog
        log_ok "Icarus Verilog 安装完成"
    fi

    # ---- 8b. Verilator ----
    log_step "8b. 安装 Verilator..."
    if check_cmd verilator; then
        log_ok "Verilator 已安装（$(verilator --version)）"
    elif [[ "$VERILATOR_FROM_SOURCE" == "true" ]]; then
        _install_verilator_source
    else
        sudo apt-get install -y verilator
        log_ok "Verilator 安装完成（$(verilator --version)）"
    fi

    # ---- 8c. Verible ----
    log_step "8c. 安装 Verible v${VERIBLE_VERSION}..."
    _install_verible

    # ---- 8d. GTKWave ----
    log_step "8d. 安装 GTKWave..."
    if check_cmd gtkwave; then
        log_ok "GTKWave 已安装"
    else
        sudo apt-get install -y gtkwave
        log_ok "GTKWave 安装完成"
    fi

    log_ok "EDA 工具安装完成"
}

# 从源码编译 Verilator（最新 v5.x）
_install_verilator_source() {
    log_step "从源码编译 Verilator（需要 10-20 分钟）..."

    local build_dir
    build_dir=$(mktemp -d)

    # 克隆最新稳定版
    git clone https://github.com/verilator/verilator.git "$build_dir/verilator" \
        --depth=1 --branch stable || {
        log_err "克隆 Verilator 失败"
        rm -rf "$build_dir"
        return 1
    }

    cd "$build_dir/verilator"
    autoconf
    ./configure --prefix="$HOME/.local"
    make -j"$(nproc)"
    make install
    cd - >/dev/null
    rm -rf "$build_dir"

    log_ok "Verilator 源码编译完成（$(verilator --version)）"
}

# 安装 Verible 预编译二进制
_install_verible() {
    # 检查是否已安装正确版本
    if check_cmd verible-verilog-lint && \
       verible-verilog-lint --version 2>/dev/null | grep -q "${VERIBLE_VERSION}"; then
        log_ok "Verible ${VERIBLE_VERSION} 已安装"
        return 0
    fi

    local os_tag="Ubuntu-22.04"    # 预编译包兼容 Ubuntu 22/24
    local pkg_name="verible-v${VERIBLE_VERSION}-linux-static-x86_64.tar.gz"
    local url="https://github.com/chipsalliance/verible/releases/download/v${VERIBLE_VERSION}/${pkg_name}"
    local tmp_dir
    tmp_dir=$(mktemp -d)

    log_step "下载 Verible ${VERIBLE_VERSION}..."
    if download "$url" "$tmp_dir/$pkg_name"; then
        tar -xzf "$tmp_dir/$pkg_name" -C "$tmp_dir"
        mkdir -p "$HOME/.local/bin"

        # 解压后的目录名
        local extracted_dir
        extracted_dir=$(find "$tmp_dir" -maxdepth 1 -type d -name "verible-*" | head -1)

        if [[ -z "$extracted_dir" ]]; then
            log_err "Verible 解压失败，未找到目录"
            rm -rf "$tmp_dir"
            return 1
        fi

        # 安装所有 verible 二进制文件
        find "$extracted_dir/bin" -type f -executable | while read -r bin; do
            cp "$bin" "$HOME/.local/bin/"
            log_ok "  已安装：$(basename "$bin")"
        done

        rm -rf "$tmp_dir"
        log_ok "Verible 安装完成"
    else
        log_warn "无法下载 Verible，请手动安装："
        log_warn "  https://github.com/chipsalliance/verible/releases"
        rm -rf "$tmp_dir"
        return 1
    fi
}

# ============================================================
# 模块 9：WezTerm 配置（仅输出，供 Windows 侧使用）
# ============================================================
setup_wezterm_config() {
    log_step "模块 9/9：准备 WezTerm 配置..."

    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local wezterm_src="$script_dir/configs/wezterm.lua"

    echo ""
    echo "================================================================"
    echo "  WezTerm 配置文件已准备好："
    echo "  Linux 路径：$wezterm_src"
    echo ""
    echo "  Windows 侧使用方法（在 PowerShell 中执行）："

    # 将 Linux 路径转换为 Windows 路径提示
    local windows_path
    windows_path=$(wslpath -w "$wezterm_src" 2>/dev/null || echo "请手动定位该文件")
    echo "    cp \"$windows_path\" \"\$env:USERPROFILE\\.wezterm.lua\""
    echo ""
    echo "  字体：Sarasa Term SC Nerd Font（需要在 Windows 侧安装）"
    echo "  下载：https://github.com/ryanoasis/nerd-fonts/releases"
    echo "       → SarasaTermSC.zip"
    echo "================================================================"
    echo ""

    log_ok "WezTerm 配置准备完成"
}

# ============================================================
# 参数解析
# ============================================================
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --verilator-source)
                VERILATOR_FROM_SOURCE=true
                shift
                ;;
            --only)
                IFS=',' read -ra ONLY_MODULES <<< "$2"
                shift 2
                ;;
            --skip)
                IFS=',' read -ra SKIP_MODULES <<< "$2"
                shift 2
                ;;
            -h|--help)
                echo "用法："
                echo "  ./setup.sh                       全量安装"
                echo "  ./setup.sh --verilator-source    Verilator 源码编译（v5.x）"
                echo "  ./setup.sh --only zsh,neovim     只运行指定模块"
                echo "  ./setup.sh --skip eda_tools      跳过指定模块"
                echo ""
                echo "模块列表："
                echo "  prerequisites, zsh, starship, fzf, dev_tools,"
                echo "  neovim, pyenv, eda_tools, wezterm_config"
                exit 0
                ;;
            *)
                log_err "未知参数：$1"
                exit 1
                ;;
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
    echo "  Ubuntu 24.04 / WSL2 | 数字 IC 工程师版"
    echo "=================================================="
    echo ""

    # 验证运行在支持的系统上
    if [[ ! -f /etc/os-release ]] || ! grep -q "Ubuntu\|Debian" /etc/os-release; then
        log_warn "当前系统不是 Ubuntu/Debian，部分功能可能无法正常工作"
    fi

    # 初始化备份目录
    init_backup_dir

    # 确保 ~/.local/bin 在 PATH 中（后续模块安装到这里）
    mkdir -p "$HOME/.local/bin"
    export PATH="$HOME/.local/bin:$PATH"

    # 按顺序执行模块
    local modules=(
        "prerequisites"
        "zsh"
        "starship"
        "fzf"
        "dev_tools"
        "neovim"
        "pyenv"
        "eda_tools"
        "wezterm_config"
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
            log_warn "跳过模块：$module"
        fi
    done

    # ---- 最终报告 ----
    echo ""
    echo "=================================================="
    if [[ ${#FAILED_MODULES[@]} -eq 0 ]]; then
        log_ok "全部模块执行完成！"
    else
        log_warn "以下模块执行失败，请手动处理："
        local m
        for m in "${FAILED_MODULES[@]}"; do
            echo "  - $m"
        done
    fi
    echo ""
    echo "后续步骤："
    echo "  1. 重新登录或执行 exec zsh 切换到 zsh"
    echo "  2. 首次运行 nvim 等待 LazyVim 自动安装插件"
    echo "  3. 运行 ./test_setup.sh 验证安装结果"
    echo "  4. WezTerm 配置文件：configs/wezterm.lua（复制到 Windows 侧）"
    echo "=================================================="
}

main "$@"
