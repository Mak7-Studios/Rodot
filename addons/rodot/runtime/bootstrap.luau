local bridge = __rodot_bridge
local unpack = table.unpack
local nativeTypeof = typeof
local function rpc(op, args)
    local reply = bridge(op, args or {})
    if reply.error then error(reply.error, 3) end
    return reply.value
end

local clock = 0
local sleepers = {}
local cancelled = setmetatable({}, {__mode = "k"})
local threadScopes = setmetatable({}, {__mode = "k"})
local scriptScopes = {}
local activeScope
local function threadIsLive(thread)
    local scope = threadScopes[thread]
    return not cancelled[thread] and (not scope or scope.alive) and coroutine.status(thread) ~= "dead"
end
local function resumeThread(thread, ...)
    if not threadIsLive(thread) then return end
    local previous = activeScope
    activeScope = threadScopes[thread]
    local ok, message = coroutine.resume(thread, ...)
    activeScope = previous
    if not ok then
        local path, line = "", 0
        for level = 0, 32 do
            local source, currentLine = debug.info(thread, level, "sl")
            if not source then break end
            source = string.gsub(source, "^@", "")
            if string.match(source, "^res://.+%.luau$") and currentLine > 0 then
                path, line = source, currentLine
                break
            end
        end
        rpc("errors", {debug.traceback(thread, tostring(message)), path, line})
    end
end
local function scopedThread(fn, scope)
    local thread = type(fn) == "thread" and fn or coroutine.create(fn)
    threadScopes[thread] = threadScopes[thread] or scope
    return thread
end

task = {}
function task.spawn(fn, ...)
    local thread = scopedThread(fn, activeScope)
    resumeThread(thread, ...)
    return thread
end
function task.defer(fn, ...)
    local thread = scopedThread(fn, activeScope)
    table.insert(sleepers, {thread = thread, at = clock, args = table.pack(...)})
    return thread
end
function task.delay(seconds, fn, ...)
    assert(type(seconds) == "number" and seconds >= 0, "delay must be nonnegative")
    local thread = scopedThread(fn, activeScope)
    table.insert(sleepers, {thread = thread, at = clock + seconds, args = table.pack(...)})
    return thread
end
function task.wait(seconds)
    seconds = seconds or 0
    assert(type(seconds) == "number" and seconds >= 0, "wait must be nonnegative")
    local thread = coroutine.running()
    assert(thread, "task.wait must run in a Rodot task")
    table.insert(sleepers, {thread = thread, at = clock + seconds, start = clock})
    return coroutine.yield()
end
function task.cancel(thread)
    cancelled[thread] = true
end

local Signal = {}
Signal.__index = Signal
function Signal.new(sticky)
    return setmetatable({listeners = {}, sticky = sticky, fired = false}, Signal)
end
function Signal:Connect(fn)
    assert(type(fn) == "function", "Connect expects a function")
    local connection = {Connected = true, fn = fn, scope = activeScope}
    function connection:Disconnect()
        self.Connected = false
        self.fn = nil
        self.scope = nil
    end
    if activeScope then activeScope.connections[connection] = true end
    table.insert(self.listeners, connection)
    return connection
end
function Signal:Once(fn)
    if self.sticky and self.fired then
        local connection = {Connected = false}
        function connection:Disconnect() end
        task.defer(fn)
        return connection
    end
    local connection = self:Connect(fn)
    connection.once = true
    return connection
end
function Signal:Wait()
    local thread = coroutine.running()
    self:Once(function(...) resumeThread(thread, ...) end)
    return coroutine.yield()
end
function Signal:Fire(...)
    self.fired = true
    local active = table.clone(self.listeners)
    for _, connection in active do
        if connection.Connected then
            local fn, scope = connection.fn, connection.scope
            if connection.once then connection:Disconnect() end
            if not scope or scope.alive then resumeThread(scopedThread(fn, scope), ...) end
        end
    end
    local keep = {}
    for _, connection in self.listeners do
        if connection.Connected then table.insert(keep, connection) end
    end
    self.listeners = keep
end

local vectorMethods = {}
local function makeVectorType(name, axes)
    local api, meta = {}, {}
    local function new(...)
        local args = {...}
        local value = {__type = name}
        for index, axis in axes do value[axis] = args[index] or 0 end
        return table.freeze(setmetatable(value, meta))
    end
    local function map(a, b, op)
        local values = {}
        for i, axis in axes do
            values[i] = op(type(a) == "number" and a or a[axis], type(b) == "number" and b or b[axis])
        end
        return new(unpack(values))
    end
    function meta.__index(value, key)
        if key == "Magnitude" then
            local sum = 0
            for _, axis in axes do sum += value[axis] ^ 2 end
            return math.sqrt(sum)
        elseif key == "Unit" then
            local length = value.Magnitude
            return length == 0 and new() or value / length
        end
        return vectorMethods[key]
    end
    meta.__add = function(a, b) return map(a, b, function(x, y) return x + y end) end
    meta.__sub = function(a, b) return map(a, b, function(x, y) return x - y end) end
    meta.__mul = function(a, b) return map(a, b, function(x, y) return x * y end) end
    meta.__div = function(a, b) return map(a, b, function(x, y) return x / y end) end
    meta.__unm = function(a) return a * -1 end
    meta.__eq = function(a, b)
        for _, axis in axes do if a[axis] ~= b[axis] then return false end end
        return true
    end
    meta.__tostring = function(a)
        local values = {}
        for _, axis in axes do table.insert(values, tostring(a[axis])) end
        return table.concat(values, ", ")
    end
    api.new = new
    api.zero = new()
    local ones = {}
    for i in axes do ones[i] = 1 end
    api.one = new(unpack(ones))
    return table.freeze(api)
