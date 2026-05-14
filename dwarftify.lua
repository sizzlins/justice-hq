--@ module=true
--@ enable=true

--[====[
gui/dwarftify
==============

A modern, in-game music player for Dwarf Fortress that interfaces directly
with the game's audio engine.

Usage
-----

    gui/dwarftify

]====]

local gui = require('gui')
local widgets = require('gui.widgets')
local overlay = require('plugins.overlay')
local utils = require('utils')

enabled = enabled or false

-- ===========================
-- Data Persistence
-- ===========================
local PERSIST_KEY = 'dwarftify_user_library'
local user_data = nil

local function loadUserData()
    if user_data then return user_data end
    user_data = dfhack.persistent.getSiteData(PERSIST_KEY, {
        custom_track_names = {},
        settings = { show_toast = true },
    })
    return user_data
end

local function saveUserData()
    if user_data then
        dfhack.persistent.saveSiteData(PERSIST_KEY, user_data)
    end
end

-- ===========================
-- Audio Harvesting
-- ===========================
local function formatVanillaName(token)
    if not token then return "Unknown Track" end
    local name = token:gsub("^DBERTSMUSICPACK_", "")
                      :gsub("_SIMON_SWERWER$", "")
                      :gsub("^TRACK_(%d+)$", "Track %1")
                      :gsub("^ADV_OST_TRACK_(%d+)$", "Adv OST Track %1")
                      :gsub("_", " ")
    -- Basic title case
    return name:gsub("(%w)(%w*)", function(first, rest) return first:upper() .. rest:lower() end)
end

local function harvestMusic()
    local library = {}
    local authors = {} -- map author name to list of tracks
    
    -- First, load all raws as the baseline
    local raws_by_id = {}
    if df.global.world and df.global.world.raws and df.global.world.raws.music then
        local mall = df.global.world.raws.music.all
        for i = 0, #mall - 1 do
            local raw = mall[i]
            if raw then
                local title = formatVanillaName(raw.token)
                -- Try to find the real title from [FILE:TITLE]
                if raw.current_definition then
                    for j = 0, #raw.current_definition - 1 do
                        local def = raw.current_definition[j].value
                        local fname = def:match("%[FILE:(.+)%]")
                        if fname then
                            title = fname:gsub("_", " "):gsub("(%w)(%w*)", function(a, b) return a:upper() .. b:lower() end)
                            break
                        end
                    end
                end
                
                raws_by_id[raw.song] = {
                    id = raw.song,
                    title = title,
                    author = "Dwarf Fortress",
                    orig_id = raw.token
                }
            end
        end
    end

    -- Then, overlay actual metadata from loaded_music (the real in-memory catalog)
    local m = df.global.musicsound
    if m and m.loaded_music then
        for i = 0, #m.loaded_music - 1 do
            pcall(function()
                local song = m.loaded_music[i]
                local s_id = song.id
                local title = song.title and #song.title > 0 and song.title or nil
                local author = song.author and #song.author > 0 and song.author or "Unknown Artist"
                
                if raws_by_id[s_id] then
                    if title then raws_by_id[s_id].title = title end
                    raws_by_id[s_id].author = author
                else
                    raws_by_id[s_id] = {
                        id = s_id,
                        title = title or ("Track #" .. s_id),
                        author = author,
                        orig_id = "Loaded Track #" .. s_id
                    }
                end
                
                -- Cross-reference: If a raw track's title matches this loaded track's title, steal the author
                if title then
                    for _, raw_track in pairs(raws_by_id) do
                        if raw_track.id < 120 and raw_track.title:upper() == title:upper() then
                            raw_track.author = author
                        end
                    end
                end
            end)
        end
    end

    -- Compile into library and authors map
    for _, track in pairs(raws_by_id) do
        table.insert(library, track)
        authors[track.author] = authors[track.author] or {}
        table.insert(authors[track.author], track)
    end

    -- Sort everything
    table.sort(library, function(a, b) return a.id < b.id end)
    for _, tracks in pairs(authors) do
        table.sort(tracks, function(a, b) return a.id < b.id end)
    end

    -- Extract sorted author list
    local sorted_authors = {}
    for author, tracks in pairs(authors) do
        table.insert(sorted_authors, {
            name = author,
            tracks = tracks,
            count = #tracks
        })
    end
    table.sort(sorted_authors, function(a, b)
        if a.name == "Dwarf Fortress" then return false end
        if b.name == "Dwarf Fortress" then return true end
        return a.name < b.name
    end)

    return library, sorted_authors
end

-- ===========================
-- Playback State
-- ===========================
CURRENT_PLAYLIST = CURRENT_PLAYLIST or {}
PLAYLIST_INDEX = PLAYLIST_INDEX or 1
LAST_PLAYED_TRACK = LAST_PLAYED_TRACK or nil
monitor_running = monitor_running or false
REPEAT_MODE = REPEAT_MODE or 'all'

