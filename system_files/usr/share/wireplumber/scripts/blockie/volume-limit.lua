cutils = require ("common-utils")
log = Log.open_topic ("s-blockie-volume")

CARD = "mt6768-mt6358"
FILTER = "blockie.volume-limit"
FILTER_OUT = "blockie.volume-limit.output"
KEY = "blockie.volume-limit"

current = nil
opened = nil
seq = nil
early = nil
cold = nil

metadata = ImplMetadata ("blockie-volume-limit")
metadata:activate (Features.ALL, function (m, e)
  if e then
    log:warning ("blockie-volume-limit metadata: " .. tostring (e))
  end
end)

records = State ("blockie-volume-limit")
record_table = records:load ()

function same (a, b)
  return a ~= nil and b ~= nil and math.abs (a - b) < 0.001
end

function near (a, b)
  return a ~= nil and b ~= nil and math.abs (a - b) <= 0.0005 * math.max (math.abs (a), math.abs (b)) + 1e-6
end

function equal (a, b)
  if not a or not b or #a ~= #b then
    return false
  end
  for i = 1, #a do
    if not near (a [i], b [i]) then
      return false
    end
  end
  return true
end

function clip (v)
  return math.max (0.05, math.min (1.0, v))
end

function setting ()
  return clip (Settings.get_float (KEY))
end

function saved ()
  local j = Settings.get_saved (KEY)
  local v = j and j:parse ()
  return type (v) == "number" and clip (v) or nil
end

function limit_now ()
  return current or saved ()
end

function spacing ()
  local m = cutils.get_object_manager ("metadata"):lookup { Constraint { "metadata.name", "=", "settings" } }
  local q = m and m:find (0, "clock.max-quantum")
  local r = m and m:find (0, "clock.rate")
  local f = m and m:find (0, "clock.force-rate")
  q, r, f = tonumber (q), tonumber (r), tonumber (f)
  if f and f > 0 then
    r = f
  end
  if q and r and r > 0 then
    return math.max (45, math.ceil (1000 * q / r) + 2)
  end
  return 45
end

function nodes ()
  return cutils.get_object_manager ("node")
end

function filter_node ()
  return nodes ():lookup { Constraint { "node.name", "=", FILTER } }
end

function card_node ()
  return nodes ():lookup {
    Constraint { "media.class", "=", "Audio/Sink", type = "pw" },
    Constraint { "api.alsa.card.name", "=", CARD, type = "pw" },
  }
end

function card_device ()
  return cutils.get_object_manager ("device"):lookup { Constraint { "api.alsa.card.name", "=", CARD, type = "pw" } }
end

function find_props (node, test)
  for p in node:iterate_params ("Props") do
    local props = cutils.parseParam (p, "Props")
    if props and test (props) then
      return props
    end
  end
  return nil
end

function has_volumes (props)
  return type (props.channelVolumes) == "table"
end

function has_gain (props)
  return type (props.channelVolumes) == "table" or type (props.volume) == "number"
end

function has_mult (props)
  if type (props.params) ~= "table" then
    return false
  end
  for i = 1, #props.params - 1 do
    if props.params [i] == "gain:Mult" then
      return true
    end
  end
  return false
end

function volumes_of (node)
  local props = node and find_props (node, has_volumes)
  if not props then
    return nil
  end
  local v = {}
  for i, x in ipairs (props.channelVolumes) do
    v [i] = x
  end
  return v
end

function mult_of (node)
  local props = find_props (node, has_mult)
  if not props then
    return nil
  end
  for i = 1, #props.params - 1 do
    if props.params [i] == "gain:Mult" then
      return props.params [i + 1]
    end
  end
  return nil
end

function scaled (volumes, from, to)
  local f = (from / to) ^ 3
  local top = 0
  for _, x in ipairs (volumes) do
    top = math.max (top, x)
  end
  if top * f > 1.0 then
    f = 1.0 / top
  end
  local v = {}
  for i, x in ipairs (volumes) do
    v [i] = x * f
  end
  return v
