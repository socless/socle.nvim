---socless.nvim: the SoCLess Chisel IDE language server in Neovim.
local M = {}

---The options in use, after `setup()`.
---@type socless.Config|nil
M.config = nil

---Configures the plugin. Nothing happens before it is called.
---@param opts? table see `:help socless-options`
function M.setup(opts)
  if vim.fn.has("nvim-0.12") ~= 1 then
    vim.notify("SoCLess: socless.nvim needs Neovim 0.12 or later", vim.log.levels.ERROR)
    return
  end
  M.config = require("socless.config").merge(opts)
end

return M
