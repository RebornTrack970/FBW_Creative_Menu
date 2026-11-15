-- "SAVE SCHEMATIC" name prompt. Opened by Game/game_creative_schem.lua right
-- after the 2nd Alt+middle-click captured a box. Like the text box editor, the
-- answer goes back through temp vars: the name into temp.creative.schem_name
-- and temp.creative.schem_state = "commit" (or "cancel"); the game's next tick
-- saves the schematic and puts it in the selected hotbar slot.

local NAME_VAR  = "temp.creative.schem_name"    -- pre-filled with a free name by the game
local STATE_VAR = "temp.creative.schem_state"   -- "edit" while this is open
local INFO_VAR  = "temp.creative.schem_info"    -- "7x5x6   120 blocks, 3 ents"
local LIST_VAR  = "temp.creative.schem_list"    -- existing schematics
local NAME_MAX  = 32

local SAVE_BTN   = { x = 0.30, y = 0.25, w = 0.40, h = 0.060 }
local started    = false
local confirm    = nil      -- a taken name: Enter / SAVE again replaces it
local warn       = nil      -- red line under the box

local function gets(var)
    local s = ga_exists(var) and ga_get_s(var) or ""
    return type(s) == "string" and s or ""
end

-- same rule as the game (game_creative_schem.lua C.schem_clean_name)
local function clean(s)
    s = tostring(s or "")
    s = string.gsub(s, "^%s+", "")
    s = string.gsub(s, "%s+$", "")
    s = string.gsub(s, "%s+", "_")
    s = string.gsub(s, "[^%w_%-]", "")
    if #s > NAME_MAX then s = string.sub(s, 1, NAME_MAX) end
    return s
end

local function taken(name)
    for entry in string.gmatch(gets(LIST_VAR), "[^,]+") do
        if string.match(entry, "^[^:]+") == name then return true end
    end
    return false
end

local function get_text(wid)
    local ok, s = pcall(ga_win_widget_text_input_get_text, wid)
    if ok and type(s) == "string" then return s end
    return ""
end

local function start(wid)
    if started then return end
    started, confirm, warn = true, nil, nil
    if not ga_exists(STATE_VAR) then ga_init_s(STATE_VAR, "edit") end
    pcall(ga_win_enable_cursor, true)
    pcall(ga_win_show_cursor_icon, true)
    ga_win_widget_text_input_start(wid, 0.50, 0.014, 0.028)
    ga_win_widget_text_input_set_text(wid, gets(NAME_VAR))
    ga_win_widget_go_back_button_start(wid, 0.06, 0.011, 0.022, "Cancel (ESC)")
end

local function finish(wid)
    if not started then return end
    started = false
    -- closed any other way than SAVE = cancelled
    if gets(STATE_VAR) == "edit" then ga_set_s(STATE_VAR, "cancel") end
end

function p.__start(wid)    start(wid) end
function p.__on_start(wid) start(wid) end
function p.__end(wid)      finish(wid) end
function p.__on_end(wid)   finish(wid) end

local function close(state)
    ga_set_s(STATE_VAR, state)
    ga_play_sound(state == "commit" and "menu_select" or "menu_back")
    ga_window_pop()
end

local function submit(wid, entered)
    local text = (type(entered) == "string" and entered ~= "") and entered or get_text(wid)
    local name = clean(text)
    if name == "" then
        warn = "Type a name (letters, digits, _ or -)"
        ga_play_sound("menu_back")
        return
    end
    if taken(name) and confirm ~= name then
        confirm = name
        warn = name .. " already exists - SAVE again to replace it"
        ga_play_sound("menu_back")
        return
    end
    if not ga_exists(NAME_VAR) then ga_init_s(NAME_VAR, "") end
    ga_set_s(NAME_VAR, name)
    close("commit")
end

function p.__process_input(wid)
    if ga_win_widget_go_back_button_process_input(wid) or ga_win_key_pressed(wid, "ESC") then
        close("cancel")
        return
    end
    local entered = ga_win_widget_text_input_process_input(wid)
    local go = ga_win_key_pressed(wid, "ENTER") or (type(entered) == "string" and entered ~= "")
    if not go and ga_win_mouse_pressed(wid, true) then
        local c = ga_win_get_cursor_pos(wid)
        local b = SAVE_BTN
        go = c.x >= b.x and c.x <= b.x + b.w and c.y >= b.y and c.y <= b.y + b.h
    end
    if go then submit(wid, entered) end
end

function p.__render(wid)
    ga_win_set_background(wid, std.vec(0.0, 0.0, 0.0), 0.92)

    ga_win_set_char_size(wid, 0.020, 0.040)
    ga_win_set_front_color(wid, std.vec(0.9, 0.85, 0.5))
    ga_win_txt_center(wid, 0.80, "SAVE SCHEMATIC")

    ga_win_set_char_size(wid, 0.011, 0.022)
    ga_win_set_front_color(wid, std.vec(0.55, 0.80, 0.95))
    ga_win_txt_center(wid, 0.70, gets(INFO_VAR))

    ga_win_set_char_size(wid, 0.010, 0.020)
    ga_win_set_front_color(wid, std.vec(0.8, 0.8, 0.8))
    ga_win_txt_center(wid, 0.58, "NAME:")
    -- (the text box itself is an engine widget, drawn by the engine at y 0.50)

    local name = clean(get_text(wid))
    if name ~= get_text(wid) and name ~= "" then
        ga_win_set_char_size(wid, 0.009, 0.018)
        ga_win_set_front_color(wid, std.vec(0.6, 0.6, 0.65))
        ga_win_txt_center(wid, 0.43, "saved as: " .. name)
    end
    if warn then
        ga_win_set_char_size(wid, 0.010, 0.020)
        ga_win_set_front_color(wid, std.vec(1.0, 0.45, 0.35))
        ga_win_txt_center(wid, 0.38, warn)
    end

    local c = ga_win_get_cursor_pos(wid)
    local b = SAVE_BTN
    local hov = c.x >= b.x and c.x <= b.x + b.w and c.y >= b.y and c.y <= b.y + b.h
    ga_win_quad_color(wid, b.x - 0.003, b.y - 0.003, b.x + b.w + 0.003, b.y + b.h + 0.003, std.vec(0.5, 0.5, 0.55))
    ga_win_quad_color(wid, b.x, b.y, b.x + b.w, b.y + b.h,
        hov and std.vec(0.24, 0.64, 0.29) or std.vec(0.15, 0.40, 0.18))
    local label = (confirm ~= nil and confirm == name) and "REPLACE (ENTER)" or "SAVE (ENTER)"
    local cw, ch = 0.012, 0.024
    ga_win_set_char_size(wid, cw, ch)
    ga_win_set_front_color(wid, std.vec(1.0, 1.0, 1.0))
    ga_win_txt(wid, b.x + (b.w - #label * cw) * 0.5, b.y + (b.h - ch) * 0.5, label)
    ga_win_set_front_color_default(wid)
end
