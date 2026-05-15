--@ module=true

--[====[
gui/announce-settings
=====================

Adds Save/Load/Disable All/Reset buttons to the Announcements settings screen,
plus column toggles to quickly set up a Terrarium mode.

Usage
-----
    Appears automatically as an overlay on the Announcements settings screen.
    (ESC > Settings > Announcements)
]====]

local gui = require('gui')
local widgets = require('gui.widgets')
local json = require('json')
local overlay = require('plugins.overlay')

local SAVE_PATH = 'dfhack-config/announce-settings.json'

local FLAG_NAMES = {
    'DO_MEGA', 'PAUSE', 'RECENTER', 'A_DISPLAY', 'D_DISPLAY',
    'UNIT_COMBAT_REPORT', 'UNIT_COMBAT_REPORT_ALL_ACTIVE', 'ALERT'
}

-- ===========================
-- Core Logic
-- ===========================

local function serialize_announcements()
    local data = {}
    local flags = df.global.d_init.announcements.flags
    for k, v in pairs(flags) do
        local entry = {}
        for _, fn in ipairs(FLAG_NAMES) do
            entry[fn] = v[fn]
        end
        data[k] = entry
    end
    return data
end

local function apply_announcements(data)
    local flags = df.global.d_init.announcements.flags
    for k, entry in pairs(data) do
        local target = flags[k]
        if target then
            for fn, val in pairs(entry) do
                target[fn] = val
            end
        end
    end
end

