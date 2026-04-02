# linux_env_setup

Ubuntu 24.04 / WSL2 & CentOS 服务器 开发环境一键配置，面向数字 IC 工程师。

## 支持场景

| 场景 | 系统 | 权限 | 网络 |
|------|------|------|------|
| 本地开发 | Ubuntu 24.04 / WSL2 | 有 sudo | 有网 |
| 公司服务器 | CentOS 7/8 | 无 sudo | 无网，FTP 传入 |

## 特性

- 幂等：可重复运行，已安装的组件自动跳过
- 备份：修改任何配置文件前自动备份到 `~/.config_backup/`
- 模块化：可通过 `--only` / `--skip` 参数选择性安装
- 无 sudo 模式：所有组件安装到 `~/.local/`，无需管理员权限
- 离线模式：从预打包的 `bundle/` 目录安装，无需网络

## 安装内容

| 组件 | 说明 |
|------|------|
| Zsh + 插件 | zsh-autosuggestions / syntax-highlighting / completions |
| Starship | 极速跨 Shell 提示符，显示 git 状态、Python 版本、执行时间 |
| fzf | 模糊搜索，Ctrl+R 历史、Ctrl+T 文件搜索 |
| ripgrep / fd | 高性能文件内容搜索 / 文件搜索 |
| Neovim v0.10 | LazyVim 配置 + Verible LSP + Verilog/SV 语法高亮 |
| pyenv + Python | pyenv 管理 Python 版本，默认安装 3.12.10 |
| Icarus Verilog | 开源 Verilog 仿真器 |
| Verilator | 高性能 Verilog/SV 仿真器（默认 apt，可选源码编译） |
| Verible | Verilog/SV lint + format + LSP |
| GTKWave | 波形查看器（WSL2 + WSLg 可直接使用 GUI） |
| WezTerm 配置 | Windows 终端配置文件，含字体、颜色、快捷键 |

## 快速开始

### Ubuntu / WSL2（在线）

```bash
git clone <repo-url> ~/linux_env_setup
cd ~/linux_env_setup
chmod +x setup.sh test_setup.sh scripts/*.sh
./setup.sh
exec zsh          # 切换到 zsh（或重新登录）
./test_setup.sh   # 验证安装结果
```

### CentOS 服务器（离线，无 sudo）

**第一步：在 WSL2 本地打包（需要网络）**

```bash
cd ~/linux_env_setup
./scripts/bundle_prepare.sh
# 产出：../linux_env_setup_bundle_YYYYMMDD.tar.gz（约 500-700MB）
```

**第二步：上传到 FTP 中间服务器**

将 `linux_env_setup_bundle_YYYYMMDD.tar.gz` 上传到 FTP 中间服务器。

**第三步：在 CentOS 服务器安装**

```bash
# 方式 A：一键脚本（提前将 server_install.sh 复制到服务器）
bash server_install.sh linux_env_setup_bundle_20260402.tar.gz

# 方式 B：手动执行
ftp get linux_env_setup_bundle_20260402.tar.gz
tar -xzf linux_env_setup_bundle_20260402.tar.gz
cd linux_env_setup
./setup.sh --offline
```

**第四步：重新登录**

CentOS 默认 shell 为 csh/tcsh，安装后 `~/.cshrc` 已追加：
```csh
if ( -x ~/.local/bin/zsh ) exec ~/.local/bin/zsh
```
重新 SSH 登录后自动切换到 zsh。

## 用法参数

```bash
./setup.sh                       # 全量安装（推荐）
./setup.sh --verilator-source    # Verilator 从源码编译 v5.x（需要 10-20 分钟）
./setup.sh --only zsh,neovim     # 只安装指定模块
./setup.sh --skip eda_tools      # 跳过指定模块
./setup.sh --help                # 显示帮助
```

可用模块名：`prerequisites` `zsh` `starship` `fzf` `dev_tools` `neovim` `pyenv` `eda_tools` `wezterm_config`

## 项目结构

