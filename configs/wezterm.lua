-- ============================================================
-- WezTerm 配置文件
-- Windows 侧安装路径：%USERPROFILE%\.wezterm.lua
-- 功能：默认打开 WSL2 Ubuntu，中英文等宽字体，IC 开发友好
-- ============================================================

local wezterm = require("wezterm")
local act = wezterm.action

local config = wezterm.config_builder()

-- ============================================================
-- 默认 Shell：直接打开 WSL2 Ubuntu
-- ============================================================
config.default_prog = { "wsl.exe", "--distribution", "Ubuntu-24.04" }

-- 若上面的发行版名称不匹配，改为：
-- config.default_prog = { "wsl.exe" }    -- 打开默认发行版

-- ============================================================
-- 字体配置
-- 主字体：Sarasa Term SC Nerd Font（更纱等距黑体）
--   中英文 2:1 严格等宽，内置 Nerd Font 图标
--   下载：https://github.com/ryanoasis/nerd-fonts/releases → SarasaTermSC.zip
-- 备用字体（未安装主字体时自动 fallback）
-- ============================================================
config.font = wezterm.font_with_fallback({
  { family = "Sarasa Term SC Nerd Font", weight = "Regular" },
  { family = "Cascadia Code NF",         weight = "Regular" },  -- 备用
  { family = "JetBrainsMono Nerd Font",  weight = "Regular" },  -- 备用
  { family = "Microsoft YaHei Mono" },                          -- 终极中文 fallback
})
config.font_size = 13.0

-- 连字（Ligature）：对 IC 代码可能干扰，按需开启
-- config.harfbuzz_features = { "calt=0", "clig=0", "liga=0" }  -- 禁用连字
config.harfbuzz_features = { "calt=1", "clig=1", "liga=1" }    -- 启用连字（默认）

-- ============================================================
-- 颜色主题：Tokyo Night（深色，IC 长时间工作友好）
-- 备选：Catppuccin Mocha / Gruvbox Dark
-- ============================================================
config.color_scheme = "Tokyo Night"

-- ============================================================
-- 窗口外观
-- ============================================================
config.window_background_opacity = 0.95   -- 轻微透明（0.0~1.0）
config.text_background_opacity    = 1.0   -- 文字背景不透明

-- 窗口内边距（避免文字贴边）
config.window_padding = {
  left   = 8,
  right  = 8,
  top    = 4,
  bottom = 4,
}

-- 初始窗口大小
config.initial_cols = 220
config.initial_rows = 55

-- 去除系统标题栏（更简洁），WezTerm 自带标签页
config.window_decorations = "RESIZE"

-- ============================================================
-- 标签栏
-- ============================================================
config.enable_tab_bar        = true
config.use_fancy_tab_bar     = false   -- 使用简洁样式
config.hide_tab_bar_if_only_one_tab = true   -- 只有一个标签时隐藏

config.tab_bar_at_bottom = false       -- 标签栏在顶部

-- 标签标题：显示序号 + 进程名
wezterm.on("format-tab-title", function(tab, _, _, _, _, _)
  local title = tab.tab_index + 1 .. ": " .. tab.active_pane.title
  return { { Text = " " .. title .. " " } }
end)

-- ============================================================
-- 滚动缓冲区（Claude Code 等 TUI 应用需要足够大的缓冲）
-- ============================================================
config.scrollback_lines = 10000

-- ============================================================
-- 键盘绑定
-- ============================================================
config.keys = {
  -- 新建标签页（Ctrl+T）
  { key = "t", mods = "CTRL", action = act.SpawnTab("CurrentPaneDomain") },
  -- 关闭标签页（Ctrl+W）
  { key = "w", mods = "CTRL", action = act.CloseCurrentTab({ confirm = false }) },
  -- 切换标签页（Ctrl+Tab / Ctrl+Shift+Tab）
  { key = "Tab",       mods = "CTRL",       action = act.ActivateTabRelative(1) },
  { key = "Tab",       mods = "CTRL|SHIFT", action = act.ActivateTabRelative(-1) },
  -- 分割窗口（水平/垂直）
  { key = "-", mods = "CTRL|SHIFT", action = act.SplitVertical({ domain = "CurrentPaneDomain" }) },
  { key = "\\",mods = "CTRL|SHIFT", action = act.SplitHorizontal({ domain = "CurrentPaneDomain" }) },
  -- 窗格导航（Ctrl + 方向键）
  { key = "LeftArrow",  mods = "CTRL", action = act.ActivatePaneDirection("Left") },
  { key = "RightArrow", mods = "CTRL", action = act.ActivatePaneDirection("Right") },
  { key = "UpArrow",    mods = "CTRL", action = act.ActivatePaneDirection("Up") },
  { key = "DownArrow",  mods = "CTRL", action = act.ActivatePaneDirection("Down") },
  -- 字体大小调整
  { key = "=", mods = "CTRL", action = act.IncreaseFontSize },
  { key = "-", mods = "CTRL", action = act.DecreaseFontSize },
  { key = "0", mods = "CTRL", action = act.ResetFontSize },
  -- 搜索（Ctrl+F）
  { key = "f", mods = "CTRL", action = act.Search({ CaseInSensitiveString = "" }) },
  -- 复制选中文本（自动，同时支持右键粘贴）
  { key = "c", mods = "CTRL|SHIFT", action = act.CopyTo("Clipboard") },
  { key = "v", mods = "CTRL|SHIFT", action = act.PasteFrom("Clipboard") },
}

-- ============================================================
-- 鼠标行为
-- ============================================================
config.mouse_bindings = {
  -- 中键粘贴（Linux 传统：选中即复制到 PrimarySelection，中键粘贴）
  {
    event  = { Down = { streak = 1, button = "Middle" } },
    mods   = "NONE",
    action = act.PasteFrom("PrimarySelection"),
  },
  -- 右键粘贴（同上，兼容无中键鼠标）
  {
    event  = { Down = { streak = 1, button = "Right" } },
    mods   = "NONE",
    action = act.PasteFrom("PrimarySelection"),
  },
}

-- 选中即复制到剪贴板
config.selection_word_boundary = " \t\n{}[]()\"'`"

-- ============================================================
-- 性能与兼容性
-- ============================================================
config.max_fps = 60

-- WSL2 下使用 xterm-256color 保证最佳兼容性
-- （部分旧 EDA 工具不识别 wezterm）
config.term = "xterm-256color"

-- Bell 静音（编译/仿真结束的提示音由脚本自己控制）
config.audible_bell = "Disabled"
config.visual_bell  = { fade_in_duration_ms = 0, fade_out_duration_ms = 0 }

return config