local function save_announcements()
    local data = serialize_announcements()
    local f = io.open(SAVE_PATH, 'w')
    if f then
        f:write(json.encode(data))
        f:close()
        print('Announce-Settings: Saved ' .. tostring(#(table.pack(pairs(data)))) .. ' announcement configs to ' .. SAVE_PATH)
        dfhack.gui.showAnnouncement('Announcement settings saved!', COLOR_GREEN)
    else
        dfhack.printerr('Announce-Settings: Failed to open ' .. SAVE_PATH .. ' for writing.')
    end
end

local function load_announcements()
    local f = io.open(SAVE_PATH, 'r')
    if not f then
        dfhack.gui.showAnnouncement('No saved announcement settings found.', COLOR_YELLOW)
        return
    end
    local text = f:read('*a')
    f:close()
    
    local ok, data = pcall(json.decode, text)
    if not ok or type(data) ~= 'table' then
        dfhack.printerr('Announce-Settings: Failed to parse ' .. SAVE_PATH)
        return
    end
    
    apply_announcements(data)
    dfhack.gui.showAnnouncement('Announcement settings loaded!', COLOR_LIGHTGREEN)
end

local TARGET_MODES = {'ALL', 'COMBAT', 'ADVENTURE', 'FORTRESS', 'OTHER'}
local current_target_idx = 1

local function get_announcement_category(enum_name)
    if not enum_name then return 'OTHER' end
    local name = tostring(enum_name)
    
    local combat_keys = {
        'COMBAT', 'WRESTLE', 'STRIKE', 'ATTACK', 'DODGE', 'PARRY', 'BLOCK', 'CHARGE',
        'FALL_OVER', 'CAUGHT_IN_', 'SLAM', 'VOMIT', 'LOSE_HOLD', 'REGAIN_', 'FREE_FROM',
        'PARALYZ', 'NOT_STUNNED', 'EXHAUSTION', 'PAIN_KO', 'BREAK_GRIP', 'FIRE', 'WEB',
        'PULL_OUT', 'STAND_UP', 'MARTIAL_TRANCE', 'MAT_BREATH', 'FLAME_', 'FAIL_TO_GRAB',
        'PUSH_ITEM', 'MOUNT'
    }
    for _, k in ipairs(combat_keys) do
        if name:find(k) then return 'COMBAT' end
    end
    
    local adv_keys = {
        'ADV_', 'YOU_', 'ADVENTURE', 'SLEEP', 'TRAVEL', 'SMELL'
    }
    for _, k in ipairs(adv_keys) do
        if name:find(k) then return 'ADVENTURE' end
    end
    
    local fort_keys = {
        'MIGRANT', 'AMBUSH', 'MERCHANT', 'CARAVAN', 'CITIZEN', 'NOBLE', 'MASTERPIECE',
        'SEASON', 'WEATHER', 'D_', 'ANIMAL', 'CAVE_COLLAPSE', 'BIRTH', 'ARTIFACT',
        'MEGABEAST', 'WEREBEAST', 'BERSERK', 'MAGMA', 'ENGRAV', 'CONSTRUCT', 'ARCHITECTURE',
        'PET', 'NIGHT_ATTACK', 'GHOST', 'UNDEAD', 'STRANGE', 'TRAINING', 'STRESS',
        'TANTRUM', 'MANDATE', 'GUILD', 'ELECTION', 'AGREEMENT', 'MONARCH', 'FOOD'
    }
    for _, k in ipairs(fort_keys) do
        if name:find(k) then return 'FORTRESS' end
    end
    
    return 'OTHER'
end

local function cycle_target_mode()
    current_target_idx = current_target_idx + 1
    if current_target_idx > #TARGET_MODES then
        current_target_idx = 1
    end
end

local function disable_all_announcements()
    local flags = df.global.d_init.announcements.flags
    local target_mode = TARGET_MODES[current_target_idx]
    local count = 0
    for k, v in pairs(flags) do
        local cat = get_announcement_category(k)
        if target_mode == 'ALL' or cat == target_mode then
            for _, fn in ipairs(FLAG_NAMES) do
                v[fn] = false
            end
            count = count + 1
        end
    end
    dfhack.gui.showAnnouncement('Disabled ' .. count .. ' ' .. target_mode .. ' announcements!', COLOR_LIGHTRED)
end

local function reset_announcements()
    local DEFAULTS_PATH = 'dfhack-config/announce-defaults.json'
    local f = io.open(DEFAULTS_PATH, 'r')
    if not f then
        dfhack.gui.showAnnouncement('No defaults snapshot found! Cannot reset.', COLOR_LIGHTRED)
        return
    end
    local text = f:read('*a')
    f:close()
    
    local ok, data = pcall(json.decode, text)
    if not ok or type(data) ~= 'table' then
        dfhack.printerr('Announce-Settings: Failed to parse defaults file.')
        return
    end
    
    apply_announcements(data)
    dfhack.gui.showAnnouncement('Announcement settings reset to vanilla defaults!', COLOR_LIGHTCYAN)
end

local function toggle_column(flag_name)
    local flags = df.global.d_init.announcements.flags
    local target_mode = TARGET_MODES[current_target_idx]
    
    -- Check if ANY are false for the current target mode
    local any_false = false
    for k, v in pairs(flags) do
        local cat = get_announcement_category(k)
        if target_mode == 'ALL' or cat == target_mode then
            if not v[flag_name] then
                any_false = true
                break
            end
        end
    end
    
    local new_val = any_false
    local count = 0
    for k, v in pairs(flags) do
        local cat = get_announcement_category(k)
        if target_mode == 'ALL' or cat == target_mode then
            v[flag_name] = new_val
            count = count + 1
        end
    end
    
    local status = new_val and 'ENABLED' or 'DISABLED'
    dfhack.gui.showAnnouncement(flag_name .. ' column ' .. status .. ' for ' .. count .. ' ' .. target_mode .. ' items.', new_val and COLOR_LIGHTGREEN or COLOR_LIGHTRED)
end

-- On first load, snapshot the current (vanilla) state as the defaults
local function snapshot_defaults_if_needed()
    local DEFAULTS_PATH = 'dfhack-config/announce-defaults.json'
    local f = io.open(DEFAULTS_PATH, 'r')
    if f then
        f:close()
        return
    end
    local data = serialize_announcements()
    f = io.open(DEFAULTS_PATH, 'w')
    if f then
        f:write(json.encode(data))
        f:close()
        print('Announce-Settings: Vanilla defaults snapshot saved to ' .. DEFAULTS_PATH)
    end
end

snapshot_defaults_if_needed()

-- ===========================
-- Overlay Widgets
-- ===========================

AnnounceSettingsProfileOverlay = defclass(AnnounceSettingsProfileOverlay, overlay.OverlayWidget)
AnnounceSettingsProfileOverlay.ATTRS = {
    desc = 'Global profile controls for Announcements (Save/Load/Disable All/Reset).',
    default_pos = {x = 23, y = -6},
    default_enabled = true,
    viewscreens = 'dwarfmode/Settings/ANNOUNCEMENTS',
    frame = {w = 23, h = 7},
}

function AnnounceSettingsProfileOverlay:init()
    self:addviews{
        widgets.Panel{
            frame = {t = 0, l = 0, r = 0, b = 0},
            frame_style = gui.FRAME_MEDIUM,
            frame_background = gui.CLEAR_PEN,
            subviews = {
                widgets.HotkeyLabel{
                    frame = {t = 0, l = 1},
                    key = 'CUSTOM_CTRL_S',
                    label = 'Save Profile',
                    text_pen = COLOR_LIGHTGREEN,
                    on_activate = save_announcements,
                },
                widgets.HotkeyLabel{
                    frame = {t = 1, l = 1},
                    key = 'CUSTOM_CTRL_L',
                    label = 'Load Profile',
                    text_pen = COLOR_LIGHTCYAN,
                    on_activate = load_announcements,
                },
                widgets.HotkeyLabel{
                    frame = {t = 3, l = 1},
                    key = 'CUSTOM_CTRL_D',
                    label = 'Disable ALL',
                    text_pen = COLOR_LIGHTRED,
                    on_activate = disable_all_announcements,
                },
                widgets.HotkeyLabel{
                    frame = {t = 4, l = 1},
                    key = 'CUSTOM_CTRL_R',
                    label = 'Reset',
                    text_pen = COLOR_WHITE,
                    on_activate = reset_announcements,
                },
            }
        }
    }
end


AnnounceSettingsMessageOverlay = defclass(AnnounceSettingsMessageOverlay, overlay.OverlayWidget)
AnnounceSettingsMessageOverlay.ATTRS = {
    desc = 'Helpful message explaining Terrarium mode requirements.',
    default_pos = {x = 48, y = -6},
    default_enabled = true,
    viewscreens = 'dwarfmode/Settings/ANNOUNCEMENTS',
    frame = {w = 50, h = 6},
}

function AnnounceSettingsMessageOverlay:init()
    self:addviews{
        widgets.Panel{
            frame = {t = 0, l = 0, r = 0, b = 0},
            frame_style = gui.FRAME_MEDIUM,
            frame_background = gui.CLEAR_PEN,
            subviews = {
                widgets.Label{
                    frame = {t = 0, l = 1},
                    text = {
                        {text = 'Tip:', pen = COLOR_YELLOW},
                    }
                },
                widgets.Label{
                    frame = {t = 2, l = 1},
                    text = {
                        {text = 'Disable ', pen = COLOR_WHITE},
                        {text = 'Popup', pen = COLOR_LIGHTRED},
                        {text = ', ', pen = COLOR_WHITE},
                        {text = 'Pause', pen = COLOR_LIGHTRED},
                        {text = ', and ', pen = COLOR_WHITE},
                        {text = 'Recenter', pen = COLOR_LIGHTRED},
                    }
                },
                widgets.Label{
                    frame = {t = 3, l = 1},
                    text = {
                        {text = 'for 24/7 uninterruptible gameplay', pen = COLOR_WHITE},
                    }
                },
                widgets.Label{
                    frame = {t = 4, l = 1},
                    text = {
                        {text = 'without pauses from the game.', pen = COLOR_WHITE},
                    }
                },
            }
        }
    }
end


AnnounceSettingsTargetOverlay = defclass(AnnounceSettingsTargetOverlay, overlay.OverlayWidget)
AnnounceSettingsTargetOverlay.ATTRS = {
    desc = 'Category target selector for Announcement settings.',
    default_pos = {x = 135, y = 10},
    default_enabled = true,
    viewscreens = 'dwarfmode/Settings/ANNOUNCEMENTS',
    frame = {w = 24, h = 3},
}

function AnnounceSettingsTargetOverlay:init()
    self:addviews{
        widgets.Panel{
            frame = {t = 0, l = 0, r = 0, b = 0},
            frame_style = gui.FRAME_MEDIUM,
            frame_background = gui.CLEAR_PEN,
            subviews = {
                widgets.HotkeyLabel{
                    frame = {t = 0, l = 1},
                    key = 'CUSTOM_ALT_T',
                    label = 'Target:',
                    text_pen = COLOR_CYAN,
                    on_activate = cycle_target_mode,
                },
                widgets.Label{
                    frame = {t = 0, l = 12},
                    text = {
                        {text = function() return '[' .. TARGET_MODES[current_target_idx] .. ']' end, pen = COLOR_WHITE}
                    }
                },
            }
        }
    }
end


AnnounceSettingsTogglesOverlay = defclass(AnnounceSettingsTogglesOverlay, overlay.OverlayWidget)
AnnounceSettingsTogglesOverlay.ATTRS = {
    desc = 'Column toggle buttons for Announcement settings.',
    default_pos = {x = 135, y = 14},
    default_enabled = true,
    viewscreens = 'dwarfmode/Settings/ANNOUNCEMENTS',
    frame = {w = 24, h = 10},
}

function AnnounceSettingsTogglesOverlay:init()
    self:addviews{
        widgets.Panel{
            frame = {t = 0, l = 0, r = 0, b = 0},
            frame_style = gui.FRAME_MEDIUM,
            frame_background = gui.CLEAR_PEN,
            subviews = {
                widgets.HotkeyLabel{
                    frame = {t = 0, l = 1},
                    key = 'CUSTOM_ALT_1',
                    label = 'Toggle Popup',
                    text_pen = COLOR_LIGHTRED,
                    on_activate = function() toggle_column('DO_MEGA') end,
                },
                widgets.HotkeyLabel{
                    frame = {t = 1, l = 1},
                    key = 'CUSTOM_ALT_2',
                    label = 'Toggle Pause',
                    text_pen = COLOR_LIGHTRED,
                    on_activate = function() toggle_column('PAUSE') end,
                },
                widgets.HotkeyLabel{
                    frame = {t = 2, l = 1},
                    key = 'CUSTOM_ALT_3',
                    label = 'Toggle Recenter',
                    text_pen = COLOR_LIGHTRED,
                    on_activate = function() toggle_column('RECENTER') end,
                },
                widgets.HotkeyLabel{
                    frame = {t = 3, l = 1},
                    key = 'CUSTOM_ALT_4',
                    label = 'Toggle Adv',
                    text_pen = COLOR_GRAY,
                    on_activate = function() toggle_column('A_DISPLAY') end,
                },
                widgets.HotkeyLabel{
                    frame = {t = 5, l = 1},
                    key = 'CUSTOM_ALT_5',
                    label = 'Toggle Fort',
                    text_pen = COLOR_GRAY,
                    on_activate = function() toggle_column('D_DISPLAY') end,
                },
                widgets.HotkeyLabel{
                    frame = {t = 6, l = 1},
                    key = 'CUSTOM_ALT_6',
                    label = 'Toggle Report',
                    text_pen = COLOR_GRAY,
                    on_activate = function() toggle_column('UNIT_COMBAT_REPORT') end,
                },
                widgets.HotkeyLabel{
                    frame = {t = 7, l = 1},
                    key = 'CUSTOM_ALT_7',
                    label = 'Toggle Rep(Act)',
                    text_pen = COLOR_GRAY,
                    on_activate = function() toggle_column('UNIT_COMBAT_REPORT_ALL_ACTIVE') end,
                },
                widgets.HotkeyLabel{
                    frame = {t = 8, l = 1},
                    key = 'CUSTOM_ALT_8',
                    label = 'Toggle Alert',
                    text_pen = COLOR_GRAY,
                    on_activate = function() toggle_column('ALERT') end,
                },
            }
        }
    }
end

OVERLAY_WIDGETS = {
    profile = AnnounceSettingsProfileOverlay,
    message = AnnounceSettingsMessageOverlay,
    target = AnnounceSettingsTargetOverlay,
    toggles = AnnounceSettingsTogglesOverlay,
}

if dfhack_flags.module then
    return
end
