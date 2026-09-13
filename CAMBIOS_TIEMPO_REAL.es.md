# Cambios agregados sobre shayarnett/love2d-mcp

Este proyecto es una versión modificada del love2d-mcp original, con tres
piezas nuevas para permitir que la IA juegue en tiempo real:

## 1. Screenshots (`get_screenshot`)
- `game/mcp_bridge.lua`: nueva función `captureIfPending()` — hay que
  llamarla al FINAL de `love.draw()`, después de dibujar todo.
- Usa `love.graphics.captureScreenshot()` (async) + `love.data.encode`
  para mandar la imagen como PNG en base64 por el socket TCP.
- Del lado del servidor MCP (`src/index.ts`), la herramienta
  `get_screenshot` devuelve la imagen directamente como bloque `image`,
  así que Claude/Cursor/etc. la puede "ver" de verdad.

## 2. Input virtual (`send_input`)
- En vez de simular teclas del sistema operativo (frágil, requiere la
  ventana enfocada, permisos, etc), el juego debe leer
  `mcp_bridge.isDown("left")` en vez de `love.keyboard.isDown("left")`.
  Esto mezcla input real del teclado Y comandos de la IA sin conflicto.
- Comandos soportados: `key_down` (con `duration` opcional para
  auto-soltar la tecla), `key_up`, `mouse_move`, `mouse_down`, `mouse_up`.
- Mirá `game/main.lua` — el "player" de ejemplo ya usa este patrón.

## 3. Tiempo real (`watch_game_state` / `unwatch_game_state`)
- Esto es lo más importante para lo que pediste: en vez de que la IA
  pregunte "¿qué pasó?" una y otra vez (polling), el JUEGO avisa solo
  cuando algo cambia.
- `mcp_bridge.checkAndPushStateChanges()` corre cada frame dentro de
  `mcp_bridge.update()`: compara el estado actual contra el anterior, y
  si cambió algo, lo empuja inmediatamente a todos los clientes
  suscritos — sin esperar que pregunten.
- Del lado del servidor MCP, `watch_game_state` reenvía cada uno de esos
  empujones como una notificación MCP (`server.notification`), así que
  la IA recibe el evento apenas ocurre, en el mismo estilo que los MCP
  de Godot que mencionaste.

## Qué falta / qué probar
Este código está escrito y verificado en sintaxis (Lua y TypeScript
compilan sin errores), pero **no fue probado corriendo LÖVE de verdad**
porque este entorno no tiene el motor instalado. Antes de darlo por
terminado, hay que:

1. Correr `love game/` y confirmar que la ventana abre y el bridge
   escucha en el puerto 12345.
2. Probar cada comando nuevo con `npx @modelcontextprotocol/inspector
   node build/index.js` (igual que el README original).
3. Ajustar `checkAndPushStateChanges()` si el JSON encoder casero
   (al final de `mcp_bridge.lua`) tiene problemas con las tablas que
   tenga tu juego real — es un encoder simple, no una librería robusta.
4. Para el juego de pelea real: llenar la tabla de cada personaje con
   `health`, `state` (idle/attacking/blocking/hitstun), y lo que haga
   falta — eso es lo que la IA va a "ver" en cada `state_changed`.

Esto es una base sólida y funcional en el papel, pero cualquier ajuste
fino de comportamiento en tiempo real (frecuencia, formato de eventos)
conviene iterarlo con OpenCode mientras lo corrés en tu PC, ya que ahí
sí se puede probar contra el motor real.

## ✅ Probado y confirmado funcionando (no solo en teoría)

Corrí el juego de verdad (LÖVE 11.5 instalado vía apt + Xvfb como pantalla
virtual) y confirmé con pruebas reales:

- `get_screenshot` devuelve un PNG válido de verdad (magic bytes
  `89504e47` confirmados tras decodificar el base64).
- `send_input` con `key_down "left"` movió al jugador de x=400 a x=339.5
  y cambió su estado de "idle" a "walking" dentro del juego en vivo.
