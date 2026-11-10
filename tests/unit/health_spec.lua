local health = require("socle.health")
local socle = require("socle")
local config = require("socle.config")

describe("health", function()
  local real = {}
  ---Every report, as "<level> <text>" ("start", "ok", "warn", "error", "info").
  local reports
  ---Overrides for `vim.fn.executable` (1 or 0); other names are absent.
  local tools
  ---Results of `health._run`, by the command's first word.
  local runs
  local dir

  local function report(level)
    return function(msg, advice)
      local text = level .. " " .. msg
      if advice then
        text = text .. " | " .. table.concat(type(advice) == "table" and advice or { advice }, " ")
      end
      table.insert(reports, text)
    end
  end

  ---The reports of `level` whose text contains `needle` (plain).
  local function find(level, needle)
    return vim.tbl_filter(function(r)
      return vim.startswith(r, level .. " ") and r:find(needle, 1, true) ~= nil
    end, reports)
  end

  local function has(level, needle)
    if #find(level, needle) == 0 then
      error(("no %s report with %q in:\n%s"):format(level, needle, table.concat(reports, "\n")), 2)
    end
  end

  local function hasnt(level, needle)
    if #find(level, needle) > 0 then
      error(("unexpected %s report with %q in:\n%s"):format(level, needle, table.concat(reports, "\n")), 2)
    end
  end

  ---A file at `path` (parents created).
  local function touch(path)
    vim.fn.mkdir(vim.fs.dirname(path), "p")
    local f = assert(io.open(path, "wb"))
    f:write("x")
    f:close()
  end

  local function java_says(version_line)
    runs.java = { code = 0, stdout = "", stderr = version_line .. "\nOpenJDK Runtime Environment\n" }
  end

  before_each(function()
    reports, runs = {}, {}
    tools = { java = 1, curl = 1, sha256sum = 1, gh = 1, verilator = 1, surfer = 1, mill = 0 }
    dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    real.health = vim.health
    real.executable = vim.fn.executable
    real.run = health._run
    real.config = socle.config
    real.stdpath = vim.fn.stdpath
    real.cwd = vim.fn.getcwd()
    real.java_home = vim.env.JAVA_HOME
    vim.env.JAVA_HOME = nil
    vim.health = {
      start = report("start"), ok = report("ok"), warn = report("warn"),
      error = report("error"), info = report("info"),
    }
    vim.fn.executable = function(name)
      return tools[name] or 0
    end
    vim.fn.stdpath = function(what)
      if what == "data" then return dir .. "/data" end
      return real.stdpath(what)
    end
    health._run = function(cmd)
      local r = runs[cmd[1]] or runs[vim.fs.basename(cmd[1])]
      if not r then return { code = -1, stdout = "", stderr = "not stubbed: " .. cmd[1] } end
      return r
    end
    java_says('openjdk version "21.0.12.1" 2026-08-18')
    runs.gh = { code = 0, stdout = "", stderr = "Logged in to github.com account someone" }
    -- the pinned jar, when a spec puts one on disk, hashes to the pin
    runs.sha256sum = { code = 0, stdout = require("socle.versions").PINNED_SHA256 .. "  x.jar\n", stderr = "" }
    -- a Mill project as the cwd, with its ./mill launcher
    touch(dir .. "/proj/build.mill")
    touch(dir .. "/proj/mill")
    vim.uv.fs_chmod(dir .. "/proj/mill", 493) -- 0755
    vim.cmd.cd(dir .. "/proj")
    socle.config = config.merge({})
  end)

  after_each(function()
    vim.health = real.health
    vim.fn.executable = real.executable
    vim.fn.stdpath = real.stdpath
    health._run = real.run
    socle.config = real.config
    vim.env.JAVA_HOME = real.java_home
    vim.cmd.cd(real.cwd)
    vim.fn.delete(dir, "rf")
  end)

  it("reports Neovim 0.12 or later as OK", function()
    health.check()
    has("ok", "Neovim 0.12")
  end)

  it("says setup has not been called, and checks with the defaults", function()
    socle.config = nil
    health.check()
    has("warn", "setup() has not been called")
    has("ok", "java 21")
  end)

  describe("java", function()
    it("accepts 21 (21.0.12.1)", function()
      health.check()
      has("ok", "java 21")
    end)

    it("accepts 25 with no dot", function()
      java_says('openjdk version "25" 2025-09-16')
      health.check()
      has("ok", "java 25")
    end)

    it("reads 21-ea as 21", function()
      java_says('openjdk version "21-ea" 2023-09-19')
      health.check()
      has("ok", "java 21")
    end)

    it("rejects 17 as an ERROR", function()
      java_says('openjdk version "17.0.9" 2023-10-17')
      health.check()
      has("error", "java 17")
      hasnt("ok", "java ")
    end)

    it("reads the legacy 1.8.0 as 8, an ERROR", function()
      java_says('java version "1.8.0_392"')
      health.check()
      has("error", "java 8")
    end)

    it("reports a java that is not found as an ERROR", function()
      tools.java = 0
      health.check()
      has("error", "java not found")
    end)

    it("reports an unreadable version as an ERROR", function()
      runs.java = { code = 1, stdout = "", stderr = "Error: something" }
      health.check()
      has("error", "cannot read the version")
    end)

    it("checks the java the client runs: cfg.java first", function()
      local asked
      socle.config = config.merge({ java = "/opt/jdk/bin/java" })
      tools["/opt/jdk/bin/java"] = 1
      local stub = health._run
      health._run = function(cmd)
        if cmd[2] == "-version" then asked = cmd[1] end
        return stub(cmd)
      end
      health.check()
      eq("/opt/jdk/bin/java", asked)
    end)

    it("checks the java the client runs: $JAVA_HOME/bin/java next", function()
      local asked
      vim.env.JAVA_HOME = "/jdk25"
      tools["/jdk25/bin/java"] = 1
      local stub = health._run
      health._run = function(cmd)
        if cmd[2] == "-version" then asked = cmd[1] end
        return stub(cmd)
      end
      health.check()
      eq("/jdk25/bin/java", asked)
    end)
  end)

  describe("jar", function()
    local PIN = require("socle.versions").PINNED_SHA256
    local function hashes_to(hash)
      runs.sha256sum = { code = 0, stdout = hash .. "  " .. dir .. "/data/socle/socle-lsp-0.25.1.jar\n", stderr = "" }
    end

    it("re-hashes a pinned jar on disk: OK when it matches PINNED_SHA256", function()
      touch(dir .. "/data/socle/socle-lsp-0.25.1.jar")
      local asked
      local stub = health._run
      health._run = function(cmd)
        if cmd[1] == "sha256sum" then asked = cmd end
        return stub(cmd)
      end
      hashes_to(PIN)
      health.check()
      eq({ "sha256sum", dir .. "/data/socle/socle-lsp-0.25.1.jar" }, asked)
      has("ok", "socle-lsp-0.25.1.jar")
      has("ok", "0.25.1")
      has("ok", "matches the pinned sha256")
    end)

    it("a pinned jar that does not match PINNED_SHA256 is an ERROR", function()
      touch(dir .. "/data/socle/socle-lsp-0.25.1.jar")
      hashes_to(string.rep("0", 64))
      health.check()
      has("error", "does not match the pinned sha256")
      has("error", ":Socle update")
    end)

    it("a pinned jar that cannot be re-hashed is a WARN", function()
      touch(dir .. "/data/socle/socle-lsp-0.25.1.jar")
      tools.sha256sum = 0
      health.check()
      has("warn", "socle-lsp-0.25.1.jar")
    end)

    it("a jar of a version the user set was checked against SHA256SUMS", function()
      touch(dir .. "/data/socle/socle-lsp-0.16.0.jar")
      socle.config = config.merge({ version = "0.16.0" })
      health.check()
      has("ok", "socle-lsp-0.16.0.jar")
      has("ok", "SHA256SUMS")
    end)

    it("a missing pinned jar is a WARN (downloaded with the first Scala buffer)", function()
      health.check()
      has("warn", "socle-lsp-0.25.1.jar")
      hasnt("error", "jar")
    end)

    it("a server_jar on disk is OK, version unknown, checksum not checked", function()
      touch(dir .. "/my.jar")
      socle.config = config.merge({ server_jar = dir .. "/my.jar" })
      health.check()
      has("ok", dir .. "/my.jar")
      has("ok", "not checked")
    end)

    it("a missing server_jar is an ERROR", function()
      socle.config = config.merge({ server_jar = dir .. "/none.jar" })
      health.check()
      has("error", dir .. "/none.jar")
    end)
  end)

  describe("download tools", function()
    it("only WARNs about gh when the jar must be downloaded", function()
      tools.gh = 0
      health.check()
      has("warn", "gh not found")
    end)

    it("reports a missing gh as INFO when the jar is on disk", function()
      tools.gh = 0
      touch(dir .. "/data/socle/socle-lsp-0.25.1.jar")
      health.check()
      has("info", "gh not found")
      hasnt("warn", "gh")
    end)

    it("reports a missing gh as INFO with a server_jar", function()
      tools.gh = 0
      touch(dir .. "/my.jar")
      socle.config = config.merge({ server_jar = dir .. "/my.jar" })
      health.check()
      has("info", "gh not found")
      hasnt("warn", "gh")
    end)

    it("WARNs about a gh that is not logged in when the jar must be downloaded", function()
      runs.gh = { code = 1, stdout = "", stderr = "You are not logged into any GitHub hosts." }
      health.check()
      has("warn", "gh is not logged in")
    end)

    it("reports a gh that is not logged in as INFO when the jar is on disk", function()
      runs.gh = { code = 1, stdout = "", stderr = "You are not logged into any GitHub hosts." }
      touch(dir .. "/data/socle/socle-lsp-0.25.1.jar")
      health.check()
      has("info", "gh is not logged in")
      hasnt("warn", "gh")
    end)

    it("reports a logged-in gh as OK", function()
      health.check()
      has("ok", "gh is logged in")
    end)

    it("asks gh auth status", function()
      local asked
      local stub = health._run
      health._run = function(cmd)
        if cmd[1] == "gh" then asked = cmd end
        return stub(cmd)
      end
      health.check()
      eq({ "gh", "auth", "status" }, asked)
    end)

    it("accepts sha256sum, or shasum", function()
      health.check()
      has("ok", "sha256sum")
      tools.sha256sum, tools.shasum = 0, 1
      reports = {}
      health.check()
      has("ok", "shasum")
    end)

    it("is an ERROR with neither checksum tool when the jar must be downloaded", function()
      tools.sha256sum = 0
      health.check()
      has("error", "neither sha256sum nor shasum")
    end)

    it("is only INFO with neither checksum tool when the jar is on disk", function()
      tools.sha256sum = 0
      touch(dir .. "/data/socle/socle-lsp-0.25.1.jar")
      health.check()
      has("info", "neither sha256sum nor shasum")
      hasnt("error", "sha256sum")
    end)

    it("reports curl, a WARN only when the jar must be downloaded", function()
      health.check()
      has("ok", "curl")
      tools.curl = 0
      reports = {}
      health.check()
      has("warn", "curl not found")
      touch(dir .. "/data/socle/socle-lsp-0.25.1.jar")
      reports = {}
      health.check()
      has("info", "curl not found")
    end)
  end)

  describe("mill", function()
    it("finds ./mill at the Mill project's root", function()
      health.check()
      has("ok", "./mill")
    end)

    it("falls back to mill on PATH", function()
      vim.fn.delete(dir .. "/proj/mill")
      tools.mill = 1
      health.check()
      has("ok", "mill on PATH")
    end)

    it("WARNs with neither ./mill nor mill on PATH", function()
      vim.fn.delete(dir .. "/proj/mill")
      health.check()
      has("warn", "no ./mill")
    end)

    it("WARNs outside a Mill project", function()
      vim.cmd.cd(dir)
      health.check()
      has("warn", "no build.mill")
    end)

    it("uses the root of a Scala buffer that is open", function()
      vim.cmd.cd(dir)
      touch(dir .. "/proj/src/A.scala")
      local buf = vim.fn.bufadd(dir .. "/proj/src/A.scala")
      vim.fn.bufload(buf)
      vim.bo[buf].filetype = "scala"
      health.check()
      vim.api.nvim_buf_delete(buf, { force = true })
      has("ok", "./mill")
    end)
  end)

  describe("simulate", function()
    it("WARNs when verilator is missing", function()
      tools.verilator = 0
      health.check()
      has("warn", "verilator not found")
    end)

    it("checks surfer by default", function()
      health.check()
      has("ok", "surfer")
      tools.surfer = 0
      reports = {}
      health.check()
      has("warn", "surfer not found")
    end)

    it("checks surfer_command, an executable (the server does not split it)", function()
      tools.surfer = 0
      tools["/opt/surfer/bin/surfer"] = 1
      socle.config = config.merge({ settings = { surfer_command = " /opt/surfer/bin/surfer " } })
      health.check()
      has("ok", "/opt/surfer/bin/surfer")
      hasnt("warn", "surfer")
    end)

    it("checks surfer for wave_viewer = custom with no wave_viewer_command", function()
      tools.surfer = 0
      socle.config = config.merge({ settings = { wave_viewer = "custom" } })
      health.check()
      has("warn", "surfer not found")
    end)

    it("does not need surfer for wave_viewer = custom with a command", function()
      tools.surfer = 0
      socle.config = config.merge({ settings = { wave_viewer = "custom", wave_viewer_command = "gtkwave {file}" } })
      health.check()
      hasnt("warn", "surfer")
      has("info", "custom")
    end)

    it("does not need surfer with wave_viewer = surfer-panel", function()
      tools.surfer = 0
      socle.config = config.merge({ settings = { wave_viewer = "surfer-panel" } })
      health.check()
      hasnt("warn", "surfer")
      has("info", "surfer-panel")
    end)
  end)
end)
