creative_ui = creative_ui or {}          -- shared by all win_creative*.lua files (one window Lua state)
creative_ui.state = creative_ui.state or {}
local C, S = creative_ui, creative_ui.state

function C.BLANK_CHUNK() -- is a function so chunk objects are safe to mutate.
    return { def = "block_default_not_set", blocks = {}, bents = {} }
end

local saved_chunk = C.BLANK_CHUNK()
local saved_chunk_bt = ""
local saved_seed = nil       -- the SEED box; starts as the world seed (set when the tab first draws)

-- the world seed (game side, Game/game_creative_chunklib.lua C.world_seed)
function C.world_seed()
    local g = rawget(_G, "creative_g")
    if type(g) == "table" and type(g.world_seed) == "function" then
        local ok, v = pcall(g.world_seed)
        if ok and type(v) == "number" then return v end
    end
    return 0
end
local saved_dirty = false
local has_error = false

-- stole this from another project of mine
function p.wrap_func_call(func, args, globals)
    local old = {}
    for i,v in pairs(globals) do
        old[i] = _G[i]
        _G[i] = v
    end
    local out = {pcall(func, table.unpack(args))}
    for i,v in pairs(globals) do
        _G[i] = old[i]
    end
    return table.unpack(out)
end

-------------------------------------------------------------------------------
-- Random numbers for the preview. Its own generator: ga_srand / ga_randi
-- would reseed and use up the GAME's random numbers. xorshift64* (Lua 5.3
-- integers wrap around at 64 bit, >> is a logical shift).
-------------------------------------------------------------------------------
local rng_state = 1

local function rng_seed(seed)
    local s = math.tointeger(seed)
    if s == nil then
        s = math.floor(tonumber(seed) or 0)
        if math.type(s) ~= "integer" then s = 0 end
    end
    local z = s + 0x9E3779B97F4A7C15             -- splitmix64: close seeds -> unrelated streams
    z = (z ~ (z >> 30)) * 0xBF58476D1CE4E5B9
    z = (z ~ (z >> 27)) * 0x94D049BB133111EB
    z = z ~ (z >> 31)
    if z == 0 then z = 1 end
    rng_state = z
end

local function rng_float()                       -- [0, 1)
    local x = rng_state
    x = x ~ (x >> 12)
    x = x ~ (x << 25)
    x = x ~ (x >> 27)
    rng_state = x
    return ((x * 0x2545F4914F6CDD1D) >> 11) / 9007199254740992.0
end

local function rng_int(a, b)                     -- a..b, both ends included
    if b < a then a, b = b, a end
    return a + math.floor(rng_float() * (b - a + 1))
end

-------------------------------------------------------------------------------
-- Stand-ins for the chunk generation API (Output/Documentation/ProgrammingAPI/
-- chunk_generation_api_functions.txt). A block's __main normally runs inside
-- the engine's chunk generator; here it runs in the window with these
-- functions put in _G for the call (p.wrap_func_call puts the old ones back).
-- Not faked: mazes, caves, perlin noise, exit -> those generators show ERRORED.
-------------------------------------------------------------------------------
local function in_chunk(x, y, z)
    return x >= 0 and x <= 15 and y >= 0 and y <= 15 and z >= 0 and z <= 15
end

