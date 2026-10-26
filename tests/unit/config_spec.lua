local config = require("socless.config")

describe("config.merge", function()
  it("keeps the defaults and sets the given value", function()
    local cfg = config.merge({ settings = { wave_viewer = "surfer-panel" } })
    eq("0.17.0", cfg.version)
    eq(nil, cfg.server_jar)
    eq(true, cfg.codelens)
    eq(true, cfg.follow_cursor)
    eq(true, cfg.notify_status)
    eq({ wave_viewer = "surfer-panel" }, cfg.settings)
  end)

  it("accepts nil and does not alias the defaults", function()
    local cfg = config.merge(nil)
    cfg.settings.wave_flag = "x"
    cfg.codelens = false
    eq(nil, config.defaults.settings.wave_flag)
    eq(true, config.defaults.codelens)
  end)

  it("keeps a function or a list for open_panel as given", function()
    local fn = function() end
    eq(fn, config.merge({ open_panel = fn }).open_panel)
    eq({ "firefox", "--new-tab" }, config.merge({ open_panel = { "firefox", "--new-tab" } }).open_panel)
  end)
end)

describe("config.to_server", function()
  it("sends only the set keys, in camelCase", function()
    local out, warnings = config.to_server({ wave_viewer = "surfer-panel" })
    eq({ waveViewer = "surfer-panel" }, out)
    eq({}, warnings)
  end)

  it("maps all ten keys to the server's names", function()
    local out = config.to_server({
      wave_flag = "emitVcd",
      surfer_command = "/opt/surfer",
      wave_viewer = "command",
      wave_viewer_command = "gtkwave {file}",
      waves_follow_selection = false,
      waves_show_clock_reset = true,
      waves_fold_bundles = false,
      waves_show_wires = true,
      waves_color_by_direction = false,
      waves_follow_delay_ms = 250,
    })
    eq({
      waveFlag = "emitVcd",
      surferCommand = "/opt/surfer",
      waveViewer = "command",
      waveViewerCommand = "gtkwave {file}",
      wavesFollowSelection = false,
      wavesShowClockReset = true,
      wavesFoldBundles = false,
      wavesShowWires = true,
      wavesColorByDirection = false,
      wavesFollowDelayMs = 250,
    }, out)
  end)

  it("gives an empty table for no settings", function()
    eq({}, (config.to_server(nil)))
    eq({}, (config.to_server({})))
  end)

  it("warns about an unknown key and does not send it", function()
    local out, warnings = config.to_server({ wave_viewer = "surfer", waveViewer = "x", bogus = 1 })
    eq({ waveViewer = "surfer" }, out)
    eq({
      "SoCLess: unknown setting 'bogus', ignored",
      "SoCLess: unknown setting 'waveViewer', ignored",
    }, warnings)
  end)
end)
