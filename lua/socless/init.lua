---socless.nvim: the SoCLess Chisel IDE language server in Neovim.
local M = {}

---The options in use, after `setup()`.
---@type socless.Config|nil
M.config = nil

---Configures the plugin. Nothing happens before it is called. The server
---starts with the first Scala buffer of a Mill project (a build.mill above it).
---@param opts? table see `:help socless-options`
function M.setup(opts)
  if vim.fn.has("nvim-0.12") ~= 1 then
    vim.notify("SoCLess: socless.nvim needs Neovim 0.12 or later", vim.log.levels.ERROR)
    return
  end
  local config = require("socless.config")
  local cfg = config.merge(opts)
  local _, unknown = config.to_server(cfg.settings)
  for _, msg in ipairs(unknown) do vim.notify(msg, vim.log.levels.WARN) end
  for _, msg in ipairs(require("socless.versions").warnings(cfg)) do vim.notify(msg, vim.log.levels.WARN) end
  M.config = cfg
  require("socless.client").setup(cfg)
end

return M
