// `node:net` for extensions: a TCP client socket plus the pure address helpers. Swift owns
// the wire over `NWConnection` (DNS, connect, reads, writes); JS owns Node's event contract.
// Server sockets stay refused — extensions listen on nothing — and `tls` still refuses outright.

import { Buffer } from "./buffer.js";
import { hostCall } from "./host.js";
import { Duplex } from "./streams.js";

const MAX_PORT = 65536;

// ─── Address validation ──────────────────────────────────────────────

/// Strict dotted decimal: four 0-255 groups, no leading zeros, no whitespace or hex.
export function isIPv4(value) {
  if (typeof value !== "string") return false;
  const parts = value.split(".");
  if (parts.length !== 4) return false;
  for (const part of parts) {
    if (!/^(0|[1-9][0-9]{0,2})$/.test(part)) return false;
    if (Number(part) > 255) return false;
  }
  return true;
}

function parseIPv6Words(value) {
  const zone = value.indexOf("%");
  const bare = zone === -1 ? value : value.slice(0, zone);
  if (zone !== -1 && (zone === value.length - 1 || value.indexOf("%", zone + 1) !== -1)) return null;
  const halves = bare.split("::");
  if (halves.length > 2) return null;
  const parseGroup = (text) => {
    if (text.length === 0 || text.length > 4 || !/^[0-9a-fA-F]+$/.test(text)) return null;
    return parseInt(text, 16);
  };
  const parseSide = (side) => {
    if (side === "") return [];
    const groups = side.split(":");
    const words = [];
    for (let index = 0; index < groups.length; index++) {
      // An embedded dotted tail consumes two groups worth of words.
      if (index === groups.length - 1 && groups[index].includes(".")) {
        const tail = parseIPv4Bytes(groups[index]);
        if (tail === null) return null;
        words.push((tail[0] << 8) | tail[1], (tail[2] << 8) | tail[3]);
      } else {
        const word = parseGroup(groups[index]);
        if (word === null) return null;
        words.push(word);
      }
    }
    return words;
  };
  if (halves.length === 1) {
    const words = parseSide(halves[0]);
    return words !== null && words.length === 8 ? words : null;
  }
  const head = parseSide(halves[0]);
  const tail = parseSide(halves[1]);
  if (head === null || tail === null || head.length + tail.length > 7) return null;
  return [...head, ...new Array(8 - head.length - tail.length).fill(0), ...tail];
}

function parseIPv4Bytes(value) {
  if (!isIPv4(value)) return null;
  return value.split(".").map(Number);
}

export function isIPv6(value) {
  return typeof value === "string" && parseIPv6Words(value) !== null;
}

export function isIP(value) {
  if (isIPv4(value)) return 4;
  if (isIPv6(value)) return 6;
  return 0;
}

function familyOf(address) {
  const version = isIP(address);
  if (version === 4) return "IPv4";
  if (version === 6) return "IPv6";
  return undefined;
}

// ─── SocketAddress ───────────────────────────────────────────────────

export class SocketAddress {
  constructor(options = {}) {
    const address = options?.address;
    // The port is validated before the address, matching Node's error precedence.
    const port = options?.port ?? 0;
    if (!Number.isInteger(port) || port < 0 || port >= MAX_PORT) {
      throw Object.assign(
        new Error(`options.port should be >= 0 and < 65536. Received type number (${port}).`),
        { code: "ERR_SOCKET_BAD_PORT" },
      );
    }
    const detected = familyOf(address)?.toLowerCase();
    const explicit = options?.family !== undefined ? String(options.family).toLowerCase() : undefined;
    // Node only auto-detects IPv4; an IPv6 literal needs an explicit family.
    const family = explicit ?? (detected === "ipv4" ? detected : undefined);
    if ((family !== "ipv4" && family !== "ipv6") || detected !== family) {
      throw Object.assign(new Error("Invalid socket address"), { code: "ERR_INVALID_ADDRESS" });
    }
    this.address = address;
    this.family = family;
    this.port = port;
    this.flowlabel = family === "ipv6" ? options?.flowlabel ?? 0 : 0;
  }
}

// ─── BlockList ───────────────────────────────────────────────────────

function addressBytes(address) {
  if (isIPv4(address)) return { family: "IPv4", bytes: Buffer.from(parseIPv4Bytes(address)) };
  const words = typeof address === "string" ? parseIPv6Words(address) : null;
  if (words === null) return null;
  const bytes = Buffer.alloc(16);
  words.forEach((word, index) => bytes.writeUInt16BE(word, index * 2));
  return { family: "IPv6", bytes };
}

function compareBytes(left, right) {
  for (let index = 0; index < left.length; index++) {
    if (left[index] !== right[index]) return left[index] < right[index] ? -1 : 1;
  }
  return 0;
}

