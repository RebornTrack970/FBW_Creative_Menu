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
        create_sprinkles = function(x1,y1,z1,x2,y2,z2, prob, bt)
            bt = fix(bt)
            if x2 < x1 then x1,x2 = x2,x1 end
            if y2 < y1 then y1,y2 = y2,y1 end
            if z2 < z1 then z1,z2 = z2,z1 end
            for x = x1,x2 do
                for y = y1,y2 do
                    for z = z1,z2 do
                        if not (x < 0 or x > 15 or y < 0 or y > 15 or z < 0 or z > 15) and randf() < prob then
                            chunk.blocks[x*256+y*16+z] = bt
                        end
                    end
                end
            end
        end,
        base_blue_tele = {
            set_blue_type_down = function()end,
            set_blue_type_terminal = function()end
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
        chunk_set_s = function()end,
        randi = ga_randi,
        randf = ga_randf,
        get_input_path_length = function()
            return 0
        end,
        get_input_path_bt = function()
            return "block_e"
        end,
        seed_normal = function()
            return saved_seed
        end,
        srand = ga_srand,
        std = {
            create_edges = function(bt)
                create_rect(bt, 0,0,0,   15,0,0)
                create_rect(bt, 0,0,15,  15,0,15)
                create_rect(bt, 0,15,0,  15,15,0)
                create_rect(bt, 0,15,15, 15,15,15)
                --
                create_rect(bt, 0,0,0,   0,15,0)
                create_rect(bt, 0,0,15,  0,15,15)
                create_rect(bt, 15,0,0,  15,15,0)
                create_rect(bt, 15,0,15, 15,15,15)
                --
                create_rect(bt, 0,0,0,   0,0,15)
                create_rect(bt, 0,15,0,  0,15,15)
                create_rect(bt, 15,0,0,  15,0,15)
                create_rect(bt, 15,15,0, 15,15,15)
            end,
        },
        get_pos = function(x,y,z)
            if x < 0 or x > 15 or y < 0 or y > 15 or z < 0 or z > 15 then return chunk.def end
            return chunk.blocks[x*256+y*16+z] or chunk.def
        end,
    })
    if not worked then ga_console_print("^1Error in worldgen in game lua state: " .. err) return false end
    return chunk
end

local yaw = 0
local pitch = 0
local timer = -100

local goal_yaw = 0
local goal_pitch = 0
local goal_moving = false

local cam_locked = false

local cross_section_opt = nil

local can_continue_drag = false

local subsection = {0,0,0,15,15,15}

local last_cursor = nil
local function render_chunk(wid,chunk)
    local cursor = ga_win_get_cursor_pos(wid)
    last_cursor = last_cursor or cursor
    if ga_win_mouse_down(true) and not cam_locked and (can_continue_drag or not (cursor.x > 0.3 and cursor.x < 0.43 and cursor.y > 0.1 and cursor.y < 0.135)) then
        can_continue_drag = true
        timer = -100
        yaw = yaw + (cursor.x-last_cursor.x)*720
        pitch = pitch + (cursor.y-last_cursor.y)*360
        if pitch > 90 then pitch = 90 end
        if pitch < -90 then pitch = -90 end
        goal_moving = false
        cross_section_opt = nil
    elseif not ga_win_mouse_down(true) then
        can_continue_drag = false
        cam_locked = false
    end
    timer = timer + 1
    if timer > 0 and not goal_moving then
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
    if subsection[1] == 0 and subsection[2] == 0 and subsection[3] == 0 and subsection[4] == 15 and subsection[5] == 15 and subsection[6] == 15 then
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
    last_cursor = cursor
end

