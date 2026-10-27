-- The real server on SoCLess's example project: View design on GcdSpec.
--
--   SOCLESS_ROOT=<a SoCLess checkout> SOCLESS_JAR=<its socless-lsp jar> \
--     nvim --headless -u NONE -l tests/run.lua integration
--
-- View design runs ./mill in SOCLESS_ROOT (it writes the Mill out/ dir there):
-- point it at a scratch clone, not a checkout you work in. The first run
-- compiles the example, which can take minutes.

local root = vim.fs.normalize(vim.env.SOCLESS_ROOT)
local server_jar = vim.fs.normalize(vim.env.SOCLESS_JAR)
local gcd_spec = root .. "/example/test/src/gcd/GcdSpec.scala"

-- the server's JVM start, then its first parse
local ATTACH_MS = 60000
-- the first view compiles the example with Mill
local VIEW_MS = 900000

---@param ms integer
---@param cond fun(): any
---@param what string
local function wait(ms, cond, what)
  if not vim.wait(ms, cond, 200) then error("timed out waiting for " .. what, 2) end
end

---The socless client attached to `buf`, if any.
local function client_of(buf)
  return vim.lsp.get_clients({ name = "socless", bufnr = buf })[1]
end

---`GET <url>ide.json`, decoded, or nil while the server does not answer.
local function ide_json(url)
  local r = vim.system({ "curl", "-fsS", "--max-time", "5", url .. "ide.json" }, { text = true }):wait()
  if r.code ~= 0 then return nil end
  local ok, json = pcall(vim.json.decode, r.stdout)
  return ok and json or nil
end

-- The specs share one Neovim and one server, and run in order: each one
-- builds on the state the one before left (the client, the buffer), and the
-- last stops the server. Run the file whole, not one spec on its own.
local opened = {}
local buf, c

describe("integration", function()
  it("attaches to GcdSpec.scala and shows the View design lens", function()
    assert(vim.uv.fs_stat(gcd_spec), "no " .. gcd_spec)
    assert(vim.uv.fs_stat(server_jar), "no " .. server_jar)
    vim.cmd("filetype on")
    vim.cmd.runtime("plugin/socless.lua") -- -u NONE loads no plugin: declares :Socless
    require("socless").setup({
      server_jar = server_jar,
      open_panel = function(url) table.insert(opened, url) end,
      schematic_density = "compact", -- reaches the panel through ide.json (0.18.0)
    })
    vim.cmd.edit(vim.fn.fnameescape(gcd_spec))
    buf = vim.api.nvim_get_current_buf()
    eq("scala", vim.bo[buf].filetype)
    wait(ATTACH_MS, function() return client_of(buf) end, "the socless client")
    c = client_of(buf)
    eq(root, c.root_dir)
    wait(ATTACH_MS, function()
      for _, r in ipairs(vim.lsp.codelens.get({ bufnr = buf, client_id = c.id }) or {}) do
        if r.lens.command and r.lens.command.command == "socless.viewDesign" then return true end
      end
    end, "a socless.viewDesign lens")
  end)

  it(":Socless view opens the panel once, and ide.json says ok", function()
    assert(c, "no client (the first spec failed)")
    vim.cmd("Socless view")
    wait(VIEW_MS, function() return opened[1] end, "socless/openPanel")
    local url = opened[1]
    -- the server's page, opened as an editor's panel
    local base = url:match("^(http://127%.0%.0%.1:%d+/)%?panel=1$")
    eq(true, base ~= nil, url)
    local last
    wait(VIEW_MS, function()
      last = ide_json(base)
      if last and last.status == "error" then error("View design failed: " .. tostring(last.message)) end
      return last and last.status == "ok"
    end, "ide.json status ok")
    eq("gcd.GcdSpec", last.suite)
    eq("compact", (last.schematicSettings or {}).density)
    -- later status changes of the same view do not open the browser again
    eq({ url }, opened)
  end)

  it("does not attach to a Scala file with no build.mill above it", function()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    local f = assert(io.open(dir .. "/Lone.scala", "w"))
    f:write("object Lone\n")
    f:close()
    vim.cmd.edit(vim.fn.fnameescape(dir .. "/Lone.scala"))
    local lone = vim.api.nvim_get_current_buf()
    eq("scala", vim.bo[lone].filetype)
    eq(false, vim.wait(2000, function() return client_of(lone) ~= nil end, 100))
  end)

  it("stops the server", function()
    -- a client leaves get_clients once its server process exited
    local function running() return #vim.lsp.get_clients({ name = "socless" }) end
    for _, cl in ipairs(vim.lsp.get_clients({ name = "socless" })) do cl:stop() end
    if not vim.wait(10000, function() return running() == 0 end, 100) then
      for _, cl in ipairs(vim.lsp.get_clients({ name = "socless" })) do cl:stop(true) end
      wait(5000, function() return running() == 0 end, "the server to exit")
    end
  end)
end)