local function setGameTrack(id)
    local m = df.global.musicsound
    if m then
        -- Tell the DJ monitor this is OUR change, not DF's
        dj_we_set_id = id
        
        -- Aggressively clear the interlude queues so the engine doesn't play a card instead
        m.neutral_card_queue:resize(0)
        m.planned_cards:resize(0)
        
        m.queued_song = id
        m.queued_song_count = 1
        m.planned_song = id
        m.next_play_duration = 0
        
        if m.music_active then
            m.flags.fade_song_out = true
        end
        m.flags.fade_card_out = true
    end
end

function playTrack(track, playlist, index)
    if playlist then
        CURRENT_PLAYLIST = playlist
        PLAYLIST_INDEX = index or 1
    else
        CURRENT_PLAYLIST = {track}
        PLAYLIST_INDEX = 1
    end
    LAST_PLAYED_TRACK = track
    setGameTrack(track.id)
    
    if showToast then
        showToast(string.char(14) .. ' Playing: ' .. track.title)
    end
    ensureMonitorRunning()
end

function playNextTrack()
    if #CURRENT_PLAYLIST == 0 then return end
    if REPEAT_MODE == 'track' then
        local track = CURRENT_PLAYLIST[PLAYLIST_INDEX]
        if track then setGameTrack(track.id) end
        return
    end
    
    PLAYLIST_INDEX = PLAYLIST_INDEX + 1
    if PLAYLIST_INDEX > #CURRENT_PLAYLIST then
        if REPEAT_MODE == 'all' then
            PLAYLIST_INDEX = 1
        else
            return
        end
    end
    
    local track = CURRENT_PLAYLIST[PLAYLIST_INDEX]
    if track then
        LAST_PLAYED_TRACK = track
        setGameTrack(track.id)
        if showToast then
            showToast(string.char(14) .. ' Playing: ' .. track.title)
        end
    end
end

function playPrevTrack()
    if #CURRENT_PLAYLIST == 0 then return end
    PLAYLIST_INDEX = PLAYLIST_INDEX - 1
    if PLAYLIST_INDEX < 1 then
        PLAYLIST_INDEX = #CURRENT_PLAYLIST
    end
    local track = CURRENT_PLAYLIST[PLAYLIST_INDEX]
    if track then
        LAST_PLAYED_TRACK = track
        setGameTrack(track.id)
    end
end

-- ===========================
-- Volume Controls
-- ===========================
local volume_channels = {"music", "ambience", "master"}
ACTIVE_VOL_IDX = ACTIVE_VOL_IDX or 1
VOL_MUTED = VOL_MUTED or {music=false, ambience=false, master=false}
VOL_CACHE = VOL_CACHE or {music=255, ambience=255, master=255}

local function getActiveVolChannel() return volume_channels[ACTIVE_VOL_IDX] end

local function cycleVolume()
    ACTIVE_VOL_IDX = ACTIVE_VOL_IDX + 1
    if ACTIVE_VOL_IDX > #volume_channels then ACTIVE_VOL_IDX = 1 end
end

local function getMedia() return df.global.init and df.global.init.media or nil end

local function getVolField(ch)
    if ch == "master" then return "volume_master" end
    return "volume_" .. ch .. "_fort"
end

local function adjustVolume(amt)
    local ch = getActiveVolChannel()
    local media = getMedia()
    if not media then return end
    local field = getVolField(ch)
    local cur = media[field]
    cur = math.max(0, math.min(255, cur + amt))
    media[field] = cur
    if cur > 0 then VOL_MUTED[ch] = false end
end

local function toggleMute()
    local ch = getActiveVolChannel()
    local media = getMedia()
    if not media then return end
    local field = getVolField(ch)
    if VOL_MUTED[ch] then
        media[field] = VOL_CACHE[ch] or 255
        VOL_MUTED[ch] = false
    else
        VOL_CACHE[ch] = media[field]
        media[field] = 0
        VOL_MUTED[ch] = true
    end
end

-- ===========================
-- Background DJ Monitor
-- ===========================
local dj_last_song = nil          -- last song ID we observed
local dj_we_set_id = nil          -- the song ID we last commanded via setGameTrack
local dj_last_change_tick = 0     -- tick when we last saw a song change
local DJ_COOLDOWN_MS = 3000       -- minimum ms between auto-advances

