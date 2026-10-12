# Director mode API

Director mode runs an HTTP server and a WebSocket server on your Mac. The built-in web page uses them, and you can write your own client with the protocol below.

## Ports

| Service | Default port | Set in |
|---|---|---|
| HTTP (the built-in web page) | `7575` | Settings → Director → Advanced (`1024`–`65534`) |
| WebSocket | `7576` (HTTP port + 1) | Automatic |

## Connecting

1. Get the access code: it is shown in **Settings → Advanced**, and it is the part after `#` in the Director link and QR code (`http://192.168.1.42:7575/#k7mpq2xa`).
2. Open a WebSocket to `ws://<mac-address>:<websocket-port>`, for example `ws://192.168.1.42:7576`.
3. Within 5 seconds, send the code as the first frame: `{"type":"auth","text":"<code>"}`. A wrong or missing code closes the connection with code `1008`; after 5 wrong codes, your address is refused for a minute. When the code is turned off in Settings, send nothing and go to step 4.
4. Send commands. While a script is active, Takeline sends its state about 10 times per second.

By default only devices on the local network may connect, browsers must open the socket from Takeline's own page, and at most 5 clients are connected at once. Traffic is not encrypted: use Director mode on networks you trust. See [SECURITY.md](../SECURITY.md).

## Commands (client → Takeline)

### `setText`: read a new script

```json
{ "type": "setText", "text": "Welcome everyone to today's live stream..." }
```

Opens the prompter with this script in word tracking mode, as the **Go** button of the web page does. The user's own script and file are left as they were.

### `updateText`: edit the unread part

```json
{
  "type": "updateText",
  "text": "Welcome everyone to today's live stream We changed the rest of the script...",
  "readCharCount": 42
}
```

Replaces the script while keeping the reader's position. Set `readCharCount` to the latest `highlightedCharCount` received; keep the text before that offset unchanged and edit only what follows.

### `stop`

```json
{ "type": "stop" }
```

Stops reading and closes the prompter.

## State (Takeline → client)

```json
{
  "words": ["Welcome", "everyone", "to", "today's", "live", "stream"],
  "highlightedCharCount": 24,
  "totalCharCount": 120,
  "isActive": true,
  "isDone": false,
  "isListening": true,
  "fontColor": "#F5F5F7",
  "cueColor": "#F5F5F7",
  "lastSpokenText": "Welcome everyone to today's",
  "audioLevels": [0.12, 0.34, 0.08]
}
```

| Field | Type | Meaning |
|---|---|---|
| `words` | `string[]` | The script split into words, as displayed. |
| `highlightedCharCount` | `int` | Characters read so far: the read boundary. |
| `totalCharCount` | `int` | Characters in the whole script. |
| `isActive` | `bool` | The prompter is open with a script. |
| `isDone` | `bool` | The whole script has been read. |
| `isListening` | `bool` | The microphone is on. |
| `fontColor`, `cueColor` | `string` | CSS colors of the text and of [cues], from the user's settings. |
| `lastSpokenText` | `string` | The last words recognized. |
| `audioLevels` | `double[]` | Recent audio levels from 0 to 1, for a waveform. |

When the prompter isn't open, Takeline sends a frame with `isActive: false` and empty arrays.

## Example client (Python)

```python
import asyncio, json, sys
import websockets

HOST = "192.168.1.42"
WS_PORT = 7576
CODE = sys.argv[1]  # from Settings → Advanced

async def director():
    async with websockets.connect(f"ws://{HOST}:{WS_PORT}") as ws:
        await ws.send(json.dumps({"type": "auth", "text": CODE}))
        await ws.send(json.dumps({"type": "setText", "text": "Hello everyone, welcome to the show."}))
        async for message in ws:
            state = json.loads(message)
            if state["totalCharCount"]:
                print(f"{state['highlightedCharCount'] / state['totalCharCount']:.0%}")
            if state["isDone"]:
                break
        await ws.send(json.dumps({"type": "stop"}))

asyncio.run(director())
```
