-- Creative menu: the "?" button (top right) and the help panel it opens with
-- the tips and controls (the tabs themselves show no tip lines). The panel
-- shows the open tab's tips next to the menu + in-world controls; clicking
-- another tab while it is open switches the help too. ? / Esc / a click
-- outside the panel closes it. See win_creative_core.lua for the shared C / S.
creative_ui = creative_ui or {}          -- shared by all win_creative*.lua files (one window Lua state)
creative_ui.state = creative_ui.state or {}
local C, S = creative_ui, creative_ui.state

local PANEL_X0, PANEL_X1 = 0.03, 0.97
-- above the slot line, below the tab titles / page line (0.810) and the
-- search box (a widget: drawn over quads)
local PANEL_Y0, PANEL_Y1 = 0.088, 0.800
local BTN_Y, BTN_H       = 0.953, 0.034

-- tab index -> { title, lines }. Index = C.TAB_* (filled lazily: the
-- constants live in win_creative_core.lua, which may load after this file)
local TAB_HELP = nil
local function tab_help()
    if TAB_HELP ~= nil then return TAB_HELP end
    TAB_HELP = {
        [C.TAB_BLOCKS] = { "BLOCKS", {
            "Click a block = put it in the hotbar and turn build mode on.",
            "R-click a block = add / remove it from the favourites (* FAV).",
            "VIEW: ALL / * FAV / RECENT.   SORT: A-Z or CATEGORY.",
            "BRUSH: SINGLE / CUBE / SPHERE, SIZE - / + = brush radius.",
        }},
        [C.TAB_WEAPONS] = { "WEAPONS", {
            "Click a gun = equip it. Click its ammo / upgrade number to type a value.",
            "FIRE MODES: L-click a locked mode = unlock it, an unlocked one = equip it.",
            "2 modes are equipped: primary + secondary fire. Equipping one keeps the last one you equipped.",
            "R-click a mode = lock it again (not while it is equipped).",
        }},
        [C.TAB_ITEMS] = { "ITEMS", {
            "The buttons add to / set each amount.",
            "Click a number to type an exact amount.",
            "TELEKINESIS UPGRADES: L-click a locked one = unlock it, R-click = lock it again. Each one = +1 block radius, -1 s free cooldown.",
        }},
        [C.TAB_BUFFS] = { "BUFFS", {
            "L-click = give / turn on.   R-click = remove / turn off.",
            "Keys and powerups: set the seconds next to each one (- / +, or click the number and type), then click its name.",
            "- / + step: 10 | Ctrl 100 | Shift 1K | Ctrl+Shift 10K.",
            "Pink / Blue Path go in the hotbar: L-click in the world = touching that ring.",
            "Icarus Mode = the game's Icarus switch (on / off).",
            "Screenshot / Save / Respawn go in the hotbar: L-click in the world = take a screenshot without the HUD / save the game / respawn.",
        }},
        [C.TAB_ENTITIES] = { "ENTITIES", {
            "Click a monster = put it in the hotbar.",
            "In the world: L-click spawns at the white box, R-click removes the red one, Alt+wheel = distance.",
            "COUNT = how many per click, DIST = spawn distance, FREEZE = spawn them frozen, TTL(s) = seconds until they vanish (INF = never).",
            "HP: click and type the HP they spawn with. Empty (or 0) = DEFAULT, the monster's own HP.",
            "Hold Ctrl = show the type id instead of the name.",
        }},
        [C.TAB_INTERACT] = { "INTERACT", {
            "Click one = put it in the hotbar. Trophies: opens the trophy list. Text Box: asks for the text when you place it.",
            "Text boxes: in build mode, F on one shows an EDIT button (top right) to change its text.",
            "In the world: L-click places it in the white cell, R-click removes the red one, Alt+wheel = distance.",
            "Settings strip: pick XP, a powerup, a key, huge ammo, a toll, a green key / door or a door unlock.",
            "- / + step: Ctrl = 10 (100 for seconds / ammo) | Shift 1K | Ctrl+Shift 10K. The - key makes XP / powerups / keys negative.",
            "Trophies are real: touching one collects it (gold/health bonus + its Steam achievement).",
            "Hold Ctrl = show the id.",
        }},
        [C.TAB_TELEPORT] = { "TELEPORT", {
            "Click a waypoint to warp.   F6 = warp by search.",
            "HOME (F7) = go home.   PLACE WP HERE = waypoint marker at your position.",
        }},
        [C.TAB_DECOR] = { "DECOR", {
            "Click a picture = put it in the hotbar. In the world: L-click place, R-click remove, Alt+wheel = distance.",
            "Aim at a wall to hang pictures (flat on the wall).",
            "PIC SIZE: S / M / L / XL, or click the % box and type a size (10-1000).",
            "SNAP (FACING) = pictures not on a wall face straight along the nearest axis.",
            "REMOVE PICS HERE = remove the pictures near the crosshair.",
            "SCHEMATICS (bottom right) = your saved schematics.",
        }},
    }
    return TAB_HELP
