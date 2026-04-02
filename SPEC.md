# linux_env_setup — 产品需求文档（PRD）

> **面向 AI 开发者的阅读指引**
> 本文档描述产品的目标、用户、设计决策与功能全貌，是持续开发的核心参考。
> 接手开发前请先读完本文件，再读 `CLAUDE.md`（编码规范），最后读 `plan.md`（当前迭代计划）。

---

## 1. 产品定位

**一句话**：面向数字 IC 工程师的开发环境自动化配置工具，一条命令搭建完整的现代化工作环境。

**核心价值**：
- 消除"新机器配置"的重复劳动（本地 WSL2 + 公司 CentOS 服务器各有一套配置要搞）
- 配置结果可验证（`test_setup.sh` 给出明确 PASS/FAIL）
- 可重复运行（幂等），不怕手滑跑两次
- 修改任何文件前自动备份，配坏了能还原

---

## 2. 目标用户

**用户画像**：薛宋军（xuesongjun）— 数字 IC 设计工程师

| 属性 | 描述 |
|------|------|
| 主要工作 | Verilog / SystemVerilog 设计与验证 |
| 公司工具 | Synopsys VCS、Verdi（商业工具，公司统一管理） |
| 脚本语言 | Python（写自动化脚本）、偶尔 Perl |
| 编辑器 | 熟悉 Vim，正在迁移到 Neovim |
| 工作环境 | 两套：本地 Windows 11 WSL2 Ubuntu + 公司 CentOS 服务器 |
| 服务器限制 | 无 sudo、无网络、默认 csh/tcsh、通过 FTP 传文件 |
| 个人偏好 | 愿意折腾，追求现代化工具链，但不想每次换机器都重新折腾 |

---

## 3. 使用场景

### 场景 A：本地 WSL2（主力开发）

```
Windows 11
└── WSL2 Ubuntu 24.04
    ├── Neovim + LazyVim（Verilog/Python 开发）
    ├── Zsh + Starship（现代 shell）
    ├── fzf / ripgrep / fd（高效导航）
    ├── Verilator + Verible + Icarus（开源 EDA）
    └── pyenv + Python 3.12（脚本环境）

终端：WezTerm（Windows 侧，替代 Windows Terminal）
```

### 场景 B：公司 CentOS 服务器（远程工作）

```
CentOS 7/8 服务器
├── 商业 EDA 工具（VCS、Verdi 等，管理员已装）
├── Neovim + Verible LSP（在服务器上编辑 RTL）
├── Zsh（从 csh/tcsh 自动切换）
└── pyenv + Python（自动化脚本）

约束：无 sudo、无网络、只能 FTP 传文件
```

---

## 4. 已实现功能

### 4.1 主安装脚本 `setup.sh`

**支持参数：**

| 参数 | 说明 |
|------|------|
| `--offline` | 离线模式，从 `bundle/` 读取所有组件 |
| `--verilator-source` | Verilator 从源码编译（v5.x，Ubuntu 场景） |
| `--only <模块列表>` | 只运行指定模块，逗号分隔 |
| `--skip <模块列表>` | 跳过指定模块 |

**环境自动探测（`detect_env()`）：**

| 变量 | 值 | 用途 |
|------|----|------|
| `OS_TYPE` | ubuntu / centos / unknown | 决定包管理器和安装路径 |
| `HAS_SUDO` | true / false | 决定是否可以用包管理器 |
| `CSH_MODE` | true / false | 是否需要在 .cshrc 中追加 exec zsh |
| `IS_OFFLINE` | true / false | 是否从 bundle/ 读取 |

**9 个功能模块：**

| 模块 | Ubuntu（在线） | CentOS（离线，无 sudo） |
|------|---------------|------------------------|
| `prerequisites` | apt install 基础包 | 跳过（提示管理员安装） |
| `zsh` | apt install + chsh | 源码编译 → .cshrc exec 切换 |
| `starship` | 官方脚本安装 | bundle 静态二进制 |
| `fzf` | git clone + install | bundle 二进制 + shell 集成脚本 |
| `dev_tools` | apt install rg/fd | bundle 静态二进制 |
| `neovim` | AppImage（在线） | AppImage 解压模式（bundle） |
| `pyenv` | git clone | bundle tar.gz + 源码包 cache |
| `eda_tools` | 全套（iverilog/Verilator/Verible/GTKWave） | 只装 Verible（静态二进制）|
| `wezterm_config` | 输出 Windows 侧安装指引 | 跳过 |

### 4.2 离线打包脚本 `scripts/bundle_prepare.sh`

在有网络的本地机器运行，6 个步骤：
1. 下载所有静态链接预编译二进制（starship/nvim/fzf/rg/fd/verible）
2. 下载源码包（zsh-5.9.tar.xz / Python-3.12.10.tar.xz）
3. 打包 git 插件仓库（zsh 插件 / pyenv / fzf-shell 集成脚本）
4. 预安装 Neovim 插件（隔离 XDG 环境，headless 运行 LazyVim sync）
5. 完整性校验
6. 打包为单一 `linux_env_setup_bundle_YYYYMMDD.tar.gz` 供 FTP 上传

### 4.3 服务器安装脚本 `scripts/server_install.sh`

FTP 取包 → 解压 → 进目录 → `./setup.sh --offline`

### 4.4 配置文件 `configs/`

| 文件 | 说明 |
|------|------|
| `zshrc` | Zsh 配置：插件 + fzf + pyenv + Starship + WSL2 剪贴板集成 + .zshrc.local 扩展点 |
| `starship.toml` | 提示符：git 状态 + Python 版本 + 执行时间，右侧显示时钟 |
| `nvim-ic.lua` | LazyVim 插件配置：Verible LSP + Verilog/SV treesitter + Pyright + mini.align |
| `wezterm.lua` | WezTerm 配置：Sarasa Term SC Nerd Font + Tokyo Night + WSL2 直连 |

