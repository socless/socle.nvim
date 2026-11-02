---The pinned server release, and the server version each setting needs.
local M = {}

---The SoCLess server release this plugin is tested against.
M.PINNED = "0.19.0"

---The sha256 of the PINNED release's socless-lsp jar. The pinned jar must
---match it; the release's SHA256SUMS is only used for a `version` the user
---set. Bump it together with PINNED.
M.PINNED_SHA256 = "36fe8f1fad5588e2da8fb38e988d0a300c6917edf4afcd6552be118379b57d57"

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
  schematic_colorize_components = "0.18.0",
  schematic_colorize_wires = "0.18.0",
  schematic_density = "0.18.0",
  schematic_label_size = "0.18.0",
  schematic_auto_optimize = "0.18.0",
  schematic_hint_bar = "0.18.0",
  schematic_show_layers = "0.18.0",
  schematic_hide = "0.18.0",
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
