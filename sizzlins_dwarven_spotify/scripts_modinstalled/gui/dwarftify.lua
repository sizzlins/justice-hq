-- In-game music player with queue, likes, and browsing.
--[====[
gui/dwarftify
=============

Tags: fort | interface | music

A full-featured in-game music player for Dwarf Fortress. Browse
the game's soundtrack by artist, manage a play queue, and mark
your favorite tracks. Playback is controlled by directly setting
the game engine's active music track.

Usage
-----

    gui/dwarftify

Opens the Dwarftify music player interface.

Keybindings
-----------

T
    Cycle between Browse, Queue, and Liked tabs.
1 / 2 / 3
    Jump directly to Browse / Queue / Liked tab.
Shift+Z
    Play previous track in queue.
Shift+X
    Play next track in queue.
L
    Toggle like on the track under the mouse cursor.
S
    Toggle shuffle mode.
R
    Cycle repeat mode (off / all / track).
Enter (left-click)
    Play the highlighted track immediately.
Shift+Enter (right-click in Browse/Liked)
    Add the highlighted track to the end of the queue.
Right-click (in Queue tab)
    Remove the track from the queue.
]====]

--@ module=true
--@ enable=true

local gui = require('gui')
local widgets = require('gui.widgets')
local json = require('json')
local overlay = require('plugins.overlay')
local utils = require('utils')

local CONFIG_FILE = 'dfhack-config/dwarftify.json'
local CUSTOM_MUSIC_DIR = 'dfhack-config/dwarftify/custom_music'

-- Persistence State
local STATE = {
    liked_songs = {}, -- map of id -> true
    queue = {},       -- list of track objects
    active_tab = 1,
    search_string = "",
    repeat_mode = "off", -- off, track, all
    shuffle = false,
    settings = { show_toast = true }
}

local function loadConfig()
    if dfhack.filesystem.isfile(CONFIG_FILE) then
        pcall(function()
            local data = json.decode_file(CONFIG_FILE)
            if data then
                STATE.liked_songs = data.liked_songs or {}
                STATE.queue = data.queue or {}
                STATE.active_tab = data.active_tab or 1
                STATE.search_string = data.search_string or ""
                STATE.repeat_mode = data.repeat_mode or "off"
                STATE.shuffle = data.shuffle or false
                if data.settings then STATE.settings = data.settings end
            end
        end)
    end
end

local function saveConfig()
    local ok, err = pcall(function()
        json.encode_file(STATE, CONFIG_FILE)
    end)
    if not ok then
        print("Dwarftify Save Error: " .. tostring(err))
    end
end

-- ===========================
-- Data Harvesting
-- ===========================
local function formatVanillaName(str)
    str = str:gsub('^TRACK_', ''):gsub('^ADV_OST_', '')
    return 'Track ' .. str
end



local function harvestMusic()
    local library = {}
    local authors = {}

    local raws_by_id = {}
    if df.global.world and df.global.world.raws and df.global.world.raws.music then
        local mall = df.global.world.raws.music.all
        for i = 0, #mall - 1 do
            local raw = mall[i]
            if raw then
                local is_custom = raw.token:find('^DWARFTIFY_')
                local title = is_custom and raw.token:gsub('^DWARFTIFY_', ''):gsub('_%d+$', ''):gsub('_', ' '):gsub('(%w)(%w*)', function(a, b) return a:upper() .. b:lower() end) or formatVanillaName(raw.token)
                
                raws_by_id[raw.song] = {
                    id = raw.song,
                    title = title,
                    author = is_custom and 'Custom Music' or 'Dwarf Fortress',
                    orig_id = raw.token
                }
            end
        end
    end

    local m = df.global.musicsound
    if m and m.loaded_music then
        for i = 0, #m.loaded_music - 1 do
            pcall(function()
                local song = m.loaded_music[i]
                local s_id = song.id
                local title = song.title and #song.title > 0 and song.title or nil
                local author = song.author and #song.author > 0 and song.author or 'Unknown Artist'
                
                if raws_by_id[s_id] then
                    if title then raws_by_id[s_id].title = title end
                    if raws_by_id[s_id].author == 'Dwarf Fortress' then
                        raws_by_id[s_id].author = author
                    end
                else
                    raws_by_id[s_id] = {
                        id = s_id,
                        title = title or ('Track #' .. s_id),
                        author = author,
                        orig_id = 'Loaded Track #' .. s_id
                    }
                end
                
                if title then
                    for _, raw_track in pairs(raws_by_id) do
                        if raw_track.id < 120 and raw_track.title:upper() == title:upper() then
                            if raw_track.author == 'Dwarf Fortress' then
                                raw_track.author = author
                            end
                        end
                    end
                end
            end)
        end
    end

    for _, track in pairs(raws_by_id) do
        table.insert(library, track)
        authors[track.author] = authors[track.author] or {}
        table.insert(authors[track.author], track)
    end
    
    if not authors['Custom Music'] then
        local steps = {
            {id = -7, title = "-- How to add custom music --", author = "Custom Music", orig_id = "TUTORIAL"},
            {id = -6, title = "1. Drop .ogg files into:", author = "Custom Music", orig_id = "TUTORIAL"},
            {id = -5, title = "   dfhack-config/dwarftify/custom_music/", author = "Custom Music", orig_id = "TUTORIAL"},
            {id = -4, title = "2. Press [Shift+S] here to sync the local mod", author = "Custom Music", orig_id = "TUTORIAL"},
            {id = -3, title = "3. Restart Dwarf Fortress & Start New World", author = "Custom Music", orig_id = "TUTORIAL"},
            {id = -2, title = "4. Enable 'Dwarftify Custom Music' in mod list", author = "Custom Music", orig_id = "TUTORIAL"},
        }
        authors['Custom Music'] = steps
        for _, s in ipairs(steps) do
            table.insert(library, s)
        end
    end

    table.sort(library, function(a, b) return a.id < b.id end)
    for _, tracks in pairs(authors) do
        table.sort(tracks, function(a, b) return a.id < b.id end)
    end

    local sorted_authors = {}
    for author, tracks in pairs(authors) do
        table.insert(sorted_authors, {
            text = author .. ' (' .. #tracks .. ')',
            name = author,
            tracks = tracks,
            count = #tracks
        })
    end
    table.sort(sorted_authors, function(a, b)
        if a.name == 'Dwarf Fortress' then return false end
        if b.name == 'Dwarf Fortress' then return true end
        if a.name == 'Custom Music' then return true end -- Keep custom music at the bottom
        if b.name == 'Custom Music' then return false end
        return a.name < b.name
    end)

    return library, sorted_authors
