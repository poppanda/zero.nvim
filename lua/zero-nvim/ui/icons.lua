local M = {}

local icon_map = {
    -- Source code
    lua = "🌙",
    py = "🐍",
    rs = "🦀",
    go = "🐹",
    js = "📜",
    ts = "📘",
    jsx = "⚛️",
    tsx = "⚛️",
    rb = "💎",
    c = "⚙️",
    cpp = "⚙️",
    h = "⚙️",
    java = "☕",
    cs = "🔷",
    swift = "🐦",
    kt = "🟣",
    php = "🐘",
    -- Web / markup
    html = "🌐",
    css = "🎨",
    scss = "🎨",
    less = "🎨",
    vue = "💚",
    svelte = "🔥",
    -- Data / config
    json = "📋",
    yaml = "📋",
    yml = "📋",
    toml = "📋",
    xml = "📋",
    csv = "📊",
    ini = "⚙️",
    conf = "⚙️",
    env = "🔒",
    -- Shell / scripts
    sh = "🐚",
    bash = "🐚",
    zsh = "🐚",
    fish = "🐚",
    bat = "🐚",
    ps1 = "🐚",
    -- Docs
    md = "📝",
    txt = "📝",
    rst = "📝",
    org = "📝",
    tex = "📝",
    pdf = "📕",
    doc = "📘",
    docx = "📘",
    xls = "📗",
    xlsx = "📗",
    ppt = "📙",
    -- Images
    png = "🖼️",
    jpg = "🖼️",
    jpeg = "🖼️",
    gif = "🖼️",
    svg = "🖼️",
    ico = "🖼️",
    bmp = "🖼️",
    webp = "🖼️",
    -- Video / audio
    mp4 = "🎬",
    mkv = "🎬",
    avi = "🎬",
    mov = "🎬",
    webm = "🎬",
    mp3 = "🎵",
    wav = "🎵",
    flac = "🎵",
    ogg = "🎵",
    -- Archives
    zip = "📦",
    tar = "📦",
    gz = "📦",
    bz2 = "📦",
    xz = "📦",
    ["7z"] = "📦",
    rar = "📦",
    -- Build / lock
    lock = "🔒",
    log = "📃",
    -- Binary / misc
    so = "🔧",
    dll = "🔧",
    exe = "🔧",
    bin = "🔧",
    o = "🔧",
}

--- Get an emoji icon for a file extension
---@param ext? string File extension (without dot)
---@return string icon
function M._file_icon(ext)
    if not ext then return "📄" end
    return icon_map[ext:lower()] or "📄"
end

M.icon_map = icon_map

return M
