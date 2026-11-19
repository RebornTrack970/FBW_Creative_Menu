// Frida agent for chunkgen.py: generates the chunk inside built-in XAR_* block
// types with the game's OWN compiled generators, into scratch buffers (nothing
// is written to the world).
//
// FBW.exe (32-bit MinGW, image base 0x400000, no ASLR) has a "generate block A
// as block B" override path in LPW::PopulateNow:
//     copy = NodeGenInput::GetCopy(input); copy.OverrideLastBT(B_id, B_name);
//     LPW::PopulateNow(tsp(copy), populater)
// This agent does the same with a fresh PopulateData + ImplPopulateSimple as
// the populater, then reads the PopulateData's block map back.
//  * a real NodeGenInput (the context: path, seeds, neighbours) is copied from
//    the game's own chunk generation (hook on LPW::PopulateNow, which also
//    gives the LPW object),
//  * the generation runs in small time-budgeted batches after
//    ProceduralWorld2::Update (main thread: the generators assert that).
// Addresses are FBW.exe virtual addresses (build of 2025-11-09, 28,889,690 bytes);
// chunkgen.py checks the exe size before attaching.
'use strict';

const IMAGE = 0x400000;
const base = Process.mainModule.base;
const A = (va) => base.add(va - IMAGE);

const ADDR = {
    opNew: 0x80bae0, opDelete: 0x80bbc0,
    ngiCtor: 0x93ebd0, ngiGetCopy: 0x93fb90, ngiOverrideLastBT: 0x93e7d0, ngiGetLastBT: 0x93e780,
    pdCtor: 0x942700, pdDtor: 0x942010, pdGetBlock: 0x941a60,
    ipsCtor: 0x93c980,
    lpwPopulateNow: 0x78feb0, pw2Update: 0x945d00,
    basIdToName: 0x40e3f0, basNameToId: 0x40eb70,
    // type id -> name of interactables / monsters (same std::string-return
    // convention as BlockAuxSystem::IdToName). LPW's own BEntSystem /
    // MEntSystem ssp's are empty, so the systems are taken as `this` from
    // methods the game calls on them anyway (see grabSystems)
    bentIdToName: 0x403250, mentIdToName: 0x827e40,
    bentRender: 0x407960, bentGetTouchDist: 0x4035c0,
    // the generators store interactables with OLD ids; the game names them via
    // OldBEntIdToStr = XarBEntSing (unordered_map<int, string>) at this global.
    // (BEntSystem::IdToName wants NEW ids and quits the game on unknown ones.)
    xarBEntSingPtr: 0x1979ca0,
    mentUpdate: 0x829cf0, mentRender: 0x82ce90, mentHasRender: 0x8285e0,
    bt2HasOverrideGet: 0x4227d0,
    // BlockAuxSystem::NameToId PoliteExit()s on unknown names. It looks them
    // up with this unordered_map<string,int>::find on [[bas + 0x58]] (custom /
    // Lua types), then XB_Maybe_WithPrefix(name, int&) (built-in XAR types)
    nameMapFind: 0x13a8f90, xbMaybeWithPrefix: 0xa75cb0,
    // ProceduralWorld::GenerateNode: switch (bt) via this jump table (index
    // bt - 3, 0x7148 entries); unhandled ids jump to NOT_HANDLED, which prints
    // "Xar node not handled" and PoliteExit()s the game
    genJumpTable: 0x170a60c, genNotHandled: 0xa676fa,
    vtblCtrlNodeGenInput: 0x17c27dc, vtblCtrlPopulateData: 0x17c27f8,
};
const NGI_SIZE = 0xd0, PD_SIZE = 0x10c, IPS_SIZE = 0x4000;

