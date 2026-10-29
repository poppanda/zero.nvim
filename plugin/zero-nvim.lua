if vim.g.loaded_zero_nvim then
  return
end
vim.g.loaded_zero_nvim = 1

-- Only apply defaults when the user hasn't configured the plugin yet. If the
-- user called setup(opts) earlier (e.g. from init.lua before plugin/ files are
-- sourced), calling setup() here would reset their options to defaults. If the
-- user calls setup(opts) later instead, that call simply re-applies with their
-- options (setup is idempotent: augroup cleared, patches guarded).
local zero = require("zero-nvim")
if not zero.is_configured() then
  zero.setup()
end