function masked(bytes, prefix) {
  const out = Buffer.from(bytes);
  for (let bit = prefix; bit < out.length * 8; bit++) out[bit >> 3] &= ~(0x80 >> (bit % 8));
  return out;
}

export class BlockList {
  constructor() {
    this.rules = [];
  }

  addAddress(address, type = "ipv4") {
    const parsed = this.parse(address, type);
    this.rules.push(`Address: ${parsed.family} ${parsed.text}`);
    this.entries = [...(this.entries ?? []), { kind: "address", ...parsed }];
  }

  addRange(start, end, type = "ipv4") {
    const first = this.parse(start, type);
    const last = this.parse(end, type);
    if (first.family !== last.family || compareBytes(first.bytes, last.bytes) > 0) {
      throw Object.assign(new Error(`The "${start}" argument is not a valid range`), {
        code: "ERR_INVALID_ADDRESS",
      });
    }
    this.rules.push(`Range: ${first.family} ${first.text}-${last.text}`);
    this.entries = [...(this.entries ?? []), { kind: "range", first, last }];
  }

  addSubnet(network, prefix, type = "ipv4") {
    const base = this.parse(network, type);
    const size = base.family === "IPv4" ? 32 : 128;
    if (!Number.isInteger(prefix) || prefix < 0 || prefix > size) {
      throw Object.assign(new Error("The prefix is out of range"), { code: "ERR_OUT_OF_RANGE" });
    }
    this.rules.push(`Subnet: ${base.family} ${base.text}/${prefix}`);
    this.entries = [
      ...(this.entries ?? []),
      { kind: "subnet", network: masked(base.bytes, prefix), prefix, family: base.family },
    ];
  }

  check(address, type = "ipv4") {
    const parsed = addressBytes(address);
    if (parsed === null) return false;
    if (String(type).toLowerCase() !== parsed.family.toLowerCase()) return false;
    for (const entry of this.entries ?? []) {
      if (entry.kind === "address") {
        if (entry.family === parsed.family && compareBytes(entry.bytes, parsed.bytes) === 0) {
          return true;
        }
      } else if (entry.kind === "range") {
        if (
          entry.first.family === parsed.family
          && compareBytes(entry.first.bytes, parsed.bytes) <= 0
          && compareBytes(parsed.bytes, entry.last.bytes) <= 0
        ) {
          return true;
        }
      } else if (entry.family === parsed.family) {
        if (compareBytes(masked(parsed.bytes, entry.prefix), entry.network) === 0) return true;
      }
    }
    return false;
  }

  parse(address, type) {
    const parsed = addressBytes(address);
    const want = String(type).toLowerCase();
    if (want !== "ipv4" && want !== "ipv6") {
      throw Object.assign(new Error(`Unknown address type: ${type}`), { code: "ERR_INVALID_ARG_VALUE" });
    }
    if (parsed === null || want !== parsed.family.toLowerCase()) {
      throw Object.assign(new Error(`Invalid address: ${address}`), { code: "ERR_INVALID_ADDRESS" });
    }
    return { ...parsed, text: String(address).split("%")[0] };
  }
}

// ─── TCP client socket ───────────────────────────────────────────────

function socketError(code, syscall, host, port, message) {
  const error = new Error(message ?? `${syscall} ${code} ${host}:${port}`);
  error.code = code;
  error.syscall = syscall;
  if (host !== undefined) error.address = host;
  if (port !== undefined) error.port = port;
  return error;
}

function normalizeConnectArgs(args) {
  if (typeof args[0] === "object" && args[0] !== null) {
    return { options: args[0], listener: typeof args[1] === "function" ? args[1] : undefined };
  }
  if (typeof args[0] === "string") {
    return {
      options: { path: args[0] },
      listener: typeof args[1] === "function" ? args[1] : undefined,
    };
  }
  const options = { port: args[0] };
  let index = 1;
  if (typeof args[index] === "string") options.host = args[index++];
  if (typeof args[index] === "function") return { options, listener: args[index] };
  return { options, listener: undefined };
}

export class Socket extends Duplex {
  constructor(options = {}) {
    super({ read() {} });
    this.allowHalfOpen = options?.allowHalfOpen ?? false;
    this.pending = true;
    this.connecting = false;
    this.readyState = "open";
    this.bytesRead = 0;
    this.bytesWritten = 0;
    this.remoteAddress = undefined;
    this.remoteFamily = undefined;
    this.remotePort = undefined;
    this.localAddress = undefined;
    this.localPort = undefined;
    this.timeoutMs = 0;
    this._nativeId = 0;
    this._writeEnded = false;
    this._readEnded = false;
    this._closeEmitted = false;
    this._sendTail = Promise.resolve();
    this.once("close", () => {
      this._closeEmitted = true;
    });
  }

