--- Remote file content <-> buffer lines conversion, shared by the builtin
--- BufReadCmd/BufWriteCmd handlers (init.lua) and the oil adapter.
---
--- Follows Vim's own read/write semantics as closely as a BufReadCmd can:
---   • 'fileformat' 检测：所有行都以 CRLF 结尾 → dos，否则 unix
---   • 'eol'：文件末尾是否有换行；写回时 eol 或 (fixeol 且非 binary) 才补换行
---   • 'bomb'：UTF-8 BOM 剥离并记录，写回时恢复
---   • 二进制 / 非 UTF-8 内容：按原始字节透传（NUL 在 buffer 里就是 NUL）；
---     含 NUL 且无末尾换行时关闭该 buffer 的 'fixeol'，保证字节级原样写回
---
--- 空文件特例：读到 "" 时把 'eol' 设为 false，这样原样保存仍写出 0 字节
--- （Vim 对 ML_EMPTY buffer 也不写换行）；一旦输入了内容，fixeol 照常补换行。

local M = {}

local BOM = "\239\187\191"

--- Normalise file content received from the daemon into a Lua byte string.
--- The daemon sends non-UTF-8 content as msgpack Binary. On Neovim 0.11/0.12
--- vim.fn.rpcrequest already hands that over as a plain Lua string (verified
--- with a fake RPC server); older/odd conversions are handled defensively:
---   • msgpack special dict { _TYPE = binary, _VAL = { "line", ... } } (NL-joined,
---     NUL encoded as "\n" inside items)
---   • byte list { 255, 0, ... } (blob2list form)
---@param v any
---@return string?
function M.to_bytes(v)
    if v == nil or v == vim.NIL then return nil end
    if type(v) == "string" then return v end
    if type(v) == "table" then
        if type(v._VAL) == "table" then
            local parts = {}
            for i, item in ipairs(v._VAL) do
                parts[i] = (tostring(item):gsub("\n", "\0"))
            end
            return table.concat(parts, "\n")
        end
        if #v > 0 and type(v[1]) == "number" then
            local chunks = {}
            for i = 1, #v, 4096 do
                chunks[#chunks + 1] = string.char(unpack(v, i, math.min(i + 4095, #v)))
            end
            return table.concat(chunks)
        end
        if next(v) == nil then return "" end
    end
    return tostring(v)
end

---@class zero.ContentInfo
---@field eol boolean
---@field fileformat "unix"|"dos"
---@field bomb boolean
---@field has_nul boolean

--- Split raw file content into buffer lines.
---@param content string|nil raw bytes
---@return string[] lines
---@return zero.ContentInfo info
function M.content_to_lines(content)
    content = M.to_bytes(content) or ""
    local info = { eol = true, fileformat = "unix", bomb = false, has_nul = false }

    if content:sub(1, 3) == BOM then
        info.bomb = true
        content = content:sub(4)
    end
    info.has_nul = content:find("\0", 1, true) ~= nil

    if content == "" then
        info.eol = false
        return { "" }, info
    end

    local nl = select(2, content:gsub("\n", ""))
    local crlf = select(2, content:gsub("\r\n", ""))
    local sep = "\n"
    if nl > 0 and crlf == nl then
        info.fileformat = "dos"
        sep = "\r\n"
    end

    if content:sub(-#sep) == sep then
        content = content:sub(1, -#sep - 1)
    else
        info.eol = false
    end

    return vim.split(content, sep, { plain = true }), info
end

---@class zero.WriteOpts
---@field eol? boolean       default true
---@field fixeol? boolean    default true
---@field binary? boolean    default false
---@field fileformat? string default "unix"
---@field bomb? boolean      default false

--- Join buffer lines back into raw file content.
---@param lines string[]
---@param opts? zero.WriteOpts
---@return string
function M.lines_to_content(lines, opts)
    opts = opts or {}
    local eol = opts.eol ~= false
    local fixeol = opts.fixeol ~= false
    local ff = opts.fileformat or "unix"
    local sep = (ff == "dos" and "\r\n") or (ff == "mac" and "\r") or "\n"

    local body
    if #lines == 0 or (#lines == 1 and lines[1] == "" and not eol) then
        -- 空 buffer：不补换行（与 Vim 写空 buffer 的行为一致）
        body = ""
    else
        body = table.concat(lines, sep)
        if eol or (fixeol and not opts.binary) then
            body = body .. sep
        end
    end

    if opts.bomb and not opts.binary then
        body = BOM .. body
    end
    return body
end

--- Content of buffer lines [first, last] (1-based, inclusive) honouring the
--- buffer's 'eol' / 'fixeol' / 'binary' / 'fileformat' / 'bomb'.
---@param buf integer
---@param first? integer
---@param last? integer
---@return string content
---@return boolean whole true when the whole buffer was taken
function M.buffer_content(buf, first, last)
    local count = vim.api.nvim_buf_line_count(buf)
    first = math.max(1, first or 1)
    last = math.min(count, last or count)
    if last < first then first, last = 1, count end
    local lines = vim.api.nvim_buf_get_lines(buf, first - 1, last, false)
    local bo = vim.bo[buf]
    local content = M.lines_to_content(lines, {
        -- 部分写入且没写到最后一行时，最后一行后面一定有换行
        eol = last < count or bo.eol,
        fixeol = bo.fixeol,
        binary = bo.binary,
        fileformat = bo.fileformat,
        bomb = first == 1 and bo.bomb,
    })
    return content, (first == 1 and last == count)
end

--- Replace the buffer content with `content` and mark it as successfully
--- loaded (b:zero_loaded) and unmodified.
---@param buf integer
---@param content string
function M.apply(buf, content)
    local lines, info = M.content_to_lines(content)
    local bo = vim.bo[buf]
    bo.modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    bo.fileformat = info.fileformat
    bo.eol = info.eol
    bo.bomb = info.bomb
    -- 含 NUL 的（二进制）文件末尾没换行时，不让 fixeol 在保存时偷偷补一个
    if info.has_nul and not info.eol then
        bo.fixeol = false
    end
    -- 'modified' 复位会顺带记录 fileformat/eol 的"原始值"，否则上面改选项会让
    -- buffer 被视为已修改。
    bo.modified = false
    vim.b[buf].zero_load_failed = nil
    vim.b[buf].zero_loaded = true
end

--- Mark a buffer whose remote content could not be read. The buffer is left
--- empty and non-modifiable, and BufWriteCmd refuses to write it (unless
--- :w!), so a failed read can never truncate the remote file.
---@param buf integer
function M.mark_failed(buf)
    if not vim.api.nvim_buf_is_valid(buf) then return end
    local bo = vim.bo[buf]
    bo.modifiable = true
    pcall(vim.api.nvim_buf_set_lines, buf, 0, -1, false, {})
    bo.eol = false -- 若用户 :w! 强制写，空 buffer 写出 0 字节而不是 "\n"
    bo.modified = false
    bo.modifiable = false
    vim.b[buf].zero_load_failed = true
    vim.b[buf].zero_loaded = false
end

--- True when the buffer's content came from the remote (or a new file).
---@param buf integer
---@return boolean
function M.is_loaded(buf)
    return vim.api.nvim_buf_is_valid(buf)
        and vim.api.nvim_buf_is_loaded(buf)
        and vim.b[buf].zero_loaded == true
end

--- Heuristic: does a daemon error mean "path does not exist" (→ new file)?
---@param err any
---@return boolean
function M.is_missing_error(err)
    local s = tostring(err or "")
    return s:find("路径不存在", 1, true) ~= nil
        or s:find("MISSING", 1, true) ~= nil
        or s:find("No such file", 1, true) ~= nil
        or s:find("NOT_FOUND", 1, true) ~= nil
end

return M
