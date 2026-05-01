-- =============================================================================
-- cmd/parsers/init.lua — Parser 协议 & 内置 passthrough parser
-- =============================================================================
-- Parser 是把"远端字节流"翻译成"结构化事件"的状态机。
--
-- 协议（任何具体 parser 必须实现）：
--   parser:feed(bytes:string)     -> Event[]?    -- stdout 增量
--   parser:feed_err(bytes:string) -> Event[]?    -- stderr 增量
--   parser:finalize()             -> Event[]?    -- EOF/abort 时 flush 残留
--
-- 纪律：parser 永远不调 vim.api、不持 buffer 引用。纯字节流 → 事件。这是 UI
-- 复用的前提（同一 parser 既能给搜索 UI 用，也能给"测试运行 + 解析输出"用）。

local M = {}

--- 透传 parser：stdout/stderr 原样转成 events（默认行为，无需自定义）
function M.passthrough()
    return {
        feed = function(_, bytes)
            return { { kind = "stdout", text = bytes } }
        end,
        feed_err = function(_, bytes)
            return { { kind = "stderr", text = bytes } }
        end,
        finalize = function()
            return {}
        end,
    }
end

--- 行式 parser：把 stdout 按行切，每行一个 event。跨 chunk 的不完整行会缓存。
function M.lines()
    local self = { _buf = "" }

    function self:feed(bytes)
        self._buf = self._buf .. bytes
        local out = {}
        while true do
            local nl = self._buf:find("\n", 1, true)
            if not nl then break end
            local line = self._buf:sub(1, nl - 1)
            self._buf = self._buf:sub(nl + 1)
            -- 删尾部 \r（兼容 CRLF）
            if line:sub(-1) == "\r" then line = line:sub(1, -2) end
            table.insert(out, { kind = "line", text = line })
        end
        return out
    end

    function self:feed_err(bytes)
        return { { kind = "stderr", text = bytes } }
    end

    function self:finalize()
        if #self._buf > 0 then
            local last = self._buf
            self._buf = ""
            if last:sub(-1) == "\r" then last = last:sub(1, -2) end
            return { { kind = "line", text = last } }
        end
        return {}
    end

    return self
end

return M
