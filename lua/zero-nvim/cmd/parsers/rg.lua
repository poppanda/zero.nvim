-- =============================================================================
-- cmd/parsers/rg.lua — ripgrep --json 输出解析器
-- =============================================================================
-- rg --json 每行一个 JSON 对象，type 字段区分：
--   begin    {data.path.text = "<file>"}
--   match    {data.path.text, lines.text, line_number, submatches=[{start,end,match}]}
--   end      {data.path.text, stats={...}}
--   summary  忽略（最后一行总结）
--
-- 输出事件：
--   {kind="file_begin", file=path}
--   {kind="match", file, lnum, col, text, match_len, submatches=[{start,end,match}]}
--   {kind="file_end", file, stats}
--   {kind="stderr", text}
--
-- 同一行多 submatch 拆成多个 match 事件（保留旧 UI"一条结果一行"的语义）。
-- col 用 submatch.start+1（1-based 字节）；match_len = end-start。

local M = {}

local function path_text(p)
    if type(p) == "table" then
        if type(p.text) == "string" then return p.text end
        -- 极少见：非 utf-8 路径，rg 用 base64 包成 {bytes=...}；这里简单丢弃，
        -- 因为我们的 UI/zero URI 也无法处理非 utf-8。
    end
    return nil
end

local function line_text(l)
    if type(l) == "table" and type(l.text) == "string" then
        return l.text
    end
    return ""
end

function M.new()
    local self = { _buf = "" }

    function self:feed(bytes)
        self._buf = self._buf .. bytes
        local out = {}
        while true do
            local nl = self._buf:find("\n", 1, true)
            if not nl then break end
            local line = self._buf:sub(1, nl - 1)
            self._buf = self._buf:sub(nl + 1)
            if line:sub(-1) == "\r" then line = line:sub(1, -2) end
            if #line == 0 then goto continue end

            local ok, obj = pcall(vim.json.decode, line)
            if not ok or type(obj) ~= "table" or not obj.type then
                -- 非 JSON 行：极可能是 rg --json 不可用 / stderr 串到 stdout
                table.insert(out, { kind = "parse_error", text = line })
                goto continue
            end

            if obj.type == "begin" then
                local file = path_text(obj.data and obj.data.path)
                if file then
                    table.insert(out, { kind = "file_begin", file = file })
                end
            elseif obj.type == "match" then
                local file = path_text(obj.data and obj.data.path)
                local lnum = obj.data and obj.data.line_number
                local text = line_text(obj.data and obj.data.lines)
                if text:sub(-1) == "\n" then text = text:sub(1, -2) end
                if text:sub(-1) == "\r" then text = text:sub(1, -2) end
                local subs = (obj.data and obj.data.submatches) or {}

                if file and lnum then
                    if #subs == 0 then
                        -- 罕见：rg 偶尔会发无 submatch 的 match（multiline 模式整段）
                        table.insert(out, {
                            kind = "match",
                            file = file,
                            lnum = lnum,
                            col = 1,
                            text = text,
                            match_len = 0,
                            submatches = {},
                        })
                    else
                        for _, sm in ipairs(subs) do
                            local s = sm.start or 0
                            local e = sm["end"] or s
                            table.insert(out, {
                                kind = "match",
                                file = file,
                                lnum = lnum,
                                col = s + 1,
                                text = text,
                                match_len = e - s,
                                submatches = subs,
                            })
                        end
                    end
                end
            elseif obj.type == "end" then
                local file = path_text(obj.data and obj.data.path)
                if file then
                    table.insert(out, {
                        kind = "file_end",
                        file = file,
                        stats = obj.data and obj.data.stats,
                    })
                end
            end
            -- "summary" 类型忽略

            ::continue::
        end
        return out
    end

    function self:feed_err(bytes)
        return { { kind = "stderr", text = bytes } }
    end

    function self:finalize()
        -- rg --json 末尾必带 \n，但万一没有，flush 缓冲里残留的最后一行
        if #self._buf > 0 then
            local r = self:feed("\n")
            self._buf = ""
            return r
        end
        return {}
    end

    return self
end

return M
