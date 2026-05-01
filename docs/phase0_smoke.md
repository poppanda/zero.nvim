# Phase 0 — 端到端冒烟测试手册

Rust 单元测试已验证 (12/12 通过)。下列命令需要在你已配置好的远程主机上执行。
把 `<USER>` / `<HOST>` 替换为实际值。

## 前置

```bash
# 编译 daemon
cd daemon && cargo build && cd ..

# 在 Neovim 内 :ZeroProject 选一次主机，确保 daemon 已起 + 主机已连
# 或直接 :ZeroLink zero://<USER>@<HOST>:22/tmp
```

## A. 同步快路径（cmd.sync）

```vim
:lua =require('zero-nvim.cmd').sync({user='<USER>',host='<HOST>'}, {'uname','-a'})
```

期望：返回 table，`stdout` 含主机内核信息，`code = 0`，`duration_ms` 通常 < 200ms。

## B. 流式 + parser

```vim
:lua << EOF
local cmd = require('zero-nvim.cmd')
local parsers = require('zero-nvim.cmd.parsers')
local sid = cmd.stream(
    {user='<USER>',host='<HOST>'},
    {
        argv = {'sh','-c','for i in $(seq 1 200); do echo line-$i; sleep 0.01; done'},
        parser = parsers.lines(),
    },
    {
        on_event = function(ev) print(vim.inspect(ev)) end,
        on_exit  = function(code, signal, reason, dur)
            print(string.format('exit code=%s reason=%s dur=%dms', code, tostring(reason), dur))
        end,
    }
)
print('sid=', sid)
EOF
```

期望：约 80ms 节奏每次几十行 chunk 涌入；最后 `exit code=0`。

## C. Cancel 验证

```vim
" 上一步的 sid 替换进去
:lua require('zero-nvim.cmd').cancel('<SID>')
```

期望：1-3 秒内出现 `aborted` 退出回调。然后到远端确认进程已死：

```bash
ssh <USER>@<HOST> 'pgrep -af "for i in"' || echo "已清理"
```

## D. 并行不阻塞回归

```vim
" 起一个长流式命令
:lua << EOF
local sid = require('zero-nvim.cmd').stream(
    {user='<USER>',host='<HOST>'},
    { argv = {'sh','-c','sleep 30 && echo done'}, parser = require('zero-nvim.cmd.parsers').passthrough() },
    { on_event = function() end, on_exit = function() end }
)
vim.g.zero_smoke_sid = sid
EOF

" 立刻发一个 :ZeroLink —— 应当秒开，不被流式命令阻塞
:ZeroLink zero://<USER>@<HOST>:22/tmp

" 完事记得 cancel
:lua require('zero-nvim.cmd').cancel(vim.g.zero_smoke_sid)
```

期望：`:ZeroLink` 立刻响应（目录列表秒出），证明流式命令的独占 Session 没有霸占 SFTP 池。

## E. 同步 + stdin（cmd.sync_full）

```vim
:lua << EOF
local res = require('zero-nvim.cmd').sync_full(
    {user='<USER>',host='<HOST>'},
    { argv = {'sh','-c','cat | wc -c'}, stdin = 'hello world' }
)
print(vim.inspect(res))
EOF
```

期望：`stdout` ≈ `"      11\n"`，`code = 0`。
