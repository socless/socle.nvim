---The `socless` LSP client: its config, the server's notifications, code
---lenses and the cursor.
local M = {}

local jar = require("socless.jar")
local config = require("socless.config")

local GROUP = "socless"
-- the start waiting for VimEnter: its own group, so a second `setup` (which
-- clears GROUP) keeps it
local START_GROUP = "socless.start"

---@type socless.Config|nil
local cfg
---@class socless.ClientState
---@field phase? "fetching"|"waiting"|"started"|"failed" "failed": the jar could not be had; only `setup` or `:Socless update` try again
---@field jar? string the server jar, once known
---@field last_url? string the last view's panel url
---@field opened_url? string the url last opened with success
---@field last_ok? string suite and test of the last "design ready"
---@field prev_status? string status, suite and test of the last status
---@field last_cursor? string buffer and line of the last socless/cursor
---@type socless.ClientState
local state

---Forgets everything (for tests).
function M._reset()
  cfg = nil
  state = {}
end
M._reset()

---The java to run: `java` (`~` expanded), else $JAVA_HOME/bin/java, else "java".
---@param c socless.Config
function M.java(c)
  if c.java then return vim.fs.normalize(c.java) end
  local home = vim.env.JAVA_HOME
  if home and home ~= "" then return home .. "/bin/java" end
  return "java"
end

---Whether the java to run exists. When it does not, says so: Neovim itself
---would only log the broken `cmd` and start nothing.
---@return boolean
local function java_found()
  local java = M.java(cfg)
  if vim.fn.executable(java) == 1 then return true end
  vim.notify(("SoCLess: java not found (%s): set `java` or $JAVA_HOME, see :checkhealth socless"):format(java),
    vim.log.levels.ERROR)
  return false
end

---Opens `url` with `open_panel`: nil for `vim.ui.open`, a list (the command,
---the url appended) or a function. Raises when it cannot.
---@param open_panel nil|string[]|fun(url: string)
---@param url string
function M._open_with(open_panel, url)
  if type(open_panel) == "function" then
    open_panel(url)
  elseif type(open_panel) == "table" then
    vim.system(vim.list_extend(vim.deepcopy(open_panel), { url }), { detach = true })
  else
    -- 0.12 returns nil and the error instead of raising
    local _, err = vim.ui.open(url)
    if err then error(err, 0) end
  end
end

---Opens the panel at `url`, unless it is the url opened last (the browser tab
---follows the live design). `force` opens it anyway. A failure is reported,
---and the next view tries again.
---@param url string
---@param force? boolean
function M.open(url, force)
  if not force and url == state.opened_url then return end
  local ok, err = pcall(M._open_with, cfg and cfg.open_panel, url)
  if ok then
    state.opened_url = url
  else
    vim.notify(("SoCLess: cannot open the panel at %s: %s"):format(url, err), vim.log.levels.ERROR)
  end
end

---Opens the last view's panel again, or says there is none.
function M.open_last()
  if not state.last_url then
    return vim.notify("SoCLess: no view yet", vim.log.levels.INFO)
  end
  M.open(state.last_url, true)
end

