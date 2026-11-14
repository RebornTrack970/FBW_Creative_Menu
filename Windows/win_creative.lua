-- Creative menu window (G): tab bar, search box, header/footer, and routing
-- input/rendering to the tab code in win_creative_lists.lua and
-- win_creative_panels.lua. Shared helpers: win_creative_core.lua,
-- win_creative_tex.lua. Hotbar HUD: win_creative_hud.lua.
creative_ui = creative_ui or {}          -- shared by all win_creative*.lua files (one window Lua state)
creative_ui.state = creative_ui.state or {}
local C, S = creative_ui, creative_ui.state

local TABS = {
    { label = "BLOCKS",   icon = "block_cube_1" },
    { label = "WEAPONS",  icon = "ammo_gun1" },
    { label = "ITEMS",    icon = "icon_gold" },
    { label = "BUFFS",    icon = "icon_damage_5x" },
    { label = "ENTITIES", icon = "MonsterGoblin" },
    { label = "INTERACT", icon = "buy_station" },
    { label = "TELEPORT", icon = "bent_bookmark" },
    { label = "DECOR",    icon = "picture_old_house" },
}
-- bottom bar: close button sits centred above the key-hint line
local CLOSE_Y, CLOSE_CW, CLOSE_TXT = 0.040, 0.011, "Close (ESC)"
local TAB_Y, TAB_H              = 0.884, 0.048
local TAB_X0, TAB_X1, TAB_GAP   = 0.02, 0.98, 0.006

local function tab_rect(i)
    local w = (TAB_X1 - TAB_X0 - TAB_GAP * (C.TAB_COUNT - 1)) / C.TAB_COUNT
    return TAB_X0 + (i - 1) * (w + TAB_GAP), TAB_Y, w, TAB_H
end

function p.init(wid)
    S.aspect = ga_get_sys_f("display.camera_params.a_ratio.value")
    if S.inited then return end
    S.inited = true
    C.compute_grid()
    ga_init_s(C.SEL_VAR, "")
    ga_win_enable_cursor(true)
    ga_win_show_cursor_icon(true)

    ga_init_s(C.FAV_VAR, "")
    ga_init_s(C.REC_VAR, "")
    ga_init_s(C.BR_SHAPE, "single")
    ga_init_i(C.BR_SIZE, 0)
    ga_init_i(C.E_COUNT, 1)
    ga_init_i(C.E_DIST, 4)
    ga_init_b(C.E_FREEZE, false)
    ga_init_i(C.E_TTL, 0)
    ga_init_i(C.D_SIZE, 2)
    ga_init_b(C.D_SNAP, true)
    ga_init_i(C.SLOT_VAR, 1)
    for i = 1, C.HB_COUNT do ga_init_s(C.HB_PREFIX .. i, "") end
    ga_init_b(C.ALT_VAR, false)
    ga_init_s(C.AREA_VAR, "")

    -- search box only on tabs that use it (see SEARCH_TABS)
    S.has_search = C.SEARCH_TABS[S.cur_tab] == true
    if S.has_search then
        ga_win_widget_text_input_start(wid, 0.835, C.fix_charw(0.012), 0.024)
        ga_win_widget_text_input_set_text(wid, S.search_text)
        ga_win_widget_text_input_set_enable_enter(wid, false)
    end

    -- tabs are drawn by render_tab_bar() and hit-tested in __process_input

    ga_win_widget_go_back_button_start(wid, CLOSE_Y, C.fix_charw(CLOSE_CW), 0.022, CLOSE_TXT)

    -- open on the tab (and grid page) that was open last time; cur_tab is
    -- module state, so it survives closing the menu
    if S.cur_tab < 1 or S.cur_tab > C.TAB_COUNT then S.cur_tab = C.TAB_BLOCKS end
    S.last_tab = S.cur_tab
    S.last_search = C.get_search(wid)
    C.rebuild(wid)
    S.page = math.max(0, math.min(S.tab_pages[S.cur_tab] or 0, C.num_pages() - 1))
end

function p.__start(wid)    p.init(wid) end
function p.__end(wid)
    -- last_tab = the tab `page` belongs to (cur_tab may already be the next
    -- tab when the window reopens itself)
    if S.last_tab >= 1 then S.tab_pages[S.last_tab] = S.page end
    S.inited = false; S.use_3d_mesh = nil; C.num_reset()
end

