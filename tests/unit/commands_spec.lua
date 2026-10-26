local commands = require("socless.commands")

local VIEW, SIM = "socless.viewDesign", "socless.simulate"
local function lens(line, cmd)
  return { range = { start = { line = line, character = 0 }, ["end"] = { line = line, character = 0 } },
    command = { title = cmd, command = cmd, arguments = { "file:///x", "S", "t" .. line } } }
end

describe("pick_lens", function()
  local lenses = { lens(30, VIEW), lens(30, SIM), lens(10, VIEW), lens(10, SIM), { range = lens(0, VIEW).range } }

  it("picks the closest lens at or above the cursor", function()
    eq(lenses[1], commands.pick_lens(lenses, 40, VIEW))
    eq(lenses[3], commands.pick_lens(lenses, 29, VIEW))
    eq(lenses[2], commands.pick_lens(lenses, 30, SIM))
  end)

  it("falls back to the first lens of the command (lowest line)", function()
    eq(lenses[3], commands.pick_lens(lenses, 2, VIEW))
  end)

  it("gives nil with no lens of that command", function()
    eq(nil, commands.pick_lens(lenses, 40, "other"))
    eq(nil, commands.pick_lens({}, 0, VIEW))
  end)
end)

describe(":Socless", function()
  it("completes the six subcommands", function()
    eq({ "view", "simulate", "panel", "update", "log", "health" }, commands.complete(""))
    eq({ "simulate" }, commands.complete("si"))
  end)

  it("is declared by plugin/socless.lua with that completion", function()
    vim.cmd.runtime("plugin/socless.lua")
    eq(2, vim.fn.exists(":Socless"))
    eq({ "view", "simulate", "panel", "update", "log", "health" }, vim.fn.getcompletion("Socless ", "cmdline"))
  end)
end)

describe("view and simulate", function()
  local client = require("socless.client")
  local notes, requests, real_notify, real_get
  before_each(function()
    notes, requests = {}, {}
    real_notify, real_get = vim.notify, vim.lsp.codelens.get
    vim.notify = function(msg, level) table.insert(notes, { msg = msg, level = level }) end
    require("socless").config = require("socless.config").merge({})
  end)
  after_each(function()
    vim.notify, vim.lsp.codelens.get = real_notify, real_get
    client._get = nil
  end)

  ---A fake socless client: answers textDocument/codeLens with `answer` (async).
  local function fake(answer)
    client._get = function()
      return {
        id = 7,
        request = function(_, method, params, handler)
          table.insert(requests, { method, params })
          if method == "textDocument/codeLens" then
            vim.defer_fn(function() handler(nil, answer, {}) end, 10)
          end
          return true, 1
        end,
      }
    end
  end

  local function wait_for(n)
    assert(vim.wait(2000, function() return #requests >= n or #notes > 0 end), "nothing happened")
  end

  it("says so when not attached", function()
    client._get = function() return nil end
    commands.run("view")
    eq("SoCLess: not attached (a Mill project with build.mill?)", notes[1].msg)
  end)

  it("asks for lenses when there are none yet, then runs the closest one", function()
    vim.lsp.codelens.get = function() return {} end
    fake({ lens(0, VIEW), lens(0, SIM) })
    commands.run("simulate")
    wait_for(2)
    eq("textDocument/codeLens", requests[1][1])
    eq({ "workspace/executeCommand", { command = SIM, arguments = { "file:///x", "S", "t0" } } }, requests[2])
  end)

  it("uses the lenses already shown, without asking", function()
    vim.lsp.codelens.get = function() return { { client_id = 7, lens = lens(0, VIEW) } } end
    fake({})
    commands.run("view")
    wait_for(1)
    eq({ "workspace/executeCommand", { command = VIEW, arguments = { "file:///x", "S", "t0" } } }, requests[1])
  end)

  it("reports a failed codeLens request and runs nothing", function()
    vim.lsp.codelens.get = function() return {} end
    client._get = function()
      return {
        id = 7,
        request = function(_, method, _, handler)
          table.insert(requests, method)
          vim.defer_fn(function() handler({ code = -32603, message = "boom" }, nil, {}) end, 10)
          return true, 1
        end,
      }
    end
    commands.run("view")
    wait_for(99)
    eq({ "textDocument/codeLens" }, requests)
    eq(vim.log.levels.ERROR, notes[1].level)
    eq(true, notes[1].msg:find("boom", 1, true) ~= nil)
  end)

  it("reports a codeLens request that could not be sent", function()
    vim.lsp.codelens.get = function() return {} end
    client._get = function()
      return { id = 7, request = function() return false, nil end }
    end
    commands.run("view")
    eq(1, #notes)
    eq(vim.log.levels.ERROR, notes[1].level)
  end)

  it("cancels the codeLens request after the timeout and says so", function()
    vim.lsp.codelens.get = function() return {} end
    local cancelled
    client._get = function()
      return {
        id = 7,
        request = function() return true, 42 end,
        cancel_request = function(_, id) cancelled = id end,
      }
    end
    local saved = commands._lens_timeout_ms
    commands._lens_timeout_ms = 30
    commands.run("view")
    local ok = vim.wait(1000, function() return #notes > 0 end)
    commands._lens_timeout_ms = saved
    assert(ok, "no timeout notice")
    eq(42, cancelled)
    eq("SoCLess: timed out waiting for code lenses", notes[1].msg)
  end)

  it("says no ChiselSim test here when there is no lens", function()
    vim.lsp.codelens.get = function() return {} end
    fake({})
    commands.run("view")
    wait_for(99)
    eq("SoCLess: no ChiselSim test here", notes[1].msg)
  end)
end)
