# Project Management System Design (Project Config Design)

## 1. Executive Summary (执行摘要)

为了提升 `zero-nvim` 在多项目、多环境下的切换效率，我们将引入 **Project Persistence Layer (项目持久化层)**。该功能允许用户保存远程连接信息、工作目录以及项目特定的 LSP 配置。

核心目标是实现 "One-Click Context Switch" (一键上下文切换)，并通过 `:ZeroProject` 提供统一的管理入口，支持健康检查 (Health Check) 以确保连接和环境的有效性。

---

## 2. Data Persistence Design (数据持久化设计)

### 2.1 Storage Mechanism (存储机制)
*   **Location**: `vim.fn.stdpath("data") .. "/zero-nvim/projects.json"`
*   **Format**: JSON. 易于读写，且方便用户手动备份或迁移。
*   **Security Note**: 我们**绝不**存储密码。连接认证完全依赖于 SSH Key 或 SSH Agent (以及本地的 `~/.ssh/config`)。

### 2.2 Data Schema (数据结构)

项目配置将是一个 Key-Value 结构，Key 为项目名称 (Project Name)，Value 为配置详情。

```json
{
  "backend-service-prod": {
    "host": "prod-server",          // 对应 SSH Config Host 或 user@ip
    "root": "/var/www/backend",     // 远程项目的根目录
    "lsp": {                        // [可选] 项目级 LSP 覆盖配置
      "basedpyright-langserver": {
        "cmd": ["/var/www/backend/.venv/bin/basedpyright-langserver", "--stdio"], // [新增] 允许覆盖启动命令
        "settings": {
          "python": {
            "pythonPath": "/var/www/backend/.venv/bin/python"
          }
        }
      }
    },
    "created_at": 1708500000
  },
  "frontend-dev": {
    "host": "192.168.1.105",
    "user": "ubuntu",
    "port": 2222,
    "root": "/home/ubuntu/projects/react-app"
    // 无 LSP 字段，则回退使用 Global Setup 配置
  }
}
```

---

## 3. UI & Interaction Design (交互设计)

### 3.1 Command: `:ZeroProject` (Main Dashboard)

这是项目管理的主入口。

*   **UI Style**: **优先使用 `zero-nvim` 原生浮动窗口风格** (参考 `ZeroLink` / `ZeroSearch` 的实现)，以保持视觉一致性。仅在极简模式下回退到 `vim.ui.select`。
*   **Display Items**:
    *   `[dev-server] /var/www/api (Python)`
    *   `[prod-db] /etc/postgresql/14/main`
*   **Actions (快捷键映射)**:
    *   `<CR>` (Enter): **Open**. 连接并打开远程目录。
        *   *Compatibility Note*: 必须尊重用户的 `opts.explorer` 设置。如果用户启用了 `oil`，自动通过 `oil.nvim` 打开 (`oil-zero://...`)，否则使用 `remote://...`。
    *   `<C-e>` (Edit): **Edit Config**. 打开浮动窗口编辑该项目的 JSON 片段。
    *   `<C-d>` (Delete): **Delete**. 删除该项目记录。
    *   `<C-h>` (Check): **Health Check**. 运行环境检查 (见下文)。

### 3.2 Command: `:ZeroProjectAdd`

在当前缓冲区 (Buffer) 下快速保存为项目。

*   **Trigger**: 用户当前正处于 `remote://` 或 `oil-zero://` 路径下。
*   **Behavior**:
    1.  自动解析当前的 Host 和 Root Dir。
    2.  弹出 Input 框询问 `Project Name` (默认为文件夹名)。
    3.  写入 `projects.json`。

---

## 4. Health Check Mechanism (环境检查机制)

为了解决 "配置了但连不上" 或 "LSP 起不来" 的痛点，设计多层级检查系统。

**触发方式**: 在 `:ZeroProject` 列表中选中项目按 `<C-h>`，或执行 `:ZeroProjectCheck <name>`。

**检查流程 (Pipeline)**:

1.  **Level 1: Connectivity (Ping/SSH)**
    *   **Action**: 调用 Rust Daemon 尝试建立 SSH 连接。
    *   **Success**: 连接成功建立。
    *   **Fail**: "Host unreachable" 或 "Auth failed"。
    
2.  **Level 2: FS Accessibility (Path)**
    *   **Action**: 对配置的 `root` 路径执行 `sftp_stat`。
    *   **Success**: 目录存在且有读权限。
    *   **Fail**: "Directory not found" 或 "Permission denied"。

3.  **Level 3: LSP Binary Check (Optional)**
    *   **Action**: 如果配置中定义了 `lsp`：
        *   检查 `cmd` (如果覆盖了) 或默认 binary 是否存在于远程 PATH 或指定路径。
        *   执行 `which <binary_name>` 或 `<binary> --version`。
    *   **Success**: 返回版本号或路径。
    *   **Fail**: "Command not found"。

**UI Feedback**:
检查结果将以 Notification (如 `nvim-notify`) 或浮动窗口列表的形式展示：
```text
[✓] SSH Connection (prod-server)
[✓] Root Directory (/var/www/api)
[x] LSP (basedpyright): Command not found in PATH
```

---

## 5. Integration Logic (集成逻辑)

### 5.1 LSP Configuration Merging (配置合并)

当用户执行 `:ZeroLspStart <server>` 时，逻辑更新如下：

1.  **Context Detection**: 获取当前 Buffer 的 `remote://` 路径。
2.  **Project Match**: 
    *   遍历 `projects.json` 中所有项目的 `root` 路径。
    *   采用 **Longest Prefix Match (最长前缀匹配)** 策略。
    *   例如：文件 `/app/backend/main.py` 应该匹配项目 `/app/backend` 而不是 `/app`。
3.  **Config Resolution**:
    *   Base: `require("zero-nvim").setup()` 中的全局配置。
    *   Override: `projects.json` 中该项目的 `lsp` 配置 (包含 `cmd` 和 `settings`)。
    *   Result: `vim.tbl_deep_extend("force", Base, Override)`。
4.  **Launch**: 使用合并后的配置 (包括自定义 `cmd`) 启动 LSP。

---

## 6. Implementation Roadmap (实施路线图)

### Milestone 4.5: Project Core (Current Focus)
*   [ ] 实现 `lua/zero-nvim/project/store.lua`: 负责 JSON 的读写。
*   [ ] 实现 `lua/zero-nvim/project/manager.lua`: 负责 Add/Delete 逻辑。

### Milestone 4.6: UI & Commands
*   [ ] 实现 `:ZeroProjectAdd` 命令。
*   [ ] 实现 `:ZeroProject` 列表 UI (基于 `ui/browser.lua` 的经验)。
*   [ ] 集成 Telescope (作为 Extension)。

### Milestone 4.7: Health Check & LSP Hook
*   [ ] 在 Daemon 中增加 `check_env` RPC 接口 (复用现有的 connect/exec)。
*   [ ] 修改 `lsp.lua` 以支持配置合并。

---

## 7. Mockups (UI 原型)

**Project List (Floating Window)**
```
 ┌────────────────────────────────────────────────────────┐
 │ ZeroProject Manager                                    │
 ├────────────────────────────────────────────────────────┤
 │ > backend-api   (host: dev-box, root: /app/api)        │
 │   frontend-web  (host: dev-box, root: /app/web)        │
 │   k8s-configs   (host: bastion, root: /etc/k8s)        │
 │                                                        │
 ├────────────────────────────────────────────────────────┤
 │ <CR>: Open | <C-e>: Edit | <C-d>: Del | <C-h>: Check   │
 └────────────────────────────────────────────────────────┘
```