  connect(...args) {
    const { options, listener } = normalizeConnectArgs(args);
    if (listener) this.once("connect", listener);
    if (options?.path !== undefined && options?.port === undefined) {
      queueMicrotask(() =>
        this._fail(socketError("ENOENT", "connect", undefined, undefined, `connect ENOENT ${options.path}`)),
      );
      return this;
    }
    const port = options?.port;
    if (!Number.isInteger(port) || port < 0 || port >= MAX_PORT) {
      throw Object.assign(new Error(`Port should be >= 0 and < 65536. Received ${port}.`), {
        code: "ERR_SOCKET_BAD_PORT",
      });
    }
    const host = options?.host ?? "localhost";
    // Like Node, a redundant `connect` fails asynchronously, never with a sync throw.
    if (this.connecting || this._nativeId !== 0) {
      const code = this._nativeId !== 0 ? "EISCONN" : "EALREADY";
      queueMicrotask(() => this._fail(socketError(code, "connect", host, port)));
      return this;
    }
    if (this._usedBefore) this._resetForReconnect();
    this._usedBefore = true;
    this._connectCalled = true;
    this._openGate = null;
    this._sendTail = Promise.resolve();
    this.connecting = true;
    this.pending = true;
    this.readyState = "opening";
    if (options?.timeout !== undefined) this.setTimeout(options.timeout);
    this._open(host, port, options?.family).catch(() => {});
    return this;
  }

  /// A closed socket reconnects like Node's: the listeners stay, the stream state resets.
  _resetForReconnect() {
    const readable = this._readableState;
    readable.readable = true;
    readable.destroyed = false;
    readable.ended = false;
    readable.endEmitted = false;
    readable.buffer.length = 0;
    readable.length = 0;
    const writable = this._writableState;
    writable.writable = true;
    writable.destroyed = false;
    writable.ending = false;
    writable.ended = false;
    writable.finished = false;
    writable.buffer.length = 0;
    writable.length = 0;
    writable.needDrain = false;
    this._closeEmitted = false;
    this._writeEnded = false;
    this._readEnded = false;
  }

  async _open(host, port, family) {
    // The async seam drops error codes, so refused connections arrive as values, not throws.
    let opened;
    try {
      opened = await hostCall("socket", "open", [
        { host: String(host), port, family: family ?? 0 },
      ]);
    } catch (error) {
      this._gate().reject(error);
      return void this._fail(error);
    }
    if (opened?.error) {
      const coded = socketError(opened.code ?? "ECONNREFUSED", opened.syscall ?? "connect", String(host), port, opened.error);
      this._gate().reject(coded);
      return void this._fail(coded);
    }
    this._gate().resolve();
    // A `destroy()` while connecting wins over the connection that lands after it.
    if (this.destroyed) {
      hostCall("socket", "close", [{ id: opened.id }]).catch(() => {});
      return;
    }
    this._nativeId = opened.id;
    this.connecting = false;
    this.pending = false;
    this.readyState = "open";
    this.remoteAddress = opened.address;
    this.remoteFamily = opened.family;
    this.remotePort = opened.port;
    this.emit("lookup", null, opened.address, opened.family === "IPv6" ? 6 : 4, String(host));
    this._noteActivity();
    this.emit("connect");
    this._pumpReads();
  }

  _fail(error) {
    if (this.destroyed) return;
    const failure = error instanceof Error ? error : new Error(String(error?.message ?? error));
    this._gate().reject(failure);
    this.connecting = false;
    this.pending = false;
    this.readyState = "closed";
    this.destroy(failure);
  }

  emit(event, ...args) {
    // Node throws an unhandled socket `error`; swallowing it would hide refused connections.
    if (event === "error" && !this.listenerCount("error")) throw args[0];
    return super.emit(event, ...args);
  }

