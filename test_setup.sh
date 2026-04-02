#!/usr/bin/env bash
# ============================================================
# test_setup.sh — 验证开发环境安装结果
# 用法：./test_setup.sh
#        ./test_setup.sh --verbose   # 显示详细版本信息
# ============================================================

set -uo pipefail

# 颜色
readonly C_GREEN='\033[0;32m'
readonly C_RED='\033[0;31m'
readonly C_YELLOW='\033[0;33m'
readonly C_RESET='\033[0m'

VERBOSE=false
PASS=0
FAIL=0
WARN=0

# 探测当前环境（与 setup.sh 逻辑一致）
_detect_os() {
    if [[ -f /etc/os-release ]]; then
        local id
        id=$(. /etc/os-release && echo "${ID:-unknown}")
        case "$id" in
            ubuntu|debian)                      echo "ubuntu" ;;
            centos|rhel|rocky|almalinux|fedora) echo "centos" ;;
            *)                                  echo "unknown" ;;
        esac
    else
        echo "unknown"
    fi
}

CURRENT_OS=$(_detect_os)

# ============================================================
# 辅助函数
# ============================================================
pass() {
    local desc="$1"
    local detail="${2:-}"
    echo -e "  ${C_GREEN}[PASS]${C_RESET} $desc"
    [[ "$VERBOSE" == "true" && -n "$detail" ]] && echo "         $detail"
    (( PASS++ ))
}

fail() {
    local desc="$1"
    local hint="${2:-}"
    echo -e "  ${C_RED}[FAIL]${C_RESET} $desc"
    [[ -n "$hint" ]] && echo "         提示：$hint"
    (( FAIL++ ))
}

warn() {
    local desc="$1"
    echo -e "  ${C_YELLOW}[WARN]${C_RESET} $desc"
    (( WARN++ ))
}

check_cmd_version() {
    local name="$1"
    local cmd="$2"
    local version_flag="${3:---version}"

    if command -v "$cmd" &>/dev/null; then
        local ver
        ver=$($cmd $version_flag 2>&1 | head -1)
        pass "$name 已安装" "$ver"
    else
        fail "$name 未安装" "运行 ./setup.sh 安装"
    fi
}

# ============================================================
# 检查项
# ============================================================
check_shell() {
    echo "─── Shell ───────────────────────────────────────────"
    if [[ -n "${ZSH_VERSION:-}" ]]; then
        pass "当前 Shell 为 zsh" "zsh $ZSH_VERSION"
    elif command -v zsh &>/dev/null; then
        warn "zsh 已安装，但当前 Shell 不是 zsh（重新登录后生效）"
    else
        fail "zsh 未安装"
    fi

    # 检查 zshrc 关键内容
    local zshrc="$HOME/.zshrc"
    if [[ -f "$zshrc" ]]; then
        local checks=("starship init" "zsh-autosuggestions" "zsh-syntax-highlighting" "pyenv init")
        local key
        for key in "${checks[@]}"; do
            if grep -q "$key" "$zshrc"; then
                pass "zshrc 包含：$key"
            else
                warn "zshrc 缺少：$key（请检查 configs/zshrc 是否正确安装）"
            fi
        done
    else
        fail "~/.zshrc 不存在"
    fi
}

check_prompt() {
    echo ""
    echo "─── 提示符 ──────────────────────────────────────────"
    check_cmd_version "Starship" "starship" "--version"
}

check_search_tools() {
    echo ""
    echo "─── 搜索工具 ────────────────────────────────────────"
    check_cmd_version "fzf" "fzf" "--version"
    check_cmd_version "ripgrep (rg)" "rg" "--version"

    # fd：Ubuntu 下命令可能是 fdfind 或通过软链接的 fd
    if command -v fd &>/dev/null; then
        check_cmd_version "fd" "fd" "--version"
    elif command -v fdfind &>/dev/null; then
        local ver
        ver=$(fdfind --version 2>&1 | head -1)
        warn "fdfind 已安装，但 fd 软链接未创建（$ver）"
        echo "         提示：ln -sf $(which fdfind) ~/.local/bin/fd"
    else
        fail "fd / fdfind 未安装"
    fi
}

