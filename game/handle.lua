-- handle.lua
--
-- Soluciona el ÚNICO caso que reload_code no puede arreglar solo: una
-- referencia externa guardada directamente a un objeto de motor
-- (userdata) -- un cuerpo de love.physics, un Source de love.audio, un
-- Canvas/Image/Shader de love.graphics. Esos objetos no son tablas Lua,
-- así que no se pueden "vaciar y rellenar" como mutateModuleInPlace hace
-- con módulos -- por diseño del lenguaje, no por falta de una técnica
-- mejor (no existe ninguna librería de hot-reload, ni siquiera las más
-- avanzadas de la comunidad de LÖVE, que resuelva esto de otra forma).
--
-- La idea: en vez de guardar el objeto de motor directamente, lo
-- envolvemos en una tabla Lua normal ("Handle"). La tabla SÍ se puede
-- mutar en el lugar -- así que cualquier sistema externo que guarde el
-- Handle (no el objeto de motor en sí) nunca pierde la referencia:
-- cuando el objeto de motor se recrea, se actualiza solo el contenido
-- de adentro del Handle, y la identidad de la tabla externa nunca
-- cambia.
--
-- CÓMO USARLO EN TU JUEGO:
--   -- al crear el objeto:
--   self.physicsBody = Handle.new(world:newBody(x, y, "dynamic"))
--
--   -- para usarlo, siempre a través del Handle (nunca guardes
--   -- self.physicsBody._target por separado en otro lado):
--   self.physicsBody:setPosition(10, 20)   -- delega al objeto real
--   local x, y = self.physicsBody:getPosition()
--
--   -- cuando el reload recree el mundo de física, re-apuntá el Handle
--   -- (no hace falta recrear ni reasignar la referencia externa):
--   Handle.rebind(self.physicsBody, world:newBody(x, y, "dynamic"))
--
-- LÍMITE HONESTO: esto no es automático ni gratis. Hay que decidir
-- envolver los objetos de motor en Handle DESDE QUE SE CREAN, y el
-- código de reload tiene que saber explícitamente qué Handle
-- corresponde a qué objeto nuevo para llamar a Handle.rebind (por eso
-- conviene registrar los Handles importantes con un nombre/id en
-- mcp_bridge.handles, ver abajo). No es magia que arregla objetos que
-- YA se guardaron sin pasar por un Handle desde el principio.

local Handle = {}
Handle.__index = function(self, key)
    local target = rawget(self, "_target")
    if target == nil then
        error("Handle sin target -- ¿se le olvidó llamar a Handle.rebind luego de recrear el objeto?")
    end
    local v = target[key]
    if type(v) == "function" then
        -- Permite llamar métodos con sintaxis de : (self.physicsBody:setPosition(...))
        -- delegando la llamada al objeto real de motor por dentro.
        return function(_, ...) return v(target, ...) end
    end
    return v
end
Handle.__newindex = function(self, key, value)
    rawget(self, "_target")[key] = value
end

-- Registro central opcional: le pone nombre a un Handle para que el
-- código de reload pueda encontrarlo y re-apuntarlo sin que la IA (o
-- vos) tengan que rastrear a mano dónde vive cada referencia.
Handle.registry = {}

function Handle.new(target, registeredName)
    local self = setmetatable({ _target = target }, Handle)
    if registeredName then
        Handle.registry[registeredName] = self
    end
    return self
end

-- Actualiza QUÉ objeto de motor real hay detrás de un Handle ya
-- existente, sin cambiar la identidad de la tabla Handle. Esto es lo
-- que hace que las referencias externas "vean" el objeto nuevo.
function Handle.rebind(handle, newTarget)
    rawset(handle, "_target", newTarget)
end

-- Atajo para re-apuntar por nombre, si se registró con Handle.new(x, "nombre").
function Handle.rebindByName(name, newTarget)
    local handle = Handle.registry[name]
    if not handle then
        return false, "no hay ningún Handle registrado con el nombre '" .. tostring(name) .. "'"
    end
    Handle.rebind(handle, newTarget)
    return true
end

return Handle
