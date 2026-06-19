p.id = "debug_wiki"
p.help = "Builds a 3D museum of block types (auto-enumerated, crashers excluded). "
      .. "Usage: debug_wiki [start] [count] [filter]"

local function build_block_list()
    local arr = ga_get_block_names_with_prefix("XAR_")
    local names = {}
    if arr then
        for _, v in ipairs(arr) do
            local nm = v
            if type(v) == "table" then nm = v.name end
            if type(nm) == "string" then
                local excluded = block_wiki_bad_blocks and block_wiki_bad_blocks[nm]
                if not excluded then names[#names + 1] = nm end
            end
        end
    end
    table.sort(names)
    return names
end

function p.get_help_str()
    return p.help
end

local co = nil
function p.__update_discrete_post()
    if co then
        local out = coroutine.resume(co)
        ga_console_print(tostring(out))
        if not out then co = nil end
    end
end

function p.__load_game()
    game_command_system.add_command(p.id, p.handler)
    game_command_system.add_help(p.id, p.get_help_str())
    game_command_system.add_command("debug_wikit2", function(str)
        local hot = str:sub(1,3) == "hot"
        co = coroutine.create(function()
            local function wait(ticks) for _=1,ticks do coroutine.yield() end end
            local main = "eee_777_777_777_777_777_777"
            local delay = 1
            game_msg.add("Blocks per second: " .. tostring(25/(delay*2)))
            ga_tele(main, std.vec(2,2,2))
            wait(1)
            local blocks = build_block_list()
            local level = ga_get_viewer_level()
            local idx = 1
            if hot then
                local max = nil 
                for v in pairs(block_wiki_bad_blocks) do
                    max = max or v
                    if v > max then max = v end
                end
                for i = 1,#blocks do
                    if blocks[i] > max then idx = i break end
                end
                if str:sub(4,4) == " " and tonumber(str:sub(5)) then idx = idx + tonumber(str:sub(5)) end
                game_msg.add("Starting at idx " .. idx)
                for i = idx,math.min(idx+10,#blocks) do ga_print(blocks[i]) end
            end
            for i = idx,#blocks do
                local bt = blocks[i]
                ga_print("!!!!!!!!!!!!!!!!!!!! About to place block: " .. bt .. " idx " .. i)
                --assert(not(blocks[i-1]) or (blocks[i-1] == ga_bp_to_bt(level,std.vec(7,7,7))), (tostring(blocks[i-1]) .. " " .. tostring(ga_bp_to_bt(level,std.vec(7,7,7)))))
                local pos = 7--0 + (i//20)%10
                ga_block_change_rl(level,std.vec(7,7,pos),bt,2.0+i*0.01)
                ga_hud_msg(bt, 0.5)
                wait(delay)
                ga_tele(main .. "_77" .. pos, std.vec(2,2,2))
                wait(delay)
                --main = main:sub(1,-2) .. (i//200)
                ga_tele(main, std.vec(2,2,2))
                -- should be able to get away with this.
                --wait(delay)
            end
        end)
        ga_console_print("Exit console to being testing")
        ga_console_print("Please enable god also")
    end)
    game_command_system.add_help("debug_wikit2", "Test all blocktypes not marked as bad progressively.\nHot parameter means we start from the last listed bad block\nUsage: debug_wikit2 [hot]")
end

function p.handler(str)
    local level = ga_get_viewer_level()
    local bp_origin = ga_get_viewer_bp(level)
    local ox, oy, oz = bp_origin.x, bp_origin.y, bp_origin.z

    local args = {}
    for word in string.gmatch(str, "%S+") do table.insert(args, word) end

    local start_idx  = tonumber(args[1]) or 1
    local batch_size = tonumber(args[2]) or 1000
    local filter_str = args[3]

    local blocks = build_block_list()
    local total_blocks = #blocks
    if total_blocks == 0 then
        ga_console_print("DEBUG: ERROR - no blocks enumerated. "
            .. "ga_get_block_names_with_prefix returned nothing.")
        return false
    end

    if filter_str then
        ga_console_print("DEBUG: Searching for MAX " .. batch_size .. " blocks matching '"
            .. filter_str .. "' starting at " .. start_idx .. " (of " .. total_blocks .. ")")
    else
        ga_console_print("DEBUG: placing " .. batch_size .. " blocks starting at "
            .. start_idx .. " (of " .. total_blocks .. ")")
    end

    local side = 32
    local spacing = tonumber(args[4]) or 2

    local current_idx = start_idx
    local matches_found = 0

    while matches_found < batch_size and current_idx <= total_blocks do
        local name = blocks[current_idx]
        if name then
            local is_match = true
            if filter_str then
                if not string.find(string.upper(name), string.upper(filter_str)) then
                    is_match = false
                end
            end

            if is_match then
                local idx = matches_found
                local layer_size = side * side

                local yi = math.floor(idx / layer_size)
                local layer_idx = idx % layer_size

                local xi = layer_idx % side
                local zi = math.floor(layer_idx / side)

                local tx = ox + (xi * spacing)
                local ty = oy + (yi * spacing)
                local tz = oz + (zi * spacing)

                local bp = std.bp(tx, ty, tz)

                if matches_found % 10 == 0 then
                    ga_console_print("Placing ["..current_idx.."]: " .. name)
                end

                local _h = ga_open_file_for_writing("debug_wiki_progress.txt")
                if _h then ga_write(_h, "idx=" .. current_idx .. " name=" .. name .. "\n"); ga_close_file(_h) end

                local status, err = pcall(ga_block_change_perm, level, bp, name)
                if not status then
                    ga_console_print("  -> FAILED: " .. tostring(err))
                end

                matches_found = matches_found + 1
            end
        end
        current_idx = current_idx + 1
    end

    ga_console_print("Batch Complete. Placed " .. matches_found .. " blocks. Scanned up to " .. (current_idx - 1))
    if current_idx <= total_blocks then
        if filter_str then
             ga_console_print("Next command: debug_wiki " .. current_idx .. " " .. batch_size .. " " .. filter_str)
        else
             ga_console_print("Next command: debug_wiki " .. current_idx .. " " .. batch_size)
        end
    else
        ga_console_print("End of block list reached.")
    end
    return false
end