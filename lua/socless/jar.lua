---The server jar: where it lives, and its download and checksum check.
local M = {}

local RELEASES = "https://github.com/e-ban/SoCless/releases/download"

---@param version string
---@return string
local function jar_name(version) return ("socless-lsp-%s.jar"):format(version) end

---@param version string
---@param asset string
---@return string
local function url(version, asset) return ("%s/v%s/%s"):format(RELEASES, version, asset) end

---Downloads `url` to `dest`, then calls `cb(nil)`, or `cb(err)` on failure.
---Replaced in tests. `cb` runs on the main loop.
---@param url string
---@param dest string
---@param cb fun(err: string|nil)
function M._fetch(url, dest, cb)
  local ok, err = pcall(vim.system, { "curl", "-fsSL", "-o", dest, url }, { text = true },
    vim.schedule_wrap(function(res)
      if res.code == 0 then return cb(nil) end
      cb(vim.trim(res.stderr or "") ~= "" and vim.trim(res.stderr) or ("curl exited " .. res.code))
    end))
  if not ok then vim.schedule(function() cb(tostring(err)) end) end
end

---The sha256 of the file at `path`, or nil and an error. `cb` runs on the main loop.
---@param path string
---@param cb fun(hash: string|nil, err: string|nil)
local function sha256(path, cb)
  local ok, err = pcall(vim.system, { "sha256sum", path }, { text = true },
    vim.schedule_wrap(function(res)
      local hash = res.code == 0 and (res.stdout or ""):match("^(%x+)")
      if hash then return cb(hash:lower()) end
      cb(nil, vim.trim(res.stderr or "") ~= "" and vim.trim(res.stderr) or "sha256sum failed")
    end))
  if not ok then vim.schedule(function() cb(nil, tostring(err)) end) end
end

---The hash `SHA256SUMS` gives for `name` (text or binary mode, any path prefix).
---@param sums string
---@param name string
---@return string|nil
local function expected_hash(sums, name)
  for line in vim.gsplit(sums, "\n", { plain = true }) do
    local hash, file = line:match("^(%x+)%s+%*?(.-)%s*$")
    if hash and vim.fs.basename(file) == name then return hash:lower() end
  end
end

---The jar the server runs from: `server_jar`, or the pinned release's jar
---under `stdpath("data")/socless`.
---@param cfg socless.Config
---@return string
function M.path(cfg)
  if cfg.server_jar then return vim.fs.normalize(cfg.server_jar) end
  return vim.fn.stdpath("data") .. "/socless/" .. jar_name(cfg.version)
end

---@type table<string, fun(path: string|nil, err: string|nil)[]>
local pending = {}

---Downloads the release jar for `cfg.version` and checks it, then calls back
---every waiter with the path or an error.
---@param cfg socless.Config
---@param path string
local function download(cfg, path)
  local part, sums_part = path .. ".part", path .. ".sha256sums.part"
  local sums_url, jar_url = url(cfg.version, "SHA256SUMS"), url(cfg.version, jar_name(cfg.version))

  local function finish(err)
    os.remove(part)
    os.remove(sums_part)
    local waiters = pending[path]
    pending[path] = nil
    for _, cb in ipairs(waiters) do
      if err then cb(nil, err) else cb(path) end
    end
  end

  vim.fn.mkdir(vim.fs.dirname(path), "p")
  M._fetch(sums_url, sums_part, function(err)
    if err then return finish(("SoCLess: could not download %s: %s"):format(sums_url, err)) end
    local f = io.open(sums_part, "rb")
    local sums = f and f:read("*a") or ""
    if f then f:close() end
    local want = expected_hash(sums, jar_name(cfg.version))
    if not want then
      return finish(("SoCLess: %s has no checksum for %s"):format(sums_url, jar_name(cfg.version)))
    end
    M._fetch(jar_url, part, function(jerr)
      if jerr then return finish(("SoCLess: could not download %s: %s"):format(jar_url, jerr)) end
      sha256(part, function(got, herr)
        if not got then return finish(("SoCLess: could not check %s: %s"):format(jar_url, herr)) end
        if got ~= want then
          return finish(("SoCLess: checksum mismatch for %s (expected %s, got %s)"):format(jar_url, want, got))
        end
        local ok, rerr = os.rename(part, path)
        finish(not ok and ("SoCLess: could not move the jar into %s: %s"):format(path, rerr) or nil)
      end)
    end)
  end)
end

---Calls `cb(path)` once the jar is on disk, downloading and checking it first
---when needed, or `cb(nil, err)`. Concurrent calls share one download; a failed
---one leaves nothing behind, so the next call retries.
---@param cfg socless.Config
---@param cb fun(path: string|nil, err: string|nil)
function M.ensure(cfg, cb)
  local path = M.path(cfg)
  if cfg.server_jar then
    if vim.uv.fs_stat(path) then return cb(path) end
    return cb(nil, ("SoCLess: server_jar not found: %s"):format(path))
  end
  if vim.uv.fs_stat(path) then return cb(path) end
  if pending[path] then return table.insert(pending[path], cb) end
  pending[path] = { cb }
  download(cfg, path)
end

---Deletes the downloaded jar (so `ensure` fetches it again). A `server_jar` is
---never deleted.
---@param cfg socless.Config
---@return boolean removed
function M.remove(cfg)
  if cfg.server_jar then return false end
  return os.remove(M.path(cfg)) ~= nil
end

return M
