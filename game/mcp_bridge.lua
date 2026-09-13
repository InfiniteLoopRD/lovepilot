-- MCP Bridge - TCP server for communicating with MCP server
local socket = require("socket")

local mcp_bridge = {}
local server = nil
local clients = {}
local objectGetter = nil

-- Virtual input state (used for AI-driven play)
local virtualKeys = {}
local virtualMouse = { x = 0, y = 0, buttons = {} }
local scheduledReleases = {}

-- Pending async screenshot requests (client sockets waiting for a screenshot)
local pendingScreenshots = {}

-- Change-tracking for real-time push updates
local lastStateSnapshot = nil
local watchingClients = {} -- clients subscribed to state-change events

-- Initialize TCP server. Safe to call more than once (e.g. after a
-- reload re-runs love.load()) — it will not rebind an already-open port.
function mcp_bridge.init(port)
    if server then
        print("MCP Bridge already listening, skipping re-init")
        return
    end
    server = assert(socket.tcp())
    server:bind("*", port)
    server:listen(5)
    server:settimeout(0) -- Non-blocking
    print("MCP Bridge listening on port " .. port)
end

-- Set function to get game objects
function mcp_bridge.setObjectGetter(getter)
    objectGetter = getter
end

-- ===== Virtual input API =====
-- Call mcp_bridge.isDown(key) instead of love.keyboard.isDown(key) in your
-- game's movement/action code so both real and AI-driven input work.
function mcp_bridge.isDown(key)
    return virtualKeys[key] == true or love.keyboard.isDown(key)
end

function mcp_bridge.mouseIsDown(button)
    return virtualMouse.buttons[button] == true or love.mouse.isDown(button)
end

function mcp_bridge.getMousePosition()
    return virtualMouse.x, virtualMouse.y
end

function mcp_bridge.pressKey(key, duration)
    virtualKeys[key] = true
    if duration then
        table.insert(scheduledReleases, { key = key, time = love.timer.getTime() + duration })
    end
end

function mcp_bridge.releaseKey(key)
    virtualKeys[key] = nil
end

function mcp_bridge.setMousePosition(x, y)
    virtualMouse.x = x
    virtualMouse.y = y
end

function mcp_bridge.pressMouse(button)
    virtualMouse.buttons[button] = true
end

function mcp_bridge.releaseMouse(button)
    virtualMouse.buttons[button] = nil
end

-- Handle incoming connections and commands
function mcp_bridge.update()
    if not server then return end

    -- Release any virtual keys/buttons whose scheduled duration has elapsed
    local now = love.timer.getTime()
    for i = #scheduledReleases, 1, -1 do
        if now >= scheduledReleases[i].time then
            virtualKeys[scheduledReleases[i].key] = nil
            table.remove(scheduledReleases, i)
        end
    end

    -- Accept new clients
    local client = server:accept()
    if client then
        client:settimeout(0)
        table.insert(clients, client)
        print("MCP client connected")
    end

    -- Handle existing clients
    for i = #clients, 1, -1 do
        local client = clients[i]
        local line, err = client:receive("*l")

        if line then
            -- Process command
            local success, response = pcall(mcp_bridge.handleCommand, line, client)
            if success then
                -- A nil response means the command is async (e.g. screenshot)
                -- and will send its own reply later.
                if response then
                    client:send(response .. "\n")
                end
            else
                client:send(json.encode({error = tostring(response)}) .. "\n")
            end
        elseif err == "closed" then
            -- Client disconnected
            client:close()
            table.remove(clients, i)
            for j = #watchingClients, 1, -1 do
                if watchingClients[j] == client then table.remove(watchingClients, j) end
            end
            print("MCP client disconnected")
        end
        -- err == "timeout" means no data available, continue
    end

    -- Push real-time state updates to any subscribed clients when
    -- something actually changed (avoids flooding the connection).
    mcp_bridge.checkAndPushStateChanges()
end

-- Compare the current game state against the last snapshot and push a
-- "state_changed" event to subscribed clients if anything is different.
-- This is what makes "watch_game_state" feel real-time on the AI side:
-- the game pushes updates itself instead of waiting to be asked.
function mcp_bridge.checkAndPushStateChanges()
    if #watchingClients == 0 or not objectGetter then return end

    local snapshot = json.encode({ objects = objectGetter() })
    if snapshot ~= lastStateSnapshot then
        lastStateSnapshot = snapshot
        local event = json.encode({ event = "state_changed", data = json.decode(snapshot) }) .. "\n"
        for i = #watchingClients, 1, -1 do
            local ok = pcall(function() watchingClients[i]:send(event) end)
            if not ok then table.remove(watchingClients, i) end
        end
    end
