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

describe(":Socless log", function()
  it("opens vim.lsp.log.get_filename() in a tab (not the deprecated get_log_path)", function()
    local real_get, real_old, opened = vim.lsp.log.get_filename, vim.lsp.get_log_path, nil
    vim.lsp.log.get_filename = function() return "/x/lsp.log" end
    vim.lsp.get_log_path = function() error("deprecated get_log_path called") end
    vim.cmd.tabedit = function(path) opened = path end
    local ok, err = pcall(commands.run, "log")
    vim.lsp.log.get_filename, vim.lsp.get_log_path, vim.cmd.tabedit = real_get, real_old, nil
    assert(ok, err)
    eq("/x/lsp.log", opened)
  end)
end)

describe(":Socless update", function()
  local jar = require("socless.jar")
  local client = require("socless.client")
  local data, real, notes

  before_each(function()
    data = vim.fn.tempname()
    notes = {}
    real = { stdpath = vim.fn.stdpath, fetch = jar._fetch, fetch_gh = jar._fetch_gh, notify = vim.notify,
      executable = vim.fn.executable, updated = client.updated }
    vim.fn.stdpath = function(what) return what == "data" and data or real.stdpath(what) end
    vim.fn.executable = function(name) return name == "gh" and 0 or real.executable(name) end
    vim.notify = function(msg, level) table.insert(notes, { msg = msg, level = level }) end
    require("socless").config = require("socless.config").merge({})
  end)

  after_each(function()
    vim.fn.stdpath, jar._fetch, jar._fetch_gh, vim.notify = real.stdpath, real.fetch, real.fetch_gh, real.notify
    vim.fn.executable, client.updated = real.executable, real.updated
    require("socless").config = nil
    vim.fn.delete(data, "rf")
  end)

  it("keeps the old jar when the download fails (the network is down)", function()
    local path = jar.path(require("socless").config)
    vim.fn.mkdir(vim.fs.dirname(path), "p")
    vim.fn.writefile({ "old jar" }, path)
    jar._fetch = function(_, _, cb) vim.schedule(function() cb("curl: (6) Could not resolve host") end) end
    local updated = 0
    client.updated = function() updated = updated + 1 end
    commands.run("update")
    assert(vim.wait(2000, function()
      return #vim.tbl_filter(function(n) return n.level == vim.log.levels.ERROR end, notes) > 0
    end), "no error")
    eq({ "old jar" }, vim.fn.readfile(path))
    eq(0, updated)
  end)

  it("forces the download, then hands the new jar to the client", function()
    local real_ensure, opts = jar.ensure, nil
    jar.ensure = function(_, cb, o) opts = o; cb("/new.jar") end
    local updated = 0
    client.updated = function() updated = updated + 1 end
    local ok, err = pcall(commands.run, "update")
    jar.ensure = real_ensure
    assert(ok, err)
    eq({ force = true }, opts)
    eq(1, updated)
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
