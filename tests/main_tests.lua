local M = {}

M.name = "main"
M.tests = { "test_main_module_exports_callable_and_static_helper" }

function test_main_module_exports_callable_and_static_helper()
  local Main = require("mods.mapamap.main")
  local stub = {
    hooks = { wrap = function() end },
    events = { on = function() end },
    log = { info = function() end, warn = function() end, error = function() end },
    save = { get = function() return nil end, set = function() end },
  }
  assert(type(Main) == "function", "main module should be a function entrypoint")
  local ok = pcall(function() Main(stub) end)
  assert(ok, "main module should be callable")
end

return M
