-- Creative mode (game side): the 3D outlines / previews in build mode.
-- See game_creative_core.lua for how the files share things.
creative_g = creative_g or {}           -- shared by all game_creative*.lua files (one game Lua state)
creative_g.state = creative_g.state or {}
local C, S = creative_g, creative_g.state

-------------------------------------------------------------------------------
-- 3D outline (called by the engine every frame for every game script)
-------------------------------------------------------------------------------

local WHITE = { 1.0, 1.0, 1.0 }
local GREY  = { 0.55, 0.55, 0.55 }
local RED   = { 1.0, 0.3, 0.3 }

local function draw_box(x0, y0, z0, x1, y1, z1, col, thick)
    ga_render_color(std.vec(col[1], col[2], col[3]))
    local xs, ys, zs = { x0, x1 }, { y0, y1 }, { z0, z1 }
    for i = 1, 2 do
        for j = 1, 2 do
            ga_render_line_thick(std.vec(xs[i], ys[j], z0), std.vec(xs[i], ys[j], z1), thick)
            ga_render_line_thick(std.vec(xs[i], y0, zs[j]), std.vec(xs[i], y1, zs[j]), thick)
            ga_render_line_thick(std.vec(x0, ys[i], zs[j]), std.vec(x1, ys[i], zs[j]), thick)
        end
    end
end

-- outline of the block(s) around bp; grow > 0 sits just outside the faces
local function draw_cells(bp, size, grow, col, thick)
    draw_box(bp.x - size - grow, bp.y - size - grow, bp.z - size - grow,
             bp.x + size + 1 + grow, bp.y + size + 1 + grow, bp.z + size + 1 + grow, col, thick)
end

-- outline of a picture rectangle (d = bent_picture / picture_placement data)
local function draw_picture_rect(d, col, thick)
    local rx, ry = d.fy, -d.fx                       -- picture's width direction
    local hw, hh = d.w * 0.5, d.h * 0.5
    local c = d.c
    local k = {
        std.vec(c.x - rx * hw, c.y - ry * hw, c.z - hh), std.vec(c.x + rx * hw, c.y + ry * hw, c.z - hh),
        std.vec(c.x + rx * hw, c.y + ry * hw, c.z + hh), std.vec(c.x - rx * hw, c.y - ry * hw, c.z + hh),
    }
    ga_render_color(std.vec(col[1], col[2], col[3]))
    for i = 1, 4 do ga_render_line_thick(k[i], k[i % 4 + 1], thick) end
end

-- red box around what right click would remove
local function draw_remove_target(tg, vlevel)
    if tg.pic ~= nil then
        draw_picture_rect(tg.pic, RED, 2.5)
    elseif tg.what == "ment" then
        local c = ga_ment_get_lp(tg.id)
        local r = ga_ment_get_radius(tg.id) or 0.5
        draw_box(c.x - r, c.y - r, c.z - r, c.x + r, c.y + r, c.z + r, RED, 2.0)
    elseif tg.level == vlevel then
        draw_cells(tg.bp, 0, 0.01, RED, 2.0)
    end
end

local function brush_radius()
    local shape = ga_get_s("temp.creative.brush_shape")
    local size  = ga_get_i("temp.creative.brush_size") or 0
    if shape == nil or shape == "" or shape == "single" or size < 0 then return 0 end
    return size
end

local CYAN   = { 0.0, 1.0, 1.0 }
local ORANGE = { 1.0, 0.6, 0.1 }

-- Area selection: almost transparent cyan box (own mesh/texture, see
-- Meshes/mesh_names.txt + Textures/texture_names.txt) with an outline (cyan,
-- orange when part of it is outside the loaded chunks).
-- x0..x1 etc. are inclusive block coords.
--
-- ORDER MATTERS: lines (ga_render_line_thick = glBegin/glVertex) use the real
-- GL matrices, but ga_render_matrix_*/push/pop only change FBW's own matrix
-- stack (GLPlusWrapper). The real matrices are only synced from that stack
-- when something is drawn through a shader (GLPlusWrapper::
-- RefreshShaderPVMMatrix: meshes, triangles, chunks). The engine syncs right
-- before __render_augmented, so lines are right until our mesh draw syncs
-- the box's translate+scale; ga_render_pop_matrix does NOT sync back. Lines
-- drawn after the mesh were therefore scaled up and pushed far away (the
-- "copy" on the K/M-chunk terrain). So: every line first, the mesh last.
-- The caller draws area_lines() (and any other lines) before area_fill().
local function area_bounds(x0, y0, z0, x1, y1, z1)
    local g = 0.015
    return x0 - g, y0 - g, z0 - g, x1 + 1 + g, y1 + 1 + g, z1 + 1 + g
end

local function area_lines(x0, y0, z0, x1, y1, z1, col)
    local ax, ay, az, bx, by, bz = area_bounds(x0, y0, z0, x1, y1, z1)
    draw_box(ax, ay, az, bx, by, bz, col or CYAN, 2.5)
end

-- must be the LAST draw of the frame's __render_augmented (see above)
local function area_fill(x0, y0, z0, x1, y1, z1)
    local ax, ay, az, bx, by, bz = area_bounds(x0, y0, z0, x1, y1, z1)
    ga_render_push_matrix()
    pcall(function()
        -- creative_area_box = unit cube centred on the origin
        ga_render_matrix_translated((ax + bx) * 0.5, (ay + by) * 0.5, (az + bz) * 0.5)
        ga_render_matrix_scaled(bx - ax, by - ay, bz - az)
        ga_render_mesh_with_tex_alpha_no_lighting("creative_area_box", "creative_cyan", 0.15)
    end)
    ga_render_pop_matrix()