### 4.5 验证脚本 `test_setup.sh`

逐项检查所有已安装组件，根据 `OS_TYPE` 自动跳过不适用的检查。
输出 PASS / FAIL / WARN，失败时退出码非 0。

---

## 5. 关键设计决策（及原因）

记录这些是为了避免后续开发误改或重复讨论。

| 决策 | 选择 | 原因 |
|------|------|------|
| Shell | Zsh（不用 Fish/Oh My Zsh） | Fish 语法不兼容 POSIX，Oh My Zsh 过重；原生 Zsh + 三个插件足够 |
| 提示符 | Starship | 跨 Shell、跨平台，配置简单，速度快 |
| Neovim 配置 | LazyVim starter + 自定义 `plugins/ic.lua` | LazyVim 维护了基础，ic.lua 只加 IC 相关内容，互不干扰 |
| Python 版本管理 | pyenv（不用 conda/miniconda） | IC 脚本场景轻量即可，pyenv 无虚拟环境开销，与 shell 集成干净 |
| 静态链接二进制 | 所有跨平台二进制用 musl 静态编译版本 | 兼容 CentOS 7 的 glibc 2.17，无需任何动态库依赖 |
| csh → zsh 切换 | `.cshrc` 追加 `exec zsh -l` | 无法 chsh（没有 sudo）；`exec` 替换进程，保证 SSH 会话正确 |
| Verilator on CentOS | 跳过 | 服务器有商业 EDA 工具，Verilator 主要用于本地仿真 |
| WezTerm 字体 | Sarasa Term SC Nerd Font | 唯一同时满足：中英文 2:1 等宽 + Nerd Font 图标 + 编程友好 |
| bundle 打包 | 单一 tar.gz（非多文件） | FTP 只需 `ftp get` 一次，减少手动操作 |
| Neovim 插件离线方案 | 隔离 XDG 环境 headless 预装 | 避免污染本机 nvim 配置，产出的 bundle 可直接解压使用 |
| 备份机制 | `~/.config_backup/时间戳/` | 每次运行生成唯一目录，不覆盖历史备份，按时间戳查找 |

---

## 6. 版本常量（所有版本号集中管理）

修改版本时，`setup.sh` 和 `scripts/bundle_prepare.sh` 两个文件的顶部常量需同步更新。

| 常量 | 当前值 |
|------|--------|
| `PYTHON_VERSION` | 3.12.10 |
| `NEOVIM_VERSION` | 0.10.4 |
| `VERIBLE_VERSION` | 0.0-3793-g4294133e |
| `ZSH_VERSION_SRC` | 5.9 |
| `FZF_VERSION` | 0.62.0 |
| `RG_VERSION` | 14.1.1 |
| `FD_VERSION` | 10.2.0 |

---

## 7. 已知限制与 TODO

> 这里记录已知的不完善之处，不是 bug，是有意识的取舍或待完善项。

- [ ] **Neovim treesitter 跨平台**：bundle 中的 treesitter parser `.so` 文件在 Ubuntu 下编译，在 CentOS 7 上可能因 glibc 版本不同无法加载，首次运行 nvim 时会触发重新编译（CentOS 有 gcc，能编译，只是慢一次）
- [ ] **bundle 大小估计**：完整 bundle 约 500-700MB，实际大小取决于 Neovim 插件数量，未精确测量
- [ ] **pyenv 编译依赖**：CentOS 无 sudo 时，若系统缺少 `zlib-devel` 等编译依赖，Python 编译会失败。目前只打印警告，无自动处理
- [ ] **WezTerm 字体自动安装**：目前只输出手动安装指引，未实现自动下载安装 Sarasa Term SC Nerd Font
- [ ] **Perl 环境**：用户提到 Perl，目前未配置 Perl 版本管理（plenv）或 cpanm

---

## 8. 待开发需求（Backlog）

> 用户可以在此追加新需求，每条写清楚：**做什么、为什么、优先级**。
> AI 开发者接手时从这里选取需求，制定 plan.md，等用户确认后再实现。

### 优先级说明
- P0：阻塞日常使用，必须先做
- P1：重要但有替代方案
- P2：有则更好，可推迟

---

<!-- 在此追加新需求，格式参考下方示例 -->

<!-- 需求示例（已注释，勿删，作为格式参考）：

### [P1] 功能名称
**需求**：用一句话描述要做什么。
**原因**：为什么需要这个功能，解决什么痛点。
**细节**：可选，补充实现上需要注意的点。
**状态**：待开发 / 开发中 / 已完成

-->

---

## 9. 项目文件职责速查

| 文件 | 职责 | 读者 |
|------|------|------|
| `SPEC.md` | 产品需求、设计决策、功能全貌（本文件） | AI 开发者 |
| `CLAUDE.md` | 编码规范、工作流程、禁止事项 | AI 开发者 |
| `plan.md` | 当前迭代的实现方案（临时，完成后归档） | AI 开发者 |
| `README.md` | 安装使用说明 | 用户 |
| `setup.sh` | 主安装脚本 | 脚本（被用户执行） |
| `test_setup.sh` | 验证脚本 | 脚本（被用户执行） |
| `scripts/bundle_prepare.sh` | 离线包生成脚本 | 脚本（在有网机器执行）|
| `scripts/server_install.sh` | 服务器端安装脚本 | 脚本（在服务器执行） |
| `configs/` | 配置模板文件 | 被 setup.sh 安装到用户目录 |
