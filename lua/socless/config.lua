---Options: the defaults, merging the user's, and the settings sent to the server.
local M = {}

---@class socless.Settings
---@field wave_flag? string
---@field surfer_command? string
---@field wave_viewer? string
---@field wave_viewer_command? string
---@field waves_follow_selection? boolean
---@field waves_show_clock_reset? boolean
---@field waves_fold_bundles? boolean
---@field waves_show_wires? boolean
---@field waves_color_by_direction? boolean
---@field waves_follow_delay_ms? integer

---@class socless.Config
---@field version string server release to download
---@field server_jar? string a local jar: overrides `version` and the download
---@field java? string nil: $JAVA_HOME/bin/java, else "java"
---@field codelens boolean
---@field follow_cursor boolean
---@field open_panel? string[]|fun(url: string) nil: vim.ui.open(url)
---@field notify_status boolean
---@field settings socless.Settings

---@type socless.Config
M.defaults = {
  version = require("socless.versions").PINNED,
  server_jar = nil,
  java = nil,
  codelens = true,
  follow_cursor = true,
  open_panel = nil,
  notify_status = true,
  -- A nil setting is not sent, so the server keeps its own default.
  settings = {},
}

---Each `settings` option and its key in the server's settings object
---(socless-lsp SimSettings.fromObject).
---@type table<string, string>
M.server_keys = {
  wave_flag = "waveFlag",
  surfer_command = "surferCommand",
  wave_viewer = "waveViewer",
  wave_viewer_command = "waveViewerCommand",
  waves_follow_selection = "wavesFollowSelection",
  waves_show_clock_reset = "wavesShowClockReset",
  waves_fold_bundles = "wavesFoldBundles",
  waves_show_wires = "wavesShowWires",
  waves_color_by_direction = "wavesColorByDirection",
  waves_follow_delay_ms = "wavesFollowDelayMs",
}

---The top-level options (the nil ones are absent from `defaults`).
M.options = { "version", "server_jar", "java", "codelens", "follow_cursor", "open_panel", "notify_status", "settings" }

---The defaults with the user's options on top (a fresh table). A setting
---given flat at the top level (`wave_viewer = ...`) goes into `settings`,
---where the same key given under `settings` wins. Any other unknown option
---is left out, with one warning each.
---@param user? table
---@return socless.Config
---@return string[] warnings
function M.merge(user)
  local opts, settings, warnings = {}, {}, {}
  for key, value in pairs(user or {}) do
    if vim.tbl_contains(M.options, key) then
      opts[key] = value
    elseif M.server_keys[key] then
      settings[key] = value
    else
      table.insert(warnings, ("SoCLess: unknown option '%s', ignored"):format(key))
    end
  end
  opts.settings = vim.tbl_extend("force", settings, opts.settings or {})
  table.sort(warnings)
  return vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts), warnings
end

---The server's settings object for `settings`: only the keys that are set, in
---the server's camelCase. Unknown keys are left out, with one warning each
---(the caller decides how to report them).
---@param settings? socless.Settings
---@return table<string, any> out
---@return string[] warnings
function M.to_server(settings)
  local out, warnings = {}, {}
  for key, value in pairs(settings or {}) do
    local server_key = M.server_keys[key]
    if server_key then
      out[server_key] = value
    else
      table.insert(warnings, ("SoCLess: unknown setting '%s', ignored"):format(key))
    end
  end
  table.sort(warnings)
  return out, warnings
end

return M
