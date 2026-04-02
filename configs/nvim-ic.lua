-- ============================================================
-- Neovim IC 工具插件配置
-- 路径：~/.config/nvim/lua/plugins/ic.lua
-- 功能：
--   - Verilog / SystemVerilog 语法高亮（treesitter）
--   - Verible LSP（格式化 + 语义高亮 + 错误提示）
--   - Python LSP（Pyright，pyenv 感知）
--   - 辅助工具：自动对齐、注释插件
-- ============================================================

-- WSL2 剪贴板配置：使用 win32yank.exe 打通 Neovim 与 Windows 剪贴板
-- 使 y/d/p 直接操作系统剪贴板，无需手动加 "+
if vim.fn.has("wsl") == 1 then
  vim.g.clipboard = {
    name  = "win32yank",
    copy  = {
      ["+"] = "win32yank.exe -i --crlf",
      ["*"] = "win32yank.exe -i --crlf",
    },
    paste = {
      ["+"] = "win32yank.exe -o --lf",
      ["*"] = "win32yank.exe -o --lf",
    },
    cache_enabled = 0,
  }
  -- 所有 yank/delete/paste 默认走系统剪贴板
  vim.opt.clipboard = "unnamedplus"
end

return {

  -- ============================================================
  -- 1. Treesitter：Verilog/SV/VHDL 语法高亮与缩进
  -- ============================================================
  {
    "nvim-treesitter/nvim-treesitter",
    opts = function(_, opts)
      -- 追加 IC 相关语言（LazyVim 已有默认列表，用 vim.list_extend 合并）
      vim.list_extend(opts.ensure_installed, {
        "verilog",       -- Verilog / SystemVerilog（同一个 grammar）
        "python",
        "bash",
        "make",
        "tcl",           -- EDA 脚本常用
      })
    end,
  },

  -- ============================================================
  -- 2. Mason：自动安装 LSP / 格式化工具
  -- ============================================================
  {
    "mason-org/mason.nvim",
    opts = function(_, opts)
      -- mason-lspconfig 管理的 LSP 服务器
      vim.list_extend(opts.ensure_installed or {}, {
        "pyright",                -- Python LSP
        -- 注意：verible 通过系统路径使用，不经由 mason 安装
        -- 因为 mason 提供的版本可能与你安装的 Verible 不一致
      })
    end,
  },

  -- ============================================================
  -- 3. nvim-lspconfig：配置 Verible LSP 和 Pyright
  -- ============================================================
  {
    "neovim/nvim-lspconfig",
    opts = {
      servers = {

        -- ---- Verible LSP（verible-verilog-ls）----
        -- 需要先通过 setup.sh 安装 Verible（~/.local/bin/verible-verilog-ls）
        verible = {
          cmd = { "verible-verilog-ls", "--rules_config_search" },
          filetypes = { "verilog", "systemverilog" },
          root_dir = function(fname)
            -- 从当前文件向上查找工程根目录标志
            local lspconfig = require("lspconfig")
            return lspconfig.util.root_pattern(
              ".verible_verilog_format",
              ".veriblelint",
              "Makefile",
              ".git"
            )(fname) or vim.fn.getcwd()
          end,
          settings = {
            -- Verible 格式化选项
            -- 列宽 100，与大多数 IC 公司编码规范匹配
          },
          -- 格式化命令（使用 verible-verilog-format）
          on_attach = function(client, bufnr)
            -- 绑定格式化快捷键
            vim.keymap.set("n", "<leader>cf", function()
              vim.lsp.buf.format({ async = true })
            end, { buffer = bufnr, desc = "Format (Verible)" })

            -- 绑定 lint 快速修复
            vim.keymap.set("n", "<leader>ca", vim.lsp.buf.code_action, {
              buffer = bufnr,
              desc = "Code Action",
            })
          end,
        },

        -- ---- Pyright（Python LSP）----
        pyright = {
          settings = {
            python = {
              analysis = {
                typeCheckingMode = "basic",    -- basic / strict / off
                autoSearchPaths = true,
                useLibraryCodeForTypes = true,
              },
              -- pyenv 支持：自动读取 .python-version
              pythonPath = vim.fn.exepath("python") ~= "" and vim.fn.exepath("python") or nil,
            },
          },
        },
      },
    },
  },

  -- ============================================================
  -- 4. conform.nvim：格式化工具配置
  -- ============================================================
  {
    "stevearc/conform.nvim",
    opts = {
      formatters_by_ft = {
        -- Verilog/SV：使用 verible-verilog-format
        verilog = { "verible_verilog_format" },
        systemverilog = { "verible_verilog_format" },
        -- Python：优先 ruff，再用 black
        python = { "ruff_format", "black" },
      },
      -- 自定义 verible-verilog-format 格式化器
      formatters = {
        verible_verilog_format = {
          command = "verible-verilog-format",
          args = {
            "--column_limit=100",
            "--indentation_spaces=2",
            "--port_declarations_alignment=align",
            "--named_port_alignment=align",
            "--named_parameter_alignment=align",
            "--assignment_statement_alignment=align",
            "--module_net_variable_alignment=align",
            "-",      -- 从 stdin 读取
          },
          stdin = true,
        },
      },
      -- 保存时自动格式化（去掉注释即可禁用）
      format_on_save = {
        timeout_ms = 3000,
        lsp_format = "fallback",
      },
    },
  },

  -- ============================================================
  -- 5. nvim-lint：静态检查（Verible lint）
  -- ============================================================
  {
    "mfussenegger/nvim-lint",
    optional = true,
    opts = {
      linters_by_ft = {
        verilog = { "verible_verilog_lint" },
        systemverilog = { "verible_verilog_lint" },
      },
    },
    config = function(_, opts)
      local lint = require("lint")

      -- 自定义 verible-verilog-lint linter
      -- 输出格式：filename:line:col: message [rule-name]
      lint.linters.verible_verilog_lint = {
        cmd = "verible-verilog-lint",
        args = {
          "--ruleset=default",
          "--rules=-line-length",   -- 行长由 format 控制，lint 不重复检查
        },
        stream = "stdout",
        ignore_exitcode = true,
        parser = function(output, _)
          local diagnostics = {}
          for line in output:gmatch("[^\n]+") do
            -- 格式：filename:lnum:col: message [rule]
            local lnum, col, msg = line:match(":(%d+):(%d+):%s+(.+)$")
            if lnum then
              table.insert(diagnostics, {
                lnum     = tonumber(lnum) - 1,  -- nvim 行号从 0 开始
                col      = tonumber(col) - 1,
                message  = msg,
                severity = vim.diagnostic.severity.WARN,
                source   = "verible-lint",
              })
            end
          end
          return diagnostics
        end,
      }

      lint.linters_by_ft = vim.tbl_deep_extend("force",
        lint.linters_by_ft or {}, opts.linters_by_ft or {})

      -- 保存时自动触发 lint
      vim.api.nvim_create_autocmd({ "BufWritePost", "BufReadPost" }, {
        callback = function()
          lint.try_lint()
        end,
      })
    end,
  },

  -- ============================================================
  -- 6. 文件类型关联（.sv / .svh / .vh 识别为 SystemVerilog）
  -- ============================================================
  {
    "LazyVim/LazyVim",
    opts = function()
      -- 在 vim.filetype 中注册 SV 扩展名
      vim.filetype.add({
        extension = {
          sv  = "systemverilog",
          svh = "systemverilog",
          vh  = "verilog",         -- header 文件按 verilog 处理
        },
      })
    end,
  },

  -- ============================================================
  -- 7. 对齐插件（IC 代码常见对齐需求）
  -- ============================================================
  {
    "nvim-mini/mini.align",
    name  = "mini.align",
    event = "VeryLazy",
    opts  = {},
    keys  = {
      { "ga", mode = { "n", "v" }, desc = "Align (mini.align)" },
      { "gA", mode = { "n", "v" }, desc = "Align with preview" },
    },
  },

}
