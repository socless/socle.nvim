---The pinned server release, and the server version each setting needs.
local M = {}

---The SoCLess server release this plugin is tested against.
M.PINNED = "0.17.0"

---The lowest server version that understands each `settings` option.
---@type table<string, string>
M.min = {
  wave_flag = "0.16.0",
  surfer_command = "0.16.0",
  wave_viewer = "0.17.0",
  wave_viewer_command = "0.17.0",
  waves_follow_selection = "0.17.0",
  waves_show_clock_reset = "0.17.0",
  waves_fold_bundles = "0.17.0",
  waves_show_wires = "0.17.0",
  waves_color_by_direction = "0.17.0",
  waves_follow_delay_ms = "0.17.0",
}

---One warning per set option that the server in use is too old for. A
---`server_jar` (or a version that does not parse) is of unknown version: no
---warning.
---@param cfg socless.Config
---@return string[]
function M.warnings(cfg)
  local out = {}
  local using = not cfg.server_jar and vim.version.parse(cfg.version or "")
  if not using then return out end
  for key in pairs(cfg.settings or {}) do
    local min = M.min[key]
    if min and vim.version.lt(using, min) then
      table.insert(out, ("SoCLess: settings.%s needs server %s or later (this is %s), it may be ignored")
        :format(key, min, cfg.version))
    end
  end
  table.sort(out)
  return out
end

return M
