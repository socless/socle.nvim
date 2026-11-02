---`:checkhealth socle`.
local M = {}

local MIN_JAVA = 21

---Runs `cmd` and waits (5 s at most by default: `gh auth status` may ask the
---network). Replaced in tests.
---@param cmd string[]
---@param timeout_ms? integer
---@return {code: integer, stdout: string, stderr: string}
function M._run(cmd, timeout_ms)
  local ok, res = pcall(function() return vim.system(cmd, { text = true }):wait(timeout_ms or 5000) end)
  if not ok then return { code = -1, stdout = "", stderr = tostring(res) } end
  return { code = res.code, stdout = res.stdout or "", stderr = res.stderr or "" }
end

---The major version in `java -version`'s output: "21.0.1" is 21, "25" is 25,
---"21-ea" is 21, and the legacy "1.8.0_392" is 8.
---@param text string
---@return integer|nil
local function java_major(text)
  local version = text:match('version "([^"]+)"')
  if not version then return nil end
  local legacy = version:match("^1%.(%d+)")
  return tonumber(legacy or version:match("^(%d+)"))
end

---@param cfg socle.Config
local function check_java(cfg)
  local java = require("socle.client").java(cfg)
  if vim.fn.executable(java) ~= 1 then
    return vim.health.error(("java not found (%s)"):format(java),
      { "Install Java 21 or later, or set the `java` option or $JAVA_HOME" })
  end
  local res = M._run({ java, "-version" })
  local major = java_major(res.stderr .. "\n" .. res.stdout)
  if not major then
    return vim.health.error(("cannot read the version of %s: %s"):format(java, vim.trim(res.stderr)))
  end
  if major < MIN_JAVA then
    return vim.health.error(("java %d (%s): the server needs Java %d or later"):format(major, java, MIN_JAVA),
      { "Install Java 21 or later, or set the `java` option or $JAVA_HOME" })
  end
  vim.health.ok(("java %d (%s)"):format(major, java))
end

---Reports a downloaded jar: the pinned version's is hashed again and
---compared with PINNED_SHA256 (a few hundred ms; checkhealth is synchronous).
---@param cfg socle.Config
---@param path string
local function check_pinned_hash(cfg, path)
  local versions = require("socle.versions")
  if cfg.version ~= versions.PINNED then
    return vim.health.ok(("server %s: %s (checked against the release's SHA256SUMS when downloaded)")
      :format(cfg.version, path))
  end
  local jar = require("socle.jar")
  local cmd = jar._hash_cmd(path)
  if not cmd then
    return vim.health.warn(("server %s: %s (cannot check its sha256: neither sha256sum nor shasum)")
      :format(cfg.version, path))
  end
  local res = M._run(cmd, 60000)
  local got = res.code == 0 and jar._parse_hash(res.stdout)
  if not got then
    return vim.health.warn(("server %s: %s (cannot check its sha256: %s)")
      :format(cfg.version, path, vim.trim(res.stderr ~= "" and res.stderr or res.stdout)))
  end
  if got ~= versions.PINNED_SHA256 then
    return vim.health.error(("server %s: %s does not match the pinned sha256 (expected %s, got %s)")
      :format(cfg.version, path, versions.PINNED_SHA256, got), { "Run :Socle update to download it again" })
  end
  vim.health.ok(("server %s: %s (matches the pinned sha256)"):format(cfg.version, path))
end

---Reports the jar; returns whether it must still be downloaded.
---@param cfg socle.Config
---@return boolean need_download
local function check_jar(cfg)
  local path = require("socle.jar").path(cfg)
  local present = vim.uv.fs_stat(path) ~= nil
  if cfg.server_jar then
    if present then
      vim.health.ok(("server_jar %s (version unknown, checksum not checked)"):format(path))
    else
      vim.health.error(("server_jar not found: %s"):format(path))
    end
    return false
  end
  if present then
    check_pinned_hash(cfg, path)
    return false
  end
  vim.health.warn(("server %s not downloaded yet: %s"):format(cfg.version, path),
    { "It is downloaded when the first Scala buffer of a Mill project opens, or with :Socle update" })
  return true
end

