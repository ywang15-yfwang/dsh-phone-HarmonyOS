import { createHash } from "node:crypto";

const WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";
const MAX_FRAME = 1 << 20;

function frameText(text) {
  const payload = Buffer.from(text, "utf8");
  const len = payload.length;
  let header;
  if (len < 126) {
    header = Buffer.from([0x81, len]);
  } else if (len < 65536) {
    header = Buffer.alloc(4);
    header[0] = 0x81;
    header[1] = 126;
    header.writeUInt16BE(len, 2);
  } else {
    header = Buffer.alloc(10);
    header[0] = 0x81;
    header[1] = 127;
    header.writeUInt32BE(0, len === 0 ? 2 : 2);
    header.writeUInt32BE(len, 6);
  }
  return Buffer.concat([header, payload]);
}

/**
 * 审批只读桥（host 半边）：
 *  - 只读会话事件 `approval/asked` / `approval/decided`，不再抢 dsh 的 waterfall；
 *  - 手机在线时推“未决审批”；手机回前台可再要一次；
 *  - 手机决定后，让网页脚本去点真实的「允许一次/拒绝」按钮；
 *  - 电脑先点掉（decided）就通知手机撤销。
 */
export function createApprovalHub(ctx, logWarn) {
  const clients = new Set();
  const pending = new Map();
  const events = [];

  function note(kind, detail) {
    events.push({ at: Date.now(), kind, ...detail });
    if (events.length > 80) events.shift();
  }

  function send(client, message) {
    try {
      client.socket.write(frameText(JSON.stringify(message)));
    } catch (error) {
      // 忽略
    }
  }

  function broadcast(role, message) {
    for (const client of [...clients]) {
      if (client.role !== role) continue;
      if (client.socket.destroyed || client.socket.writable === false) {
        drop(client);
        continue;
      }
      send(client, message);
    }
  }

  function items() {
    return [...pending.values()];
  }

  function pushPending(client) {
    send(client, { type: "approval/pending-list", items: items() });
  }

  function feed(client, chunk) {
    client.buffer = Buffer.concat([client.buffer, chunk]);
    while (client.buffer.length >= 2) {
      const first = client.buffer[0];
      const second = client.buffer[1];
      const opcode = first & 0x0f;
      const masked = (second & 0x80) !== 0;
      let length = second & 0x7f;
      let offset = 2;
      if (length === 126) {
        if (client.buffer.length < 4) return;
        length = client.buffer.readUInt16BE(2);
        offset = 4;
      } else if (length === 127) {
        if (client.buffer.length < 10) return;
        const hi = client.buffer.readUInt32BE(2);
        const lo = client.buffer.readUInt32BE(6);
        if (hi !== 0 || lo > MAX_FRAME) {
          client.socket.destroy();
          return;
        }
        length = lo;
        offset = 10;
      }
      let mask = null;
      if (masked) {
        if (client.buffer.length < offset + 4) return;
        mask = client.buffer.subarray(offset, offset + 4);
        offset += 4;
      }
      if (client.buffer.length < offset + length) return;
      const payload = Buffer.from(client.buffer.subarray(offset, offset + length));
      client.buffer = client.buffer.subarray(offset + length);
      if (mask !== null) {
        for (let i = 0; i < payload.length; i++) payload[i] ^= mask[i % 4];
      }
      if (opcode === 0x8) {
        drop(client);
        return;
      }
      if (opcode === 0x9) {
        try {
          client.socket.write(Buffer.from([0x8a, payload.length]));
        } catch (error) {
          // 忽略
        }
        continue;
      }
      if (opcode !== 0x1) continue;
      let message;
      try {
        message = JSON.parse(payload.toString("utf8"));
      } catch (error) {
        continue;
      }
      handleMessage(client, message);
    }
  }

  function handleMessage(client, message) {
    if (message === null || typeof message !== "object") return;
    const type = message.type;
    if (type === "hello") {
      client.role = message.role === "web" ? "web" : "phone";
      note("hello", { role: client.role });
      if (client.role === "phone") pushPending(client);
      return;
    }
    if (type === "approval/list") {
      if (client.role === "phone") pushPending(client);
      return;
    }
    if (type === "approval/decide") {
      const id = typeof message.id === "string" ? message.id : "";
      const decision = message.outcome === "allowed-once" ? "allowed-once" : "rejected";
      if (id.length === 0) return;
      note("decide", { id, decision });
      let delivered = false;
      broadcast("web", { type: "approval/click", id, decision });
      for (const one of clients) if (one.role === "web") delivered = true;
      if (!delivered) send(client, { type: "approval/click-failed", id, reason: "no-web" });
      return;
    }
    if (type === "approval/click-result") {
      const id = typeof message.id === "string" ? message.id : "";
      if (message.ok !== true) broadcast("phone", { type: "approval/click-failed", id, reason: String(message.reason ?? "not-found") });
      return;
    }
  }

  function drop(client) {
    clients.delete(client);
    try {
      client.socket.destroy();
    } catch (error) {
      // 忽略
    }
  }

  function handleUpgrade(req, socket, head) {
    const key = req.headers["sec-websocket-key"];
    if (typeof key !== "string" || key.length === 0) {
      socket.end("HTTP/1.1 400 Bad Request\r\n\r\n");
      return;
    }
    const accept = createHash("sha1").update(key + WS_GUID).digest("base64");
    socket.write(
      "HTTP/1.1 101 Switching Protocols\r\n" +
      "Upgrade: websocket\r\n" +
      "Connection: Upgrade\r\n" +
      `Sec-WebSocket-Accept: ${accept}\r\n\r\n`
    );
    const client = { socket, buffer: Buffer.alloc(0), role: "unknown" };
    clients.add(client);
    socket.on("data", (chunk) => feed(client, chunk));
    socket.on("error", () => drop(client));
    socket.on("end", () => drop(client));
    socket.on("close", () => drop(client));
    if (head !== undefined && head.length > 0) feed(client, head);
  }

  if (typeof ctx.on === "function") {
    ctx.on("session/event", (session, event) => {
      if (event === null || event === undefined) return;
      const type = event.type;
      const data = event.data ?? {};
      if (type === "approval/asked") {
        const id = String(data.id ?? "");
        if (id.length === 0) return;
        pending.set(id, {
          id,
          sessionId: session?.header?.id ?? "",
          toolName: String(data.toolName ?? ""),
          reason: String(data.reason ?? ""),
          displayReason: ""
        });
        note("asked", { id, toolName: String(data.toolName ?? "") });
        broadcast("phone", { type: "approval/pending", item: pending.get(id) });
        return;
      }
      if (type === "approval/decided") {
        const id = String(data.id ?? "");
        pending.delete(id);
        note("decided", { id, outcome: String(data.outcome ?? "") });
        broadcast("phone", { type: "approval/cancelled", id });
      }
    });
  }

  return {
    handleUpgrade,
    debug: () => ({ clients: clients.size, pending: [...pending.keys()], events }),
    pendingItems: items
  };
}
