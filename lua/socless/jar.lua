---The server jar: where it lives, and its download and checksum check.
local M = {}

local versions = require("socless.versions")

---The GitHub repository the server releases come from.
M.REPO = "e-ban/SoCless"

---Time limits of the commands, in ms. curl's is a little over its own
---`--max-time`, so curl's own message wins.
M._timeout_ms = { curl = 330000, gh = 300000, hash = 60000 }

---A sha256 in hex: exactly 64 hex digits (the pattern is followed by a space
---or the end where it is used).
local HEX64 = string.rep("%x", 64)

local RELEASES = "https://github.com/" .. M.REPO .. "/releases/download"

---@param version string
---@return string
local function jar_name(version) return ("socless-lsp-%s.jar"):format(version) end

---@param version string
---@param asset string
---@return string
local function url(version, asset) return ("%s/v%s/%s"):format(RELEASES, version, asset) end

---Runs `cmd` for at most `timeout_ms`, then calls `cb(res)` on the main loop
---with its `vim.SystemCompleted`, or with `{ code = -1, stderr = err }` when
---it cannot start. A timeout is a failure whose stderr says so.
---@param cmd string[]
---@param timeout_ms integer
---@param cb fun(res: vim.SystemCompleted|{code: integer, stderr: string})
local function run(cmd, timeout_ms, cb)
  local ok, err = pcall(vim.system, cmd, { text = true, timeout = timeout_ms }, vim.schedule_wrap(function(res)
    -- vim.system kills the command at the time limit and sets code 124
    if res.code == 124 then
      res = { code = 124, stdout = "", stderr = ("%s timed out after %g s"):format(cmd[1], timeout_ms / 1000) }
    end
    cb(res)
  end))
  if not ok then vim.schedule(function() cb({ code = -1, stderr = tostring(err) }) end) end
end

---The text a failed command gives: its stderr, or its exit code.
---@param cmd string[]
---@param res {code: integer, stderr?: string}
---@return string
local function failure(cmd, res)
  local stderr = vim.trim(res.stderr or "")
  return stderr ~= "" and stderr or (cmd[1] .. " exited " .. res.code)
end

---Runs a download command, then calls `cb(nil)`, or `cb(err)`.
---@param cmd string[]
---@param timeout_ms integer
---@param cb fun(err: string|nil)
local function download_with(cmd, timeout_ms, cb)
  run(cmd, timeout_ms, function(res) cb(res.code ~= 0 and failure(cmd, res) or nil) end)
end

---The curl command that downloads `url` to `dest`: https only, TLS 1.2 or
---later, and time limits so a stalled download fails.
---@param u string
---@param dest string
---@return string[]
function M._curl_cmd(u, dest)
  return { "curl", "-fsSL", "--connect-timeout", "15", "--max-time", "300", "--proto", "=https", "--tlsv1.2",
    "-o", dest, u }
end

---Downloads `url` to `dest` with curl, then calls `cb(nil)`, or `cb(err)`.
---Replaced in tests. `cb` runs on the main loop.
---@param u string
---@param dest string
---@param cb fun(err: string|nil)
function M._fetch(u, dest, cb)
  download_with(M._curl_cmd(u, dest), M._timeout_ms.curl, cb)
end

---The gh command that downloads one release asset to `dest`.
---@param version string
---@param asset string
---@param dest string
---@return string[]
function M._gh_cmd(version, asset, dest)
  return { "gh", "release", "download", "v" .. version, "--repo", M.REPO, "--pattern", asset,
    "--output", dest, "--clobber" }
end

---Downloads a release asset to `dest` with gh, which can read a private
---repository after `gh auth login`, then calls `cb(nil)`, or `cb(err)`.
---Replaced in tests. `cb` runs on the main loop.
---@param version string
---@param asset string
---@param dest string
---@param cb fun(err: string|nil)
function M._fetch_gh(version, asset, dest, cb)
  download_with(M._gh_cmd(version, asset, dest), M._timeout_ms.gh, cb)
end

---Downloads one release asset: curl, then gh when curl fails and gh is
---installed, one attempt each. Calls `cb(nil, used_gh)`, or `cb(err)` naming
---the URL.
---@param version string
---@param asset string
---@param dest string
---@param cb fun(err: string|nil, used_gh: boolean|nil)
local function download_asset(version, asset, dest, cb)
  local u = url(version, asset)
  M._fetch(u, dest, function(err)
    if not err then return cb(nil, false) end
    if vim.fn.executable("gh") ~= 1 then
      local hint = err:find("404", 1, true)
        and ". The repository may be private: install gh and run `gh auth login`, or set server_jar" or ""
      return cb(("SoCLess: could not download %s: %s%s"):format(u, err, hint))
    end
    M._fetch_gh(version, asset, dest, function(gh_err)
      if not gh_err then return cb(nil, true) end
      cb(("SoCLess: could not download %s: curl failed (%s) and gh failed (%s). The repository %s"
        .. " may be private: run `gh auth login`, or set server_jar"):format(u, err, gh_err, M.REPO))
    end)
  end)
end

---The command that prints the sha256 of `path`: sha256sum, else
---`shasum -a 256` (macOS), else nil.
---@param path string
---@return string[]|nil
function M._hash_cmd(path)
  if vim.fn.executable("sha256sum") == 1 then return { "sha256sum", path } end
  if vim.fn.executable("shasum") == 1 then return { "shasum", "-a", "256", path } end
end

---The sha256 in a hasher's output, lowercase, or nil.
---@param stdout string
---@return string|nil
function M._parse_hash(stdout)
  local hash = stdout:match("^(" .. HEX64 .. ")%s")
  return hash and hash:lower()
end

