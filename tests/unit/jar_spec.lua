local jar = require("socless.jar")
local config = require("socless.config")

local BASE = "https://github.com/e-ban/SoCless/releases/download/v0.17.0/"
local JAR_URL = BASE .. "socless-lsp-0.17.0.jar"
local SUMS_URL = BASE .. "SHA256SUMS"
-- A NUL byte, so a hash that stops at the first NUL fails the match.
local CONTENT = "PK\3\4fake\0jar\0bytes"

local HASH = vim.fn.executable("sha256sum") == 1 and { "sha256sum" } or { "shasum", "-a", "256" }
local function sha256(s)
  return vim.split(vim.system(HASH, { stdin = s }):wait().stdout, " ")[1]
end

local data, real_stdpath, real_fetch, real_fetch_gh, real_executable
---Overrides for `vim.fn.executable` (1 or 0); other names are looked up for real.
local tools

---A fake gh fetcher: serves `files[asset]` after a short delay; a missing asset fails.
local function fake_gh(files)
  local calls = {}
  jar._fetch_gh = function(version, asset, dest, cb)
    table.insert(calls, version .. " " .. asset)
    vim.defer_fn(function()
      if files[asset] == nil then
        return cb("release not found")
      end
      local f = assert(io.open(dest, "wb"))
      f:write(files[asset])
      f:close()
      cb(nil)
    end, 20)
  end
  return calls
