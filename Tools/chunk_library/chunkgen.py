"""Generates one chunk for every built-in XAR_* block type with Fractal Block
World's own compiled generators (via Frida, chunkgen_agent.js) and collects
them in out/chunks.jsonl. build_library.py turns that into the mod's library.

Usage (game running, in a world; move around a bit so the game generates a
chunk the agent can borrow the context of):
    pip install frida
    python chunkgen.py [--only XAR_FOO,XAR_BAR] [--limit N] [--budget-ms 30]

Resumable: types already in out/chunks.jsonl are skipped. If the game dies
while generating a type, that type goes to out/bad.txt (skipped next time);
restart the game and run again.
"""
import argparse, json, os, sys, time, re
import frida

HERE = os.path.dirname(os.path.abspath(__file__))
GAME = os.path.abspath(os.path.join(HERE, "..", "..", "..", "..", ".."))
EXE = os.path.join(GAME, "Bin", "WindowsMinGW", "FBW.exe")
EXE_SIZE = 28889690            # the build the agent's addresses are for
TYPES = os.path.join(GAME, "Output", "Documentation", "xar", "xar_builtin_block_types.txt")
MOD_BAD = os.path.join(HERE, "..", "..", "Game", "block_wiki_bad_blocks.lua")
OUT = os.path.join(GAME, "Output", "chunk_library")   # (outside the mod folder: never uploaded)
CHUNKS = os.path.join(OUT, "chunks_v2.jsonl")   # v2: samples per type + ents / monsters
BAD = os.path.join(OUT, "bad.txt")
PROGRESS = os.path.join(OUT, "progress.log")


def read_lines(path):
    if not os.path.exists(path):
        return []
    with open(path, encoding="utf-8") as f:
        return [l.strip() for l in f if l.strip()]


def done_types():
    done = set()
    for l in read_lines(CHUNKS):
        try:
            done.add(json.loads(l)["name"])
        except Exception:
            pass
    return done


def mod_bad_blocks():
    if not os.path.exists(MOD_BAD):
        return set()
    # values: true / 1 / 2 (see the file's header) - anything but false/nil = crashes
    src = open(MOD_BAD, encoding="utf-8").read()
    return set(re.findall(r'\[?"?(XAR_[A-Z0-9_]+)"?\]?\s*=\s*(?!false|nil)[\w.]+', src))


def crash_culprit():
    """the last 'begin' without its 'done' in the progress log (the game died there)"""
    last = None
    for l in read_lines(PROGRESS):
        op, _, name = l.partition(" ")
        if op == "begin":
            last = name
        elif op == "done" and name == last:
            last = None
    return last


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--only", help="comma separated type names")
    ap.add_argument("--limit", type=int, default=0)
    ap.add_argument("--budget-ms", type=int, default=30, help="generation time per game frame")
    a = ap.parse_args()

    if os.path.getsize(EXE) != EXE_SIZE:
        sys.exit(f"FBW.exe is not the build this tool was made for ({os.path.getsize(EXE)} bytes, want {EXE_SIZE})")
    os.makedirs(OUT, exist_ok=True)

    culprit = crash_culprit()
    if culprit:
        print(f"last run died while generating {culprit}: marking it bad")
        with open(BAD, "a", encoding="utf-8") as f:
            f.write(culprit + "\n")
        with open(PROGRESS, "a", encoding="utf-8") as f:
            f.write(f"done {culprit}\n")

    skip = done_types() | set(read_lines(BAD)) | mod_bad_blocks()
    types = a.only.split(",") if a.only else read_lines(TYPES)
    todo = [t for t in types if t not in skip]
    if a.limit:
        todo = todo[: a.limit]
    print(f"{len(types)} types, {len(todo)} to generate ({len(skip)} done / bad / skipped)")
    if not todo:
        return

    finished, dead = [False], [None]
    stats = {"ok": 0, "err": 0, "t0": time.time()}
    out = open(CHUNKS, "a", encoding="utf-8")

    def on_message(msg, data):
        if msg["type"] == "error":
            print("AGENT ERROR:", msg.get("stack") or msg)
            return
        p = msg["payload"]
        if p["type"] == "hooked":
            print("hooked the game's chunk generation:", p)
        elif p["type"] == "sys":
            if p["which"] == "missing":
                print("  WARNING: never saw the game's", p["ptr"], "system - those names are left out (stand near items / monsters next time)")
            else:
                print(f"  found the {p['which']} system ({p['ptr']})")
        elif p["type"] == "selftest":
            print("  self-test (my run vs the game's):", {k: v for k, v in p.items() if k != "type"})
        elif p["type"] == "pool":
            print(f"  borrowed context {p['size']} (needs 4 different chunks: keep moving)")
        elif p["type"] == "chunks":
            for it in p["items"]:
                if "error" in it:
                    stats["err"] += 1
                    print("  error:", it["name"], it["error"][:300])
                    if it["name"] != "?":
                        with open(BAD, "a", encoding="utf-8") as f:
                            f.write(it["name"] + "\n")
                else:
                    stats["ok"] += 1
                    out.write(json.dumps(it) + "\n")
            out.flush()
            n = stats["ok"] + stats["err"]
            if n % 100 < len(p["items"]) or p["left"] == 0:
                rate = n / max(0.001, time.time() - stats["t0"])
                print(f"  {stats['ok']} ok, {stats['err']} errors, {p['left']} left ({rate:.0f}/s)")
        elif p["type"] == "finished":
            finished[0] = True

    def on_detached(reason, crash):
        dead[0] = reason
        if crash:
            print("CRASH:", crash.summary)

    pid = None
    print("waiting for FBW.exe ...")
    while pid is None:
        for p in frida.get_local_device().enumerate_processes():
            if p.name.lower() == "fbw.exe":
                pid = p.pid
        if pid is None:
            time.sleep(1.0)
    time.sleep(2.0)
    session = frida.attach(pid)
    session.on("detached", on_detached)
    script = session.create_script(open(os.path.join(HERE, "chunkgen_agent.js"), encoding="utf-8").read())
    script.on("message", on_message)
    script.load()
    script.exports_sync.selftest(4)       # the first real chunks: compare blocks / ents / monsters
    print("agent:", script.exports_sync.start(todo, PROGRESS.replace("\\", "/"), a.budget_ms))
    print("waiting for the game: move / shrink around near some items and monsters (needs 4 new chunks)...")
    try:
        while not finished[0] and dead[0] is None:
            time.sleep(0.2)
    except KeyboardInterrupt:
        print("stopped")
    out.close()
    if dead[0] is not None:
        c = crash_culprit()
        print(f"game connection lost ({dead[0]}); died while generating: {c}. Restart the game and run again.")
    else:
        script.unload()
        session.detach()
        print(f"done: {stats['ok']} ok, {stats['err']} errors")


if __name__ == "__main__":
    main()