end

function write_gain (g)
  local f = filter_node ()
  if f then
    f:set_param ("Props", Pod.Object {
      "Spa:Pod:Object:Param:Props", "Props",
      params = Pod.Struct { "gain:Mult", g + 0.0 },
    })
  end
end

function write_volumes (id, v)
  local cv = {}
  for i, x in ipairs (v) do
    cv [tostring (i - 1)] = { volume = x + 0.0 }
  end
  log:debug ("number write on node " .. tostring (id))
  Plugin.find ("mixer-api"):call ("set-volume", id, { channelVolumes = cv })
end

function clamp (node, to)
  local props = find_props (node, has_gain)
  if not props then
    return
  end
  local param, change = { "Spa:Pod:Object:Param:Props", "Props" }, false
  if type (props.volume) == "number" and to (props.volume) ~= props.volume then
    param.volume = to (props.volume)
    change = true
  end
  if type (props.channelVolumes) == "table" then
    local out = { "Spa:Float" }
    for i, x in ipairs (props.channelVolumes) do
      out [i + 1] = to (x)
      change = change or out [i + 1] ~= x
    end
    param.channelVolumes = Pod.Array (out)
  end
  if change then
    node:set_param ("Props", Pod.Object (param))
  end
end

function unity ()
  return 1.0
end

function capped (x)
  return math.min (x, 1.0)
end

function route_of (node)
  local dev_id = node.properties ["device.id"]
  local profile_device = tonumber (node.properties ["card.profile.device"])
  local device = dev_id and cutils.get_object_manager ("device"):lookup {
    Constraint { "bound-id", "=", dev_id, type = "gobject" },
  }
  if not device then
    return nil, nil
  end
  for p in device:iterate_params ("Route") do
    local route = cutils.parseParam (p, "Route")
    if route and route.device == profile_device then
      return device, route
    end
  end
  return device, nil
end

function key_of (device, route)
  return device.properties ["device.name"] .. ":" .. route.direction:lower () .. ":" .. route.name
end

function record (key, limit, volumes)
  local v = {}
  for i, x in ipairs (volumes) do
    v [i] = x
  end
  record_table [key] = Json.Object { limit = limit, channelVolumes = Json.Array (v) }:to_string ()
  records:save_after_timeout (record_table)
end

function read_record (key)
  local value = record_table [key]
  local r = value and Json.Raw (value):parse ()
  if type (r) == "table" and type (r.limit) == "number" and type (r.channelVolumes) == "table" then
    return r
  end
  return nil
end