end

-- ===========================
-- Overlays & Toast
-- ===========================
DwarftifyLauncherOverlay = defclass(DwarftifyLauncherOverlay, overlay.OverlayWidget)
DwarftifyLauncherOverlay.ATTRS{
    desc = 'Adds a Dwarftify music player launcher button to the main game screen.',
    default_pos = {x = -27, y = 17},
    default_enabled = true,
    viewscreens = 'dwarfmode',
    frame = {w = 3, h = 3},
}

function DwarftifyLauncherOverlay:init()
    self:addviews{
        widgets.Panel{
            frame = {t = 0, l = 0, w = 3, h = 3},
            frame_style = gui.MEDIUM_FRAME,
            frame_background = gui.CLEAR_PEN,
            subviews = {
                widgets.Label{
                    frame = {t = 0, l = 0},
                    text = {
                        {text = string.char(14), pen = dfhack.pen.parse{fg = COLOR_LIGHTGREEN, bg = COLOR_BLACK}},
                    },
                    on_click = function() dfhack.run_script('gui/dwarftify') end,
                },
            },
        },
    }
end

DwarftifyToastOverlay = defclass(DwarftifyToastOverlay, overlay.OverlayWidget)
DwarftifyToastOverlay.ATTRS{
    desc = 'Shows a brief notification when a new track starts playing.',
    default_pos = {x = -137, y = 6},
    default_enabled = true,
    viewscreens = 'dwarfmode',
    frame = {w = 40, h = 1},
}

TOAST_TEXT = TOAST_TEXT or ''
TOAST_EXPIRE = TOAST_EXPIRE or 0

function showToast(text, duration_ms)
    TOAST_TEXT = text
    TOAST_EXPIRE = dfhack.getTickCount() + (duration_ms or 4000)
end

function DwarftifyToastOverlay:init()
    self:addviews{
        widgets.Label{
            view_id = 'toast_label',
            frame = {t = 0, l = 0},
            text = '',
        },
    }
end

function DwarftifyToastOverlay:onRenderBody(dc)
    local label = self.subviews.toast_label
    if not label then return end
    if STATE.settings and STATE.settings.show_toast == false then
        label:setText('')
        return
    end
    if TOAST_TEXT ~= '' and dfhack.getTickCount() < TOAST_EXPIRE then
        label:setText({{text = TOAST_TEXT, pen = dfhack.pen.parse{fg = COLOR_LIGHTGREEN, bg = COLOR_BLACK}}})
    else
        label:setText('')
        TOAST_TEXT = ''
    end
end

OVERLAY_WIDGETS = {
    launcher = DwarftifyLauncherOverlay,
    toast = DwarftifyToastOverlay,
}

-- ===========================
-- Playback & Queue Management
-- ===========================
local monitor_running = false
local dj_last_song = nil
local dj_we_set_id = nil
local dj_last_change_tick = 0
local dj_ignore_next_transition = false
local last_submit_tick = 0

