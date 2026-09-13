#!/usr/bin/env node

import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import {
  CallToolRequestSchema,
  ListToolsRequestSchema,
} from "@modelcontextprotocol/sdk/types.js";
import { z } from "zod";
import net from "net";

const LOVE2D_HOST = "localhost";
const LOVE2D_PORT = 12345;

// TCP client to communicate with LÖVE2D game
class Love2DClient {
  private client: net.Socket | null = null;
  private buffer = "";
  // Comandos que todavía no se mandaron por el cable (esperando su turno).
  private waitingQueue: { command: any; resolve: (v: any) => void; reject: (e: any) => void; timeoutMs: number }[] = [];
  // El único comando que sí está "en vuelo" ahora mismo -- mandado, esperando
  // su respuesta. Se identifica por 'id', no por posición en una cola, así
  // que una respuesta tardía de un comando YA vencido por timeout se puede
  // reconocer (por su id) y descartar en vez de confundirse con la
  // respuesta del comando que está en vuelo en este momento.
  private inFlight: { id: number; command: any; resolve: (v: any) => void; reject: (e: any) => void; timer: NodeJS.Timeout } | null = null;
  private nextRequestId = 1;
  private stateListeners: ((data: any) => void)[] = [];

  private connect(): Promise<void> {
    return new Promise((resolve, reject) => {
      this.client = net.createConnection({ host: LOVE2D_HOST, port: LOVE2D_PORT }, () => {
        console.error("Connected to LÖVE2D game");
        this.client!.on("data", (chunk: Buffer) => this.onData(chunk));
        this.client!.on("close", () => {
          console.error("LÖVE2D connection closed");
          this.client = null;
          this.failPending(new Error("LÖVE2D connection closed"));
        });
        this.client!.on("error", (err) => {
          console.error("TCP connection error:", err);
          this.client = null;
          this.failPending(err);
          reject(err);
        });
        resolve();
      });
    });
  }

  // Rechaza el comando en vuelo (si hay uno) y todo lo que estaba
  // esperando turno. Se llama cuando el socket muere, para que ninguna
  // promesa se quede esperando para siempre una respuesta que ya nunca
  // va a llegar (y para que ensureConnected() pueda reconectar limpio).
  private failPending(err: Error): void {
    this.buffer = "";
    if (this.inFlight) {
      clearTimeout(this.inFlight.timer);
      this.inFlight.reject(err);
      this.inFlight = null;
    }
    const queue = this.waitingQueue;
    this.waitingQueue = [];
    for (const item of queue) {
      item.reject(err);
    }
  }

  private async ensureConnected(): Promise<void> {
    if (!this.client || this.client.destroyed) {
      this.client = null;
      await this.connect();
    }
  }

  // timeoutMs cubre el caso de que el juego se cuelgue o no conteste un
  // comando sin cerrar el socket -- sin esto, la llamada de la IA se
  // quedaba esperando para siempre sin ningún error. Cada comando lleva
  // un 'id' propio que el juego devuelve tal cual en su respuesta; si esa
  // respuesta llega DESPUÉS de que el timeout ya lo dio por vencido, se
  // reconoce por el id (que ya no coincide con el comando en vuelo actual)
  // y se descarta -- nunca se le atribuye al comando que esté en vuelo en
  // ese momento. Ver onData() más abajo.
  async sendCommand(command: any, timeoutMs = 15000): Promise<any> {
    await this.ensureConnected();
    return new Promise((resolve, reject) => {
      this.waitingQueue.push({ command, resolve, reject, timeoutMs });
      this.pump();
    });
  }