end
Vector2 = makeVectorType("Vector2", {"X", "Y"})
Vector3 = makeVectorType("Vector3", {"X", "Y", "Z"})
function vectorMethods:Dot(other)
    return self.X * other.X + self.Y * other.Y + (self.Z or 0) * (other.Z or 0)
end
function vectorMethods:Cross(other)
    assert(self.__type == "Vector3" and other.__type == "Vector3", "Cross requires Vector3")
    return Vector3.new(self.Y * other.Z - self.Z * other.Y, self.Z * other.X - self.X * other.Z, self.X * other.Y - self.Y * other.X)
end
function vectorMethods:Lerp(other, alpha) return self + (other - self) * alpha end
function vectorMethods:FuzzyEq(other, epsilon) return (self - other).Magnitude <= (epsilon or 1e-5) end
function vectorMethods:Angle(other, axis)
    local angle = math.acos(math.clamp(self.Unit:Dot(other.Unit), -1, 1))
    if axis and self:Cross(other):Dot(axis) < 0 then return -angle end
    return angle
end
function vectorMethods:Abs()
    if self.Z then return Vector3.new(math.abs(self.X), math.abs(self.Y), math.abs(self.Z)) end
    return Vector2.new(math.abs(self.X), math.abs(self.Y))
end

local colorMethods = {}
local colorMeta = {__index = colorMethods}
Color3 = {}
function Color3.new(r, g, b)
    return table.freeze(setmetatable({__type = "Color3", R = r or 0, G = g or 0, B = b or 0}, colorMeta))
end
function Color3.fromRGB(r, g, b) return Color3.new(r / 255, g / 255, b / 255) end
function Color3.fromHSV(h, s, v)
    local sector = (h % 1) * 6
    local c = v * s
    local x = c * (1 - math.abs(sector % 2 - 1))
    local m = v - c
    local colors = {{c, x, 0}, {x, c, 0}, {0, c, x}, {0, x, c}, {x, 0, c}, {c, 0, x}}
    local a = colors[math.floor(sector) + 1]
    return Color3.new(a[1] + m, a[2] + m, a[3] + m)
