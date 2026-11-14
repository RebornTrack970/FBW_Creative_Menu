-- Creative mode (game side): console commands + mouse/key handlers, the
-- xar equip hooks, the per-tick update and __load_game. The work is done in
-- game_creative_core / _edit / _place / _render.lua.
creative_g = creative_g or {}           -- shared by all game_creative*.lua files (one game Lua state)
creative_g.state = creative_g.state or {}
local C, S = creative_g, creative_g.state

function p.handler_menu(str)
    ga_window_push("win_creative")
    return false
end

function p.handler_toggle(str)
    C.ensure_vars()
    local arg = nil
    for w in string.gmatch(str or "", "%S+") do arg = w break end
    if arg == "on" then
        C.set_build_mode(true)
    elseif arg == "off" then
        C.set_build_mode(false)
    else
        C.set_build_mode(not ga_get_b(C.MODE_VAR))
    end
    return false
end

-------------------------------------------------------------------------------
-- Mouse / key handlers (bound in build mode)
-------------------------------------------------------------------------------

function p.handler_place(str)
    C.ensure_vars()
    if not C.build_mode_or_heal() then return false end
    local kind, name = C.cur_entry()
    if kind == nil then
        ga_hud_msg("Creative: empty hotbar slot (press G to pick something)", 2.0)
        return false
    end
    if kind == "path" then
        local ok, err = pcall(C.use_path, name)
        if not ok then ga_console_print("creative path error: " .. tostring(err)) end
        return false
    end
    if kind ~= "block" then
        local ok, err = pcall(C.place_nonblock, kind, name)
        if not ok then
            ga_hud_msg("place FAIL: " .. tostring(err), 3.0)
            ga_console_print("creative_place error '" .. tostring(name) .. "': " .. tostring(err))
        end
        return false
    end
    if block_wiki_bad_blocks[name] then
        ga_hud_msg("Creative: that block is excluded (crashes)", 2.0)
        return false
    end
    if ga_get_b(C.ALT_VAR) then
        C.area_click("place", name)
        return false
    end
    local level, _bp, bp2 = C.look_target()
    if level == nil then return false end
    C.apply_brush(level, bp2, name)
    return false
end

function p.handler_break(str)
    C.ensure_vars()
    if not C.build_mode_or_heal() then return false end
    local kind = C.cur_entry()
    if kind == "path" then return false end         -- path entries only use L-click
    if kind ~= nil and kind ~= "block" then
        local ok, tg = pcall(C.find_remove_target, kind)
        if not ok then
            ga_console_print("creative_break error: " .. tostring(tg))
        elseif tg == nil then
            ga_hud_msg("Nothing to remove here", 1.0)
        else
            C.remove_target(tg)
        end
        return false
    end
    if ga_get_b(C.ALT_VAR) then
        C.area_click("break", nil)
        return false
    end
    -- a shop / picture / trophy / monster in front of the block goes first
    local ok, tg = pcall(C.crosshair_target)
    if ok and tg ~= nil then
        C.remove_target(tg)
        return false
    end
    local level, bp = C.look_target()
    if level == nil then return false end
    C.apply_brush(level, bp, C.AIR)
    return false
end

