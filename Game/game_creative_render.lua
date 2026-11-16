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

-- Alt held with corner 1 set (area fill or schematic, any hotbar slot): the
-- live box. Returns true when it drew it (then nothing else is drawn).
local function render_area_select()
    if not ga_get_b(C.ALT_VAR) or S.area == nil then return false end
    local vlevel = ga_get_viewer_level()
    if S.area.level ~= vlevel then return true end
    -- live 3D box from corner 1 (re-resolved: the grid shifts as you move) to
    -- the depth cursor
    local a = C.area_a()
    if a == nil then return true end
    local c = C.area_cursor() or a
    local x0, y0, z0, x1, y1, z1 = C.area_box(a, c)
    local w, h, d = x1 - x0 + 1, y1 - y0 + 1, z1 - z0 + 1
    local n = w * h * d
    local loaded = "all"
    if n <= C.AREA_CAP then loaded = C.box_loaded(vlevel, x0, y0, z0, x1, y1, z1) end
    area_lines(x0, y0, z0, x1, y1, z1, (loaded == "all") and CYAN or ORANGE)
    draw_cells(c, 0, 0.03, CYAN, 3.0)           -- the cursor cell itself
    area_fill(x0, y0, z0, x1, y1, z1)            -- mesh LAST: no lines after it
    local info = w .. "x" .. h .. "x" .. d .. " = " .. n
    if n > C.AREA_CAP then info = info .. " (too big, max " .. C.AREA_CAP .. ")"
    elseif loaded ~= "all" then info = info .. " (part not loaded, skipped)" end
    info = info .. "   depth " .. S.area_depth
    if ga_get_s(C.AREA_VAR) ~= info then ga_set_s(C.AREA_VAR, info) end
    return true                                  -- no white/grey outlines while dragging
end

local function render_block_outline()
    local vlevel = ga_get_viewer_level()
    local alt = ga_get_b(C.ALT_VAR)
    local level, bp, bp2 = C.look_target()

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
        draw_cells(bp, r, 0.001, WHITE, 2.0)    -- what R-click breaks
    end
    draw_cells(bp2, r, -0.001, GREY, 1.0)        -- where L-click places
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
        --if r < 0.2 then r = 0.2 end
        --if r > 4.0 then r = 4.0 end
        draw_box(pos.x - r, pos.y - r, pos.z - r, pos.x + r, pos.y + r, pos.z + r, WHITE, 1.5)
        local k = 0.15   -- small cross marking the exact point
        ga_render_line_thick(std.vec(pos.x - k, pos.y, pos.z), std.vec(pos.x + k, pos.y, pos.z), 2.0)
        ga_render_line_thick(std.vec(pos.x, pos.y - k, pos.z), std.vec(pos.x, pos.y + k, pos.z), 2.0)
        ga_render_line_thick(std.vec(pos.x, pos.y, pos.z - k), std.vec(pos.x, pos.y, pos.z + k), 2.0)
    end
end