```
linux_env_setup/
├── setup.sh                    # 主配置脚本（Ubuntu + CentOS 双场景）
├── test_setup.sh               # 验证脚本
├── README.md
├── CLAUDE.md                   # Claude 开发规范
├── scripts/
│   ├── bundle_prepare.sh       # 在有网机器打包所有组件（供 FTP 传输）
│   └── server_install.sh       # 在服务器端一键取包+安装
├── configs/
│   ├── zshrc                   # Zsh 配置模板
│   ├── starship.toml           # Starship 提示符配置
│   ├── nvim-ic.lua             # Neovim IC 工具插件配置
│   └── wezterm.lua             # WezTerm 配置（Windows 侧使用）
├── bundle/                     # 由 bundle_prepare.sh 生成，不提交到 git
│   ├── *.tar.gz / *.appimage   # 预编译二进制
│   ├── plugins/                # zsh 插件 tarball
│   ├── nvim-config.tar.gz      # 预构建 Neovim 配置
│   └── nvim-plugins.tar.gz     # 预安装 LazyVim 插件
└── .gitignore
```

## WezTerm 配置（Windows 侧）

`configs/wezterm.lua` 需要复制到 Windows 侧使用：

```powershell
# 在 PowerShell 中执行（替换为实际路径）
cp "\\wsl.localhost\Ubuntu-24.04\home\<用户名>\linux_env_setup\configs\wezterm.lua" "$env:USERPROFILE\.wezterm.lua"
```

字体需要在 Windows 侧安装 **Sarasa Term SC Nerd Font**（更纱等距黑体）：
- 下载：[Nerd Fonts Releases](https://github.com/ryanoasis/nerd-fonts/releases) → 搜索 `SarasaTermSC.zip`
- 全选字体文件 → 右键 → 为所有用户安装

## Neovim 快捷键（IC 相关）

| 快捷键 | 功能 |
|--------|------|
| `<leader>cf` | 格式化当前文件（Verible format / ruff） |
| `<leader>ca` | 代码操作（快速修复 lint 问题） |
| `ga` / `gA` | 对齐代码（mini.align） |
| `K` | 查看 LSP hover 文档 |
| `gd` | 跳转到定义 |
| `gr` | 查找引用 |

## 备份机制

每次运行 `setup.sh` 时，将要修改的文件会自动备份到：

```
~/.config_backup/
└── 20260402_143022/    ← 时间戳目录
    ├── .zshrc
    └── nvim/
```

## CentOS 安装内容

CentOS 服务器场景（无 sudo + 离线）只安装以下组件，其余 EDA 工具由服务器管理员提供：

| 组件 | 说明 |
|------|------|
| zsh | 从源码编译安装到 `~/.local/bin/zsh` |
| Starship | 静态链接二进制 |
| fzf / ripgrep / fd | 静态链接二进制 |
| Neovim | AppImage 解压模式 |
| pyenv + Python | 源码编译 |
| **Verible** | 静态链接二进制（lint + format + LSP） |

## 常见问题

**Q: Neovim AppImage 报 FUSE 错误**

WSL2 默认不支持 FUSE，`setup.sh` 已自动切换到解压模式，无需手动处理。

**Q: GTKWave 无法打开 GUI**

需要 Windows 11 + WSLg。在 Windows 11 上运行 `wsl --update` 更新到支持 WSLg 的版本。

**Q: Verible LSP 在 Neovim 中不工作**

确认 `verible-verilog-ls` 已在 PATH 中：

```bash
which verible-verilog-ls
# 应输出：/home/<用户>/.local/bin/verible-verilog-ls
```

如果不在，重新运行：`./setup.sh --only eda_tools`

**Q: pyenv install 失败（编译错误）**

缺少编译依赖，运行：

```bash
./setup.sh --only prerequisites
pyenv install 3.12.10
```

**Q: CentOS 服务器登录后没有切换到 zsh**

检查 `~/.cshrc` 或 `~/.tcshrc` 末尾是否有：
```csh
if ( -x ~/.local/bin/zsh ) exec ~/.local/bin/zsh
```
若无，重新运行：`./setup.sh --offline --only zsh`

**Q: bundle_prepare.sh 报 "nvim 未安装，跳过插件预安装"**

先在 WSL2 运行 `./setup.sh` 安装 nvim，再重新运行 `bundle_prepare.sh`。
或者接受首次在服务器运行 nvim 时在线安装插件（此时需要临时网络）。

**Q: FTP 取包时文件名记不住**

`bundle_prepare.sh` 运行结束后会打印完整的 `ftp get` 命令，复制执行即可。
