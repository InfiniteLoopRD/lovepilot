-- Simple LÖVE2D game with MCP support
local mcp_bridge = require("mcp_bridge")

-- Game objects
local objects = {}
local nextId = 1

-- Example AI-controllable player. Movement reads mcp_bridge.isDown()
-- instead of love.keyboard.isDown() directly, so both a human on the
-- keyboard AND the AI's send_input commands move the same character.
local player = {
    id = "player_1",
    type = "player",
    x = 400,
    y = 300,
    speed = 200,
    health = 100,
    state = "idle", -- idle | walking | attacking
}

function love.load()
    -- Initialize MCP bridge
    mcp_bridge.init(12345)

    objects[player.id] = player

    -- Create some example objects (bouncing balls)
    for i = 1, 9 do
        local obj = {
            id = "ball_" .. nextId,
            type = "ball",
            x = math.random(50, 750),
            y = math.random(50, 550),
            vx = math.random(-200, 200),
            vy = math.random(-200, 200),
            radius = math.random(10, 30),
            r = math.random(),
            g = math.random(),
            b = math.random()
        }
        objects[obj.id] = obj
        nextId = nextId + 1
    end

    -- Register object access functions with MCP bridge
    mcp_bridge.setObjectGetter(function()
        return objects
    end)
end

function love.update(dt)
    -- Update MCP bridge (check for incoming commands)
    mcp_bridge.update()

    -- Move the player using virtual OR real input (see mcp_bridge.isDown)
    player.state = "idle"
    if mcp_bridge.isDown("left") then player.x = player.x - player.speed * dt; player.state = "walking" end
    if mcp_bridge.isDown("right") then player.x = player.x + player.speed * dt; player.state = "walking" end
    if mcp_bridge.isDown("up") then player.y = player.y - player.speed * dt; player.state = "walking" end
    if mcp_bridge.isDown("down") then player.y = player.y + player.speed * dt; player.state = "walking" end
    if mcp_bridge.isDown("space") then player.state = "attacking" end

    -- Update game objects
    for _, obj in pairs(objects) do
        if obj.type == "ball" then
            -- Update position
            obj.x = obj.x + obj.vx * dt
            obj.y = obj.y + obj.vy * dt

            -- Bounce off walls
            if obj.x - obj.radius < 0 or obj.x + obj.radius > love.graphics.getWidth() then
                obj.vx = -obj.vx
                obj.x = math.max(obj.radius, math.min(love.graphics.getWidth() - obj.radius, obj.x))
            end

            if obj.y - obj.radius < 0 or obj.y + obj.radius > love.graphics.getHeight() then
                obj.vy = -obj.vy
                obj.y = math.max(obj.radius, math.min(love.graphics.getHeight() - obj.radius, obj.y))
            end
        end
    end
end

function love.draw()
    -- Draw all objects
    for _, obj in pairs(objects) do
        if obj.type == "ball" then
            love.graphics.setColor(obj.r, obj.g, obj.b)
            love.graphics.circle("fill", obj.x, obj.y, obj.radius)
        elseif obj.type == "player" then
            love.graphics.setColor(1, 1, 0)
            love.graphics.rectangle("fill", obj.x - 15, obj.y - 15, 30, 30)
        end
    end

    -- Draw instructions
    love.graphics.setColor(1, 1, 1)
    love.graphics.print("LÖVE2D MCP Demo - Bouncing Balls", 10, 10)
    love.graphics.print("MCP Server: localhost:12345", 10, 30)
    love.graphics.print("Objects: " .. getObjectCount(), 10, 50)
    love.graphics.print("Player state: " .. player.state, 10, 70)

    -- IMPORTANT: this must be the last line of love.draw() so any pending
    -- screenshot request captures the fully-rendered frame.
    mcp_bridge.captureIfPending()
end

function getObjectCount()
    local count = 0
    for _ in pairs(objects) do
        count = count + 1
    end
    return count
end

function love.quit()
    mcp_bridge.shutdown()
end
