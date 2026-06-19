local p = {}

local SEL_VAR  = "creative.selected_block"
local MODE_VAR = "creative.build_mode"
local AIR      = "XAR_AIR_BASIC"

local function ensure_vars()
    ga_init_s(SEL_VAR, "")
    ga_init_b(MODE_VAR, false)
    ga_init_s("creative.brush_shape", "single")
    ga_init_i("creative.brush_size", 0)
    ga_init_s("creative.wp_search", "")
end

local function selected() return ga_get_s(SEL_VAR) end

local function enable_cheats()
    -- Intentionally NO-OP. metagame.cheat.enabled is READ ONLY — ga_set_sys_b on
    -- it is a native crash. Cheats are already on via program_startup.txt, and
    -- ga_set_i/ga_set_f writes bypass the cheat gate anyway.
end

local function bind_mouse_creative()
    ga_command('bind MOUSE1.downup tocommand "creative_break"')
    ga_command('bind MOUSE2.downup tocommand "creative_place"')
    ga_command('bind MOUSE3.downup tocommand "creative_eyedrop"')
    ga_command('bind C.down tocommand "creative_eyedrop"')
    ga_command('bind BACKSPACE.down tocommand "creative_undo"')
end

local function bind_mouse_weapons()
    ga_command('bind MOUSE1.downup tocommands "use_equipped primary start" "use_equipped primary stop"')
    ga_command('bind MOUSE2.downup tocommands "use_equipped secondary start" "use_equipped secondary stop"')
end

local function set_build_mode(on)
    ga_set_b(MODE_VAR, on)
    if on then
        bind_mouse_creative()
        ga_hud_msg("Creative build: ON  (L-click break / R-click place)", 2.5)
    else
        bind_mouse_weapons()
        ga_hud_msg("Creative build: OFF  (mouse = weapons)", 2.5)
    end
end

local function look_target()
    if not ga_look_object_block_exists() then return nil end
    local cid = ga_look_object_block_get_chunk_id()
    local lbp = ga_look_object_block_get_lbp()
    local vcp = ga_chunk_id_to_vcp(cid)
    local bp  = ga_lbp_to_bp(vcp, lbp)
    local level = ga_get_viewer_level()
    local bp2 = std.get_adj_bp(bp, ga_look_object_block_get_normal_side())
    return level, bp, bp2
end

function p.handler_menu(str)
    ga_window_push("win_creative")
    return false
end

function p.handler_toggle(str)
    ensure_vars()
    local arg = nil
    for w in string.gmatch(str or "", "%S+") do arg = w break end
    if arg == "on" then
        set_build_mode(true)
    elseif arg == "off" then
        set_build_mode(false)
    else
        set_build_mode(not ga_get_b(MODE_VAR))
    end
    return false
end

local undo_stack = {}
local UNDO_MAX   = 60

