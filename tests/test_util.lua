-- TestUtil: shared boilerplate for the mapamap suites.
--
-- test_all.lua accepts suite.tests entries as either strings (resolved
-- against _G, the legacy style) or FUNCTION REFERENCES (preferred for new
-- suites: no global namespace pollution).  Pair the function style with
-- TestUtil.suite{} and the makeMod/session helpers here and a new suite's
-- header shrinks to a few lines.  Requires Data/Session to be loaded by the
-- requiring suite first (they set the Session/Data upvalues used below).

local TestUtil = {}

-- A mod stub whose save is an in-memory table (assertable in tests).
function TestUtil.makeMod()
  return {
    log = { warn = function() end, info = function() end,
            error = function() end },
    save = {
      _store = {},
      get = function(self, k, d)
        return self._store[k] ~= nil and self._store[k] or d
      end,
      set = function(self, k, v) self._store[k] = v end,
    },
    ui = { Font = { draw = function() end } },
  }
end

local Session -- bound by bind(Data, Session)
local Data

-- Wires the session constructor + data registry this suite uses.
function TestUtil.bind(data, sessionCtor)
  Data = data
  Session = sessionCtor
end

-- A session over `mapId` (default PALLET_TOWN) with the placement lists
-- cleared.  Pass `game` (a { data = ... } table) when the suite keeps one,
-- so save-ledger writes land where the suite can see them.
function TestUtil.session(mod, mapId, game)
  mapId = mapId or "PALLET_TOWN"
  game = game or { data = Data }
  local s = assert(Session.new(mod, game, mapId))
  s.def.objects = {}
  s.def.warps = {}
  s.def.signs = {}
  return s
end

-- Suite table builder: name plus an array of named functions.
function TestUtil.suite(name, fns)
  return { name = name, tests = fns }
end

return TestUtil