---Reports curl, the checksum tool and gh: problems are WARN (ERROR for the
---checksum tool) only when the jar must be downloaded, else INFO.
---@param need_download boolean
local function check_download_tools(need_download)
  local soft = need_download and vim.health.warn or vim.health.info
  local hard = need_download and vim.health.error or vim.health.info
  local unneeded = need_download and "" or " (only needed to download the jar)"

  if vim.fn.executable("curl") == 1 then
    vim.health.ok("curl")
  else
    soft("curl not found" .. unneeded, { "The download falls back to gh" })
  end

  if vim.fn.executable("sha256sum") == 1 then
    vim.health.ok("sha256sum")
  elseif vim.fn.executable("shasum") == 1 then
    vim.health.ok("shasum (shasum -a 256)")
  else
    hard("neither sha256sum nor shasum is installed" .. unneeded,
      { "The downloaded jar cannot be checked: install coreutils (sha256sum) or perl (shasum)" })
  end

  local repo = require("socle.jar").REPO
  if vim.fn.executable("gh") ~= 1 then
    return soft("gh not found" .. unneeded,
      { ("While %s is private, the download needs a logged-in gh, or set server_jar"):format(repo) })
  end
  if M._run({ "gh", "auth", "status" }).code == 0 then
    vim.health.ok("gh is logged in (the download falls back to it)")
  else
    soft("gh is not logged in" .. unneeded,
      { ("Run `gh auth login` with access to %s, or set server_jar"):format(repo) })
  end
end

---The Mill project roots to check: those of the Scala buffers open (the
---current buffer is the health report), else the working directory's.
---@return string[]
local function mill_roots()
  local roots = {}
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].filetype == "scala" then
      local root = vim.fs.root(buf, { "build.mill" })
      if root and not vim.tbl_contains(roots, root) then table.insert(roots, root) end
    end
  end
  if #roots == 0 then
    local root = vim.fs.root(vim.fn.getcwd(), { "build.mill" })
    if root then table.insert(roots, root) end
  end
  return roots
end

---The server runs the project's ./mill, else mill on PATH (MillBridge).
local function check_mill()
  local roots = mill_roots()
  if #roots == 0 then
    return vim.health.warn("no build.mill above the Scala buffers or the working directory",
      { "The client only starts in a Mill project" })
  end
  for _, root in ipairs(roots) do
    local launcher = vim.uv.fs_stat(root .. "/mill")
    if launcher and launcher.type == "file" then
      vim.health.ok(("./mill in %s"):format(root))
    elseif vim.fn.executable("mill") == 1 then
      vim.health.ok(("mill on PATH (no ./mill in %s)"):format(root))
    else
      vim.health.warn(("no ./mill in %s and no mill on PATH"):format(root),
        { "The server asks Mill for the test classpath" })
    end
  end
end

---Simulate's tools: verilator, and the Surfer app for wave_viewer = "surfer"
---(or "custom" with no command, which the server runs as `<surfer> <trace>`).
---@param cfg socle.Config
local function check_simulate(cfg)
  if vim.fn.executable("verilator") == 1 then
    vim.health.ok("verilator")
  else
    vim.health.warn("verilator not found", { "Simulate needs Verilator on PATH (View design does not)" })
  end
  local settings = cfg.settings or {}
  local viewer = settings.wave_viewer or "surfer"
  local custom_cmd = vim.trim(settings.wave_viewer_command or "")
  if viewer == "surfer-panel" or (viewer == "custom" and custom_cmd ~= "") then
    return vim.health.info(("wave_viewer = %s: the Surfer app is not needed"):format(viewer))
  end
  -- one executable: the server does not split it into words
  local surfer = vim.trim(settings.surfer_command or "")
  if surfer == "" then surfer = "surfer" end
  if vim.fn.executable(surfer) == 1 then
    vim.health.ok(("%s (wave viewer)"):format(surfer))
  else
    vim.health.warn(("%s not found"):format(surfer),
      { "Simulate opens the waves in Surfer: install it, set settings.surfer_command,"
        .. ' or set settings.wave_viewer = "surfer-panel"' })
  end
end

function M.check()
  vim.health.start("socle.nvim")
  if vim.fn.has("nvim-0.12") == 1 then
    vim.health.ok("Neovim 0.12 or later")
  else
    vim.health.error("Neovim 0.12 or later is needed")
  end
  local cfg = require("socle").config
  if not cfg then
    vim.health.warn("setup() has not been called: checking with the default options",
      { 'Call require("socle").setup()' })
    cfg = require("socle.config").merge({})
  end

  vim.health.start("Server")
  check_java(cfg)
  local need_download = check_jar(cfg)
  check_download_tools(need_download)

  vim.health.start("Mill project")
  check_mill()

  vim.health.start("Simulate")
  check_simulate(cfg)
end

return M