local function setGameTrack(id)
    if id < 0 then return end
    local m = df.global.musicsound
    if m then
        dj_we_set_id = id
        dj_last_change_tick = dfhack.getTickCount()
        dj_ignore_next_transition = true
        
        m.neutral_card_queue:resize(0)
        m.planned_cards:resize(0)
        m.queued_song = id
        m.queued_song_count = 1
        m.planned_song = id
        
        -- Tell the engine to instantly kill whatever is currently playing (songs or interlude cards).
        -- This natively triggers FMOD's hardcoded 3-second fade-out.
        m.next_play_duration = 0
        
        -- We must wait for FMOD to finish its 3-second fade-out.
        -- If we try to force a track instantly during the fade, FMOD will crash,
        -- return 0 length, and cause the engine to instantly kill our new track (causing infinite queue popping).
        -- We use 'frames' so the 3 seconds tick down even if the user leaves the UI paused.
        dfhack.timeout(150, 'frames', function()
            if dj_we_set_id ~= id then return end -- Abort if the user clicked another track during the wait
            
            m.queued_song = id
            m.planned_song = id
            m.queued_song_count = 1
            m.next_play_duration = 1
            
            -- Do not use fade flags. This allows the engine to freeze the duration at 1 natively
            -- until the FMOD audio file finishes playing, preserving flawless native auto-advance.
            m.flags.fade_card_out = false
            m.flags.fade_song_out = false
            
            dj_we_set_id = nil
        end)
    end
end

function playTrackNow(track)
    if not track then return end
    if track.id < 0 then
        if track.id == -1 then
            dfhack.gui.showAnnouncement('Dwarftify: DF Audio Engine rejected this track. It may not be a valid .ogg file.', COLOR_RED)
        else
            dfhack.gui.showAnnouncement('Dwarftify: Custom tracks require a new world to play.', COLOR_CYAN)
        end
        return
    end
    
    saveConfig()
    if GLOBAL_DWARFTIFY_SCREEN then GLOBAL_DWARFTIFY_SCREEN:updateFilters() end
    ensureMonitorRunning()
    setGameTrack(track.id)
    showToast(string.char(14) .. ' Playing: ' .. track.title)
end

function enqueueTrack(track)
    if not track then return end
    if track.id < 0 then
        if track.id == -1 then
            dfhack.gui.showAnnouncement('Dwarftify: DF Audio Engine rejected this track. It may not be a valid .ogg file.', COLOR_RED)
        else
            dfhack.gui.showAnnouncement('Dwarftify: Custom tracks require a new world to play.', COLOR_CYAN)
        end
        return
    end
    table.insert(STATE.queue, track)
    saveConfig()
    showToast(string.char(14) .. ' Added to Queue: ' .. track.title)
    if GLOBAL_DWARFTIFY_SCREEN then GLOBAL_DWARFTIFY_SCREEN:updateFilters() end
    ensureMonitorRunning()
end