function seed (device, limit)
  local name = device.properties ["device.name"]
  if not name then
    return
  end
  local prefix = name .. ":output:"
  for key, value in pairs (State ("default-routes"):load ()) do
    if key:sub (1, #prefix) == prefix and not read_record (key) then
      local stored = Json.Raw (value):parse ()
      if type (stored) == "table" and type (stored.channelVolumes) == "table" then
        record (key, limit, stored.channelVolumes)
      end
    end
  end
end

function publish (p)
  metadata:set (0, "applied", "Spa:String", string.format ("%.2f", p))
end

function holds (s)
  local card = card_node ()
  if not card or card ["bound-id"] ~= s.id then
    return nil
  end
  local _, route = route_of (card)
  if (route and route.index) ~= s.route then
    return nil
  end
  return card
end

function reread (s)
  local p = setting ()
  if not same (p, current) then
    log:info (string.format ("the setting reads %.2f after the sequence to %.2f, once more", p, s.to))
    start (p)
  end
end

function finish (s)
  if seq ~= s then
    return
  end
  if s.deadline then
    s.deadline:destroy ()
    s.deadline = nil
  end
  seq = nil
  publish (s.to)
  reread (s)
end

function expire (s)
  s.deadline = nil
  if seq ~= s then
    return
  end
  log:warning (string.format ("the sequence to %.2f ran past 5 s, cleared", s.to))
  local f = filter_node ()
  local m = f and mult_of (f)
  if m and m > current ^ 3 + 1e-6 then
    log:warning (string.format ("the gain reads %.6f above the limit's %.6f, written down", m, current ^ 3))
    write_gain (current ^ 3)
    publish (current)
  elseif m and m >= current ^ 3 - 1e-6 then
    publish (current)
  end
  seq = nil
  reread (s)
end

function begin (s)
  seq = s
  s.deadline = Core.timeout_add (5000, function ()
    expire (s)
  end)
end

function steps (s, after)
  local g0, g1 = s.from ^ 3, s.to ^ 3
  local k = 0
  local function step ()
    if seq ~= s then
      return
    end
    k = k + 1
    local g = g0 * (g1 / g0) ^ (k / 5)
    log:debug (string.format ("gain step %d of 5: %.6f", k, g))
    write_gain (g)
    if k < 5 then
      Core.timeout_add (s.space, step)
    else
      after (s)
    end
  end
  step ()
end

function landed (s)
  if s.wait then
    s.wait:destroy ()
  end
  s.want = nil
  s.wait = nil
  local go = s.next
  s.next = nil
  go ()
end

function await (s, v, go)
  s.want = v
  s.next = go
  s.wait = Core.timeout_add (s.fallback, function ()
    if seq ~= s or not s.want then
      return
    end
    s.wait = nil
    local card = holds (s)
    if not (card and equal (volumes_of (card), v)) then
      log:info ("the number write to " .. tostring (s.id) .. " was not seen, dropped")
    end
    landed (s)
  end)
  write_volumes (s.id, v)
end

function renumber (s)
  if seq ~= s then
    return
  end
  local card = s.id and holds (s)
  if card then
    local now = volumes_of (card)
    if equal (now, s.volumes) then
      local v = scaled (now, s.from, s.to)
      if not equal (v, now) then
        await (s, v, function ()
          finish (s)
        end)
        return
      end
    end
  end
  finish (s)
end

function raise (s)
  local v = s.volumes and scaled (s.volumes, s.from, s.to)
  if not v or equal (v, s.volumes) then
    steps (s, finish)
    return
  end
  await (s, v, function ()
    steps (s, finish)
  end)
end

function lower (s)
  steps (s, function ()
    s.gain = s.to ^ 3
    s.wait = Core.timeout_add (s.fallback, function ()
      if seq ~= s or not s.gain then
        return
      end
      s.gain = nil
      s.wait = nil
      renumber (s)
    end)
  end)
end

function start (p1)
  local s = { from = current, to = p1, space = spacing () }
  s.fallback = math.max (200, 2 * s.space)
  current = p1
  begin (s)
  local card = card_node ()
  if card then
    local _, route = route_of (card)
    s.id = card ["bound-id"]
    s.route = route and route.index
    s.volumes = volumes_of (card)
  end
  local device = card_device ()
  if device then
    seed (device, s.from)
  end
  if s.to > s.from then
    raise (s)
  else
    lower (s)
  end
end

function open_at (p, hint)
  if cold then
    cold:destroy ()
    cold = nil
  end
  local from = hint or saved ()
  local s = { from = from or p, to = p, space = spacing () }
  s.fallback = math.max (200, 2 * s.space)
  current = p
  begin (s)
  local card = card_node ()
  if card and from and not same (from, p) then
    local _, route = route_of (card)
    s.id = card ["bound-id"]
    s.route = route and route.index
    s.volumes = volumes_of (card)
    local v = s.volumes and scaled (s.volumes, from, p)
    if v and not equal (v, s.volumes) then
      log:info (string.format ("cold open at %.2f, the number first from the saved %.2f", p, from))
      await (s, v, function ()
        write_gain (p ^ 3)
        finish (s)
      end)
      return
    end
  end
  log:info (string.format ("cold open at %.2f", p))
  write_gain (p ^ 3)
  finish (s)
end

function open (node)
  local id = node ["bound-id"]
  if opened == id then
    return
  end
  opened = id
  seq = nil
  current = nil
  local m = mult_of (node)
  if m and m > 1e-6 then
    current = clip (m ^ (1 / 3))
    if m > current ^ 3 + 1e-6 then
      write_gain (current ^ 3)
    end
    publish (current)
    metadata:set (0, "ready", "Spa:String", "1")
    log:info (string.format ("the filter is open at %.6f, taken as the limit %.2f", m, current))
    if early then
      early = nil
      changed ("an early push")
    end
    return
  end
  if cold then
    cold:destroy ()
  end
  cold = Core.timeout_add (10000, function ()
    cold = nil
    if opened ~= id or current then
      return
    end
    local v = saved ()
    if v then
      log:info ("no push in 10 s, the filter opens at the saved limit")
      open_at (v)
    else
      log:info ("no push in 10 s and no saved limit, the filter stays silent")
    end
  end)
  metadata:set (0, "ready", "Spa:String", "1")
  if early then
    local hint = early
    early = nil
    changed ("an early push", type (hint) == "number" and hint or nil)
  end
end

function changed (by, hint)
  if not opened then
    if not early then
      early = saved () or true
    end
    log:info (string.format ("change by %s before the open", by))
    return
  end
  local p = setting ()
  log:info (string.format ("change to %.2f by %s, current %s, %s", p, by, tostring (current),
      seq and "a sequence runs" or "idle"))
  if not current then
    open_at (p, hint)
  elseif seq then
    return
  elseif not same (p, current) then
    start (p)
  else
    publish (current)
  end
end

function linked (id)
  local f = filter_node ()
  return f ~= nil and cutils.get_object_manager ("link"):lookup {
    Constraint { "link.output.node", "=", id, type = "pw-global" },
    Constraint { "link.input.node", "=", f ["bound-id"], type = "pw-global" },
  } ~= nil
end

SimpleEventHook {
  name = "blockie/volume-limit-open",
  interests = {
    EventInterest {
      Constraint { "event.type", "=", "node-added" },
      Constraint { "node.name", "=", FILTER },
    },
  },
  execute = function (event)
    open (event:get_subject ())
  end
}:register ()

SimpleEventHook {
  name = "blockie/volume-limit-gone",
  interests = {
    EventInterest {
      Constraint { "event.type", "=", "node-removed" },
      Constraint { "node.name", "=", FILTER },
    },
  },
  execute = function (event)
    opened = nil
    seq = nil
    current = nil
  end
}:register ()

SimpleEventHook {
  name = "blockie/volume-limit-default",
  before = { "default-nodes/find-selected-default-node",
             "default-nodes/find-stored-default-node",
             "default-nodes/find-best-default-node" },
  interests = {
    EventInterest {
      Constraint { "event.type", "=", "select-default-node" },
    },
  },
  execute = function (event)
    local available = event:get_data ("available-nodes")
    available = available and available:parse ()
    if not available then
      return
    end
    local kept = {}
    for _, props in ipairs (available) do
      if props ["node.name"] ~= FILTER then
        table.insert (kept, Json.Object (props))
      end
    end
    if #kept < #available then
      log:info ("the filter is left out of the default node candidates")
    end
    event:set_data ("available-nodes", Json.Array (kept))
  end
}:register ()

SimpleEventHook {
  name = "blockie/volume-limit-props",
  interests = {
    EventInterest {
      Constraint { "event.type", "=", "node-params-changed" },
      Constraint { "event.subject.param-id", "=", "Props" },
    },
  },
  execute = function (event)
    local node = event:get_subject ()
    local name = node.properties ["node.name"]
    local id = node ["bound-id"]
    if name == FILTER or name == FILTER_OUT then
      clamp (node, unity)
    end
    local s = seq
    if s and s.gain and name == FILTER and near (mult_of (node), s.gain) then
      s.wait:destroy ()
      s.gain = nil
      s.wait = nil
      Core.timeout_add (s.space, function ()
        renumber (s)
      end)
    elseif s and s.want and id == s.id and equal (volumes_of (node), s.want) then
      landed (s)
    elseif node.properties ["media.class"] == "Stream/Output/Audio" and linked (id) then
      clamp (node, capped)
    end
  end
}:register ()

SimpleEventHook {
  name = "blockie/volume-limit-link",
  interests = {
    EventInterest {
      Constraint { "event.type", "=", "link-added" },
    },
  },
  execute = function (event)
    local props = event:get_subject ().properties
    local f = filter_node ()
    if not f or tonumber (props ["link.input.node"]) ~= f ["bound-id"] then
      return
    end
    local node = nodes ():lookup {
      Constraint { "bound-id", "=", props ["link.output.node"], type = "gobject" },
      Constraint { "media.class", "=", "Stream/Output/Audio" },
    }
    if node then
      clamp (node, capped)
    end
  end
}:register ()

SimpleEventHook {
  name = "blockie/volume-limit-record",
  interests = {
    EventInterest {
      Constraint { "event.type", "=", "device-params-changed" },
      Constraint { "event.subject.param-id", "=", "Route" },
    },
  },
  execute = function (event)
    local device = event:get_subject ()
    local limit = limit_now ()
    if device.properties ["api.alsa.card.name"] ~= CARD or not limit then
      return
    end
    for p in device:iterate_params ("Route") do
      local route = cutils.parseParam (p, "Route")
      local props = route and route.props and route.props.properties
      if props and route.direction == "Output" and route.available ~= "no" and route.save
          and type (props.channelVolumes) == "table" then
        record (key_of (device, route), limit, props.channelVolumes)
      end
    end
  end
}:register ()

SimpleEventHook {
  name = "blockie/volume-limit-restore",
  after = "device/apply-route-props",
  before = "device/apply-routes",
  interests = {
    EventInterest {
      Constraint { "event.type", "=", "select-routes" },
    },
  },
  execute = function (event)
    local device = event:get_subject ()
    local selected = event:get_data ("selected-routes")
    local limit = limit_now ()
    if device.properties ["api.alsa.card.name"] ~= CARD or not selected or not limit then
      return
    end
    local infos = {}
    for p in device:iterate_params ("EnumRoute") do
      local r = cutils.parseParam (p, "EnumRoute")
      if r then
        infos [r.index] = r
      end
    end
    local out, change = {}, false
    for device_id, value in pairs (selected) do
      out [device_id] = value
      local route = Json.Raw (value):parse ()
      local info = route.index and infos [route.index]
      local props = route.props
      local r = info and info.direction == "Output" and type (props) == "table"
          and type (props.channelVolumes) == "table" and read_record (key_of (device, info))
      if r and not same (r.limit, limit) and equal (r.channelVolumes, props.channelVolumes) then
        props.channelVolumes = Json.Array (scaled (props.channelVolumes, r.limit, limit))
        for _, k in ipairs { "channelMap", "iec958Codecs" } do
          if type (props [k]) == "table" then
            props [k] = Json.Array (props [k])
          end
        end
        out [device_id] = Json.Object { index = route.index, props = Json.Object (props) }:to_string ()
        change = true
      end
    end
    if change then
      event:set_data ("selected-routes", out)
    end
  end
}:register ()

SimpleEventHook {
  name = "blockie/volume-limit-push",
  interests = {
    EventInterest {
      Constraint { "event.type", "=", "metadata-changed" },
      Constraint { "metadata.name", "=", "blockie-volume-limit" },
      Constraint { "event.subject.key", "=", "push" },
    },
  },
  execute = function (event)
    changed ("the nonce")
  end
}:register ()

Settings.subscribe (KEY, function ()
  changed ("the setting")
end)

Core.sync (function ()
  local f = filter_node ()
  if f then
    open (f)
  end
end)