  _write(chunk, encoding, callback) {
    if (this.destroyed || this._writeEnded) {
      callback(socketError("ERR_STREAM_DESTROYED", "write", undefined, undefined, "Cannot call write after a stream was destroyed"));
      return;
    }
    const data = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk, encoding);
    this._sendTail = this._sendTail.then(() => this._transmit(data, false));
    this._sendTail.then(
      () => {
        this.bytesWritten += data.length;
        this._noteActivity();
        callback(null);
      },
      callback,
    );
  }

  _final(callback) {
    this._writeEnded = true;
    if (this.readyState === "open") this.readyState = "readOnly";
    if (this._nativeId === 0) return void callback(null);
    this._sendTail = this._sendTail.then(() => this._transmit(Buffer.alloc(0), true));
    this._sendTail.then(
      () => callback(null),
      (error) => callback(error),
    );
  }

  _destroy(error, callback) {
    this._closeNative();
    callback(error ?? null);
  }

  /// `destroy()` after the readable side already ended must still release the native
  /// connection, without emitting a second `close` on top of the one `push(null)` sent.
  destroy(error) {
    this._closeNative();
    this.pending = false;
    if (this._closeEmitted) return this;
    super.destroy(error);
    return this;
  }

  end(chunk, encoding, callback) {
    if (this.readyState === "open") this.readyState = "readOnly";
    return super.end(chunk, encoding, callback);
  }

  destroySoon(chunk, encoding, callback) {
    if (chunk !== undefined) this.write(chunk, encoding);
    this.end(() => {
      this.destroy();
      callback?.();
    });
  }

  resetAndDestroy() {
    this.destroy();
    return this;
  }

  setTimeout(msecs, callback) {
    if (callback) this.once("timeout", callback);
    this.timeoutMs = Number(msecs) || 0;
    this._armTimeout();
    return this;
  }

  setNoDelay() {
    return this;
  }

  setKeepAlive() {
    return this;
  }

  ref() {
    return this;
  }

  unref() {
    return this;
  }

  /// Writes before `connect` wait for the connection, the way Node buffers them.
  _gate() {
    if (!this._openGate) {
      let resolve, reject;
      const promise = new Promise((res, rej) => {
        resolve = res;
        reject = rej;
      });
      // A rejection nobody awaits yet is a buffered write, not a crash.
      promise.catch(() => {});
      this._openGate = { promise, resolve, reject };
    }
    return this._openGate;
  }

  async _transmit(data, end) {
    if (!this._connectCalled) throw socketError("ERR_SOCKET_CLOSED", "send", undefined, undefined, "Socket is closed");
    await this._gate().promise;
    if (this._nativeId === 0 || this.destroyed) {
      throw socketError("ERR_SOCKET_CLOSED", "send", undefined, undefined, "Socket is closed");
    }
    const failed = await hostCall("socket", "send", [
      { id: this._nativeId, base64: data.toString("base64"), end },
    ]);
    if (failed?.error) {
      throw socketError(failed.code ?? "EIO", failed.syscall ?? "write", this.remoteAddress, this.remotePort, failed.error);
    }
  }

  async _pumpReads() {
    for (;;) {
      let event;
      try {
        event = await hostCall("socket", "receive", [this._nativeId]);
      } catch (error) {
        this._remoteClosed(socketError("ECONNRESET", "read", this.remoteAddress, this.remotePort));
        return;
      }
      if (this.destroyed) return;
      if (event.type === "close") {
        const failure = event.error
          ? socketError(event.code ?? "ECONNRESET", event.syscall ?? "read", this.remoteAddress, this.remotePort, String(event.error))
          : undefined;
        this._remoteClosed(failure);
        return;
      }
      const data = Buffer.from(event.base64 ?? "", "base64");
      this.bytesRead += data.length;
      this._noteActivity();
      this.push(data);
      if (event.end) {
        this._readEnded = true;
        if (this.readyState === "open") this.readyState = "writeOnly";
        this.push(null);
        // With no half-open, the readable end closing finishes the connection.
        if (!this.allowHalfOpen && !this._writeEnded) this.end();
        else if (this._writeEnded) this._closeNative();
        return;
      }
    }
  }

  _remoteClosed(error) {
    if (this.destroyed) return;
    if (!this._readEnded) {
      this._readEnded = true;
      this.push(null);
    }
    this.readyState = "closed";
    this.destroy(error ?? undefined);
  }

  _closeNative() {
    this.connecting = false;
    if (this._timeout) {
      clearTimeout(this._timeout);
      this._timeout = undefined;
    }
    try {
      this._gate().reject(socketError("ERR_SOCKET_CLOSED", "send", undefined, undefined, "Socket is closed"));
    } catch {}
    this.readyState = this._closeEmitted ? this.readyState : "closed";
    if (this._nativeId === 0) return;
    const id = this._nativeId;
    this._nativeId = 0;
    hostCall("socket", "close", [{ id }]).catch(() => {});
  }

  _noteActivity() {
    this._armTimeout();
  }

  _armTimeout() {
    if (this._timeout) {
      clearTimeout(this._timeout);
      this._timeout = undefined;
    }
    if (!this.timeoutMs || this.destroyed || this._closeEmitted) return;
    this._timeout = setTimeout(() => {
      this._timeout = undefined;
      this.emit("timeout");
    }, this.timeoutMs);
    this._timeout?.unref?.();
  }
}

// `net.Stream` is the legacy alias of the client socket.
const Stream = Socket;

export function createConnection(...args) {
  const socket = new Socket(typeof args[0] === "object" && args[0] !== null ? args[0] : {});
  return socket.connect(...args);
}

const connect = createConnection;

export const netModule = {
  Socket,
  Stream,
  createConnection,
  connect,
  isIP,
  isIPv4,
  isIPv6,
  SocketAddress,
  BlockList,
};
