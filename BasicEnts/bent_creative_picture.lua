--A picture placed with the Creative Menu (DECOR tab).
--
--It is a basic ent instead of xar's ment_picture_* moving ents: those are
--world-gen props, and when their chunk unloads the engine only saves its own
--bookkeeping vars (no texture, size, facing or ttl override), so they came
--back as plain ment_picture_* with the type's 1 hour ttl and expired at once.
--A basic ent is saved exactly: its block, plus one string param:
--
--    "tex|w|h|fx|fy|ox|oy|oz"
--    tex    = picture_* texture
--    w, h   = size in blocks
--    fx, fy = horizontal direction you look INTO the picture
--    ox..oz = picture centre relative to this block's centre
--
--The engine draws a basic ent with the matrix at its block centre, 1 unit =
--1 block, then calls __on_render(level, bp).
--
--NOTE: user packages only load basic ents from cached_lua_scripts.dat in
--this folder; after editing this file, update its copy in there too.

local PIC_MESH  = "creative_picture"   --Meshes/creative_picture.obj (unit box)
local THICKNESS = 0.06

local parsed = {}   --param string -> table, or false when it can't be read

function p.decode(s)
    if type(s) ~= "string" or s == "" then return nil end
    local d = parsed[s]
    if d ~= nil then return d or nil end
    local f = {}
    for part in string.gmatch(s, "[^|]+") do f[#f + 1] = part end
    d = false
    if #f >= 8 then
        local n = {}
        for i = 2, 8 do n[i] = tonumber(f[i]) end
        if n[2] and n[3] and n[4] and n[5] and n[6] and n[7] and n[8] then
            d = { tex = f[1], w = n[2], h = n[3], fx = n[4], fy = n[5],
                  ox = n[6], oy = n[7], oz = n[8] }
        end
    end
    parsed[s] = d
    return d or nil
end

function p.__get_mesh() return "" end
function p.__get_touch_dist() return 0.0 end
function p.__get_can_use(level, bp) return false end

function p.__on_render(level, bp)
    --like xar's pictures: only drawn on your own level
    if level ~= ga_get_viewer_level() then return end
    local d = p.decode(ga_bent_get_param_s(level, bp))
    if d == nil then return end
    ga_render_matrix_translated(d.ox, d.oy, d.oz)
    --mesh X = picture width, Y = depth (looking into it), Z = up
    ga_render_matrix_frame(std.vec(d.fy, -d.fx, 0.0), std.vec(d.fx, d.fy, 0.0), std.vec(0.0, 0.0, 1.0))
    ga_render_matrix_scaled(d.w, THICKNESS, d.h)
    ga_render_mesh_with_tex_no_lighting(PIC_MESH, d.tex)
end