function C.render_worldgen_tab(wid)
    local cursor = ga_win_get_cursor_pos(wid)
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

    ga_win_set_screen_coord_mode(wid,"screen")
    local x = 0.1
	local y = 0.125
	local width = 0.05
	local aspect = ga_get_sys_f("display.camera_params.a_ratio.value")

    local yaw_rad = math.rad(yaw)
    local pitch_rad = math.rad(math.min(math.max(-89.999,pitch),89.999))

	local look = std.vec(math.sin(yaw_rad)*math.cos(pitch_rad), math.cos(yaw_rad)*math.cos(pitch_rad), math.sin(pitch_rad))
    local left = std.normalize(std.cross(std.vec(0,0,1),look))
	local up = std.cross(look,left)
    local function thing(vec)
        -- std.dot(std.vec(1,0,0),std.vec_scale(left,-1)),std.dot(std.vec(1,0,0),up),std.dot(std.vec(1,0,0),look)
        return std.dot(vec,std.vec_scale(left,-1)),std.dot(vec,up),std.dot(vec,look)
    end
    local things = {}
    local s = 0.005
    ga_win_set_char_size(wid, s, s*2)
    ga_win_set_back_params(wid, std.vec(0,0,0),1,1)
	local dx,dy,z = thing(std.vec(1,0,0))
	things[#things+1] = {"X+",dx,dy,z, 1,0,0}
    local tx,ty = dx,dy
    dx,dy,z = thing(std.vec(-1,0,0))
	things[#things+1] = {"X-",dx,dy,z, -1,0,0}
    ga_win_line(wid,x+dx*width/aspect,y+dy*width,x+tx*width/aspect,y+ty*width,std.vec(1,0,0))
	dx,dy,z = thing(std.vec(0,1,0))
	things[#things+1] = {"Y+",dx,dy,z, 0,1,0}
    local tx,ty = dx,dy
    dx,dy,z = thing(std.vec(0,-1,0))
	things[#things+1] = {"Y-",dx,dy,z, 0,-1,0}
    ga_win_line(wid,x+dx*width/aspect,y+dy*width,x+tx*width/aspect,y+ty*width,std.vec(0,1,0))
	dx,dy,z = thing(std.vec(0,0,1))
    things[#things+1] = {"Z+",dx,dy,z, 0,0,1}
    local tx,ty = dx,dy
	--ga_win_line(wid,x,y,x+dx*width/aspect,y+dy*width,std.vec(0,0,1))
    --ga_win_txt_alpha_bg(wid, x+dx*width/aspect-0.005,y+dy*width-0.005, 1, "Z+")
    dx,dy,z = thing(std.vec(0,0,-1))
    things[#things+1] = {"Z-",dx,dy,z, 0,0,-1}
    ga_win_line(wid,x+dx*width/aspect,y+dy*width,x+tx*width/aspect,y+ty*width,std.vec(0,0,1))
    for b = 0,7 do
        dx,dy,z = thing(std.vec(((b&4)>>2)*2-1,((b&2)>>1)*2-1,(b&1)*2-1))
        local c = {[0]="-","+"}
        things[#things+1] = {c[(b&4)>>2] .. c[(b&2)>>1] .. c[b&1],dx,dy,z, ((b&4)>>2)*2-1,((b&2)>>1)*2-1,(b&1)*2-1}
    end
    --ga_win_txt_alpha_bg(wid, x+dx*width/aspect-0.005,y+dy*width-0.005, 1, "Z-")
    table.sort(things,function(a,b) return a[4] > b[4] end)
    local potential = nil
    for i = 1,#things do
        local v = things[i]
        s = 0.02/(v[4]+5)
        ga_win_set_char_size(wid, s, s*2)
        local X,Y = x+v[2]*width/aspect,y+v[3]*width
        local w = s*#v[1]*0.5
        ga_win_txt_alpha_bg(wid, X-w,Y-s, 1, v[1])
        local c = ga_win_get_cursor_pos(wid)
        if ga_win_mouse_pressed(wid, true) and c.x >= X-w and c.x <= X+w and c.y >= Y-s and c.y <= Y+s then
            if potential then
                if things[potential][4] > v[4] then potential = i end
            else
                potential = i
            end
        end
    end
    if potential then
        local v = things[potential]
        cam_locked = true
        goal_yaw = -math.deg(math.atan2(v[5],-v[6]))
        goal_pitch = math.deg(math.asin(-std.normalize(std.vec(v[5],v[6],v[7])).z))
        goal_moving = true
        if v[1] == "X-" then cross_section_opt = 2 end
        if v[1] == "Z-" then cross_section_opt = 3 end
        if v[1] == "Y-" then cross_section_opt = 1 end
        if v[1] == "Y+" then cross_section_opt = 4 end
        if v[1] == "X+" then cross_section_opt = 5 end
        if v[1] == "Z+" then cross_section_opt = 6 end
    end
    if cross_section_opt then
        if C.small_btn(wid, cursor, 0.3,0.1, 0.03,0.035, "-", false) and ga_win_mouse_pressed(wid, true) then
            ga_play_sound("menu_select")
            subsection[cross_section_opt] = subsection[cross_section_opt] - 1
        end
        if C.small_btn(wid, cursor, 0.4,0.1, 0.03,0.035, "+", false) and ga_win_mouse_pressed(wid, true) then
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
        ga_win_txt(wid, 0.34,0.11, subsection[cross_section_opt])
    end
    C.num_field(wid, "seed", 0.3,0.2, 0.01,0.02, saved_seed, function(v)
        saved_seed = v
        saved_dirty = true
    end, { neg = true })
    if C.small_btn(wid, cursor, 0.22,0.2, 0.03,0.035, "-", false) and ga_win_mouse_pressed(wid, true) then
        ga_play_sound("menu_select")
        saved_seed = saved_seed-1
        saved_dirty = true
    end
    if C.small_btn(wid, cursor, 0.25,0.2, 0.03,0.035, "+", false) and ga_win_mouse_pressed(wid, true) then
        ga_play_sound("menu_select")
        saved_seed = saved_seed+1
        saved_dirty = true
    end
    if goal_moving then
        yaw = yaw + ((goal_yaw-yaw+180)%360-180)*0.2
        pitch = pitch + (goal_pitch-pitch)*0.2
    end
end

-- TODO add uncrash info