- `watch_game_state` empujó automáticamente varios eventos `state_changed`
  con las posiciones actualizadas de las bolitas, sin que el cliente
  preguntara nada — confirmado el modelo de tiempo real por push.

Lo único que no se pudo probar acá es el rendimiento visual real en tu
PC (Celeron/4GB), porque este entorno usa renderizado por software sin
GPU real.

## 4. Referencias que sobreviven al reload (mutación en el lugar)

Esto era el pendiente de la última sesión: qué pasa cuando algo guarda
una referencia a un módulo (`local Player = require("modules.player")`)
y ese algo no forma parte de lo que `reload_code` vuelve a ejecutar —
antes, esa referencia se quedaba apuntando para siempre a la versión
vieja, aunque el código en disco ya estuviera actualizado.

**Ya está implementado y probado con el escenario exacto descrito.**
`mcp_bridge.clearModuleCache()` ahora instala temporalmente un
`require()` que, quien capturó una tabla de módulo, cuando ese módulo
se vuelve a pedir, en vez de reemplazar la tabla vieja por una nueva
(que dejaría a las referencias externas apuntando a la basura), vacía
la tabla vieja y le mete el contenido nuevo adentro — misma identidad,
contenido actualizado. Cualquier referencia externa guardada de
antemano lo ve automáticamente, sin que la IA tenga que perseguirla y
reasignarla a mano con `run_lua`.

Prueba real hecha (proyecto de prueba aparte, con LÖVE 11.5 real vía
Xvfb, no simulado): un sistema externo guardó `require("modules.player")`
antes del reload; se editó `modules/player.lua` en disco (io.open, como
haría cualquier editor externo); se llamó `reload_code`; la referencia
externa mostró el código nuevo y la identidad de tabla (dirección de
memoria) fue idéntica antes y después — confirmado, no solo en teoría.

**Límite que sigue en pie (y que hay que tener claro):** esto arregla
referencias a MÓDULOS, no a INSTANCIAS ya creadas antes del reload
(ej. `enemigo.objetivo = player` donde `player = Player.new()`). Una
instancia es una tabla aparte que main.lua recrea de cero al
reejecutarse; mutar la clase Player en el lugar no reescribe instancias
que ya existían. Para ese caso puntual: seguir usando `run_lua` para
re-apuntar la referencia a mano, o —mejor a largo plazo— rediseñar el
sistema para que guarde un id y busque la instancia en una tabla
central en vez de guardarse la tabla misma directamente.

## 5. Objetos de motor (física, audio, canvas) — el caso que SÍ es
##    imposible de mutar directamente, y cómo se rodea con `handle.lua`

Investigado a fondo (foros de LÖVE, y las librerías de hot-reload más
usadas de la comunidad: lurker, LuaHotLoader, lua-hot-reload): NINGUNA
de ellas resuelve este caso, ni siquiera las más avanzadas. No es que
nos faltara una técnica mejor — es un límite real del lenguaje: un
cuerpo de `love.physics`, un `Source` de `love.audio`, o un
`Canvas`/`Image`/`Shader` de `love.graphics` son `userdata` (objetos
hechos en C por dentro de LÖVE), no tablas Lua. `mutateModuleInPlace`
solo puede vaciar y rellenar TABLAS — con userdata no hay nada que
"vaciar", así que si algo guarda ese objeto directamente y luego se
recrea, la referencia vieja queda huérfana. Se probó y confirmó esto
con un Canvas real: la referencia externa se quedó pegada al Canvas
viejo mientras el juego ya usaba uno nuevo.

**La solución real (probada, no solo teórica): `game/handle.lua`.**
En vez de guardar el objeto de motor directamente, se envuelve en un
`Handle` — una tabla Lua normal que por dentro apunta al objeto real.
Como el Handle SÍ es una tabla, se puede re-apuntar (`Handle.rebind` /
`Handle.rebindByName`) sin cambiar su identidad — así que cualquier
sistema externo que haya guardado el Handle (nunca el objeto crudo)
nunca pierde la referencia, y además lo sigue usando con la sintaxis
normal (`handle:metodo(...)`) sin darse cuenta de que por dentro cambió.

