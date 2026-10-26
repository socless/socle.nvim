local client = require("socless.client")
local jar = require("socless.jar")

local real = {}
local notes, configs, enabled, lens_enables

---A scratch Mill project (a build.mill) or not, with one Scala file in it.
local function scala_buffer(mill)
  local dir = vim.fn.tempname()
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
    client._can_attach = function() return true end
    notes, configs, enabled, lens_enables = {}, {}, {}, {}
    vim.notify = function(msg, level) table.insert(notes, { msg = msg, level = level }) end
    vim.lsp.config = function(name, cfg) table.insert(configs, { name = name, cfg = cfg }) end
    vim.lsp.enable = function(name) table.insert(enabled, name) end
    vim.lsp.codelens.enable = function(on, filter) table.insert(lens_enables, { on = on, filter = filter }) end
    jar.ensure = function(_, cb) cb("/tmp/socless-lsp-0.17.0.jar") end
    client._reset()
  end)

  after_each(function()
    vim.notify, vim.fn.has = real.notify, real.has
    vim.lsp.config, vim.lsp.enable = real.config, real.enable
    vim.lsp.codelens.enable, vim.lsp.get_client_by_id = real.lens_enable, real.get_client
    jar.ensure, client._can_attach = real.ensure, real.can_attach
    pcall(vim.api.nvim_del_augroup_by_name, "socless")
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_get_name(buf):match("%.scala$") then vim.api.nvim_buf_delete(buf, { force = true }) end
    end
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
      require("socless").setup({ java = "/opt/java", settings = { wave_viewer = "browser", waves_show_wires = false } })
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
      eq({ panel = "client", waveViewer = "browser", wavesShowWires = false }, c.cfg.init_options)
      eq({ socless = { waveViewer = "browser", wavesShowWires = false } }, c.cfg.settings)
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
      vim.api.nvim_exec_autocmds("VimEnter", { group = "socless" })
      eq(1, #configs)
      eq({ "socless" }, enabled)
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

    it("reports a jar error once and retries on the next Scala buffer", function()
      jar.ensure = function(_, cb) cb(nil, "SoCLess: could not download URL") end
      require("socless").setup({})
      vim.bo[scala_buffer(true)].filetype = "scala"
      eq(0, #configs)
      eq("SoCLess: could not download URL", notes[1].msg)
      eq(vim.log.levels.ERROR, notes[1].level)
      jar.ensure = function(_, cb) cb("/tmp/j.jar") end
      vim.bo[scala_buffer(true)].filetype = "scala"
      eq(1, #configs)
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
  end)

  describe("status", function()
    local function status(s, msg, test)
      client.handlers["socless/status"](nil, { status = s, suite = "S", test = test or "t", message = msg or "" }, {})
    end

    it("notifies once per outcome change, WARN for an error", function()
      require("socless").setup({})
      status("running")
      eq(0, #notes)
      status("ok")
      status("ok")
      eq(1, #notes)
      eq(vim.log.levels.INFO, notes[1].level)
      status("error", "boom")
      eq(2, #notes)
      eq(vim.log.levels.WARN, notes[2].level)
      eq(true, notes[2].msg:find("boom", 1, true) ~= nil)
      status("simulating")
      eq(3, #notes)
      -- a second view of the same test, after running, notifies again
      status("running")
      status("ok")
      eq(4, #notes)
    end)

    it("stays quiet with notify_status off", function()
      require("socless").setup({ notify_status = false })
      status("ok")
      status("error", "boom")
      eq(0, #notes)
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

    it("sends nothing with follow_cursor = false", function()
      require("socless").setup({ follow_cursor = false })
      client._send_cursor(buf)
      eq({}, sent)
    end)
  end)
end)
