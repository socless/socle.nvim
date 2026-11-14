local jar = require("socle.jar")
local config = require("socle.config")

local BASE = "https://github.com/socless/socle/releases/download/v0.29.0/"
local JAR_URL = BASE .. "socle-lsp-0.29.0.jar"
local SUMS_URL = BASE .. "SHA256SUMS"
-- A NUL byte, so a hash that stops at the first NUL fails the match.
local CONTENT = "PK\3\4fake\0jar\0bytes"

local HASH = vim.fn.executable("sha256sum") == 1 and { "sha256sum" } or { "shasum", "-a", "256" }
local function sha256(s)
  return vim.split(vim.system(HASH, { stdin = s }):wait().stdout, " ")[1]
end

local versions = require("socle.versions")
local data, real_stdpath, real_fetch, real_fetch_gh, real_executable, real_notify, real_pin
---What `vim.notify` got, as { msg, level }.
local notes
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
  if not exists(data .. "/socle") then return out end
  for name in vim.fs.dir(data .. "/socle") do table.insert(out, name) end
  table.sort(out)
  return out
end

describe("jar", function()
  before_each(function()
    data = vim.fn.tempname()
    vim.fn.mkdir(data, "p")
    real_stdpath, real_fetch, real_fetch_gh = vim.fn.stdpath, jar._fetch, jar._fetch_gh
    real_executable = vim.fn.executable
    real_notify = vim.notify
    notes = {}
    vim.notify = function(msg, level) table.insert(notes, { msg = msg, level = level }) end
    -- Most specs check against SHA256SUMS, which applies to a version the user
    -- set: with this pin, 0.29.0 is such a version. "pinned hash" pins it.
    real_pin = { versions.PINNED, versions.PINNED_SHA256 }
    versions.PINNED = "0.0.0-test"
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
    vim.notify = real_notify
    versions.PINNED, versions.PINNED_SHA256 = real_pin[1], real_pin[2]
    vim.fn.delete(data, "rf")
  end)

  describe("path", function()
    it("gives the pinned path under stdpath('data')", function()
      eq(data .. "/socle/socle-lsp-0.29.0.jar", jar.path(config.merge({})))
      eq(data .. "/socle/socle-lsp-0.16.0.jar", jar.path(config.merge({ version = "0.16.0" })))
    end)

    it("is overridden by server_jar", function()
      eq("/opt/socle/socle-lsp.jar", jar.path(config.merge({ server_jar = "/opt/socle/socle-lsp.jar" })))
    end)
  end)

  describe("ensure", function()
    it("writes the jar after a matching sha256", function()
      local calls = fake({
        [SUMS_URL] = "abc  socle-0.29.0.html\n" .. sha256(CONTENT) .. "  socle-lsp-0.29.0.jar\n",
        [JAR_URL] = CONTENT,
      })
      local res = ensure(config.merge({}))
      eq(nil, res.err)
      eq(data .. "/socle/socle-lsp-0.29.0.jar", res.path)
      eq(CONTENT, vim.fn.readblob(res.path))
      eq({ "socle-lsp-0.29.0.jar" }, listing())
      eq({ SUMS_URL, JAR_URL }, calls)
    end)

    it("accepts a binary-mode line of SHA256SUMS", function()
      fake({ [SUMS_URL] = sha256(CONTENT) .. " *socle-lsp-0.29.0.jar\n", [JAR_URL] = CONTENT })
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
      fake({ [SUMS_URL] = string.rep("0", 64) .. "  socle-lsp-0.29.0.jar\n", [JAR_URL] = CONTENT })
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
      local calls = fake({ [SUMS_URL] = sha256(CONTENT) .. "  socle-lsp-0.29.0.jar\n", [JAR_URL] = CONTENT })
      local got = {}
      jar.ensure(config.merge({}), function(path) table.insert(got, path) end)
      jar.ensure(config.merge({}), function(path) table.insert(got, path) end)
      assert(vim.wait(2000, function() return #got == 2 end), "both callbacks should fire")
      local path = data .. "/socle/socle-lsp-0.29.0.jar"
      eq({ path, path }, got)
      eq({ SUMS_URL, JAR_URL }, calls)
    end)

    it("names the URL on a failed fetch, and the next call retries", function()
      local calls = fake({ [SUMS_URL] = sha256(CONTENT) .. "  socle-lsp-0.29.0.jar\n" })
      local res = ensure(config.merge({}))
      eq(nil, res.path)
      eq(true, res.err:find(JAR_URL, 1, true) ~= nil, res.err)
      eq({}, listing())
      eq(2, #calls)

      fake({ [SUMS_URL] = sha256(CONTENT) .. "  socle-lsp-0.29.0.jar\n", [JAR_URL] = CONTENT })
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
    local SUMS = sha256(CONTENT) .. "  socle-lsp-0.29.0.jar\n"

    it("downloads with gh when curl fails", function()
      tools.gh = 1
      local calls = fake({})
      local gh_calls = fake_gh({ SHA256SUMS = SUMS, ["socle-lsp-0.29.0.jar"] = CONTENT })
      local res = ensure(config.merge({}))
      eq(nil, res.err)
      eq(CONTENT, vim.fn.readblob(res.path))
      eq({ SUMS_URL, JAR_URL }, calls)
      eq({ "0.29.0 SHA256SUMS", "0.29.0 socle-lsp-0.29.0.jar" }, gh_calls)
      eq({ "socle-lsp-0.29.0.jar" }, listing())
    end)

    it("only asks gh for the file curl failed on", function()
      tools.gh = 1
      fake({ [SUMS_URL] = SUMS })
      local gh_calls = fake_gh({ ["socle-lsp-0.29.0.jar"] = CONTENT })
      eq(nil, ensure(config.merge({})).err)
      eq({ "0.29.0 socle-lsp-0.29.0.jar" }, gh_calls)
    end)

    it("says curl and gh both failed and what to do", function()
      tools.gh = 1
      fake({ [SUMS_URL] = SUMS })
      local gh_calls = fake_gh({})
      local res = ensure(config.merge({}))
      eq(nil, res.path)
      for _, want in ipairs({ JAR_URL, "curl", "gh", "gh auth login", "server_jar" }) do
        eq(true, res.err:find(want, 1, true) ~= nil, want .. " in " .. res.err)
      end
      eq(1, #gh_calls)
      eq({}, listing())
    end)

    it("does not try gh when it is not installed", function()
      tools.gh = 0
      fake({})
      local gh_calls = fake_gh({ SHA256SUMS = SUMS, ["socle-lsp-0.29.0.jar"] = CONTENT })
      local res = ensure(config.merge({}))
      eq(nil, res.path)
      eq(true, res.err:find(SUMS_URL, 1, true) ~= nil, res.err)
      eq({}, gh_calls)
    end)

    it("builds the gh command from the repo constant", function()
      eq("socless/socle", jar.REPO)
      eq({ "gh", "release", "download", "v0.29.0", "--repo", "socless/socle", "--pattern",
        "socle-lsp-0.29.0.jar", "--output", "/x/y.part", "--clobber" },
        jar._gh_cmd("0.29.0", "socle-lsp-0.29.0.jar", "/x/y.part"))
    end)
  end)

  describe("checksum tool", function()
    local function good()
      fake({ [SUMS_URL] = sha256(CONTENT) .. "  socle-lsp-0.29.0.jar\n", [JAR_URL] = CONTENT })
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
        fake({ [SUMS_URL] = string.rep("0", 64) .. "  socle-lsp-0.29.0.jar\n", [JAR_URL] = CONTENT })
        local res = ensure(config.merge({}))
        eq(nil, res.err)
        -- one .part per Neovim process, so two instances never share one
        eq(data .. "/socle/socle-lsp-0.29.0.jar." .. vim.fn.getpid() .. ".part", seen)
      end)
      jar._sha256 = real
      assert(ok, err)
    end)
  end)

  describe("robustness", function()
    local SUMS = sha256(CONTENT) .. "  socle-lsp-0.29.0.jar\n"

    it("calls every waiter when one throws, and reports the error", function()
      fake({ [SUMS_URL] = SUMS, [JAR_URL] = CONTENT })
      local function errors()
        return vim.tbl_filter(function(n) return n.level == vim.log.levels.ERROR end, notes)
      end
      local second
      jar.ensure(config.merge({}), function() error("waiter boom") end)
      jar.ensure(config.merge({}), function(path, e) second = { path = path, err = e } end)
      assert(vim.wait(2000, function() return second ~= nil and #errors() > 0 end), "second waiter or notify missing")
      eq(data .. "/socle/socle-lsp-0.29.0.jar", second.path)
      eq(true, errors()[1].msg:find("waiter boom", 1, true) ~= nil, errors()[1].msg)
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
        fake({ [SUMS_URL] = bad .. "  socle-lsp-0.29.0.jar\n", [JAR_URL] = CONTENT })
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

  describe("pinned hash", function()
    before_each(function()
      versions.PINNED, versions.PINNED_SHA256 = "0.29.0", sha256(CONTENT)
    end)

    it("checks the pinned version against PINNED_SHA256, without SHA256SUMS", function()
      local calls = fake({ [JAR_URL] = CONTENT })
      local res = ensure(config.merge({}))
      eq(nil, res.err)
      eq(CONTENT, vim.fn.readblob(res.path))
      eq({ JAR_URL }, calls)
    end)

    it("rejects a pinned jar that does not match PINNED_SHA256, even when SHA256SUMS agrees", function()
      versions.PINNED_SHA256 = string.rep("0", 64)
      fake({ [SUMS_URL] = sha256(CONTENT) .. "  socle-lsp-0.29.0.jar\n", [JAR_URL] = CONTENT })
      local res = ensure(config.merge({}))
      eq(nil, res.path)
      eq(true, res.err:find("checksum mismatch", 1, true) ~= nil, res.err)
      eq({}, listing())
    end)

    it("uses SHA256SUMS for a version the user set", function()
      local base = "https://github.com/socless/socle/releases/download/v0.16.0/"
      local calls = fake({
        [base .. "SHA256SUMS"] = sha256("old") .. "  socle-lsp-0.16.0.jar\n",
        [base .. "socle-lsp-0.16.0.jar"] = "old",
      })
      local res = ensure(config.merge({ version = "0.16.0" }))
      eq(nil, res.err)
      eq({ base .. "SHA256SUMS", base .. "socle-lsp-0.16.0.jar" }, calls)
    end)
  end)

  describe("force (:Socle update)", function()
    local SUMS = sha256(CONTENT) .. "  socle-lsp-0.29.0.jar\n"
    local function forced(cfg)
      local res
      jar.ensure(cfg, function(path, err) res = { path = path, err = err } end, { force = true })
      assert(vim.wait(2000, function() return res ~= nil end), "ensure never called back")
      return res
    end
    local function old_jar()
      local path = jar.path(config.merge({}))
      vim.fn.mkdir(vim.fs.dirname(path), "p")
      local f = assert(io.open(path, "wb"))
      f:write("old jar")
      f:close()
      return path
    end

    it("downloads again over an existing jar", function()
      local path = old_jar()
      fake({ [SUMS_URL] = SUMS, [JAR_URL] = CONTENT })
      local res = forced(config.merge({}))
      eq(nil, res.err)
      eq(CONTENT, vim.fn.readblob(path))
      eq({ "socle-lsp-0.29.0.jar" }, listing())
    end)

    it("keeps the old jar when the download fails", function()
      local path = old_jar()
      fake({ [SUMS_URL] = SUMS })
      local res = forced(config.merge({}))
      eq(nil, res.path)
      eq("old jar", vim.fn.readblob(path))
      eq({ "socle-lsp-0.29.0.jar" }, listing())
    end)

    it("keeps the old jar when the new one does not verify", function()
      local path = old_jar()
      fake({ [SUMS_URL] = string.rep("0", 64) .. "  socle-lsp-0.29.0.jar\n", [JAR_URL] = CONTENT })
      local res = forced(config.merge({}))
      eq(nil, res.path)
      eq("old jar", vim.fn.readblob(path))
    end)
  end)

  describe("notices", function()
    local SUMS = sha256(CONTENT) .. "  socle-lsp-0.29.0.jar\n"
    local function infos()
      return vim.tbl_map(function(n) return n.msg end,
        vim.tbl_filter(function(n) return n.level == vim.log.levels.INFO end, notes))
    end

    it("says when a download starts and when the server is ready", function()
      fake({ [SUMS_URL] = SUMS, [JAR_URL] = CONTENT })
      ensure(config.merge({}))
      eq({ "Socle: downloading server 0.29.0...", "Socle: server 0.29.0 ready" }, infos())
    end)

    it("says nothing for a jar already on disk", function()
      local path = jar.path(config.merge({}))
      vim.fn.mkdir(vim.fs.dirname(path), "p")
      vim.fn.writefile({ "x" }, path)
      ensure(config.merge({}))
      eq({}, notes)
    end)

    it("says once for two concurrent calls", function()
      fake({ [SUMS_URL] = SUMS, [JAR_URL] = CONTENT })
      local got = 0
      jar.ensure(config.merge({}), function() got = got + 1 end)
      jar.ensure(config.merge({}), function() got = got + 1 end)
      assert(vim.wait(2000, function() return got == 2 end))
      eq(2, #infos())
    end)

    it("names gh in the final message only, when curl failed", function()
      tools.gh = 1
      fake({})
      fake_gh({ SHA256SUMS = SUMS, ["socle-lsp-0.29.0.jar"] = CONTENT })
      ensure(config.merge({}))
      local msgs = infos()
      eq(2, #msgs)
      eq("Socle: downloading server 0.29.0...", msgs[1])
      eq(true, msgs[2]:find("ready", 1, true) ~= nil and msgs[2]:find("gh", 1, true) ~= nil, msgs[2])
    end)
  end)

  describe("curl, gh and the hasher", function()
    it("gives curl connect and total time limits, https only, TLS 1.2 or later", function()
      eq({ "curl", "-fsSL", "--connect-timeout", "15", "--max-time", "300", "--proto", "=https", "--tlsv1.2",
        "-o", "/x/y.part", "https://h/f" }, jar._curl_cmd("https://h/f", "/x/y.part"))
    end)

    it("runs curl, gh and the hasher with a time limit", function()
      local seen = {}
      local real_system = vim.system
      vim.system = function(cmd, opts) seen[cmd[1]] = opts.timeout; return {} end
      local ok, err = pcall(function()
        real_fetch("https://h/f", "/x", function() end)
        real_fetch_gh("0.29.0", "a", "/x", function() end)
        jar._sha256("/x", function() end)
      end)
      vim.system = real_system
      assert(ok, err)
      eq(330000, seen.curl) -- a little over --max-time, so curl's own message wins
      eq(300000, seen.gh)
      eq(60000, seen[jar._hash_cmd("/x")[1]])
    end)

    it("reports a command that timed out", function()
      local real_cmd, real_ms = jar._hash_cmd, jar._timeout_ms.hash
      jar._hash_cmd = function() return { "sleep", "5" } end
      jar._timeout_ms.hash = 100
      local got
      jar._sha256("/x", function(hash, e) got = { hash = hash, err = e } end)
      local ok = vim.wait(3000, function() return got ~= nil end)
      jar._hash_cmd, jar._timeout_ms.hash = real_cmd, real_ms
      assert(ok, "no callback")
      eq(nil, got.hash)
      eq("sleep timed out after 0.1 s", got.err)
    end)

    it("hints at gh for a 404 when gh is not installed", function()
      tools.gh = 0
      fake({})
      local res = ensure(config.merge({}))
      for _, want in ipairs({ "404", "Check the version", "install gh", "gh auth login", "server_jar" }) do
        eq(true, res.err:find(want, 1, true) ~= nil, want .. " in " .. res.err)
      end
    end)
  end)
end)