end

-- Handle a command from MCP server
-- `client` is the raw TCP socket this command came from (needed for
-- async replies like screenshots, and for subscribing to watch events).
function mcp_bridge.handleCommand(line, client)
    local command = json.decode(line)
    local reqId = command._reqId -- número de pedido puesto por el cliente MCP, si vino

    local response
    if command.command == "get_objects" then
        response = mcp_bridge.getObjects(command.id)
    elseif command.command == "run_lua" then
        response = mcp_bridge.runLua(command.code)
    elseif command.command == "get_screenshot" then
        -- Asíncrono: guardamos el _reqId junto con el cliente para poder
        -- devolverlo en la respuesta real, que se manda más tarde desde
        -- captureIfPending() (ver ahí), no acá.
        table.insert(pendingScreenshots, { client = client, reqId = reqId })
        return nil -- async: reply is sent from love.draw() once captured
    elseif command.command == "send_input" then
        response = mcp_bridge.handleInput(command)
    elseif command.command == "watch_game_state" then
        table.insert(watchingClients, client)
        response = json.encode({ ok = true, message = "subscribed to state_changed events" })
    elseif command.command == "unwatch_game_state" then
        for i = #watchingClients, 1, -1 do
            if watchingClients[i] == client then table.remove(watchingClients, i) end
        end
        response = json.encode({ ok = true, message = "unsubscribed" })
    elseif command.command == "reload_code" then
        local ok, err = mcp_bridge.reloadCode(command.file)
        if ok then
            response = json.encode({ ok = true, message = "reloaded " .. tostring(command.file or "main.lua") })
        else
            response = json.encode({ error = err })
        end
    elseif command.command == "list_lua_files" then
        response = json.encode({ files = mcp_bridge.listLuaFiles(command.dir) })
    else
        response = json.encode({error = "Unknown command: " .. tostring(command.command)})
    end

    -- Le metemos el _reqId de vuelta a la respuesta síncrona, para que el
    -- cliente MCP pueda reconocer a cuál comando corresponde (y descartar
    -- respuestas tardías que ya vencieron por timeout, en vez de
    -- pegárselas por error al comando que esté en vuelo en ese momento).
    if response and reqId ~= nil then
        local decoded = json.decode(response)
        decoded._reqId = reqId
        response = json.encode(decoded)
    end
    return response
end

-- Handle a virtual input command.
-- Expected shapes:
--   {type="key_down", key="left", duration=0.2}
--   {type="key_up", key="left"}
--   {type="mouse_move", x=100, y=200}
--   {type="mouse_down", button=1}
--   {type="mouse_up", button=1}
function mcp_bridge.handleInput(command)
    local t = command.type
    if t == "key_down" then
        mcp_bridge.pressKey(command.key, command.duration)
    elseif t == "key_up" then
        mcp_bridge.releaseKey(command.key)
    elseif t == "mouse_move" then
        mcp_bridge.setMousePosition(command.x, command.y)
    elseif t == "mouse_down" then
        mcp_bridge.pressMouse(command.button or 1)
    elseif t == "mouse_up" then
        mcp_bridge.releaseMouse(command.button or 1)
    else
        return json.encode({ error = "Unknown input type: " .. tostring(t) })
    end
    return json.encode({ ok = true })
end

-- Call this once per frame from love.draw(), AFTER your normal drawing
-- code, so any pending screenshot requests capture the fully-rendered
-- frame. Screenshots are asynchronous in LÖVE, so replies are sent here
-- once the captured image is ready, not immediately when requested.
function mcp_bridge.captureIfPending()
    if #pendingScreenshots == 0 then return end

    local waitingClients = pendingScreenshots
    pendingScreenshots = {}

    love.graphics.captureScreenshot(function(imageData)
        -- Todo este bloque corre FUERA del ciclo normal de comandos (el
        -- que sí está protegido con pcall en mcp_bridge.update()), así
        -- que si no lo protegemos acá, un fallo en encode() no solo deja
        -- al cliente esperando una respuesta que nunca llega -- puede
        -- tirar abajo el juego completo, porque nada más lo atrapa.
        local ok, base64OrErr = pcall(function()
            local fileData = imageData:encode("png")
            return love.data.encode("string", "base64", fileData:getString())
        end)

        -- Cada cliente que pidió captura puede tener su propio _reqId, así
        -- que la respuesta se arma una vez por cliente (no se puede
        -- reusar un solo string para todos, porque el _reqId cambia).
        for _, item in ipairs(waitingClients) do
            local payload
            if ok then
                payload = { screenshot = base64OrErr, format = "png_base64" }
            else
                payload = { error = "screenshot encode failed: " .. tostring(base64OrErr) }
            end
            if item.reqId ~= nil then
                payload._reqId = item.reqId
            end
            local response = json.encode(payload) .. "\n"
            pcall(function() item.client:send(response) end)
        end
    end)
