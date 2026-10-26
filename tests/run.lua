-- A small dependency-free spec runner.
--
--   nvim --headless -u NONE -l tests/run.lua [pattern]
--
-- Runs every tests/**/*_spec.lua (or those whose path matches the Lua
-- pattern), with `describe`, `it`, `before_each`, `after_each` and `eq` as
-- globals, and exits non-zero when a spec fails.

local root = vim.fs.dirname(vim.fs.dirname(vim.fs.abspath(debug.getinfo(1, "S").source:sub(2))))
vim.opt.runtimepath:prepend(root)
package.path = root .. "/tests/?.lua;" .. package.path

local pattern = _G.arg[1]
local names, hooks = {}, { before = {}, after = {} }
local passed, failed = 0, {}

---@param a any
---@param b any
---@param msg? string
function _G.eq(a, b, msg)
  if not vim.deep_equal(a, b) then
    error(("%sexpected %s, got %s"):format(msg and (msg .. ": ") or "", vim.inspect(a), vim.inspect(b)), 2)
  end
end

---@param name string
---@param fn fun()
function _G.describe(name, fn)
  table.insert(names, name)
  local saved = { before = vim.list_slice(hooks.before), after = vim.list_slice(hooks.after) }
  fn()
  hooks.before, hooks.after = saved.before, saved.after
  table.remove(names)
end

function _G.before_each(fn) table.insert(hooks.before, fn) end
function _G.after_each(fn) table.insert(hooks.after, fn) end

---@param name string
---@param fn fun()
function _G.it(name, fn)
  local full = table.concat(names, " ") .. " " .. name
  local ok, err = true, nil
  for _, h in ipairs(hooks.before) do
    if ok then ok, err = xpcall(h, debug.traceback) end
  end
  if ok then ok, err = xpcall(fn, debug.traceback) end
  for _, h in ipairs(hooks.after) do
    local aok, aerr = xpcall(h, debug.traceback)
    if ok and not aok then ok, err = false, aerr end
  end
  if ok then
    passed = passed + 1
    io.write("PASS ", full, "\n")
  else
    table.insert(failed, full)
    io.write("FAIL ", full, "\n", tostring(err), "\n")
  end
end

local files = vim.fn.globpath(root .. "/tests", "**/*_spec.lua", false, true)
table.sort(files)
for _, file in ipairs(files) do
  if not pattern or file:find(pattern) then
    local ok, err = xpcall(dofile, debug.traceback, file)
    if not ok then
      table.insert(failed, file)
      io.write("ERROR loading ", file, "\n", tostring(err), "\n")
    end
  end
end

io.write(("\n%d passed, %d failed\n"):format(passed, #failed))
os.exit(#failed == 0 and 0 or 1)