-------------------------------------------------------------------------------
-- Ent models: how to draw a basic ent / moving ent TYPE without an instance
-- (schematic ghost here, the SCHEMS tab's 3D preview in the menu).
--
-- Only meshes the game surely has: an unknown mesh name makes the engine quit
-- (FBW.exe PackageMeshSystem::GetTexName -> PoliteExit; pcall can't catch it)
-- and there is no "does this mesh exist" function. So:
--   * moving ents: their __mesh (every xar / base type sets it at type init;
--     the engine draws exactly that one for live ents),
--   * basic ents: __get_mesh() / __get_mesh2(), else the mesh named like the
--     type (what the engine does), minus the xar bents that have no such mesh
--     (same list as the INTERACT icons, Windows/win_creative_tex.lua),
--   * types that draw themselves (__on_render) are skipped (they may read the
--     world at their spot), except our own pictures, drawn from their param.
-- Model = { meshes = { { mesh, tex }, ... }, scale, pulse } or false.
-------------------------------------------------------------------------------
local NO_MESH_BENTS = { bent_ammo_gun_3_huge = true, bent_genesis_marker_long = true,
                        bent_genesis_marker_short = true }
local PIC_BENT, PIC_MESH, PIC_THICKNESS = "bent_creative_picture", "creative_picture", 0.06

local model_cache = { bent = {}, ment = {} }

-- a texture name the game really has, else nil
local function real_tex(name)
    if type(name) ~= "string" or name == "" then return nil end
    local ui = rawget(_G, "creative_ui")
    if type(ui) ~= "table" or type(ui.ntex) ~= "function" then return nil end
    local ok, t = pcall(ui.ntex, name)
    if ok and t == name then return t end
    return nil
end

local function mesh_entry(mesh)
    if type(mesh) ~= "string" or mesh == "" then return nil end
    local ok, tex = pcall(ga_mesh_get_tex, mesh)
    if not ok or type(tex) ~= "string" then return nil end
    return { mesh = mesh, tex = tex }
end

local function bent_model(t)
    local mod = rawget(_G, t)
    if type(mod) ~= "table" or mod.__on_render ~= nil then return false end
    local meshes = {}
    local m1 = nil
    if mod.__get_mesh ~= nil then
        local ok, r = pcall(mod.__get_mesh)
        if ok then m1 = r end
    elseif not NO_MESH_BENTS[t] then
        m1 = t                                   -- the engine's default: mesh named like the type
    end
    meshes[#meshes + 1] = mesh_entry(m1)
    if mod.__get_mesh2 ~= nil then
        local ok, r = pcall(mod.__get_mesh2)
        if ok then meshes[#meshes + 1] = mesh_entry(r) end
    end
    if #meshes == 0 then return false end
    local scale, pulse = 1.0, true
    if mod.__get_scale ~= nil then
        local ok, r = pcall(mod.__get_scale)
        if ok and type(r) == "number" then scale = r end
    end
    if mod.__get_pulsates ~= nil then
        local ok, r = pcall(mod.__get_pulsates)
        if ok and r == false then pulse = false end
    end
    return { meshes = meshes, scale = scale, pulse = pulse }
end

local function ment_static(t, var, getter)
    local ok, has = pcall(ga_ment_type_var_exists, t, var)
    if not ok or has ~= true then return nil end
    local ok2, v = pcall(getter, t, var)
    if ok2 then return v end
    return nil
end

local function ment_model(t)
    local mod = rawget(_G, t)
    if type(mod) == "table" and mod.__on_render ~= nil then return false end
    if ment_static(t, "__hide", ga_ment_get_static_b) == true then return false end
    local mesh = ment_static(t, "__mesh", ga_ment_get_static_s)
    local e = mesh_entry(mesh)
    if e == nil then return false end
    local tex = real_tex(ment_static(t, "__tex_override", ga_ment_get_static_s))
    if tex then e.tex = tex end
    local r = ment_static(t, "__radius", ga_ment_get_static_f)
    if type(r) ~= "number" or r <= 0 then r = 0.5 end
    local ok, inv = pcall(ga_mesh_get_inv_radius, mesh)
    if not ok or type(inv) ~= "number" then inv = 1.0 end
    return { meshes = { e }, scale = r * inv, pulse = false }
end

-- kind "bent" | "ment"; false when it has no model we can draw
function C.ent_model(kind, t)
    local cache = model_cache[kind]
    if cache == nil or type(t) ~= "string" then return false end
    local m = cache[t]
    if m == nil then
        m = (kind == "bent") and bent_model(t) or ment_model(t)
        cache[t] = m
    end
    return m
end

-- our picture's param -> { tex, w, h, fx, fy, ox, oy, oz } (the bent's own decode)
local function picture_data(ps)
    local mod = rawget(_G, PIC_BENT)
    if type(mod) ~= "table" or type(mod.decode) ~= "function" then return nil end
    local ok, d = pcall(mod.decode, ps)
    if ok and type(d) == "table" and real_tex(d.tex) then return d end
    return nil
end

-- Draws one model with the matrix at the ent's centre. alpha = number: see-
-- through, unlit (ghost); nil: solid (menu preview). tex = a texture to use
-- instead (a ment's saved __tex_override).
local function draw_model(m, alpha, tex)
    local s = m.scale
    if m.pulse then s = s * (1.0 + math.cos(6.0 * ga_get_sys_f("time.current")) * 0.1) end
    ga_render_matrix_scaled(s, s, s)
    for _, e in ipairs(m.meshes) do
        local tx = tex or e.tex
        if alpha then ga_render_mesh_with_tex_alpha_no_lighting(e.mesh, tx, alpha)
        else ga_render_mesh_with_tex(e.mesh, tx) end
    end
end

local function draw_picture(d, alpha)
    ga_render_matrix_translated(d.ox, d.oy, d.oz)
    ga_render_matrix_frame(std.vec(d.fy, -d.fx, 0.0), std.vec(d.fx, d.fy, 0.0), std.vec(0.0, 0.0, 1.0))
    ga_render_matrix_scaled(d.w, PIC_THICKNESS, d.h)
    if alpha then ga_render_mesh_with_tex_alpha_no_lighting(PIC_MESH, d.tex, alpha)
    else ga_render_mesh_with_tex_no_lighting(PIC_MESH, d.tex) end
end

-- what a schematic ent looks like: "model" (+ the model), "picture" (+ data) or nil
local function sch_bent_look(b)
    if b.t == PIC_BENT then
        local d = picture_data(b.ps)
        if d then return "picture", d end
        return nil
    end
    local m = C.ent_model("bent", b.t)
    if m then return "model", m end
    return nil
end

-- Schematic ents at box corner (ox, oy, oz). Lines (ghost only): the cyan box /
-- cross of every ent WITHOUT a model - call before any mesh (see area_fill).
function C.schem_ent_lines(sch, ox, oy, oz)
    for _, b in ipairs(sch.bents) do
        if sch_bent_look(b) == nil then
            draw_cells(std.bp(ox + b.x, oy + b.y, oz + b.z), 0, -0.3, CYAN, 1.5)
        end
    end
    local k = 0.35
    ga_render_color(std.vec(CYAN[1], CYAN[2], CYAN[3]))
    for _, m in ipairs(sch.ments) do
        if not C.ent_model("ment", m.t) then
            local x, y, z = ox + m.x, oy + m.y, oz + m.z
            ga_render_line_thick(std.vec(x - k, y, z), std.vec(x + k, y, z), 2.0)
            ga_render_line_thick(std.vec(x, y - k, z), std.vec(x, y + k, z), 2.0)
            ga_render_line_thick(std.vec(x, y, z - k), std.vec(x, y, z + k), 2.0)
        end
    end
end

-- Meshes of the schematic's ents. alpha: see draw_model. stand_in = true
-- (menu: no lines there) draws a small see-through cube for ents without a model.
function C.schem_ent_meshes(sch, ox, oy, oz, alpha, stand_in)
    local function one(x, y, z, f)
        ga_render_push_matrix()
        ga_render_matrix_translated(x, y, z)
        local ok, err = pcall(f)
        ga_render_pop_matrix()
        return ok, err
    end
    local function cube(size)
        return function()
            ga_render_matrix_scaled(size, size, size)
            ga_render_mesh_with_tex_alpha_no_lighting("creative_area_box", "creative_cyan", 0.5)
        end
    end
    for _, b in ipairs(sch.bents) do
        local look, d = sch_bent_look(b)
        local x, y, z = ox + b.x + 0.5, oy + b.y + 0.5, oz + b.z + 0.5
        if look == "model" then
            one(x, y, z, function() draw_model(d, alpha) end)
        elseif look == "picture" then
            one(x, y, z, function() draw_picture(d, alpha) end)
        elseif stand_in then
            one(x, y, z, cube(0.4))
        end
    end
    for _, m in ipairs(sch.ments) do
        local model = C.ent_model("ment", m.t)
        local x, y, z = ox + m.x, oy + m.y, oz + m.z
        if model then
            one(x, y, z, function() draw_model(model, alpha, real_tex(m.tex)) end)
        elseif stand_in then
            one(x, y, z, cube(0.5))
        end
    end
end

-- Holding a schematic: where L-click puts it. Outline of its box (orange when
-- part of it isn't loaded), the blocks as half see-through cubes with their
-- own textures (game_creative_schem.lua C.schem_holo) and the ents / monsters
-- as half see-through models (a cyan box / cross for ents without a model).
-- Lines first, the meshes LAST (see area_fill).
local HOLO_ALPHA, HOLO_SCALE = 0.5, 0.98     -- a hair inside the cells: no flicker on block faces
local HOLO_TINT = { 0.80, 1.0, 1.0 }         -- same light cyan as the blocks' textures
local function holo_cube(x, y, z, tex)
    ga_render_matrix_translated(x, y, z)
    ga_render_matrix_scaled(HOLO_SCALE, HOLO_SCALE, HOLO_SCALE)
    ga_render_mesh_with_tex_alpha_no_lighting("creative_area_box", tex, HOLO_ALPHA)
end
local function render_schem_preview(raw)
    local sch = C.schem_get(raw)
    if sch == nil then return end
    local level, ox, oy, oz = C.schem_origin(sch)
    if level ~= ga_get_viewer_level() then return end
    local x1, y1, z1 = ox + sch.sx - 1, oy + sch.sy - 1, oz + sch.sz - 1
    local loaded = C.box_loaded(level, ox, oy, oz, x1, y1, z1)
    area_lines(ox, oy, oz, x1, y1, z1, (loaded == "all") and CYAN or ORANGE)
    C.schem_ent_lines(sch, ox, oy, oz)
    local holo = C.schem_holo(sch)
    for _, g in ipairs(holo.groups) do
        ga_render_color(std.vec(g.col[1], g.col[2], g.col[3]))   -- tints the texture
        local c = g.cells
        for i = 1, #c, 3 do
            ga_render_push_matrix()
            pcall(holo_cube, ox + c[i] + 0.5, oy + c[i + 1] + 0.5, oz + c[i + 2] + 0.5, g.tex)
            ga_render_pop_matrix()
        end
    end
    ga_render_color(std.vec(HOLO_TINT[1], HOLO_TINT[2], HOLO_TINT[3]))
    C.schem_ent_meshes(sch, ox, oy, oz, HOLO_ALPHA, false)
end

local outline_err_shown = false
local function render_outline()
    if not ga_exists(C.MODE_VAR) or not ga_get_b(C.MODE_VAR) then return end
    C.chunk_cache_reset()   -- vcps shift as you move, so cache per frame only
    local kind, raw = C.cur_entry()
    if render_area_select() then
        -- Alt + corner 1 set: only the selection box
    elseif kind == "path" or kind == "action" then
        -- nothing to aim with a path / action entry (and no box in screenshots)
    elseif kind == "schem" then
        render_schem_preview(raw)
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
