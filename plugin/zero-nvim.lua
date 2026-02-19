if vim.g.loaded_zero_nvim then
  return
end
vim.g.loaded_zero_nvim = 1

require("zero-nvim").setup()