local function djMonitorLoop()
    if not monitor_running then return end
    if not dfhack.isWorldLoaded() then monitor_running = false; return end

    local m = df.global.musicsound
    if m and REPEAT_MODE ~= 'off' then
        local current_song = m.song

        if current_song ~= dj_last_song then
            local now = dfhack.getTickCount()
            local elapsed = now - dj_last_change_tick

            -- Song changed. Was it us or DF?
            if dj_we_set_id and current_song == dj_we_set_id then
                -- This is our own setGameTrack taking effect. Just record it.
                dj_last_song = current_song
                dj_last_change_tick = now
                dj_we_set_id = nil
            elseif elapsed >= DJ_COOLDOWN_MS then
                -- DF changed the song on its own (previous track finished).
                -- Enough time has passed, safe to auto-advance.
                dj_last_song = current_song
                dj_last_change_tick = now
                playNextTrack()
            else
                -- Song changed too fast. Just track it, don't advance.
                dj_last_song = current_song
            end
        end
    end

    dfhack.timeout(5, 'frames', djMonitorLoop)
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
-- UI Implementation (Dual Panel)
-- ===========================
Dwarftify = defclass(Dwarftify, gui.ZScreen)
Dwarftify.ATTRS = {
    focus_path = 'dwarftify',
}

function Dwarftify:init()
    loadUserData()
    self.library, self.authors = harvestMusic()
    self.selected_author_idx = 1
    
    self:addviews{
        widgets.Window{
            frame = {w = 90, h = 45},
            frame_title = string.char(14) .. ' DWARFTIFY MUSIC PLAYER',
            frame_style = gui.FRAME_INTERIOR,
            resizable = false,
            subviews = {
                -- LEFT PANEL: Artists
                widgets.Panel{
                    frame = {t = 0, l = 0, w = 35, b = 7},
                    frame_style = gui.FRAME_INTERIOR,
                    frame_title = 'Artists',
                    subviews = {
                        widgets.FilteredList{
                            view_id = 'list_artists',
                            frame = {t = 0, l = 0, r = 0, b = 0},
                            row_height = 1,
                            choices = self:buildArtistChoices(),
                            on_select = self:callback('onArtistSelect'),
                            on_submit = function() self.subviews.list_tracks:setFocus(true) end,
                        },
                    },
                },
                -- RIGHT PANEL: Album Tracks
                widgets.Panel{
                    frame = {t = 0, l = 36, r = 0, b = 7},
                    frame_style = gui.FRAME_INTERIOR,
                    frame_title = 'Album Tracks',
                    subviews = {
                        widgets.FilteredList{
                            view_id = 'list_tracks',
                            frame = {t = 0, l = 0, r = 0, b = 0},
                            row_height = 1,
                            choices = {}, -- populated on artist select
                            on_submit = self:callback('onTrackSubmit'),
                        },
                    },
                },
                -- FOOTER
                widgets.Panel{
                    view_id = 'context_bar',
                    frame = {b = 0, l = 0, r = 0, h = 6},
                    subviews = {
                        widgets.Label{
                            frame = {t = 0, l = 0},
                            text = {{text = string.rep('-', 88), pen = COLOR_DARKGREY}},
                        },
                        -- Now Playing Row
                        widgets.Label{
                            view_id = 'now_playing',
                            frame = {t = 1, l = 1},
                            text = {{text = 'Now Playing: ...', pen = COLOR_GREY}},
                        },

                        widgets.Label{
                            frame = {t = 2, l = 1},
                            text = {{text = string.char(14) .. ' Playback Active', pen = COLOR_LIGHTGREEN}},
                        },
                        widgets.CycleHotkeyLabel{
                            view_id = 'repeat_cycle',
                            frame = {t = 2, l = 32},
                            key = 'CUSTOM_SHIFT_T',
                            label = 'Repeat:',
                            options = {
                                {label = 'OFF', value = 'off', pen = COLOR_GREY},
                                {label = 'ALL', value = 'all', pen = COLOR_LIGHTGREEN},
                                {label = 'TRACK', value = 'track', pen = COLOR_LIGHTMAGENTA},
                            },
                            initial_option = REPEAT_MODE == 'all' and 2 or (REPEAT_MODE == 'track' and 3 or 1),
                            on_change = function(val) REPEAT_MODE = val end,
                        },
                        widgets.Label{
                            frame = {t = 3, l = 0},
                            text = {{text = string.rep('=', 88), pen = COLOR_DARKGREY}},
                        },
                        -- Transport Row
                        widgets.HotkeyLabel{
                            frame = {t = 4, l = 22, w = 14},
                            key = 'CUSTOM_SHIFT_Z',
                            label = '|< [Prev]',
                            on_activate = function() playPrevTrack() end,
                        },
                        widgets.Label{
                            frame = {t = 4, l = 38},
                            text = {{text = '[ || PAUSE ]', pen = COLOR_WHITE}},
                        },
                        widgets.HotkeyLabel{
                            frame = {t = 4, l = 53, w = 14},
                            key = 'CUSTOM_SHIFT_X',
                            label = '[Next] >|',
                            on_activate = function() playNextTrack() end,
                        },
                        widgets.Label{
                            view_id = 'vol_indicator',
                            frame = {t = 4, l = 68},
                            text = "Vol [Mast]: .....",
                        },
                    },
                },
            },
        },
    }
    
    -- Init selection
    if #self.authors > 0 then
        self:onArtistSelect(1, {data = self.authors[1]})
    end
