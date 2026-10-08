#!/usr/bin/env python3
"""Generate the benchmark fixture profile through a running zeron engine.

Start the engine (the pinned Rust `zeron headless`, the same binary both clients
then talk to) on an empty data dir with the mock harness:

    ZERON_DATA_DIR=$D ZERON_IPC_PORT=27990 ZERON_HARNESS=mock \
      ZERON_MOCK_REPEAT=6 ZERON_MOCK_CODE=1 ZERON_MOCK_TABLE=1 ZERON_MOCK_MEND=1 \
      zeron headless &
    python3 bench/seed_fixture.py --port 27990 --chats 150 --turns 40 --out $D/bench-fixture.json

Creates one project space, `--chats` chats (titled, spread over the space), and in
the first chat ("Bench: long transcript") `--turns` sequential mock runs: every run
streams the mock script (markdown headings, lists, a tool call with output, code
blocks, tables) `ZERON_MOCK_REPEAT` times, so the transcript is long and mixed.
Writes `--out` (chat ids, counts) for bench/run_bench.py. Stop the engine afterwards
and copy the data dir per benchmark run so each run starts from the same bytes."""

import argparse
import json
import os
import sys
import time
import uuid

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from zeron_rpc import Rpc, RpcError, wait_ready  # noqa: E402

CONFIG = {"harness": "mock", "model": None, "reasoning": None, "sandbox": "workspace-write"}

TOPICS = [
    "Fix flaky sync test", "Sidebar truncation", "Refactor transcript fold", "Metal blur pass",
    "Upgrade tokio", "Terminal resize race", "Release notes v0.2", "Voice dictation latency",
    "Markdown table widths", "Settings stress crash", "Worktree cleanup", "PR review queue",
]


def doc_messages(rpc, chat_id, timeout=30.0):
    """Current transcript (the `reset` frame WatchDocMessages sends on attach)."""
    rid = rpc.subscribe("WatchDocMessages", {"chatId": chat_id})
    deadline = time.monotonic() + timeout
    try:
        while time.monotonic() < deadline:
            item = rpc.next_item(rid, timeout=max(0.1, deadline - time.monotonic()))
            if item is None:
                return []
            if isinstance(item, dict) and "reset" in item:
                return item["reset"]
            if isinstance(item, list):  # legacy full-list frames
                return item
        return []
    finally:
        rpc.cancel(rid)


def completed_assistant(msgs):
    return sum(1 for m in msgs if m.get("role") == "assistant" and m.get("status") in ("complete", "completed"))


def queue_run(rpc, chat_id, prompt, cwd):
    rpc.call("QueueCommand", {
        "chatId": chat_id,
        "command": {
            "kind": "run",
            "messageId": str(uuid.uuid4()),
            "request": {"prompt": prompt, "model": None, "reasoning": None, "cwd": cwd,
                        "sandbox": "workspace-write", "autoApprove": True, "resume": None},
        },
    })


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=27990)
    ap.add_argument("--chats", type=int, default=150)
    ap.add_argument("--turns", type=int, default=40)
    ap.add_argument("--space-path", default=None, help="project folder (created; default <out dir>/project)")
    ap.add_argument("--out", required=True)
    a = ap.parse_args()

    space_path = a.space_path or os.path.join(os.path.dirname(os.path.abspath(a.out)), "project")
    os.makedirs(space_path, exist_ok=True)
    rpc = wait_ready(a.port)
    device = rpc.call("LocalDevice", {})["deviceId"]
    space_id = str(uuid.uuid4())
    rpc.call("Mutate", {"op": "createSpace", "spaceId": space_id, "deviceId": device, "path": space_path})

    chats = []
    t0 = time.monotonic()
    for i in range(a.chats):
        cid = str(uuid.uuid4())
        rpc.call("Mutate", {"op": "createChat", "chatId": cid, "spaceId": space_id, "config": CONFIG})
        title = "Bench: long transcript" if i == 0 else f"{TOPICS[i % len(TOPICS)]} #{i}"
        rpc.call("Mutate", {"op": "renameChat", "chatId": cid, "title": title})
        chats.append(cid)
    print(f"seed: {a.chats} chats in {time.monotonic() - t0:.1f}s", flush=True)

    long_chat = chats[0]
    t0 = time.monotonic()
    for turn in range(a.turns):
        queue_run(rpc, long_chat, f"Bench turn {turn + 1}: walk me through the streaming pipeline again, with code and a table.", space_path)
        deadline = time.monotonic() + 120
        while True:
            n = completed_assistant(doc_messages(rpc, long_chat))
            if n >= turn + 1:
                break
            if time.monotonic() > deadline:
                raise RpcError(f"turn {turn + 1} did not complete (have {n})")
            time.sleep(0.3)
        if (turn + 1) % 10 == 0:
            print(f"seed: {turn + 1}/{a.turns} turns ({time.monotonic() - t0:.1f}s)", flush=True)
    # A short second transcript, so chat switching has somewhere to go.
    queue_run(rpc, chats[1], "Short one.", space_path)
    time.sleep(1.0)

    msgs = doc_messages(rpc, long_chat)
    chars = sum(len(p.get("text") or "") for m in msgs for p in m.get("parts", []) if isinstance(p, dict))
    info = {"deviceId": device, "spaceId": space_id, "spacePath": space_path, "chats": chats,
            "longChat": long_chat, "shortChat": chats[1], "turns": a.turns,
            "longChatMessages": len(msgs), "longChatTextChars": chars,
            "mockRepeat": os.environ.get("ZERON_MOCK_REPEAT")}
    with open(a.out, "w") as f:
        json.dump(info, f, indent=1)
    print(f"seed: long chat {len(msgs)} messages, {chars} text chars -> {a.out}", flush=True)
    rpc.close()


if __name__ == "__main__":
    main()
