-- Shared connection helpers for the map editor modules.

local Connections = {}

-- Extra connections beyond the primary slot live in `def.connectionsExtra[dir]`
-- (an array, never nil for a non-empty side). Every side in the union therefore
-- has at least one entry: the primary `def.connections[dir]` when present,
-- followed by the `connectionsExtra[dir]` list. The engine only ever reads the
-- primary slot (`Map:connection`, `OverworldState.computeNeighbors`), so extra
-- connections are invisible to gameplay but fully traversable by the editor.
-- Some runtime/patch paths also materialize a whole side as an array of
-- connection objects; flatten that form before the rest of the editor consumes
-- it, otherwise a side with multiple maps degenerates into one nested table.
function Connections.connectionsOn(def, dir)
  local list = {}
  local seen = {}

  -- The engine-readable `connections[dir]` may already hold the full merged
  -- array (primary + extras), so dedupe by reference to avoid double-counting
  -- the extras that also live in `connectionsExtra[dir]`.
  local function add(conn)
    if not conn or seen[conn] then return end
    seen[conn] = true
    -- Gen 2 extractions may carry a numeric `map` field alongside (or instead
    -- of) the string `mapId`.  The data.maps registry is keyed by the string
    -- id, so always prefer `mapId` when present to ensure lookups like
    -- `maps[conn.map]` resolve correctly.  Conversely, mapamap-created
    -- connections set `map` but may lack `mapId`; the Gen 2 runtime checks
    -- `conn.mapId` for traversal, so propagate the other way too.
    if conn.mapId then conn.map = conn.mapId
    elseif conn.map then conn.mapId = conn.map end
    list[#list + 1] = conn
  end

  local v = def and def.connections and def.connections[dir]
  if v then
    if v.map or v.mapId then
      add(v)
    elseif type(v) == "table" then
      for _, conn in ipairs(v) do add(conn) end
    end
  end
  local extra = def and def.connectionsExtra and def.connectionsExtra[dir]
  if extra then
    for _, conn in ipairs(extra) do add(conn) end
  end

  table.sort(list, function(a, b)
    local ao = tonumber(a and a.offset) or 0
    local bo = tonumber(b and b.offset) or 0
    if ao == bo then
      local am = tostring(a and (a.map or a.mapId) or "")
      local bm = tostring(b and (b.map or b.mapId) or "")
      return am < bm
    end
    return ao < bo
  end)

  return list
end

-- Turns a side value into a normal connection list: a single connection object
-- stays as one element, while a merged/array form is flattened in place.
function Connections.connectionList(value)
  if not value then return {} end
  if value.map or value.mapId then
    if value.mapId then value.map = value.mapId
    elseif value.map then value.mapId = value.map end
    return { value }
  end
  if type(value) == "table" then
    local out = {}
    for _, conn in ipairs(value) do
      if conn.mapId then conn.map = conn.mapId
      elseif conn.map then conn.mapId = conn.map end
      out[#out + 1] = conn
    end
    return out
  end
  return {}
end

-- Links `def` to `otherDef` over `dir` with the given block offset and span.
-- The first connection on a side is the primary slot; any further ones become
-- editor-only extras (kept in `connectionsExtra[dir]`).  Crucially,
-- `connections[dir]` is always rebuilt as the full merged array (primary +
-- extras) so the engine -- which only reads `connections[dir]` -- can traverse
-- extra connections and make them walkable at runtime.  The far side is wired
-- reciprocally with a negated offset.
function Connections.addConnection(def, otherDef, dir, offset, span)
  span = span or 0
  local wire = function(from, to, d, off, sp)
    local conn = { map = to.id, mapId = to.id, offset = off }
    if sp and sp > 0 then conn.size = sp end

    if not from.connections then from.connections = {} end
    if not from.connectionsExtra then from.connectionsExtra = {} end

    -- Normalize the side to a clean array of every connection on it (primary
    -- first, then extras).
    local list = from.connections[d]
    if type(list) == "table" and not (list.map or list.mapId) then
      list = list
    elseif type(list) == "table" then
      list = { list }
    else
      list = {}
    end
    table.insert(list, conn)

    -- Engine slot: the full merged array (or the single connection).
    from.connections[d] = (#list == 1) and list[1] or list
    -- Editor-only extras: everything after the primary slot.
    from.connectionsExtra[d] = {}
    for i = 2, #list do from.connectionsExtra[d][i - 1] = list[i] end
    table.sort(from.connectionsExtra[d], function(a, b)
      local ao = a.offset or 0
      local bo = b.offset or 0
      if ao == bo then
        return tostring(a.map or a.mapId or "")
             < tostring(b.map or b.mapId or "")
      end
      return ao < bo
    end)
  end

  local recip = { north = "south", south = "north", west = "east", east = "west" }
  if def and def.id and otherDef and otherDef.id then
    print(string.format("mapamap debug: addConnection %s.%s -> %s @ offset=%s span=%s", tostring(def.id), tostring(dir), tostring(otherDef.id), tostring(offset or 0), tostring(span or 0)))
  end
  wire(def, otherDef, dir, offset, span)
  wire(otherDef, def, recip[dir], -offset, span)
end

-- Merges connectionsExtra into connections so the engine can use extra
-- connections during neighbor computation. Extra connections are stored in
-- connectionsExtra[dir] as an array; this function makes them visible to the
-- engine by merging them with the primary connection in connections[dir].
function Connections.mergeExtraConnections(mod, data)
  if not data or not data.maps then return end
  for mapId, def in pairs(data.maps) do
    if def.connectionsExtra then
      if not def.connections then def.connections = {} end
      for dir, extras in pairs(def.connectionsExtra) do
        if extras and #extras > 0 then
          local merged = {}
          local primary = def.connections[dir]
          if primary then
            for _, conn in ipairs(Connections.connectionList(primary)) do
              merged[#merged + 1] = conn
            end
          end
          for i = 1, #extras do
            merged[#merged + 1] = extras[i]
          end
          table.sort(merged, function(a, b)
            local ao = tonumber(a and a.offset) or 0
            local bo = tonumber(b and b.offset) or 0
            if ao == bo then
              local am = tostring(a and a.map or "")
              local bm = tostring(b and b.map or "")
              return am < bm
            end
            return ao < bo
          end)
          if #merged == 1 then
            def.connections[dir] = merged[1]
          elseif #merged > 1 then
            def.connections[dir] = merged
          end
          local entries = {}
          for _, conn in ipairs(merged) do
            entries[#entries + 1] = string.format("%s@%s", tostring(conn.map), tostring(conn.offset or 0))
          end
          mod.log:info("mapamap debug: merged %d extra connection(s) on %s.%s -> %s",
            #extras, mapId, dir, table.concat(entries, ", "))
          mod.log:info("mapamap: merged %d extra connection(s) on %s.%s",
            #extras, mapId, dir)
        end
      end
    end
  end
end

--Placeholder for runtime forced updatte of connections
function Connections.runtimeUpdate()
end

return Connections
