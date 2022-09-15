
local VERSION = "0.21.24"

local PacketType = {
    ServerStatus        = 0x00,
    ServerStatusRequest = 0x01,
    ConnectRequest      = 0x03,
    Disconnect          = 0x05,
    ModsMismatch        = 0x07,
    RequestPassword     = 0x0a,
}



--- Util ---

local bit = require 'bit'
local ffi = require 'ffi'

-- Java hashCode
local function hashCode(str)
    local h = ffi.new('int32_t', 0)
    for i = 1, #str do
        h = ffi.cast('int32_t', 31 * h + str:byte(i,i))
    end
    return tonumber(h)
end

local function readStr16(str, pos)
    local len; len, pos = ('>I2'):unpack(str, pos)
    local out = {}
    for i = 1, len do
        local char; char, pos = ('>xc1'):unpack(str, pos)
        out[i] = char
    end
    return table.concat(out), pos
end

local function makeBoolGetter(str)
    local lastField, remainingBits = 0, 0
    return function(nextPos)
        if remainingBits <= 0 then
            lastField, nextPos = ('>B'):unpack(str, nextPos)
            remainingBits = 8
        end
        remainingBits = remainingBits - 1
        return bit.band(lastField, bit.lshift(1, 7 - remainingBits)) > 0, nextPos
    end
end



--- Parsers ---

local parsers = setmetatable({}, {__index = function() return nil end})

-- ServerStatus
local Difficulty = {[0] = "Casual", "Easy", "Normal", "Hard", "Brutal"}
local Penalty = {[0] = "None", "Drop Materials", "Drop Main Inventory", "Drop Full Inventory", "Hardcore"}
local RaidFreq = {[0] = "Occasionally", "Rarely", "Never"}
parsers[PacketType.ServerStatus] = function(data, nextPos)
    local getBoolean = makeBoolGetter(data)
    local t = {}

    t.state, t.uid, t.playersOnline, t.slots, nextPos = ('>i4i8BB'):unpack(data, nextPos)
    t.passwordProtected, nextPos = getBoolean(nextPos)

    do -- World settings
        local s = {}

        s.allowCheats, nextPos = getBoolean(nextPos)
        s.playerHunger, nextPos = getBoolean(nextPos)
        s.disableMobSpawns, nextPos = getBoolean(nextPos)
        s.forcedPvP, nextPos = getBoolean(nextPos)
        s.unloadSettlements, nextPos = getBoolean(nextPos)
        s.difficulty, s.deathPenalty, s.raidFrequency, s.maxSettlementsPerPlayer, s.dayTimeMod, s.nightTimeMod, nextPos
                = ('>BBBi4ff'):unpack(data, nextPos)

        s.difficulty = Difficulty[s.difficulty] or "Invalid"
        s.deathPenalty = Penalty[s.deathPenalty] or "Invalid"
        s.raidFrequency = RaidFreq[s.raidFrequency] or "Invalid"

        t.worldSettings = s
    end

    t.modsHash, nextPos = ('>i4'):unpack(data, nextPos)
    t.version, nextPos = readStr16(data, nextPos)

    return t
end


-- Disconnect
local ErrCode = {[0] = 'Null', 'Internal error', 'Kick', 'Client not responding', 'Server stopping', 'Server error', 'Client error', 'Wrong password',
        'Missing client', 'Banned', 'Wrong version', 'Already playing', 'Server full', 'Disconnected', 'Missing appearance', 'Network error', 'State desync'}
parsers[PacketType.Disconnect] = function(data, nextPos)
    local errCode; errCode, nextPos = ('>xB'):unpack(data, nextPos)

    return "Request error: "..ErrCode[errCode]
end


-- ModsMismatch
parsers[PacketType.ModsMismatch] = function(data, nextPos)
    local totalMods; totalMods, nextPos = ('>I2'):unpack(data, nextPos)
    local getBoolean = makeBoolGetter(data)

    local mods = {}

    for i = 1, totalMods do
        local t = {}
        t.modId, nextPos = readStr16(data, nextPos)
        t.modVer, nextPos = readStr16(data, nextPos)
        t.modName, nextPos = readStr16(data, nextPos)
        t.isClientSide, nextPos = getBoolean(nextPos)
        t.isWorkshop, nextPos = getBoolean(nextPos)

        mods[i] = t
    end

    -- calc modsHash
    local h = ffi.new('int32_t', 0)
    for _, mod in ipairs(mods) do
        if not mod.isClientSide then
            h = ffi.cast('int32_t', h * 37 + hashCode(mod.modId))
            h = ffi.cast('int32_t', h * 13 + hashCode(mod.modVer))
        end
    end

    return mods, bit.tohex(h, 8)
end


-- RequestPassword
parsers[PacketType.RequestPassword] = function(data, nextPos)
    return "Password is non-empty!"
end


local function parse(data)
    local _, packetType, nextPos = ('>BI2'):unpack(data)

    return packetType, parsers[packetType](data, nextPos)
end



--- Serializers ---

local sers = setmetatable({}, {__index = function() return nil end})

-- ServerStatusRequest
sers[PacketType.ServerStatusRequest] = function(seed)
    return ('>I2i4'):pack(0, seed)
end

-- ConnectRequest
sers[PacketType.ConnectRequest] = function(password)
    password = password or 0
    if type(password) == 'string' then
        password = hashCode(password)
    end

    local ver16 = VERSION:gsub('.', '\0%1')
    return ('>I8i4i4i4'):pack(
        1234,
        0,
        password,
        #VERSION
    ) .. ver16 .. '\1'
end

local function serialize(packetType, ...)
    local res = sers[packetType](...)
    return type(res) == 'string' and ('>BI2'):pack(0, packetType)..res or nil
end



---

return {
    PacketType = PacketType,
    parse = parse,
    serialize = serialize,
}
