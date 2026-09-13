# LÖVE2D MCP Server

A Model Context Protocol (MCP) server that enables AI assistants to interact with running LÖVE2D games in real time: introspect state, simulate keyboard/mouse input so the AI can actually play, capture screenshots, execute Lua code, and receive push notifications when the game state changes.

Fork/extension of [shayarnett/love2d-mcp](https://github.com/shayarnett/love2d-mcp) with real-time play capabilities and a more robust TCP client.

## Features

- **Real-time introspection** — query game objects, positions, properties, and state
- **AI-driven input** — simulate keyboard and mouse so the AI can move, attack, and play the game
- **Screenshots** — capture the running window as a PNG the AI can see
- **Dynamic code execution** — run Lua code inside the live game context
- **Push notifications** — the game pushes `state_changed` events when anything changes; no polling needed
- **Hot-reload** — reload a Lua file from disk into the running game without restarting it
- **Robust transport** — FIFO command queue, ordered 1:1 responses, auto-reconnect, no listener leaks
- **Proper error reporting** — every tool returns `isError: true` with a descriptive message on failure

## Architecture

```
┌─────────────┐ stdio  ┌─────────────┐   TCP    ┌─────────────┐
│ MCP Client  │◄──────►│  MCP Server │◄────────►│  LÖVE2D     │
│ (Claude,    │        │ (Node/TS)   │  JSON-L   │  Game (Lua) │
│  Cursor,    │        │ build/      │  per line │  + bridge   │
│  OpenCode)  │        └─────────────┘           └─────────────┘
└─────────────┘        stdio uses MCP      TCP uses JSON each line,
                        (newline-delimited)        1 response per command
```

- **MCP Server**: Node.js/TypeScript server speaking the MCP protocol over stdio
- **LÖVE2D Bridge**: small Lua TCP server embedded in the game (`game/mcp_bridge.lua`)
- **Communication**: JSON per line over TCP; the game replies in strict FIFO order
- **Real-time push**: subscribed clients receive `state_changed` events automatically

## Requirements

- Node.js 18+ and npm
- LÖVE2D 11.0+ ([download here](https://love2d.org))
- Git (optional, for cloning)

## Setup

```bash
git clone <your-repo-url> love2d-mcp
cd love2d-mcp
npm install
npm run build
```

The compiled server lives at `build/index.js`. Run it directly (`node build/index.js`) or via `npm start`.

## Quick Start

### 1. Start the example game

```bash
love game/
```

A window opens and the game starts a TCP bridge on port `12345`. Use port `12345` in your own game too, or change `LOVE2D_PORT` at the top of `src/index.ts`.

### 2. Connect a client

With the MCP Inspector:

```bash
npx @modelcontextprotocol/inspector node build/index.js
```

In a config file for Claude/Cursor/OpenCode-style clients:

```json
{
  "mcpServers": {
    "love2d": {
      "command": "node",
      "args": ["/path/to/love2d-mcp/build/index.js"]
    }
  }
}
```

## Available MCP Tools

### `get_objects`

Lists all objects in the current game scene, or gets one specific object
if you pass an id. Replaces the old separate `list_objects` /
`get_object` tools — same underlying query, with or without a filter.

**Arguments:**
- `id` (string, optional): the object ID, e.g. `"p1"`. Omit to list every object.

**Returns:** if `id` is omitted, an array of `{id, type, x, y}` for
every game object. If `id` is given, the complete object data
including every property (state, health, x, y, velocity, stocks…).

### `run_lua`

Execute arbitrary Lua code in the game context.

**Arguments:**
- `code` (string): Lua code to execute

**Returns:** the result (string, or table encoded as JSON).

**Available in the code context:** `objects` (all game objects), `love` (full LÖVE2D API), plus standard Lua libs (`math`, `string`, `table`, `pairs`, `ipairs`, …).

```lua
return objects.p1.x
```

### `get_screenshot`

Capture a screenshot of the currently running game window.

**Arguments:** none

**Returns:** a PNG image block (base64) that the AI assistant can view. Requires `love.graphics.captureScreenshot` — call `mcp_bridge.captureIfPending()` at the end of the bridge's `love.draw()`.

### `send_input`

Simulate keyboard or mouse input so the AI can control the game.

**Arguments:**
- `type` (string, required): `key_down`, `key_up`, `mouse_move`, `mouse_down`, `mouse_up`
- `key` (string): LÖVE KeyConstant, e.g. `"left"`, `"space"`, `"a"` (for key events)
- `duration` (number): optional, auto-release the key after N seconds for `key_down`
- `x`, `y` (number): target position for `mouse_move`
- `button` (number): `1` = left, `2` = right, `3` = middle (for mouse buttons)

**Returns:** `{ok: true}` on success.

**Important:** the game must read input through the bridge — `mcp_bridge.isDown("left")` instead of `love.keyboard.isDown("left")` — so real keyboard input and AI input coexist (see the example in `game/main.lua`).

### `watch_game_state`

Subscribe to real-time updates. Every time something changes (position, health, state, …), the game pushes a `state_changed` notification to the AI automatically — no polling.

**Arguments:** none

**Returns:** `{ok: true, message: "subscribed to state_changed events"}`.

### `unwatch_game_state`

Stop receiving state-change notifications.

**Arguments:** none

**Returns:** `{ok: true, message: "unsubscribed"}`.

### `reload_code`

Hot-reload a Lua file from disk into the running game. **LÖVE does not do this on its own** — editing a `.lua` file while the game is running has zero effect until you restart the process, unless you call this tool.

**Arguments:**
- `file` (string, optional): path relative to the game's source folder. Defaults to `"main.lua"`.

**Returns:** `{ok: true, message: "reloaded main.lua"}` on success.

**How it works:** re-reads and re-executes the file, then calls the freshly-defined `love.load()` again — this behaves like restarting the level with the new code, not a state-preserving patch. Most game state lives in `local` variables that get re-created when the file's top-level code runs again, so expect a reset (e.g. entities repositioned to their initial values), not a seamless in-place edit. `mcp_bridge.init()` is safe to call twice — it detects the server is already listening and skips re-binding the port instead of erroring.

## Real-Time State Watching

Instead of the AI repeatedly asking "what changed?", the game pushes updates itself:

- The bridge compares the current state snapshot against the previous one each frame (`mcp_bridge.checkAndPushStateChanges()`).
- When something differs, it sends `{"event":"state_changed", "data":{...}}` to all subscribed clients.
- The MCP server forwards every push as a standard `notifications/message` MCP notification, so the AI receives it the moment it happens — regardless of whether a command is pending.
- Pushes never corrupt command responses: the FIFO command queue guarantees each response is matched to the right request 1:1, even under heavy push traffic (tested with 2000+ pushes landing while commands were in flight).

## Integrating with Your Own Game

1. Copy `game/mcp_bridge.lua` to your game directory.

2. In `main.lua`:

```lua
local mcp_bridge = require("mcp_bridge")

function love.load()
    mcp_bridge.init(12345)
    mcp_bridge.setObjectGetter(function() return objects end)
end

function love.update(dt)
    mcp_bridge.update()          -- handles commands + pushes state changes
    -- your game logic; read AI+real input via:
    --   mcp_bridge.isDown("left"), mcp_bridge.mouseIsDown(1)
end

function love.draw()
    -- draw your game...
    mcp_bridge.captureIfPending() -- end of draw, so AI screenshots see the frame
end

function love.quit()
    mcp_bridge.shutdown()
end
```

3. Fill the object table with the properties the AI should see (state, health, facing, stocks…). The bridge's simple JSON encoder handles nested tables of strings/numbers/booleans.

## Development

```bash
npm run dev     # tsc --watch, auto-rebuild
npm run build   # compile TypeScript once
npm start       # run the compiled server
```

### Project structure

```
love2d-mcp/
├── src/
│   └── index.ts            # MCP server implementation + TCP client
├── build/
│   └── index.js            # compiled output (what you run)
├── game/
│   ├── main.lua            # example: bouncing balls + an AI/keyboard-controllable
│   │                       # square (idle/walking/attacking states, no real combat)
│   └── mcp_bridge.lua      # Lua TCP bridge module
├── CAMBIOS_TIEMPO_REAL.md  # (Spanish) real-time features walkthrough
├── package.json
├── tsconfig.json
└── README.md
```

## Troubleshooting

### Game won't start
- Verify LÖVE2D is installed: `love --version`
- Check for syntax errors in the Lua files

### MCP connection fails
- Make sure the game is running **before** starting the MCP server (the server connects to port 12345 lazily on first command)
- Check port 12345 isn't already in use; look for "MCP Bridge listening" in the game console

### AI tools error with "argument 'x' (string|number) is required"
- That tool requires at least one argument; pass it via the schema shown in `tools/list`

### Screenshot not working
- Call `mcp_bridge.captureIfPending()` at the very end of `love.draw()`

## License

MIT — see [LICENSE](LICENSE).

## Acknowledgments

- Original base: [shayarnett/love2d-mcp](https://github.com/shayarnett/love2d-mcp)
- [Model Context Protocol](https://modelcontextprotocol.io/)
- [LÖVE2D](https://love2d.org/)