end
function Color3.fromHex(hex)
    hex = hex:gsub("^#", "")
    if #hex == 3 then hex = hex:gsub("(.)", "%1%1") end
    assert(#hex == 6 and tonumber(hex, 16), "Invalid hex color")
    return Color3.fromRGB(tonumber(hex:sub(1, 2), 16), tonumber(hex:sub(3, 4), 16), tonumber(hex:sub(5, 6), 16))
end
function colorMethods:Lerp(other, alpha)
    return Color3.new(self.R + (other.R - self.R) * alpha, self.G + (other.G - self.G) * alpha, self.B + (other.B - self.B) * alpha)
end
function colorMethods:ToHex()
    return string.format("%02x%02x%02x", math.round(math.clamp(self.R, 0, 1) * 255), math.round(math.clamp(self.G, 0, 1) * 255), math.round(math.clamp(self.B, 0, 1) * 255))
end
function colorMethods:ToHSV()
    local max, min = math.max(self.R, self.G, self.B), math.min(self.R, self.G, self.B)
    local d, h = max - min, 0
    if d > 0 then
        if max == self.R then h = ((self.G - self.B) / d) % 6
        elseif max == self.G then h = (self.B - self.R) / d + 2
        else h = (self.R - self.G) / d + 4 end
    end
    return h / 6, max == 0 and 0 or d / max, max
end
colorMeta.__eq = function(a, b) return a.R == b.R and a.G == b.G and a.B == b.B end
colorMeta.__tostring = function(a) return string.format("%g, %g, %g", a.R, a.G, a.B) end

local cfMethods, cfMeta = {}, {}
CFrame = {}
local function cf(position, right, up, back)
    return table.freeze(setmetatable({__type = "CFrame", p = position, r = right, u = up, b = back}, cfMeta))
end
function CFrame.new(...)
    local a = {...}
    if #a == 12 then
        return cf(Vector3.new(a[1], a[2], a[3]), Vector3.new(a[4], a[7], a[10]), Vector3.new(a[5], a[8], a[11]), Vector3.new(a[6], a[9], a[12]))
    end
    if type(a[1]) == "table" then
        if a[2] then return CFrame.lookAt(a[1], a[2]) end
        return cf(a[1], Vector3.new(1, 0, 0), Vector3.new(0, 1, 0), Vector3.new(0, 0, 1))
    end
    return CFrame.new(Vector3.new(a[1], a[2], a[3]))
end
function CFrame.fromMatrix(position, right, up, back) return cf(position, right, up, back or right:Cross(up)) end
function CFrame.lookAt(position, target, up)
    assert((position - target).Magnitude > 0, "lookAt points must differ")
    local back = (position - target).Unit
    local reference = up or Vector3.new(0, 1, 0)
    if math.abs(reference.Unit:Dot(back)) > 0.9999 then reference = Vector3.new(1, 0, 0) end
    local right = reference:Cross(back).Unit
    return cf(position, right, back:Cross(right), back)
end
function CFrame.Angles(x, y, z)
    local sx, cx, sy, cy, sz, cz = math.sin(x), math.cos(x), math.sin(y), math.cos(y), math.sin(z), math.cos(z)
    return CFrame.new(0, 0, 0, cy * cz, -cy * sz, sy, cx * sz + sx * sy * cz, cx * cz - sx * sy * sz, -sx * cy, sx * sz - cx * sy * cz, sx * cz + cx * sy * sz, cx * cy)
end
CFrame.fromEulerAnglesXYZ = CFrame.Angles
function cfMeta.__index(a, key)
    local properties = {Position = a.p, X = a.p.X, Y = a.p.Y, Z = a.p.Z, RightVector = a.r, UpVector = a.u, LookVector = -a.b, Rotation = cf(Vector3.zero, a.r, a.u, a.b)}
    return properties[key] or cfMethods[key]
end
function cfMethods:VectorToWorldSpace(v) return self.r * v.X + self.u * v.Y + self.b * v.Z end
function cfMethods:PointToWorldSpace(v) return self.p + self:VectorToWorldSpace(v) end
function cfMethods:VectorToObjectSpace(v) return Vector3.new(v:Dot(self.r), v:Dot(self.u), v:Dot(self.b)) end
function cfMethods:PointToObjectSpace(v) return self:VectorToObjectSpace(v - self.p) end
function cfMethods:Inverse()
    local right = Vector3.new(self.r.X, self.u.X, self.b.X)
    local up = Vector3.new(self.r.Y, self.u.Y, self.b.Y)
    local back = Vector3.new(self.r.Z, self.u.Z, self.b.Z)
    return cf(-self:VectorToObjectSpace(self.p), right, up, back)
end
function cfMethods:ToWorldSpace(other) return self * other end
function cfMethods:ToObjectSpace(other) return self:Inverse() * other end
function cfMethods:GetComponents()
    return self.p.X, self.p.Y, self.p.Z, self.r.X, self.u.X, self.b.X, self.r.Y, self.u.Y, self.b.Y, self.r.Z, self.u.Z, self.b.Z
end
function cfMethods:Lerp(other, alpha)
    local value = rpc("cframe_lerp", {{__type = "CFrame", components = {self:GetComponents()}}, {__type = "CFrame", components = {other:GetComponents()}}, alpha})
    return CFrame.new(unpack(value.components))
end
function CFrame.fromAxisAngle(axis, angle)
    axis = axis.Unit
    local x, y, z, c, s = axis.X, axis.Y, axis.Z, math.cos(angle), math.sin(angle)
    local t = 1 - c
    return CFrame.new(0, 0, 0, t*x*x+c, t*x*y-s*z, t*x*z+s*y, t*x*y+s*z, t*y*y+c, t*y*z-s*x, t*x*z-s*y, t*y*z+s*x, t*z*z+c)
end
cfMeta.__mul = function(a, b)
    if b.__type == "Vector3" then return a:PointToWorldSpace(b) end
    assert(b.__type == "CFrame", "CFrame can multiply CFrame or Vector3")
    return cf(a:PointToWorldSpace(b.p), a:VectorToWorldSpace(b.r), a:VectorToWorldSpace(b.u), a:VectorToWorldSpace(b.b))
end
cfMeta.__add = function(a, b) return cf(a.p + b, a.r, a.u, a.b) end
cfMeta.__sub = function(a, b) return cf(a.p - b, a.r, a.u, a.b) end
cfMeta.__eq = function(a, b) return a.p == b.p and a.r == b.r and a.u == b.u and a.b == b.b end
CFrame.identity = CFrame.new()

local function recordType(name, fields, defaults)
    local api = {}
    function api.new(...)
        local args, result = {...}, {__type = name}
        for i, field in fields do
            result[field] = if args[i] ~= nil then args[i] else defaults and defaults[i]
        end
        return table.freeze(result)
    end
    return api
end
UDim = recordType("UDim", {"Scale", "Offset"}, {0, 0})
UDim2 = recordType("UDim2", {"X", "Y"})
function UDim2.new(xs, xo, ys, yo) return table.freeze({__type = "UDim2", X = UDim.new(xs, xo), Y = UDim.new(ys, yo)}) end
function UDim2.fromScale(x, y) return UDim2.new(x, 0, y, 0) end
function UDim2.fromOffset(x, y) return UDim2.new(0, x, 0, y) end
NumberRange = {}
local function integerVector(name, axes)
    return {new = function(...)
        local args, result = {...}, {__type = name}
        for i, axis in axes do result[axis] = (math.floor(args[i] or 0) + 32768) % 65536 - 32768 end
        return table.freeze(result)
    end}
end
Vector2int16 = integerVector("Vector2int16", {"X", "Y"})
Vector3int16 = integerVector("Vector3int16", {"X", "Y", "Z"})
Region3 = {}
function Region3.new(min, max)
    assert(min.X <= max.X and min.Y <= max.Y and min.Z <= max.Z, "Region3 bounds are reversed")
    local result = {__type = "Region3", CFrame = CFrame.new((min + max) / 2), Size = max - min}
    function result:ExpandToGrid(resolution)
        assert(resolution > 0, "Grid resolution must be positive")
        local low, high = self.CFrame.Position - self.Size / 2, self.CFrame.Position + self.Size / 2
        return Region3.new(Vector3.new(math.floor(low.X / resolution), math.floor(low.Y / resolution), math.floor(low.Z / resolution)) * resolution, Vector3.new(math.ceil(high.X / resolution), math.ceil(high.Y / resolution), math.ceil(high.Z / resolution)) * resolution)
    end
    return table.freeze(result)
end
function NumberRange.new(min, max)
    max = max or min
    assert(type(min) == "number" and min <= max, "Invalid NumberRange")
    return table.freeze({__type = "NumberRange", Min = min, Max = max})
end
NumberSequenceKeypoint = recordType("NumberSequenceKeypoint", {"Time", "Value", "Envelope"}, {0, 0, 0})
ColorSequenceKeypoint = recordType("ColorSequenceKeypoint", {"Time", "Value"})
local function sequence(name, keypoint, default)
    return {new = function(a, b)
        local points = type(a) == "table" and not a.__type and table.clone(a) or {keypoint.new(0, a or default), keypoint.new(1, b or a or default)}
        assert(#points >= 2 and points[1].Time == 0 and points[#points].Time == 1, "Sequence must span 0 to 1")
        for i = 2, #points do assert(points[i].Time >= points[i - 1].Time, "Sequence times must be sorted") end
        return table.freeze({__type = name, Keypoints = table.freeze(points)})
    end}
end
NumberSequence = sequence("NumberSequence", NumberSequenceKeypoint, 0)
ColorSequence = sequence("ColorSequence", ColorSequenceKeypoint, Color3.new())
PhysicalProperties = recordType("PhysicalProperties", {"Density", "Friction", "Elasticity", "FrictionWeight", "ElasticityWeight"}, {1, 0.3, 0.5, 1, 1})
Rect = {}
function Rect.new(a, b, c, d)
    local min, max = a, b
    if type(a) == "number" then min, max = Vector2.new(a, b), Vector2.new(c, d) end
    return table.freeze({__type = "Rect", Min = min, Max = max, Width = max.X - min.X, Height = max.Y - min.Y})
end
local rayMethods = {}
Ray = {}
function Ray.new(origin, direction) return table.freeze(setmetatable({__type = "Ray", Origin = origin, Direction = direction}, {__index = rayMethods})) end
function rayMethods:ClosestPoint(point)
    local t = math.max(0, (point - self.Origin):Dot(self.Direction.Unit))
    return self.Origin + self.Direction.Unit * t
end
function rayMethods:Distance(point) return (point - self:ClosestPoint(point)).Magnitude end
Random = {}
function Random.new(seed)
    local state = math.floor(seed or os.clock() * 1000000) % 2147483647
    if state <= 0 then state = 1 end
    local object = {__type = "Random"}
    function object:NextNumber(min, max)
        state = (state * 16807) % 2147483647
        min, max = min or 0, max or 1
        return min + (max - min) * ((state - 1) / 2147483646)
    end
    function object:NextInteger(min, max)
        assert(min <= max and min % 1 == 0 and max % 1 == 0, "Invalid integer range")
        return math.min(max, math.floor(self:NextNumber(min, max + 1)))
    end
    function object:NextUnitVector()
        local z, angle = self:NextNumber(-1, 1), self:NextNumber(0, math.pi * 2)
        local radius = math.sqrt(1 - z * z)
        return Vector3.new(radius * math.cos(angle), radius * math.sin(angle), z)
    end
    return object
end

Enum = {}
for name, entries in __rodot_enums do
    local enum = {__type = "Enum", Name = name}
    local items = {}
    for key, value in entries do
        local item = table.freeze(setmetatable({__type = "EnumItem", Name = key, Value = value, EnumType = enum}, {__tostring = function() return "Enum." .. name .. "." .. key end}))
        enum[key] = item
        table.insert(items, item)
    end
    table.sort(items, function(a, b) return a.Value < b.Value end)
    function enum:GetEnumItems() return table.clone(items) end
    Enum[name] = table.freeze(enum)
end
Enum = table.freeze(Enum)

Path = {}
local pathMeta = {__tostring = function(value) return value.Value end}
function Path.new(value)
    assert(type(value) == "string" and #value > 0, "Path.new expects a nonempty string")
    return table.freeze(setmetatable({__type = "Path", Value = value}, pathMeta))
end

RaycastParams = {}
local raycastParamsMethods = {}
function raycastParamsMethods:AddToFilter(value)
    if typeof(value) == "Instance" then table.insert(self.FilterDescendantsInstances, value)
    else
        for _, instance in value do table.insert(self.FilterDescendantsInstances, instance) end
    end
end
function RaycastParams.new()
    return setmetatable({__type = "RaycastParams", FilterType = Enum.RaycastFilterType.Exclude, FilterDescendantsInstances = {}, ExcludeInstances = {}, CollisionGroup = "Default", IgnoreWater = false, RespectCanCollide = false, IncludeAreas = false}, {__index = raycastParamsMethods})
end

local cache = setmetatable({}, {__mode = "v"})
local instanceMethods, instanceMeta = {}, {}
local signals = {}
local decode
local function wrap(id)
    if cache[id] then return cache[id] end
    local proxy = table.freeze(setmetatable({__type = "Instance", id = id}, instanceMeta))
    cache[id] = proxy
    return proxy
end
local function encode(value)
    if type(value) ~= "table" then return value end
    if value.__type == "Instance" then return {__type = "Instance", id = value.id} end
    if value.__type == "CFrame" then return {__type = "CFrame", components = {value:GetComponents()}} end
    if value.__type == "EnumItem" then return value.Value end
    local copy = {}
    for key, item in value do copy[key] = encode(item) end
    return copy
end
decode = function(value)
    if type(value) ~= "table" then return value end
    local kind = value.__type
    if kind == "Instance" then return wrap(value.id) end
    if kind == "Path" then return Path.new(value.Value) end
    if kind == "EnumItem" then return Enum[value.EnumType][value.Name] end
    if kind == "Vector3" then return Vector3.new(value.X, value.Y, value.Z) end
    if kind == "Vector2" then return Vector2.new(value.X, value.Y) end
    if kind == "Color3" then return Color3.new(value.R, value.G, value.B) end
    if kind == "CFrame" then return CFrame.new(unpack(value.components)) end
    local copy = {}
    for key, item in value do copy[key] = decode(item) end
    return if kind == "RaycastResult" then table.freeze(copy) else copy
end
local function encodeArguments(...)
    local values = table.pack(...)
    local result = table.create(values.n)
    for i = 1, values.n do result[i] = if values[i] == nil then {__type = "GodotNil"} else encode(values[i]) end
    return result
end
local function validateSaveValue(value, depth)
    assert(depth <= 32, "Save data is too deeply nested or contains a cycle")
    local kind = type(value)
    if kind == "number" then
        assert(value == value and math.abs(value) < math.huge, "Save numbers must be finite")
    elseif kind == "table" then
        assert(value.__type ~= "Instance", "Save an instance's data instead of its live reference")
        if value.__type == "EnumItem" then
            validateSaveValue(value.Value, depth + 1)
        else
            for _, item in value do validateSaveValue(item, depth + 1) end
        end
    else
        assert(kind == "string" or kind == "boolean", "Save data must contain numbers, strings, booleans, or tables")
    end
end
local function encodeSave(value)
    validateSaveValue(value, 0)
    return encode(value)
end
local function getSignal(id, name, native)
    local token = tostring(id) .. ":" .. name
    if not signals[token] then
        if native then rpc("subscribe", {id, name}) end
        signals[token] = Signal.new()
    end
    return signals[token]
end
local signalNames = {Touched = true, MouseButton1Click = true}
local classMethods = {
    ParticleEmitter = {Emit = "emit", Clear = "clear"},
    Part = {ApplyImpulse = "apply_central_impulse", ApplyAngularImpulse = "apply_torque_impulse", ApplyImpulseAtPosition = "apply_impulse_at_position", GetMass = "get_mass_value", GetPivot = "get_pivot", PivotTo = "pivot_to"}
}
local classMethodNames = {}
for _, methods in classMethods do
    for name in methods do classMethodNames[name] = true end
end
function instanceMeta.__index(self, key)
    if instanceMethods[key] then return instanceMethods[key] end
    if key == "Raycast" and self == workspace then
        return function(receiver, origin, direction, params)
            return decode(rpc("raycast", {receiver.id, encode(origin), encode(direction), encode(params)}))
        end
    end
    if classMethodNames[key] then
        local methods = classMethods[rpc("get", {self.id, "ClassName"})]
        local method = methods and methods[key]
        if method then return function(receiver, ...) return receiver:Call(method, ...) end end
    end
    if key == "Changed" or key == "ChildAdded" or key == "ChildRemoved" then return getSignal(self.id, key, false) end
    if signalNames[key] then return getSignal(self.id, key, true) end
    local value = rpc("get", {self.id, key})
    if type(value) == "table" then
        if value.__type == "GodotMethod" then return function(receiver, ...) return receiver:Call(value.Name, ...) end end
        if value.__type == "GodotSignal" then return getSignal(self.id, value.Name, true) end
    end
    return decode(value)
end
function instanceMeta.__newindex(self, key, value) rpc("set", {self.id, key, encode(value)}) end
function instanceMeta.__tostring(self) return self.Name end
function instanceMethods:GetChildren() return decode(rpc("children", {self.id})) end
function instanceMethods:GetDescendants() return decode(rpc("descendants", {self.id})) end
function instanceMethods:FindFirstChild(name, recursive) return decode(rpc("find", {self.id, name, recursive or false})) end
function instanceMethods:WaitForChild(name, timeout)
    local start = clock
    repeat
        local child = self:FindFirstChild(name)
        if child then return child end
        if timeout and clock - start >= timeout then return nil end
        task.wait()
    until false
end
function instanceMethods:FindFirstChildOfClass(class)
    for _, child in self:GetChildren() do if child.ClassName == class then return child end end
    return nil
end
function instanceMethods:FindFirstAncestor(name)
    local parent = self.Parent
    while parent do
        if parent.Name == name then return parent end
        parent = parent.Parent
    end
    return nil
end
function instanceMethods:IsA(class) return rpc("isa", {self.id, class}) end
function instanceMethods:IsDescendantOf(parent)
    local current = self.Parent
    while current do
        if current == parent then return true end
        current = current.Parent
    end
    return false
end
function instanceMethods:GetFullName() return rpc("fullname", {self.id}) end
function instanceMethods:Destroy()
    rpc("destroy", {self.id})
    for token, signal in signals do
        if token:sub(1, #tostring(self.id) + 1) == tostring(self.id) .. ":" then
            for _, connection in signal.listeners do connection:Disconnect() end
            signals[token] = nil
        end
    end
end
function instanceMethods:Clone() return decode(rpc("clone", {self.id})) end
function instanceMethods:ClearAllChildren() for _, child in self:GetChildren() do child:Destroy() end end
function instanceMethods:GetAttribute(name) return decode(rpc("attribute_get", {self.id, name})) end
function instanceMethods:GetAttributes() return decode(rpc("attributes", {self.id})) end
function instanceMethods:SetAttribute(name, value) rpc("attribute_set", {self.id, name, encode(value)}) end
function instanceMethods:GetAttributeChangedSignal(name) return getSignal(self.id, "attribute:" .. name, false) end
function instanceMethods:AddTag(tag) rpc("tag_add", {self.id, tag}) end
function instanceMethods:RemoveTag(tag) rpc("tag_remove", {self.id, tag}) end
function instanceMethods:HasTag(tag) return rpc("tag_has", {self.id, tag}) end
function instanceMethods:GetTags() return decode(rpc("tags", {self.id})) end
function instanceMethods:GetPropertyChangedSignal(name) return getSignal(self.id, "property:" .. name, false) end
function instanceMethods:GetSignal(name) return getSignal(self.id, name, true) end
function instanceMethods:Call(method, ...) return decode(rpc("call", {self.id, method, encodeArguments(...)})) end
Instance = {}
function Instance.new(class, parent)
    local value = decode(rpc("create", {class}))
    if parent then value.Parent = parent end
    return value
end

Godot = {Ready = Signal.new(true), Process = Signal.new(), PhysicsProcess = Signal.new(), SceneChanged = getSignal(0, "scene:changed", false)}
function Godot.Instantiate(path, parent, ...)
    if path == Godot then path, parent = parent, ... end
    assert(type(path) == "string" or typeof(path) == "Path", "Instantiate expects a project scene path")
    return decode(rpc("instantiate_scene", {encode(path), encode(parent)}))
end
function Godot.ChangeScene(path, ...)
    if path == Godot then path = ... end
    assert(type(path) == "string" or typeof(path) == "Path", "ChangeScene expects a project scene path")
    return rpc("change_scene", {encode(path)})
end
function Godot.ReloadScene() return rpc("reload_scene") end
local LocalSave = {}
function LocalSave:Write(slot, value) return rpc("local_save", {"write", slot, encodeSave(value)}) end
function LocalSave:Read(slot)
    local entry = rpc("local_save", {"read", slot})
    return if entry then decode(entry.data) else nil
end
function LocalSave:Has(slot) return rpc("local_save", {"has", slot}) end
Godot.Save = LocalSave

local DataStoreService = {}
local DataStore = {}
local dataStoreMeta = {__index = DataStore}
local dataStores = setmetatable({}, {__mode = "v"})
local remoteStoreThreads = {}
local updateTransforms = setmetatable({}, {__mode = "k"})
function DataStoreService:GetDataStore(name, scope, backend)
    if type(scope) == "table" and scope.EnumType == Enum.DataStoreType and backend == nil then
        backend, scope = scope, nil
    end
    if scope == nil then scope = "global" end
    if type(backend) == "table" and backend.EnumType == nil then backend = backend.Backend end
    if backend == nil then
        local value = rpc("data_store", {"default"})
        for _, item in Enum.DataStoreType:GetEnumItems() do
            if item.Value == value then backend = item break end
        end
    end
    assert(type(backend) == "table" and backend.EnumType == Enum.DataStoreType, "Expected Enum.DataStoreType")
    assert(type(name) == "string" and type(scope) == "string", "Expected a DataStore name and scope")
    rpc("data_store", {"validate", backend.Value, name, scope})
    local id = tostring(backend.Value) .. ":" .. tostring(#name) .. ":" .. name .. scope
    if not dataStores[id] then
        dataStores[id] = table.freeze(setmetatable({__type = "DataStore", Name = name, Scope = scope, Type = backend}, dataStoreMeta))
    end
    return dataStores[id]
end
local function dataStoreCall(store, operation, key, ...)
    assert(type(key) == "string", "DataStore keys must be strings")
    local args = {operation, store.Type.Value, store.Name, store.Scope, key, ...}
    if store.Type == Enum.DataStoreType.Local then return rpc("data_store", args) end
    local thread = coroutine.running()
    assert(coroutine.isyieldable() and not updateTransforms[thread], "Remote DataStore calls require a yielding Rodot task outside UpdateAsync transforms")
    local request = rpc("data_store", args)
    remoteStoreThreads[request] = thread
    local reply = coroutine.yield()
    if reply.error then error(reply.error, 3) end
    return reply.value
end
local function recordValue(record)
    return if record then decode(record.data) else nil
end
function DataStore:GetAsync(key) return recordValue(dataStoreCall(self, "get", key)) end
function DataStore:SetAsync(key, value) return dataStoreCall(self, "set", key, encodeSave(value)) end
function DataStore:IncrementAsync(key, delta) return dataStoreCall(self, "increment", key, delta) end
function DataStore:RemoveAsync(key) return recordValue(dataStoreCall(self, "remove", key)) end
function DataStore:UpdateAsync(key, transform)
    assert(type(transform) == "function", "UpdateAsync expects a transform function")
    for _ = 1, 5 do
        local record = dataStoreCall(self, "get", key)
        local thread = coroutine.create(transform)
        updateTransforms[thread] = true
        local ok, value = coroutine.resume(thread, recordValue(record))
        updateTransforms[thread] = nil
        if not ok then error(value, 2) end
        if coroutine.status(thread) ~= "dead" then
            task.cancel(thread)
            error("UpdateAsync transforms cannot yield", 2)
        end
        if value == nil then return nil end
        local revision = if record then record.revision else ""
        if dataStoreCall(self, "compare_and_set", key, encodeSave(value), revision) then return value end
    end
    error("DataStore key changed too many times during UpdateAsync", 2)
end
function Godot:Run(code, ...)
    local runner = getfenv(2).script
    return decode(rpc("run_gdscript", {encode(code), runner and runner.id or 0, encodeArguments(...)}))
end
function Godot.IsKeyDown(key) return rpc("input", {type(key) == "table" and key.Value or key}) end
local runService = {Heartbeat = Godot.Process, RenderStepped = Godot.Process, Stepped = Godot.PhysicsProcess}
function runService:IsRunning() return true end
function runService:IsStudio() return false end
local Debris = {}
function Debris:AddItem(instance, lifetime)
    task.delay(lifetime or 10, function()
        pcall(function() instance:Destroy() end)
    end)
end
local HttpService = {}
function HttpService:JSONEncode(value) return rpc("json_encode", {encode(value)}) end
function HttpService:JSONDecode(value) return decode(rpc("json_decode", {value})) end
function HttpService:GenerateGUID(braces)
    local guid = rpc("guid")
    return braces == false and guid or "{" .. guid .. "}"
end
local InputService = {
    ActionPressed = getSignal(0, "input:action_pressed", false),
    ActionReleased = getSignal(0, "input:action_released", false),
}
function InputService:IsKeyDown(key) return Godot.IsKeyDown(key) end
function InputService:HasAction(action) return rpc("input_action", {"has", action}) end
function InputService:GetActions() return decode(rpc("input_action", {"actions"})) end
function InputService:IsActionPressed(action) return rpc("input_action", {"pressed", action}) end
function InputService:IsActionJustPressed(action) return rpc("input_action", {"just_pressed", action}) end
function InputService:IsActionJustReleased(action) return rpc("input_action", {"just_released", action}) end
function InputService:GetActionStrength(action) return rpc("input_action", {"strength", action}) end
function InputService:GetAxis(negative, positive) return rpc("input_action", {"axis", negative, positive}) end
function InputService:GetVector(left, right, up, down, deadzone)
    return decode(rpc("input_action", {"vector", left, right, up, down, deadzone}))
end
Godot.Input = InputService

local CameraControls = {BlendFinished = getSignal(0, "camera:blend_finished", false)}
local function cameraCommand(operation, ...)
    return decode(rpc("camera_control", {operation, encodeArguments(...)}))
end
function CameraControls:GetCurrent() return cameraCommand("current") end
function CameraControls:SetCurrent(camera) cameraCommand("set_current", camera) end
function CameraControls:Follow(camera, target, offset, speed, lookOffset) cameraCommand("follow", camera, target, offset, speed, lookOffset) end
function CameraControls:StopFollowing() cameraCommand("stop_following") end
function CameraControls:BlendTo(camera, duration) cameraCommand("blend_to", camera, duration) end
function CameraControls:CancelBlend() cameraCommand("cancel_blend") end
Godot.Camera = CameraControls
TweenInfo = {}
function TweenInfo.new(duration, style, direction, repeats, reverses, delayTime)
    duration, repeats, delayTime = duration or 1, repeats or 0, delayTime or 0
    assert(duration >= 0 and delayTime >= 0 and repeats >= -1 and repeats % 1 == 0, "Invalid TweenInfo")
    return table.freeze({__type = "TweenInfo", Time = duration, EasingStyle = style or Enum.EasingStyle.Quad, EasingDirection = direction or Enum.EasingDirection.Out, RepeatCount = repeats, Reverses = reverses or false, DelayTime = delayTime})
end
local TweenService = {}
local activeTweens = setmetatable({}, {__mode = "k"})
local function ease(alpha, style, direction)
    local function base(x)
        if style == Enum.EasingStyle.Linear then return x end
        if style == Enum.EasingStyle.Sine then return 1 - math.cos(x * math.pi / 2) end
        if style == Enum.EasingStyle.Quad then return x * x end
        if style == Enum.EasingStyle.Cubic then return x * x * x end
        error("Unsupported easing style")
    end
    if direction == Enum.EasingDirection.In then return base(alpha) end
    if direction == Enum.EasingDirection.Out then return 1 - base(1 - alpha) end
    return alpha < 0.5 and base(alpha * 2) / 2 or 1 - base((1 - alpha) * 2) / 2
end
function TweenService:GetValue(alpha, style, direction) return ease(math.clamp(alpha, 0, 1), style, direction) end
function TweenService:Create(target, info, goals)
    assert(typeof(target) == "Instance" and typeof(info) == "TweenInfo", "Invalid tween target or info")
    local tween = {Completed = Signal.new(), PlaybackState = Enum.PlaybackState.Begin}
    local elapsed, starts, paused = 0, {}, false
    local keys = {}
    for key, goal in goals do
        local start = target[key]
        assert(type(goal) == "number" and type(start) == "number" or typeof(goal) == typeof(start) and (typeof(goal) == "Vector3" or typeof(goal) == "Vector2" or typeof(goal) == "Color3" or typeof(goal) == "CFrame"), "Unsupported tween property type: " .. key)
        keys[key] = goal
    end
    function tween:Cancel()
        if self.connection then self.connection:Disconnect() end
        self.PlaybackState = Enum.PlaybackState.Cancelled
        if activeTweens[target] then
            for key in keys do if activeTweens[target][key] == self then activeTweens[target][key] = nil end end
        end
        paused, elapsed = false, 0
        self.Completed:Fire(self.PlaybackState)
    end
    function tween:Pause()
        if self.PlaybackState ~= Enum.PlaybackState.Playing and self.PlaybackState ~= Enum.PlaybackState.Delayed then return end
        if self.connection then self.connection:Disconnect() end
        paused = true
        self.PlaybackState = Enum.PlaybackState.Paused
    end
    function tween:Play()
        if self.PlaybackState == Enum.PlaybackState.Playing or self.PlaybackState == Enum.PlaybackState.Delayed then return end
        if not activeTweens[target] then activeTweens[target] = {} end
        for key in keys do
            local previous = activeTweens[target][key]
            if previous and previous ~= self then previous:Cancel() end
            activeTweens[target][key] = self
            if not paused then starts[key] = target[key] end
        end
        if not paused then elapsed = 0 end
        paused = false
        self.PlaybackState = Enum.PlaybackState.Playing
        self.connection = Godot.Process:Connect(function(dt)
            elapsed += dt
            local legs = info.Reverses and 2 or 1
            local cycle = info.DelayTime + info.Time * legs
            local total = cycle * (info.RepeatCount + 1)
            local done = info.RepeatCount ~= -1 and elapsed >= total
            local phase = done and cycle or cycle > 0 and elapsed % cycle or 0
            if not done and phase < info.DelayTime then self.PlaybackState = Enum.PlaybackState.Delayed return end
            self.PlaybackState = Enum.PlaybackState.Playing
            local progress = info.Time == 0 and legs or (phase - info.DelayTime) / info.Time
            local alpha = info.Reverses and progress > 1 and 2 - progress or math.min(progress, 1)
            alpha = ease(math.clamp(alpha, 0, 1), info.EasingStyle, info.EasingDirection)
            local ok, message = pcall(function()
                for key, goal in keys do
                    local start = starts[key]
                    target[key] = type(goal) == "number" and start + (goal - start) * alpha or start:Lerp(goal, alpha)
                end
            end)
            if not ok then self:Cancel() rpc("errors", {message}) return end
            if done then
                self.connection:Disconnect()
                self.PlaybackState = Enum.PlaybackState.Completed
                for key in keys do if activeTweens[target][key] == self then activeTweens[target][key] = nil end end
                self.Completed:Fire(self.PlaybackState)
            end
        end)
    end
    return tween
end
local CollectionService = {}
function CollectionService:GetTagged(tag) return decode(rpc("tagged", {tag})) end
local localServices = {RunService = runService, Debris = Debris, HttpService = HttpService, TweenService = TweenService, InputService = InputService, UserInputService = InputService, DataStoreService = DataStoreService, CollectionService = CollectionService}
game = {}
function game:GetService(name)
    if name == "Workspace" then return decode(rpc("world")) end
    if localServices[name] then return localServices[name] end
    local service = decode(rpc("service", {name}))
    localServices[name] = service
    return service
end
setmetatable(game, {__index = function(self, key) return self:GetService(key) end})
function typeof(value) return type(value) == "table" and rawget(value, "__type") or nativeTypeof(value) end
function warn(...) print("[Rodot warning]", ...) end
wait, spawn, delay = task.wait, task.spawn, task.delay
function time() return clock end

local moduleBodies, moduleValues, loadingModules = {}, {}, {}
function __rodot_register_module(fn, id)
    rpc("track_script", {id})
    moduleBodies[id] = fn
    moduleValues[id] = nil
end

function require(module)
    assert(typeof(module) == "Instance" and module.ClassName == "ModuleScript", "Expected a ModuleScript")
    local id = module.id
    if moduleValues[id] ~= nil then return moduleValues[id] end
    assert(not loadingModules[id], "Circular ModuleScript require: " .. module.Name)
    local fn = moduleBodies[id]
    assert(fn, "ModuleScript source is unavailable: " .. module.Name)
    loadingModules[id] = true
    setfenv(fn, setmetatable({script = module}, {__index = getfenv(0)}))
    local result = table.pack(pcall(fn))
    loadingModules[id] = nil
    if not result[1] then error(result[2], 2) end
    assert(result.n == 2 and result[2] ~= nil, "ModuleScript must return one value")
    moduleValues[id] = result[2]
    return result[2]
end

function __rodot_execute(fn, id)
    World = decode(rpc("world"))
    workspace = World
    local environment = setmetatable({script = wrap(id)}, {__index = getfenv(0)})
    setfenv(fn, environment)
    local scope = scriptScopes[id]
    if not scope then
        scope = {alive = true, connections = setmetatable({}, {__mode = "k"})}
        scriptScopes[id] = scope
        rpc("track_script", {id})
    end
    resumeThread(scopedThread(fn, scope))
end
function __rodot_refresh_scene(id, retired)
    World = if id == 0 then nil else wrap(id)
    workspace = World
    for _, scriptId in retired do
        local scope = scriptScopes[scriptId]
        if scope then
            scope.alive = false
            for connection in scope.connections do connection:Disconnect() end
            scriptScopes[scriptId] = nil
        end
        moduleBodies[scriptId], moduleValues[scriptId], loadingModules[scriptId] = nil, nil, nil
    end
end
function __rodot_tick(delta)
    clock += delta
    local batch = sleepers
    sleepers = {}
    if not Godot.Ready.fired then Godot.Ready:Fire() end
    local events = rpc("events")
    for _, event in events do
        if event[1] == 0 and event[2] == "data_store:result" then
            local request, reply = unpack(event[3])
            local thread = remoteStoreThreads[request]
            remoteStoreThreads[request] = nil
            if thread then resumeThread(thread, reply) end
        else
            local signal = signals[tostring(event[1]) .. ":" .. event[2]]
            if signal then signal:Fire(unpack(decode(event[3]))) end
        end
    end
    for _, entry in batch do
        if threadIsLive(entry.thread) then
            if entry.at <= clock then
                if entry.start then resumeThread(entry.thread, clock - entry.start)
                else resumeThread(entry.thread, unpack(entry.args, 1, entry.args.n)) end
            else table.insert(sleepers, entry) end
        end
    end
    Godot.Process:Fire(delta)
end
function __rodot_physics(delta) Godot.PhysicsProcess:Fire(delta) end