end

-- DECOR -> SCHEMATICS page (win_creative_schem.lua)
local SCHEM_HELP = { "SCHEMATICS", {
    "Make one in build mode: hold Alt, middle-click (or C) one corner, aim the cyan cursor (Alt+wheel = depth), middle-click again, type a name.",
    "It keeps the blocks, interactables / pictures / text boxes with their settings, monsters (HP, frozen) and trophies. It goes into your selected hotbar slot.",
    "Holding one shows a cyan ghost: L-click places it there, Backspace undoes it.",
    "Here: click one = put it in the hotbar. R-click twice = delete it.",
    "Middle-click one = save it as Lua code: a block script (create_rect / set_pos, interactables, monsters) in Output/FileOut/block_schem_<name>.lua. Copy it into a package's WorldNodes/Nodes/. Bigger than 16x16x16 = one script per 16-block piece.",
    "Saved in Output/FileOut/creative_schems.txt (not in the mod folder, so uploading the mod never uploads them). RELOAD FILE reads it again, e.g. after copying in someone else's file.",
}}

local MENU_HELP = {
    "Click a tab, or TAB = next tab.   Wheel / Up / Down = page.",
    "Number boxes: click to type. Left / Right / Home / End move, double-click or Ctrl+A = select all, Enter = set, Esc = cancel.",
    "Esc / Close = close the menu.",
}

local WORLD_HELP = {
    "G = this menu.   V = build mode on / off.",
    "1-9 / wheel = hotbar slot.   Alt+wheel = distance.",
    "L-click = place.   R-click = break / remove (red outline).",
    "Blocks: Alt+click = area fill (L-click fill, R-click delete, Alt+wheel = depth).",
    "Alt+middle-click twice = save the box as a schematic.",
    "C / middle mouse = pick what you aim at.   Backspace = undo.",
    "F6 = warp by search.   F7 = home.",
}

-- ? button rect (square on screen)
local function btn_rect()
    local w = BTN_H / S.aspect
    return PANEL_X1 + 0.01 - w, BTN_Y, w, BTN_H
end

local function in_panel(c)
    return c.x >= PANEL_X0 and c.x <= PANEL_X1 and c.y >= PANEL_Y0 and c.y <= PANEL_Y1
end