end

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
    real_stdpath, real_fetch, real_fetch_gh = vim.fn.stdpath, jar._fetch, jar._fetch_gh
    real_executable = vim.fn.executable
    vim.fn.stdpath = function(what)
      if what == "data" then return data end
      return real_stdpath(what)
    end
    -- No gh unless a spec says so, and never the real one.
    tools = { gh = 0 }
    vim.fn.executable = function(name)
      if tools[name] ~= nil then return tools[name] end
      return real_executable(name)
    end
    fake_gh({})
  end)

  after_each(function()
    vim.fn.stdpath, jar._fetch, jar._fetch_gh = real_stdpath, real_fetch, real_fetch_gh
    vim.fn.executable = real_executable
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

  describe("gh fallback", function()
    local SUMS = sha256(CONTENT) .. "  socless-lsp-0.17.0.jar\n"

    it("downloads with gh when curl fails", function()
      tools.gh = 1
      local calls = fake({})
      local gh_calls = fake_gh({ SHA256SUMS = SUMS, ["socless-lsp-0.17.0.jar"] = CONTENT })
      local res = ensure(config.merge({}))
      eq(nil, res.err)
      eq(CONTENT, vim.fn.readblob(res.path))
      eq({ SUMS_URL, JAR_URL }, calls)
      eq({ "0.17.0 SHA256SUMS", "0.17.0 socless-lsp-0.17.0.jar" }, gh_calls)
      eq({ "socless-lsp-0.17.0.jar" }, listing())
    end)

    it("only asks gh for the file curl failed on", function()
      tools.gh = 1
      fake({ [SUMS_URL] = SUMS })
      local gh_calls = fake_gh({ ["socless-lsp-0.17.0.jar"] = CONTENT })
      eq(nil, ensure(config.merge({})).err)
      eq({ "0.17.0 socless-lsp-0.17.0.jar" }, gh_calls)
    end)

    it("says curl and gh both failed and the repo may be private", function()
      tools.gh = 1
      fake({ [SUMS_URL] = SUMS })
      local gh_calls = fake_gh({})
      local res = ensure(config.merge({}))
      eq(nil, res.path)
      for _, want in ipairs({ JAR_URL, "curl", "gh", "private", "gh auth login", "server_jar" }) do
        eq(true, res.err:find(want, 1, true) ~= nil, want .. " in " .. res.err)
      end
      eq(1, #gh_calls)
      eq({}, listing())
    end)

    it("does not try gh when it is not installed", function()
      tools.gh = 0
      fake({})
      local gh_calls = fake_gh({ SHA256SUMS = SUMS, ["socless-lsp-0.17.0.jar"] = CONTENT })
      local res = ensure(config.merge({}))
      eq(nil, res.path)
      eq(true, res.err:find(SUMS_URL, 1, true) ~= nil, res.err)
      eq({}, gh_calls)
    end)

    it("builds the gh command from the repo constant", function()
      eq("e-ban/SoCless", jar.REPO)
      eq({ "gh", "release", "download", "v0.17.0", "--repo", "e-ban/SoCless", "--pattern",
        "socless-lsp-0.17.0.jar", "--output", "/x/y.part", "--clobber" },
        jar._gh_cmd("0.17.0", "socless-lsp-0.17.0.jar", "/x/y.part"))
    end)
  end)

  describe("checksum tool", function()
    local function good()
      fake({ [SUMS_URL] = sha256(CONTENT) .. "  socless-lsp-0.17.0.jar\n", [JAR_URL] = CONTENT })
    end

    it("uses sha256sum when present", function()
      eq({ "sha256sum", "/a.jar" }, jar._hash_cmd("/a.jar"))
    end)

    it("falls back to shasum -a 256", function()
      tools.sha256sum = 0
      eq({ "shasum", "-a", "256", "/a.jar" }, jar._hash_cmd("/a.jar"))
    end)

    it("verifies a real jar with shasum", function()
      if real_executable("shasum") ~= 1 then return io.write("  (skipped: no shasum)\n") end
      tools.sha256sum = 0
      good()
      local res = ensure(config.merge({}))
      eq(nil, res.err)
      eq(CONTENT, vim.fn.readblob(res.path))
    end)

    it("names both tools when neither exists", function()
      tools.sha256sum, tools.shasum = 0, 0
      eq(nil, jar._hash_cmd("/a.jar"))
      good()
      local res = ensure(config.merge({}))
      eq(nil, res.path)
      eq(true, res.err:find("sha256sum", 1, true) ~= nil, res.err)
      eq(true, res.err:find("shasum", 1, true) ~= nil, res.err)
      eq({}, listing())
    end)

    it("uses an injected hasher", function()
      local real = jar._sha256
      local seen
      jar._sha256 = function(path, cb) seen = path; cb(string.rep("0", 64)) end
      local ok, err = pcall(function()
        fake({ [SUMS_URL] = string.rep("0", 64) .. "  socless-lsp-0.17.0.jar\n", [JAR_URL] = CONTENT })
        local res = ensure(config.merge({}))
        eq(nil, res.err)
        eq(data .. "/socless/socless-lsp-0.17.0.jar.part", seen)
      end)
      jar._sha256 = real
      assert(ok, err)
    end)
  end)

  describe("robustness", function()
    local SUMS = sha256(CONTENT) .. "  socless-lsp-0.17.0.jar\n"

    it("calls every waiter when one throws, and reports the error", function()
      fake({ [SUMS_URL] = SUMS, [JAR_URL] = CONTENT })
      local real_notify = vim.notify
      local notes = {}
      vim.notify = function(msg, level) table.insert(notes, { msg = msg, level = level }) end
      local ok, err = pcall(function()
        local second
        jar.ensure(config.merge({}), function() error("waiter boom") end)
        jar.ensure(config.merge({}), function(path, e) second = { path = path, err = e } end)
        assert(vim.wait(2000, function() return second ~= nil and #notes > 0 end), "second waiter or notify missing")
        eq(data .. "/socless/socless-lsp-0.17.0.jar", second.path)
        eq(vim.log.levels.ERROR, notes[1].level)
        eq(true, notes[1].msg:find("waiter boom", 1, true) ~= nil, notes[1].msg)
      end)
      vim.notify = real_notify
      assert(ok, err)
    end)

    it("reports a failing mkdir, and the next call retries", function()
      local calls = fake({ [SUMS_URL] = SUMS, [JAR_URL] = CONTENT })
      local real_mkdir = vim.fn.mkdir
      vim.fn.mkdir = function() error("Vim:E739: Cannot create directory: read-only") end
      local ok, res = pcall(ensure, config.merge({}))
      vim.fn.mkdir = real_mkdir
      assert(ok, res)
      eq(nil, res.path)
      eq(true, res.err:find("E739", 1, true) ~= nil, res.err)
      eq({}, calls)

      res = ensure(config.merge({}))
      eq(nil, res.err)
      eq(CONTENT, vim.fn.readblob(res.path))
    end)

    it("only accepts a SHA256SUMS hash of 64 hex characters", function()
      for _, bad in ipairs({ "abc", string.rep("a", 63), string.rep("a", 65) }) do
        fake({ [SUMS_URL] = bad .. "  socless-lsp-0.17.0.jar\n", [JAR_URL] = CONTENT })
        local res = ensure(config.merge({}))
        eq(nil, res.path)
        eq(true, res.err:find("no checksum", 1, true) ~= nil, res.err)
      end
    end)

    it("rejects a hasher output that is not 64 hex characters", function()
      local real = jar._hash_cmd
      jar._hash_cmd = function() return { "echo", "abc  file" } end
      local got
      jar._sha256("/x", function(hash, err) got = { hash = hash, err = err } end)
      jar._hash_cmd = real
      assert(vim.wait(2000, function() return got ~= nil end))
      eq(nil, got.hash)
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