check_neovim() {
    echo ""
    echo "─── Neovim ──────────────────────────────────────────"
    if command -v nvim &>/dev/null; then
        local ver
        ver=$(nvim --version 2>&1 | head -1)
        pass "Neovim 已安装" "$ver"
    else
        fail "Neovim 未安装" "检查 ~/.local/bin/nvim 是否存在"
    fi

    # 检查 LazyVim 配置
    local nvim_config="$HOME/.config/nvim"
    if [[ -d "$nvim_config" ]]; then
        if grep -q "LazyVim" "$nvim_config/lua/config/lazy.lua" 2>/dev/null; then
            pass "LazyVim 配置已安装"
        else
            warn "~/.config/nvim 存在，但可能不是 LazyVim"
        fi
    else
        fail "~/.config/nvim 不存在"
    fi

    # 检查 IC 插件配置
    if [[ -f "$HOME/.config/nvim/lua/plugins/ic.lua" ]]; then
        pass "Neovim IC 插件配置已安装"
    else
        warn "IC 插件配置未安装（$HOME/.config/nvim/lua/plugins/ic.lua）"
    fi

    # 检查 Node.js（LSP 依赖）
    if command -v node &>/dev/null; then
        pass "Node.js 已安装（LSP 依赖）" "$(node --version)"
    else
        warn "Node.js 未安装，部分 LSP 功能可能不可用"
    fi
}

check_python() {
    echo ""
    echo "─── Python / pyenv ──────────────────────────────────"
    if [[ -d "$HOME/.pyenv" ]]; then
        pass "pyenv 已安装" "$(~/.pyenv/bin/pyenv --version 2>&1)"
    else
        fail "pyenv 未安装（~/.pyenv 不存在）"
    fi

    # 检查 python 命令
    local python_cmd
    python_cmd=$(command -v python 2>/dev/null || command -v python3 2>/dev/null || true)
    if [[ -n "$python_cmd" ]]; then
        local py_ver
        py_ver=$($python_cmd --version 2>&1)
        pass "Python 可用" "$py_ver（$python_cmd）"
    else
        fail "python / python3 命令不可用"
    fi
}

check_eda_tools() {
    echo ""
    echo "─── EDA 工具 ────────────────────────────────────────"

    # Verible（所有平台必检）
    local verible_bins=("verible-verilog-lint" "verible-verilog-format" "verible-verilog-ls")
    local verible_ok=true
    local vb
    for vb in "${verible_bins[@]}"; do
        if ! command -v "$vb" &>/dev/null; then
            verible_ok=false
            break
        fi
    done

    if [[ "$verible_ok" == "true" ]]; then
        local ver
        ver=$(verible-verilog-lint --version 2>&1 | head -1)
        pass "Verible（lint + format + ls）" "$ver"
    else
        fail "Verible 未完整安装" "检查 ~/.local/bin/ 中是否有 verible-verilog-* 文件"
    fi

    # CentOS 服务器：只需要 Verible，其余跳过
    if [[ "$CURRENT_OS" == "centos" ]]; then
        warn "CentOS 模式：iverilog / Verilator / GTKWave 由服务器管理员提供，跳过检查"
        return 0
    fi

    # Ubuntu：完整 EDA 工具检查
    if command -v iverilog &>/dev/null; then
        local ver
        ver=$(iverilog -V 2>&1 | head -1)
        pass "Icarus Verilog" "$ver"
    else
        fail "Icarus Verilog 未安装"
    fi

    if command -v verilator &>/dev/null; then
        pass "Verilator" "$(verilator --version 2>&1)"
    else
        fail "Verilator 未安装"
    fi

    if command -v gtkwave &>/dev/null; then
        pass "GTKWave" "$(gtkwave --version 2>&1 | head -1)"
    elif [[ -n "${WSL_DISTRO_NAME:-}" ]]; then
        warn "GTKWave 未安装（WSL2 需要 WSLg / Windows 11）"
    else
        fail "GTKWave 未安装"
    fi
}