const F = {
    opNew: new NativeFunction(A(ADDR.opNew), 'pointer', ['uint32'], 'mscdecl'),
    opDelete: new NativeFunction(A(ADDR.opDelete), 'void', ['pointer'], 'mscdecl'),
    ngiCtor: new NativeFunction(A(ADDR.ngiCtor), 'void', ['pointer'], 'thiscall'),
    ngiGetCopy: new NativeFunction(A(ADDR.ngiGetCopy), 'void', ['pointer', 'pointer'], 'thiscall'),
    ngiOverride: new NativeFunction(A(ADDR.ngiOverrideLastBT), 'void', ['pointer', 'int', 'pointer'], 'thiscall'),
    ngiLastBT: new NativeFunction(A(ADDR.ngiGetLastBT), 'int', ['pointer'], 'thiscall'),
    pdCtor: new NativeFunction(A(ADDR.pdCtor), 'void', ['pointer', 'int'], 'thiscall'),
    pdDtor: new NativeFunction(A(ADDR.pdDtor), 'void', ['pointer'], 'thiscall'),
    pdGetBlock: new NativeFunction(A(ADDR.pdGetBlock), 'int', ['pointer', 'pointer'], 'thiscall'),
    ipsCtor: new NativeFunction(A(ADDR.ipsCtor), 'void', ['pointer', 'pointer'], 'thiscall'),
    lpwPopulateNow: new NativeFunction(A(ADDR.lpwPopulateNow), 'void', ['pointer', 'pointer', 'pointer'], 'thiscall'),
    // std::string return: sret in ECX, then this, id on the stack
    idToName: new NativeFunction(A(ADDR.basIdToName), 'void', ['pointer', 'pointer', 'int'], 'thiscall'),
    nameToId: new NativeFunction(A(ADDR.basNameToId), 'int', ['pointer', 'pointer'], 'thiscall'),
    bentIdToName: new NativeFunction(A(ADDR.bentIdToName), 'void', ['pointer', 'pointer', 'int'], 'thiscall'),
    mentIdToName: new NativeFunction(A(ADDR.mentIdToName), 'void', ['pointer', 'pointer', 'int'], 'thiscall'),
    hasOverride: new NativeFunction(A(ADDR.bt2HasOverrideGet), 'uint8', ['pointer', 'int', 'pointer'], 'thiscall'),
    nameMapFind: new NativeFunction(A(ADDR.nameMapFind), 'pointer', ['pointer', 'pointer'], 'thiscall'),
    xbMaybeWithPrefix: new NativeFunction(A(ADDR.xbMaybeWithPrefix), 'uint8', ['pointer', 'pointer'], 'mscdecl'),
};

// does the running game know this block name? (the same two lookups as
// NameToId, which would quit the game if both fail)
function knownName(nameStr) {
    const node = bas.add(0x58).readPointer();
    if (!node.isNull()) {
        const map = node.readPointer();
        if (!map.isNull() && !F.nameMapFind(map, nameStr).isNull()) return true;
    }
    const out = Memory.alloc(4);
    return F.xbMaybeWithPrefix(nameStr, out) !== 0;
}

// would GenerateNode reach a generator for this id? (same tests as its code:
// ids 0..2, 4, 5, 0x29, 0x2a = Node_SolidBoring, the rest via the jump table)
function handled(id) {
    if ((id >= 0 && id <= 2) || id === 4 || id === 5 || id === 0x29 || id === 0x2a) return true;
    const i = id - 3;
    if (i < 0 || i > 0x7147) return false;
    return !A(ADDR.genJumpTable).add(4 * i).readPointer().equals(A(ADDR.genNotHandled));
}

// the type the game really generates for id (LPW::PopulateNow follows
// BlockTypes2 overrides first)
function overridden(id) {
    const node = lpw.add(0xb0).readPointer();             // ssp<BlockTypes2>
    if (node.isNull()) return id;
    const bt2 = node.readPointer();
    if (bt2.isNull()) return id;
    const out = Memory.alloc(4);
    out.writeS32(-1);
    if (F.hasOverride(bt2, id, out) !== 0) {
        const o = out.readS32();
        if (o >= 0) return o;
    }
    return id;
}

// --- MinGW libstdc++ (__cxx11) std::string, 32-bit: { char* p; size_t len; union { char buf[16]; size_t cap; } }
function makeStr(s) {
    const m = Memory.alloc(24 + s.length + 1);
    const data = m.add(24);
    data.writeUtf8String(s);
    m.writePointer(data);
    m.add(4).writeU32(s.length);
    m.add(8).writeU32(s.length);
    return m;
}
function readStr(m) {
    const p = m.readPointer(), n = m.add(4).readU32();
    return n === 0 ? '' : p.readUtf8String(n);
}