local function make_gen_api(chunk, real_std, seed, bt)
    local function fix(bt)
        if type(bt) ~= "string" then return "block_e" end
        if bt:sub(1,4) ~= "XAR_" and bt:sub(1,6) ~= "block_" then return "block_" .. bt end
        return bt
    end
    local api = {}
    local function nop() end

    -- block types as integer codes (the *_c functions)
    local codes, code_of = {}, {}
    function api.bt_str_to_code(bt)
        local k = code_of[bt]
        if k == nil then
            k = #codes + 1
            codes[k] = bt
            code_of[bt] = k
        end
        return k
    end
    function api.bt_code_to_str(code) return codes[code] or "e" end

    -- blocks
    function api.set_default_block(bt) chunk.def = fix(bt) end
    function api.set_default_block_c(code) chunk.def = fix(codes[code]) end
    function api.set_pos(x, y, z, bt)
        if not in_chunk(x, y, z) then return end
        chunk.blocks[x*256+y*16+z] = fix(bt)
    end
    function api.set_pos_c(x, y, z, code) api.set_pos(x, y, z, codes[code]) end
    function api.get_pos(x, y, z)
        if not in_chunk(x, y, z) then return chunk.def end
        return chunk.blocks[x*256+y*16+z] or chunk.def
    end
    function api.get_pos_c(x, y, z) return api.bt_str_to_code(api.get_pos(x, y, z)) end
    function api.create_rect(bt, x1, y1, z1, x2, y2, z2)
        bt = fix(bt)
        if x2 < x1 then x1,x2 = x2,x1 end
        if y2 < y1 then y1,y2 = y2,y1 end
        if z2 < z1 then z1,z2 = z2,z1 end
        for x = math.max(x1, 0), math.min(x2, 15) do
            for y = math.max(y1, 0), math.min(y2, 15) do
                for z = math.max(z1, 0), math.min(z2, 15) do
                    chunk.blocks[x*256+y*16+z] = bt
                end
            end
        end
    end
    function api.create_rect_c(code, x1, y1, z1, x2, y2, z2)
        api.create_rect(codes[code], x1, y1, z1, x2, y2, z2)
    end
    function api.create_sprinkles(x1, y1, z1, x2, y2, z2, prob, bt)
        bt = fix(bt)
        if x2 < x1 then x1,x2 = x2,x1 end
        if y2 < y1 then y1,y2 = y2,y1 end
        if z2 < z1 then z1,z2 = z2,z1 end
        for x = x1,x2 do
            for y = y1,y2 do
                for z = z1,z2 do
                    if in_chunk(x, y, z) and rng_float() < prob then
                        chunk.blocks[x*256+y*16+z] = bt
                    end
                end
            end
        end
    end
    function api.create_sprinkles_c(x1, y1, z1, x2, y2, z2, prob, code)
        api.create_sprinkles(x1, y1, z1, x2, y2, z2, prob, codes[code])
    end
    function api.bt_get_is_solid_physically(bt) return false end

    -- create_xar_chunk("XAR_FOO"): in the game, the chunk becomes what the
    -- built-in block XAR_FOO's compiled generator makes. Here: that type's
    -- chunk library sample (Game/game_creative_chunklib.lua) - exactly the
    -- game's result for generators without randomness; for the others the
    -- SEED picks one of the library's results. The Lua code can go on
    -- changing blocks after it.
    function api.create_xar_chunk(bt)
        if type(bt) ~= "string" or bt:sub(1, 4) ~= "XAR_" then
            error('create_xar_chunk: the block type must start with "XAR_", got ' .. tostring(bt))
        end
        local g = rawget(_G, "creative_g")
        local lib = (type(g) == "table" and type(g.clib_chunk) == "function") and g.clib_chunk(bt, seed) or nil
        if lib == nil then error("create_xar_chunk: no chunk library entry for " .. bt) end
        chunk.def = lib.def
        chunk.blocks = {}
        for i, name in pairs(lib.blocks) do chunk.blocks[i] = name end   -- (a copy: the Lua code may change it)
        chunk.bents = {}
        for _, e in ipairs(lib.lib_ents or {}) do chunk.bents[e.x*256+e.y*16+e.z] = e.t end
    end

    -- interactables (drawn); monsters, env rects and vars are ignored
    local function bent(x, y, z, name)
        if in_chunk(x, y, z) then chunk.bents[x*256+y*16+z] = name end
    end
    api.add_bent = bent
    api.add_bent_i = bent
    api.add_bent_s = bent
    for _, n in ipairs({ "bent_set_param_i", "bent_set_param_s",
                         "add_ment", "ment_start", "ment_set_b", "ment_set_i", "ment_set_f",
                         "ment_set_v", "ment_set_s", "ment_set_offset", "ment_end", "add_env_rect",
                         "block_set_b", "block_set_i", "block_set_f", "block_set_v", "block_set_s",
                         "chunk_set_b", "chunk_set_i", "chunk_set_f", "chunk_set_v", "chunk_set_s",
                         "chunk_dyn_set_b", "chunk_dyn_set_i", "chunk_dyn_set_f", "chunk_dyn_set_v",
                         "chunk_dyn_set_s", "set_blue_type_up", "set_blue_type_down",
                         "set_blue_type_terminal" }) do
        api[n] = nop
    end

    -- random numbers + seeds (every seed = the SEED box)
    api.srand = rng_seed
    api.randi = rng_int
    api.randf = rng_float
    for _, n in ipairs({ "seed_normal", "seed_nearby", "seed_xy", "seed_xz", "seed_yz",
                         "seed_normal_chop", "seed_nearby_chop", "seed_xy_chop", "seed_xz_chop",
                         "seed_yz_chop", "seed_from_last_of_type", "get_world_seed" }) do
        api[n] = function() return seed end
    end

    -- where the chunk is: the preview has no parent chunks
    function api.get_level() return 0 end
    function api.get_input_path_length() return 0 end
    -- path = positions 0..len-1, bts = block types 0..len (len = this block)
    function api.get_input_path() return {} end
    function api.get_input_path_bt() return "block_e" end
    function api.get_input_path_bts() return { [0] = { name = bt } } end
    function api.get_input_adj_bt() return "block_e" end
    function api.get_input_parent_adj_bt() return "block_e" end
    function api.get_input_path_block_var_exists() return false end
    function api.get_input_path_block_b() return false end
    function api.get_input_path_block_i() return 0 end
    function api.get_input_path_block_f() return 0.0 end
    function api.get_input_path_block_v() return std.vec(0, 0, 0) end
    function api.get_input_path_block_s() return "" end
    function api.state_get_b() return false end
    function api.state_get_i() return 0 end
    function api.state_get_f() return 0.0 end
    function api.state_get_v() return std.vec(0, 0, 0) end
    function api.state_get_s() return "" end
    function api.get_sys_time() return ga_get_sys_f("time.current") end
    function api.get_game_time() return ga_get_sys_f("time.current") end

    -- every chunk generation function may also start with "gen_"
    local names = {}
    for k in pairs(api) do names[#names + 1] = k end
    for _, k in ipairs(names) do api["gen_" .. k] = api[k] end

    -- base's chunk helper modules. The block helpers below are base's
    -- WorldNodes/Helpers/std.lua ones (same rects); everything else falls
    -- back to the real std (std.vec, std.bp, ...).
    local rect_c = api.create_rect_c
    local h = {}
    function h.create_center_c(diam, bt_int)
        if diam >= 1 and diam <= 13 then
            local half = (diam - 1) >> 1
            local x1, x2 = 7 - half, 7 + half
            if diam % 2 == 0 then x2 = x2 + 1 end
            rect_c(bt_int, x1,x1,x1, x2,x2,x2)
        end
    end
    function h.create_tube_c(diam, axis, bt_int)
        if diam >= 1 and diam <= 6 then
            local half = (diam - 1) >> 1
            local k1, k2 = 7 - half, 7 + half
            if diam % 2 == 0 then k2 = k2 + 1 end
            if     axis == "x" then rect_c(bt_int, 0,k1,k1, 15,k2,k2)
            elseif axis == "y" then rect_c(bt_int, k1,0,k1, k2,15,k2)
            elseif axis == "z" then rect_c(bt_int, k1,k1,0, k2,k2,15) end
        end
    end
    function h.create_half_tube_c(diam, dir, bt_int)
        if diam >= 1 and diam <= 6 then
            local half = (diam - 1) >> 1
            local i1, i2 = 7 - half, 7 + half
            if diam % 2 == 0 then i2 = i2 + 1 end
            if     dir == "x_pos" then rect_c(bt_int, i1,i1,i1, 15,i2,i2)
            elseif dir == "x_neg" then rect_c(bt_int, 0,i1,i1, i2,i2,i2)
            elseif dir == "y_pos" then rect_c(bt_int, i1,i1,i1, i2,15,i2)
            elseif dir == "y_neg" then rect_c(bt_int, i1,0,i1, i2,i2,i2)
            elseif dir == "z_pos" then rect_c(bt_int, i1,i1,i1, i2,i2,15)
            elseif dir == "z_neg" then rect_c(bt_int, i1,i1,0, i2,i2,i2) end
        end
    end
    function h.create_edges_c(bt_int)
        rect_c(bt_int, 0,0,0,   15,0,0)
        rect_c(bt_int, 0,0,15,  15,0,15)
        rect_c(bt_int, 0,15,0,  15,15,0)
        rect_c(bt_int, 0,15,15, 15,15,15)
        rect_c(bt_int, 0,0,0,   0,15,0)
        rect_c(bt_int, 0,0,15,  0,15,15)
        rect_c(bt_int, 15,0,0,  15,15,0)
        rect_c(bt_int, 15,0,15, 15,15,15)
        rect_c(bt_int, 0,0,0,   0,0,15)
        rect_c(bt_int, 0,15,0,  0,15,15)
        rect_c(bt_int, 15,0,0,  15,0,15)
        rect_c(bt_int, 15,15,0, 15,15,15)
    end
    function h.create_shell_c(bt_int)
        rect_c(bt_int, 0,0,0,  0,15,15)
        rect_c(bt_int, 15,0,0, 15,15,15)
        rect_c(bt_int, 0,0,0,  15,0,15)
        rect_c(bt_int, 0,15,0, 15,15,15)
        rect_c(bt_int, 0,0,0,  15,15,0)
        rect_c(bt_int, 0,0,15, 15,15,15)
    end
    function h.create_2x2_door_c(dir, rim, hole)
        if     dir == "x_pos" then rect_c(rim, 15,6,6, 15,9,9); rect_c(hole, 15,7,7, 15,8,8)
        elseif dir == "x_neg" then rect_c(rim, 0,6,6, 0,9,9);   rect_c(hole, 0,7,7, 0,8,8)
        elseif dir == "y_pos" then rect_c(rim, 6,15,6, 9,15,9); rect_c(hole, 7,15,7, 8,15,8)
        elseif dir == "y_neg" then rect_c(rim, 6,0,6, 9,0,9);   rect_c(hole, 7,0,7, 8,0,8)
        elseif dir == "z_pos" then rect_c(rim, 6,6,15, 9,9,15); rect_c(hole, 7,7,15, 8,8,15)
        elseif dir == "z_neg" then rect_c(rim, 6,6,0, 9,9,0);   rect_c(hole, 7,7,0, 8,8,0) end
    end
    local code = api.bt_str_to_code
    function h.create_center(diam, bt) h.create_center_c(diam, code(bt)) end
    function h.create_tube(diam, axis, bt) h.create_tube_c(diam, axis, code(bt)) end
    function h.create_half_tube(diam, dir, bt) h.create_half_tube_c(diam, dir, code(bt)) end
    function h.create_edges(bt) h.create_edges_c(code(bt)) end
    function h.create_shell(bt) h.create_shell_c(code(bt)) end
    function h.create_2x2_door(dir, rim, hole) h.create_2x2_door_c(dir, code(rim), code(hole)) end
    api.std = setmetatable(h, { __index = real_std })

    -- base_blue_tele (blue ring chunks): every function does nothing here
    api.base_blue_tele = setmetatable({}, { __index = function() return nop end })
    return api
end

-- does block type bt have a Lua chunk generator (its module's __main)? The
-- built-in XAR_* blocks are made by FBW.exe itself: nothing to run for them.
local function block_module(bt)
    if type(bt) ~= "string" or bt == "" then return nil end
    local ok, m = pcall(function() return _G[bt] end)
    if ok and type(m) == "table" then return m end
    return nil
end
function C.wg_has_gen(bt)
    local m = block_module(bt)
    return m ~= nil and type(m.__main) == "function"
end

-- Runs bt's generator with the stand-ins above. Returns the chunk table, or
-- nil (+ the error, also printed) when it errored. Also used by the BLOCKS
-- tab's PREVIEW (win_creative_blockview.lua).
function C.wg_generate(bt, seed)
    local chunk = C.BLANK_CHUNK()
    local m = block_module(bt)
    local func = m and m.__main or nil
    rng_seed(seed)
    local worked,err = p.wrap_func_call(func, {}, make_gen_api(chunk, std, seed, bt))
    if not worked then ga_console_print("^1Error in worldgen in game lua state: " .. tostring(err)) return nil, err end
    return chunk
end

-- sub = { x1, y1, z1, x2, y2, z2 }: the part of the chunk that is drawn
local function sub_is_full(sub)
    return sub[1] == 0 and sub[2] == 0 and sub[3] == 0
       and sub[4] == 15 and sub[5] == 15 and sub[6] == 15
end
C.WG_FULL = { 0, 0, 0, 15, 15, 15 }

local cam = nil                          -- C.cam_new() (win_creative_view3d.lua), made on first use
local GIZMO_X, GIZMO_Y = 0.1, 0.125

-- cross section: index into subsection (1-3 = X/Y/Z min, 4-6 = X/Y/Z max)
local cross_section_opt = nil
local CUT_FACE  = { ["X-"] = 1, ["Y-"] = 2, ["Z-"] = 3, ["X+"] = 4, ["Y+"] = 5, ["Z+"] = 6 }
local FACE_NAME = { "X-", "Y-", "Z-", "X+", "Y+", "Z+" }

local subsection = {0,0,0,15,15,15}

local function reset_cut()
    subsection = {0,0,0,15,15,15}
    cross_section_opt = nil
end

local function cut_is_full()
    return sub_is_full(subsection)
end

-- a drag only starts on the preview: right of the grid, above the SEED / CUT
-- rows, below the page line (so clicking tiles, buttons or the gizmo doesn't
-- also turn the camera)
local function on_preview(cursor)
    local gx1 = C.X0 + S.COLS * S.CW + 0.01
    return cursor.x > gx1 and cursor.x < 0.99 and cursor.y > 0.26 and cursor.y < 0.80
end

-- flat colour per block type (like the schematic ghost's)
local function type_col(name)
    local h = 0
    for i = 1, #name do h = (h * 31 + string.byte(name, i)) % 100003 end
    return std.vec(0.30 + (h % 60) / 100, 0.30 + (math.floor(h / 7) % 60) / 100, 0.30 + (math.floor(h / 53) % 60) / 100)
end

-- Draws a generated chunk (current matrix = the preview's centre) turned by
-- view_cam, only the part inside sub. Also used by win_creative_blockview.lua.
-- solid_unknown = every block in chunk.blocks is something you'd see (the
-- chunk copies: air is already left out), so blocks without a known texture
-- are drawn white with a colour per type instead of not at all, and only
-- texture names the game really has are used.
function C.wg_render_chunk(view_cam, chunk, sub, solid_unknown)
    -- RAW rendering...
    C.cam_apply(view_cam, 16, 16, 16)
    ga_render_set_depth_test_enabled(false)
    if sub_is_full(sub) then
        ga_render_push_matrix()
        ga_render_matrix_scaled(16,16,16)
        ga_render_mesh_with_tex_alpha_no_lighting("creative_block","creative_white",0.1)
        ga_render_pop_matrix()
    else
        ga_render_push_matrix()
        ga_render_matrix_scaled(16,16,16)
        ga_render_mesh_with_tex_alpha_no_lighting("creative_block","creative_white",0.051)
        ga_render_pop_matrix()
        ga_render_push_matrix()
        ga_render_matrix_translated(sub[1],sub[2],sub[3])
        ga_render_matrix_scaled(sub[4]-sub[1]+1,sub[5]-sub[2]+1,sub[6]-sub[3]+1)
        ga_render_mesh_with_tex_alpha_no_lighting("creative_block","creative_white",0.051)
        ga_render_pop_matrix()
    end
    ga_render_set_depth_test_enabled(true)
    local tex_cache, tint = {}, {}
    local function btex(bt)
        if tex_cache[bt] then return tex_cache[bt] end
        local tex = C.block_tex(bt)
        if solid_unknown and bt ~= chunk.def then
            local real = (tex ~= "") and C.ntex(tex) or nil
            if real then
                tex = real
            else
                tex = "creative_white"
                tint[bt] = type_col(bt)
            end
        end
        tex_cache[bt] = tex
        return tex
    end
    local function solid(bt)
        local tex = btex(bt)
        return tex and tex ~= ""
    end
    local function solidp(x,y,z)
        if not (x >= sub[1] and y >= sub[2] and z >= sub[3] and x <= sub[4] and y <= sub[5] and z <= sub[6]) then return false end
        return solid(chunk.blocks[x*256+y*16+z] or chunk.def)
    end
    for x = 0,15 do
        for y = 0,15 do
            for z = 0,15 do
                local bt = chunk.blocks[x*256+y*16+z] or chunk.def
                local tex = btex(bt)
                if tex and tex ~= "" and x >= sub[1] and y >= sub[2] and z >= sub[3] and x <= sub[4] and y <= sub[5] and z <= sub[6] and
                    not (solidp(x+1,y,z) and solidp(x-1,y,z) and solidp(x,y+1,z) and solidp(x,y-1,z) and solidp(x,y,z+1) and solidp(x,y,z-1))
                    then
                    ga_render_push_matrix()
                    ga_render_matrix_translated(x,y,z)
                    if tint[bt] then ga_render_color(tint[bt]) end
                    ga_render_mesh_with_tex("creative_block",tex)
                    if tint[bt] then ga_render_color(std.vec(1.0, 1.0, 1.0)) end
                    ga_render_pop_matrix()
                end
            end
        end
    end
    -- Interactables. Types that draw themselves (__on_render) are asked to;
    -- the rest get the schematic preview's models (Game/game_creative_render.lua
    -- C.schem_ent_meshes): their mesh (__get_mesh / __get_mesh2, else the one
    -- named like the type) WITH the mesh's own texture, scale and pulse - what
    -- the engine draws - and only meshes the game surely has (an unknown mesh
    -- name quits the game); a small see-through cube for types without one.
    local models = {}
    for i,v in pairs(chunk.bents) do
        local bp = std.vec(i//256,i//16%16,i%16)
        local x,y,z = bp.x,bp.y,bp.z
        if x >= sub[1] and y >= sub[2] and z >= sub[3] and x <= sub[4] and y <= sub[5] and z <= sub[6] then
            if _G[v] and _G[v].__on_render then
                ga_render_push_matrix()
                ga_render_matrix_translated(bp.x+0.5,bp.y+0.5,bp.z+0.5)
                p.wrap_func_call(_G[v].__on_render,{0,bp},{
                    ga_get_game_time = function()
                        return ga_get_sys_f("time.current")
                    end,
                })
                ga_render_pop_matrix()
            else
                models[#models + 1] = { x = x, y = y, z = z, t = v, pi = 0, ps = "" }
            end
        end
    end
    local g = rawget(_G, "creative_g")
    if #models > 0 and type(g) == "table" and type(g.schem_ent_meshes) == "function" then
        ga_render_color(std.vec(1.0, 1.0, 1.0))
        g.schem_ent_meshes({ bents = models, ments = {} }, 0, 0, 0, nil, true)
    end
end

function C.render_worldgen_tab(wid)
    local cursor = ga_win_get_cursor_pos(wid)
    if saved_seed == nil then saved_seed = C.world_seed() end
    if S.worldgen_picked_block then
        saved_chunk_bt = S.worldgen_picked_block.raw
        saved_dirty = true
        S.worldgen_picked_block = nil
        reset_cut()                              -- a new block starts uncut
    end
    if saved_dirty then
        local out = C.wg_generate(saved_chunk_bt, saved_seed)
        if out == nil then
            has_error = true
        else
            has_error = false
            saved_chunk = out
        end

        saved_dirty = false
    end
    S.COLS = math.max(1, math.floor((C.GRID_W + C.GAPX) / S.CW)) // 2
    S.PER_PAGE = S.COLS * S.ROWS
    cam = cam or C.cam_new()
    C.cam_input(wid, cam, function(c)
        return on_preview(c) and not C.cam_on_gizmo(c, GIZMO_X, GIZMO_Y)
    end)
    if has_error then
        ga_win_set_front_color(wid, std.vec(1,0,0))
        ga_win_set_char_size(wid, 0.02, 0.04)
        ga_win_txt(wid, 0.7-0.01*7,0.45-0.02, "ERRORED")
        ga_win_set_front_color_default(wid)
    else
        ga_render_set_depth_test_enabled(true)
        ga_render_push_matrix()
        ga_render_matrix_translated(0.75,0.45,0)
        C.wg_render_chunk(cam, saved_chunk, subsection)
        ga_render_pop_matrix()
        ga_render_set_depth_test_enabled(false)
    end
    C.render_grid_tab(wid,"worldgen")

    ga_win_set_screen_coord_mode(wid,"screen")
    -- gizmo (bottom left): an axis label also picks that side for the cut
    local label = C.cam_gizmo(wid, cam, GIZMO_X, GIZMO_Y)
    if label and CUT_FACE[label] then cross_section_opt = CUT_FACE[label] end

    -- CUT row: the side picked on the gizmo, - / + moves that side's plane
    local pressed = ga_win_mouse_pressed(wid, true) and not S.help_open
    if cross_section_opt then
        ga_win_set_char_size(wid, 0.009, 0.018)
        ga_win_txt(wid, 0.215, 0.11, "CUT " .. FACE_NAME[cross_section_opt])
        if C.small_btn(wid, cursor, 0.3,0.1, 0.03,0.035, "-", false) and pressed then
            ga_play_sound("menu_select")
            subsection[cross_section_opt] = subsection[cross_section_opt] - 1
        end
        if C.small_btn(wid, cursor, 0.4,0.1, 0.03,0.035, "+", false) and pressed then
            ga_play_sound("menu_select")
            subsection[cross_section_opt] = subsection[cross_section_opt] + 1
        end
        if subsection[cross_section_opt] < 0 then subsection[cross_section_opt] = 0 end
        if subsection[cross_section_opt] > 15 then subsection[cross_section_opt] = 15 end
        if cross_section_opt <= 3 then
            if subsection[cross_section_opt] > subsection[cross_section_opt+3] then subsection[cross_section_opt] = subsection[cross_section_opt+3] end
        else
            if subsection[cross_section_opt] < subsection[cross_section_opt-3] then subsection[cross_section_opt] = subsection[cross_section_opt-3] end
        end
        ga_win_set_char_size(wid, 0.009, 0.018)
        ga_win_txt(wid, 0.34,0.11, tostring(subsection[cross_section_opt]))
    end
    if not cut_is_full() then
        if C.small_btn(wid, cursor, 0.45,0.1, 0.075,0.035, "RESET", false) and pressed then
            ga_play_sound("menu_select")
            reset_cut()
        end
    end

    -- SEED row
    ga_win_set_char_size(wid, 0.009, 0.018)
    ga_win_txt(wid, 0.172, 0.211, "SEED")
    C.num_field(wid, "seed", 0.3,0.2, 0.01,0.02, saved_seed, function(v)
        saved_seed = v
        saved_dirty = true
    end, { neg = true })
    if C.small_btn(wid, cursor, 0.22,0.2, 0.03,0.035, "-", false) and pressed then
        ga_play_sound("menu_select")
        saved_seed = saved_seed-1
        saved_dirty = true
    end
    if C.small_btn(wid, cursor, 0.25,0.2, 0.03,0.035, "+", false) and pressed then
        ga_play_sound("menu_select")
        saved_seed = saved_seed+1
        saved_dirty = true
    end
end

-- TODO add uncrash info
