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

local function do_worldgen(func)
    local chunk = C.BLANK_CHUNK()
    local function fix(bt)
        if bt:sub(1,4) ~= "XAR_" and bt:sub(1,6) ~= "block_" then return "block_" .. bt end
        return bt
    end
    ga_srand(saved_seed)
    local worked,err = p.wrap_func_call(func, {}, {
        set_default_block = function(bt)
            chunk.def = fix(bt)
        end,
        set_pos = function(x,y,z,bt)
            if x < 0 or x > 15 or y < 0 or y > 15 or z < 0 or z > 15 then return end
            chunk.blocks[x*256+y*16+z] = fix(bt)
        end,
        create_rect = function(bt,x1,y1,z1,x2,y2,z2)
            bt = fix(bt)
            if x2 < x1 then x1,x2 = x2,x1 end
            if y2 < y1 then y1,y2 = y2,y1 end
            if z2 < z1 then z1,z2 = z2,z1 end
            for x = x1,x2 do
                for y = y1,y2 do
                    for z = z1,z2 do
                        if not (x < 0 or x > 15 or y < 0 or y > 15 or z < 0 or z > 15) then
                            chunk.blocks[x*256+y*16+z] = bt
                        end
                    end
                end
            end
        end,
        base_blue_tele = {
            set_blue_type_down = function()end
        },
        add_bent = function(x,y,z,bent)
            if x < 0 or x > 15 or y < 0 or y > 15 or z < 0 or z > 15 then return end
            chunk.bents[x*256+y*16+z] = bent
        end,
        add_bent_s = function(x,y,z,bent,str)
            if x < 0 or x > 15 or y < 0 or y > 15 or z < 0 or z > 15 then return end
            chunk.bents[x*256+y*16+z] = bent
        end,
        block_set_s = function()end,
        randi = ga_randi,
        randf = ga_randf,
    })
    if not worked then ga_console_print("^1Error in worldgen in game lua state: " .. err) return false end
    return chunk
end

local yaw = 0
local pitch = 0
local timer = -100

local last_cursor = nil
local function render_chunk(wid,chunk)
    local cursor = ga_win_get_cursor_pos(wid)
    last_cursor = last_cursor or cursor
    if ga_win_mouse_down(true) then
        timer = -100
        yaw = yaw + (cursor.x-last_cursor.x)*720
        pitch = pitch + (cursor.y-last_cursor.y)*360
        if pitch > 90 then pitch = 90 end
        if pitch < -90 then pitch = -90 end
    end
    timer = timer + 1
    if timer > 0 then
        yaw = yaw - ga_get_sys_f("time.elapsed")*30
    end
    -- RAW rendering...
    ga_render_matrix_scaled(0.03,0.03,0.03)
    ga_render_matrix_scaled(1/S.aspect,1,1)
    ga_render_matrix_rotated(90,std.vec(0,1,0))
    ga_render_matrix_rotated(-90,std.vec(1,0,0))
    ga_render_matrix_rotated(pitch,std.vec(0,1,0))
    ga_render_matrix_rotated(yaw,std.vec(0,0,1))
    ga_render_matrix_translated(-8,-8,-8)
    ga_render_set_depth_test_enabled(false)
    ga_render_push_matrix()
    ga_render_matrix_scaled(16,16,16)
    ga_render_mesh_with_tex_alpha_no_lighting("creative_block","creative_white",0.1)
    ga_render_pop_matrix()
    ga_render_set_depth_test_enabled(true)
    for x = 0,15 do
        for y = 0,15 do
            for z = 0,15 do
                local bt = chunk.blocks[x*256+y*16+z] or chunk.def
                local tex = C.block_tex(bt)
                if tex and tex ~= "" then
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
        if _G[v] and _G[v].__on_render then
            p.wrap_func_call(_G[v].__on_render,{0,bp},{
                ga_get_game_time = function()
                    return ga_get_sys_f("time.current")
                end,
            })
        elseif _G[v] and _G[v].__get_mesh then
            --Creating the classic "pulsating" look.
            local cur_time = ga_get_sys_f("time.current")--ga_get_game_time()
            local scale = 1.0 + math.cos(6.0 * cur_time) * 0.1
            if _G[v].__get_pulsates and not _G[v].__get_pulsates() then scale = 1.0 end
            if _G[v].__get_scale then scale = scale * _G[v].__get_scale() end
            ga_render_matrix_scaled(scale, scale, scale);
            --
            -- local mesh_name = "txt_not_yet_added"
            local mesh_name = _G[v].__get_mesh()
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
        ga_render_pop_matrix()
    end
    last_cursor = cursor
end

function C.render_worldgen_tab(wid)
    if S.worldgen_picked_block then
        saved_chunk_bt = S.worldgen_picked_block.raw
        saved_dirty = true
        S.worldgen_picked_block = nil
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
    if has_error then
        ga_win_set_front_color(wid, std.vec(1,0,0))
        ga_win_set_char_size(wid, 0.02, 0.04)
        ga_win_txt(wid, 0.7-0.01*7,0.45-0.02, "ERRORED")
    else
        ga_render_set_depth_test_enabled(true)
        ga_render_push_matrix()
        ga_render_matrix_translated(0.75,0.45,0)
        render_chunk(wid,saved_chunk)
        ga_render_pop_matrix()
        ga_render_set_depth_test_enabled(false)
    end
    C.render_grid_tab(wid,"worldgen")
end

-- TODO add uncrash info