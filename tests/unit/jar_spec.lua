local jar = require("socless.jar")
local config = require("socless.config")

local BASE = "https://github.com/e-ban/SoCless/releases/download/v0.17.0/"
local JAR_URL = BASE .. "socless-lsp-0.17.0.jar"
local SUMS_URL = BASE .. "SHA256SUMS"
-- A NUL byte, so a hash that stops at the first NUL fails the match.
local CONTENT = "PK\3\4fake\0jar\0bytes"

local function sha256(s)
  return vim.split(vim.system({ "sha256sum" }, { stdin = s }):wait().stdout, " ")[1]
end

local data, real_stdpath, real_fetch

---A fake fetcher: serves `files[url]` after a short delay; a missing url fails.
local function fake(files)
  local calls = {}
  jar._fetch = function(url, dest, cb)
    table.insert(calls, url)
    vim.defer_fn(function()
      if files[url] == nil then
        return cb("curl: (22) The requested URL returned error: 404")
      end
      local f = assert(io.open(dest, "wb"))
      f:write(files[url])
      f:close()
      cb(nil)
    end, 20)
  end
  return calls
end

---Runs `jar.ensure` and waits for its callback.
local function ensure(cfg)
  local res
  jar.ensure(cfg, function(path, err) res = { path = path, err = err } end)
  assert(vim.wait(2000, function() return res ~= nil end), "ensure never called back")
  return res
end

local function exists(p) return vim.uv.fs_stat(p) ~= nil end

---The files left in the jar's directory.
local function listing()
  local out = {}
  if not exists(data .. "/socless") then return out end
  for name in vim.fs.dir(data .. "/socless") do table.insert(out, name) end
  table.sort(out)
  return out
end