-- Pick what you look at into the hotbar: a monster/ment, a basic ent, or a block.
function p.handler_eyedrop(str)
    C.ensure_vars()
    local eye  = ga_get_viewer_offset()
    local look = ga_get_sys_v("game.player.camera.look")
    local vlevel = ga_get_viewer_level()
    local best_kind, best_raw, best_d = nil, nil, 1e30
    local best_amount = nil      -- the picked pickup's amount (its int param)
    local best_str = nil         -- ... and its text param (green key combo etc.)

    if ga_look_object_ment_exists() then
        local id = ga_look_object_ment_inst_id()
        if id ~= nil and id >= 0 and ga_ment_exists(id) and ga_ment_get_level(id) == vlevel then
            local t = ga_ment_get_type(id)
            if type(t) == "string" and t ~= "" and string.sub(t, 1, 13) ~= "ment_picture_"
               and string.sub(t, 1, 11) ~= "ment_player" then
                best_kind, best_raw = "ment", t
                best_d = C.dist3(ga_ment_get_lp(id), eye) - ga_ment_get_radius(id)
            end
        end
    end
    if ga_look_object_bent_exists() then
        local cid = ga_look_object_bent_get_chunk_id()
        local blevel = ga_chunk_id_to_level(cid)
        local bp = ga_lbp_to_bp(ga_chunk_id_to_vcp(cid), ga_look_object_bent_get_lbp())
        local ok, t = pcall(ga_bent_get_type, blevel, bp)
        local d = C.ray_box_t(eye, look, bp) or 1e29
        if ok and type(t) == "string" and t ~= "" and t ~= C.PIC_BENT and d < best_d then
            best_kind, best_raw, best_d = "bent", t, d
            best_amount, best_str = nil, nil
            if C.bent_amount(t) ~= nil then          -- XP / powerup / key / ammo / toll
                local okn, n = pcall(ga_bent_get_param_i, blevel, bp)
                if okn and type(n) == "number" and n > 0 then best_amount = n end
            end
            if C.bent_param_s(t) ~= nil then         -- combo / area / door var / upgrade
                local oks, s = pcall(ga_bent_get_param_s, blevel, bp)
                if oks and type(s) == "string" then best_str = s end
            end
        end
    end
    -- pictures, by their whole rectangle
    local okc, ctg = pcall(C.crosshair_target)
    if okc and ctg ~= nil and ctg.pic ~= nil and ctg.t ~= nil and ctg.t < best_d then
        best_kind, best_raw, best_d = "picture", ctg.pic.tex, ctg.t
    end
    local level, bp = C.look_target()
    if level ~= nil then
        local ok, name = pcall(ga_block_get, level, bp)
        local d = (level == vlevel) and (C.ray_box_t(eye, look, bp) or 1e29) or 1e29
        if ok and type(name) == "string" and name ~= "" and name ~= C.AIR and name ~= C.TROPHY_BLOCK
           and (best_kind == nil or d < best_d) then
            best_kind, best_raw = "block", name
        end
    end

    if best_kind ~= nil then
        C.hb_pick(best_kind, best_raw)
        local msg = "Picked: " .. best_raw
        if best_kind == "bent" and best_amount ~= nil then
            local var = C.AMOUNT_PREFIX .. best_raw
            if not ga_exists(var) then ga_init_i(var, best_amount) end
            ga_set_i(var, best_amount)
            msg = msg .. " (amount " .. best_amount .. ")"
        end
        if best_kind == "bent" and best_str ~= nil and C.bent_param_remember(best_raw, best_str) then
            msg = msg .. " (\"" .. best_str .. "\")"
        end
        ga_hud_msg(msg, 1.5)
    end
    return false
end

-- Mouse wheel in build mode: cycle hotbar slots. With Alt held: move the
-- non-block placement point away (+) / closer (-).
local function wheel(delta)
    C.ensure_vars()
    local step = (delta > 0) and 1 or -1
    if ga_get_b(C.ALT_VAR) then
        local kind = C.cur_entry()
        if kind == nil or kind == "block" then
            C.area_depth_step(step)                          -- area-fill 3D cursor
        else
            local d = C.place_dist() + step
            if d < C.DIST_MIN then d = C.DIST_MIN end
            if d > C.DIST_MAX then d = C.DIST_MAX end
            ga_set_i(C.DIST_VAR, d)
        end
    else
        -- wheel down = next slot (to the right), wheel up = previous
        ga_set_i(C.SLOT_VAR, (C.cur_slot() - 1 - step) % C.HB_COUNT + 1)
        C.sync_sel()
    end
end

local function select_slot(n)
    C.ensure_vars()
    if n == nil or n < 1 or n > C.HB_COUNT then return end
    ga_set_i(C.SLOT_VAR, n)
    C.sync_sel()
end

function p.handler_alt(str)
    C.ensure_vars()
    local down = string.match(str or "", "%S+") == "start"
    ga_set_b(C.ALT_VAR, down)
    C.area_cancel()   -- every Alt press starts a fresh selection; letting go drops it
    return false
end

-- console versions: creative_wheel 1|-1, creative_slot N
function p.handler_wheel(str)
    wheel(tonumber(string.match(str or "", "%S+") or "") or 0)
    return false
end

function p.handler_slot(str)
    select_slot(tonumber(string.match(str or "", "%S+") or ""))
    return false
end

-- While build mode is on, xar's equip commands (wheel = equip_right/equip_left,
-- 1-9 = equip N) drive the hotbar instead of switching guns.
local hook_orig, hook_wrap = {}, {}
local function hook_cmd(cmd_name, mod_name, on_build)
    if hook_wrap[cmd_name] == nil then
        local mod = _G[mod_name]
        local orig = (type(mod) == "table" and mod.handler) or game_command_system.get_command_by_name(cmd_name)
        if orig == nil then return end
        hook_orig[cmd_name] = orig
        hook_wrap[cmd_name] = function(str)
            if ga_exists(C.MODE_VAR) and ga_get_b(C.MODE_VAR) then
                local ok, err = pcall(on_build, str)
                if not ok then ga_console_print("creative " .. cmd_name .. " error: " .. tostring(err)) end
                return ""
            end
            return hook_orig[cmd_name](str)
        end
        -- xar registers p.handler in its own __load_game; if that has not run
        -- yet it will now register our wrapper
        if type(mod) == "table" then mod.handler = hook_wrap[cmd_name] end
    end
    game_command_system.add_command(cmd_name, hook_wrap[cmd_name])