function p.__process_input(wid)
    -- held Ctrl: ENTITIES tooltip shows the type id instead of the in-game name
    S.ctrl_down = ga_win_key_down("LCTRL") or ga_win_key_down("RCTRL")
    -- an open amount field owns the keyboard (digits, Backspace, Enter, Esc)
    local editing, closed = C.num_edit_keys(wid)
    if closed then return end
    if ga_win_widget_go_back_button_process_input(wid) or (not editing and ga_win_key_pressed(wid, "ESC")) then
        C.num_edit_commit()
        ga_window_pop()
        return
    end

    -- click on an amount = edit it; click anywhere else applies the open one
    if ga_win_mouse_pressed(wid, true) and C.num_edit_click(ga_win_get_cursor_pos(wid)) then
        return
    end

    if ga_win_mouse_pressed(wid, true) then
        local cursor = ga_win_get_cursor_pos(wid)
        for i = 1, C.TAB_COUNT do
            local tx, ty, tw, th = tab_rect(i)
            if i ~= S.cur_tab and C.btn_rect(cursor, tx, ty, tw, th) then
                S.cur_tab = i
                ga_play_sound("menu_select")
            end
        end
    end
    if not editing and ga_win_key_pressed(wid, "TAB") then
        S.cur_tab = (S.cur_tab % C.TAB_COUNT) + 1
    end

    -- typing an amount must not also go into the search box
    if S.has_search and not editing then ga_win_widget_text_input_process_input(wid) end
    local cur_search = C.get_search(wid)
    if S.has_search then S.search_text = cur_search end

    if S.cur_tab ~= S.last_tab and (C.SEARCH_TABS[S.cur_tab] == true) ~= S.has_search then
        -- the search box can't appear / disappear in an open window, so
        -- reopen the menu on the new tab (__end saves the old tab's page)
        ga_window_pop()
        ga_window_push("win_creative")
        return
    end

    if S.cur_tab ~= S.last_tab or cur_search ~= S.last_search then
        local tab_changed = (S.cur_tab ~= S.last_tab)
        if tab_changed and S.last_tab >= 1 then S.tab_pages[S.last_tab] = S.page end
        -- going to another tab closes INTERACT's trophy page (reopening the
        -- menu on INTERACT keeps it)
        if tab_changed and S.cur_tab ~= C.TAB_INTERACT then C.tp.sub = nil end
        S.last_tab = S.cur_tab
        S.last_search = cur_search
        C.rebuild(wid)                -- resets page to 0
        if tab_changed then
            S.page = math.max(0, math.min(S.tab_pages[S.cur_tab] or 0, C.num_pages() - 1))
        end
    end

    C.grid_input(wid)
    if C.panels_input(wid) then return end
    C.strip_input(wid)

end

function p.__render(wid)
    S.aspect = ga_get_sys_f("display.camera_params.a_ratio.value")
    ga_win_set_screen_coord_mode(wid, "screen")
    C.num_frame_begin()

    ga_win_set_background(wid, std.vec(0.04, 0.04, 0.06), 0.97)

    ga_win_set_char_size(wid, C.fix_charw(0.018), 0.036)
    ga_win_set_front_color(wid, std.vec(0.9, 0.85, 0.5))
    ga_win_txt_center(wid, 0.965, "CREATIVE INVENTORY")
    ga_win_set_front_color_default(wid)
    ga_win_quad_color(wid, 0.02, 0.9455, 0.98, 0.9475, std.vec(0.30, 0.26, 0.12))

    C.render_tab_bar(wid)

    ga_win_set_char_size(wid, C.fix_charw(0.010), 0.020)
    if S.has_search then ga_win_txt(wid, 0.02, 0.84, "SEARCH:") end

    local sel_kind, sel = C.cur_entry()
    if sel ~= nil and sel ~= "" then
        local sx = 0.02
        local sel_label, stex = C.entry_info(sel_kind, sel)
        if stex ~= "" then
            local sh = 0.030
            local sw = sh / S.aspect
            ga_win_quad_color(wid, sx - 0.002 / S.aspect, 0.043, sx + sw + 0.002 / S.aspect, 0.045 + sh + 0.002, std.vec(1.0, 0.9, 0.3))
            ga_win_quad(wid, sx, 0.045, sx + sw, 0.045 + sh, stex)
            sx = sx + sw + 0.008
        end
        -- keep clear of the centred Close button
        local close_x0 = 0.5 - #CLOSE_TXT * C.fix_charw(CLOSE_CW) * 0.5 - 0.02
        local max_chars = math.max(4, math.floor((close_x0 - sx) / 0.009))
        ga_win_set_char_size(wid, 0.009, 0.018)
        ga_win_set_front_color(wid, std.vec(1.0, 0.9, 0.3))
        ga_win_txt(wid, sx, 0.050, C.fit("Slot " .. C.cur_slot() .. ": " .. sel_label, max_chars))
        ga_win_set_front_color_default(wid)
    end

    ga_win_set_char_size(wid, 0.0075, 0.015)
    ga_win_set_front_color(wid, std.vec(0.5, 0.5, 0.5))
    ga_win_txt_center(wid, 0.010, "TAB=tabs | Wheel=page | V=build | 1-9/Wheel=hotbar | Alt+Wheel=dist | C/MMB=pick | Bksp=undo | F6/F7=warp/home")
    ga_win_set_front_color_default(wid)

    if S.cur_tab == C.TAB_BLOCKS then
        C.render_grid_tab(wid, "block")
        C.render_control_strip_blocks(wid)
    elseif S.cur_tab == C.TAB_WEAPONS then
        C.render_weapons_tab(wid)
    elseif S.cur_tab == C.TAB_ITEMS then
        C.render_items_tab(wid)
    elseif S.cur_tab == C.TAB_BUFFS then
        C.render_buffs_tab(wid)
    elseif S.cur_tab == C.TAB_ENTITIES then
        C.render_grid_tab(wid, "entity")
        C.render_control_strip_entities(wid)
        C.render_pick_hint(wid, "Click = put in hotbar. L-click spawns at the white box, R-click removes the red one, Alt+wheel = distance, Ctrl = id.")
    elseif S.cur_tab == C.TAB_INTERACT and C.tp.sub == "trophies" then
        C.render_grid_tab(wid, "interact")
        C.render_trophy_strip(wid)
    elseif S.cur_tab == C.TAB_INTERACT then
        C.render_grid_tab(wid, "interact")
        C.render_control_strip_interact(wid)
        C.render_pick_hint(wid, "Click = hotbar (Trophies: trophy list, Text Box: asks text). L-click place, R-click remove, Alt+wheel = distance, Ctrl = id.")
    elseif S.cur_tab == C.TAB_TELEPORT then
        C.render_teleport_tab(wid)
    elseif S.cur_tab == C.TAB_DECOR then
        C.render_grid_tab(wid, "decor")
        C.render_control_strip_decor(wid)
    end
