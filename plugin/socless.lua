-- Declares :Socless only; nothing else happens before require("socless").setup().
if vim.g.loaded_socless then return end
vim.g.loaded_socless = true

vim.api.nvim_create_user_command("Socless", function(o)
  require("socless.commands").run(o.fargs[1])
end, {
  nargs = 1,
  desc = "SoCLess: view, simulate, panel, update, log, health",
  complete = function(arglead) return require("socless.commands").complete(arglead) end,
})
