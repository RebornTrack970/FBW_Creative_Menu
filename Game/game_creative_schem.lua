-- Creative mode (game side): schematics.
--
-- Making one: hold Alt, middle-click (or C) = corner 1, aim the cyan cursor
-- (Alt+wheel = depth), middle-click again = capture the box (the same box
-- selection as the Alt area fill, game_creative_edit.lua area_click mode
-- "schem"). A schematic keeps
--   * every block that isn't air (+ the api name of trophy blocks),
--   * every basic ent (shops, pickups, keys, text boxes, pictures, secret
--     trophies, ...) with its int and string param,
--   * every monster / moving ent that the game saves (type, exact spot, HP,
--     frozen or not).
-- Then Windows/win_creative_schem_name.lua asks for a name; the schematic is
-- saved and put in the selected hotbar slot (kind "schem"). Holding it shows
-- a cyan ghost (game_creative_render.lua); L-click places it, Backspace
-- undoes that (blocks + the ents it placed).
--
-- Storage: Output/FileOut/creative_schems.txt (+ creative_schems_backup.txt).
-- That is OUTSIDE the mod folder, so a Steam Workshop upload of the mod never
-- contains anyone's schematics. Lua can't read files here (no io library, and
-- ga_open_file_for_writing only writes a plain "name.txt" into
-- Output/FileOut/), so the file is a console script: every line is
--     game_input "creative_schem_io <piece>"
-- and loading runs the engine command
--     execf ../../Output/FileOut/creative_schems.txt
-- (execf puts "../../Input/Scripts/" in front and doesn't check the path).
-- In FBW.exe ga_command -> CmdSystem -> Command_Execf -> Command_GameInput ->
-- GameSystem::Top_GameInput -> top.__game_input are all synchronous, so every
-- line has reached schem_io() when ga_command returns. A probe file checks that
-- this works before the real file is ever written over.
-- Everything in the file is lowercase hex / digits / "x , . -", so the
-- console parser can't change anything (names and params are hex-encoded).
-- See game_creative_core.lua for how the files share things.
creative_g = creative_g or {}           -- shared by all game_creative*.lua files (one game Lua state)
creative_g.state = creative_g.state or {}
local C, S = creative_g, creative_g.state

local SCHEM_FILE   = "creative_schems.txt"
local SCHEM_BACKUP = "creative_schems_backup.txt"
local PROBE_FILE   = "creative_schem_probe.txt"
local EXECF_DIR    = "../../Output/FileOut/"
C.SCHEM_CMD        = "creative_schem_io"
local FORMAT       = 1
local LINE_MAX     = 400      -- chars of data per file line
local NAME_MAX     = 32
local CELLS_MAX    = 262144   -- biggest box a file may hold (captures are capped at C.AREA_CAP)

-- shared with the windows (Windows/win_creative_schem*.lua)
C.SCHEM_LIST_VAR   = "temp.creative.schem_list"    -- "name:sx:sy:sz:blocks:ents:monsters,..."
C.SCHEM_STATUS_VAR = "temp.creative.schem_status"  -- "" | "ok" | "noread" | "broken"
C.SCHEM_NAME_VAR   = "temp.creative.schem_name"    -- name prompt <-> game
C.SCHEM_STATE_VAR  = "temp.creative.schem_state"   -- "" | "edit" | "commit" | "cancel"
C.SCHEM_INFO_VAR   = "temp.creative.schem_info"    -- what the name prompt shows
C.SCHEM_REQ_VAR    = "temp.creative.schem_req"     -- menu -> game: "del <name>" | "lua <name>" | "reload"

-- name -> schematic { name, sx, sy, sz, pal = { block names },
--   cells = { [1 + x + sx*(y + sy*z)] = palette index, 0 = empty },
--   tro = { [cell] = trophy api name }, nblocks,
--   bents = { { x, y, z, t, pi, ps } },          (cell offsets in the box)
--   ments = { { x, y, z, t, hp, fz } },          (float offsets from the box corner)
--   unsaved = true while it is not in the file, holo = cached ghost boxes }
S.schems = S.schems or {}
-- S.schem_status: nil = not loaded yet this session, "ok", "noread" (reading
-- files back doesn't work: kept for the session only), "broken" (the file is
-- damaged: never written over)
S.schem_pending = nil                    -- captured, waiting for its name
S.schem_load_tries = S.schem_load_tries or 0

-------------------------------------------------------------------------------
-- Small helpers
-------------------------------------------------------------------------------

local function hex(s)
    return (string.gsub(s, ".", function(c) return string.format("%02x", string.byte(c)) end))
end

local function unhex(h)
    if type(h) ~= "string" or #h % 2 == 1 or string.find(h, "[^%x]") then return nil end
    return (string.gsub(h, "%x%x", function(b) return string.char(tonumber(b, 16)) end))
end

-- what a schematic may be called: letters, digits, _ and -, spaces become _
function C.schem_clean_name(s)
    s = tostring(s or "")
    s = string.gsub(s, "^%s+", "")
    s = string.gsub(s, "%s+$", "")
    s = string.gsub(s, "%s+", "_")
    s = string.gsub(s, "[^%w_%-]", "")
    if #s > NAME_MAX then s = string.sub(s, 1, NAME_MAX) end
    return s
end

local function sorted_names()
    local t = {}
    for name, _ in pairs(S.schems) do t[#t + 1] = name end
    table.sort(t, function(a, b) return string.lower(a) < string.lower(b) end)
    return t
end

function C.schem_get(name)
    if name == nil then return nil end
    return S.schems[name]
end

function C.schem_dims_str(sch)
    return sch.sx .. "x" .. sch.sy .. "x" .. sch.sz
end

-- "120 blocks, 3 ents, 2 monsters" (parts that are 0 left out)
function C.schem_contents_str(sch)
    local parts = { sch.nblocks .. " block" .. (sch.nblocks == 1 and "" or "s") }
    if #sch.bents > 0 then parts[#parts + 1] = #sch.bents .. " ent" .. (#sch.bents == 1 and "" or "s") end
    if #sch.ments > 0 then parts[#parts + 1] = #sch.ments .. " monster" .. (#sch.ments == 1 and "" or "s") end
    return table.concat(parts, ", ")
end

local function set_var_s(var, v)
    if not ga_exists(var) then ga_init_s(var, v) end
    ga_set_s(var, v)
end

-- the menu reads the list from a var (Windows/win_creative_schem.lua)
local function publish_list()
    local parts = {}
    for _, name in ipairs(sorted_names()) do
        local s = S.schems[name]
        parts[#parts + 1] = table.concat({ name, s.sx, s.sy, s.sz, s.nblocks, #s.bents, #s.ments }, ":")
    end
    set_var_s(C.SCHEM_LIST_VAR, table.concat(parts, ","))
    set_var_s(C.SCHEM_STATUS_VAR, S.schem_status or "")
end
C.schem_publish = publish_list

-- Air-like blocks are not part of a schematic (placing it leaves those cells
-- alone, the ghost doesn't show them). Levels have their own air types with
-- all kinds of names (XAR_EMPTY_BORING is the air of the boring levels, and
-- "EMPTY" / "AIR" are also in names of real blocks), so the engine's block
-- flags decide: nothing to see (not solid-looking, not glass, not water, not
-- see-through-but-drawn) and nothing to bump into = air. Plus the game's air
-- C.AIR, and blocks that crash the game are never copied.
local function bt_flag(fn, name)
    local ok, r = pcall(fn, name)
    if not ok then return nil end
    return r == true
end

-- true / false, or nil when the engine can't tell
local function invisible(name)
    local vs = bt_flag(ga_bt_get_is_visibly_solid, name)
    if vs == nil then return nil end
    if vs then return false end
    if bt_flag(ga_bt_get_is_visibly_glass, name) or bt_flag(ga_bt_get_is_visibly_water, name)
       or bt_flag(ga_bt_get_is_partially_transparent, name) or bt_flag(ga_bt_get_is_physically_solid, name) then
        return false
    end
    return true
end

local empty_cache = {}
local function is_empty(name)
    if type(name) ~= "string" or name == "" or name == C.AIR then return true end
    local e = empty_cache[name]
    if e ~= nil then return e end
    if type(block_wiki_bad_blocks) == "table" and block_wiki_bad_blocks[name] then
        e = true
    elseif name == C.TROPHY_BLOCK or string.sub(name, 1, 6) == "block_" then
        e = false                        -- Lua block types (trophies, ...) draw themselves
    else
        e = invisible(name)
        if e == nil then e = string.find("_" .. name .. "_", "_AIR_", 1, true) ~= nil end
    end
    empty_cache[name] = e
    return e
end
C.block_is_empty = is_empty      -- (the chunk library, game_creative_chunklib.lua)

-- Does a block / ent type with this name exist in the loaded game? (A file can
-- come from another mod setup or be edited by hand; unknown names are skipped.)
local exists_cache = { block = {}, bent = {}, ment = {} }
local function names_have(fn, name)
    local ok, arr = pcall(fn, name)
    if not ok or type(arr) ~= "table" then return false end
    for _, v in ipairs(arr) do
        local nm = (type(v) == "table") and v.name or v
        if nm == name then return true end
    end
    return false
end
local function type_exists(kind, name)
    local c = exists_cache[kind]
    if c[name] ~= nil then return c[name] end
    local e = false
    if kind == "block" then
        local ok, r = pcall(ga_bt_exists, name)
        e = ok and r == true
    elseif kind == "bent" then
        e = names_have(ga_get_bent_names_with_prefix, name)
    else
        e = names_have(ga_get_ment_names_with_prefix, name)
    end
    c[name] = e
    return e
end

-------------------------------------------------------------------------------
-- Capture
-------------------------------------------------------------------------------

local function ment_hp(id)
    -- xar: with the difficulty curve on, health_curved holds the real HP
    -- once health_max_curved isn't -1 (game_ment_health); all of them are ints
    if ga_ment_var_exists(id, "health_max_curved") and ga_ment_var_exists(id, "health_curved")
       and ga_ment_get_i(id, "health_max_curved") ~= -1 then
        return ga_ment_get_i(id, "health_curved")
    end
    if ga_ment_var_exists(id, "health") then return ga_ment_get_i(id, "health") end
    return 0
end

local function ment_frozen(id)
    if ga_ment_var_exists(id, "frozen") and ga_ment_get_b(id, "frozen") then return true end
    return ga_ment_var_exists(id, "__vel_disabled") and ga_ment_get_b(id, "__vel_disabled") == true
end

-- the ment's own texture (__tex_override, a built-in string var): without it
-- ments whose look comes from it (picture-like props, recoloured monsters)
-- came back with the type's default texture, often plain black
local function ment_tex(id)
    if not ga_ment_var_exists(id, "__tex_override") then return "" end
    local t = ga_ment_get_s(id, "__tex_override")
    return type(t) == "string" and t or ""
end

-- box = inclusive block coords on level (viewer-centric)
function C.schem_capture(level, x0, y0, z0, x1, y1, z1)
    C.chunk_cache_reset()
    -- whole numbers (engine positions can come as 3.0, which would print as
    -- "3.0" in the file's integer fields)
    local fl = math.floor
    x0, y0, z0, x1, y1, z1 = fl(x0 + 0.5), fl(y0 + 0.5), fl(z0 + 0.5), fl(x1 + 0.5), fl(y1 + 0.5), fl(z1 + 0.5)
    local sx, sy, sz = x1 - x0 + 1, y1 - y0 + 1, z1 - z0 + 1
    local sch = { sx = sx, sy = sy, sz = sz, pal = {}, cells = {}, tro = {},
                  bents = {}, ments = {}, nblocks = 0 }
    local pal_idx = {}
    local i = 0
    for z = 0, sz - 1 do
        for y = 0, sy - 1 do
            for x = 0, sx - 1 do
                i = i + 1
                local v = 0
                local bp = std.bp(x0 + x, y0 + y, z0 + z)
                if C.cell_loaded(level, bp) then
                    local ok, name = pcall(ga_block_get, level, bp)
                    if ok and not is_empty(name) then
                        v = pal_idx[name]
                        if v == nil then
                            sch.pal[#sch.pal + 1] = name
                            v = #sch.pal
                            pal_idx[name] = v
                        end
                        sch.nblocks = sch.nblocks + 1
                        if name == C.TROPHY_BLOCK then
                            local ok2, api = pcall(ga_block_get_s, level, bp, "api_name")
                            if ok2 and type(api) == "string" and api ~= "" then sch.tro[i] = api end
                        end
                    end
                end
                sch.cells[i] = v
            end
        end
    end

    local center = std.vec(x0 + sx * 0.5, y0 + sy * 0.5, z0 + sz * 0.5)
    local radius = math.sqrt(sx * sx + sy * sy + sz * sz) * 0.5 + 1

    -- basic ents: one per block cell, with both params (unused ones are 0 / "")
    local okb, found = pcall(ga_bent_sphere_query, level, center, radius)
    if okb and type(found) == "table" then
        local seen = {}
        for _, v in pairs(found) do
            local bp = v.bp
            if bp ~= nil and bp.x >= x0 and bp.x <= x1 and bp.y >= y0 and bp.y <= y1
               and bp.z >= z0 and bp.z <= z1 then
                local key = bp.x .. "," .. bp.y .. "," .. bp.z
                local okt, t = pcall(ga_bent_get_type, level, bp)
                if not seen[key] and okt and type(t) == "string" and t ~= "" then
                    seen[key] = true
                    local oki, pi = pcall(ga_bent_get_param_i, level, bp)
                    local oks, ps = pcall(ga_bent_get_param_s, level, bp)
                    sch.bents[#sch.bents + 1] = {
                        x = fl(bp.x - x0 + 0.5), y = fl(bp.y - y0 + 0.5), z = fl(bp.z - z0 + 0.5), t = t,
                        pi = (oki and type(pi) == "number") and math.floor(pi) or 0,
                        ps = (oks and type(ps) == "string") and ps or "",
                    }
                end
            end
        end
    end

    -- moving ents the game would save (not projectiles / effects / the
    -- world's picture props: those have __disable_saving), not players
    local okm, ments = pcall(ga_ment_sphere_query, level, level, level, center, radius)
    if okm and type(ments) == "table" then
        local seen = {}
        for _, v in pairs(ments) do
            local id = v.inst_id
            if id ~= nil and not seen[id] and ga_ment_exists(id) and ga_ment_get_level(id) == level then
                seen[id] = true
                local t = ga_ment_get_type(id)
                local okd, nosave = pcall(ga_ment_get_static_b, t, "__disable_saving")
                if type(t) == "string" and string.sub(t, 1, 11) ~= "ment_player" and okd and nosave ~= true then
                    local lp = ga_ment_get_lp(id)
                    if lp.x >= x0 and lp.x < x1 + 1 and lp.y >= y0 and lp.y < y1 + 1
                       and lp.z >= z0 and lp.z < z1 + 1 then
                        local okh, hp = pcall(ment_hp, id)
                        local okf, fz = pcall(ment_frozen, id)
                        local okx, tex = pcall(ment_tex, id)
                        sch.ments[#sch.ments + 1] = {
                            x = lp.x - x0, y = lp.y - y0, z = lp.z - z0, t = t,
                            hp = (okh and type(hp) == "number") and math.floor(hp) or 0,
                            fz = okf and fz == true,
                            tex = okx and tex or "",
                        }
                    end
                end
            end
        end
    end
    return sch
end

-------------------------------------------------------------------------------
-- File format (version 1). Lines (inside game_input "creative_schem_io ..."):
--   begin 1
--   s <hex name> <sx> <sy> <sz>           a schematic starts
--   p <hex block>,<hex block>,...         palette (1, 2, ...), continues over lines
--   d <tok>,<tok>,...                     cells, x fastest then y then z;
--                                         tok = v or <count>x<v>, v = palette index (0 = empty)
--   t <cell>,<hex api name>               trophy block api name (cell = 1-based index)
--   b <x>,<y>,<z>,<hex type>,<int param>,<hex string param>
--   m <x>,<y>,<z>,<hex type>,<hp>,<0|1 frozen>,<hex __tex_override>   (the last
--                                         field is missing in older files)
--   e                                     the schematic ends
--   end
-------------------------------------------------------------------------------

local function line(s) return 'game_input "' .. C.SCHEM_CMD .. ' ' .. s .. '"' end

-- items joined with "," into lines of at most LINE_MAX chars
local function emit_list(out, tag, items)
    local buf, len = {}, 0
    for _, it in ipairs(items) do
        if #buf > 0 and len + #it + 1 > LINE_MAX then
            out[#out + 1] = line(tag .. " " .. table.concat(buf, ","))
            buf, len = {}, 0
        end
        buf[#buf + 1] = it
        len = len + #it + 1
    end
    if #buf > 0 then out[#out + 1] = line(tag .. " " .. table.concat(buf, ",")) end
end

local function num3(v) return string.format("%.3f", v) end

local function encode(sch, out)
    out[#out + 1] = line("s " .. hex(sch.name) .. " " .. sch.sx .. " " .. sch.sy .. " " .. sch.sz)
    -- palette: only the entries that are used, renumbered
    local remap, pal = { [0] = 0 }, {}
    for _, v in ipairs(sch.cells) do
        if remap[v] == nil then
            pal[#pal + 1] = hex(sch.pal[v])
            remap[v] = #pal
        end
    end
    emit_list(out, "p", pal)
    -- run-length cells
    local toks, n = {}, #sch.cells
    local i = 1
    while i <= n do
        local v, j = remap[sch.cells[i]], i
        while j < n and remap[sch.cells[j + 1]] == v do j = j + 1 end
        local run = j - i + 1
        toks[#toks + 1] = (run == 1) and tostring(v) or (run .. "x" .. v)
        i = j + 1
    end
    emit_list(out, "d", toks)
    local cells = {}
    for c, _ in pairs(sch.tro) do cells[#cells + 1] = c end
    table.sort(cells)
    for _, c in ipairs(cells) do out[#out + 1] = line("t " .. c .. "," .. hex(sch.tro[c])) end
    for _, b in ipairs(sch.bents) do
        out[#out + 1] = line("b " .. b.x .. "," .. b.y .. "," .. b.z .. "," .. hex(b.t) .. ","
            .. b.pi .. "," .. hex(b.ps))
    end
    for _, m in ipairs(sch.ments) do
        out[#out + 1] = line("m " .. num3(m.x) .. "," .. num3(m.y) .. "," .. num3(m.z) .. ","
            .. hex(m.t) .. "," .. m.hp .. "," .. (m.fz and "1" or "0") .. "," .. hex(m.tex or ""))
    end
    out[#out + 1] = line("e")
end

local function file_lines()
    local out = {
        "# Creative Menu schematics (FBW_Creative_Menu mod). Written by the mod; the mod reads",
        "# it back with the console command: execf ../../Output/FileOut/" .. SCHEM_FILE,
        "# Every line hands one piece of a schematic to the mod (names / params are hex).",
        line("begin " .. FORMAT),
    }
    for _, name in ipairs(sorted_names()) do encode(S.schems[name], out) end
    out[#out + 1] = line("end")
    return out
end

local function write_file(fn, lines)
    local ok, h = pcall(ga_open_file_for_writing, fn)
    if not ok or h == nil then return false end
    local buf = {}
    for _, l in ipairs(lines) do
        buf[#buf + 1] = l
        if #buf >= 200 then
            ga_write(h, table.concat(buf, "\n") .. "\n")
            buf = {}
        end
    end
    if #buf > 0 then ga_write(h, table.concat(buf, "\n") .. "\n") end
    ga_close_file(h)
    return true
end

-- writes every schematic (backup first). Returns ok, reason
local function save_all()
    if S.schem_status == "noread" then
        return false, "this game version can't read the schematics file back"
    elseif S.schem_status == "broken" then
        return false, "Output/FileOut/" .. SCHEM_FILE .. " could not be read (fix or delete it)"
    end
    local lines = file_lines()
    if not write_file(SCHEM_BACKUP, lines) or not write_file(SCHEM_FILE, lines) then
        return false, "could not write Output/FileOut/" .. SCHEM_FILE
    end
    for _, sch in pairs(S.schems) do sch.unsaved = nil end
    return true
end

-------------------------------------------------------------------------------
-- Reading the file back: execf runs it, every line calls schem_io()
-------------------------------------------------------------------------------

local rd = nil   -- reader state while execf runs: { list, cur, done, bad }

local function rd_fail(msg)
    if rd ~= nil then rd.bad = true end
    ga_console_print("creative schematics file: " .. tostring(msg))
end

local function finish_cur()
    local cur = rd.cur
    rd.cur = nil
    if #cur.cells ~= cur.sx * cur.sy * cur.sz then
        return rd_fail("schematic " .. cur.name .. " has " .. #cur.cells .. " cells, expected "
            .. cur.sx * cur.sy * cur.sz)
    end
    -- palette entries that are air (files saved before the air check knew
    -- about every level's air, e.g. XAR_EMPTY_BORING) become empty cells; the
    -- file is then written again without them
    local air = {}
    for v, name in ipairs(cur.pal) do air[v] = is_empty(name) end
    local n, cleaned = 0, false
    for i, v in ipairs(cur.cells) do
        if v > #cur.pal then return rd_fail("schematic " .. cur.name .. ": bad palette index " .. v) end
        if v > 0 and air[v] then
            cur.cells[i] = 0
            cleaned = true
        elseif v > 0 then
            n = n + 1
        end
    end
    cur.nblocks = n
    if cleaned then cur.unsaved = true end
    rd.list[#rd.list + 1] = cur
end

local function io_line(str)
    local a = {}
    for w in string.gmatch(str or "", "%S+") do a[#a + 1] = w end
    local c = a[1]
    if c == "probe" then S.schem_probe_seen = true return end
    if c == "begin" then rd = { list = {}, cur = nil, done = false, bad = false } return end
    if rd == nil or rd.done then return end
    local cur = rd.cur
    if c == "s" then
        if cur ~= nil then return rd_fail("schematic without its end line") end
        local name = C.schem_clean_name(unhex(a[2]) or "")
        local sx, sy, sz = tonumber(a[3]), tonumber(a[4]), tonumber(a[5])
        if name == "" or not sx or not sy or not sz or sx < 1 or sy < 1 or sz < 1
           or sx * sy * sz > CELLS_MAX then
            return rd_fail("bad schematic header: " .. tostring(str))
        end
        rd.cur = { name = name, sx = math.floor(sx), sy = math.floor(sy), sz = math.floor(sz),
                   pal = {}, cells = {}, tro = {}, bents = {}, ments = {}, nblocks = 0 }
        return
    end
    if cur == nil then
        if c == "end" then rd.done = true return end
        return rd_fail("data outside a schematic: " .. tostring(c))
    end
    local arg = a[2] or ""
    if c == "p" then
        for item in string.gmatch(arg, "[^,]+") do
            local name = unhex(item)
            if name == nil then return rd_fail("bad palette entry " .. item) end
            cur.pal[#cur.pal + 1] = name
        end
    elseif c == "d" then
        local cells, total = cur.cells, cur.sx * cur.sy * cur.sz
        for tok in string.gmatch(arg, "[^,]+") do
            local n, v = string.match(tok, "^(%d+)x(%d+)$")
            if n == nil then n, v = 1, string.match(tok, "^(%d+)$") end
            n, v = tonumber(n), tonumber(v)
            if n == nil or v == nil or #cells + n > total then return rd_fail("bad cell data " .. tok) end
            for _ = 1, n do cells[#cells + 1] = v end
        end
    elseif c == "t" then
        local i, h = string.match(arg, "^(%d+),(%x+)$")
        local api = unhex(h)
        if i == nil or api == nil then return rd_fail("bad trophy line") end
        cur.tro[tonumber(i)] = api
    elseif c == "b" then
        local x, y, z, t, pi, ps = string.match(arg, "^(%-?%d+),(%-?%d+),(%-?%d+),(%x+),(%-?%d+),(%x*)$")
        t, ps = unhex(t), unhex(ps)
        if x == nil or t == nil or ps == nil then return rd_fail("bad ent line") end
        cur.bents[#cur.bents + 1] = { x = tonumber(x), y = tonumber(y), z = tonumber(z), t = t,
                                      pi = tonumber(pi), ps = ps }
    elseif c == "m" then
        local x, y, z, t, hp, fz, tex = string.match(arg,
            "^(%-?[%d%.]+),(%-?[%d%.]+),(%-?[%d%.]+),(%x+),(%-?%d+),([01]),?(%x*)$")
        t, tex = unhex(t), unhex(tex or "")
        if x == nil or t == nil or tex == nil or tonumber(x) == nil or tonumber(y) == nil or tonumber(z) == nil then
            return rd_fail("bad monster line")
        end
        cur.ments[#cur.ments + 1] = { x = tonumber(x), y = tonumber(y), z = tonumber(z), t = t,
                                      hp = tonumber(hp), fz = fz == "1", tex = tex }
    elseif c == "e" then
        finish_cur()
    else
        return rd_fail("unknown line " .. tostring(c))
    end
end

-- the creative_schem_io command (registered in game_creative.lua)
function C.schem_io(str)
    local ok, err = pcall(io_line, str)
    if not ok then rd_fail(err) end
    return ""
end

-- runs one file through execf: "ok", "missing" or "broken" (+ reader state)
local function run_file(fn)
    rd = nil
    ga_command("execf " .. EXECF_DIR .. fn)
    local r = rd
    rd = nil
    if r == nil then return "missing" end
    if r.bad or not r.done or r.cur ~= nil then return "broken", r end
    return "ok", r
end

-- (Re)loads the schematics file. Schematics made this session that never
-- made it into the file (S.schems[..].unsaved) are kept and written now.
function C.schem_load()
    S.schem_load_tries = S.schem_load_tries + 1
    local keep = {}
    for name, sch in pairs(S.schems) do
        if sch.unsaved then keep[name] = sch end
    end
    -- 1. can we read a file back at all? (if not, never write over the real one)
    S.schem_probe_seen = false
    if write_file(PROBE_FILE, { "# Creative Menu: checks that it can read its schematics file back",
                                line("probe") }) then
        ga_command("execf " .. EXECF_DIR .. PROBE_FILE)
    end
    if not S.schem_probe_seen then
        S.schem_status = "noread"
        ga_console_print("creative schematics: could not read a file back with execf;"
            .. " new schematics are kept for this session only")
        publish_list()
        return S.schem_status
    end
    -- 2. the schematics (the backup if the file itself is damaged)
    local st, r = run_file(SCHEM_FILE)
    if st == "broken" then
        local st2, r2 = run_file(SCHEM_BACKUP)
        if st2 == "ok" then
            ga_console_print("creative schematics: " .. SCHEM_FILE .. " is damaged, loaded "
                .. SCHEM_BACKUP .. " instead")
            st, r = "ok", r2
            for _, sch in ipairs(r.list) do sch.unsaved = true end   -- rewrite the main file
        end
    end
    S.schems = {}
    if st == "ok" then
        for _, sch in ipairs(r.list) do S.schems[sch.name] = sch end
    end
    S.schem_status = (st == "broken") and "broken" or "ok"
    local dirty = (st == "missing")       -- write an (empty) file so execf finds one next time
    for name, sch in pairs(keep) do
        S.schems[name] = sch
        dirty = true
    end
    for _, sch in pairs(S.schems) do
        if sch.unsaved then dirty = true end
    end
    if dirty and S.schem_status == "ok" then save_all() end
    publish_list()
    return S.schem_status
end

-- load once per session; retry a failed read while you're alive (xar's
-- __game_input ignores input while you are dead)
function C.schem_ensure_loaded()
    if S.schem_status == "noread" and S.schem_load_tries < 3 and ga_get_sys_b("game.player.alive") then
        return C.schem_load()
    end
    if S.schem_status == nil then return C.schem_load() end
    return S.schem_status
end

-------------------------------------------------------------------------------
-- Making a schematic: capture -> name prompt -> save + hotbar
-------------------------------------------------------------------------------

local function unique_name(base)
    local n = 1
    while S.schems[base .. "_" .. n] ~= nil do n = n + 1 end
    return base .. "_" .. n
end

-- 2nd Alt+middle-click (game_creative_edit.lua area_click)
function C.schem_begin_capture(level, x0, y0, z0, x1, y1, z1)
    C.schem_ensure_loaded()
    local sch = C.schem_capture(level, x0, y0, z0, x1, y1, z1)
    if sch.nblocks + #sch.bents + #sch.ments == 0 then
        ga_hud_msg("Schematic: nothing in that box", 2.0)
        return
    end
    S.schem_pending = sch
    set_var_s(C.SCHEM_NAME_VAR, unique_name("schematic"))
    set_var_s(C.SCHEM_INFO_VAR, C.schem_dims_str(sch) .. "   " .. C.schem_contents_str(sch))
    set_var_s(C.SCHEM_STATE_VAR, "edit")
    publish_list()                          -- the prompt checks names against it
    ga_set_b(C.ALT_VAR, false)              -- (the window takes the Alt key-up)
    ga_window_push("win_creative_schem_name")
end

-- adds sch as `name` (replacing one with that name), saves, puts it in the
-- selected hotbar slot
function C.schem_add(sch, raw_name)
    local name = C.schem_clean_name(raw_name)
    if name == "" then
        ga_hud_msg("Schematic not saved: it needs a name (letters, digits, _ or -)", 2.5)
        return false
    end
    sch.name, sch.holo, sch.unsaved = name, nil, true
    S.schems[name] = sch
    local ok, why = save_all()
    publish_list()
    C.hb_set_current("schem", name)
    local msg = "Saved schematic " .. name .. "  (" .. C.schem_dims_str(sch) .. ", "
        .. C.schem_contents_str(sch) .. ") - in hotbar slot " .. C.cur_slot()
    if not ok then msg = "Schematic " .. name .. " is in hotbar slot " .. C.cur_slot()
        .. " but NOT saved: " .. why end
    ga_hud_msg(msg, ok and 3.0 or 5.0)
    return true
end

function C.schem_delete(name)
    if S.schems[name] == nil then return false end
    if S.schem_status == "broken" then
        ga_hud_msg("Can't delete: the schematics file could not be read", 2.5)
        return false
    end
    S.schems[name] = nil
    if S.schem_status == "ok" then
        local ok, why = save_all()
        if not ok then ga_hud_msg("Schematic deleted, but " .. why, 3.0) end
    end
    C.hb_remove_entry("schem", name)
    publish_list()
    return true
end

-- every tick (game_creative.lua): first load, menu requests, name prompt result
function C.schem_tick()
    if S.schem_status == nil and S.schem_load_tries == 0 then C.schem_load() end
    if ga_exists(C.SCHEM_REQ_VAR) then
        local req = ga_get_s(C.SCHEM_REQ_VAR)
        if req ~= "" then
            ga_set_s(C.SCHEM_REQ_VAR, "")
            local cmd, arg = string.match(req, "^(%S+)%s*(.*)$")
            if cmd == "del" then C.schem_delete(arg)
            elseif cmd == "lua" then C.schem_export_lua(arg)
            elseif cmd == "reload" then C.schem_load() end
        end
    end
    if not ga_exists(C.SCHEM_STATE_VAR) then return end
    local st = ga_get_s(C.SCHEM_STATE_VAR)
    if st ~= "commit" and st ~= "cancel" then return end
    ga_set_s(C.SCHEM_STATE_VAR, "")
    local pend = S.schem_pending
    S.schem_pending = nil
    if pend == nil then return end
    if st == "cancel" then
        ga_hud_msg("Schematic not saved", 1.5)
        return
    end
    C.schem_add(pend, ga_get_s(C.SCHEM_NAME_VAR))
end

-------------------------------------------------------------------------------
-- Placing
-------------------------------------------------------------------------------

-- Where a schematic goes: the box sits on the face you aim at (on the floor:
-- bottom layer on the aimed cell, centred; on a wall: sticking out of it; on
-- a ceiling: hanging down). Nothing aimed: centred on the aim point (Alt+wheel
-- = distance). Returns level, the box's min corner x, y, z.
function C.schem_origin(sch)
    local vlevel = ga_get_viewer_level()
    local sx, sy, sz = sch.sx, sch.sy, sch.sz
    local hx, hy, hz = math.floor((sx - 1) / 2), math.floor((sy - 1) / 2), math.floor((sz - 1) / 2)
    local level, bp, bp2 = C.look_target()
    if level ~= nil and level == vlevel then
        local nx, ny, nz = bp2.x - bp.x, bp2.y - bp.y, bp2.z - bp.z
        local ox, oy, oz = bp2.x - hx, bp2.y - hy, bp2.z
        if nx == 1 then ox = bp2.x elseif nx == -1 then ox = bp2.x - sx + 1 end
        if ny == 1 then oy = bp2.y elseif ny == -1 then oy = bp2.y - sy + 1 end
        if nz == -1 then oz = bp2.z - sz + 1 end
        return vlevel, ox, oy, oz
    end
    local _, pos = C.aim_point(0.5)
    local c = std.lp_to_bp(pos)
    return vlevel, c.x - hx, c.y - hy, c.z - hz
end

function C.schem_place(name)
    local sch = S.schems[name]
    if sch == nil then
        C.schem_ensure_loaded()
        sch = S.schems[name]
    end
    if sch == nil then
        ga_hud_msg("Schematic " .. tostring(name) .. " not found (deleted?)", 2.5)
        return
    end
    C.chunk_cache_reset()
    local level, ox, oy, oz = C.schem_origin(sch)
    local skipped, unknown, occupied = 0, 0, 0

    -- blocks
    local list, trophies = {}, {}
    local i = 0
    for z = 0, sch.sz - 1 do
        for y = 0, sch.sy - 1 do
            for x = 0, sch.sx - 1 do
                i = i + 1
                local v = sch.cells[i]
                if v > 0 then
                    local bname = sch.pal[v]
                    local bp = std.bp(ox + x, oy + y, oz + z)
                    if not C.cell_loaded(level, bp) then
                        skipped = skipped + 1
                    elseif (type(block_wiki_bad_blocks) == "table" and block_wiki_bad_blocks[bname])
                           or not type_exists("block", bname) then
                        unknown = unknown + 1
                    else
                        list[#list + 1] = { bp = bp, name = bname }
                        if sch.tro[i] then trophies[#trophies + 1] = { bp = bp, api = sch.tro[i] } end
                    end
                end
            end
        end
    end

    -- Backspace removes the ents this placed (the blocks come back by themselves)
    local placed_bents, placed_ments = {}, {}
    local function on_undo()
        C.chunk_cache_reset()
        local n = 0
        for _, pb in ipairs(placed_bents) do
            local bp = C.anchor_bp(pb.anchor)
            local ok, t = false, nil
            if bp ~= nil then ok, t = pcall(ga_bent_get_type, pb.level, bp) end
            if ok and t == pb.t then
                ga_bent_remove_perm(pb.level, bp)
                n = n + 1
            end
        end
        for _, pm in ipairs(placed_ments) do
            if ga_ment_exists(pm.id) and ga_ment_get_type(pm.id) == pm.t then
                if not pcall(ga_ment_remove_perm, pm.id) then pcall(ga_ment_remove, pm.id) end
                n = n + 1
            end
        end
        return n
    end
    local changed = C.apply_block_list(level, list, on_undo)
    for _, tr in ipairs(trophies) do pcall(ga_block_set_s, level, tr.bp, "api_name", tr.api) end

    -- basic ents with their params (one per cell: a taken cell is left alone)
    for _, b in ipairs(sch.bents) do
        local bp = std.bp(ox + b.x, oy + b.y, oz + b.z)
        if not C.cell_loaded(level, bp) then
            skipped = skipped + 1
        elseif not type_exists("bent", b.t) or not C.bent_param_valid(b.t, b.ps) then
            unknown = unknown + 1
        else
            local okt, there = pcall(ga_bent_get_type, level, bp)
            if okt and type(there) == "string" and there ~= "" then
                occupied = occupied + 1
            else
                local ok = pcall(function()
                    if b.pi ~= 0 then
                        ga_bent_add_i(level, bp, b.t, b.pi, C.BIG_TTL)
                        if b.ps ~= "" then ga_bent_set_param_s(level, bp, b.ps, C.BIG_TTL) end
                    elseif b.ps ~= "" then
                        ga_bent_add_s(level, bp, b.t, b.ps, C.BIG_TTL)
                    else
                        ga_bent_add(level, bp, b.t, C.BIG_TTL)
                    end
                end)
                local anchor = ok and C.anchor_make(level, bp)
                if anchor then placed_bents[#placed_bents + 1] = { level = level, anchor = anchor, t = b.t } end
            end
        end
    end

    -- monsters at their exact spot, with their HP / frozen state
    for _, m in ipairs(sch.ments) do
        local pos = std.vec(ox + m.x, oy + m.y, oz + m.z)
        if not C.cell_loaded(level, std.lp_to_bp(pos)) then
            skipped = skipped + 1
        elseif not type_exists("ment", m.t) then
            unknown = unknown + 1
        else
            local ok, id = pcall(C.spawn_ment_at, level, pos, m.t, m.hp, m.fz, m.tex)
            if ok and type(id) == "number" and id >= 0 then
                placed_ments[#placed_ments + 1] = { id = id, t = m.t }
            end
        end
    end

    local msg = "Placed " .. name .. ": " .. changed .. " block(s)"
    if #placed_bents > 0 then msg = msg .. ", " .. #placed_bents .. " ent(s)" end
    if #placed_ments > 0 then msg = msg .. ", " .. #placed_ments .. " monster(s)" end
    msg = msg .. "  (Backspace = undo)"
    if skipped > 0 then msg = msg .. "  - " .. skipped .. " outside the loaded area skipped" end
    if unknown > 0 then msg = msg .. "  - " .. unknown .. " unknown type(s) skipped" end
    if occupied > 0 then msg = msg .. "  - " .. occupied .. " ent spot(s) already taken" end
    ga_hud_msg(msg, 3.0)
end

-------------------------------------------------------------------------------
-- The ghost (drawn by game_creative_render.lua): one see-through cube per
-- block you could see from outside (blocks with all 6 neighbours filled are
-- skipped), with that block's own texture - the same one the BLOCKS tab shows
-- (Windows/win_creative_tex.lua C.block_tex; windows and game scripts share
-- one Lua state). Blocks without a known texture get a flat colour per type.
-- Grouped by block type: { count, groups = { { tex, col, cells = { x, y, z, ... } } } }
-------------------------------------------------------------------------------

C.HOLO_CELLS_MAX = 4000
local HOLO_TINT = { 0.80, 1.0, 1.0 }        -- textures get a light cyan tint

-- the block's texture (an existing texture name) or nil
local function ghost_tex(name)
    local ui = rawget(_G, "creative_ui")
    if type(ui) ~= "table" or type(ui.block_tex) ~= "function" or type(ui.ntex) ~= "function" then return nil end
    local ok, t = pcall(ui.block_tex, name)
    if not ok or type(t) ~= "string" or t == "" then return nil end
    local ok2, real = pcall(ui.ntex, t)           -- only names the game really has
    if ok2 and type(real) == "string" and real ~= "" then return real end
    return nil
end

local function type_col(name)
    local h = 0
    for i = 1, #name do h = (h * 31 + string.byte(name, i)) % 100003 end
    return { 0.30 + (h % 60) / 100, 0.30 + (math.floor(h / 7) % 60) / 100, 0.30 + (math.floor(h / 53) % 60) / 100 }
end

local function build_holo(sch)
    local sx, sy, sz, cells = sch.sx, sch.sy, sch.sz, sch.cells
    local function filled(x, y, z)
        if x < 0 or y < 0 or z < 0 or x >= sx or y >= sy or z >= sz then return false end
        return cells[1 + x + sx * (y + sy * z)] > 0
    end
    local groups, by_v, n = {}, {}, 0
    local i = 0
    for z = 0, sz - 1 do
        for y = 0, sy - 1 do
            for x = 0, sx - 1 do
                i = i + 1
                local v = cells[i]
                if v > 0 and n < C.HOLO_CELLS_MAX
                   and not (filled(x - 1, y, z) and filled(x + 1, y, z) and filled(x, y - 1, z)
                            and filled(x, y + 1, z) and filled(x, y, z - 1) and filled(x, y, z + 1)) then
                    local g = by_v[v]
                    if g == nil then
                        local name = sch.pal[v]
                        local tex = ghost_tex(name)
                        g = { tex = tex or "creative_white", col = tex and HOLO_TINT or type_col(name), cells = {} }
                        by_v[v] = g
                        groups[#groups + 1] = g
                    end
                    local c = g.cells
                    c[#c + 1] = x; c[#c + 1] = y; c[#c + 1] = z
                    n = n + 1
                end
            end
        end
    end
    return { count = n, groups = groups }
end

function C.schem_holo(sch)
    if sch.holo == nil then sch.holo = build_holo(sch) end
    return sch.holo
end

-------------------------------------------------------------------------------
-- Export as Lua: a block script (world node) that builds the schematic inside
-- the block, the way xar's "snap" console command writes one for a chunk -
-- plus the ents and monsters, and with the blocks merged into big boxes:
-- greedy 3D merging per block type (grow along x, then y, then z while every
-- cell is that type), linear time, so it's fine on big builds (xar's
-- game_merge_engine merges pairs, which gets slow). Boxes -> create_rect,
-- single blocks -> set_pos. A block holds 16x16x16 cells, so a bigger
-- schematic is cut into pieces (one script each, to place side by side).
-- Middle-click a schematic in the SCHEMS tab. Files go to
-- Output/FileOut/block_schem_<name>[_x_y_z].lua (the engine only writes there,
-- names only a-z A-Z 0-9 _ and one dot).
-------------------------------------------------------------------------------

local CHUNK = 16
local YEAR  = 60 * 60 * 24 * 365

-- boxes of equal block type: { { v, x0, y0, z0, x1, y1, z1 }, ... }
-- get(x, y, z) = palette index (0 = empty) for 0 <= x < nx etc.
local function merge_boxes(get, nx, ny, nz)
    local done, boxes = {}, {}
    local function id(x, y, z) return 1 + x + nx * (y + ny * z) end
    local function free(x, y, z, v) return get(x, y, z) == v and not done[id(x, y, z)] end
    for z = 0, nz - 1 do
        for y = 0, ny - 1 do
            for x = 0, nx - 1 do
                local v = get(x, y, z)
                if v > 0 and not done[id(x, y, z)] then
                    local x1, y1, z1 = x, y, z
                    while x1 + 1 < nx and free(x1 + 1, y, z, v) do x1 = x1 + 1 end
                    local function row(yy, zz)
                        for xx = x, x1 do if not free(xx, yy, zz, v) then return false end end
                        return true
                    end
                    while y1 + 1 < ny and row(y1 + 1, z) do y1 = y1 + 1 end
                    local function layer(zz)
                        for yy = y, y1 do if not row(yy, zz) then return false end end
                        return true
                    end
                    while z1 + 1 < nz and layer(z1 + 1) do z1 = z1 + 1 end
                    for zz = z, z1 do for yy = y, y1 do for xx = x, x1 do done[id(xx, yy, zz)] = true end end end
                    boxes[#boxes + 1] = { v, x, y, z, x1, y1, z1 }
                end
            end
        end
    end
    return boxes
end
C.schem_merge_boxes = merge_boxes          -- (tests)

local function q(s) return string.format("%q", s) end
local function n3(v) return (string.gsub(string.format("%.3f", v), "%.?0+$", "")) end

-- one piece: schematic cells [cx0, cx0 + nx) x ..., drawn at chunk offset off*
local function piece_lines(sch, fname, label, cx0, cy0, cz0, nx, ny, nz, offx, offy, offz)
    local sx, sy = sch.sx, sch.sy
    local function get(x, y, z) return sch.cells[1 + (cx0 + x) + sx * ((cy0 + y) + sy * (cz0 + z))] end
    local boxes = merge_boxes(get, nx, ny, nz)

    -- the look from outside: the most common block's texture, when known
    local count, best, best_n = {}, nil, 0
    for _, b in ipairs(boxes) do
        local v = b[1]
        count[v] = (count[v] or 0) + (b[5] - b[2] + 1) * (b[6] - b[3] + 1) * (b[7] - b[4] + 1)
        if count[v] > best_n then best, best_n = v, count[v] end
    end
    local tex = best and ghost_tex(sch.pal[best]) or nil

    local L = {
        "-- " .. fname .. ".lua - made by the Creative Menu (FBW_Creative_Menu mod) from schematic",
        "-- " .. q(sch.name) .. " (" .. C.schem_dims_str(sch) .. ")" .. label .. ".",
        "-- Use: copy this file into a package's WorldNodes/Nodes/ folder; the block type is then",
        "-- " .. q(fname) .. ". Place it and shrink into it to see the build.",
        "-- Blocks are merged into boxes (create_rect); single blocks use set_pos.",
        "",
    }
    if tex then
        L[#L + 1] = "function p.__get_is_solid() return true end"
        L[#L + 1] = "function p.__get_tex() return " .. q(tex) .. " end   -- the block seen from outside"
    else
        L[#L + 1] = "function p.__get_is_solid() return false end"
        L[#L + 1] = "function p.__get_tex() return \"\" end   -- the block seen from outside (none set)"
    end
    L[#L + 1] = ""
    L[#L + 1] = "function p.__main()"
    L[#L + 1] = "    set_default_block(\"e\")   -- air in every other cell"
    local nb, nset = 0, 0
    for _, b in ipairs(boxes) do
        local name = sch.pal[b[1]]
        local bad = type(block_wiki_bad_blocks) == "table" and block_wiki_bad_blocks[name]
        if not bad then
            local x0, y0, z0 = b[2] + offx, b[3] + offy, b[4] + offz
            local x1, y1, z1 = b[5] + offx, b[6] + offy, b[7] + offz
            if x0 == x1 and y0 == y1 and z0 == z1 then
                L[#L + 1] = "    set_pos(" .. x0 .. "," .. y0 .. "," .. z0 .. ", " .. q(name) .. ")"
                nset = nset + 1
            else
                L[#L + 1] = "    create_rect(" .. q(name) .. ", " .. x0 .. "," .. y0 .. "," .. z0 .. ", "
                    .. x1 .. "," .. y1 .. "," .. z1 .. ")"
                nb = nb + 1
            end
        end
    end
    local function inside(x, y, z)
        return x >= cx0 and x < cx0 + nx and y >= cy0 and y < cy0 + ny and z >= cz0 and z < cz0 + nz
    end
    -- trophy names
    local cells = {}
    for c, _ in pairs(sch.tro) do cells[#cells + 1] = c end
    table.sort(cells)
    for _, c in ipairs(cells) do
        local i = c - 1
        local x, y, z = i % sx, math.floor(i / sx) % sy, math.floor(i / (sx * sy))
        if inside(x, y, z) then
            L[#L + 1] = "    block_set_s(" .. (x - cx0 + offx) .. "," .. (y - cy0 + offy) .. "," .. (z - cz0 + offz)
                .. ", \"api_name\", " .. q(sch.tro[c]) .. ")"
        end
    end
    -- basic ents with their params
    local ne, nm = 0, 0
    for _, e in ipairs(sch.bents) do
        if inside(e.x, e.y, e.z) and C.bent_param_valid(e.t, e.ps) then
            local at = (e.x - cx0 + offx) .. "," .. (e.y - cy0 + offy) .. "," .. (e.z - cz0 + offz)
            if e.pi ~= 0 then
                L[#L + 1] = "    add_bent_i(" .. at .. ", " .. q(e.t) .. ", " .. e.pi .. ")"
                if e.ps ~= "" then L[#L + 1] = "    bent_set_param_s(" .. at .. ", " .. q(e.ps) .. ")" end
            elseif e.ps ~= "" then
                L[#L + 1] = "    add_bent_s(" .. at .. ", " .. q(e.t) .. ", " .. q(e.ps) .. ")"
            else
                L[#L + 1] = "    add_bent(" .. at .. ", " .. q(e.t) .. ")"
            end
            ne = ne + 1
        end
    end
    -- monsters: start in their cell, then the exact spot + HP / frozen / texture
    for _, m in ipairs(sch.ments) do
        local fx, fy, fz = math.floor(m.x), math.floor(m.y), math.floor(m.z)
        if inside(fx, fy, fz) then
            local px, py, pz = m.x - cx0 + offx, m.y - cy0 + offy, m.z - cz0 + offz
            L[#L + 1] = "    ment_start(" .. math.floor(px) .. "," .. math.floor(py) .. "," .. math.floor(pz)
                .. ", " .. q(m.t) .. ")"
            L[#L + 1] = "    ment_set_offset(" .. n3(px) .. ", " .. n3(py) .. ", " .. n3(pz) .. ")"
            local function has(var)
                local ok, r = pcall(ga_ment_type_var_exists, m.t, var)
                return ok and r == true
            end
            if m.hp and m.hp > 0 then
                for _, var in ipairs({ "health", "health_curved", "health_max_curved" }) do
                    if has(var) then L[#L + 1] = "    ment_set_i(" .. q(var) .. ", " .. m.hp .. ")" end
                end
            end
            if m.fz then
                L[#L + 1] = "    ment_set_b(\"__vel_disabled\", true)"
                L[#L + 1] = "    ment_set_b(\"__turning_disabled\", true)"
                if has("frozen") then                  -- = xar's laser freeze, for a year
                    L[#L + 1] = "    ment_set_b(\"frozen\", true)"
                    L[#L + 1] = "    ment_set_s(\"__tex_override\", \"ice\")"
                    if has("freeze_endtime") then
                        L[#L + 1] = "    ment_set_f(\"freeze_endtime\", get_game_time() + " .. YEAR .. ")"
                    end
                end
            elseif m.tex and m.tex ~= "" then
                L[#L + 1] = "    ment_set_s(\"__tex_override\", " .. q(m.tex) .. ")"
            end
            L[#L + 1] = "    ment_end()"
            nm = nm + 1
        end
    end
    L[#L + 1] = "end"
    return L, { boxes = nb, singles = nset, ents = ne, monsters = nm }
end

-- Writes the schematic's block script(s). Returns the file names (nil on error).
function C.schem_export_lua(name)
    local sch = S.schems[name]
    if sch == nil then
        ga_hud_msg("Schematic " .. tostring(name) .. " not found", 2.0)
        return nil
    end
    local px = math.ceil(sch.sx / CHUNK)
    local py = math.ceil(sch.sy / CHUNK)
    local pz = math.ceil(sch.sz / CHUNK)
    local single = (px * py * pz == 1)
    local base = "block_schem_" .. string.lower((string.gsub(name, "[^%w_]", "_")))
    local written, stats = {}, { boxes = 0, singles = 0, ents = 0, monsters = 0 }
    for k = 0, pz - 1 do
        for j = 0, py - 1 do
            for i = 0, px - 1 do
                local cx0, cy0, cz0 = i * CHUNK, j * CHUNK, k * CHUNK
                local nx = math.min(CHUNK, sch.sx - cx0)
                local ny = math.min(CHUNK, sch.sy - cy0)
                local nz = math.min(CHUNK, sch.sz - cz0)
                -- one block: centred, standing on the bottom; pieces fill their block
                local offx = single and math.floor((CHUNK - nx) / 2) or 0
                local offy = single and math.floor((CHUNK - ny) / 2) or 0
                local fname = single and base or (base .. "_" .. i .. "_" .. j .. "_" .. k)
                local label = single and "" or
                    (", piece x" .. i .. " y" .. j .. " z" .. k .. " of " .. px .. "x" .. py .. "x" .. pz
                     .. " (the build is bigger than one block: place the pieces side by side)")
                local lines, st = piece_lines(sch, fname, label, cx0, cy0, cz0, nx, ny, nz, offx, offy, 0)
                if not write_file(fname .. ".lua", lines) then
                    ga_hud_msg("Could not write Output/FileOut/" .. fname .. ".lua", 3.0)
                    return nil
                end
                written[#written + 1] = fname .. ".lua"
                for key, v in pairs(st) do stats[key] = stats[key] + v end
            end
        end
    end
    local what = stats.boxes .. " create_rect + " .. stats.singles .. " set_pos"
    if stats.ents > 0 then what = what .. ", " .. stats.ents .. " ents" end
    if stats.monsters > 0 then what = what .. ", " .. stats.monsters .. " monsters" end
    if single then
        ga_hud_msg("Saved Output/FileOut/" .. written[1] .. "  (" .. what .. ")", 4.0)
    else
        ga_hud_msg("Saved " .. #written .. " pieces Output/FileOut/" .. base .. "_X_Y_Z.lua  (" .. what .. ")", 5.0)
    end
    return written
end