// --- tsp<T> = { T* ptr; ctrl* c; std::string name; int id }  (0x24 bytes);
// ctrl = { vtable, use, weak, T* } (0x10). Counts start huge: the engine never
// frees our objects through them (we free the PopulateData ourselves).
function makeTsp(obj, ctrlVtbl) {
    const ctrl = F.opNew(0x10);
    ctrl.writePointer(A(ctrlVtbl));
    ctrl.add(4).writeU32(0x40000000);
    ctrl.add(8).writeU32(0x40000000);
    ctrl.add(12).writePointer(obj);
    const t = Memory.alloc(0x24);
    t.writePointer(obj);
    t.add(4).writePointer(ctrl);
    t.add(8).writePointer(t.add(16));    // empty SSO name
    t.add(12).writeU32(0);
    t.add(16).writeU8(0);
    t.add(0x20).writeS32(-1);
    return t;
}

// --- state
let lpw = null;          // LPW*
let bas = null;          // BlockAuxSystem*
let bes = null;          // BEntSystem*
let mes = null;          // MEntSystem*
const POOL = 4;          // contexts per type = samples per type (before dedupe)
let pool = [];           // our NodeGenInput copies of real generations (different chunks = different seeds)
let poolNext = 0;        // which one a fresh context replaces
let sinceRefresh = 0;
let queue = [];
let busy = false;
let budgetMs = 30;
let progress = null;     // File: "begin <name>" before each generation (crash culprit)
const names = { b: new Map(), e: new Map(), m: new Map() };
let verified = false;

// old interactable id -> name, read straight from the XarBEntSing map (no game
// calls: an unknown id is just left out). node = { next, int key at +4,
// std::string at +8 }
let oldBEntNames = null;
function oldBEntName(id) {
    if (oldBEntNames === null) {
        const sing = A(ADDR.xarBEntSingPtr).readPointer();
        if (sing.isNull()) return null;                    // (not loaded yet)
        const m = new Map();
        let node = sing.add(8).readPointer();
        let n = 0;
        while (!node.isNull() && n < 100000) {
            const len = node.add(12).readU32();
            if (len > 0 && len < 256) m.set(node.add(4).readS32(), node.add(8).readPointer().readUtf8String(len));
            node = node.readPointer();
            n++;
        }
        oldBEntNames = m;
        send({ type: 'sys', which: 'interactable names', ptr: m.size + ' old ids' });
    }
    const nm = oldBEntNames.get(id);
    return nm === undefined ? null : nm;
}

function nameOf(kind, id) {
    if (kind === 'e') return oldBEntName(id);
    const cache = names[kind];
    let n = cache.get(id);
    if (n !== undefined) return n;
    const sys = kind === 'b' ? bas : kind === 'e' ? bes : mes;
    if (sys === null || sys.isNull()) return null;        // (not found yet: the entry is left out)
    const out = Memory.alloc(24);
    if (kind === 'b') F.idToName(out, bas, id);
    else F.mentIdToName(out, mes, id);
    n = readStr(out);
    cache.set(id, n);
    return n;
}
const idName = (id) => nameOf('b', id);

// PopulateData: block map = std::unordered_map<LocalBlockPos, int> at +0x2c
// (buckets, count, before_begin.next at +0x34, element count at +0x38);
// node = { next, LocalBlockPos{s8 x,y,z} at +4, int bt at +8, hash at +0xc }.
// Cells not in the map are the default block (+0x28).
function readChunk(pd) {
    const def = pd.add(0x28).readS32();
    const cells = new Int32Array(4096).fill(def);
    let node = pd.add(0x34).readPointer();
    let n = 0;
    while (!node.isNull() && n < 1000000) {
        const x = node.add(4).readS8(), y = node.add(5).readS8(), z = node.add(6).readS8();
        if (x >= 0 && x < 16 && y >= 0 && y < 16 && z >= 0 && z < 16) cells[x * 256 + y * 16 + z] = node.add(8).readS32();
        node = node.readPointer();
        n++;
    }
    return { def, cells, n, count: pd.add(0x38).readU32() };
}

