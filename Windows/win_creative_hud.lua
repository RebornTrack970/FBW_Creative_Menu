-- Creative hotbar HUD. Added to the HUD by game_creative.__load_game via
-- ga_hud_window_add("win_creative_hud", 160); drawn while build mode is on.
-- HUD windows render in the engine's default "inner" coords, the same ones
-- xar's ammo row uses, so the backing panel lines up with (and hides) the
-- gun bar while guns are off. See win_creative_core.lua for the shared C / S.
creative_ui = creative_ui or {}          -- shared by all win_creative*.lua files (one window Lua state)
creative_ui.state = creative_ui.state or {}
local C, S = creative_ui, creative_ui.state

local HB_SLOT_H, HB_BOTTOM = 0.090, 0.016
local HB_TAG = { ment = "MOB", bent = "INT", picture = "PIC", trophy = "TRO", secret = "SEC", path = "TP" }

local function inner_aspect()
    local a = ga_get_sys_f("display.camera_params.a_ratio.value")
    if type(ga_win_inner_coord_to_screen_coord) == "function" then
        local ok, p0, p1 = pcall(function()
            return ga_win_inner_coord_to_screen_coord(std.vec(0, 0, 0)),
                   ga_win_inner_coord_to_screen_coord(std.vec(1, 1, 0))
        end)
        if ok and type(p0) == "table" and type(p1) == "table"
           and type(p0.x) == "number" and type(p1.y) == "number" and p1.y ~= p0.y then
            local r = a * (p1.x - p0.x) / (p1.y - p0.y)
            if r > 0.3 and r < 5 then a = r end
        end
    end
    return a
end

-- text with a 1px-ish black drop shadow so it reads on any background
local function shadow_txt(wid, x, y, cw, ch, col, s, ia)
    ga_win_set_char_size(wid, cw, ch)
    ga_win_set_front_color(wid, std.vec(0, 0, 0))
    ga_win_txt(wid, x + ch * 0.08 / ia, y - ch * 0.08, s)
    ga_win_set_front_color(wid, col)
    ga_win_txt(wid, x, y, s)
end