local function undo_push(batch)
    if #batch == 0 then return end
    undo_stack[#undo_stack + 1] = batch
    while #undo_stack > UNDO_MAX do table.remove(undo_stack, 1) end
end

local BRUSH_CELL_CAP = 4096

local function brush_cells(center)
    local shape = ga_get_s("creative.brush_shape")
    local size  = ga_get_i("creative.brush_size")
    if shape == nil or shape == "" then shape = "single" end
    if size == nil or size < 0 then size = 0 end
    if shape == "single" or size == 0 then return { center } end
    local cells, r2 = {}, size * size
    for dx = -size, size do
        for dy = -size, size do
            for dz = -size, size do
                local keep = (shape ~= "sphere") or (dx*dx + dy*dy + dz*dz <= r2)
                if keep then
                    cells[#cells + 1] = std.bp(center.x + dx, center.y + dy, center.z + dz)
                    if #cells >= BRUSH_CELL_CAP then return cells end
                end
            end
        end
    end
    return cells
end

local function apply_brush(level, center, new_name)
    local batch = {}
    for _, cell in ipairs(brush_cells(center)) do
        local ok_old, old = pcall(ga_block_get, level, cell)
        if ok_old and old ~= new_name then
            local ok = pcall(ga_block_change_perm, level, cell, new_name)
            if ok then batch[#batch + 1] = { level = level, bp = cell, old = old } end
        end
    end
    undo_push(batch)
end

function p.handler_place(str)
    ensure_vars()
    local name = selected()
    if name == nil or name == "" then
        ga_hud_msg("Creative: no block selected (press G)", 2.0)
        return false
    end
    if block_wiki_bad_blocks and block_wiki_bad_blocks[name] then
        ga_hud_msg("Creative: that block is excluded (crashes)", 2.0)
        return false
    end
    local level, _bp, bp2 = look_target()
    if level == nil then return false end
    apply_brush(level, bp2, name)
    return false
end

function p.handler_break(str)
    ensure_vars()
    local level, bp = look_target()
    if level == nil then return false end
    apply_brush(level, bp, AIR)
    return false
end

function p.handler_eyedrop(str)
    ensure_vars()
    local level, bp = look_target()
    if level == nil then return false end
    local ok, name = pcall(ga_block_get, level, bp)
    if ok and type(name) == "string" and name ~= "" and name ~= AIR then
        ga_set_s(SEL_VAR, name)
        ga_hud_msg("Picked: " .. name, 1.5)
    end
    return false
end

function p.handler_undo(str)
    local batch = undo_stack[#undo_stack]
    if batch == nil then ga_hud_msg("Undo: nothing to undo", 1.0); return false end
    undo_stack[#undo_stack] = nil
    local n = 0
    for i = #batch, 1, -1 do
        local e = batch[i]
        if pcall(ga_block_change_perm, e.level, e.bp, e.old) then n = n + 1 end
    end
    ga_hud_msg("Undo: restored " .. n .. " block(s)", 1.5)
    return false
end

function p.handler_wp_home(str)
    if game_base_wp_system and game_base_wp_system.teleport_home then
        local ok, err = pcall(game_base_wp_system.teleport_home)
        if not ok then ga_hud_msg("WP home FAIL: " .. tostring(err), 2.5) end
    else
        ga_hud_msg("Waypoint system unavailable", 2.0)
    end
    return false
end

function p.handler_wp_warp(str)
    if not (game_base_wp_system and game_base_wp_system.teleport_to_first_matches_fancy) then
        ga_hud_msg("Waypoint system unavailable", 2.0); return false
    end
    local pat = ga_get_s("creative.wp_search")
    if pat == nil or pat == "" then
        ga_hud_msg("Warp: type a waypoint name in the menu first", 2.5); return false
    end
    local ok, err = pcall(game_base_wp_system.teleport_to_first_matches_fancy, pat)
    if not ok then ga_hud_msg("Warp FAIL: " .. tostring(err), 2.5) end
    return false
end

function p.handler_set_var(str)
    enable_cheats()
    local a = {}
    for w in string.gmatch(str or "", "%S+") do a[#a + 1] = w end
    local t, var, val = a[1], a[2], a[3]
    if t == nil or var == nil then ga_console_print("creative_set_var: bad args '" .. tostring(str) .. "'") return false end
    local ok, err = pcall(function()
        if     t == "di" then ga_set_i_by_delta(var, tonumber(val) or 0)
        elseif t == "i"  then ga_set_i(var, tonumber(val) or 0)
        elseif t == "f"  then ga_set_f(var, tonumber(val) or 0)
        elseif t == "b"  then ga_set_b(var, val == "true")
        elseif t == "sb" then ga_set_sys_b(var, val == "true")
        elseif t == "si" then ga_set_sys_i(var, tonumber(val) or 0)
        elseif t == "s"  then ga_set_s(var, val or "")
        end
    end)
    if ok then
        ga_hud_msg("set " .. var, 1.2)
    else
        ga_hud_msg("set_var FAIL: " .. tostring(err), 3.0)
        ga_console_print("creative_set_var error on '" .. tostring(str) .. "': " .. tostring(err))
    end
    return false
end

function p.handler_spawn_ent(str)
    enable_cheats()
    local name = nil
    for w in string.gmatch(str or "", "%S+") do name = w break end
    if name == nil then return false end
    local level = ga_get_viewer_level()
    local pos
    local lvl2, _bp, bp2 = look_target()
    if lvl2 ~= nil then
        level = lvl2
        pos = std.block_center(bp2)
    else
        local off = ga_get_viewer_offset()
        pos = std.vec(off.x, off.y, off.z + 1.0)
    end
    local ok, err = pcall(function()
        ga_ment_start(level, pos, name)
        ga_ment_end()
    end)
    if ok then
        ga_hud_msg("spawned " .. name, 2.0)
    else
        ga_hud_msg("spawn FAIL: " .. tostring(err), 3.0)
        ga_console_print("creative_spawn_ent error '" .. tostring(name) .. "': " .. tostring(err))
    end
    return false
end

local function register()
    if not game_command_system then return end
    game_command_system.add_command("creative_menu", p.handler_menu)
    game_command_system.add_help("creative_menu", "Open the creative inventory menu.")
    game_command_system.add_command("creative_set_var", p.handler_set_var)
    game_command_system.add_help("creative_set_var", "Set a var. Usage: creative_set_var di|i|f|sb|s <var> <value>")
    game_command_system.add_command("creative_spawn_ent", p.handler_spawn_ent)
    game_command_system.add_help("creative_spawn_ent", "Spawn a moving entity where you look. Usage: creative_spawn_ent <ment_name>")
    game_command_system.add_command("creative_build_toggle", p.handler_toggle)
    game_command_system.add_help("creative_build_toggle", "Toggle creative build mode. Usage: creative_build_toggle [on|off]")
    game_command_system.add_command("creative_place", p.handler_place)
    game_command_system.add_help("creative_place", "Place the selected creative block where you look.")
    game_command_system.add_command("creative_break", p.handler_break)
    game_command_system.add_help("creative_break", "Break the block you look at.")
    game_command_system.add_command("creative_eyedrop", p.handler_eyedrop)
    game_command_system.add_help("creative_eyedrop", "Pick the looked-at block into the selection (eyedropper).")
    game_command_system.add_command("creative_undo", p.handler_undo)
    game_command_system.add_help("creative_undo", "Undo the last creative place/break/brush.")
    game_command_system.add_command("creative_wp_home", p.handler_wp_home)
    game_command_system.add_help("creative_wp_home", "Teleport to your EMERGENCY waypoint.")
    game_command_system.add_command("creative_wp_warp", p.handler_wp_warp)
    game_command_system.add_help("creative_wp_warp", "Warp to the first waypoint matching creative.wp_search.")
end

function p.__load_game()
    ensure_vars()
    register()
end

register()

return p