// interactables: unordered_map<LocalBlockPos, BEnt> at +0xa0 (first node at
// +0xa8); node (0x30) = { next, LocalBlockPos at +4, BEnt at +8 = { int type,
// int param, std::string param_s, bool }, hash at +0x2c }
function readBEnts(pd) {
    const out = [];
    let node = pd.add(0xa8).readPointer();
    let n = 0;
    while (!node.isNull() && n < 4096) {
        const x = node.add(4).readS8(), y = node.add(5).readS8(), z = node.add(6).readS8();
        const t = node.add(8).readS32(), pi = node.add(12).readS32();
        const nm = (x >= 0 && x < 16 && y >= 0 && y < 16 && z >= 0 && z < 16) ? nameOf('e', t) : null;
        if (nm) out.push([x, y, z, nm, pi]);
        node = node.readPointer();
        n++;
    }
    return out;
}

// monsters: vector<tsp<PreMEnt>> at +0xbc / +0xc0 (tsp = 0x24 bytes, object
// pointer first). PreMEnt = { int type, int code id, tsp<var map> at +8, ... };
// its position is the vector var "__offset" (chunk coordinates; the
// constructor sets it to the cell centre, SetOffset changes it). Var map =
// unordered_map<string, BasicType>; BasicType vector = tag 'v', floats at +8.
const OFFSET_KEY = '__offset';
function mentPos(pm) {
    const map = pm.add(8).readPointer();
    if (map.isNull()) return null;
    let node = map.add(8).readPointer();
    let n = 0;
    while (!node.isNull() && n < 256) {
        for (const ko of [4, 8]) {                       // key offset: 4, or 8 if the pair is 8-aligned
            const len = node.add(ko + 4).readU32();
            if (len === OFFSET_KEY.length) {
                const key = node.add(ko).readPointer().readUtf8String(len);
                if (key === OFFSET_KEY) {
                    for (const bo of [ko + 24, ko + 28]) {
                        const bt = node.add(bo);
                        if (bt.readU8() === 0x76) {
                            return [bt.add(8).readFloat(), bt.add(12).readFloat(), bt.add(16).readFloat()];
                        }
                    }
                }
            }
        }
        node = node.readPointer();
        n++;
    }
    return null;
}
function readMEnts(pd) {
    const out = [];
    const b = pd.add(0xbc).readPointer(), e = pd.add(0xc0).readPointer();
    if (b.isNull() || e.isNull()) return out;
    const count = Math.floor(e.sub(b).toInt32() / 0x24);
    for (let i = 0; i < count && i < 512; i++) {
        const pm = b.add(i * 0x24).readPointer();
        if (pm.isNull()) continue;
        const p = mentPos(pm);
        if (p === null) continue;
        const nm = nameOf('m', pm.readS32());
        if (nm) out.push([+p[0].toFixed(2), +p[1].toFixed(2), +p[2].toFixed(2), nm]);
    }
    return out;
}

// (first chunk only) the map walk must agree with the engine's own GetBlock
function verify(pd, cells) {
    const lbp = Memory.alloc(4);
    for (let i = 0; i < 4096; i += 37) {
        lbp.writeS8(i >> 8); lbp.add(1).writeS8((i >> 4) & 15); lbp.add(2).writeS8(i & 15);
        const v = F.pdGetBlock(pd, lbp);
        if (v !== cells[i]) return 'cell ' + i + ': map ' + cells[i] + ' vs GetBlock ' + v;
    }
    return null;
}

function encodeCells(cells) {
    const pal = [], idx = new Map(), toks = [];
    let runV = -1, runN = 0;
    for (let i = 0; i < 4096; i++) {
        const bt = cells[i];
        let k = idx.get(bt);
        if (k === undefined) { k = pal.length; idx.set(bt, k); pal.push(idName(bt)); }
        if (k === runV) runN++;
        else { if (runN) toks.push(runN === 1 ? String(runV) : runN + 'x' + runV); runV = k; runN = 1; }
    }
    if (runN) toks.push(runN === 1 ? String(runV) : runN + 'x' + runV);
    return { pal, rle: toks.join(',') };
}

