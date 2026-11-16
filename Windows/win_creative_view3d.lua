-- Creative menu: the turntable camera of the 3D previews (WORLDGEN chunk,
-- SCHEMS schematic). Drag on the preview = turn it, after a while it spins by
-- itself, the axis gizmo turns it to look from one side.
-- One camera table per preview (C.cam_new). See win_creative_core.lua for how
-- the files share things.
creative_ui = creative_ui or {}          -- shared by all win_creative*.lua files (one window Lua state)
creative_ui.state = creative_ui.state or {}
local C, S = creative_ui, creative_ui.state

function C.cam_new()
    return { yaw = 0, pitch = 0, timer = -100, goal_yaw = 0, goal_pitch = 0,
             goal_moving = false, dragging = false, last = nil }
end

-- Once per frame. can_start(cursor) = may a drag start there (the preview
-- area, not a button / tile / the gizmo).
function C.cam_input(wid, cam, can_start)
    local cursor = ga_win_get_cursor_pos(wid)
    cam.last = cam.last or cursor
    if not ga_win_mouse_down(true) then
        cam.dragging = false
    elseif ga_win_mouse_pressed(wid, true) and not S.help_open and can_start(cursor) then
        cam.dragging = true
    end
    if cam.dragging then
        cam.timer = -100
        cam.yaw = cam.yaw + (cursor.x - cam.last.x) * 720
        cam.pitch = cam.pitch + (cursor.y - cam.last.y) * 360
        if cam.pitch > 90 then cam.pitch = 90 end
        if cam.pitch < -90 then cam.pitch = -90 end
        cam.goal_moving = false
    end
    cam.timer = cam.timer + 1
    if cam.timer > 0 and not cam.goal_moving then
        cam.yaw = cam.yaw - ga_get_sys_f("time.elapsed") * 30
    end
    if cam.goal_moving then
        cam.yaw = cam.yaw + ((cam.goal_yaw - cam.yaw + 180) % 360 - 180) * 0.2
        cam.pitch = cam.pitch + (cam.goal_pitch - cam.pitch) * 0.2
    end
    cam.last = cursor
end

-- The matrix for a box of sx x sy x sz blocks (corner at 0,0,0), with the
-- current matrix at the preview's centre: the biggest side becomes 0.48 high
-- (WORLDGEN: 16 blocks = 0.03 each), turned, the box centred.
-- Box (x,y,z) is drawn like the gizmo's own space (-y, x, z) (see C.cam_gizmo).
function C.cam_apply(cam, sx, sy, sz)
    local k = 0.48 / math.max(sx, sy, sz, 1)
    ga_render_matrix_scaled(k, k, k)
    ga_render_matrix_scaled(1 / S.aspect, 1, 1)
    ga_render_matrix_rotated(90, std.vec(0, 1, 0))
    ga_render_matrix_rotated(-90, std.vec(1, 0, 0))
    ga_render_matrix_rotated(cam.pitch, std.vec(0, 1, 0))
    ga_render_matrix_rotated(cam.yaw, std.vec(0, 0, 1))
    ga_render_matrix_translated(-sx / 2, -sy / 2, -sz / 2)
end

-- Axis gizmo centred at (x, y), screen coords. Labels are in BOX coordinates
-- (set_pos x,y,z for WORLDGEN, the schematic's x,y,z for SCHEMS): the camera
-- draws box (x,y,z) like the gizmo's space (-y, x, z), so box +X points where
-- gizmo +Y does and box +Y where gizmo -X does. Clicking a label turns the
-- camera to look from that side. Returns the clicked label ("X+", "+-+", ...)
-- or nil.
function C.cam_gizmo(wid, cam, x, y)
    local width = 0.05
    local aspect = S.aspect

    local yaw_rad = math.rad(cam.yaw)
    local pitch_rad = math.rad(math.min(math.max(-89.999, cam.pitch), 89.999))

    local look = std.vec(math.sin(yaw_rad) * math.cos(pitch_rad), math.cos(yaw_rad) * math.cos(pitch_rad), math.sin(pitch_rad))
    local left = std.normalize(std.cross(std.vec(0, 0, 1), look))
    local up = std.cross(look, left)
    local function project(vec)
        return std.dot(vec, std.vec_scale(left, -1)), std.dot(vec, up), std.dot(vec, look)
    end
    -- { label, screen dx, dy, depth, gizmo-space dir x, y, z }
    local things = {}
    local function add(label, cx, cy, cz)
        local gx, gy, gz = -cy, cx, cz          -- box dir -> gizmo dir
        local dx, dy, depth = project(std.vec(gx, gy, gz))
        things[#things + 1] = { label, dx, dy, depth, gx, gy, gz }
        return dx, dy
    end
    ga_win_set_back_params(wid, std.vec(0, 0, 0), 1, 1)
    local axis_name = { "X", "Y", "Z" }
    local axis_col  = { std.vec(1, 0, 0), std.vec(0, 1, 0), std.vec(0, 0, 1) }
    for a = 1, 3 do
        local d = { 0, 0, 0 }
        d[a] = 1
        local px, py = add(axis_name[a] .. "+", d[1], d[2], d[3])
        local nx, ny = add(axis_name[a] .. "-", -d[1], -d[2], -d[3])
        ga_win_line(wid, x + nx * width / aspect, y + ny * width, x + px * width / aspect, y + py * width, axis_col[a])
    end
    local c = { [0] = "-", "+" }
    for b = 0, 7 do
        local sx, sy, sz = (b >> 2) & 1, (b >> 1) & 1, b & 1
        add(c[sx] .. c[sy] .. c[sz], sx * 2 - 1, sy * 2 - 1, sz * 2 - 1)
    end
    table.sort(things, function(a, b) return a[4] > b[4] end)   -- far ones first
    local potential = nil
    local cur = ga_win_get_cursor_pos(wid)
    local pressed = ga_win_mouse_pressed(wid, true) and not S.help_open
    for i = 1, #things do
        local v = things[i]
        local s = 0.02 / (v[4] + 5)
        ga_win_set_char_size(wid, s, s * 2)
        local X, Y = x + v[2] * width / aspect, y + v[3] * width
        local w = s * #v[1] * 0.5
        ga_win_txt_alpha_bg(wid, X - w, Y - s, 1, v[1])
        if pressed and cur.x >= X - w and cur.x <= X + w and cur.y >= Y - s and cur.y <= Y + s then
            if potential == nil or things[potential][4] > v[4] then potential = i end
        end
    end
    if potential == nil then return nil end
    local v = things[potential]
    cam.goal_yaw = -math.deg(math.atan2(v[5], -v[6]))
    cam.goal_pitch = math.deg(math.asin(-std.normalize(std.vec(v[5], v[6], v[7])).z))
    cam.goal_moving = true
    return v[1]
end

-- is the cursor on the gizmo at (x, y) (so a click there doesn't start a drag)
function C.cam_on_gizmo(cursor, x, y)
    local dx, dy = (cursor.x - x) * S.aspect, cursor.y - y
    return dx * dx + dy * dy < 0.075 * 0.075
end

-- not a real window: only here so the window Lua state loads it
function p.__start(wid) end
function p.__end(wid) end
function p.__on_start(wid) end
function p.__on_end(wid) end
function p.__render(wid) end
function p.__process_input(wid) end
