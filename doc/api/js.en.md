# JavaScript API Reference

[中文版本](js.zh.md) · [Comic Source Development Guide](comic_source.en.md) · [Documentation Index](../README.en.md#developer-api)

This document describes the JavaScript extension runtime API for VeneraNext. Function names and invocations follow [assets/init.js](../../assets/init.js) and the host implementation in [js_engine.dart](../../lib/foundation/js_engine.dart).

## Runtime Environment

Source scripts run within the QuickJS engine, supporting standard ES2020 JavaScript features along with application-specific APIs documented here. The environment does not provide Node.js native modules or browser DOM globals. For cross-bridge data exchange, use standard primitive types (strings, numbers, booleans, plain objects, and arrays); use `ArrayBuffer` for binary data.

## Network

All network functions return Promises. Transport errors throw exceptions. HTTP 4xx and 5xx responses resolve to standard response objects; extensions must inspect `status` directly.

| Method | Returns | Description |
|---|---|---|
| `Network.get(url, headers?, extra?)` | `Promise<{status, headers, body}>` | Sends a GET request; `body` is a string |
| `Network.post(url, headers?, data?, extra?)` | `Promise<{status, headers, body}>` | Sends a POST request |
| `Network.put(url, headers?, data?, extra?)` | `Promise<{status, headers, body}>` | Sends a PUT request |
| `Network.delete(url, headers?, extra?)` | `Promise<{status, headers, body}>` | Sends a DELETE request |
| `Network.patch(url, headers?, data?, extra?)` | `Promise<{status, headers, body}>` | Sends a PATCH request |
| `Network.sendRequest(method, url, headers?, data?, extra?)` | `Promise<{status, headers, body}>` | Sends an arbitrary HTTP method request |
| `Network.fetchBytes(method, url, headers?, data?, extra?)` | `Promise<{status, headers, body: ArrayBuffer}>` | Sends a request and receives the response body as an `ArrayBuffer` |

- `headers`: A plain key-value object of strings.
- `data`: Request body (string, ArrayBuffer, or object). When sending JSON, explicitly call `JSON.stringify` and set `Content-Type: application/json`.
- Setting `headers["cache-time"] = "no"` bypasses the short-term network cache.

### Cookie Management

| Method | Description |
|---|---|
| `new Cookie({name, value, domain?})` | Constructs a Cookie object |
| `Network.setCookies(url, cookies)` | Persists an array of Cookies for the specified URL |
| `Network.getCookies(url)` | Synchronously returns matching Cookies for a URL |
| `Network.deleteCookies(url)` | Deletes stored Cookies for a URL |

### fetch

`fetch(url, {method?, headers?, body?})` wraps basic HTTP requests, returning a Promise that resolves to an object with `ok`, `status`, `statusText`, `headers` (plain object), and async methods `text()`, `json()`, and `arrayBuffer()`.

### WebSocket

`Network.WebSocket.connect(url, headers = {}, options = {})` establishes a general-purpose WebSocket connection.

- `options`:
  - `protocols?: string[]`: Subprotocols.
  - `connectTimeoutMs?: number`: Connection timeout in milliseconds (default 30000).
- Returns a `WebSocketConnection` object:
  - `id` (`string`): Connection identifier.
  - `protocol` (`string`): Selected subprotocol.
  - `closed` (`boolean`): Whether the connection is closed.
  - `send(data: string | ArrayBuffer | ArrayBufferView): Promise<void>`: Sends text or binary frames.
  - `receive(): Promise<string | ArrayBuffer>`: Waits for and receives the next incoming frame (text returns `string`, binary returns `ArrayBuffer`). Only one pending `receive()` is allowed at a time.
  - `close(code = 1000, reason = ""): Promise<void>`: Closes the connection.
- Transport and protocol errors reject their respective Promises. This API provides raw bidirectional transport without built-in reconnection or heartbeat logic.

## HTML Parsing

`new HtmlDocument(htmlString)` parses an HTML string into a DOM tree without executing scripts.

| Member | Description |
|---|---|
| `document.querySelector(selector)` | Returns the first matching `HtmlElement` or `null` |
| `document.querySelectorAll(selector)` | Returns all matching nodes as `HtmlElement[]` |
| `document.getElementById(id)` | Finds an element by ID |
| `document.dispose()` | **Frees native memory**. Call explicitly after extracting necessary data |
| `element.text` | Text content of the element and its children |
| `element.innerHTML` | Inner HTML string of the element |
| `element.attributes` | Attribute map (e.g. `element.attributes["href"]`) |
| `element.children` | Child elements as `HtmlElement[]` |
| `element.parent` / `previousElementSibling` / `nextElementSibling` | Node navigation |

```javascript
const doc = new HtmlDocument('<div class="list"><a href="/item">Title</a></div>');
try {
    const link = doc.querySelector("a");
    const href = link?.attributes["href"];
} finally {
    doc.dispose();
}
```

## Convert: Encoding, Hashing, and Cryptography

All `Convert` functions execute synchronously and operate on `ArrayBuffer` for binary payloads:

| API | Function |
|---|---|
| `Convert.encodeUtf8(text)` / `decodeUtf8(bytes)` | UTF-8 string to/from ArrayBuffer |
| `Convert.encodeGbk(text)` / `decodeGbk(bytes)` | GBK string to/from ArrayBuffer |
| `Convert.encodeBase64(bytes)` / `decodeBase64(text)` | Binary to/from Base64 string |
| `Convert.hexEncode(bytes)` | Binary to hexadecimal string |
| `Convert.md5(bytes)`, `sha1`, `sha256`, `sha512` | Cryptographic hash digests returning ArrayBuffer |
| `Convert.hmac(key, bytes, hash)` | HMAC digest returning ArrayBuffer |
| `Convert.hmacString(key, bytes, hash)` | HMAC digest returning hexadecimal string |
| `Convert.encryptAesEcb(bytes, key)` / `decryptAesEcb(...)` | AES-ECB cipher |
| `Convert.encryptAesCbc(bytes, key, iv)` / `decryptAesCbc(...)` | AES-CBC cipher |
| `Convert.encryptAesCfb(bytes, key, iv, blockSize)` / `decryptAesCfb(...)` | AES-CFB cipher |
| `Convert.encryptAesOfb(bytes, key, blockSize)` / `decryptAesOfb(...)` | AES-OFB cipher |
| `Convert.decryptRsa(bytes, key)` | RSA PKCS#1 decryption with Base64 PKCS#8 private key |
| `Convert.encodeGzip(bytes)` | **Gzip compression**: compresses an ArrayBuffer to a Gzip byte stream |
| `Convert.decodeGzip(bytes)` | **Gzip decompression**: decompresses a Gzip ArrayBuffer to raw bytes |

## Image Handling and Layout Constraints

### ImageLoadingConfig

`comic.onImageLoad` and `comic.onThumbnailLoad` return configuration objects:

| Field | Type | Description |
|---|---|---|
| `url` | `string?` | Image URL; defaults to image key |
| `headers` | `object?` | Custom HTTP headers map |
| `method` | `string?` | HTTP method (default GET) |
| `data` | `any?` | Request body |
| `onResponse(bytes)` | `Function?` | Transforms response ArrayBuffer; supported for both chapter and thumbnail images |
| `modifyImage` | `string?` | Script string defining `function modifyImage(image)` for pixel manipulation; chapter images only |
| `onLoadFailed()` | `Function?` | Retry hook returning a new `ImageLoadingConfig`; chapter images only |

### Header Parsing and User-Agent Fallback Contract

1. **Source UA Priority**: Custom User-Agent headers declared in `headers` take highest precedence.
2. **Case-Insensitive Lookup**: Matches `User-Agent`, `user-agent`, or any casing. If provided, it is strictly preserved without being overwritten by the default UA.
3. **Default Fallback**: If `headers` is omitted or contains no User-Agent, the runtime supplies the default browser identifier (`user-agent: webUA`).
4. **Independent Map**: Output headers are placed in a new, independent mutable map; invalid input types throw explicit exceptions.

### ComicImageLoadTarget Layout Constraints (onImageLoad Only)

`comic.onImageLoad(url, comicId, epId, target)` receives an optional fourth parameter:

- `logicalWidth` (`number | null`): container logical width in dp; reflects width after side-margin deduction when enabled.
- `logicalHeight` (`number | null`): container logical height in dp.
- `devicePixelRatio` (`number`): screen DPR.
- `fit` (`"contain" | "fitWidth" | "fitHeight"`): layout adaptation mode.
- `splitWideImage` (`boolean`): whether dual-page split mode is enabled.
- **`target: null`**: indicates no specific viewport constraints (e.g. Save Original, Copy Original, Share Original, general preloading).

### The `Image` Object (inside `modifyImage`)

| Property / Method | Description |
|---|---|
| `image.width`, `image.height` | Image dimensions |
| `image.copyRange(x, y, width, height)` | Crops a sub-region into a new `Image` |
| `image.copyAndRotate90()` | Rotates the image 90 degrees |
| `image.fillImageAt(x, y, other)` | Pastes another image at given coordinates |
| `image.fillImageRangeAt(x, y, other, sx, sy, w, h)` | Copies a sub-region from another image |
| `Image.empty(width, height)` | Creates an empty blank image |

## Source Storage and Environment

### Instance Methods

- `this.loadData(key)`: Reads persisted string data for this source.
- `this.saveData(key, value)`: Persists data for this source.
- `this.deleteData(key)`: Deletes a stored item.
- `this.loadSetting(key)`: Reads a source setting value.
- `this.isLogged`: Boolean indicating login status.
- `this.translate(text)`: Looks up translation in the source's dictionary.

### APP Global Information & Clipboard

- `APP.version`: Application version string (e.g. `"2.2.1"`).
- `APP.locale`: Current locale string (e.g. `"zh_CN"`, `"en_US"`).
- `APP.platform`: Operating system (`"android"`, `"ios"`, `"windows"`, `"macos"`, `"linux"`).
- `setClipboard(text)`: Writes string to system clipboard.
- `getClipboard()`: Reads text from system clipboard.

## UI Interactions

| Method | Description |
|---|---|
| `UI.showMessage(message)` | Shows a toast message |
| `UI.showDialog(title, content, actions)` | Displays an alert dialog with action buttons |
| `UI.launchUrl(url)` | Opens an external URL in the system browser |
| `UI.showLoading(onCancel?)` | Displays a global loading overlay and returns an ID |
| `UI.cancelLoading(id)` | Dismisses a loading overlay |
| `UI.showInputDialog(title, validator?, image?)` | Prompts for text input; returns `Promise<string|null>` |
| `UI.showSelectDialog(title, options, initialIndex?)` | Displays a selection dialog; returns `Promise<number|null>` |

## Logging, Timers, and Background Computation

- `log(level, title, content)`: Logs to application logger (`info`, `warning`, `error`).
- `console.log(value)`, `console.warn`, `console.error`: Console output.
- `createUuid()`: Generates a new time-based UUID string.
- `randomInt(min, max)`, `randomDouble(min, max)`: Generates pseudo-random numbers.
- `setTimeout(callback, delayMs)`: One-shot delayed callback.
- `setInterval(callback, delayMs)`: Recurring timer with `timer.cancel()`.
- `compute(functionCode, ...args)`: Runs heavy JS compute logic in a background worker isolate and resolves the result.
