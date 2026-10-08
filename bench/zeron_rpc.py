"""Minimal stdlib-only client for the zeron engine's IPC (ndjson JSON-RPC over a
WebSocket on 127.0.0.1:<ZERON_IPC_PORT>; crates/rpc/src/lib.rs framing):

  client -> server  {id, method, params}       / {id, cancel: true}
  server -> client  {id, ok} | {id, err}        (unary)
                    {id, item}* then {id, done} (streams)

Used by the benchmark harness (bench/seed_fixture.py, bench/run_bench.py) so the
fixture is generated and driven through the engine's real public surface, the same
way for both clients. No third-party packages (CI runners have a bare python3)."""

import base64
import json
import os
import socket
import struct
import time


class RpcError(Exception):
    pass


class Rpc:
    def __init__(self, port, host="127.0.0.1", timeout=30.0):
        self.sock = socket.create_connection((host, port), timeout=timeout)
        key = base64.b64encode(os.urandom(16)).decode()
        req = (
            f"GET / HTTP/1.1\r\nHost: {host}:{port}\r\nUpgrade: websocket\r\n"
            f"Connection: Upgrade\r\nSec-WebSocket-Key: {key}\r\n"
            "Sec-WebSocket-Version: 13\r\n\r\n"
        )
        self.sock.sendall(req.encode())
        buf = b""
        while b"\r\n\r\n" not in buf:
            chunk = self.sock.recv(4096)
            if not chunk:
                raise RpcError("handshake: connection closed")
            buf += chunk
        head, self._rest = buf.split(b"\r\n\r\n", 1)
        if b" 101 " not in head.split(b"\r\n", 1)[0]:
            raise RpcError(f"handshake failed: {head[:200]!r}")
        self._next_id = 1
        self._pending = {}  # id -> list of messages not yet consumed

    # --- websocket framing -------------------------------------------------
    def _recv_exact(self, n):
        out = b""
        if self._rest:
            out, self._rest = self._rest[:n], self._rest[n:]
        while len(out) < n:
            chunk = self.sock.recv(max(65536, n - len(out)))
            if not chunk:
                raise RpcError("connection closed")
            out += chunk
        if len(out) > n:
            self._rest = out[n:] + self._rest
            out = out[:n]
        return out

    def _send_frame(self, opcode, payload):
        mask = os.urandom(4)
        n = len(payload)
        hdr = bytes([0x80 | opcode])
        if n < 126:
            hdr += bytes([0x80 | n])
        elif n < 65536:
            hdr += bytes([0x80 | 126]) + struct.pack(">H", n)
        else:
            hdr += bytes([0x80 | 127]) + struct.pack(">Q", n)
        masked = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
        self.sock.sendall(hdr + mask + masked)

    def _recv_message(self):
        data = b""
        while True:
            b0, b1 = self._recv_exact(2)
            fin, opcode = b0 & 0x80, b0 & 0x0F
            n = b1 & 0x7F
            if n == 126:
                (n,) = struct.unpack(">H", self._recv_exact(2))
            elif n == 127:
                (n,) = struct.unpack(">Q", self._recv_exact(8))
            mask = self._recv_exact(4) if b1 & 0x80 else None
            payload = self._recv_exact(n)
            if mask:
                payload = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
            if opcode == 0x9:  # ping
                self._send_frame(0xA, payload)
                continue
            if opcode == 0xA:
                continue
            if opcode == 0x8:
                raise RpcError("server closed the connection")
            data += payload
            if fin:
                return json.loads(data)

    # --- rpc ---------------------------------------------------------------
    def _send(self, obj):
        self._send_frame(0x1, json.dumps(obj).encode())

    def _next_for(self, rid, deadline):
        q = self._pending.setdefault(rid, [])
        while not q:
            if deadline is not None:
                left = deadline - time.monotonic()
                if left <= 0:
                    raise TimeoutError(f"rpc id {rid}: timed out")
                self.sock.settimeout(left)
            msg = self._recv_message()
            self._pending.setdefault(msg.get("id"), []).append(msg)
        return q.pop(0)

    def call(self, method, params=None, timeout=60.0):
        rid = self._next_id
        self._next_id += 1
        self._send({"id": rid, "method": method, "params": params or {}})
        msg = self._next_for(rid, time.monotonic() + timeout)
        self._pending.pop(rid, None)
        if "err" in msg:
            raise RpcError(f"{method}: {msg['err']}")
        return msg.get("ok")

    def subscribe(self, method, params=None):
        rid = self._next_id
        self._next_id += 1
        self._send({"id": rid, "method": method, "params": params or {}})
        return rid

    def next_item(self, rid, timeout=60.0):
        """Next stream item, or None when the stream ended (resubscribe)."""
        msg = self._next_for(rid, time.monotonic() + timeout)
        if "err" in msg:
            raise RpcError(f"stream {rid}: {msg['err']}")
        if msg.get("done"):
            self._pending.pop(rid, None)
            return None
        return msg.get("item")

    def cancel(self, rid):
        self._send({"id": rid, "cancel": True})
        self._pending.pop(rid, None)

    def close(self):
        try:
            self._send_frame(0x8, b"")
            self.sock.close()
        except OSError:
            pass


def wait_ready(port, timeout=60.0):
    deadline = time.monotonic() + timeout
    last = None
    while time.monotonic() < deadline:
        try:
            r = Rpc(port, timeout=5)
            r.call("LocalDevice", {}, timeout=10)
            return r
        except (OSError, RpcError, TimeoutError) as e:
            last = e
            time.sleep(0.25)
    raise RpcError(f"engine on :{port} not ready after {timeout}s: {last}")