function playNextTrack()
    if #STATE.queue == 0 then return end
    
    local now = dfhack.getTickCount()
    if now - dj_last_change_tick < 1000 then return end -- Debounce protection

    if STATE.repeat_mode == 'track' then
        local track = STATE.queue[1]
        if track then setGameTrack(track.id) end
        return
    end
    
    local finished_track = table.remove(STATE.queue, 1)
    if STATE.repeat_mode == 'all' and finished_track then
        if STATE.shuffle and #STATE.queue > 0 then
            table.insert(STATE.queue, math.random(1, #STATE.queue + 1), finished_track)
        else
            table.insert(STATE.queue, finished_track)
        end
    end
    
    if #STATE.queue > 0 then
        local next_track = STATE.queue[1]
        saveConfig()
        if GLOBAL_DWARFTIFY_SCREEN then GLOBAL_DWARFTIFY_SCREEN:updateFilters() end
        
        if next_track then
            setGameTrack(next_track.id)
            showToast(string.char(14) .. ' Playing: ' .. next_track.title)
        end
    else
        saveConfig()
    end
end

function playPrevTrack()
    if #STATE.queue == 0 then return end
    
    local now = dfhack.getTickCount()
    if now - dj_last_change_tick < 1000 then return end -- Debounce protection
    
    if #STATE.queue > 1 then
        local last_track = table.remove(STATE.queue)
        table.insert(STATE.queue, 1, last_track)
        saveConfig()
    end
    
    local track = STATE.queue[1]
    if track then
        setGameTrack(track.id)
        showToast(string.char(14) .. ' Playing: ' .. track.title)
    end
end

function toggleRepeat()
    if STATE.repeat_mode == 'off' then STATE.repeat_mode = 'all'
    elseif STATE.repeat_mode == 'all' then STATE.repeat_mode = 'track'
    else STATE.repeat_mode = 'off' end
    saveConfig()
end

function toggleShuffle()
    STATE.shuffle = not STATE.shuffle
    if STATE.shuffle and #STATE.queue > 1 then
        local first = table.remove(STATE.queue, 1)
        for i = #STATE.queue, 2, -1 do
            local j = math.random(i)
            local temp = STATE.queue[i]
            STATE.queue[i] = STATE.queue[j]
            STATE.queue[j] = temp
        end
        table.insert(STATE.queue, 1, first)
    end
    saveConfig()
end

function toggleLike(track)
    if not track then return end
    local key = track.orig_id or tostring(track.id)
    if STATE.liked_songs[key] then
        STATE.liked_songs[key] = nil
    else
        STATE.liked_songs[key] = true
    end
    saveConfig()
end

-- ===========================
-- Background DJ Monitor
-- ===========================
local DJ_COOLDOWN_MS = 3000

local function djMonitorLoop()
    if not monitor_running then return end
    if not dfhack.isWorldLoaded() then monitor_running = false; return end

    local m = df.global.musicsound
    if m and #STATE.queue > 0 then
        local current_song = m.song

        if current_song ~= dj_last_song then
            if dj_ignore_next_transition then
                dj_ignore_next_transition = false
                dj_last_song = current_song
                return
            end
            
            local now = dfhack.getTickCount()
            local elapsed = now - dj_last_change_tick

            if elapsed >= DJ_COOLDOWN_MS then
                dj_last_song = current_song
                playNextTrack()
            else
                dj_last_song = current_song
            end
        end
    end
    dfhack.timeout(1, 'frames', djMonitorLoop)
end

function ensureMonitorRunning()
    if not monitor_running then
        monitor_running = true
        dj_last_song = nil
        dj_we_set_id = nil
        dj_last_change_tick = dfhack.getTickCount()
        djMonitorLoop()
    end
end

-- ===========================
-- TUI Application
-- ===========================
Dwarftify = defclass(Dwarftify, gui.ZScreen)
Dwarftify.ATTRS = {
    focus_path = 'dwarftify',
    defocused = true,
}

GLOBAL_DWARFTIFY_SCREEN = nil

function Dwarftify:init()
    GLOBAL_DWARFTIFY_SCREEN = self
    loadConfig()
    self.library, self.authors = harvestMusic()
    
    -- Heal engine IDs (volatile) and legacy titles using stable orig_id (tokens)
    local lib_map = {}
    local lib_by_orig = {}
    for _, t in ipairs(self.library) do 
        lib_map[t.id] = t 
        if t.orig_id then lib_by_orig[t.orig_id] = t end
    end
    for _, q in ipairs(STATE.queue) do
        local lt = (q.orig_id and lib_by_orig[q.orig_id]) or lib_map[q.id]
        if lt then
            q.id = lt.id -- Update to current engine ID!
            q.title = lt.title
            q.author = lt.author
            q.orig_id = lt.orig_id
        end
    end
    saveConfig()
    
    self.selected_author_idx = 1
    
    self:addviews{
        widgets.Window{
            frame = {w = 115, h = 55},
            frame_title = string.char(14) .. ' DWARFTIFY MUSIC PLAYER',
            frame_style = gui.FRAME_INTERIOR,
            resizable = false,
            subviews = {
                -- HEADER (Search + Tabs)
                widgets.Panel{
                    frame = {t = 0, l = 0, h = 3, r = 0},
                    subviews = {
                        widgets.EditField{
                            view_id = 'search',
                            frame = {t = 0, l = 1, r = 1},
                            label_text = 'Search Tracks: ',
                            text = STATE.search_string,
                            on_change = function(text) 
                                STATE.search_string = text
                                self:updateFilters()
                            end,
                        },
                        widgets.Label{
                            frame = {t = 2, l = 1, w = 12},
                            text = '[1] Browse',
                            on_click = function() self:switchTab(1) end,
                        },
                        widgets.Label{
                            frame = {t = 2, l = 20, w = 11},
                            text = '[2] Queue',
                            on_click = function() self:switchTab(2) end,
                        },
                        widgets.Label{
                            frame = {t = 2, l = 39, w = 11},
                            text = '[3] Liked',
                            on_click = function() self:switchTab(3) end,
                        },
                    }
                },
                
                -- TAB 1: BROWSE
                widgets.Panel{
                    view_id = 'tab_1',
                    frame = {t = 4, l = 0, b = 7, r = 0},
                    visible = function() return STATE.active_tab == 1 end,
                    subviews = {
                        -- SPLIT VIEW (When NOT searching)
                        widgets.Panel{
                            frame = {t = 0, l = 0, r = 0, b = 0},
                            visible = function() return STATE.search_string == "" end,
                            subviews = {
                                -- Artists List
                                widgets.Panel{
                                    view_id = 'panel_artists',
                                    frame = {t = 0, l = 0, w = 55, b = 0},
                                    frame_style = gui.FRAME_INTERIOR,
                                    frame_title = '  Artists',
                                    subviews = {
                                        widgets.FilteredList{
                                            view_id = 'list_artists',
                                            frame = {t = 0, l = 0, r = 0, b = 0},
                                            choices = self.authors,
                                            on_select = function(idx, choice)
                                                self.selected_author_idx = idx
                                                self:updateFilters()
                                            end,
                                            on_submit = function(idx, choice)
                                                self.selected_author_idx = idx
                                                self:updateFilters()
                                                self.subviews.list_browse_tracks:setFocus(true)
                                            end,
                                        }
                                    }
                                },
                                -- Tracks List (Split)
                                widgets.Panel{
                                    view_id = 'panel_tracks_split',
                                    frame = {t = 0, l = 57, r = 0, b = 0},
                                    frame_style = gui.FRAME_INTERIOR,
                                    frame_title = '  Tracks',
                                    subviews = {
                                        widgets.FilteredList{
                                            view_id = 'list_browse_tracks',
                                            frame = {t = 0, l = 0, r = 0, b = 0},
                                            on_submit = function(idx, choice)
                                                local now = dfhack.getTickCount()
                                                if now - last_submit_tick < 500 then return end
                                                last_submit_tick = now
                                                playTrackNow(choice.track) 
                                            end,
                                            on_submit2 = function(idx, choice) enqueueTrack(choice.track) end,
                                        }
                                    }
                                }
                            }
                        },
                                -- FULL VIEW (When searching)
                                widgets.Panel{
                                    view_id = 'panel_tracks_full',
                                    frame = {t = 0, l = 0, r = 0, b = 0},
                                    frame_style = gui.FRAME_INTERIOR,
                                    frame_title = '  Global Search Results',
                                    visible = function() return STATE.search_string ~= "" end,
                                    subviews = {
                                        widgets.FilteredList{
                                            view_id = 'list_search_tracks',
                                            frame = {t = 0, l = 0, r = 0, b = 0},
                                            on_submit = function(idx, choice)
                                                local now = dfhack.getTickCount()
                                                if now - last_submit_tick < 500 then return end
                                                last_submit_tick = now
                                                playTrackNow(choice.track) 
                                            end,
                                            on_submit2 = function(idx, choice) enqueueTrack(choice.track) end,
                                        }
                                    }
                                }
                    }
                },

                -- TAB 2: QUEUE
                widgets.Panel{
                    view_id = 'tab_2',
                    frame = {t = 4, l = 0, b = 7, r = 0},
                    frame_style = gui.FRAME_INTERIOR,
                    frame_title = 'Up Next (Queue)',
                    visible = function() return STATE.active_tab == 2 end,
                    subviews = {
                        widgets.FilteredList{
                            view_id = 'list_queue',
                            frame = {t = 0, l = 0, r = 0, b = 0},
                            on_submit = function(idx, choice) 
                                local now = dfhack.getTickCount()
                                if now - last_submit_tick < 500 then return end
                                last_submit_tick = now

                                if not choice or not choice.track then return end
                                local real_idx = choice.real_idx
                                
                                if real_idx and real_idx ~= 1 then
                                    local track = table.remove(STATE.queue, real_idx)
                                    table.insert(STATE.queue, 1, track)
                                end
                                
                                local track = STATE.queue[1]
                                saveConfig()
                                self:updateFilters()
                                ensureMonitorRunning()
                                setGameTrack(track.id)
                                showToast(string.char(14) .. ' Playing: ' .. track.title)
                                self:updateFilters()
                            end,
                            on_submit2 = function(idx, choice)
                                if not choice or not choice.real_idx then return end
                                table.remove(STATE.queue, choice.real_idx)
                                saveConfig()
                                self:updateFilters()
                            end,
                        }
                    }
                },

                -- TAB 3: LIKED
                widgets.Panel{
                    view_id = 'tab_3',
                    frame = {t = 4, l = 0, b = 7, r = 0},
                    frame_style = gui.FRAME_INTERIOR,
                    frame_title = 'Liked Songs',
                    visible = function() return STATE.active_tab == 3 end,
                    subviews = {
                        widgets.FilteredList{
                            view_id = 'list_liked',
                            frame = {t = 0, l = 0, r = 0, b = 0},
                            on_submit = function(idx, choice)
                                local now = dfhack.getTickCount()
                                if now - last_submit_tick < 500 then return end
                                last_submit_tick = now
                                playTrackNow(choice.track) 
                            end,
                            on_submit2 = function(idx, choice) enqueueTrack(choice.track) end,
                        }
                    }
                },

                -- FOOTER (Transport)
                widgets.Panel{
                    frame = {b = 0, l = 0, h = 6, r = 0},
                    subviews = {
                        widgets.Label{
                            frame = {t = 0, l = 0},
                            text = {{text = string.rep('=', 113), pen = COLOR_DARKGREY}},
                        },
                        widgets.Label{
                            view_id = 'now_playing',
                            frame = {t = 1, l = 0},
                            text = "Now Playing: None (Silence)",
                        },
                        widgets.Label{
                            view_id = 'now_playing_status',
                            frame = {t = 2, l = 0},
                            text = "   Queue Empty",
                        },
                        widgets.Label{
                            frame = {t = 3, l = 0},
                            text = {{text = string.rep('=', 113), pen = COLOR_DARKGREY}},
                        },
                        widgets.Label{
                            view_id = 'footer_instructions',
                            frame = {t = 4, l = 2},
                            text = "[Enter] Play Now  |  [Shift+Enter] Add to Queue  |  [Tab] Switch View",
                            pen = COLOR_DARKGREY,
                        },
                        widgets.HotkeyLabel{
                            frame = {t = 5, l = 2, w = 16},
                            key = 'CUSTOM_L',
                            label = 'Heart (Like)',
                            on_activate = function()
                                local track = self:getTrackUnderMouse()
                                if track then
                                    toggleLike(track)
                                    self:updateFilters()
                                else
                                    local active_list = self:getActiveList()
                                    if active_list then
                                        local _, choice = active_list:getSelected()
                                        if choice and choice.track then
                                            toggleLike(choice.track)
                                            self:updateFilters()
                                        end
                                    end
                                end
                            end,
                        },
                        widgets.HotkeyLabel{
                            frame = {t = 5, l = 22, w = 14},
                            key = 'CUSTOM_SHIFT_Z',
                            label = '|< [Prev]',
                            on_activate = function() playPrevTrack() end,
                        },
                        widgets.Label{
                            frame = {t = 5, l = 38},
                            text = {{text = '[ || PAUSE ]', pen = COLOR_WHITE}},
                        },
                        widgets.HotkeyLabel{
                            frame = {t = 5, l = 53, w = 14},
                            key = 'CUSTOM_SHIFT_X',
                            label = '[Next] >|',
                            on_activate = function() playNextTrack() end,
                        },
                        widgets.HotkeyLabel{
                            frame = {t = 5, l = 70, w = 18},
                            key = 'CUSTOM_S',
                            label = function() return STATE.shuffle and 'Shuffle: ON' or 'Shuffle: OFF' end,
                            on_activate = function() toggleShuffle(); self:updateFilters() end,
                        },
                        widgets.HotkeyLabel{
                            frame = {t = 5, l = 90, w = 22},
                            key = 'CUSTOM_R',
                            label = function() return 'Repeat: ' .. STATE.repeat_mode:upper() end,
                            on_activate = function() toggleRepeat(); self:updateFilters() end,
                        },
                        widgets.HotkeyLabel{
                            view_id = 'sync_button',
                            frame = {t = 4, l = 75, w = 30},
                            key = 'CUSTOM_SHIFT_S',
                            label = 'Sync Custom Music',
                            text_pen = COLOR_LIGHTCYAN,
                            visible = false,
                            on_activate = function()
                                pcall(dfhack.run_script, 'dwarftify-sync')
                                showToast(string.char(14) .. ' Mod Generated! Restart DF to play.')
                                dfhack.gui.showAnnouncement("Dwarftify: Custom Mod Generated! Restart Dwarf Fortress to play.", COLOR_CYAN)
                                self.library, self.authors = harvestMusic()
                                self:updateFilters()
                            end,
                        },
                    },
                },
            },
        },
    }
    
    self:updateFilters()
    ensureMonitorRunning()
end

function Dwarftify:onDestroy()
    GLOBAL_DWARFTIFY_SCREEN = nil
end

function Dwarftify:switchTab(tab_idx)
    STATE.active_tab = tab_idx
    saveConfig()
    self:updateFilters()
    
    if tab_idx == 1 then
        if STATE.search_string == "" then
            self.subviews.list_artists:setFocus(true)
        else
            self.subviews.list_search_tracks:setFocus(true)
        end
    elseif tab_idx == 2 then
        self.subviews.list_queue:setFocus(true)
    elseif tab_idx == 3 then
        self.subviews.list_liked:setFocus(true)
    end
end

function Dwarftify:getActiveList()
    if STATE.active_tab == 1 then
        if STATE.search_string ~= "" then
            return self.subviews.list_search_tracks
        else
            if self.subviews.list_browse_tracks.focus then return self.subviews.list_browse_tracks end
            if self.subviews.list_artists.focus then
                local _, choice = self.subviews.list_artists:getSelected()
                if choice and choice.tracks and #choice.tracks > 0 then
                    return self.subviews.list_browse_tracks
                end
            end
            return nil
        end
    elseif STATE.active_tab == 2 then
        return self.subviews.list_queue
    elseif STATE.active_tab == 3 then
        return self.subviews.list_liked
    end
    return nil
end

function Dwarftify:updateFilters()
    if not self.subviews.panel_tracks_split then return end
    
    if self.subviews.footer_instructions then
        if STATE.active_tab == 2 then
            self.subviews.footer_instructions:setText("[Enter] Play Now  |  [Shift+Enter] Remove from Queue  |  [T] Switch View")
        else
            local author_data = self.authors[self.selected_author_idx]
            local is_custom = author_data and author_data.name == 'Custom Music'
            if is_custom and STATE.active_tab == 1 and STATE.search_string == '' then
                self.subviews.footer_instructions:setText("[Enter] Play Now  |  [Shift+Enter] Add to Queue  |  [T] Switch View")
                if self.subviews.sync_button then self.subviews.sync_button.visible = true end
            else
                self.subviews.footer_instructions:setText("[Enter] Play Now  |  [Shift+Enter] Add to Queue  |  [T] Switch View")
                if self.subviews.sync_button then self.subviews.sync_button.visible = false end
            end
        end
    end

    local queued_ids = {}
    for _, t in ipairs(STATE.queue) do
        queued_ids[t.id] = true
    end

    local function makeTrackChoice(track, is_queue)
        local key = track.orig_id or tostring(track.id)
        local is_liked = STATE.liked_songs[key] or STATE.liked_songs[tostring(track.id)]
        local is_queued = queued_ids[track.id]
        local heart = is_liked and string.char(3) or ' '
        
        local title_pen = COLOR_WHITE
        local title_dpen = COLOR_GREY
        local author_pen = COLOR_CYAN
        local author_dpen = COLOR_DARKGREY
        
        if is_queue or is_queued then
            title_pen = COLOR_YELLOW
            title_dpen = COLOR_BROWN
            author_pen = is_queue and COLOR_WHITE or COLOR_BROWN
            author_dpen = COLOR_DARKGREY
        end
        
        local max_len = is_queue and 80 or 35

        local title_chunk = {text = track.title, pen = title_pen, dpen = title_dpen}
        
        return {
            text = {
                {text = heart .. ' ', pen = COLOR_LIGHTRED, dpen = COLOR_RED},
                title_chunk,
                {text = ' - ', pen = COLOR_GREY, dpen = COLOR_DARKGREY},
                {text = track.author, pen = author_pen, dpen = author_dpen}
            },
            track = track,
            max_len = max_len,
            raw_title = track.title,
            title_chunk = title_chunk,
            search_key = track.title:lower() .. " " .. track.author:lower()
        }
    end

    local function makeTutorialChoice(track)
        return {
            text = {
                {text = track.title, pen = COLOR_YELLOW}
            },
            track = track,
            search_key = track.title:lower()
        }
    end

    local search_lower = STATE.search_string:lower()

    if STATE.active_tab == 1 then
        local browse_choices = {}
        if STATE.search_string ~= "" then
            for _, track in ipairs(self.library) do
                if track.id >= 0 then
                    local search_key = track.title:lower() .. " " .. track.author:lower()
                    if search_key:find(search_lower, 1, true) then
                        table.insert(browse_choices, makeTrackChoice(track, false))
                    end
                end
            end
            self.subviews.list_search_tracks:setChoices(browse_choices)
        else
            local author_data = self.authors[self.selected_author_idx]
            self.subviews.panel_tracks_split.frame_title = author_data and (author_data.name .. "'s Tracks") or 'Tracks'
            if author_data then
                for _, track in ipairs(author_data.tracks) do
                    if track.orig_id == 'TUTORIAL' then
                        table.insert(browse_choices, makeTutorialChoice(track))
                    else
                        table.insert(browse_choices, makeTrackChoice(track, false))
                    end
                end
            end
            self.subviews.list_browse_tracks:setChoices(browse_choices)
        end
    end

    if STATE.active_tab == 2 then
        local queue_choices = {}
        for i, track in ipairs(STATE.queue) do
            local choice = makeTrackChoice(track, true)
            choice.real_idx = i
            if search_lower == "" or choice.search_key:find(search_lower, 1, true) then
                table.insert(choice.text, 1, {text = string.format("%02d. ", i), pen = COLOR_DARKGREY, dpen = COLOR_DARKGREY})
                table.insert(queue_choices, choice)
            end
        end
        self.subviews.list_queue:setChoices(queue_choices)
    end

    if STATE.active_tab == 3 then
        local liked_choices = {}
        for _, track in ipairs(self.library) do
            local key = track.orig_id or tostring(track.id)
            if STATE.liked_songs[key] or STATE.liked_songs[tostring(track.id)] then
                local choice = makeTrackChoice(track, false)
                if search_lower == "" or choice.search_key:find(search_lower, 1, true) then
                    table.insert(liked_choices, choice)
                end
            end
        end
        self.subviews.list_liked:setChoices(liked_choices)
    end
end

function Dwarftify:onRenderBody(dc)
    local base_style = type(gui.FRAME_INTERIOR) == 'function' and gui.FRAME_INTERIOR() or gui.FRAME_INTERIOR
    local FRAME_FOCUSED = {}
    for k,v in pairs(base_style) do FRAME_FOCUSED[k] = v end
    FRAME_FOCUSED.title_pen = dfhack.pen.parse{fg=COLOR_CYAN, bg=COLOR_BLACK, bold=true}

    local FRAME_UNFOCUSED = {}
    for k,v in pairs(base_style) do FRAME_UNFOCUSED[k] = v end
    FRAME_UNFOCUSED.title_pen = dfhack.pen.parse{fg=COLOR_DARKGREY, bg=COLOR_BLACK}

    if self.subviews.panel_artists and self.subviews.list_artists then
        self.subviews.panel_artists.frame_title = self.subviews.list_artists.focus and (string.char(16) .. ' Artists') or '  Artists'
        self.subviews.panel_artists.frame_style = self.subviews.list_artists.focus and FRAME_FOCUSED or FRAME_UNFOCUSED
    end
    if self.subviews.browse_tracks_panel and self.subviews.list_browse_tracks then
        self.subviews.browse_tracks_panel.frame_title = self.subviews.list_browse_tracks.focus and (string.char(16) .. ' Tracks') or '  Tracks'
        self.subviews.browse_tracks_panel.frame_style = self.subviews.list_browse_tracks.focus and FRAME_FOCUSED or FRAME_UNFOCUSED
    end

    local m = df.global.musicsound
    if m then
        local display_id = m.queued_song ~= -1 and m.queued_song or m.song
        if self._last_display_id ~= display_id or self._last_queue_len ~= #STATE.queue then
            self._last_display_id = display_id
            self._last_queue_len = #STATE.queue
            
            local np_label = self.subviews.now_playing
            local stat_label = self.subviews.now_playing_status
            
            if display_id == -1 or display_id == 0 then
                np_label:setText({{text = "Now Playing: None (Silence)", pen = COLOR_GREY}})
            else
                local title = "Track #" .. display_id
                local author = ""
                for _, t in ipairs(self.library) do
                    if t.id == display_id then
                        title = t.title
                        author = " by " .. t.author
                        break
                    end
                end
                np_label:setText({
                    {text = "Now Playing: ", pen = COLOR_WHITE},
                    {text = title, pen = COLOR_LIGHTGREEN},
                    {text = author, pen = COLOR_CYAN},
                    {text = " [ID:" .. display_id .. "]", pen = COLOR_DARKGREY}
                })
            end
            
            local active_str = m.music_active and "Active" or "Inactive (Engine Override)"
            if df.global.pause_state then
                active_str = "Game Paused (Press Space to transition track!)"
            end
            
            local queue_str = #STATE.queue > 0 and ("Queue: " .. #STATE.queue .. " tracks") or "Queue Empty"
            stat_label:setText({
                {text = string.char(14) .. " Engine: " .. active_str, pen = (m.music_active and not df.global.pause_state) and COLOR_LIGHTGREEN or COLOR_RED},
                {text = "    " .. string.char(16) .. " " .. queue_str, pen = COLOR_YELLOW}
            })
        end
    end

    Dwarftify.super.onRenderBody(self, dc)
end

function Dwarftify:getTrackUnderMouse()
    local flist
    if STATE.active_tab == 1 then
        if STATE.search_string ~= "" then
            flist = self.subviews.list_search_tracks
        else
            flist = self.subviews.list_browse_tracks
        end
    elseif STATE.active_tab == 2 then
        flist = self.subviews.list_queue
    elseif STATE.active_tab == 3 then
        flist = self.subviews.list_liked
    end

    if flist and flist.list and flist.list:getIdxUnderMouse() then
        local idx = flist.list:getIdxUnderMouse()
        local choice = flist.list.choices[idx]
        if choice and choice.track then
            return choice.track, choice.real_idx
        end
    end
    return nil, nil
end



function Dwarftify:onInput(keys)
    if keys._MOUSE_R then
        local track, real_idx = self:getTrackUnderMouse()
        if track then
            if STATE.active_tab == 2 and real_idx then
                table.remove(STATE.queue, real_idx)
                saveConfig()
                self:updateFilters()
            else
                enqueueTrack(track)
            end
            return true
        end
    end

    if keys.LEAVESCREEN then
        if STATE.active_tab == 1 and STATE.search_string == "" and self.subviews.list_browse_tracks.focus then
            self.subviews.list_artists:setFocus(true)
            return true
        end
    elseif keys.KEYBOARD_CURSOR_RIGHT then
        if STATE.active_tab == 1 and STATE.search_string == "" and self.subviews.list_artists.focus then
            self.subviews.list_browse_tracks:setFocus(true)
            return true
        end
    elseif keys.KEYBOARD_CURSOR_LEFT then
        if STATE.active_tab == 1 and STATE.search_string == "" and self.subviews.list_browse_tracks.focus then
            self.subviews.list_artists:setFocus(true)
            return true
        end
    elseif keys.CUSTOM_T then
        local next_tab = STATE.active_tab + 1
        if next_tab > 3 then next_tab = 1 end
        self:switchTab(next_tab)
        return true

    elseif keys._STRING == 49 then -- '1'
        self:switchTab(1)
        return true
    elseif keys._STRING == 50 then -- '2'
        self:switchTab(2)
        return true
    elseif keys._STRING == 51 then -- '3'
        self:switchTab(3)
        return true
    end
    
    return Dwarftify.super.onInput(self, keys)
end

if not dfhack_flags.module then
    local screen = Dwarftify{}
    screen:show()
end