---Calls `cb(hash)` with the sha256 of the file at `path`, or `cb(nil, err)`.
---Replaced in tests. `cb` runs on the main loop.
---@param path string
---@param cb fun(hash: string|nil, err: string|nil)
function M._sha256(path, cb)
  local cmd = M._hash_cmd(path)
  if not cmd then
    return vim.schedule(function() cb(nil, "neither sha256sum nor shasum is installed") end)
  end
  run(cmd, M._timeout_ms.hash, function(res)
    local hash = res.code == 0 and M._parse_hash(res.stdout or "")
    if hash then return cb(hash) end
    if res.code == 0 then return cb(nil, ("%s printed no sha256: %s"):format(cmd[1], vim.trim(res.stdout or ""))) end
    cb(nil, failure(cmd, res))
  end)
end

---The hash `SHA256SUMS` gives for `name` (text or binary mode, any path prefix).
---@param sums string
---@param name string
---@return string|nil
local function expected_hash(sums, name)
  for line in vim.gsplit(sums, "\n", { plain = true }) do
    local hash, file = line:match("^(" .. HEX64 .. ")%s+%*?(.-)%s*$")
    if hash and vim.fs.basename(file) == name then return hash:lower() end
  end
end

---The jar the server runs from: `server_jar`, or the release's jar under
---`stdpath("data")/socless`.
---@param cfg socless.Config
---@return string
function M.path(cfg)
  if cfg.server_jar then return vim.fs.normalize(cfg.server_jar) end
  return vim.fn.stdpath("data") .. "/socless/" .. jar_name(cfg.version)
end

---@type table<string, fun(path: string|nil, err: string|nil)[]>
local pending = {}

---Downloads the release jar for `cfg.version` to a `.part` file, checks it
---(the pinned version against PINNED_SHA256, another one against the
---release's SHA256SUMS), and only then moves it onto `path`. Calls back every
---waiter with the path or an error.
---@param cfg socless.Config
---@param path string
local function download(cfg, path)
  local pid = vim.fn.getpid()
  local part, sums_part = ("%s.%d.part"):format(path, pid), ("%s.sha256sums.%d.part"):format(path, pid)
  local name = jar_name(cfg.version)
  local sums_url, jar_url = url(cfg.version, "SHA256SUMS"), url(cfg.version, name)
  local used_gh = false

  local function finish(err)
    os.remove(part)
    os.remove(sums_part)
    if not err then
      vim.notify(("SoCLess: server %s ready%s"):format(cfg.version,
        used_gh and " (downloaded with gh, curl failed)" or ""), vim.log.levels.INFO)
    end
    local waiters = pending[path]
    pending[path] = nil
    -- One waiter that throws must not keep the others from their result.
    local errors = {}
    for _, cb in ipairs(waiters) do
      local ok, cb_err
      if err then ok, cb_err = pcall(cb, nil, err) else ok, cb_err = pcall(cb, path) end
      if not ok then table.insert(errors, tostring(cb_err)) end
    end
    if #errors > 0 then
      vim.schedule(function()
        vim.notify("SoCLess: error in a jar callback: " .. table.concat(errors, "; "), vim.log.levels.ERROR)
      end)
    end
  end

  ---Downloads the jar and checks it against `want`.
  local function fetch_jar(want)
    download_asset(cfg.version, name, part, function(jerr, gh)
      if jerr then return finish(jerr) end
      used_gh = used_gh or gh
      M._sha256(part, function(got, herr)
        if not got then return finish(("SoCLess: could not check %s: %s"):format(jar_url, herr)) end
        if got ~= want then
          return finish(("SoCLess: checksum mismatch for %s (expected %s, got %s)"):format(jar_url, want, got))
        end
        -- replaces an older jar in one step: it is never deleted before this
        local ok, rerr = os.rename(part, path)
        finish(not ok and ("SoCLess: could not move the jar into %s: %s"):format(path, rerr) or nil)
      end)
    end)
  end

  local ok, mkdir_err = pcall(vim.fn.mkdir, vim.fs.dirname(path), "p")
  if not ok then
    return finish(("SoCLess: could not create %s: %s"):format(vim.fs.dirname(path), mkdir_err))
  end
  vim.notify(("SoCLess: downloading server %s..."):format(cfg.version), vim.log.levels.INFO)
  if cfg.version == versions.PINNED then return fetch_jar(versions.PINNED_SHA256) end
  download_asset(cfg.version, "SHA256SUMS", sums_part, function(err, gh)
    if err then return finish(err) end
    used_gh = gh
    local f = io.open(sums_part, "rb")
    local sums = f and f:read("*a") or ""
    if f then f:close() end
    local want = expected_hash(sums, name)
    if not want then
      return finish(("SoCLess: %s has no checksum for %s"):format(sums_url, name))
    end
    fetch_jar(want)
  end)
end

---Calls `cb(path)` once the jar is on disk, downloading and checking it first
---when needed, or `cb(nil, err)`. Concurrent calls share one download; a failed
---one leaves nothing behind, so the next call retries. `opts.force` downloads
---again even when the jar is on disk: the jar there is only replaced once
---the new one verified.
---@param cfg socless.Config
---@param cb fun(path: string|nil, err: string|nil)
---@param opts? {force?: boolean}
function M.ensure(cfg, cb, opts)
  local path = M.path(cfg)
  if cfg.server_jar then
    if vim.uv.fs_stat(path) then return cb(path) end
    return cb(nil, ("SoCLess: server_jar not found: %s"):format(path))
  end
  if not (opts and opts.force) and vim.uv.fs_stat(path) then return cb(path) end
  if pending[path] then return table.insert(pending[path], cb) end
  pending[path] = { cb }
  download(cfg, path)
end

return M