Prueba real hecha: un sistema externo guardó un `Handle` que envolvía
un Canvas; se recreó el Canvas real y se hizo `Handle.rebindByName`;
la referencia externa mantuvo su identidad de tabla, el objeto de
adentro sí cambió al nuevo, y siguió funcionando con `:renderTo(...)`
sin ningún ajuste adicional.

**Costo honesto de esto (no es gratis ni automático):** hay que decidir
envolver los objetos de motor en `Handle` desde que se crean (no se
puede "arreglar" retroactivamente algo que ya se guardó crudo en otro
lado), y el código de reload tiene que saber qué Handle re-apuntar a
qué objeto nuevo — por eso `Handle.new(objeto, "nombre")` los registra
en `Handle.registry`, para que baste con `Handle.rebindByName("nombre",
nuevoObjeto)` en vez de rastrear la referencia a mano cada vez. Es un
patrón de arquitectura a adoptar en el juego, no algo que `reload_code`
haga solo por detrás sin que el proyecto esté armado para usarlo.

## 6. Timeout de comandos + número de pedido (`_reqId`) — respuestas
##    tardías ya no se pegan al comando equivocado

Se encontraron y arreglaron dos huecos reales en el manejo de errores:

**a) Captura de pantalla podía tumbar el juego.** El paso de
codificación (PNG → base64) no estaba protegido con `pcall`, y corría
fuera del ciclo normal de comandos que sí lo está. Se envolvió en su
propio `pcall`; si falla, el cliente recibe un `{error: ...}` en vez de
crashear el proceso. Probado forzando un fallo real de `love.data.encode`.

**b) El servidor MCP no tenía límite de espera por comando.** Si el
juego se colgaba o dejaba de responder sin cerrar la conexión, la
llamada de la IA se quedaba esperando para siempre, sin ningún error.
Se agregó un timeout configurable (15s por defecto) por comando.

**El problema que esto introdujo al principio, y cómo se arregló de
verdad:** el protocolo no tenía forma de saber a qué comando
correspondía cada respuesta más que el orden de llegada. Si un comando
vencía por timeout y el juego respondía tarde, esa respuesta tardía se
le podía pegar por error al SIGUIENTE comando que ya estaba en vuelo.
Se arregló agregando un número de pedido (`_reqId`) a cada comando que
manda el cliente MCP; el bridge de LÖVE devuelve ese mismo número en su
respuesta (tanto en las síncronas como en la asíncrona de captura de
pantalla, donde cada cliente en espera puede tener un `_reqId`
distinto). Ahora solo hay UN comando "en vuelo" a la vez, identificado
por su `_reqId` — si llega una respuesta cuyo `_reqId` no coincide con
el comando en vuelo actual (porque ya venció por timeout y se
descartó), se **descarta silenciosamente** en vez de resolvérsela al
comando equivocado.

Nota: se usó el nombre de campo `_reqId` y no `id`, porque `get_objects`
ya usa `id` para su propio dato (el id del objeto a buscar) — reusar el
mismo nombre los habría pisado entre sí.

Probado en dos niveles:
- Con un servidor falso en Node que simula un comando lento (responde
  después de que el timeout ya lo dio por vencido) seguido de un
  comando normal: se confirmó que el comando normal recibe su propia
  respuesta correcta, y que la respuesta tardía del primero se descarta
  sola cuando por fin llega, sin afectar nada más.
- Con LÖVE real corriendo el bridge de verdad: tres pedidos
  concurrentes con distinto `_reqId` (un `get_objects` y dos
  `get_screenshot` simultáneos) devolvieron cada uno su propio `_reqId`
  correcto, sin mezclarse.