check_centos_specific() {
    [[ "$CURRENT_OS" != "centos" ]] && return 0

    echo ""
    echo "─── CentOS 特定检查 ─────────────────────────────────"

    # zsh 安装位置（可能在 ~/.local/bin/）
    if command -v zsh &>/dev/null; then
        pass "zsh 可用" "$(zsh --version 2>&1)"
    elif [[ -x "$HOME/.local/bin/zsh" ]]; then
        pass "zsh 已编译安装" "$HOME/.local/bin/zsh"
    else
        fail "zsh 未安装（CentOS 下需从源码编译）"
    fi

    # csh → zsh 切换配置
    local csh_config
    if [[ -f "$HOME/.tcshrc" ]]; then
        csh_config="$HOME/.tcshrc"
    elif [[ -f "$HOME/.cshrc" ]]; then
        csh_config="$HOME/.cshrc"
    else
        csh_config=""
    fi

    if [[ -n "$csh_config" ]]; then
        if grep -q "linux_env_setup: switch to zsh" "$csh_config" 2>/dev/null; then
            pass "csh → zsh 切换已配置" "$csh_config"
        else
            warn "csh 配置文件未设置 zsh 切换（$csh_config）"
        fi
    else
        warn "未找到 .cshrc / .tcshrc（登录 shell 可能不是 csh）"
    fi

    # ~/.local/bin 在 PATH 中
    if [[ ":$PATH:" == *":$HOME/.local/bin:"* ]]; then
        pass "~/.local/bin 在 PATH 中"
    else
        warn "~/.local/bin 不在当前 PATH（重新登录后生效）"
    fi
}

check_paths() {
    echo ""
    echo "─── PATH 配置 ───────────────────────────────────────"
    local required_paths=("$HOME/.local/bin")
    local p
    for p in "${required_paths[@]}"; do
        if [[ ":$PATH:" == *":$p:"* ]]; then
            pass "PATH 包含：$p"
        else
            warn "PATH 缺少：$p（重启终端后应该自动生效）"
        fi
    done
}

check_wezterm_config() {
    echo ""
    echo "─── WezTerm 配置 ────────────────────────────────────"
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    if [[ -f "$script_dir/configs/wezterm.lua" ]]; then
        pass "wezterm.lua 配置文件已准备好"
        if [[ -n "${WSL_DISTRO_NAME:-}" ]]; then
            local win_path
            win_path=$(wslpath -w "$script_dir/configs/wezterm.lua" 2>/dev/null || echo "无法转换路径")
            echo "         Windows 路径：$win_path"
            echo "         复制命令：cp \"$win_path\" \"\$env:USERPROFILE\\.wezterm.lua\""
        fi
    else
        fail "wezterm.lua 不存在"
    fi
}

# ============================================================
# 主函数
# ============================================================
main() {
    if [[ "${1:-}" == "--verbose" ]]; then
        VERBOSE=true
    fi

    echo ""
    echo "=================================================="
    echo "  开发环境验证报告"
    echo "  $(date '+%Y-%m-%d %H:%M:%S')"
    echo "=================================================="
    echo ""

    echo "  当前系统：$CURRENT_OS"
    echo ""

    check_shell
    check_prompt
    check_search_tools
    check_neovim
    check_python
    check_eda_tools
    check_centos_specific
    check_paths
    # WezTerm 仅在 Ubuntu/WSL2 有意义
    [[ "$CURRENT_OS" != "centos" ]] && check_wezterm_config

    # ---- 汇总 ----
    echo ""
    echo "=================================================="
    echo -e "  结果：${C_GREEN}${PASS} 通过${C_RESET} | ${C_RED}${FAIL} 失败${C_RESET} | ${C_YELLOW}${WARN} 警告${C_RESET}"
    echo "=================================================="
    echo ""

    if [[ $FAIL -gt 0 ]]; then
        echo "  存在失败项，请运行 ./setup.sh 安装缺失组件"
        echo ""
        exit 1
    elif [[ $WARN -gt 0 ]]; then
        echo "  存在警告项，部分功能可能需要重新登录后生效"
        echo ""
        exit 0
    else
        echo "  所有检查通过！开发环境已就绪"
        echo ""
        exit 0
    fi
}

main "$@"
