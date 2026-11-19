"""Checks chunkgen_agent.js against the game: after each of the next N real
chunk generations, the agent runs the same block type from the same input
its own way and compares the 4096 cells with what the game made.
    python selftest.py [N]
(game running, in a world: move / shrink so chunks get generated)
"""
import sys, time, frida, os

HERE = os.path.dirname(os.path.abspath(__file__))
n = int(sys.argv[1]) if len(sys.argv) > 1 else 10
results = []


def on_message(msg, data):
    if msg["type"] == "error":
        print("AGENT ERROR:", msg.get("stack") or msg)
        return
    p = msg["payload"]
    if p["type"] == "selftest":
        results.append(p)
        print("  ", p)


pid = next(p.pid for p in frida.get_local_device().enumerate_processes() if p.name.lower() == "fbw.exe")
session = frida.attach(pid)
script = session.create_script(open(os.path.join(HERE, "chunkgen_agent.js"), encoding="utf-8").read())
script.on("message", on_message)
script.load()
script.exports_sync.selftest(n)
print(f"comparing the next {n} real chunk generations (move around in the game)...")
t0 = time.time()
while len(results) < n and time.time() - t0 < 600:
    time.sleep(0.3)
script.unload()
session.detach()
same = sum(1 for r in results if r.get("diff") == 0)
print(f"{same}/{len(results)} identical")