// checks a type; returns its id or an { error }
function lookup(name, nameStr) {
    if (!knownName(nameStr)) return { error: 'unknown to the running game (not loaded)' };
    const id = F.nameToId(bas, nameStr);
    if (id < 0) return { error: 'unknown type' };
    if (!name.startsWith('block_') && !handled(overridden(id))) {
        return { error: "no generator (none in the game's dispatch)" };
    }
    return id;
}

// runs bt (id, nameStr) in the context of NodeGenInput src; returns the raw result
function runOnce(id, nameStr, src) {
    const ngi = F.opNew(NGI_SIZE);
    F.ngiCtor(ngi);
    F.ngiGetCopy(src, ngi);
    F.ngiOverride(ngi, id, nameStr);
    const tN = makeTsp(ngi, ADDR.vtblCtrlNodeGenInput);
    const pd = F.opNew(PD_SIZE);
    F.pdCtor(pd, id);
    const tP = makeTsp(pd, ADDR.vtblCtrlPopulateData);
    const ips = Memory.alloc(IPS_SIZE);
    F.ipsCtor(ips, tP);
    F.lpwPopulateNow(lpw, tN, ips);
    const r = readChunk(pd);
    r.bents = readBEnts(pd);
    r.ments = readMEnts(pd);
    if (!verified) {
        const bad = verify(pd, r.cells);
        verified = (bad === null);
        if (bad) r.error = 'map check failed: ' + bad;
    }
    F.pdDtor(pd);
    F.opDelete(pd);
    return r;
}

// one type, once per context in the pool; identical results are kept once
// (a type without randomness ends up with one sample)
function generate(name) {
    const nameStr = makeStr(name);
    const id = lookup(name, nameStr);
    if (typeof id !== 'number') return { name, error: id.error };
    const samples = [], seen = new Set();
    for (const src of pool) {
        const r = runOnce(id, nameStr, src);
        if (r.error) return { name, error: r.error };
        const enc = encodeCells(r.cells);
        const s = { pal: enc.pal, rle: enc.rle, bents: r.bents, ments: r.ments };
        const key = JSON.stringify(s);
        if (!seen.has(key)) { seen.add(key); samples.push(s); }
    }
    return { name, id, samples, contexts: pool.length };
}

function log(s) {
    if (progress) { progress.write(s + '\n'); progress.flush(); }
}

// the systems: `this` of methods the game calls on them (interactables near
// you are drawn / touched, monsters updated / drawn); IdToName itself has
// `this` on the stack (the std::string result is in ECX)
let poolFullAt = 0;
function grab(kind, onStack) {
    return {
        onEnter(args) {
            const t = onStack ? args[0] : this.context.ecx;
            if (t.isNull()) return;
            if (kind === 'e' && (bes === null || !t.equals(bes))) {
                bes = t; names.e.clear(); send({ type: 'sys', which: 'interactables', ptr: t.toString() });
            } else if (kind === 'm' && (mes === null || !t.equals(mes))) {
                mes = t; names.m.clear(); send({ type: 'sys', which: 'monsters', ptr: t.toString() });
            }
        }
    };
}
for (const a of [ADDR.bentRender, ADDR.bentGetTouchDist]) Interceptor.attach(A(a), grab('e', false));
Interceptor.attach(A(ADDR.bentIdToName), grab('e', true));
for (const a of [ADDR.mentUpdate, ADDR.mentRender, ADDR.mentHasRender]) Interceptor.attach(A(a), grab('m', false));
Interceptor.attach(A(ADDR.mentIdToName), grab('m', true));
let warned = false;