end

local function hook_equip_commands()
    hook_cmd("equip_right", "game_cmd_equiv_right", function() wheel(1) end)
    hook_cmd("equip_left",  "game_cmd_equiv_left",  function() wheel(-1) end)
    hook_cmd("equip",       "game_cmd_equip", function(str)
        select_slot(tonumber(string.match(str or "", "%S+") or ""))
    end)
end

p.undo_held = false
p.undo_held_dur = 0
local tick_err_shown = false
function p.__update_discrete_post()
    local ok, err = pcall(function()
        C.finish_text_box()                     -- a message typed in win_creative_text
        if S.hb_restored then C.hb_mirror() end    -- hotbar -> dyn vars (saved with the game)
    end)
    if not ok and not tick_err_shown then
        tick_err_shown = true
        ga_console_print("creative tick error: " .. tostring(err))
    end
    if p.undo_held then
        local second = 25
        if p.undo_held_dur == 0 or p.undo_held_dur >= second then
            p.handler_undo()
        end
        p.undo_held_dur = p.undo_held_dur + 1
    else
        p.undo_held_dur = 0
    end
end

function p.handler_undo(str)
    local batch = C.undo_stack[#C.undo_stack]
    if batch == nil then ga_hud_msg("Undo: nothing to undo", 1.0); return false end
    local chunk_ids = {}
    local n = 0
    
    local cache = {}
    for i = 1,#batch do
        local v = batch[i]
        if cache[v.path] then chunk_ids[i] = cache[v.path] end
        local chunk_id = ga_path_to_chunk_id(C.full_path_from_minipath(v.path))
        if chunk_id < 0 then
            -- TODO: handle better
            ga_hud_msg("Undo ERROR: chunk not loaded!", 2.0)
            return
        end
        cache[v.path] = chunk_id
        chunk_ids[i] = chunk_id
    end
    C.undo_stack[#C.undo_stack] = nil
    for i = #batch, 1, -1 do
        local e = batch[i]
        n = n + 1
        local level = ga_chunk_id_to_level(chunk_ids[i])
        local bp = std.chunk_id_and_lbph_to_bp(chunk_ids[i], e.lbph)
        ga_block_change_perm(level, bp, e.old)
    end
    ga_hud_msg("Undo: restored " .. n .. " block(s)", 1.5)
end

function p.handler_wp_home(str)
    game_base_wp_system.teleport_home()
end

function p.handler_wp_warp(str)
    local pat = ga_get_s("temp.creative.wp_search")
    if pat == "" then
        ga_hud_msg("Warp: type a waypoint name in the menu first", 2.5)
        return
    end
    game_base_wp_system.teleport_to_first_matches_fancy(pat)
end

function p.handler_set_var(str)
    C.enable_cheats()
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
    C.enable_cheats()
    local name = nil
    for w in string.gmatch(str or "", "%S+") do name = w break end
    if name == nil then return false end
    local level = ga_get_viewer_level()
    local pos
    local lvl2, _bp, bp2 = C.look_target()
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
    game_command_system.add_help("creative_eyedrop", "Pick the looked-at block/monster/ent into the hotbar (eyedropper).")
    game_command_system.add_command("creative_wheel", p.handler_wheel)
    game_command_system.add_help("creative_wheel", "Move the non-block placement point. Usage: creative_wheel 1|-1")
    game_command_system.add_command("creative_alt", p.handler_alt)
    game_command_system.add_help("creative_alt", "Internal: Alt held (start) / released (stop) in build mode.")
    game_command_system.add_command("creative_slot", p.handler_slot)
    game_command_system.add_help("creative_slot", "Select a creative hotbar slot. Usage: creative_slot 1..9")
    game_command_system.add_command("creative_undo", function(str)
        p.undo_held = str == "start"
    end)
    game_command_system.add_help("creative_undo", "Begin/stop undoing the last creative place/break/brush.")
    game_command_system.add_command("creative_wp_home", p.handler_wp_home)
    game_command_system.add_help("creative_wp_home", "Teleport to your EMERGENCY waypoint.")
    game_command_system.add_command("creative_wp_warp", p.handler_wp_warp)
    game_command_system.add_help("creative_wp_warp", "Warp to the first waypoint matching temp.creative.wp_search.")
end

function p.__load_game()
    C.ensure_vars()
    -- module locals survive a "soft" load of another save: start clean
    S.text_pending = nil
    ga_set_s("temp.creative.text_state", "")
    local ok, err = pcall(C.hb_restore)
    S.hb_restored = ok
    if not ok then ga_console_print("creative hotbar restore error: " .. tostring(err)) end
    register()
    hook_equip_commands()
    -- hotbar HUD (Windows/win_creative_hud.lua); above xar's win_hud (100)
    -- and win_hud_user_above (150)
    ga_hud_window_add("win_creative_hud", 160)
end