---Handlers for the server's notifications, given to the client's config.
M.handlers = {
  ---`{url, test}`, sent on every view.
  ["socless/openPanel"] = function(_, params)
    if not (params and params.url) then return end
    state.last_url = params.url
    M.open(params.url, false)
  end,
  ---`{status, suite, test, message}`, status one of idle, running, simulating,
  ---ok, error. Says "design ready" when a test other than the last one shown
  ---ready gets its design (a save's rerun of the same test stays quiet), and
  ---"simulating" when a simulation starts. An error, or an ok with a message
  ---(a simulation's end), is left to the server's own window/showMessage.
  ["socless/status"] = function(_, params)
    if not params then return end
    local test_key = (params.suite or "") .. "\0" .. (params.test or "")
    local key = (params.status or "") .. "\0" .. test_key
    local prev = state.prev_status
    state.prev_status = key
    local text
    if params.status == "ok" and (params.message or "") == "" and test_key ~= state.last_ok then
      state.last_ok = test_key
      text = ("SoCLess: %s: design ready"):format(params.test or "the test")
    elseif params.status == "simulating" and key ~= prev then
      text = ("SoCLess: simulating %s"):format(params.test or "the test")
    end
    if text and cfg and cfg.notify_status then vim.notify(text, vim.log.levels.INFO) end
  end,
}

---The `vim.lsp.config("socless", ...)` table for `c`, running `jar_path`.
---@param c socless.Config
---@param jar_path string
function M.lsp_config(c, jar_path)
  local server = config.to_server(c.settings)
  return {
    cmd = { M.java(c), "-Djava.net.preferIPv4Stack=true", "-jar", jar_path },
    filetypes = { "scala" },
    root_markers = { "build.mill" },
    -- no build.mill above the file (sbt, a lone file): no client at all
    workspace_required = true,
    init_options = vim.tbl_extend("force", vim.deepcopy(server), { panel = "client" }),
    -- the server reads this section from workspace/didChangeConfiguration;
    -- left out when empty (an empty table would go out as a JSON array)
    settings = next(server) and { socless = server } or nil,
    handlers = M.handlers,
  }
end

---Whether `vim.lsp.enable` attaches the buffers already open now: it does so
---only after VimEnter or inside a FileType event.
function M._can_attach()
  return vim.v.vim_did_enter == 1 or vim.fn.did_filetype() == 1
end

---Registers the client config for the options in use now. An assignment
---replaces the config; `vim.lsp.config(name, tbl)` would deep-merge it into
---the old one, keeping a setting that was removed since.
local function register()
  vim.lsp.config.socless = M.lsp_config(cfg, state.jar)
end

---Configures and enables the client, with the options in use now.
local function start()
  state.phase = "started"
  register()
  vim.lsp.enable("socless")
end

---Restarts a started client with the options in use now: the jar for them
---first (perhaps a download), then a new config, and a disable (which stops
---the running servers) and enable, which start a new server for the Scala
---buffers open. While the jar is not there, the running server stays.
---@param msg string notified once restarted
local function restart(msg)
  if not java_found() then return end
  state.phase = "fetching"
  local wanted = jar.path(cfg)
  jar.ensure(cfg, function(path, err)
    state.phase = "started"
    -- a setup during the download asked for another jar: get that one
    if jar.path(cfg) ~= wanted then return restart(msg) end
    if not path then return vim.notify(err or "SoCLess: no server jar", vim.log.levels.ERROR) end
    state.jar = path
    state.last_cursor = nil
    register()
    -- enable(false) stops only initialized clients (get_clients skips the
    -- others), and enable() would then reuse a server still starting: stop
    -- those too. `_uninitialized` is the runtime's own (package) filter, the
    -- only way 0.12 lists a starting client.
    for _, c in ipairs(vim.lsp.get_clients({ name = "socless", _uninitialized = true })) do c:stop() end
    vim.lsp.enable("socless", false)
    vim.lsp.enable("socless")
    -- enable re-attaches the open buffers only after VimEnter or inside a
    -- FileType event (its doautoall); elsewhere, fire its FileType ourselves
    if not M._can_attach() then
      for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].filetype == "scala" then
          pcall(vim.api.nvim_exec_autocmds, "FileType", { group = "nvim.lsp.enable", buffer = buf })
        end
      end
    end
    vim.notify(msg, vim.log.levels.INFO)
  end)
end

---Starts the client the first time a Scala buffer of a Mill project shows
---up: the jar first (perhaps a download), then config and enable, which
---attach the Scala buffers open by then. During startup (a `setup` from
---`-c` or an init file, after the buffer loaded) that waits for VimEnter.
---A missing java is reported each time; a jar that cannot be had only once,
---until `setup` or `:Socless update`.
---@param buf integer
function M._on_filetype(buf)
  if state.phase or not cfg then return end
  if not vim.fs.root(buf, { "build.mill" }) then return end
  if not java_found() then return end
  state.phase = "fetching"
  local wanted = jar.path(cfg)
  jar.ensure(cfg, function(path, err)
    -- a setup during the download asked for another jar: start over
    if jar.path(cfg) ~= wanted then
      state.phase = nil
      return M._on_filetype(buf)
    end
    if not path then
      state.phase = "failed"
      return vim.notify((err or "SoCLess: no server jar") .. ". Run :Socless update to try again",
        vim.log.levels.ERROR)
    end
    state.jar = path
    if M._can_attach() then return start() end
    state.phase = "waiting"
    vim.api.nvim_create_autocmd("VimEnter", {
      group = vim.api.nvim_create_augroup(START_GROUP, { clear = true }),
      once = true,
      callback = start,
    })
  end)
end

---`LspAttach`: lenses for the socless client only, so the lenses of another
---client on the buffer (Metals) stay as they are.
function M._on_attach(args)
  local c = vim.lsp.get_client_by_id(args.data.client_id)
  if not (c and c.name == "socless") then return end
  -- a new server knows no cursor yet
  state.last_cursor = nil
  if not (cfg and cfg.codelens) then return end
  vim.lsp.codelens.enable(true, { bufnr = args.buf, client_id = c.id })
end

---After `:Socless update` put a new jar on disk: restarts a started client
---on it, else starts one for the current buffer when it is a Scala one.
function M.updated()
  if not cfg then return end
  if state.phase == "started" then return restart("SoCLess: restarted on the new server") end
  if state.phase == "fetching" or state.phase == "waiting" then return end
  state.phase = nil
  local buf = vim.api.nvim_get_current_buf()
  if vim.bo[buf].filetype == "scala" then M._on_filetype(buf) end
end

---The socless client attached to `buf`, if any, never one that is stopping
---(a restart's old server).
---@param buf integer
function M.get(buf)
  if M._get then return M._get(buf) end
  for _, c in ipairs(vim.lsp.get_clients({ name = "socless", bufnr = buf })) do
    if not c:is_stopped() then return c end
  end
end

---Sends `socless/cursor {uri, line}` (0-based) for the cursor in `buf`, when
---the buffer or the line changed since the last one sent.
---@param buf integer
function M._send_cursor(buf)
  if not (cfg and cfg.follow_cursor) then return end
  local c = M.get(buf)
  local win = vim.fn.bufwinid(buf)
  if not c or win == -1 then return end
  local line = vim.api.nvim_win_get_cursor(win)[1] - 1
  local key = buf .. ":" .. line
  if key == state.last_cursor then return end
  state.last_cursor = key
  c:notify("socless/cursor", { uri = vim.uri_from_bufnr(buf), line = line })
end

---Installs the autocmds (replacing those of an earlier `setup`) and starts
---for the Scala buffers already open (a plugin loaded on `ft = "scala"`).
---When the client already started and the options `changed`, the server is
---restarted with them. A start waiting for VimEnter starts over (its jar
---may have changed), and a jar that could not be had is tried again.
---@param c socless.Config
---@param changed? boolean
function M.setup(c, changed)
  cfg = c
  if state.phase == "failed" then state.phase = nil end
  if changed and state.phase == "waiting" then
    pcall(vim.api.nvim_del_augroup_by_name, START_GROUP)
    state.phase = nil
  end
  if changed and state.phase == "started" then restart("SoCLess: restarted with the new options") end
  local group = vim.api.nvim_create_augroup(GROUP, { clear = true })
  vim.api.nvim_create_autocmd("FileType", {
    group = group,
    pattern = "scala",
    callback = function(ev) M._on_filetype(ev.buf) end,
  })
  vim.api.nvim_create_autocmd("LspAttach", { group = group, callback = M._on_attach })
  vim.api.nvim_create_autocmd("CursorHold", {
    group = group,
    callback = function(ev)
      if vim.bo[ev.buf].filetype == "scala" then M._send_cursor(ev.buf) end
    end,
  })
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].filetype == "scala" then
      M._on_filetype(buf)
    end
  end
end

---The options in use (nil before `setup`).
---@return socless.Config|nil
function M.config() return cfg end

return M