local function shadow_txt_center(wid, y, cw, ch, col, s, ia)
    shadow_txt(wid, 0.5 - #s * cw * 0.5, y, cw, ch, col, s, ia)
end

-- outline only (4 thin quads); t = thickness in inner-height units
local function frame(wid, x0, y0, x1, y1, t, ia, col)
    local tx = t / ia
    ga_win_quad_color(wid, x0 - tx, y0 - t, x1 + tx, y0, col)
    ga_win_quad_color(wid, x0 - tx, y1, x1 + tx, y1 + t, col)
    ga_win_quad_color(wid, x0 - tx, y0, x0, y1, col)
    ga_win_quad_color(wid, x1, y0, x1 + tx, y1, col)
end

-- xar's HUD keeps a table of render callbacks (win_hud.get_hud_table); wrap its
-- "ammo" one so the gun bar hides while build mode is on (guns are off then)
-- and the hotbar takes its place.
local function hide_xar_ammo_in_build_mode()
    if type(win_hud) ~= "table" or type(win_hud.get_hud_table) ~= "function" then return end
    local t = win_hud.get_hud_table()
    if type(t) ~= "table" then return end
    for _, e in pairs(t) do
        if type(e) == "table" and e.name == "ammo" and type(e.func) == "function" and not e.creative_wrapped then
            local orig = e.func
            e.func = function(wid)
                if ga_exists(C.MODE_VAR) and ga_get_b(C.MODE_VAR) then return end
                return orig(wid)
            end
            e.creative_wrapped = true
        end
    end
end

local function render_hotbar(wid)
    hide_xar_ammo_in_build_mode()
    if not ga_exists(C.MODE_VAR) or not ga_get_b(C.MODE_VAR) then return end
    if ga_exists("xar.hud.disable_hud") and ga_get_b("xar.hud.disable_hud") then return end

    local ia   = inner_aspect()
    local sh   = HB_SLOT_H
    local sw   = sh / ia
    local gapx = sw * 0.10
    local total = C.HB_COUNT * sw + (C.HB_COUNT - 1) * gapx
    local x0, y0 = 0.5 - total * 0.5, HB_BOTTOM
    local slot = C.cur_slot()
    local kind, raw = C.cur_entry()
    local white = std.vec(1.0, 1.0, 1.0)
    local green = std.vec(0.0, 1.0, 0.0)          -- xar HUD text green
    local dim_green = std.vec(0.0, 0.65, 0.0)

    for i = 1, C.HB_COUNT do
        local sx = x0 + (i - 1) * (sw + gapx)
        local is_sel = (i == slot)
        ga_win_quad_color_alpha(wid, sx, y0, sx + sw, y0 + sh, std.vec(0.0, 0.0, 0.0), is_sel and 0.55 or 0.35)

        local k, r = C.hb_get(i)
        if k == nil and i == slot and kind == "block" then k, r = kind, raw end
        if k ~= nil then
            local label, tex = C.entry_info(k, r)
            local pad = 0.010
            if tex ~= "" then
                ga_win_quad(wid, sx + pad / ia, y0 + pad, sx + sw - pad / ia, y0 + sh - pad, tex)
            else
                ga_win_quad_color(wid, sx + pad / ia, y0 + pad, sx + sw - pad / ia, y0 + sh - pad, C.cat_color(k .. r))
                local ab = string.upper(string.sub(label, 1, 3))
                shadow_txt(wid, sx + sw * 0.5 - #ab * 0.005, y0 + sh * 0.5 - 0.009, 0.010, 0.020, green, ab, ia)
            end
            local tag = HB_TAG[k]
            if tag then
                shadow_txt(wid, sx + sw - #tag * 0.0062 - 0.003, y0 + 0.004, 0.0062, 0.012, green, tag, ia)
            end
        end

        if is_sel then
            frame(wid, sx, y0, sx + sw, y0 + sh, 0.005, ia, white)
        else
            frame(wid, sx, y0, sx + sw, y0 + sh, 0.002, ia, std.vec(0.55, 0.55, 0.60))
        end
    end

    -- name of the selected entry, above the slots (like Minecraft)
    local name
    if kind == nil then
        name = "Empty slot - press G to pick something"
    else
        name = (C.entry_info(kind, raw))
    end
    local ncw = 0.011
    shadow_txt_center(wid, y0 + sh + 0.014, ncw, 0.022,
        kind and green or dim_green, C.fit(name, math.floor(0.9 / ncw)), ia)

    -- controls hint above the name
    local hint
    if kind == nil then
        hint = "G = menu   V = exit build"
    elseif kind == "block" then
        local area = ga_exists(C.AREA_VAR) and ga_get_s(C.AREA_VAR) or ""
        if ga_exists(C.ALT_VAR) and ga_get_b(C.ALT_VAR) then
            if area == "" then
                hint = "Area: L-click = corner at place spot   R-click = corner at block   (aim at nothing = cyan cursor)"
            else
                hint = "Area " .. area .. "   L-click fill   R-click delete   Alt+wheel = depth   release Alt = cancel"
            end
        else
            hint = "L-click place   R-click break   Alt+click area fill   MMB/C pick   Bksp undo   V exit"
        end
    elseif kind == "path" then
        hint = "L-click = use it like a " .. raw .. " ring   wheel = hotbar   V exit"
    else
        local d = ga_get_i(C.E_DIST) or 4
        hint = "L-click place   R-click remove   Alt+Wheel = distance (" .. d .. ")   MMB/C pick   V exit"
    end
    shadow_txt_center(wid, y0 + sh + 0.044, 0.0072, 0.0145, green, hint, ia)
    ga_win_set_front_color_default(wid)
end

local err_shown = false

function p.__on_start(wid) end
function p.__on_end(wid) end
function p.__start(wid) end
function p.__end(wid) end

function p.__render(wid)
    local ok, err = pcall(render_hotbar, wid)
    if not ok and not err_shown then
        err_shown = true   -- report once, don't spam every frame
        if type(ga_print) == "function" then ga_print("creative hotbar error: " .. tostring(err)) end
    end
end