-- word wrap to n chars; continuation lines get a 2 space indent
local function wrap(s, n)
    local out, line = {}, ""
    for word in string.gmatch(s, "%S+") do
        if line == "" then
            line = word
        elseif #line + 1 + #word <= n then
            line = line .. " " .. word
        else
            out[#out + 1] = line
            line = "  " .. word
        end
    end
    if line ~= "" then out[#out + 1] = line end
    return out
end

-- Input. Returns true when it used this frame's input (stop there).
-- tab_rect_hit(cursor) = true when the click is on a tab: those still work
-- while the help is open (it then shows that tab's help).
function C.help_input(wid, editing, esc, tab_rect_hit)
    local click = ga_win_mouse_pressed(wid, true)
    local cursor = ga_win_get_cursor_pos(wid)
    if click then
        local x, y, w, h = btn_rect()
        if C.btn_rect(cursor, x, y, w, h) then
            C.num_edit_commit()
            S.help_open = not S.help_open
            ga_play_sound("menu_select")
            return true
        end
    end
    if not S.help_open then return false end
    if esc and not editing then S.help_open = false return true end
    if click and not tab_rect_hit(cursor) then
        if not in_panel(cursor) then S.help_open = false end
        return true
    end
    return false
end

function C.render_help_button(wid)
    local cursor = ga_win_get_cursor_pos(wid)
    local x, y, w, h = btn_rect()
    local hov = C.btn_rect(cursor, x, y, w, h)
    local edge = S.help_open and std.vec(0.30, 0.85, 0.95) or std.vec(0.40, 0.40, 0.55)
    local bg = S.help_open and std.vec(0.13, 0.19, 0.27)
               or (hov and std.vec(0.34, 0.34, 0.50) or std.vec(0.10, 0.10, 0.16))
    local f = 0.002
    ga_win_quad_color(wid, x - f / S.aspect, y - f, x + w + f / S.aspect, y + h + f, edge)
    ga_win_quad_color(wid, x, y, x + w, y + h, bg)
    local ch = h * 0.62
    local cw = C.fix_charw(ch * 0.5)
    ga_win_set_char_size(wid, cw, ch)
    ga_win_set_front_color(wid, (hov or S.help_open) and std.vec(1.0, 0.92, 0.55) or std.vec(0.85, 0.85, 0.90))
    ga_win_txt(wid, x + (w - cw) * 0.5, y + (h - ch) * 0.5 + 0.002, "?")
    ga_win_set_front_color_default(wid)
end

-- draws one titled block of bullet lines; returns the next y
local function section(wid, x, y, colw, title, lines)
    local cw, ch, step = C.fix_charw(0.0078), 0.0156, 0.0255
    ga_win_set_char_size(wid, C.fix_charw(0.0095), 0.019)
    ga_win_set_front_color(wid, std.vec(0.9, 0.85, 0.5))
    ga_win_txt(wid, x, y, title)
    y = y - 0.036
    ga_win_set_char_size(wid, cw, ch)
    local n = math.max(10, math.floor(colw / cw) - 2)
    for _, s in ipairs(lines) do
        for i, l in ipairs(wrap(s, n)) do
            ga_win_set_front_color(wid, std.vec(0.86, 0.86, 0.92))
            ga_win_txt(wid, x, y, (i == 1) and ("- " .. l) or l)
            y = y - step
        end
        y = y - 0.006
    end
    ga_win_set_front_color_default(wid)
    return y - 0.020
end

function C.render_help(wid)
    if not S.help_open then return end
    local f = 0.003
    ga_win_quad_color(wid, PANEL_X0 - f / S.aspect, PANEL_Y0 - f, PANEL_X1 + f / S.aspect, PANEL_Y1 + f,
        std.vec(0.30, 0.26, 0.12))
    ga_win_quad_color(wid, PANEL_X0, PANEL_Y0, PANEL_X1, PANEL_Y1, std.vec(0.045, 0.045, 0.07))

    local top = PANEL_Y1 - 0.045
    local mid = (PANEL_X0 + PANEL_X1) * 0.5
    ga_win_quad_color(wid, mid - 0.0008, PANEL_Y0 + 0.05, mid + 0.0008, PANEL_Y1 - 0.02, std.vec(0.20, 0.20, 0.28))

    local th = tab_help()[S.cur_tab] or { "MENU", {} }
    if S.cur_tab == C.TAB_DECOR and C.dp ~= nil and C.dp.sub == "schems" then th = SCHEM_HELP end
    section(wid, PANEL_X0 + 0.02, top, mid - PANEL_X0 - 0.04, th[1] .. " TAB", th[2])

    local y = section(wid, mid + 0.02, top, PANEL_X1 - mid - 0.04, "MENU", MENU_HELP)
    section(wid, mid + 0.02, y, PANEL_X1 - mid - 0.04, "IN THE WORLD (build mode)", WORLD_HELP)

    ga_win_set_char_size(wid, C.fix_charw(0.0072), 0.0144)
    ga_win_set_front_color(wid, std.vec(0.5, 0.5, 0.58))
    ga_win_txt_center(wid, PANEL_Y0 + 0.016, "? / Esc / click outside = close help")
    ga_win_set_front_color_default(wid)
end

-- not a real window: only here so the window Lua state loads it
function p.__start(wid) end
function p.__end(wid) end
function p.__on_start(wid) end
function p.__on_end(wid) end
function p.__render(wid) end
function p.__process_input(wid) end