  // Manda el siguiente comando en espera, si no hay ninguno en vuelo
  // todavía. Solo un comando viaja por el cable a la vez.
  private pump(): void {
    if (this.inFlight) return;
    const next = this.waitingQueue.shift();
    if (!next) return;

    const id = this.nextRequestId++;
    // Nombre de campo en el cable: "_reqId", NO "id" -- varios comandos
    // (get_objects) ya usan "id" para sus propios datos (el id del
    // objeto a buscar), así que reusar ese nombre para el número de
    // pedido los pisaría entre sí.
    const payload = { ...next.command, _reqId: id };

    const timer = setTimeout(() => {
      // Si para cuando dispara el timer YA se resolvió normalmente (o
      // failPending ya limpió todo), this.inFlight ya no es este id --
      // en ese caso no hacer nada, para no pisar un estado más nuevo.
      if (this.inFlight && this.inFlight.id === id) {
        this.inFlight = null;
        next.reject(
          new Error(
            `Timed out after ${next.timeoutMs}ms waiting for a reply from the LÖVE game for command '${next.command.command}' (request id ${id}). Is the game still running and responsive? If it replies later, that late reply will now be safely discarded instead of being mismatched to a different command.`
          )
        );
        this.pump();
      }
    }, next.timeoutMs);

    this.inFlight = { id, command: next.command, resolve: next.resolve, reject: next.reject, timer };

    try {
      this.client!.write(JSON.stringify(payload) + "\n");
    } catch (err) {
      clearTimeout(timer);
      this.inFlight = null;
      next.reject(err);
      this.pump();
    }
  }

  // Lector de línea única: separa los datos de TCP en líneas. Los
  // eventos de state_changed (sin id, no solicitados) van a los
  // suscriptores de watch; cualquier otra cosa se empareja por 'id'
  // contra el comando en vuelo. Si el id no coincide (respuesta huérfana
  // / tardía de un comando ya vencido por timeout), se descarta sin
  // tocar el comando que esté en vuelo ahora -- esto es justo lo que
  // evita que una respuesta tardía se le pegue al comando equivocado.
  private onData(chunk: Buffer): void {
    this.buffer += chunk.toString();
    let nl: number;
    while ((nl = this.buffer.indexOf("\n")) !== -1) {
      const line = this.buffer.slice(0, nl).replace(/\r$/, "");
      this.buffer = this.buffer.slice(nl + 1);
      if (!line.trim()) continue;
      let msg: any;
      try {
        msg = JSON.parse(line);
      } catch {
        continue;
      }
      if (msg && msg.event === "state_changed") {
        for (const cb of this.stateListeners) {
          try {
            cb(msg.data);
          } catch {
            // listener errors must not kill the reader
          }
        }
        continue;
      }

      if (this.inFlight && msg && msg._reqId === this.inFlight.id) {
        const item = this.inFlight;
        this.inFlight = null;
        clearTimeout(item.timer);
        item.resolve(msg);
        this.pump();
      } else {
        // Respuesta huérfana: o llegó tarde (el comando al que
        // corresponde ya se dio por vencido con timeout), o no hay
        // ningún comando en vuelo ahora mismo. Se descarta a propósito
        // -- NUNCA se le asigna al comando que esté en vuelo en este
        // momento, que es justo el bug que había antes.
        console.error(`Discarding orphaned/late reply from LÖVE game (_reqId=${msg && msg._reqId}): ${line}`);
      }
    }
  }

  // Subscribe to the "watch_game_state" firehose. LÖVE pushes a
  // state_changed event over this same socket every time something
  // changes (see checkAndPushStateChanges in mcp_bridge.lua), and we
  // forward each one to the AI as an MCP notification. This is what
  // gives the AI a real-time feed instead of it having to poll.
  onStateChanged(callback: (data: any) => void): void {
    this.stateListeners.push(callback);
  }

  disconnect(): void {
    if (this.client) {
      this.client.end();
      this.client = null;
    }
  }
}

const love2dClient = new Love2DClient();

// Create MCP server
const server = new Server(
  {
    name: "love2d-mcp",
    version: "1.0.0",
  },
  {
    capabilities: {
      tools: {},
      logging: {},
    },
  }
);

