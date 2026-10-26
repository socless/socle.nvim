local versions = require("socless.versions")
local config = require("socless.config")

describe("versions", function()
  it("pins 0.17.0", function()
    eq("0.17.0", versions.PINNED)
    eq(versions.PINNED, config.defaults.version)
  end)

  it("warns for wave_viewer on 0.16.0", function()
    local w = versions.warnings(config.merge({ version = "0.16.0", settings = { wave_viewer = "surfer-panel" } }))
    eq(1, #w)
    eq(true, w[1]:find("wave_viewer", 1, true) ~= nil, w[1])
    eq(true, w[1]:find("0.17.0", 1, true) ~= nil, w[1])
  end)

  it("does not warn on 0.17.0", function()
    eq({}, versions.warnings(config.merge({ version = "0.17.0", settings = { wave_viewer = "surfer-panel" } })))
  end)

  it("does not warn with a server_jar (version unknown)", function()
    eq({}, versions.warnings(config.merge({
      version = "0.16.0",
      server_jar = "/tmp/socless-lsp.jar",
      settings = { wave_viewer = "surfer-panel" },
    })))
  end)

  it("keeps wave_flag and surfer_command at 0.16.0", function()
    eq({}, versions.warnings(config.merge({
      version = "0.16.0",
      settings = { wave_flag = "emitVcd", surfer_command = "surfer" },
    })))
    eq(2, #versions.warnings(config.merge({
      version = "0.15.0",
      settings = { wave_flag = "emitVcd", surfer_command = "surfer" },
    })))
  end)

  it("gives one warning per option, for every waves_* option", function()
    local w = versions.warnings(config.merge({
      version = "0.16.0",
      settings = {
        wave_viewer = "surfer", wave_viewer_command = "x", waves_follow_selection = true,
        waves_show_clock_reset = true, waves_fold_bundles = true, waves_show_wires = true,
        waves_color_by_direction = true, waves_follow_delay_ms = 1,
      },
    }))
    eq(8, #w)
  end)

  it("compares versions numerically", function()
    eq({}, versions.warnings(config.merge({ version = "0.100.0", settings = { wave_viewer = "surfer" } })))
    eq(1, #versions.warnings(config.merge({ version = "0.9.0", settings = { wave_viewer = "surfer" } })))
  end)

  it("does not warn for wave_viewer on 0.17.1-SNAPSHOT or 1.0.0, warns on 0.16.0", function()
    local function w(v) return versions.warnings(config.merge({ version = v, settings = { wave_viewer = "surfer" } })) end
    eq({}, w("0.17.1-SNAPSHOT"))
    eq({}, w("1.0.0"))
    eq(1, #w("0.16.0"))
  end)

  -- the docs name the pin; a bump that forgets them fails here
  it("is the version README.md and doc/socless.txt name", function()
    local root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2))))
    local function read(rel)
      local f = assert(io.open(root .. "/" .. rel))
      local s = f:read("*a")
      f:close()
      return s
    end
    local readme, doc = read("README.md"), read("doc/socless.txt")
    local default = ('version = "%s"'):format(versions.PINNED)
    eq(true, readme:find(default, 1, true) ~= nil, "README.md: " .. default)
    eq(true, readme:find(("PINNED`, now %s)"):format(versions.PINNED), 1, true) ~= nil, "README.md: the pin")
    eq(true, doc:find(default, 1, true) ~= nil, "doc/socless.txt: " .. default)
    eq(true, doc:find(("tested against (%s)"):format(versions.PINNED), 1, true) ~= nil, "doc/socless.txt: the pin")
  end)
end)
