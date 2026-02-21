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

### 3.1 Command: `:ZeroProject [subcommand]` (Main Dashboard)

这是项目管理的主入口。

*   **Subcommands**:
    *   `:ZeroProject` (无参数): 打开项目列表面板。
    *   `:ZeroProject add`: 将当前远程缓冲区添加为新项目。
    *   `:ZeroProject check <name>`: 对指定项目运行健康检查。

*   **UI Style**: 使用 `zero-nvim` 原生浮动窗口风格，支持模态交互（Modal Interactions）。
    *   **Project List**: 最小高度 10 行，最大 20 行，支持滚动。
    *   **Add Prompt**: 自定义浮动输入框，覆盖在列表上方，提供无缝体验。
    *   **Config Editor**: 使用 `buftype=acwrite` 的临时缓冲区，支持通过 `:w` 触发保存并自动刷新列表。

*   **Actions (快捷键映射)**:
    *   `<CR>` (Enter): **Open**. 连接并打开远程目录。
        *   *Compatibility Note*: 自动适配 `oil.nvim` (使用 `oil-zero://`) 或 `netrw` (`remote://`)。
    *   `<C-a>` (Add): **Add Project**. 在列表界面直接添加当前缓冲区为项目（无缝弹窗）。
    *   `<C-e>` (Edit): **Edit Config**. 打开浮动窗口编辑该项目的 JSON 片段。
    *   `<C-d>` (Delete): **Delete**. 删除该项目记录。
    *   `<C-h>` (Check): **Health Check**. 运行实时环境检查 (见下文)。

---

## 4. Health Check Mechanism (环境检查机制)

为了解决 "配置了但连不上" 或 "LSP 起不来" 的痛点，设计了**实时非阻塞**的检查系统。

**触发方式**: 在 `:ZeroProject` 列表中选中项目按 `<C-h>`，或执行 `:ZeroProject check <name>`。

**UI Feedback**:
检查开始时立即弹出结果窗口，并在后台异步更新每项状态，避免界面冻结。

```text
[✓] SSH Connection (prod-server)
[✓] Root Directory (/var/www/api)
[?] LSP (basedpyright): Configured (Binary check pending)
```

**检查流程 (Pipeline)**:

1.  **Level 1: Connectivity (Ping/SSH)**
    *   **Action**: 调用 Rust Daemon 尝试建立 SSH 连接。
    *   **Success**: 连接成功建立。
    *   **Fail**: "Host unreachable" 或 "Auth failed"。
    
2.  **Level 2: FS Accessibility (Path)**
    *   **Action**: 对配置的 `root` 路径执行 `sftp_stat`。
    *   **Success**: 目录存在且有读权限。
    *   **Fail**: "Directory not found" 或 "Permission denied"。

3.  **Level 3: LSP Configuration Check**
    *   **Action**: 验证配置文件中是否定义了 LSP 覆盖。
    *   *Note*: 具体的二进制执行检查 (Binary Check) 依赖于 Daemon 的 `exec` 能力 (Milestone 4.7)。

---

## 5. Integration Logic (集成逻辑)

### 5.1 LSP Configuration Merging (配置合并)

当用户执行 `:ZeroLspStart <server>` 时，逻辑更新如下：

1.  **Context Detection**: 获取当前 Buffer 的 `remote://` 路径。
2.  **Project Match**: 
    *   遍历 `projects.json` 中所有项目的 `root` 路径。
    *   采用 **Longest Prefix Match (最长前缀匹配)** 策略。
3.  **Config Resolution**:
    *   Base: `require("zero-nvim").setup()` 中的全局配置。
    *   Override: `projects.json` 中该项目的 `lsp` 配置 (包含 `cmd` 和 `settings`)。
    *   Result: `vim.tbl_deep_extend("force", Base, Override)`。
4.  **Launch**: 使用合并后的配置 (包括自定义 `cmd`) 启动 LSP。

---

## 6. Implementation Status (实施状态)

### Milestone 4.5: Project Core (Completed)
*   [x] 实现 `lua/zero-nvim/project/store.lua`: 负责 JSON 的读写。
*   [x] 实现 `lua/zero-nvim/project/manager.lua`: 负责 Add/Delete 及最长前缀匹配逻辑。

### Milestone 4.6: UI & Commands (Completed)
*   [x] 实现 `:ZeroProject` 统一命令及子命令 (`add`, `check`)。
*   [x] 实现 Project List UI，支持固定高度及 `<C-a>` 无缝添加。
*   [x] 实现 Config Editor，支持 `:w` 保存及自动刷新。
*   [x] 实现 Real-time Health Check UI。

### Milestone 4.7: Advanced Features (Pending)
*   [ ] 在 Daemon 中增加 `exec` RPC 接口，以支持 LSP 二进制的真实存在性检查。

---

## 7. Mockups (UI 原型)

**Project List (Floating Window)**
```
 ┌────────────────────────────────────────────────────────┐
 │ Zero Projects                                          │
 ├────────────────────────────────────────────────────────┤
 │ > backend-api   (host: dev-box, root: /app/api)        │
 │   frontend-web  (host: dev-box, root: /app/web)        │
 │   k8s-configs   (host: bastion, root: /etc/k8s)        │
 │                                                        │
 │                                                        │
 ├────────────────────────────────────────────────────────┤
 │ <CR>:Open | <C-a>:Add | <C-e>:Edit | <C-d>:Del | <C-h> │
 └────────────────────────────────────────────────────────┘
```
