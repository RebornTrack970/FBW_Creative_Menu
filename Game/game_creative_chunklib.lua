-- Creative mode (game side): the chunk library behind the BLOCKS tab's
-- PREVIEW (Windows/win_creative_blockview.lua) and WORLDGEN's
-- create_xar_chunk for the built-in XAR_* blocks.
--
-- Their insides are made by FBW.exe's compiled generators, which mod Lua
-- can't run (ga_worldgen_main_dummy only takes block_* types). So
-- Tools/chunk_library ran the game's own generators for every built-in type
-- in a few different contexts and stored the different results in
-- Game/creative_chunk_lib_NN.lua:
--     creative_chunk_lib["XAR_FOO"] = "<sample>|<sample>|..."
--     sample = "<palette>;<cells>;<ents>;<monsters>"
-- palette = block names, comma separated; cells = the 4096 cells, index
-- x*256 + y*16 + z (z fastest), run-length tokens "v" or "<count>x<v>",
-- v = 0-based palette index; ents = "x:y:z:type:param" / ...; monsters =
-- "x:y:z:type" / ... (Tools/chunk_library/build_library.py).
-- A type without randomness has one sample; for the others the seed picks
-- one (the world seed in the preview, WORLDGEN's SEED box there).
-- See game_creative_core.lua for how the files share things.
creative_g = creative_g or {}           -- shared by all game_creative*.lua files (one game Lua state)
creative_g.state = creative_g.state or {}
local C, S = creative_g, creative_g.state

-- air = nothing to draw (same test as the schematics: engine block flags)
local function empty(name)
    if C.block_is_empty then return C.block_is_empty(name) end
    return type(name) ~= "string" or name == "" or name == C.AIR
end

local function lib()
    local l = rawget(_G, "creative_chunk_lib")
    if type(l) == "table" then return l end
    return nil
end

local function split(s, sep)
    local out = {}
    for part in string.gmatch(s, "([^" .. sep .. "]*)") do out[#out + 1] = part end
    return out
end

-- the samples of bt (strings), or nil
local function samples(bt)
    local l = lib()
    local s = l and l[bt]
    if type(s) ~= "string" then return nil end
    local out = {}
    for part in string.gmatch(s, "[^|]+") do out[#out + 1] = part end
    return out
end

-- which sample a seed picks (the type's name is mixed in, so one seed
-- doesn't pick sample 1 of every type)
local function pick(bt, n, seed)
    if n <= 1 then return 1 end
    local h = 0
    for i = 1, #bt do h = (h * 31 + string.byte(bt, i)) % 1000003 end
    seed = math.floor(tonumber(seed) or 0)
    return (h + seed) % n + 1
end

-- the world seed (xar reads it the same way: game_worldseed.lua)
function C.world_seed()
    local ok, v = pcall(ga_get_sys_i, "game.package.seed")
    if ok and type(v) == "number" then return v end
    return 0
end

local function decode(sample)
    local f = split(sample, ";")
    local pal_s, cells_s, ents_s, mons_s = f[1] or "", f[2] or "", f[3] or "", f[4] or ""
    local solid, k = {}, 0
    for nm in string.gmatch(pal_s, "[^,]+") do
        solid[k] = (not empty(nm)) and nm or false
        k = k + 1
    end
    local blocks, i, n = {}, 0, 0
    for tok in string.gmatch(cells_s, "[^,]+") do
        local cnt, v = string.match(tok, "^(%d+)x(%d+)$")
        if cnt == nil then cnt, v = 1, tok end
        cnt, v = tonumber(cnt), tonumber(v)
        local name = v and solid[v]
        for _ = 1, cnt or 0 do
            if name and i < 4096 then
                blocks[i] = name
                n = n + 1
            end
            i = i + 1
        end
    end
    -- in the schematic ent format, so C.schem_ent_meshes can draw them
    local ents, mons = {}, {}
    for item in string.gmatch(ents_s, "[^/]+") do
        local x, y, z, t, pi = string.match(item, "^(%-?%d+):(%-?%d+):(%-?%d+):([%w_]+):(%-?%d+)$")
        if x then ents[#ents + 1] = { x = tonumber(x), y = tonumber(y), z = tonumber(z), t = t, pi = tonumber(pi), ps = "" } end
    end
    for item in string.gmatch(mons_s, "[^/]+") do
        local x, y, z, t = string.match(item, "^(%-?[%d%.]+):(%-?[%d%.]+):(%-?[%d%.]+):([%w_]+)$")
        if x and tonumber(x) then
            mons[#mons + 1] = { x = tonumber(x), y = tonumber(y), z = tonumber(z), t = t, hp = 0, fz = false, tex = "" }
        end
    end
    -- (bents stays the WORLDGEN index -> name table; the library's ents are
    -- in lib_ents / lib_mons)
    return { def = C.AIR, blocks = blocks, bents = {}, lib_ents = ents, lib_mons = mons, n = n }
end

-- bt's library chunk for a seed as a WORLDGEN chunk table
-- (win_creative_worldgen.lua: { def, blocks = { [x*256 + y*16 + z] = block
-- name }, bents }) + lib_ents / lib_mons (schematic ent format), n = blocks
-- that aren't air, samples = how many the type has, sample = which one this
-- is. nil when the library has no entry for it. seed nil = the world seed.
local cache_key, cache_chunk = nil, nil
function C.clib_chunk(bt, seed)
    local list = samples(bt)
    if list == nil or #list == 0 then return nil end
    local k = pick(bt, #list, seed == nil and C.world_seed() or seed)
    local key = bt .. "#" .. k
    if key == cache_key then return cache_chunk end
    local chunk = decode(list[k])
    chunk.samples, chunk.sample = #list, k
    cache_key, cache_chunk = key, chunk
    return chunk
end

-- how many block types the library has
local count = nil
function C.clib_count()
    if count == nil then
        count = 0
        for _ in pairs(lib() or {}) do count = count + 1 end
    end
    return count
end
