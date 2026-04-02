# Linux 环境配置项目 - Claude 开发规范

## AI 开发者阅读顺序

1. `SPEC.md` — 产品需求、用户画像、功能全貌、设计决策（**先读这个**）
2. `CLAUDE.md` — 编码规范与工作流（本文件）
3. `plan.md` — 当前迭代方案（如存在）

## 项目概述

目标平台：Ubuntu 24.04 / WSL2（在线，有 sudo）+ CentOS 7/8 服务器（离线，无 sudo）
用途：数字 IC 工程师开发环境一键配置

## 技术选型

- **主语言：Bash**（无外部依赖，Linux 原生，适合系统配置脚本）
- **配置模板**：独立文件放在 `configs/` 目录
- **验证脚本**：`test_setup.sh`

## 代码风格

### 函数规范
```bash
# 每个模块一个函数，函数名 setup_xxx
# 成功返回 0，失败返回 1
setup_zsh() {
    log_step "配置 Zsh..."
    ...
    return 0
}
```

### 日志函数（统一使用）
```bash
log_step()  # [*] 蓝色，步骤开始
log_ok()    # [OK] 绿色，成功
log_warn()  # [WARN] 黄色，警告
log_err()   # [ERROR] 红色，失败
```

### 幂等性原则
- 每个 setup 函数**必须支持重复运行**（已安装则跳过，已配置则更新）
- 用 `command -v xxx` 检查命令是否存在
- 用文件内容关键字检查配置是否已写入

### 备份规范（强制）
- 修改任何已存在的配置文件前，**必须先备份**
- 统一备份到 `~/.config_backup/YYYYMMDD_HHMMSS/`
- 使用公共函数 `backup_file <path>`，不允许直接覆盖

```bash
backup_file() {
    local file="$1"
    if [[ -f "$file" ]]; then
        local backup_dir="$HOME/.config_backup/$(date +%Y%m%d_%H%M%S)"
        mkdir -p "$backup_dir"
        cp "$file" "$backup_dir/$(basename "$file")"
        log_ok "已备份: $file → $backup_dir"
    fi
}
```

### 错误处理
```bash
set -euo pipefail  # 脚本顶部设置
```
- 关键步骤失败后打印错误并 return 1，不直接 exit（允许主函数汇总结果）
- 非关键步骤（如可选工具）失败只 warn，不中断流程

## 配置文件管理

- 所有配置模板放 `configs/` 目录
- 写入用户目录时用 `install_config <src> <dst>` 公共函数（内含备份逻辑）
- 不硬编码用户路径，统一用 `$HOME`

## 模块划分

| 函数 | 说明 |
|------|------|
| `setup_prerequisites` | apt 更新，基础依赖 |
| `setup_zsh` | Zsh + 插件 |
| `setup_starship` | Starship 提示符 |
| `setup_fzf` | 模糊搜索 |
| `setup_neovim` | Neovim + LazyVim |
| `setup_pyenv` | pyenv + Python |
| `setup_dev_tools` | ripgrep / fd / git 配置 |
| `setup_eda_tools` | Verilator / Verible / Icarus / GTKWave |
| `setup_wezterm_config` | 输出 WezTerm 配置文件（Windows 侧使用） |

## 禁止事项

- 禁止用 `sudo` 安装到用户目录（`~/.local`、`~/.config` 等不需要 sudo）
- 禁止无备份直接覆盖已存在的配置文件
- 禁止硬编码版本号为常量以外的地方（版本号统一在脚本顶部定义）
- 禁止假设网络畅通（下载前先检查，失败给出手动安装提示）
