creative_ui = creative_ui or {}          -- shared by all win_creative*.lua files (one window Lua state)
creative_ui.state = creative_ui.state or {}
local C, S = creative_ui, creative_ui.state

function C.BLANK_CHUNK() -- is a function so chunk objects are safe to mutate.
    return { def = "block_default_not_set", blocks = {}, bents = {} }
end

local saved_chunk = C.BLANK_CHUNK()
local saved_chunk_bt = ""
local path = "EMPTY_PATH"
local saved_seed = ga_path_to_seed(path)
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

local function make_gen_api(chunk, real_std)
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
        api[n] = function() return saved_seed end
    end

    -- where the chunk is: the preview has no parent chunks
    function api.get_level() return 0 end
    function api.get_input_path_length() return 0 end
    -- path = positions 0..len-1, bts = block types 0..len (len = this block)
    function api.get_input_path() return {} end
    function api.get_input_path_bt() return "block_e" end
    function api.get_input_path_bts() return { [0] = { name = saved_chunk_bt } } end
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

local function do_worldgen(func)
    local chunk = C.BLANK_CHUNK()
    rng_seed(saved_seed)
    local worked,err = p.wrap_func_call(func, {}, make_gen_api(chunk, std))
    if not worked then ga_console_print("^1Error in worldgen in game lua state: " .. tostring(err)) return false end
    return chunk
end

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
    return subsection[1] == 0 and subsection[2] == 0 and subsection[3] == 0
       and subsection[4] == 15 and subsection[5] == 15 and subsection[6] == 15
end

-- a drag only starts on the preview: right of the grid, above the SEED / CUT
-- rows, below the page line (so clicking tiles, buttons or the gizmo doesn't
-- also turn the camera)
local function on_preview(cursor)
    local gx1 = C.X0 + S.COLS * S.CW + 0.01
    return cursor.x > gx1 and cursor.x < 0.99 and cursor.y > 0.26 and cursor.y < 0.80
end

local function render_chunk(wid,chunk)
    -- RAW rendering...
    C.cam_apply(cam, 16, 16, 16)
    ga_render_set_depth_test_enabled(false)
    if cut_is_full() then
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
        ga_render_matrix_translated(subsection[1],subsection[2],subsection[3])
        ga_render_matrix_scaled(subsection[4]-subsection[1]+1,subsection[5]-subsection[2]+1,subsection[6]-subsection[3]+1)
        ga_render_mesh_with_tex_alpha_no_lighting("creative_block","creative_white",0.051)
        ga_render_pop_matrix()
    end
    ga_render_set_depth_test_enabled(true)
    local tex_cache = {}
    local function btex(bt)
        if tex_cache[bt] then return tex_cache[bt] end
        local tex = C.block_tex(bt)
        tex_cache[bt] = tex
        return tex
    end
    local function solid(bt)
        local tex = btex(bt)
        return tex and tex ~= ""
    end
    local function solidp(x,y,z)
        if not (x >= subsection[1] and y >= subsection[2] and z >= subsection[3] and x <= subsection[4] and y <= subsection[5] and z <= subsection[6]) then return false end
        return solid(chunk.blocks[x*256+y*16+z] or chunk.def)
    end
    for x = 0,15 do
        for y = 0,15 do
            for z = 0,15 do
                local bt = chunk.blocks[x*256+y*16+z] or chunk.def
                local tex = btex(bt)
                if tex and tex ~= "" and x >= subsection[1] and y >= subsection[2] and z >= subsection[3] and x <= subsection[4] and y <= subsection[5] and z <= subsection[6] and
                    not (solidp(x+1,y,z) and solidp(x-1,y,z) and solidp(x,y+1,z) and solidp(x,y-1,z) and solidp(x,y,z+1) and solidp(x,y,z-1))
                    then
                    ga_render_push_matrix()
                    ga_render_matrix_translated(x,y,z)
                    ga_render_mesh_with_tex("creative_block",tex)
                    ga_render_pop_matrix()
                end
            end
        end
    end
    for i,v in pairs(chunk.bents) do
        ga_render_push_matrix()
        local bp = std.vec(i//256,i//16%16,i%16)
        ga_render_matrix_translated(bp.x+0.5,bp.y+0.5,bp.z+0.5)
        local x,y,z = bp.x,bp.y,bp.z
        if x >= subsection[1] and y >= subsection[2] and z >= subsection[3] and x <= subsection[4] and y <= subsection[5] and z <= subsection[6] then
            if _G[v] and _G[v].__on_render then
                p.wrap_func_call(_G[v].__on_render,{0,bp},{
                    ga_get_game_time = function()
                        return ga_get_sys_f("time.current")
                    end,
                })
            elseif _G[v] then
                --Creating the classic "pulsating" look.
                local cur_time = ga_get_sys_f("time.current")--ga_get_game_time()
                local scale = 1.0 + math.cos(6.0 * cur_time) * 0.1
                if _G[v].__get_pulsates and not _G[v].__get_pulsates() then scale = 1.0 end
                if _G[v].__get_scale then scale = scale * _G[v].__get_scale() end
                ga_render_matrix_scaled(scale, scale, scale);
                --
                -- local mesh_name = "txt_not_yet_added"
                local mesh_name = _G[v].__get_mesh and _G[v].__get_mesh() or v
                if mesh_name ~= "" then
                    ga_render_mesh(mesh_name)
                end
                if _G[v].__get_mesh2 then
                    mesh_name = _G[v].__get_mesh2()
                    if mesh_name ~= "" then
                        ga_render_mesh(mesh_name)
                    end
                end
            end
        end
        ga_render_pop_matrix()
    end
end

function C.render_worldgen_tab(wid)
    local cursor = ga_win_get_cursor_pos(wid)
    if S.worldgen_picked_block then
        saved_chunk_bt = S.worldgen_picked_block.raw
        saved_dirty = true
        S.worldgen_picked_block = nil
        reset_cut()                              -- a new block starts uncut
    end
    if saved_dirty then
        local out = do_worldgen(_G[saved_chunk_bt] and _G[saved_chunk_bt].__main)
        if out == false then
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
        render_chunk(wid,saved_chunk)
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
