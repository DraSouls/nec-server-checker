---@diagnostic disable: cast-local-type, redefined-local
--->use-luvit<---

--- Default config ---

local TIMEOUT = 1500
local MAX_RETRIES = 3

local MODLIST_CACHE_TTL = 420



--- Util ---

local fs = require 'fs'
local dns = require 'dns'
local udp = require 'dgram'
local json = require 'json'
local timer = require 'timer'
local process = require 'process'.globalProcess()
local weblitApp = require 'weblit-app'
local querystring = require 'querystring'

local packets = require './packets'
local PacketType = packets.PacketType


-- Env and cache

local NCPSK = querystring.parse(process.env.NCPSK or '', ',')

-- key=<iphost>:<modshash>
-- value={<expireTime cmp os.time()>, <modslist>}
local modlistCache = {}

timer.setInterval(62000, function()
    local toRemove = {}
    for k, v in pairs(modlistCache) do
        if v[1] > os.time() then
            toRemove[#toRemove+1] = k
        end
    end
    for i = 1, #toRemove do
        modlistCache[toRemove[i]] = nil
    end
end)


-- Coro socket funcs

local function waitResponse(thr)
    local tout = timer.setTimeout(TIMEOUT, function()
        if coroutine.status(thr) == 'suspended' then
            coroutine.resume(thr, false)
        end
    end)

    local res = coroutine.yield()
    timer.clearTimeout(tout)
    return res
end

local function sendThenWait(thr, socket, port, server, data)
    local res
    for _ = 0, MAX_RETRIES do
        socket:send(data, port, server, function() end)
        res = waitResponse(thr)
        if res then break end
    end

    if not res then
        socket:close(function() end)
        return nil
    end

    return res
end



--- Query ---

-- only here to catch common mistakes, non-exhaustive
local illegalIps = {['0'] = true, ['10'] = true, ['127'] = true, ['255'] = true, ['169.254'] = true, ['192.168'] = true,}

local function getServerInfo(host, port, password, getStatus, getMods)
    local thr = coroutine.running()
    local result = {}
    result.code = 200
    result.err = ""

    if illegalIps[host:match('%d+')] or illegalIps[host:match('%d+%.%d+')] or host == 'localhost'  then
        result.code = 420
        result.online = false
        result.err = "That's not a public host, you numpty"
        return result
    end

    -- resolve if hostname was given instead
    if not host:match('%d+%.%d+%.%d+%.%d+') then
        dns.resolve4(host, function(err, data) coroutine.resume(thr, data, err) end)
        local ret, err = coroutine.yield()
        if not ret then
            result.code = 500
            result.online = false
            result.err = "Unable to locate '"..host.."': "..(err and err.message or 'Unknown error')
            return result
        end
        host = ret[1].address
    end

    local socket = udp.createSocket('udp4', function(data)
        if coroutine.status(thr) == 'suspended' then
            coroutine.resume(thr, data)
        end
    end)
    socket:bind(port, host)
    socket:recvStart()

    local resp

    resp = sendThenWait(thr, socket, port, host, packets.serialize(PacketType.ServerStatusRequest, math.random(1,1047563)))
    if not resp then
        result.code = 500
        result.online = false
        result.err = "The server failed to respond. Probably try again."
        goto END
    end

    do
        local _, status = packets.parse(resp)
        result.online = true
        if getStatus then
            status.uid = nil
            status.state = nil
            result.status = status
        end

        if getMods then
            if status.modsHash == 0 then
                result.mods = {}
                result.modCount = 0
                goto END
            end

            if modlistCache[host..':'..status.modsHash] then
                result.mods = modlistCache[host..':'..status.modsHash][2]
                result.modCount = #result.mods
                goto END
            end


            resp = sendThenWait(thr, socket, port, host, packets.serialize(PacketType.ConnectRequest, status.passwordProtected and password or 0))
            if not resp then
                result.mods = {}
                result.modCount = -1
                result.err = "The server failed to respond for modlist request. Probably try again."
                goto END
            end

            local packetType, data = packets.parse(resp)
            if packetType == PacketType.RequestPassword or packetType == PacketType.Disconnect then
                result.mods = {}
                result.modCount = -1
                result.err = "Server refused modlist request: "..tostring(data)
            elseif packetType == PacketType.ModsMismatch then
                result.mods = data
                result.modCount = #data
                modlistCache[host..':'..status.modsHash] = { os.time() + MODLIST_CACHE_TTL, data }
            else
                result.mods = {}
                result.modCount = -1
                result.err = "Server sent unknown packet: "..tostring(data)
                p(data)
            end
        end
    end

    ::END::

    socket:close(function() end)
    return result
end



--- Web server ---

local app = weblitApp.bind {
    host = "0.0.0.0",
    port = process.env.PORT or 8080
}

app.route({method = 'GET', path = '/'}, function(req, res)
    res.body = fs.readFileSync('index.min.html') or fs.readFileSync('index.html')
    res.code = 200
end)

app.route({method = 'POST', path = '/api'}, function(req, res)
    local ct = req.headers['Content-Type']
    req.body = req.body and req.body:gsub('^%s+', ''):gsub('%s+$', '') or ''

    local data
    if ct == 'application/json' then
        local t, _, err = json.decode(req.body)
        if type(t) ~= 'table' then
            res.body = json.encode { code = 400, err = "Malformed JSON: "..(err or "Object required") }
            res.code = 400
            return
        end
        data = t
    elseif ct == 'application/x-www-form-urlencoded' then
        data = querystring.parse(req.body)
    else
        res.body = json.encode { code = 400, err = "Invalid Content-Type header. Accepts: 'application/json', 'application/x-www-form-urlencoded', got '"..tostring(ct).."'" }
        res.code = 400
        return
    end

    if type(data.host) ~= 'string' or #data.host:gsub('^%s+', ''):gsub('%s+$', '') == 0 then
        res.body = json.encode { code = 400, err = "Host parameter is required." }
        res.code = 400
        return
    end

    local s, t = pcall(getServerInfo,
        data.host,
        tonumber(data.port) or 14159,
        tonumber(NCPSK[data.psk] or NCPSK[data.password]) or tonumber(data.passHash) or data.password or '',
        data.getStatus,
        data.getMods
    )

    if not s then
        res.body = json.encode { code = 500, err = "The specified host might've sent an invalid response. ("..tostring(t)..")" }
        res.code = 500
        return
    end
    t.host = data.host

    res.body = json.encode(t)
    res.code = 200
end)



--- Start server ---

app.start()

print(("Ready! Took %.3fms."):format(os.clock()*1000))
