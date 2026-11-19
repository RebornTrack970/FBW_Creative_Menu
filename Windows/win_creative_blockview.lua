-- Creative menu: PREVIEW on the BLOCKS tab (button at the right end of the
-- strip; on by default). On: the grid takes the left half (C.compute_grid) and
-- the right half shows the chunk inside a block in 3D: the R-clicked (pinned)
-- one, else the block under the mouse, else the selected one. R-click the
-- pinned one again = follow the mouse again. Clicking picks a block as usual.
-- Where the chunk comes from:
--   * blocks with a Lua chunk generator (their module's __main): it is run
--     with WORLDGEN's stand-ins (win_creative_worldgen.lua C.wg_generate);
--   * the built-in XAR_* blocks (made by FBW.exe, no Lua to run): the chunk
--     library - one chunk per type made by the game's own generators
--     (Tools/chunk_library, Game/game_creative_chunklib.lua).
-- Drawn by C.wg_render_chunk, turned with the camera of win_creative_view3d.lua.
-- See win_creative_core.lua for how the files share things.
creative_ui = creative_ui or {}          -- shared by all win_creative*.lua files (one window Lua state)
creative_ui.state = creative_ui.state or {}
local C, S = creative_ui, creative_ui.state

C.bv = {
    btn = { x = 0.895, w = 0.080 },      -- PREVIEW on the BLOCKS strip (y / h = the strip's)
}

local cam = nil                          -- C.cam_new(), made on first use
local PREVIEW_X, PREVIEW_Y = 0.75, 0.48  -- centre of the preview
local GIZMO_X, GIZMO_Y     = 0.935, 0.235
local NAME_Y, NOTE_Y       = 0.188, 0.162
local err_shown            = {}          -- block -> true: render error printed once

-- the game side (windows and game scripts share one Lua state)
local function game()
    local g = rawget(_G, "creative_g")
    if type(g) == "table" then return g end
    return nil
end

-- a block's chunk: { chunk, kind }. kind: "lua" (its generator ran), "error"
-- (it errored), "lib" (from the chunk library), "none" (not in the library).
-- Kept for the last CACHE_MAX blocks, so moving the mouse over the grid
-- doesn't run a generator again (or print its error again) every time.
local CACHE_MAX = 24
local cache, cache_order = {}, {}
local function preview_gen(bt)
    local g = cache[bt]
    if g then return g end
    g = { chunk = nil, kind = "none" }
    if C.wg_has_gen(bt) then
        g.chunk = C.wg_generate(bt, C.world_seed())             -- nil = errored (printed)
        g.kind = g.chunk and "lua" or "error"
    else
        local gs = game()
        if gs and gs.clib_chunk then
            local ok, chunk = pcall(gs.clib_chunk, bt, C.world_seed())    -- (random types: the world seed picks)
            if ok and type(chunk) == "table" then g.chunk, g.kind = chunk, "lib" end
        end
    end
    cache[bt] = g
    cache_order[#cache_order + 1] = bt
    if #cache_order > CACHE_MAX then cache[table.remove(cache_order, 1)] = nil end
    return g
end

-- the block to show: the pinned one, else the tile under the mouse, else the
-- selected block
local function preview_bt(wid)
    if S.block_pin ~= nil then return S.block_pin end
    local gi = C.hovered_index(ga_win_get_cursor_pos(wid))
    if gi >= 1 and S.items[gi] then return S.items[gi].raw end
    local k, r = C.cur_entry()
    if k == "block" and r ~= "" then return r end
    return nil
end

function C.bv.toggle()
    local first = S.page * S.PER_PAGE            -- keep the first tile on screen
    S.block_preview = not S.block_preview
    if not S.block_preview then S.block_pin = nil end
    C.compute_grid()
    S.page = math.max(0, math.min(first // S.PER_PAGE, C.num_pages() - 1))
    ga_play_sound("menu_select")
end

-- R-click on BLOCKS tile gi with PREVIEW on: pin it (the preview stops
-- following the mouse); R-click the pinned one again = unpin
function C.bv.pin(gi)
    local it = S.items[gi]
    if it == nil then return end
    if S.block_pin == it.raw then S.block_pin = nil else S.block_pin = it.raw end
    ga_play_sound("menu_move")
end

function C.bv.is_pinned(raw)
    return S.block_preview and raw ~= nil and raw == S.block_pin
end

-- a drag starts only on the preview (right of the grid, above the info lines)
local function on_preview(cursor)
    local gx1 = C.X0 + S.COLS * S.CW + 0.01
    return cursor.x > gx1 and cursor.x < 0.99 and cursor.y > NAME_Y + 0.025 and cursor.y < 0.80
       and not C.cam_on_gizmo(cursor, GIZMO_X, GIZMO_Y)
end

local function render_3d(bt, g)
    local depth = 0
    local ok, err = pcall(function()
        ga_render_color(std.vec(1.0, 1.0, 1.0))
        ga_render_push_matrix(); depth = 1
        ga_render_matrix_translated(PREVIEW_X, PREVIEW_Y, 0)
        ga_render_set_depth_test_enabled(true)
        C.wg_render_chunk(cam, g.chunk, C.WG_FULL, g.kind == "lib")
        -- the library's interactables and monsters, as models (the schematic
        -- preview's; types without a model = a small see-through cube).
        -- Same matrix: wg_render_chunk left the chunk's turntable on it.
        local ents, mons = g.chunk.lib_ents, g.chunk.lib_mons
        local gs = game()
        if gs and type(gs.schem_ent_meshes) == "function" and ((ents and #ents > 0) or (mons and #mons > 0)) then
            ga_render_color(std.vec(1.0, 1.0, 1.0))
            gs.schem_ent_meshes({ bents = ents or {}, ments = mons or {} }, 0, 0, 0, nil, true)
        end
    end)
    for _ = 1, depth do ga_render_pop_matrix() end
    ga_render_color(std.vec(1.0, 1.0, 1.0))
    ga_render_set_depth_test_enabled(false)
    if not ok and not err_shown[bt] then
        err_shown[bt] = true                     -- once, not every frame
        ga_console_print("creative block preview error (" .. tostring(bt) .. "): " .. tostring(err))
    end
end

-- centred under the preview, between the grid (gx1) and the gizmo (0.89)
local function centred_txt(wid, y, cw, ch, col, text, gx1)
    text = C.fit(text, math.max(4, math.floor((0.89 - gx1) / cw)))
    local w = #text * cw
    ga_win_set_char_size(wid, cw, ch)
    ga_win_set_front_color(wid, col)
    ga_win_txt(wid, math.max(gx1, math.min(PREVIEW_X - w * 0.5, 0.89 - w)), y, text)
    ga_win_set_front_color_default(wid)
end

local GREY = std.vec(0.45, 0.45, 0.55)

-- right half of the BLOCKS tab; call before the grid (its hover tip goes over this)
function C.bv.render(wid)
    cam = cam or C.cam_new()
    C.cam_input(wid, cam, on_preview)
    local gx1 = C.X0 + S.COLS * S.CW + 0.02
    local bt = preview_bt(wid)
    if bt == nil then
        centred_txt(wid, PREVIEW_Y, 0.010, 0.020, GREY, "Point at a block to preview the chunk inside it", gx1)
        return
    end

    local g = preview_gen(bt)
    local note
    if g.kind == "lua" or g.kind == "lib" then
        render_3d(bt, g)
        ga_win_set_screen_coord_mode(wid, "screen")
        note = ((g.chunk.n or 1) == 0) and "all air" or nil
        C.cam_gizmo(wid, cam, GIZMO_X, GIZMO_Y)
    elseif g.kind == "error" then
        centred_txt(wid, PREVIEW_Y, 0.010, 0.020, std.vec(1.0, 0.45, 0.35), "Its Lua generator ERRORED", gx1)
        note = "see the console for why"
    else
        centred_txt(wid, PREVIEW_Y, 0.010, 0.020, GREY, "No preview for this block", gx1)
        note = "its generator can't run outside the world"
    end
    centred_txt(wid, NAME_Y, 0.009, 0.018, std.vec(0.75, 0.90, 1.0), C.clean_name(bt), gx1)
    if note then centred_txt(wid, NOTE_Y, 0.0075, 0.015, std.vec(0.6, 0.6, 0.65), note, gx1) end
end

-- not a real window: only here so the window Lua state loads it
function p.__start(wid) end
function p.__end(wid) end
function p.__on_start(wid) end
function p.__on_end(wid) end
function p.__render(wid) end
function p.__process_input(wid) end