// List available tools
server.setRequestHandler(ListToolsRequestSchema, async () => {
  return {
    tools: [
      {
        name: "get_objects",
        description:
          "Get objects from the current game scene. Omit 'id' to list every object " +
          "(id, type, x, y for each). Pass 'id' to get full detail on just that one object " +
          "instead. Replaces what used to be two separate tools (list_objects / get_object) " +
          "since they were the same underlying query with or without a filter.",
        inputSchema: {
          type: "object",
          properties: {
            id: {
              type: "string",
              description: "Optional. The ID of a specific object to retrieve. Omit to list all objects.",
            },
          },
        },
      },
      {
        name: "run_lua",
        description: "Execute arbitrary Lua code in the game context",
        inputSchema: {
          type: "object",
          properties: {
            code: {
              type: "string",
              description: "The Lua code to execute",
            },
          },
          required: ["code"],
        },
      },
      {
        name: "get_screenshot",
        description:
          "Capture a screenshot of the currently running game window as a base64 PNG image",
        inputSchema: {
          type: "object",
          properties: {},
        },
      },
      {
        name: "send_input",
        description:
          "Simulate keyboard or mouse input in the game, letting the AI actually play (move, attack, click, etc). " +
          "type must be one of: key_down, key_up, mouse_move, mouse_down, mouse_up.",
        inputSchema: {
          type: "object",
          properties: {
            type: {
              type: "string",
              enum: ["key_down", "key_up", "mouse_move", "mouse_down", "mouse_up"],
            },
            key: { type: "string", description: "LÖVE KeyConstant, e.g. 'left', 'space', 'a'" },
            duration: { type: "number", description: "Optional: auto-release the key after N seconds" },
            x: { type: "number" },
            y: { type: "number" },
            button: { type: "number", description: "1 = left, 2 = right, 3 = middle" },
          },
          required: ["type"],
        },
      },
      {
        name: "watch_game_state",
        description:
          "Subscribe to real-time game state updates. The game will push a notification " +
          "every time something changes (position, health, animation state, etc), instead of " +
          "you having to repeatedly call get_objects. Call unwatch_game_state to stop.",
        inputSchema: {
          type: "object",
          properties: {},
        },
      },
      {
        name: "unwatch_game_state",
        description: "Stop receiving real-time game state update notifications.",
        inputSchema: {
          type: "object",
          properties: {},
        },
      },
      {
        name: "list_lua_files",
        description:
          "List every .lua file in the game project. Real games are usually split across " +
          "several files (main.lua plus modules), so check this before deciding what to " +
          "edit and pass to reload_code — don't assume everything lives in main.lua.",
        inputSchema: {
          type: "object",
          properties: {
            dir: {
              type: "string",
              description: "Subfolder to scan, relative to the game's source folder. Defaults to the project root.",
            },
          },
        },
      },
      {
        name: "reload_code",
        description:
          "Hot-reload a Lua file from disk into the running game (default 'main.lua'). " +
          "LÖVE does NOT pick up file edits on its own — without this tool, changes you " +
          "write to disk have zero effect until the game is restarted. This clears the " +
          "require() cache for every game module first (so edits to files required by " +
          "main.lua are picked up too, not just main.lua itself), then re-runs the file " +
          "and calls love.load() again — it behaves like restarting the level with the " +
          "new code rather than a state-preserving patch. Module tables themselves are " +
          "reloaded via in-place mutation (same table identity, new contents), so any " +
          "other system that already did `local X = require(...)` and kept that reference " +
          "will see the updated code automatically — you do NOT need to manually re-point " +
          "those. This does NOT apply to instances created from a module before the reload " +
          "(e.g. an object made with Class.new()) — those keep their old field values and " +
          "identity; if something else is holding a reference to a specific pre-reload " +
          "instance, use run_lua to re-point it manually, or design around ids/lookup " +
          "tables instead of raw instance references.",
        inputSchema: {
          type: "object",
          properties: {
            file: {
              type: "string",
              description: "Path relative to the game's source folder. Defaults to 'main.lua'.",
            },
          },
        },
      },
    ],
  };
});