end

-- List all objects
-- Lista todos los objetos, o trae uno solo si se pasa un id. Fusiona lo
-- que antes eran dos comandos separados (list_objects / get_object) en
-- uno solo, porque eran la misma operación con o sin filtro -- misma
-- fuente de datos (objectGetter), solo cambiaba si se devolvía todo o
-- una sola entrada.
function mcp_bridge.getObjects(id)
    if not objectGetter then
        return json.encode({error = "No object getter configured"})
    end

    local objects = objectGetter()

    if id ~= nil then
        -- Comportamiento idéntico al viejo get_object(id)
        local obj = objects[id]
        if not obj then
            return json.encode({error = "Object not found: " .. tostring(id)})
        end
        return json.encode({object = obj})
    end

    -- Comportamiento idéntico al viejo list_objects()
    local result = {}
    for objId, obj in pairs(objects) do
        table.insert(result, {
            id = objId,
            type = obj.type,
            x = obj.x,
            y = obj.y
        })
    end
    return json.encode({objects = result})
end

-- Run arbitrary Lua code with access to game objects
function mcp_bridge.runLua(code)
    local func, err = loadstring(code)
    if not func then
        return json.encode({error = "Syntax error: " .. tostring(err)})
    end

    -- Set up environment with access to objects
    local env = {
        objects = objectGetter and objectGetter() or {},
        love = love,
        print = print,
        pairs = pairs,
        ipairs = ipairs,
        type = type,
        tostring = tostring,
        tonumber = tonumber,
        table = table,
        math = math,
        string = string,
    }
    setfenv(func, env)

    local success, result = pcall(func)
    if not success then
        return json.encode({error = "Runtime error: " .. tostring(result)})
    end

    -- Handle table results by encoding them
    if type(result) == "table" then
        return json.encode({result = result})
    else
        return json.encode({result = tostring(result)})
    end
end

-- Módulos que NUNCA hay que limpiar de package.loaded al recargar: son
-- del lenguaje/motor/bridge, no del juego. Cualquier otra cosa que esté
-- en package.loaded se asume que la puso el propio juego vía require()
-- y se limpia, sin importar en qué orden el juego la haya requerido
-- (esto evita depender de tomar una "foto" del estado al arrancar,
-- que fallaría si el juego requiere sus propios módulos antes de
-- llamar a mcp_bridge.init()).
local PROTECTED_MODULES = {
    ["_G"] = true, ["package"] = true, ["coroutine"] = true, ["table"] = true,
    ["io"] = true, ["os"] = true, ["string"] = true, ["math"] = true,
    ["utf8"] = true, ["debug"] = true, ["bit"] = true, ["ffi"] = true,
    ["jit"] = true, ["jit.opt"] = true, ["jit.util"] = true,
    ["string.buffer"] = true, ["socket"] = true, ["socket.core"] = true,
    ["mime"] = true, ["mime.core"] = true, ["mcp_bridge"] = true,
}

-- Copia el contenido de newModule DENTRO de oldModule, sin cambiar la
-- identidad de la tabla oldModule. Esto es lo que permite que una
-- referencia externa guardada de antemano (ej. `local Player =
-- require("modules.player")` en otro sistema) "vea" el código nuevo sin
-- que nadie tenga que volver a buscarla y reasignarla: como esa
-- referencia apunta a la tabla por identidad, no por nombre, si la
-- tabla sigue siendo la misma pero con contenido actualizado adentro,
-- el cambio se propaga solo.
--
-- Límite importante (y que hay que tener claro): esto arregla
-- referencias a MÓDULOS (lo que devuelve require(...)), no a INSTANCIAS
-- creadas a partir de un módulo (ej. `player = Player.new()`). Una
-- instancia es una tabla aparte que main.lua vuelve a crear desde cero
-- cada vez que se re-ejecuta por completo; mutar la clase Player en el
-- lugar no reescribe instancias que ya existían antes del reload. Para
-- ese caso puntual seguí usando run_lua para re-apuntar la referencia a
-- mano, o rediseñá el sistema para que guarde un id y busque la
-- instancia en una tabla central en vez de guardarse la tabla misma.
local function mutateModuleInPlace(oldModule, newModule)
    if type(oldModule) ~= "table" or type(newModule) ~= "table" then
        -- No hay identidad de tabla que preservar (el módulo devuelve una
        -- función, un string, etc.) — se usa la versión nueva tal cual,
        -- igual que haría un require() normal.
        return newModule
    end
    for k in pairs(oldModule) do
        oldModule[k] = nil
    end
    for k, v in pairs(newModule) do
        oldModule[k] = v
    end
    setmetatable(oldModule, getmetatable(newModule))
    return oldModule