function batch() {
    if (busy || queue.length === 0 || lpw === null || pool.length < POOL) return;
    if (poolFullAt === 0) poolFullAt = Date.now();
    if (mes === null && Date.now() - poolFullAt < 20000) return;   // (give it 20 s)
    if (mes === null && !warned) {
        warned = true;
        send({ type: 'sys', which: 'missing', ptr: 'monsters' });
    }
    busy = true;
    const t0 = Date.now();
    const out = [];
    try {
        while (queue.length > 0 && Date.now() - t0 < budgetMs) {
            const name = queue.shift();
            log('begin ' + name);
            const r = generate(name);
            log('done ' + name);
            out.push(r);
            sinceRefresh++;
        }
    } catch (e) {
        out.push({ name: '?', error: 'agent exception: ' + e.stack });
    }
    busy = false;
    send({ type: 'chunks', items: out, left: queue.length });
    if (queue.length === 0) send({ type: 'finished' });
}

// self test: after a real generation, run the same type from the same input
// our way and compare with what the game made (blocks, ents, monsters)
let selftest = 0;
let depth = 0;
function selfCheck(st) {
    const realPd = st.ips.add(4).readPointer();          // ImplPopulateSimple: tsp<PopulateData> at +4
    const src = st.tsp.readPointer();
    if (realPd.isNull() || src.isNull()) return;
    const real = readChunk(realPd);
    const realB = readBEnts(realPd), realM = readMEnts(realPd);
    const id = F.ngiLastBT(src);
    const name = idName(id);
    busy = true;
    let mine;
    try { mine = runOnce(id, makeStr(name), src); } finally { busy = false; }
    let diff = 0;
    for (let i = 0; i < 4096; i++) if (mine.cells[i] !== real.cells[i]) diff++;
    send({ type: 'selftest', name, id, diff,
           bents: [realB.length, mine.bents.length], ments: [realM.length, mine.ments.length],
           sameEnts: JSON.stringify(realB) === JSON.stringify(mine.bents),
           sameMonsters: JSON.stringify(realM) === JSON.stringify(mine.ments),
           sampleBent: realB[0], sampleMent: realM[0] });
    selftest--;
}

// a real generation: borrow its context. The pool fills up first (POOL
// different chunks), then a fresh one replaces the oldest every 25 types.
Interceptor.attach(A(ADDR.lpwPopulateNow), {
    onEnter(args) {
        if (busy) return;                              // (our own calls)
        if (selftest > 0 && depth === 0 && lpw !== null) this.st = { tsp: args[0], ips: args[1] };
        depth++;
        this.counted = true;
        const cur = this.context.ecx;
        if (lpw === null || !cur.equals(lpw)) {             // first time, or another world loaded
            lpw = cur;
            bas = lpw.add(0x50).readPointer().readPointer();
            pool = [];                                       // (old contexts belong to the old world)
            send({ type: 'hooked', lpw: lpw.toString(), bas: bas.toString() });
        }
        if (depth !== 1) return;                             // (the outer call only)
        if (pool.length < POOL || sinceRefresh >= 25) {
            const src = args[0].readPointer();               // tsp<NodeGenInput const>* -> NodeGenInput*
            if (src.isNull()) return;
            busy = true;
            try {
                const c = F.opNew(NGI_SIZE);
                F.ngiCtor(c);
                F.ngiGetCopy(src, c);
                if (pool.length < POOL) {
                    pool.push(c);
                    send({ type: 'pool', size: pool.length });
                } else {
                    pool[poolNext] = c;
                    poolNext = (poolNext + 1) % POOL;
                    sinceRefresh = 0;
                }
            } finally { busy = false; }
        }
    },
    onLeave() {
        if (!this.counted) return;
        depth--;
        if (this.st && selftest > 0 && mes !== null) {
            try { selfCheck(this.st); } catch (e) { send({ type: 'selftest', error: e.stack }); }
        }
    }
});

Interceptor.attach(A(ADDR.pw2Update), { onLeave() { batch(); } });

rpc.exports = {
    start(list, progressPath, budget) {
        queue = list.slice();
        budgetMs = budget || 30;
        progress = new File(progressPath, 'a');
        return { base: base.toString(), queued: queue.length, contexts: POOL };
    },
    selftest(n) { selftest = n; return n; },
    status() {
        return { lpw: lpw ? lpw.toString() : null, pool: pool.length, left: queue.length };
    },
};
