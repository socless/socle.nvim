local client = require("socless.client")
local jar = require("socless.jar")

local real = {}
local notes, configs, enabled, disabled, lens_enables
---Executables `vim.fn.executable` says are missing (all others exist).
local missing
---The scratch dirs of `scala_buffer`, deleted after each spec.
local dirs = {}

---A table like `vim.lsp.config`: `vim.lsp.config.socless = tbl` (and the
---call form) are recorded in `configs`.
local function config_recorder()
  local function record(_, name, cfg) table.insert(configs, { name = name, cfg = cfg }) end
  return setmetatable({}, { __newindex = record, __call = record })
end

---A scratch Mill project (a build.mill) or not, with one Scala file in it.
local function scala_buffer(mill)
  local dir = vim.fn.tempname()
  table.insert(dirs, dir)
  vim.fn.mkdir(dir .. "/src", "p")
  if mill then
    local f = assert(io.open(dir .. "/build.mill", "w"))
    f:write("// mill\n")
    f:close()
  end
  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_name(buf, dir .. "/src/Spec.scala")
  return buf, dir
end

describe("client", function()
  before_each(function()
    real.notify, real.has = vim.notify, vim.fn.has
    real.config, real.enable = vim.lsp.config, vim.lsp.enable
    real.lens_enable, real.get_client = vim.lsp.codelens.enable, vim.lsp.get_client_by_id
    real.ensure, real.can_attach = jar.ensure, client._can_attach
    real.executable = vim.fn.executable
    client._can_attach = function() return true end
    notes, configs, enabled, disabled, lens_enables, missing = {}, {}, {}, {}, {}, {}
    vim.notify = function(msg, level) table.insert(notes, { msg = msg, level = level }) end
    vim.fn.executable = function(name) return missing[name] and 0 or 1 end
    vim.lsp.config = config_recorder()
    vim.lsp.enable = function(name, enable)
      table.insert(enable == false and disabled or enabled, name)
    end
    vim.lsp.codelens.enable = function(on, filter) table.insert(lens_enables, { on = on, filter = filter }) end
    jar.ensure = function(_, cb) cb("/tmp/socless-lsp-0.17.0.jar") end
    client._reset()
  end)

  after_each(function()
    vim.notify, vim.fn.has = real.notify, real.has
    vim.lsp.config, vim.lsp.enable = real.config, real.enable
    vim.lsp.codelens.enable, vim.lsp.get_client_by_id = real.lens_enable, real.get_client
    jar.ensure, client._can_attach = real.ensure, real.can_attach
    vim.fn.executable = real.executable
    pcall(vim.api.nvim_del_augroup_by_name, "socless")
    pcall(vim.api.nvim_del_augroup_by_name, "socless.start")
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_get_name(buf):match("%.scala$") then vim.api.nvim_buf_delete(buf, { force = true }) end
    end
    for _, dir in ipairs(dirs) do vim.fn.delete(dir, "rf") end
    dirs = {}
    client._reset()
    require("socless").config = nil
  end)

  describe("setup", function()
    it("on Neovim older than 0.12 notifies once and does nothing", function()
      vim.fn.has = function(f) return f == "nvim-0.12" and 0 or real.has(f) end
      require("socless").config = nil
      require("socless").setup({})
      eq(1, #notes)
      eq(vim.log.levels.ERROR, notes[1].level)
      eq(true, notes[1].msg:find("0.12", 1, true) ~= nil)
      eq(nil, require("socless").config)
      eq(0, #vim.api.nvim_get_autocmds({ event = "FileType", pattern = "scala" }))
    end)

    it("notifies the unknown-setting and version warnings once each, at WARN", function()
      require("socless").setup({ version = "0.16.0", settings = { wave_viewer = "surfer", bogus = 1 } })
      local warns = vim.tbl_filter(function(n) return n.level == vim.log.levels.WARN end, notes)
      eq(2, #warns)
      eq(true, warns[1].msg:find("bogus", 1, true) ~= nil or warns[2].msg:find("bogus", 1, true) ~= nil)
      eq(true, warns[1].msg:find("wave_viewer", 1, true) ~= nil or warns[2].msg:find("wave_viewer", 1, true) ~= nil)
    end)

    it("registers the socless config once a Mill project's Scala buffer opens", function()
      require("socless").setup({ java = "/opt/java", settings = { wave_viewer = "surfer-panel", waves_show_wires = false } })
      eq(0, #configs) -- nothing before a scala buffer
      local buf = scala_buffer(true)
      vim.bo[buf].filetype = "scala"
      eq(1, #configs)
      local c = configs[1]
      eq("socless", c.name)
      eq({ "/opt/java", "-Djava.net.preferIPv4Stack=true", "-jar", "/tmp/socless-lsp-0.17.0.jar" }, c.cfg.cmd)
      eq({ "scala" }, c.cfg.filetypes)
      eq({ "build.mill" }, c.cfg.root_markers)
      eq(true, c.cfg.workspace_required)
      eq({ panel = "client", waveViewer = "surfer-panel", wavesShowWires = false }, c.cfg.init_options)
      eq({ socless = { waveViewer = "surfer-panel", wavesShowWires = false } }, c.cfg.settings)
      eq(client.handlers, c.cfg.handlers)
      eq({ "socless" }, enabled)
    end)

    it("configures and enables once for two Scala buffers", function()
      require("socless").setup({})
      vim.bo[scala_buffer(true)].filetype = "scala"
      vim.bo[scala_buffer(true)].filetype = "scala"
      eq(1, #configs)
      eq(1, #enabled)
    end)

    it("starts for a Scala buffer already open before setup", function()
      local buf = scala_buffer(true)
      vim.bo[buf].filetype = "scala"
      require("socless").setup({})
      eq(1, #configs)
    end)

    it("during startup, waits for VimEnter to enable (setup from -c after the buffer loaded)", function()
      client._can_attach = function() return false end
      local buf = scala_buffer(true)
      vim.bo[buf].filetype = "scala"
      require("socless").setup({})
      eq(0, #enabled)
      vim.api.nvim_exec_autocmds("VimEnter", {})
      eq(1, #configs)
      eq({ "socless" }, enabled)
    end)

    it("a second setup before VimEnter keeps the pending start, with the new options", function()
      client._can_attach = function() return false end
      vim.bo[scala_buffer(true)].filetype = "scala"
      require("socless").setup({ java = "/one" })
      require("socless").setup({ java = "/two" })
      vim.api.nvim_exec_autocmds("VimEnter", {})
      eq(1, #configs)
      eq("/two", configs[1].cfg.cmd[1])
      eq({ "socless" }, enabled)
    end)

    it("a second setup after the start restarts the server with the new options", function()
      vim.bo[scala_buffer(true)].filetype = "scala"
      require("socless").setup({ java = "/one" })
      eq(1, #configs)
      require("socless").setup({ java = "/two" })
      eq(2, #configs)
      eq("/two", configs[2].cfg.cmd[1])
      -- disabled (which stops the running clients), then enabled again
      eq({ "socless" }, disabled)
      eq({ "socless", "socless" }, enabled)
      eq("SoCLess: restarted with the new options", notes[#notes].msg)
      eq(vim.log.levels.INFO, notes[#notes].level)
    end)

    it("a second setup re-resolves the jar (a new server_jar is used)", function()
      jar.ensure = function(c, cb) cb(c.server_jar) end
      vim.bo[scala_buffer(true)].filetype = "scala"
      require("socless").setup({ server_jar = "/a.jar" })
      require("socless").setup({ server_jar = "/b.jar" })
      eq("/a.jar", configs[1].cfg.cmd[4])
      eq("/b.jar", configs[2].cfg.cmd[4])
    end)

    it("a second setup replaces the registered config: a removed setting does not survive", function()
      vim.lsp.config = real.config
      local ok, err = pcall(function()
        vim.bo[scala_buffer(true)].filetype = "scala"
        require("socless").setup({ java = "/one", settings = { wave_viewer = "surfer-panel" } })
        eq("surfer-panel", vim.lsp.config.socless.settings.socless.waveViewer)
        require("socless").setup({ java = "/two", settings = { waves_show_wires = false } })
        local registered = vim.lsp.config.socless
        eq({ socless = { wavesShowWires = false } }, registered.settings)
        eq(nil, registered.init_options.waveViewer)
        eq("/two", registered.cmd[1])
      end)
      vim.lsp.config._configs.socless = nil
      assert(ok, err)
    end)

    it("a second setup with a java that is missing keeps the running server", function()
      vim.bo[scala_buffer(true)].filetype = "scala"
      require("socless").setup({ java = "/one" })
      missing["/two"] = true
      require("socless").setup({ java = "/two" })
      eq(1, #configs)
      eq({}, disabled)
      eq(vim.log.levels.ERROR, notes[#notes].level)
      eq(true, notes[#notes].msg:find("java not found", 1, true) ~= nil, notes[#notes].msg)
    end)

    it("a restart outside a FileType event attaches the open Scala buffers itself", function()
      local buf = scala_buffer(true)
      vim.bo[buf].filetype = "scala"
      require("socless").setup({ java = "/one" })
      -- stands in for the group vim.lsp.enable creates
      local fired = {}
      vim.api.nvim_create_autocmd("FileType", {
        group = vim.api.nvim_create_augroup("nvim.lsp.enable", { clear = true }),
        callback = function(ev) table.insert(fired, ev.buf) end,
      })
      client._can_attach = function() return false end
      local ok, err = pcall(function()
        require("socless").setup({ java = "/two" })
        eq({ buf }, fired)
      end)
      vim.api.nvim_del_augroup_by_name("nvim.lsp.enable")
      assert(ok, err)
    end)

    it("the same setup twice warns once and does not reconfigure", function()
      vim.bo[scala_buffer(true)].filetype = "scala"
      require("socless").setup({ settings = { bogus = 1 } })
      require("socless").setup({ settings = { bogus = 1 } })
      eq(1, #notes)
      eq(1, #configs)
    end)

    it("starts once for two Scala buffers opened while the jar downloads", function()
      local calls = 0
      jar.ensure = function(_, cb)
        calls = calls + 1
        vim.defer_fn(function() cb("/tmp/j.jar") end, 20)
      end
      require("socless").setup({})
      vim.bo[scala_buffer(true)].filetype = "scala"
      vim.bo[scala_buffer(true)].filetype = "scala"
      eq(0, #configs)
      assert(vim.wait(1000, function() return #enabled > 0 end), "never enabled")
      eq(1, calls)
      eq(1, #configs)
      eq({ "socless" }, enabled)
    end)

    it("does nothing for a Scala file outside a Mill project (no fetch, no config)", function()
      local fetched = 0
      jar.ensure = function(_, cb) fetched = fetched + 1; cb("/tmp/x.jar") end
      require("socless").setup({})
      vim.bo[scala_buffer(false)].filetype = "scala"
      eq(0, fetched)
      eq(0, #configs)
      eq(0, #notes)
    end)

    it("reports a jar error once, does not retry on the next Scala buffer, retries on setup", function()
      local calls = 0
      jar.ensure = function(_, cb) calls = calls + 1; cb(nil, "SoCLess: could not download URL") end
      require("socless").setup({})
      vim.bo[scala_buffer(true)].filetype = "scala"
      eq(0, #configs)
      eq(1, #notes)
      eq("SoCLess: could not download URL", notes[1].msg)
      eq(vim.log.levels.ERROR, notes[1].level)
      vim.bo[scala_buffer(true)].filetype = "scala"
      eq(1, calls)
      eq(1, #notes)
      jar.ensure = function(_, cb) cb("/tmp/j.jar") end
      require("socless").setup({})
      eq(1, #configs)
    end)

    it("a missing java is an ERROR naming what was tried, with no download", function()
      local fetched = 0
      jar.ensure = function(_, cb) fetched = fetched + 1; cb("/tmp/j.jar") end
      missing["/nojava"] = true
      require("socless").setup({ java = "/nojava" })
      vim.bo[scala_buffer(true)].filetype = "scala"
      eq(0, fetched)
      eq(0, #configs)
      eq(1, #notes)
      eq(vim.log.levels.ERROR, notes[1].level)
      eq("SoCLess: java not found (/nojava): set `java` or $JAVA_HOME, see :checkhealth socless", notes[1].msg)
      -- no phase was taken: once java is there, the next Scala buffer starts
      missing["/nojava"] = nil
      vim.bo[scala_buffer(true)].filetype = "scala"
      eq(1, #configs)
    end)

    it("expands ~ in the java option", function()
      eq(vim.fs.normalize("~/jdk/bin/java"), client.java({ java = "~/jdk/bin/java" }))
      eq("/", client.java({ java = "~/jdk/bin/java" }):sub(1, 1))
    end)

    it("leaves settings out of the client config when none is set", function()
      local c = client.lsp_config({ settings = {} }, "/j.jar")
      eq(nil, c.settings)
      eq({ panel = "client" }, c.init_options)
    end)

    it("notifies an unknown top-level option at WARN", function()
      require("socless").setup({ bogus = 1 })
      eq({ { msg = "SoCLess: unknown option 'bogus', ignored", level = vim.log.levels.WARN } }, notes)
    end)

    it("sends a setting given flat at the top level of the options", function()
      require("socless").setup({ wave_viewer = "surfer-panel" })
      vim.bo[scala_buffer(true)].filetype = "scala"
      eq({ socless = { waveViewer = "surfer-panel" } }, configs[1].cfg.settings)
    end)

    it("uses $JAVA_HOME/bin/java, else java", function()
      local saved = vim.env.JAVA_HOME
      vim.env.JAVA_HOME = "/jdk"
      eq("/jdk/bin/java", client.lsp_config({ settings = {} }, "/j.jar").cmd[1])
      vim.env.JAVA_HOME = nil
      eq("java", client.lsp_config({ settings = {} }, "/j.jar").cmd[1])
      vim.env.JAVA_HOME = saved
    end)
  end)

  describe("openPanel", function()
    local opened
    before_each(function()
      opened = {}
      require("socless").setup({ open_panel = function(url) table.insert(opened, url) end })
    end)

    local function open_panel(url)
      client.handlers["socless/openPanel"](nil, { url = url, test = "t" }, { method = "socless/openPanel" })
    end

    it("opens once for the same URL, again for a new one", function()
      open_panel("http://127.0.0.1:1/")
      open_panel("http://127.0.0.1:1/")
      eq({ "http://127.0.0.1:1/" }, opened)
      open_panel("http://127.0.0.1:2/")
      eq({ "http://127.0.0.1:1/", "http://127.0.0.1:2/" }, opened)
    end)

    it(":Socless panel forces the last URL open again", function()
      open_panel("http://127.0.0.1:1/")
      require("socless.commands").run("panel")
      eq({ "http://127.0.0.1:1/", "http://127.0.0.1:1/" }, opened)
    end)

    it(":Socless panel with no view yet says so", function()
      require("socless.commands").run("panel")
      eq({}, opened)
      eq("SoCLess: no view yet", notes[#notes].msg)
    end)

    it("runs a command list with the URL appended", function()
      local ran
      local real_system = vim.system
      vim.system = function(cmd, opts) ran = { cmd = cmd, opts = opts }; return {} end
      local ok, err = pcall(client._open_with, { "firefox", "--new-tab" }, "http://u/")
      vim.system = real_system
      assert(ok, err)
      eq({ "firefox", "--new-tab", "http://u/" }, ran.cmd)
    end)

    it("reports an opener failure with the URL, and the next view retries", function()
      local real_open = vim.ui.open
      local tries = 0
      vim.ui.open = function() tries = tries + 1; return nil, "vim.ui.open: no handler found" end
      require("socless").setup({})
      local ok, err = pcall(function()
        open_panel("http://127.0.0.1:1/")
        open_panel("http://127.0.0.1:1/")
      end)
      vim.ui.open = real_open
      assert(ok, err)
      eq(2, tries)
      eq(vim.log.levels.ERROR, notes[1].level)
      eq(true, notes[1].msg:find("http://127.0.0.1:1/", 1, true) ~= nil)
      eq(true, notes[1].msg:find("no handler found", 1, true) ~= nil)
    end)
  end)

  describe("status", function()
    local function status(s, msg, test)
      client.handlers["socless/status"](nil, { status = s, suite = "S", test = test or "t", message = msg or "" }, {})
    end

    it("says design ready once per test: a rerun of the same test (a save) is silent", function()
      require("socless").setup({})
      status("running")
      eq(0, #notes)
      status("ok")
      eq(1, #notes)
      eq(vim.log.levels.INFO, notes[1].level)
      eq(true, notes[1].msg:find("design ready", 1, true) ~= nil)
      status("running")
      status("ok")
      status("idle")
      status("running")
      status("ok")
      eq(1, #notes)
    end)

    it("notifies design ready for a new test", function()
      require("socless").setup({})
      status("ok", "", "a")
      status("running", "", "b")
      status("ok", "", "b")
      eq(2, #notes)
      eq(true, notes[2].msg:find("b", 1, true) ~= nil)
    end)

    it("never notifies an error (the server shows it)", function()
      require("socless").setup({})
      status("running")
      status("error", "boom")
      eq(0, #notes)
    end)

    it("never notifies an ok with a message (a simulation's end, the server shows it)", function()
      require("socless").setup({})
      status("simulating")
      status("ok", "Simulation failed: x")
      eq(1, #notes) -- the simulating one only
      eq(true, notes[1].msg:find("simulating", 1, true) ~= nil)
    end)

    it("stays silent for an ok after an error of the same test already shown ready", function()
      require("socless").setup({})
      status("ok")
      status("error", "boom")
      status("running")
      status("ok")
      eq(1, #notes)
    end)

    it("notifies simulating once per start", function()
      require("socless").setup({})
      status("simulating")
      status("simulating")
      eq(1, #notes)
      status("ok", "done")
      status("simulating")
      eq(2, #notes)
    end)

    it("stays quiet with notify_status off", function()
      require("socless").setup({ notify_status = false })
      status("ok")
      status("error", "boom")
      eq(0, #notes)
    end)
  end)

  describe("updated (a new jar from :Socless update)", function()
    it("restarts a started client", function()
      vim.bo[scala_buffer(true)].filetype = "scala"
      require("socless").setup({})
      client.updated()
      eq({ "socless" }, disabled)
      eq({ "socless", "socless" }, enabled)
    end)

    it("starts for the current Scala buffer when no client started", function()
      local calls = 0
      jar.ensure = function(_, cb)
        calls = calls + 1
        if calls == 1 then return cb(nil, "SoCLess: offline") end
        cb("/tmp/j.jar")
      end
      require("socless").setup({})
      local buf = scala_buffer(true)
      vim.bo[buf].filetype = "scala"
      eq(0, #configs)
      vim.api.nvim_set_current_buf(buf)
      client.updated()
      eq(1, #configs)
      eq({ "socless" }, enabled)
    end)
  end)

  describe("codelens", function()
    it("enables lenses for the attaching socless client only", function()
      require("socless").setup({})
      vim.lsp.get_client_by_id = function(id) return { id = id, name = id == 7 and "socless" or "metals" } end
      client._on_attach({ buf = 3, data = { client_id = 9 } })
      eq({}, lens_enables)
      client._on_attach({ buf = 3, data = { client_id = 7 } })
      eq({ { on = true, filter = { bufnr = 3, client_id = 7 } } }, lens_enables)
    end)

    it("does not enable lenses with codelens = false", function()
      require("socless").setup({ codelens = false })
      vim.lsp.get_client_by_id = function(id) return { id = id, name = "socless" } end
      client._on_attach({ buf = 3, data = { client_id = 7 } })
      eq({}, lens_enables)
    end)
  end)

  describe("cursor", function()
    local sent, buf
    before_each(function()
      sent = {}
      buf = scala_buffer(true)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "a", "b", "c", "d" })
      vim.api.nvim_set_current_buf(buf)
      vim.api.nvim_win_set_cursor(0, { 3, 0 })
      client._get = function() return { notify = function(_, m, p) table.insert(sent, { m, p }) end } end
    end)
    after_each(function() client._get = nil end)

    it("sends socless/cursor with a 0-based line", function()
      require("socless").setup({})
      client._send_cursor(buf)
      eq({ { "socless/cursor", { uri = vim.uri_from_bufnr(buf), line = 2 } } }, sent)
    end)

    it("sends again only when the line or the buffer changed", function()
      require("socless").setup({})
      client._send_cursor(buf)
      client._send_cursor(buf)
      eq(1, #sent)
      vim.api.nvim_win_set_cursor(0, { 4, 0 })
      client._send_cursor(buf)
      eq(2, #sent)
      eq(3, sent[2][2].line)
      local other = scala_buffer(true)
      vim.api.nvim_buf_set_lines(other, 0, -1, false, { "a", "b", "c", "d" })
      vim.api.nvim_set_current_buf(other)
      vim.api.nvim_win_set_cursor(0, { 4, 0 })
      client._send_cursor(other)
      eq(3, #sent)
    end)

    it("sends the same line again after a new socless client attached", function()
      require("socless").setup({ codelens = false })
      vim.lsp.get_client_by_id = function(id) return { id = id, name = "socless" } end
      client._send_cursor(buf)
      client._on_attach({ buf = buf, data = { client_id = 8 } })
      client._send_cursor(buf)
      eq(2, #sent)
    end)

    it("sends nothing with follow_cursor = false", function()
      require("socless").setup({ follow_cursor = false })
      client._send_cursor(buf)
      eq({}, sent)
    end)
  end)
end)