end

function C.render_tab_bar(wid)
    local cursor = ga_win_get_cursor_pos(wid)
    local pad = C.default_padding
    for i, t in ipairs(TABS) do
        local x, y, w, h = tab_rect(i)
        local active = (i == S.cur_tab)
        local hov = (not active) and C.btn_rect(cursor, x, y, w, h)

        local edge = active and std.vec(0.22, 0.50, 0.58) or std.vec(0.20, 0.20, 0.30)
        local bg   = active and std.vec(0.13, 0.19, 0.27)
                  or (hov and std.vec(0.17, 0.17, 0.26) or std.vec(0.08, 0.08, 0.12))
        ga_win_quad_color(wid, x - C.fix_padding(pad), y - pad, x + w + C.fix_padding(pad), y + h + pad, edge)
        ga_win_quad_color(wid, x, y, x + w, y + h, bg)
        if active then
            ga_win_quad_color(wid, x, y, x + w, y + 0.005, std.vec(0.30, 0.85, 0.95))
        end

        -- icon + label, centred together inside the tab
        local ih    = h - 0.016
        local iw    = ih / S.aspect
        local gap   = C.fix_padding(0.012)
        local n     = #t.label
        local charw = math.min(C.fix_charw(0.0095), (w - iw - gap - C.fix_padding(0.016)) / n)
        local charh = 0.019 * charw / C.fix_charw(0.0095)
        local gx    = x + (w - (iw + gap + charw * n)) * 0.5
        local dw    = C.draw_icon(wid, gx, y + 0.009, ih, t.icon, true)
        if dw == 0 then gx = x + (w - charw * n) * 0.5 else gx = gx + iw + gap end

        ga_win_set_char_size(wid, charw, charh)
        if active then
            ga_win_set_front_color(wid, std.vec(1.0, 0.92, 0.55))
        elseif hov then
            ga_win_set_front_color(wid, std.vec(1.0, 1.0, 1.0))
        else
            ga_win_set_front_color(wid, std.vec(0.62, 0.62, 0.70))
        end
        ga_win_txt(wid, gx, y + h * 0.5 - charh * 0.40, t.label)
        ga_win_set_front_color_default(wid)
    end
end

function p.uncrash__info()
    local out = uncrash.info {
        local_funcs={
            compute_grid=C.compute_grid,
            clean_name=C.clean_name,
            clean_ent_name=C.clean_ent_name,
            category_of=C.category_of,
            -- more!!!
        }
    }
    C.compute_grid=out.compute_grid
    C.clean_name=out.clean_name
    C.clean_ent_name=out.clean_ent_name
    C.category_of=out.category_of
end