end

local function render_block_outline()
    local vlevel = ga_get_viewer_level()
    local alt = ga_get_b(C.ALT_VAR)
    local level, bp, bp2 = C.look_target()

    if alt and S.area ~= nil then
        if S.area.level ~= vlevel then return end
        -- live 3D box from corner 1 (re-resolved: the grid shifts as you
        -- move) to the depth cursor
        local a = C.area_a()
        if a == nil then return end
        local c = C.area_cursor() or a
        local x0, y0, z0, x1, y1, z1 = C.area_box(a, c)
        local w, h, d = x1 - x0 + 1, y1 - y0 + 1, z1 - z0 + 1
        local n = w * h * d
        local loaded = "all"
        if n <= C.AREA_CAP then loaded = C.box_loaded(vlevel, x0, y0, z0, x1, y1, z1) end
        area_lines(x0, y0, z0, x1, y1, z1, (loaded == "all") and CYAN or ORANGE)
        draw_cells(c, 0, 0.03, CYAN, 3.0)       -- the cursor cell itself
        area_fill(x0, y0, z0, x1, y1, z1)        -- mesh LAST: no lines after it
        local info = w .. "x" .. h .. "x" .. d .. " = " .. n
        if n > C.AREA_CAP then info = info .. " (too big, max " .. C.AREA_CAP .. ")"
        elseif loaded ~= "all" then info = info .. " (part not loaded, skipped)" end
        info = info .. "   depth " .. S.area_depth
        if ga_get_s(C.AREA_VAR) ~= info then ga_set_s(C.AREA_VAR, info) end
        return                                  -- no white/grey outlines while dragging
    end

    if alt and (level == nil or level ~= vlevel) then
        -- Alt held, nothing of your level aimed (sky, K/M-chunk terrain):
        -- corner 1 would go on the 3D cursor, kept inside the loaded chunks
        local c = C.area_cursor()
        if c ~= nil then draw_cells(c, 0, 0.03, CYAN, 3.0) end
        return
    end

    -- red: a shop / picture / trophy / monster in front of the block is what
    -- R-click removes instead of the block
    local tg = (not alt) and C.crosshair_target() or nil
    if tg ~= nil then draw_remove_target(tg, vlevel) end

    if level == nil or level ~= vlevel then return end
    local r = alt and 0 or brush_radius()       -- area mode ignores the brush
    if tg == nil then
        draw_cells(bp, r, 0.006, WHITE, 2.0)    -- what R-click breaks
    end
    draw_cells(bp2, r, -0.03, GREY, 1.0)        -- where L-click places
end

local function render_nonblock_preview(kind, raw)
    local vlevel = ga_get_viewer_level()

    -- red: what right click removes
    local tg = C.find_remove_target(kind)
    if tg ~= nil then draw_remove_target(tg, vlevel) end

    -- white: where left click places
    if kind == "picture" then
        draw_picture_rect(C.picture_placement(raw), WHITE, 2.0)
        return
    end
    local _, pos = C.aim_point(0.5)
    if kind == "bent" or kind == "secret" or kind == "trophy" then
        draw_cells(std.lp_to_bp(pos), 0, -0.02, WHITE, 2.0)
    else
        local r = 0.5
        if kind == "ment" then
            local ok, sr = pcall(function()
                if ga_ment_type_var_exists(raw, "__radius") then return ga_ment_get_static_f(raw, "__radius") end
            end)
            if ok and type(sr) == "number" then r = sr end
        end
        if r < 0.2 then r = 0.2 end
        if r > 4.0 then r = 4.0 end
        draw_box(pos.x - r, pos.y - r, pos.z - r, pos.x + r, pos.y + r, pos.z + r, WHITE, 1.5)
        local k = 0.15   -- small cross marking the exact point
        ga_render_line_thick(std.vec(pos.x - k, pos.y, pos.z), std.vec(pos.x + k, pos.y, pos.z), 2.0)
        ga_render_line_thick(std.vec(pos.x, pos.y - k, pos.z), std.vec(pos.x, pos.y + k, pos.z), 2.0)
        ga_render_line_thick(std.vec(pos.x, pos.y, pos.z - k), std.vec(pos.x, pos.y, pos.z + k), 2.0)
    end
end

local outline_err_shown = false
local function render_outline()
    if not ga_exists(C.MODE_VAR) or not ga_get_b(C.MODE_VAR) then return end
    C.chunk_cache_reset()   -- vcps shift as you move, so cache per frame only
    local kind, raw = C.cur_entry()
    if kind == "path" then
        -- nothing to aim with a path entry
    elseif kind ~= nil and kind ~= "block" then
        render_nonblock_preview(kind, raw)
    else
        render_block_outline()
    end
    ga_render_color(std.vec(1.0, 1.0, 1.0))
end

-- The engine calls this once per rendered level (your level, the K-chunk's
-- level, ...), each pass in that level's coordinates. Our coords are viewer-
-- level coords, so draw only on the viewer level's pass.
function p.__render_augmented(level)
    if type(level) == "number" and level ~= ga_get_viewer_level() then return end
    local ok, err = pcall(render_outline)
    if not ok and not outline_err_shown then
        outline_err_shown = true   -- report once, don't spam every frame
        ga_console_print("creative outline error: " .. tostring(err))
    end
end
