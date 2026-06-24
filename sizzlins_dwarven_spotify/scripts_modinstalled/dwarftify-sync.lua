-- Synchronizes custom .ogg files into the Dwarftify music player.
--[====[

dwarftify-sync
==============
Scans the `dfhack-config/dwarftify/custom_music/` directory for `.ogg` files and dynamically
injects them into the game's in-memory music structures. 

It also generates a local Dwarf Fortress mod (`Dwarftify Custom Music`) containing the 
raw text files required for the engine to natively parse your custom audio tracks upon 
the creation of a new world.

]====]
local CUSTOM_MUSIC_DIR = 'dfhack-config/dwarftify/custom_music'
dfhack.filesystem.mkdir_recursive(CUSTOM_MUSIC_DIR)

local files = dfhack.filesystem.listdir_recursive(CUSTOM_MUSIC_DIR, 0)
if not files or #files == 0 then return end

local df_path = dfhack.getDFPath()
local mod_dir = df_path .. '/mods/dwarftify'
local sound_dir = mod_dir .. '/sound'
local raw_dir = mod_dir .. '/objects'

-- Validate that a file is a real OGG (check magic bytes: "OggS")
local function is_valid_ogg(path)
    local f = io.open(path, 'rb')
    if not f then return false end
    local header = f:read(4)
    local size = f:seek('end')
    f:close()
    
    -- Limit to ~15MB to prevent memory leak crashes in the DF engine
    if size > 15728640 then
        dfhack.printerr('Dwarftify: Skipping file (exceeds 15MB limit): ' .. path)
        return false
    end
    
    return header == 'OggS' and size > 1000
end

-- Create mod directory structure
dfhack.filesystem.mkdir_recursive(mod_dir)
dfhack.filesystem.mkdir_recursive(sound_dir)
dfhack.filesystem.mkdir_recursive(raw_dir)

local info = io.open(mod_dir .. '/info.txt', 'w')
if info then
    info:write('[ID:dwarftify]\n[NUMERIC_VERSION:1]\n[DISPLAYED_VERSION:1.0]\n[EARLIEST_COMPATIBLE_NUMERIC_VERSION:1]\n[EARLIEST_COMPATIBLE_DISPLAYED_VERSION:1.0]\n[AUTHOR:Dwarftify]\n[NAME:Dwarftify Custom Music]\n[DESCRIPTION:Custom music tracks synced by Dwarftify.]\n')
    info:close()
end

local mall = df.global.world.raws.music.all
local existing = {}
for i = 0, #mall - 1 do
    existing[mall[i].token] = true
end

local cid = -100
local synced = 0
local skipped = 0
local raw_entries = {}

-- Clear old sounds to prevent buildup
for _, f in ipairs(dfhack.filesystem.listdir_recursive(sound_dir, 0) or {}) do
    if not f.isdir then os.remove(f.path) end
end

for _, entry in ipairs(files) do
    if not entry.isdir and entry.path then
        local filename = entry.path:match('([^/\\]+)$') or entry.path
        if filename:lower():match('%.ogg$') then
            -- Validate the ogg file before processing
            if not is_valid_ogg(entry.path) then
                dfhack.printerr('Dwarftify: Skipping invalid ogg: ' .. filename .. ' (not a valid OGG file)')
                skipped = skipped + 1
            else
                local base_name = filename:match('^(.+)%.ogg$') or filename
                -- Truncate base_name heavily (10 chars) to prevent DF raw parser buffer overflow
                local safe_name = base_name:lower():gsub('[^%w_]', '_')
                if #safe_name > 10 then safe_name = safe_name:sub(1, 10) end
                
                -- Hash based on the full name to ensure uniqueness despite truncation
                local hash = 0
                for i = 1, #base_name do hash = (hash * 31 + string.byte(base_name, i)) % 10000 end
                
                local track_id = 'DWARFTIFY_' .. safe_name:upper() .. '_' .. string.format('%04d', hash)
                local dest_file_name = safe_name:lower() .. '_' .. string.format('%04d', hash) .. '.ogg'

                -- Copy file to mod sound directory
                local src = io.open(entry.path, 'rb')
                if src then
                    local dst = io.open(sound_dir .. '/' .. dest_file_name, 'wb')
                    if dst then
                        dst:write(src:read('*a'))
                        dst:close()
                    end
                    src:close()
                end

                -- Inject into raws if not already present
                if not existing[track_id] then
                    local m = df.musicst:new()
                    m.token = track_id
                    m.song = cid
                    m.index = #mall
                    mall:insert('#', m)
                    existing[track_id] = true
                    cid = cid - 1
                    synced = synced + 1
                end

                -- Format title from the base_name for metadata
                local nice_title = base_name:gsub('_', ' '):gsub('(%w)(%w*)', function(a, b) return a:upper() .. b:lower() end)
                if #nice_title > 50 then nice_title = nice_title:sub(1, 47) .. '...' end

                table.insert(raw_entries, {
                    track_id = track_id, 
                    filename = dest_file_name,
                    title = nice_title
                })
            end
        end
    end
end

-- Generate MUSIC_FILE mapping for the sound directory
if #raw_entries > 0 then
    local mapping_path = sound_dir .. '/music_file_dwarftify.txt'
    local mf = io.open(mapping_path, 'w')
    if mf then
        mf:write('music_file_dwarftify\n\n')
        mf:write('[OBJECT:MUSIC_FILE]\n\n')
        for _, e in ipairs(raw_entries) do
            mf:write('[MUSIC_FILE:' .. e.track_id .. ']\n')
            mf:write('    [FILE:' .. e.filename .. ']\n')
            mf:write('    [TITLE:' .. e.title .. ']\n')
            mf:write('    [AUTHOR:Custom Music]\n\n')
        end
        mf:close()
    end
end

-- Generate RAW file for future worlds
if #raw_entries > 0 then
    local raw_path = raw_dir .. '/music_dwarftify_custom.txt'
    local f = io.open(raw_path, 'w')
    if f then
        f:write('music_dwarftify_custom\n')
        f:write('\n')
        f:write('[OBJECT:MUSIC]\n')
        f:write('\n')
        for _, e in ipairs(raw_entries) do
            f:write('[MUSIC:' .. e.track_id .. ']\n')
            f:write('\t[FILE:' .. e.track_id .. ']\n')
            f:write('\t[CONTEXT:ANY]\n')
            f:write('\n')
        end
        f:close()
    end
end