end

-- Vacía la caché de require() de todos los módulos del juego, PERO en
-- vez de simplemente borrarlos y dejar que el próximo require() cree
-- tablas nuevas (lo que rompe cualquier referencia externa guardada de
-- antemano), instala temporalmente una versión de require() que fusiona
-- el módulo nuevo DENTRO de la tabla vieja (mutación en el lugar, ver
-- mutateModuleInPlace arriba).
--
-- Devuelve tres cosas:
--   1. mutated: lista de nombres de módulo que sí se volvieron a
--      requerir (y por lo tanto mutaron en el lugar) durante este reload.
--   2. restoreRequire(): función para devolver el require() original.
--      Hay que llamarla siempre al terminar, incluso si el reload falló.
--   3. oldModules: los módulos que NO se volvieron a requerir (porque el
--      código recargado no pasa por ellos). El llamador debe reponerlos
--      tal cual en package.loaded para no dejarlos huérfanos.
function mcp_bridge.clearModuleCache()
    local originalRequire = require
    local oldModules = {}
    local mutated = {}

    for k, v in pairs(package.loaded) do
        if not PROTECTED_MODULES[k] then
            oldModules[k] = v
            package.loaded[k] = nil
        end
    end

    _G.require = function(modname)
        if oldModules[modname] ~= nil then
            local newModule = originalRequire(modname)
            local merged = mutateModuleInPlace(oldModules[modname], newModule)
            package.loaded[modname] = merged
            oldModules[modname] = nil -- ya procesado
            mutated[#mutated + 1] = modname
            return merged
        else
            return originalRequire(modname)
        end
    end

    local function restoreRequire()
        _G.require = originalRequire
    end

    return mutated, restoreRequire, oldModules
end

-- Lista todos los archivos .lua del proyecto (recursivo), para que la
-- IA sepa qué archivos existen antes de decidir cuál editar/recargar,
-- en vez de asumir que todo vive en un único main.lua.
function mcp_bridge.listLuaFiles(dir)
    dir = dir or ""
    local result = {}
    local function walk(path)
        local items = love.filesystem.getDirectoryItems(path)
        for _, item in ipairs(items) do
            local fullPath = (path == "" and item) or (path .. "/" .. item)
            local info = love.filesystem.getInfo(fullPath)
            if info then
                if info.type == "directory" then
                    walk(fullPath)
                elseif info.type == "file" and fullPath:match("%.lua$") then
                    result[#result+1] = fullPath
                end
            end
        end
    end
    walk(dir)
    return result
end

-- Hot-reload a Lua file from disk while the game is running.
--
-- LÖVE does NOT do this on its own: editing a file on disk has zero
-- effect on the running process until you restart it. This function:
--   1. Clears the require() cache for every game module (see
--      clearModuleCache above), so requires anywhere in the reloaded
--      chain pick up fresh code, not stale cached tables.
--   2. Re-reads and re-executes the given file (default "main.lua"),
--      redefining love.load/update/draw/etc with whatever is on disk.
--   3. Calls the freshly-defined love.load() so the game re-initializes,
--      same as LÖVE does at boot.
-- This is a "restart the level with new code" reload, not a
-- state-preserving patch — most game state lives in locals that get
-- re-created when the file's top-level code runs again.
function mcp_bridge.reloadCode(file)
    file = file or "main.lua"

    local _, restoreRequire, oldModules = mcp_bridge.clearModuleCache()

    -- Repone en package.loaded, sin mutar, cualquier módulo que el reload
    -- de este archivo no haya vuelto a tocar — para que no quede huérfano.
    local function restoreUntouchedModules()
        for k, v in pairs(oldModules) do
            package.loaded[k] = v
        end
    end

    local chunk, loadErr = love.filesystem.load(file)
    if not chunk then
        restoreRequire()
        restoreUntouchedModules()
        return false, "load error: " .. tostring(loadErr)
    end

    local ok, runErr = pcall(chunk)
    restoreRequire()
    restoreUntouchedModules()
    if not ok then
        return false, "runtime error while reloading: " .. tostring(runErr)
    end

    -- The reloaded file just redefined love.load (among others). Call it
    -- now so the game re-initializes, same as LÖVE calling it at boot.
    if love.load then
        local ok2, err2 = pcall(love.load, {})
        if not ok2 then
            return false, "error in love.load() after reload: " .. tostring(err2)
        end
    end

    return true, nil
end

function mcp_bridge.shutdown()
    -- Close all clients
    for _, client in ipairs(clients) do
        client:close()
    end
    clients = {}

    -- Close server
    if server then
        server:close()
        server = nil
        print("MCP Bridge shut down")
    end
end

-- Simple JSON encoder/decoder
json = {}

function json.encode(obj)
    local t = type(obj)
    if t == "table" then
        local parts = {}
        local isArray = true
        local arraySize = 0

        -- Check if it's an array
        for k, v in pairs(obj) do
            if type(k) ~= "number" then
                isArray = false
                break
            end
            arraySize = arraySize + 1
        end

        if isArray and arraySize > 0 then
            for i, v in ipairs(obj) do
                table.insert(parts, json.encode(v))
            end
            return "[" .. table.concat(parts, ",") .. "]"
        else
            for k, v in pairs(obj) do
                local key = type(k) == "string" and json.encode(k) or tostring(k)
                table.insert(parts, key .. ":" .. json.encode(v))
            end
            return "{" .. table.concat(parts, ",") .. "}"
        end
    elseif t == "string" then
        return '"' .. obj:gsub('\\', '\\\\'):gsub('"', '\\"'):gsub('\n', '\\n') .. '"'
    elseif t == "number" or t == "boolean" then
        return tostring(obj)
    elseif t == "nil" then
        return "null"
    else
        return '"' .. tostring(obj) .. '"'
    end
end

function json.decode(str)
    local pos = 1

    local function skip_whitespace()
        while pos <= #str and str:sub(pos, pos):match("%s") do
            pos = pos + 1
        end
    end

    local function decode_string()
        local result = ""
        pos = pos + 1 -- skip opening quote
        while pos <= #str do
            local char = str:sub(pos, pos)
            if char == '"' then
                pos = pos + 1
                return result
            elseif char == "\\" then
                pos = pos + 1
                local escape = str:sub(pos, pos)
                if escape == "n" then result = result .. "\n"
                elseif escape == "t" then result = result .. "\t"
                elseif escape == "r" then result = result .. "\r"
                elseif escape == "\\" then result = result .. "\\"
                elseif escape == '"' then result = result .. '"'
                else result = result .. escape end
                pos = pos + 1
            else
                result = result .. char
                pos = pos + 1
            end
        end
        error("Unterminated string")
    end

    local function decode_value()
        skip_whitespace()
        local char = str:sub(pos, pos)

        if char == '"' then
            return decode_string()
        elseif char == "{" then
            local obj = {}
            pos = pos + 1
            skip_whitespace()
            if str:sub(pos, pos) == "}" then
                pos = pos + 1
                return obj
            end
            while true do
                skip_whitespace()
                local key = decode_string()
                skip_whitespace()
                if str:sub(pos, pos) ~= ":" then error("Expected :") end
                pos = pos + 1
                obj[key] = decode_value()
                skip_whitespace()
                char = str:sub(pos, pos)
                if char == "}" then
                    pos = pos + 1
                    return obj
                elseif char == "," then
                    pos = pos + 1
                else
                    error("Expected , or }")
                end
            end
        elseif char == "[" then
            local arr = {}
            pos = pos + 1
            skip_whitespace()
            if str:sub(pos, pos) == "]" then
                pos = pos + 1
                return arr
            end
            while true do
                table.insert(arr, decode_value())
                skip_whitespace()
                char = str:sub(pos, pos)
                if char == "]" then
                    pos = pos + 1
                    return arr
                elseif char == "," then
                    pos = pos + 1
                else
                    error("Expected , or ]")
                end
            end
        elseif str:sub(pos, pos + 3) == "true" then
            pos = pos + 4
            return true
        elseif str:sub(pos, pos + 4) == "false" then
            pos = pos + 5
            return false
        elseif str:sub(pos, pos + 3) == "null" then
            pos = pos + 4
            return nil
        else
            local num_str = str:match("^%-?%d+%.?%d*[eE]?[%+%-]?%d*", pos)
            if num_str then
                pos = pos + #num_str
                return tonumber(num_str)
            end
            error("Invalid JSON value at position " .. pos)
        end
    end

    return decode_value()
end

return mcp_bridge