describe("jar", function()
  before_each(function()
    data = vim.fn.tempname()
    vim.fn.mkdir(data, "p")
    real_stdpath, real_fetch = vim.fn.stdpath, jar._fetch
    vim.fn.stdpath = function(what)
      if what == "data" then return data end
      return real_stdpath(what)
    end
  end)

  after_each(function()
    vim.fn.stdpath, jar._fetch = real_stdpath, real_fetch
    vim.fn.delete(data, "rf")
  end)

  describe("path", function()
    it("gives the pinned path under stdpath('data')", function()
      eq(data .. "/socless/socless-lsp-0.17.0.jar", jar.path(config.merge({})))
      eq(data .. "/socless/socless-lsp-0.16.0.jar", jar.path(config.merge({ version = "0.16.0" })))
    end)

    it("is overridden by server_jar", function()
      eq("/opt/socless/socless-lsp.jar", jar.path(config.merge({ server_jar = "/opt/socless/socless-lsp.jar" })))
    end)
  end)

  describe("ensure", function()
    it("writes the jar after a matching sha256", function()
      local calls = fake({
        [SUMS_URL] = "abc  SoCLess-0.17.0.html\n" .. sha256(CONTENT) .. "  socless-lsp-0.17.0.jar\n",
        [JAR_URL] = CONTENT,
      })
      local res = ensure(config.merge({}))
      eq(nil, res.err)
      eq(data .. "/socless/socless-lsp-0.17.0.jar", res.path)
      eq(CONTENT, vim.fn.readblob(res.path))
      eq({ "socless-lsp-0.17.0.jar" }, listing())
      eq({ SUMS_URL, JAR_URL }, calls)
    end)

    it("accepts a binary-mode line of SHA256SUMS", function()
      fake({ [SUMS_URL] = sha256(CONTENT) .. " *socless-lsp-0.17.0.jar\n", [JAR_URL] = CONTENT })
      eq(nil, ensure(config.merge({})).err)
    end)

    it("uses an existing jar without fetching", function()
      local calls = fake({})
      local path = jar.path(config.merge({}))
      vim.fn.mkdir(vim.fs.dirname(path), "p")
      vim.fn.writefile({ "x" }, path)
      local res = ensure(config.merge({}))
      eq(path, res.path)
      eq({}, calls)
    end)

    it("rejects a mismatch, leaving no .part file and no jar", function()
      fake({ [SUMS_URL] = string.rep("0", 64) .. "  socless-lsp-0.17.0.jar\n", [JAR_URL] = CONTENT })
      local res = ensure(config.merge({}))
      eq(nil, res.path)
      eq(true, res.err:find("checksum", 1, true) ~= nil, res.err)
      eq(true, res.err:find(JAR_URL, 1, true) ~= nil, res.err)
      eq({}, listing())
    end)

    it("rejects a jar SHA256SUMS does not list", function()
      fake({ [SUMS_URL] = "abc  other.jar\n", [JAR_URL] = CONTENT })
      local res = ensure(config.merge({}))
      eq(nil, res.path)
      eq(true, res.err:find(SUMS_URL, 1, true) ~= nil, res.err)
      eq({}, listing())
    end)

    it("makes one fetch for two concurrent calls, and both callbacks fire", function()
      local calls = fake({ [SUMS_URL] = sha256(CONTENT) .. "  socless-lsp-0.17.0.jar\n", [JAR_URL] = CONTENT })
      local got = {}
      jar.ensure(config.merge({}), function(path) table.insert(got, path) end)
      jar.ensure(config.merge({}), function(path) table.insert(got, path) end)
      assert(vim.wait(2000, function() return #got == 2 end), "both callbacks should fire")
      local path = data .. "/socless/socless-lsp-0.17.0.jar"
      eq({ path, path }, got)
      eq({ SUMS_URL, JAR_URL }, calls)
    end)

    it("names the URL on a failed fetch, and the next call retries", function()
      local calls = fake({ [SUMS_URL] = sha256(CONTENT) .. "  socless-lsp-0.17.0.jar\n" })
      local res = ensure(config.merge({}))
      eq(nil, res.path)
      eq(true, res.err:find(JAR_URL, 1, true) ~= nil, res.err)
      eq({}, listing())
      eq(2, #calls)

      fake({ [SUMS_URL] = sha256(CONTENT) .. "  socless-lsp-0.17.0.jar\n", [JAR_URL] = CONTENT })
      res = ensure(config.merge({}))
      eq(nil, res.err)
      eq(CONTENT, vim.fn.readblob(res.path))
    end)

    it("names the SHA256SUMS URL when it cannot be fetched", function()
      local calls = fake({})
      local res = ensure(config.merge({}))
      eq(true, res.err:find(SUMS_URL, 1, true) ~= nil, res.err)
      eq({ SUMS_URL }, calls)
      eq({}, listing())
    end)

    it("uses an existing server_jar and never fetches", function()
      local calls = fake({})
      local p = data .. "/my.jar"
      vim.fn.writefile({ "x" }, p)
      eq(p, ensure(config.merge({ server_jar = p })).path)
      eq({}, calls)
    end)

    it("reports a missing server_jar", function()
      local calls = fake({})
      local res = ensure(config.merge({ server_jar = data .. "/missing.jar" }))
      eq(nil, res.path)
      eq(true, res.err:find(data .. "/missing.jar", 1, true) ~= nil, res.err)
      eq({}, calls)
    end)
  end)

  describe("remove", function()
    it("deletes the pinned jar", function()
      local cfg = config.merge({})
      local path = jar.path(cfg)
      vim.fn.mkdir(vim.fs.dirname(path), "p")
      vim.fn.writefile({ "x" }, path)
      jar.remove(cfg)
      eq(false, exists(path))
    end)

    it("never deletes a server_jar", function()
      local p = data .. "/my.jar"
      vim.fn.writefile({ "x" }, p)
      jar.remove(config.merge({ server_jar = p }))
      eq(true, exists(p))
    end)
  end)
end)
