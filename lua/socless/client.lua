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
---@field phase? "fetching"|"waiting"|"started"
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

---The java to run: `java`, else $JAVA_HOME/bin/java, else "java".
---@param c socless.Config
local function java(c)
  if c.java then return c.java end
  local home = vim.env.JAVA_HOME
  if home and home ~= "" then return home .. "/bin/java" end
  return "java"
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
    cmd = { java(c), "-Djava.net.preferIPv4Stack=true", "-jar", jar_path },
    filetypes = { "scala" },
    root_markers = { "build.mill" },
    -- no build.mill above the file (sbt, a lone file): no client at all
    workspace_required = true,
    init_options = vim.tbl_extend("force", vim.deepcopy(server), { panel = "client" }),
    -- the server reads this section from workspace/didChangeConfiguration
    settings = { socless = server },
    handlers = M.handlers,
  }
end

---Whether `vim.lsp.enable` attaches the buffers already open now: it does so
---only after VimEnter or inside a FileType event.
function M._can_attach()
  return vim.v.vim_did_enter == 1 or vim.fn.did_filetype() == 1
end

---Configures and enables the client, with the options in use now.
local function start()
  state.phase = "started"
  vim.lsp.config("socless", M.lsp_config(cfg, state.jar))
  vim.lsp.enable("socless")
end

---Starts the client the first time a Scala buffer of a Mill project shows
---up: the jar first (perhaps a download), then config and enable, which
---attach the Scala buffers open by then. During startup (a `setup` from
---`-c` or an init file, after the buffer loaded) that waits for VimEnter.
---@param buf integer
function M._on_filetype(buf)
  if state.phase or not cfg then return end
  if not vim.fs.root(buf, { "build.mill" }) then return end
  state.phase = "fetching"
  jar.ensure(cfg, function(path, err)
    if not path then
      state.phase = nil
      return vim.notify(err or "SoCLess: no server jar", vim.log.levels.ERROR)
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
  if not (c and c.name == "socless" and cfg and cfg.codelens) then return end
  vim.lsp.codelens.enable(true, { bufnr = args.buf, client_id = c.id })
end

---The socless client attached to `buf`, if any.
---@param buf integer
function M.get(buf)
  if M._get then return M._get(buf) end
  return vim.lsp.get_clients({ name = "socless", bufnr = buf })[1]
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
---When the client already started and the options `changed`, the new config
---is registered, but a running server keeps the old one until
---`:lsp restart socless`.
---@param c socless.Config
---@param changed? boolean
function M.setup(c, changed)
  cfg = c
  if changed and state.phase == "started" then
    vim.lsp.config("socless", M.lsp_config(cfg, state.jar))
    vim.notify("SoCLess: new options apply after :lsp restart socless", vim.log.levels.INFO)
  end
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