// Handle tool calls
function errorResult(message: string) {
  return {
    content: [{ type: "text", text: `Error: ${message}` }],
    isError: true,
  };
}
server.setRequestHandler(CallToolRequestSchema, async (request) => {
  const { name, arguments: args } = request.params;

  try {
    switch (name) {
      case "get_objects": {
        const objectId =
          args && typeof (args as any).id === "string" && (args as any).id.trim()
            ? (args as any).id
            : undefined;
        const response = await love2dClient.sendCommand({
          command: "get_objects",
          id: objectId,
        });
        if (response && response.error) {
          return errorResult(response.error);
        }
        return {
          content: [
            {
              type: "text",
              text: JSON.stringify(response, null, 2),
            },
          ],
        };
      }

      case "run_lua": {
        if (!args || typeof (args as any).code !== "string" || !(args as any).code.trim()) {
          return errorResult("argument 'code' (string) is required");
        }
        const code = (args as any).code;
        const response = await love2dClient.sendCommand({
          command: "run_lua",
          code: code,
        });
        if (response && response.error) {
          return errorResult(response.error);
        }
        return {
          content: [
            {
              type: "text",
              text: JSON.stringify(response, null, 2),
            },
          ],
        };
      }

      case "get_screenshot": {
        const response = await love2dClient.sendCommand({ command: "get_screenshot" });
        if (!response || typeof response.screenshot !== "string" || !response.screenshot) {
          return errorResult("no screenshot received from the game");
        }
        return {
          content: [
            {
              type: "image",
              data: response.screenshot,
              mimeType: "image/png",
            },
          ],
        };
      }

      case "send_input": {
        if (!args || typeof (args as any).type !== "string" || !(args as any).type.trim()) {
          return errorResult("argument 'type' (string) is required");
        }
        const input = args as any;
        const response = await love2dClient.sendCommand({
          command: "send_input",
          type: input.type,
          key: input.key,
          duration: input.duration,
          x: input.x,
          y: input.y,
          button: input.button,
        });
        if (response && response.error) {
          return errorResult(response.error);
        }
        return {
          content: [{ type: "text", text: JSON.stringify(response, null, 2) }],
        };
      }

      case "watch_game_state": {
        // Forward every push from the game as an MCP notification, so
        // the AI receives updates as they happen instead of polling.
        love2dClient.onStateChanged((data) => {
          try {
            server.notification({
              method: "notifications/message",
              params: {
                level: "info",
                logger: "love2d-mcp",
                data: { event: "game_state_changed", ...data },
              },
            });
          } catch {
            // a notification failure must never kill the server
          }
        });
        const response = await love2dClient.sendCommand({ command: "watch_game_state" });
        if (response && response.error) {
          return errorResult(response.error);
        }
        return {
          content: [{ type: "text", text: JSON.stringify(response, null, 2) }],
        };
      }

      case "unwatch_game_state": {
        const response = await love2dClient.sendCommand({ command: "unwatch_game_state" });
        if (response && response.error) {
          return errorResult(response.error);
        }
        return {
          content: [{ type: "text", text: JSON.stringify(response, null, 2) }],
        };
      }

      case "list_lua_files": {
        const dir = (args as any)?.dir;
        const response = await love2dClient.sendCommand({ command: "list_lua_files", dir });
        if (response && response.error) {
          return errorResult(response.error);
        }
        return {
          content: [{ type: "text", text: JSON.stringify(response, null, 2) }],
        };
      }

      case "reload_code": {
        const file = (args as any)?.file;
        const response = await love2dClient.sendCommand({ command: "reload_code", file });
        if (response && response.error) {
          return errorResult(response.error);
        }
        return {
          content: [{ type: "text", text: JSON.stringify(response, null, 2) }],
        };
      }

      default:
        throw new Error(`Unknown tool: ${name}`);
    }
  } catch (error) {
    return {
      content: [
        {
          type: "text",
          text: `Error: ${error instanceof Error ? error.message : String(error)}`,
        },
      ],
      isError: true,
    };
  }
});

// Start the server
async function main() {
  const transport = new StdioServerTransport();
  await server.connect(transport);
  console.error("LÖVE2D MCP server running on stdio");
}

main().catch((error) => {
  console.error("Fatal error:", error);
  process.exit(1);
});