end

function Dwarftify:buildArtistChoices()
    local choices = {}
    for _, author in ipairs(self.authors) do
        local name = author.name
        if #name > 22 then name = string.sub(name, 1, 19) .. "..." end
        table.insert(choices, {
            text = {
                {text = string.format("%-24s", name), pen = COLOR_CYAN},
                {text = string.format("[%2d trks]", author.count), pen = COLOR_DARKGREY}
            },
            search_key = string.lower(author.name),
            data = author
        })
    end
    return choices
end

function Dwarftify:onArtistSelect(idx, choice)
    if choice and choice.data then
        local tracks = choice.data.tracks
        local track_choices = {}
        for _, track in ipairs(tracks) do
            local title = track.title
            if #title > 28 then title = string.sub(title, 1, 25) .. "..." end
            table.insert(track_choices, {
                text = {
                    {text = " " .. string.char(14) .. " ", pen = COLOR_GREEN},
                    {text = string.format("%-30s", title), pen = COLOR_WHITE},
                    {text = string.format("ID:%-3s", track.id), pen = COLOR_DARKGREY}
                },
                search_key = string.lower(track.title),
                data = track
            })
        end
        local track_list = self.subviews.list_tracks
        if track_list then
            track_list:setChoices(track_choices)
        end
    end
end

function Dwarftify:onTrackSubmit(idx, choice)
    if choice and choice.data then
        local artist_idx, artist_choice = self.subviews.list_artists:getSelected()
        if artist_choice then
            playTrack(choice.data, artist_choice.data.tracks, idx)
        end
    end
end

function Dwarftify:onRenderBody(dc)
    -- Vol Indicator
    local ch = getActiveVolChannel()
    local media = getMedia()
    local val = media and media[getVolField(ch)] or 0
    local muted = VOL_MUTED[ch]
    
    if self._last_vol_ch ~= ch or self._last_vol_val ~= val or self._last_vol_muted ~= muted then
        self._last_vol_ch = ch
        self._last_vol_val = val
        self._last_vol_muted = muted
        if self.subviews.vol_indicator then
            local blocks = math.floor((val / 255) * 5 + 0.5)
            local bar = ""
            for i=1,5 do
                bar = bar .. (i <= blocks and string.char(254) or string.char(250))
            end
            local lbl = ch:sub(1,4):gsub("^%l", string.upper)
            if muted then
                self.subviews.vol_indicator:setText({{text = "Vol [" .. lbl .. "]: MUTED", pen = COLOR_RED}})
            else
                self.subviews.vol_indicator:setText("Vol [" .. lbl .. "]: " .. bar)
            end
        end
    end

    -- Playback State
    local m = df.global.musicsound
    if m then


        local display_id = m.queued_song ~= -1 and m.queued_song or m.song
        if self._last_display_id ~= display_id then
            self._last_display_id = display_id
            local label = self.subviews.now_playing
            if label then
                if display_id == -1 or display_id == 0 then
                    label:setText({{text = "Now Playing: None (Silence)", pen = COLOR_GREY}})
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
                    label:setText({
                        {text = "Now Playing: ", pen = COLOR_WHITE},
                        {text = title, pen = COLOR_LIGHTGREEN},
                        {text = author, pen = COLOR_CYAN},
                        {text = " [ID:" .. display_id .. "]", pen = COLOR_DARKGREY}
                    })
                end
            end
        end
    end

    Dwarftify.super.onRenderBody(self, dc)
end

function Dwarftify:onInput(keys)
    if keys._STRING then
        if keys._STRING == 43 then adjustVolume(15); return true end   -- '+'
        if keys._STRING == 45 then adjustVolume(-15); return true end  -- '-'
    end
    if keys.CUSTOM_SHIFT_V then cycleVolume(); return true
    elseif keys.CUSTOM_SHIFT_M then toggleMute(); return true
    elseif keys.LEAVESCREEN then
        -- Handle returning focus from tracks list back to artist list instead of closing immediately
        if self.subviews.list_tracks.has_focus then
            self.subviews.list_artists:setFocus(true)
            return true
        end
    end

    return Dwarftify.super.onInput(self, keys)
end

-- ===========================
-- Overlays
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
    local ud = loadUserData()
    if ud.settings and ud.settings.show_toast == false then
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
-- Module / Entry Point
-- ===========================
if dfhack_flags.module then
    return
end

local screen = Dwarftify{}
screen:show()
