-- Creative mode (game side): block editing - brush, undo, Alt area fill.
-- See game_creative_core.lua for how the files share things.
creative_g = creative_g or {}           -- shared by all game_creative*.lua files (one game Lua state)
creative_g.state = creative_g.state or {}
local C, S = creative_g, creative_g.state

C.undo_stack = {}
local UNDO_MAX   = 1000

local function undo_push(batch)
    if #batch == 0 then return end
    C.undo_stack[#C.undo_stack + 1] = batch
    while #C.undo_stack > UNDO_MAX do table.remove(C.undo_stack, 1) end
end

local BRUSH_CELL_CAP = 4096

local function brush_cells(center)
    local shape = ga_get_s("temp.creative.brush_shape")
    local size  = ga_get_i("temp.creative.brush_size")
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

local base_paths
-- turn a path string into a minipath which is smaller (but coupled to base_paths)
local function make_minipath(path)
    -- stub!!!
    return path
end
function C.full_path_from_minipath(minipath)
    -- stub!!!
    return minipath
end

-- cache does not survive across update discretes
local function get_undo_pos(level, bp, cache)
    local vcp = std.bp_to_parent_vcp(bp)
    local vcpstr = vcp.x .. "_" .. vcp.y .. "_" .. vcp.z
    local lbph = std.lbp_to_lbph(std.bp_to_lbp(bp))
    if cache[vcpstr] then return cache[vcpstr],lbph end
    local path = ga_chunk_id_to_path(ga_vcp_to_chunk_id(level, vcp))

    local minipath = make_minipath(path)

    return minipath,lbph
end

local function apply_cells(level, cells, new_name)
    local cache = {}
    local batch = {}
    for _, cell in ipairs(cells) do
        local ok_old, old = pcall(ga_block_get, level, cell)
        if ok_old and old ~= new_name then
            ga_block_change_perm(level, cell, new_name)
            local path,lbph = get_undo_pos(level, cell, cache)
            batch[#batch + 1] = { path = path, lbph = lbph, old = old }
        end
    end
    undo_push(batch)
    return #batch
end

function C.apply_brush(level, center, new_name)
    return apply_cells(level, brush_cells(center), new_name)
end

-------------------------------------------------------------------------------
-- Area fill (block selected + Alt held). First click sets corner 1: L = the
-- cell a normal L-click would place into, R = the block a normal R-click would
-- break. Second click (still holding Alt) sets corner 2 the same way and then
-- L fills the box with the selected block, R deletes it. Releasing Alt cancels.
--
-- Block positions are VIEWER-CENTRIC (std.lua: vcp = "viewer centric
-- position"): the whole grid shifts by 16 every time you walk into another
-- chunk. A corner kept as a plain bp therefore jumped to another chunk while
-- you moved. Corner 1 is stored as (chunk path + offset from that chunk) and
-- turned back into a bp every time it is used, like the undo stack does.
--
-- Only chunks of YOUR level that are loaded can be edited. Past them the
-- world is drawn with K-chunks / M-chunks (the levels above), so the cursor
-- and the box are kept inside the loaded chunks instead of being drawn on top
-- of that far terrain.
-------------------------------------------------------------------------------

C.AREA_VAR = "temp.creative.area"   -- "" or "WxHxD (n)" for the HUD hint
C.AREA_CAP = 32768                  -- max blocks per fill (32^3)
S.area = nil                        -- { level, anchor, mode = "place" | "break" }

function C.area_cancel()
    S.area = nil
    if ga_exists(C.AREA_VAR) and ga_get_s(C.AREA_VAR) ~= "" then ga_set_s(C.AREA_VAR, "") end
end

-- chunk id of the loaded chunk at vcp on level, or nil. Cached; the cache is
-- reset every frame / click because vcps shift when the viewer moves.
local chunk_cache = {}
function C.chunk_cache_reset() chunk_cache = {} end

local function chunk_at(level, vx, vy, vz)
    local key = level .. ":" .. vx .. "," .. vy .. "," .. vz
    local c = chunk_cache[key]
    if c == nil then
        local ok, cid = pcall(ga_vcp_to_chunk_id, level, { x = vx, y = vy, z = vz })
        c = (ok and type(cid) == "number" and cid >= 0) and cid or false
        chunk_cache[key] = c
    end
    return c or nil
end

local function cell_loaded(level, bp)
    local v = std.bp_to_parent_vcp(bp)
    return chunk_at(level, v.x, v.y, v.z) ~= nil
end

-- bp -> anchor that survives the grid shifting (nil if nothing is loaded)
function C.anchor_make(level, bp)
    local v = std.bp_to_parent_vcp(bp)
    local cid = chunk_at(level, v.x, v.y, v.z)
    if cid == nil then
        -- the cell's own chunk isn't loaded: hang it off the viewer's chunk
        v = std.lp_to_vcp(ga_get_viewer_offset())
        cid = chunk_at(level, v.x, v.y, v.z)
        if cid == nil then return nil end
    end
    local ok, path = pcall(ga_chunk_id_to_path, cid)
    if not ok or type(path) ~= "string" then return nil end
    return { path = path, level = level,
             dx = bp.x - 16 * v.x, dy = bp.y - 16 * v.y, dz = bp.z - 16 * v.z }
end

-- anchor -> bp in today's viewer-centric coords (nil once its chunk unloads)
function C.anchor_bp(a)
    local ok, cid = pcall(ga_path_to_chunk_id, a.path)
    if not ok or type(cid) ~= "number" or cid < 0 then return nil end
    if ga_chunk_id_to_level(cid) ~= a.level then return nil end
    local v = ga_chunk_id_to_vcp(cid)
    return std.bp(16 * v.x + a.dx, 16 * v.y + a.dy, 16 * v.z + a.dz)
end

local function area_corner(mode)
    local level, bp, bp2 = C.look_target()
    if level == nil then return nil end
    if mode == "place" then return level, bp2 end
    return level, bp
end

function C.area_box(a, b)
    return math.min(a.x, b.x), math.min(a.y, b.y), math.min(a.z, b.z),
           math.max(a.x, b.x), math.max(a.y, b.y), math.max(a.z, b.z)
end

-- 3D cursor for corner 2: the block cell AREA_DEPTH ahead of the camera, NOT
-- the block the crosshair hits (that kept the box flat on surfaces and made it
-- jump to whatever far chunk the ray reached). Alt+wheel changes the depth.
S.area_depth = 4

local function clamp_depth(d)
    if d < 1 then d = 1 end
    if d > C.DIST_MAX then d = C.DIST_MAX end
    return d
end

local function cursor_cell(d)
    local eye  = ga_get_viewer_offset()
    local look = C.unit(ga_get_sys_v("game.player.camera.look"))
    return std.lp_to_bp(std.vec(eye.x + look.x * d, eye.y + look.y * d, eye.z + look.z * d))
end

-- The cursor cell, pulled back along the look ray until it is in a loaded
-- chunk of the viewer level (so it never sits out in K-chunk land).
-- Returns bp, or nil when nothing in front of you is loaded.
function C.area_cursor()
    local level = ga_get_viewer_level()
    local d = S.area_depth
    while d >= 0.5 do
        local bp = cursor_cell(d)
        if cell_loaded(level, bp) then return bp end
        d = d - 0.5
    end
    return nil
end

-- Alt+wheel on the area cursor; won't push it past the loaded chunks (that
-- range would do nothing visible and you'd have to scroll all the way back)
function C.area_depth_step(step)
    local d = clamp_depth(S.area_depth + step)
    if step > 0 then
        C.chunk_cache_reset()
        if not cell_loaded(ga_get_viewer_level(), cursor_cell(d)) then return end
    end
    S.area_depth = d
end

-- Loaded-chunk test for a whole box: "all", "some" or "none".
function C.box_loaded(level, x0, y0, z0, x1, y1, z1)
    local any, all = false, true
    for vx = math.floor(x0 / 16), math.floor(x1 / 16) do
        for vy = math.floor(y0 / 16), math.floor(y1 / 16) do
            for vz = math.floor(z0 / 16), math.floor(z1 / 16) do
                if chunk_at(level, vx, vy, vz) ~= nil then any = true else all = false end
            end
        end
    end
    if all then return "all" end
    return any and "some" or "none"
end

-- corner 1 in today's coords; drops the selection if its chunk went away
function C.area_a()
    if S.area == nil then return nil end
    local a = C.anchor_bp(S.area.anchor)
    if a == nil then
        ga_hud_msg("Area: corner 1 is no longer loaded, selection dropped", 2.0)
        C.area_cancel()
    end
    return a
end

function C.area_click(mode, block_name)
    C.chunk_cache_reset()
    local vlevel = ga_get_viewer_level()
    if S.area == nil then
        -- corner 1: L = cell a normal L-click places into, R = block a normal
        -- R-click breaks; nothing aimed (or a K/M-chunk) = the 3D cursor
        local level, c = area_corner(mode)
        if level == nil or level ~= vlevel or not cell_loaded(vlevel, c) then
            level, c = vlevel, C.area_cursor()
            if c == nil then
                ga_hud_msg("Area: nothing loaded in front of you", 1.5)
                return
            end
        else
            -- start the 3D cursor right on corner 1
            local center = std.vec(c.x + 0.5, c.y + 0.5, c.z + 0.5)
            S.area_depth = clamp_depth(math.floor(C.dist3(center, ga_get_viewer_offset()) + 0.5))
        end
        local anchor = C.anchor_make(level, c)
        if anchor == nil then
            ga_hud_msg("Area: nothing loaded here", 1.5)
            return
        end
        S.area = { level = level, anchor = anchor, mode = mode }
        return
    end
    if vlevel ~= S.area.level then
        ga_hud_msg("Area: you changed level, selection dropped", 2.0)
        C.area_cancel()
        return
    end
    local a = C.area_a()
    if a == nil then return end
    local level, c = S.area.level, C.area_cursor()
    if c == nil then
        ga_hud_msg("Area: nothing loaded in front of you", 1.5)
        return
    end
    local x0, y0, z0, x1, y1, z1 = C.area_box(a, c)
    local n = (x1 - x0 + 1) * (y1 - y0 + 1) * (z1 - z0 + 1)
    if n > C.AREA_CAP then
        -- keep corner 1 so another corner 2 can be picked
        ga_hud_msg("Area too big: " .. n .. " blocks (max " .. C.AREA_CAP .. ")", 2.5)
        return
    end
    -- never touch cells of chunks that aren't loaded (K/M-chunk land)
    local cells, skipped = {}, 0
    for x = x0, x1 do
        for y = y0, y1 do
            for z = z0, z1 do
                local bp = std.bp(x, y, z)
                if cell_loaded(level, bp) then cells[#cells + 1] = bp else skipped = skipped + 1 end
            end
        end
    end
    local name = (mode == "place") and block_name or C.AIR
    local changed = apply_cells(level, cells, name)
    local msg = (mode == "place" and "Filled " or "Deleted ") .. changed .. " block(s)  (Backspace = undo)"
    if skipped > 0 then msg = msg .. "  - " .. skipped .. " outside the loaded area skipped" end
    ga_hud_msg(msg, 2.5)
    C.area_cancel()
end
