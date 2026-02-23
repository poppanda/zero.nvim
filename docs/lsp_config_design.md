# LSP Configuration Design (LSP 配置设计)

## Overview (概述)

为了支持不同语言服务器 (LSP) 的个性化配置（例如 Python 的解释器路径、Lua 的全局变量等），`zero-nvim` 引入了一个统一的配置机制。该机制允许用户在 `setup()` 函数中定义服务器特定的设置，并在调用 `:ZeroLspStart` 命令时自动应用这些设置。

## Configuration Structure (配置结构)

用户可以在 `require("zero-nvim").setup()` 中通过 `lsp` 表来配置服务器。

```lua
require("zero-nvim").setup({
    -- ... 其他配置 ...
    lsp = {
        servers = {
            -- 键名 (Key) 必须匹配传递给 :ZeroLspStart 的二进制名称
            ["basedpyright-langserver"] = {
                -- settings 表会直接传递给 vim.lsp.start_client 的 settings 参数
                settings = {
                    python = {
                        analysis = {
                            autoSearchPaths = true,
                            useLibraryCodeForTypes = true,
                            diagnosticMode = "workspace"
                        },
                        -- 指定远程服务器上的 Python 解释器路径
                        pythonPath = "/usr/bin/python3"
                    }
                }
            },
            ["lua-language-server"] = {
                settings = {
                    Lua = {
                        diagnostics = {
                            globals = { "vim" }
                        },
                        workspace = {
                            library = vim.api.nvim_get_runtime_file("", true),
                            checkThirdParty = false
                        }
                    }
                }
            }
        }
    }
})
```

## Internal Implementation (内部实现)

### 1. `lua/zero-nvim/init.lua`

*   **Defaults**: `defaults` 表中新增了 `lsp = { servers = {} }` 字段。
*   **Command**: `:ZeroLspStart` 命令被更新。当用户执行 `:ZeroLspStart <server_name> [args...]` 时：
    1.  提取第一个参数 `<server_name>`（例如 `basedpyright-langserver`）。
    2.  在 `options.lsp.servers` 中查找该名称对应的配置。
    3.  如果找到配置且包含 `settings` 字段，提取该 `settings` 表。
    4.  调用 `require("zero-nvim.lsp").start_lsp(0, args, settings)`，将设置传递给核心 LSP 启动函数。

### 2. `lua/zero-nvim/lsp.lua`

*   **`start_lsp` Function**: 签名更新为 `start_lsp(bufnr, cmd_args, settings)`。
*   **`vim.lsp.start_client`**: 接收传入的 `settings` 参数。这确保了 LSP 服务器在初始化 (`initialize` 请求) 或初始化后 (`workspace/configuration` 请求) 能够接收到正确的配置。

## Usage Example (使用示例)

假设你需要配置 `basedpyright` 以使用远程服务器上的特定 Python 环境：

1.  **配置插件**:
    ```lua
    require("zero-nvim").setup({
        lsp = {
            servers = {
                ["basedpyright-langserver"] = {
                    settings = {
                        python = { pythonPath = "/home/ec2-user/my-env/bin/python" }
                    }
                }
            }
        }
    })
    ```

2.  **启动 LSP**:
    在打开远程文件（如 `remote://.../main.py`）后，执行：
    ```vim
    :ZeroLspStart basedpyright-langserver --stdio
    ```

    `zero-nvim` 会自动将配置中的 `pythonPath` 发送给服务器，从而解决依赖解析和环境感知问题。
