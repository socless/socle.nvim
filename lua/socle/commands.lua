---`:Socle {view|simulate|panel|update|log|health}`.
local M = {}

local client = require("socle.client")

M.SUBCOMMANDS = { "view", "simulate", "panel", "update", "log", "health" }

local COMMAND = { view = "socle.viewDesign", simulate = "socle.simulate" }
---How long `view` and `simulate` wait for the server's lenses.
M._lens_timeout_ms = 10000

---The subcommands starting with `arglead`.
---@param arglead string
---@return string[]
function M.complete(arglead)
  return vim.tbl_filter(function(s) return vim.startswith(s, arglead) end, M.SUBCOMMANDS)
end

---The lens of `command` closest at or above `cursor_line` (0-based), else
---the one of `command` on the lowest line, else nil.
---@param lenses lsp.CodeLens[]
---@param cursor_line integer
---@param command string
---@return lsp.CodeLens|nil
function M.pick_lens(lenses, cursor_line, command)
  local above, first
  for _, lens in ipairs(lenses) do
    if lens.command and lens.command.command == command then
      local line = lens.range.start.line
      if line <= cursor_line and (not above or line > above.range.start.line) then above = lens end
      if not first or line < first.range.start.line then first = lens end
    end
  end
  return above or first
end

---Calls `cb(lenses)` with the socle lenses of `buf`: those shown, else
---asks the server once, waiting up to 10 s.
local function lenses_of(c, buf, cb)
  local shown = vim.tbl_map(function(r) return r.lens end,
    vim.lsp.codelens.get({ bufnr = buf, client_id = c.id }) or {})
  if #shown > 0 then return cb(shown) end
  local done = false
  local ok, id = c:request("textDocument/codeLens", { textDocument = { uri = vim.uri_from_bufnr(buf) } },
    function(err, result)
      if done then return end -- timed out (and cancelled) already
      done = true
      if err then
        return vim.notify(("Socle: cannot get the lenses: %s"):format(err.message or vim.inspect(err)),
          vim.log.levels.ERROR)
      end
      cb(result or {})
    end, buf)
  if not ok then
    done = true
    return vim.notify("Socle: cannot ask the server for code lenses (it stopped?)", vim.log.levels.ERROR)
  end
  vim.defer_fn(function()
    if done then return end
    done = true
    c:cancel_request(id)
    vim.notify("Socle: timed out waiting for code lenses", vim.log.levels.WARN)
  end, M._lens_timeout_ms)
end

---Runs the View design or Simulate lens closest to the cursor.
---@param which "view"|"simulate"
local function run_lens(which)
  local buf = vim.api.nvim_get_current_buf()
  local c = client.get(buf)
  if not c then
    return vim.notify("Socle: not attached (a Mill project with build.mill?)", vim.log.levels.WARN)
  end
  local line = vim.api.nvim_win_get_cursor(0)[1] - 1
  lenses_of(c, buf, function(lenses)
    local lens = M.pick_lens(lenses, line, COMMAND[which])
    if not lens then
      return vim.notify("Socle: no ChiselSim test here", vim.log.levels.WARN)
    end
    c:request("workspace/executeCommand",
      { command = lens.command.command, arguments = lens.command.arguments },
      function(err)
        if err then
          vim.notify(("Socle: %s failed: %s"):format(which, err.message or vim.inspect(err)),
            vim.log.levels.ERROR)
        end
      end, buf)
  end)
end

---Downloads the jar again (the one on disk stays until the new one
---verified), then restarts the client on it, or starts one.
local function update(cfg)
  local jar = require("socle.jar")
  if cfg.server_jar then
    return vim.notify("Socle: server_jar is set, nothing to download", vim.log.levels.INFO)
  end
  jar.ensure(cfg, function(path, err)
    if not path then return vim.notify(err, vim.log.levels.ERROR) end
    client.updated()
  end, { force = true })
end

---Runs one subcommand.
---@param sub string|nil
function M.run(sub)
  if sub == "health" then return vim.cmd("checkhealth socle") end
  if sub == "log" then return vim.cmd.tabedit(vim.lsp.log.get_filename()) end
  if not vim.tbl_contains(M.SUBCOMMANDS, sub) then
    return vim.notify(("Socle: unknown subcommand %s (expected %s)")
      :format(vim.inspect(sub), table.concat(M.SUBCOMMANDS, ", ")), vim.log.levels.ERROR)
  end
  local cfg = require("socle").config
  if not cfg then
    return vim.notify('Socle: call require("socle").setup() first', vim.log.levels.WARN)
  end
  if sub == "panel" then return client.open_last() end
  if sub == "update" then return update(cfg) end
  run_lens(sub)
end

return M
