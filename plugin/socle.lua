-- Declares :Socle only; nothing else happens before require("socle").setup().
if vim.g.loaded_socle then return end
vim.g.loaded_socle = true

vim.api.nvim_create_user_command("Socle", function(o)
  require("socle.commands").run(o.fargs[1])
end, {
  nargs = 1,
  desc = "Socle: view, simulate, panel, update, log, health",
  complete = function(arglead) return require("socle.commands").complete(arglead) end,
})
