--@ module=true
--@ enable=true

--[====[
gui/justice-hq
==============

Tags: fort | interface

Useful DFHack overlay to help you with the Justice mechanic. Alerts you about villains entering your fort, looping interrogations until they concede, pardon or execute convicts by the hands of your Captain of the guard/Sherrif, and maps villain networks on your fort.

Usage
-----

    gui/justice-hq

]====]

local gui = require('gui')
local widgets = require('gui.widgets')
local dialogs = require('gui.dialogs')
local utils = require('utils')

-- Persistent watchlist: tracks suspects under relentless interrogation
-- Key = unit.id, Value = {name, retries, max_retries, status, unit_id, hf_id}
interrogation_watchlist = interrogation_watchlist or {}

local MAX_RETRIES = 15
local MAX_CONSECUTIVE_DUDS = 3  -- stop after this many failed attempts in a row
local GLOBAL_KEY = 'gui/justice-hq'

enabled = enabled or false

function isEnabled()
    return enabled
end

local function persist_state()
    -- Convert numeric keys to strings for JSON compatibility
    local watchlist_data = {}
    for uid, watch in pairs(interrogation_watchlist) do
        watchlist_data[tostring(uid)] = {
            name = watch.name,
            full_name = watch.full_name,
            retries = watch.retries,
            max_retries = watch.max_retries,
            consecutive_duds = watch.consecutive_duds,
            status = watch.status,
            unit_id = watch.unit_id,
            hf_id = watch.hf_id,
        }
    end
    dfhack.persistent.saveSiteData(GLOBAL_KEY, {
        enabled = enabled,
        watchlist = watchlist_data,
    })
end

local INTERRUPTABLE_JOBS = {}
for _, name in ipairs({
    'StoreItemInStockpile', 'StoreItemInArchive', 'StoreItemInBag',
    'StoreItemInBarrel', 'StoreItemInBin', 'StoreItemInChest',
    'StoreOwnedItem', 'StoreItemInHospital', 'StoreItemOnDisplay',
    'StoreItemInTomb', 'StoreItemInVehicles', 'CleanItems',
    'CleanSelf', 'CollectSand', 'CollectClay'
}) do
    if df.job_type[name] then
        INTERRUPTABLE_JOBS[df.job_type[name]] = true
    end
end

local function load_state()
    local persisted_data = dfhack.persistent.getSiteData(GLOBAL_KEY, {enabled=true})
    enabled = persisted_data.enabled
    -- Restore watchlist, converting string keys back to numbers
    if persisted_data.watchlist then
        interrogation_watchlist = {}
        for uid_str, watch in pairs(persisted_data.watchlist) do
            local uid = tonumber(uid_str)
            if uid then
                -- Reset transient per-session state
                if watch.status == 'dispatched' then
                    watch.status = 'active'
                end
                watch.dispatched_tick = nil
                watch.seen_interrogating = nil
                interrogation_watchlist[uid] = watch
            end
        end
    end
end

-- ===========================
-- Date Formatting
-- ===========================

local DF_MONTHS = {
    'Granite', 'Slate', 'Felsite',
    'Hematite', 'Malachite', 'Galena',
    'Limestone', 'Sandstone', 'Timber',
    'Moonstone', 'Opal', 'Obsidian'
}

-- Terminology Tooltips
-- ===========================
-- Plain-English descriptions of DF's internal enum names,
-- sourced from live probe of df.intrigue_plot_type, df.plot_role_type, df.plot_strategy_type.

local PLOT_TOOLTIPS = {
    Grow_Funding_Network = "Recruit wealthy contacts to fund espionage operations.",
    Grow_Asset_Network = "Build a network of loyal agents and operatives.",
    Acquire_Artifact = "Steal or seize a specific artifact for the mastermind.",
    Grow_Corruption_Network = "Recruit corrupt officials to undermine governance.",
    Attain_Rank = "Manipulate politics to gain a position of power.",
    Assassinate_Actor = "Plot to kill a specific target.",
    Corruptly_Punish_Actor = "Use authority to unjustly punish someone.",
    Frame_Actor = "Plant false evidence to frame an innocent.",
    Kidnap_Actor = "Abduct a target to use as leverage.",
    Sabotage_Actor = "Undermine or destroy a target's work or property.",
    Direct_War_To_Actor = "Redirect military forces against a target.",
    Corrupt_Actors_Government = "Infiltrate and corrupt a civilization's leadership.",
    Counterintelligence = "Detect and neutralize enemy spies.",
    Become_Immortal = "Seek immortality through necromancy or artifacts.",
    Undead_World_Conquest = "Raise undead armies to conquer the world.",
    Infiltrate_Society = "Embed agents into a civilization or site.",
}

local ROLE_TOOLTIPS = {
    Possible_Threat = "Identified as a potential obstacle to the mastermind's plans.",
    Rebuffed = "Refused the mastermind's overtures. May be targeted.",
    Source_Of_Funds = "Provides financial resources for operations.",
    Source_Of_Funds_For_Master = "Funds flow through this actor to the mastermind's superior.",
    Master = "The mastermind's direct superior in the conspiracy.",
    Suspected_Criminal = "Believed to be involved in criminal activity.",
    Asset = "A recruited agent working for the mastermind.",
    Lieutenant = "A trusted subordinate managing operations.",
    Usable_Thief = "Can be leveraged to steal items.",
    Potential_Employer = "Someone who might offer useful employment.",
    Indirect_Director = "Controls operations through intermediaries.",
    Corrupt_Position_Holder = "Holds a position of authority and has been corrupted.",
    Delivery_Target = "Designated to receive stolen goods or kidnapped victims.",
    Handler = "Manages and directs field agents.",
    Usable_Assassin = "Can be leveraged to carry out assassinations.",
    Director = "Directly commands operations.",
    Enemy = "An active adversary of the mastermind.",
    Usable_Snatcher = "Can be leveraged to kidnap targets.",
    Plot_Snatcher = "Assigned to carry out a specific kidnapping plot.",
    Plot_Saboteur = "Assigned to carry out a specific sabotage plot.",
    Underworld_Contact = "A criminal connection in the underworld.",
    None = "No specific role assigned.",
}

local STRATEGY_TOOLTIPS = {
    Corrupt_And_Pacify = "Bribe or coerce to prevent interference.",
    Obey = "Follow this actor's orders without question.",
    Avoid = "Stay away and don't attract attention.",
    Use = "Exploit this actor for personal gain.",
    Tax = "Extract resources from this actor.",
    Neutralize = "Eliminate or remove this actor as a threat.",
    Monitor = "Keep this actor under surveillance.",
    Work_If_Suited = "Collaborate when mutually beneficial.",
    Torment = "Inflict suffering as punishment or intimidation.",
    None = "No specific strategy assigned.",
}

local function dfDateString(year, year_tick)
    if not year or year < 0 then return 'Unknown' end
    if not year_tick or year_tick < 0 then return 'Year ' .. year end
    local month_idx = math.floor(year_tick / 33600)
    if month_idx > 11 then month_idx = 11 end
    local day = math.floor((year_tick % 33600) / 1200) + 1
    return string.format('%d %s, %d', day, DF_MONTHS[month_idx + 1], year)
end

-- Helper: Crime Data Lookup
-- ===========================

CRIME_CACHE = CRIME_CACHE or nil
INTERROGATION_HISTORY_CACHE = INTERROGATION_HISTORY_CACHE or nil

function initCrimeCache()
    CRIME_CACHE = {}
    INTERROGATION_HISTORY_CACHE = {}
    for _, crime in ipairs(df.global.world.crimes.all) do
        local function add_to_cache(uid)
            if uid ~= -1 then
                CRIME_CACHE[uid] = CRIME_CACHE[uid] or {
                    times_accused = 0,
                    times_convicted = 0,
                    crimes_list = {},
                }
                CRIME_CACHE[uid].times_accused = CRIME_CACHE[uid].times_accused + 1
                if crime.flags.sentenced then
                    CRIME_CACHE[uid].times_convicted = CRIME_CACHE[uid].times_convicted + 1
                end
                table.insert(CRIME_CACHE[uid].crimes_list, crime)
            end
        end
        add_to_cache(crime.accused)
        if crime.criminal ~= crime.accused then
            add_to_cache(crime.criminal)
        end
    end

    local events = df.global.world.history.events
    for i = #events - 1, 0, -1 do
        local event = events[i]
        if df.history_event_hf_interrogatedst:is_instance(event) then
            INTERROGATION_HISTORY_CACHE[event.target_hf] = (INTERROGATION_HISTORY_CACHE[event.target_hf] or 0) + 1
        end
        -- Stop scanning once we're too far back (performance)
        if event.year < df.global.cur_year - 5 then break end
    end
end

function getUnitCrimeData(unit)
    if not CRIME_CACHE then initCrimeCache() end
    
    local cdata = CRIME_CACHE[unit.id]
    
    local data = {
        times_accused = cdata and cdata.times_accused or 0,
        times_convicted = cdata and cdata.times_convicted or 0,
        crimes_list = cdata and cdata.crimes_list or {},
        is_caged = false,
        is_chained = false,
    }
    
    -- Check caged/chained via unit flags
    pcall(function()
        if unit.flags1.caged then data.is_caged = true end
        if unit.flags1.chained then data.is_chained = true end
    end)
    
    return data
end

-- ===========================
-- Helper: Find Captain of Guard
-- ===========================

function findCaptainOfGuard()
    for _, unit in ipairs(df.global.world.units.active) do
        if dfhack.units.isCitizen(unit) and dfhack.units.isAlive(unit) then
            local positions = dfhack.units.getNoblePositions(unit)
            if positions then
                for _, pos in ipairs(positions) do
                    if pos.position and (pos.position.code == 'CAPTAIN_OF_THE_GUARD'
                                      or pos.position.code == 'SHERIFF') then
                        return unit
                    end
                end
            end
        end
    end
    return nil
end

function findHammerer()
    for _, unit in ipairs(df.global.world.units.active) do
        if dfhack.units.isCitizen(unit) and dfhack.units.isAlive(unit) then
            local positions = dfhack.units.getNoblePositions(unit)
            if positions then
                for _, pos in ipairs(positions) do
                    if pos.position and pos.position.code == 'HAMMERER' then
                        return unit
                    end
                end
            end
        end
    end
    return nil
end

-- ===========================
-- Helper: Find Available Jail Restraint
-- ===========================

function findAvailableJailRestraint()
    for _, bld in ipairs(df.global.world.buildings.other.CHAIN) do
        -- Must be assigned to a jail zone
        local is_jail = false
        if bld.relations then
            for _, zone in ipairs(bld.relations) do
                if zone and zone:getType() == df.building_type.Civzone and zone.type == df.civzone_type.Dungeon then
                    is_jail = true
                    break
                end
            end
        end
        
        -- Must be empty
        if is_jail and not bld.chained then
            return bld
        end
    end
    return nil
end

-- ===========================
-- Helper: Detain Unit
-- ===========================

function detainUnit(unit)
    -- Step 1: Try to use the punishment's pre-assigned chain first
    local restraint = nil
    for _, punishment in ipairs(df.global.plotinfo.punishments) do
        if punishment.criminal == unit.id and punishment.chain ~= -1 then
            local assigned = df.building.find(punishment.chain)
            if assigned and not assigned.chained then
                restraint = assigned
                break
            end
        end
    end
    
    -- Step 2: Fall back to any empty jail chain
    if not restraint then
        restraint = findAvailableJailRestraint()
    end
    
    if not restraint then
        return false, "No empty jail chains/ropes found!"
    end
    
    local ok, err = pcall(function()
        -- Teleport unit to restraint
        unit.pos.x = restraint.centerx
        unit.pos.y = restraint.centery
        unit.pos.z = restraint.z
        
        -- Link building -> unit
        restraint.chained = unit
        
        -- Link unit -> building via general_ref
        local has_chain_ref = false
        for _, ref in ipairs(unit.general_refs) do
            if ref:getType() == df.general_ref_type.BUILDING_CHAIN then
                ref.building_id = restraint.id
                has_chain_ref = true
                break
            end
        end
        if not has_chain_ref then
            local new_ref = df.general_ref_building_chainst:new()
            new_ref.building_id = restraint.id
            unit.general_refs:insert('#', new_ref)
        end
        
        -- Set flags
        unit.flags1.chained = true
        unit.flags1.caged = false
        
        -- Stop their current pathing/job
        unit.path.dest.x = -30000
        unit.path.dest.y = -30000
        unit.path.dest.z = -30000
        unit.path.path.x:resize(0)
        unit.path.path.y:resize(0)
        unit.path.path.z:resize(0)
    end)
    
    if not ok then return false, tostring(err) end
    return true
end

function releaseUnit(unit)
    local ok, err = pcall(function()
        local target_chain = nil
        for _, bld in ipairs(df.global.world.buildings.other.CHAIN) do
            if bld.chained and bld.chained.id == unit.id then
                target_chain = bld
                break
            end
        end

        if target_chain then
            target_chain.chained = nil
        end

        unit.flags1.chained = false

        for i = #unit.general_refs - 1, 0, -1 do
            local ref = unit.general_refs[i]
            if ref:getType() == df.general_ref_type.BUILDING_CHAIN then
                unit.general_refs:erase(i)
            end
        end
    end)
    
    if not ok then return false, tostring(err) end
    return true
end

-- ===========================
-- Helper: Create Interrogation Job
-- ===========================

function tryCreateInterrogationJob(suspect_unit)
    local guard = findCaptainOfGuard()
    if not guard then
        return false, "No Captain of the Guard assigned!"
    end
    
    if guard.id == suspect_unit.id then
        return false, "The Captain of the Guard cannot interrogate themselves!"
    end
    
    -- Don't interrupt if the Captain is already busy
    if guard.job.current_job then
        return false, "Captain is busy (" .. tostring(df.job_type[guard.job.current_job.job_type]) .. ")"
    end
    
    local ok, err = pcall(function()
        local job = df.job:new()
        job.job_type = df.job_type.InterrogateSubject
        
        -- Set position to suspect's location
        job.pos.x = suspect_unit.pos.x
        job.pos.y = suspect_unit.pos.y
        job.pos.z = suspect_unit.pos.z
        
        -- Link target suspect (the person being interrogated)
        local target_ref = df.general_ref_unit_interrogateest:new()
        target_ref.unit_id = suspect_unit.id
        job.general_refs:insert('#', target_ref)
        
        -- Link the job into the world properly so the engine manages it
        dfhack.job.linkIntoWorld(job, true)
        
        -- Assign the Captain to the job natively
        dfhack.job.addWorker(job, guard)
    end)
    
    if not ok then
        return false, tostring(err)
    end
    return true
end
local MONITOR_INTERVAL = 50 -- game ticks between checks (~2 seconds)
GLOBAL_SELECTED_SUSPECT_ID = GLOBAL_SELECTED_SUSPECT_ID or nil

-- ===========================
-- Helper: Fix Ghost Cases (Vanilla Bug)
-- ===========================
function fixGhostCases()
    if not df.global.world.crimes then return end
    local fixed_count = 0
    for _, crime in ipairs(df.global.world.crimes.all) do
        -- If it's an Open Case (needs_trial = true) but someone was convicted (accused_hf.hfid ~= -1)
        if crime.flags.needs_trial and crime.accused_hf and crime.accused_hf.hfid ~= -1 then
            -- It's a ghost case where the unit was garbage collected but the historical figure was remembered!
            crime.flags.needs_trial = false
            crime.flags.sentenced = true
            fixed_count = fixed_count + 1
        end
    end
    if fixed_count > 0 then
        dfhack.color(COLOR_GREEN)
        dfhack.println("CI-HQ: Auto-fixed " .. fixed_count .. " ghost case(s) where the convict left the map.")
        dfhack.color(COLOR_RESET)
    end
end

-- ===========================
-- Helper: Get Intrigue Data from Historical Figure
-- Reads the ACTUAL Fort Mode espionage structures from hf.info.relationships.intrigues
-- ===========================
function getHfIntrigueData(hf)
    local data = {
        has_intrigues = false,
        plot_count = 0,
        actor_count = 0,
        plots = {},        -- list of {type, on_hold, actor_count}
        actors = {},       -- list of {hf_id, role, strategy}
        is_villain = false,
    }
    if not hf or not hf.info or not hf.info.relationships then return data end
    local intrigues = hf.info.relationships.intrigues
    if not intrigues then return data end

    data.has_intrigues = true

    -- Gather plots
    if intrigues.plots then
        for _, plot in ipairs(intrigues.plots) do
            local plot_type_name = "Unknown"
            pcall(function() plot_type_name = df.intrigue_plot_type[plot.plot_type] or "Unknown" end)
            local actor_ids = {}
            if plot.plot_agreements then
                for _, pa in ipairs(plot.plot_agreements) do
                    table.insert(actor_ids, pa.actor_id)
                end
            end
            table.insert(data.plots, {
                type_name = plot_type_name,
                on_hold = plot.flags.on_hold,
                actor_ids = actor_ids,
            })
            data.plot_count = data.plot_count + 1
        end
    end

    -- Gather intrigue actors (the villain's perspective on other people)
    if intrigues.intrigue then
        for _, actor in ipairs(intrigues.intrigue) do
            local role_name = "Unknown"
            pcall(function() role_name = df.plot_role_type[actor.role] or "Unknown" end)
            local strategy_name = "Unknown"
            pcall(function() strategy_name = df.plot_strategy_type[actor.strategy] or "Unknown" end)
            table.insert(data.actors, {
                hf_1 = actor.hf_1,
                hf_2 = actor.hf_2,
                role_name = role_name,
                strategy_name = strategy_name,
                handle_actor_id = actor.handle_actor_id,
                active_plot_ids = actor.active_plot_id,
            })
            data.actor_count = data.actor_count + 1
        end
    end

    data.is_villain = (data.plot_count > 0 or data.actor_count > 0)
    return data
end

JusticeHQ = defclass(JusticeHQ, gui.ZScreen)
JusticeHQ.ATTRS = {
    focus_path = 'justice-hq',
}

function JusticeHQ:init()
    fixGhostCases()
    self.filter_level = 1
    self.suspects = self:gatherSuspects()
    self.selected_suspect = nil
    self.init_complete = false
    
    if GLOBAL_SELECTED_SUSPECT_ID then
        for _, s in ipairs(self.suspects) do
            if s.unit.id == GLOBAL_SELECTED_SUSPECT_ID then
                self.selected_suspect = s
                break
            end
        end
        if not self.selected_suspect then
            local u = df.unit.find(GLOBAL_SELECTED_SUSPECT_ID)
            if u then
                local race_name = "unknown"
                pcall(function()
                    local raw = df.creature_raw.find(u.race)
                    if raw then race_name = raw.name[0] end
                end)
                local gender = ""
                if u.sex == 0 then gender = string.char(12)
                elseif u.sex == 1 then gender = string.char(11)
                end
                local full_name = dfhack.units.getReadableName(u)
                local first_name = full_name:match("^(%S+)") or full_name
                
                local s = {
                    unit = u,
                    category = dfhack.units.isCitizen(u) and 'citizen' or (dfhack.units.isResident(u) and 'resident' or 'visitor'),
                    name = full_name,
                    first_name = first_name,
                    short_name = first_name .. " (" .. race_name .. ")",
                    prof = dfhack.units.getProfessionName(u),
                    race = race_name,
                    gender = gender,
                    threat = "Low",
                    reason_lines = {"No longer considered an active threat."},
                    crime_data = getUnitCrimeData(u)
                }
                table.insert(self.suspects, s)
                self.selected_suspect = s
            end
        end
    end

    self:addviews{
        widgets.Window{
            frame = {w = 90, h = 45},
            frame_title = 'Counter-Intelligence HQ',
            resizable = true,
            subviews = {
                -- Tab Bar
                widgets.TabBar{
                    frame = {t = 0, l = 0},
                    labels = {'Suspects', 'Cases', 'Convicts', 'Network', 'Case File'},
                    on_select = function(idx)
                        self.subviews.pages:setSelected(idx)
                        self:rebuildActiveTab()
                    end,
                    get_cur_page = function()
                        return self.subviews.pages:getSelected()
                    end,
                    key = 'CUSTOM_CTRL_T',
                },
                -- Pages
                widgets.Pages{
                    view_id = 'pages',
                    frame = {t = 3, l = 0, r = 0, b = 4},
                    subviews = {
                        -- PAGE 1: Suspect List (FilteredList, cards)
                        widgets.Panel{
                            frame = {t = 0, l = 0, r = 0, b = 0},
                            frame_style = gui.FRAME_INTERIOR,
                            frame_title = 'Ranked Suspects',
                            subviews = {
                                widgets.FilteredList{
                                    view_id = 'suspect_list',
                                    frame = {t = 0, l = 0, r = 0, b = 0},
                                    row_height = 3,
                                    choices = self:buildChoices(),
                                    on_select = self:callback('onSelectSuspect'),
                                    on_submit = self:callback('onOpenCaseFile'),
                                },
                            },
                        },
                        -- PAGE 2: Fortress Cases (FilteredList, cards)
                        widgets.Panel{
                            frame = {t = 0, l = 0, r = 0, b = 0},
                            frame_style = gui.FRAME_INTERIOR,
                            frame_title = 'Fortress Cases',
                            subviews = {
                                widgets.Label{
                                    frame = {t = 0, l = 1, r = 1, h = 1},
                                    text = {{text = 'Select a case and press Enter for dossier. Use [i][p][k] actions below.', pen = COLOR_DARKGREY}},
                                },
                                widgets.FilteredList{
                                    view_id = 'cases_list',
                                    frame = {t = 1, l = 0, r = 0, b = 0},
                                    row_height = 2,
                                    choices = self:buildCaseChoices(),
                                    on_select = self:callback('onSelectCase'),
                                    on_submit = self:callback('onSubmitCase'),
                                },
                            },
                        },
                        -- PAGE 3: Active Convicts (FilteredList, cards)
                        widgets.Panel{
                            frame = {t = 0, l = 0, r = 0, b = 0},
                            frame_style = gui.FRAME_INTERIOR,
                            frame_title = 'Active Convicts',
                            subviews = {
                                widgets.FilteredList{
                                    view_id = 'convicts_list',
                                    frame = {t = 0, l = 0, r = 0, b = 0},
                                    row_height = 2,
                                    choices = self:buildConvictChoices(),
                                    on_select = self:callback('onSelectConvict'),
                                    on_submit = self:callback('onSubmitConvict'),
                                },
                            },
                        },
                        -- PAGE 4: Network Map (grouped list)
                        widgets.Panel{
                            frame = {t = 0, l = 0, r = 0, b = 0},
                            frame_style = gui.FRAME_INTERIOR,
                            frame_title = 'Villain Networks & Cells',
                            subviews = {
                                widgets.Label{
                                    view_id = 'network_guidance',
                                    frame = {t = 0, l = 1, r = 1, h = 1},
                                    text = {{text = 'Select an actor and press Enter for dossier, or use actions below.', pen = COLOR_DARKGREY}},
                                },
                                widgets.List{
                                    view_id = 'network_list',
                                    frame = {t = 1, l = 0, r = 0, b = 0},
                                    choices = self:buildNetworkChoices(),
                                    on_select = self:callback('onSelectNetwork'),
                                    on_submit = self:callback('onSubmitNetwork'),
                                },
                            },
                        },
                        -- PAGE 5: Case File Dossier
                        widgets.Panel{
                            frame = {t = 0, l = 0, r = 0, b = 0},
                            frame_style = gui.FRAME_INTERIOR,
                            frame_title = 'Case File',
                            subviews = {
                                widgets.Label{
                                    view_id = 'case_file',
                                    frame = {t = 0, l = 1, r = 1},
                                    text = {{text = 'Select a suspect to view their dossier.', pen = COLOR_GREY}},
                                    auto_height = false,
                                },
                            },
                        },
                    },
                },
                -- Bottom Controls
                widgets.Panel{
                    frame = {b = 0, l = 0, r = 0, h = 4},
                    frame_background = gui.CLEAR_PEN,
                    frame_style = gui.FRAME_MEDIUM,
                    subviews = {
                        widgets.CycleHotkeyLabel{
                            view_id = 'filter_cycle',
                            frame = {l = 0, t = 0},
                            key = 'CUSTOM_F',
                            label = 'Show:',
                            options = {
                                {label = 'High threats', value = 1, pen = COLOR_RED},
                                {label = 'High + Medium', value = 2, pen = COLOR_YELLOW},
                                {label = 'All + Detained', value = 3, pen = COLOR_CYAN},
                                {label = 'Everyone', value = 4, pen = COLOR_GREEN},
                            },
                            initial_option = 1,
                            on_change = self:callback('onFilterChange'),
                            visible = function() return self.subviews.pages:getSelected() == 1 end,
                        },
                        widgets.CycleHotkeyLabel{
                            view_id = 'cases_filter_cycle',
                            frame = {l = 0, t = 0},
                            key = 'CUSTOM_F',
                            label = 'Show:',
                            options = {
                                {label = 'Open Cases', value = 1, pen = COLOR_LIGHTRED},
                                {label = 'Cold Cases', value = 2, pen = COLOR_CYAN},
                                {label = 'Closed Cases', value = 3, pen = COLOR_DARKGREY},
                                {label = 'All Cases', value = 4, pen = COLOR_GREEN},
                            },
                            initial_option = 1,
                            on_change = self:callback('onCasesFilterChange'),
                            visible = function() return self.subviews.pages:getSelected() == 2 end,
                        },
                        widgets.CycleHotkeyLabel{
                            view_id = 'convicts_filter',
                            frame = {l = 0, t = 0},
                            key = 'CUSTOM_F',
                            label = 'Show:',
                            options = {
                                {label = 'All Sentences', value = 1, pen = COLOR_WHITE},
                                {label = 'Prison Only', value = 2, pen = COLOR_CYAN},
                                {label = 'Beatings / Executions', value = 3, pen = COLOR_LIGHTRED},
                            },
                            initial_option = 1,
                            on_change = self:callback('onConvictsFilterChange'),
                            visible = function() return self.subviews.pages:getSelected() == 3 end,
                        },
                        -- SORTS
                        widgets.CycleHotkeyLabel{
                            view_id = 'suspect_sort',
                            frame = {l = 30, t = 0},
                            key = 'CUSTOM_S',
                            label = 'Sort:',
                            options = {
                                {label = 'Threat Level', value = 1, pen = COLOR_WHITE},
                                {label = 'Name', value = 2, pen = COLOR_WHITE},
                            },
                            initial_option = 1,
                            on_change = self:callback('onFilterChange'),
                            visible = function() return self.subviews.pages:getSelected() == 1 end,
                        },
                        widgets.CycleHotkeyLabel{
                            view_id = 'cases_sort',
                            frame = {l = 30, t = 0},
                            key = 'CUSTOM_S',
                            label = 'Sort:',
                            options = {
                                {label = 'Newest Cases', value = 1, pen = COLOR_WHITE},
                                {label = 'Crime Type', value = 2, pen = COLOR_WHITE},
                                {label = 'Accused Name', value = 3, pen = COLOR_WHITE},
                                {label = 'Victim Name', value = 4, pen = COLOR_WHITE},
                            },
                            initial_option = 1,
                            on_change = self:callback('onCasesFilterChange'),
                            visible = function() return self.subviews.pages:getSelected() == 2 end,
                        },
                        widgets.CycleHotkeyLabel{
                            view_id = 'convicts_sort',
                            frame = {l = 30, t = 0},
                            key = 'CUSTOM_S',
                            label = 'Sort:',
                            options = {
                                {label = 'Time Left', value = 1, pen = COLOR_WHITE},
                                {label = 'Name', value = 2, pen = COLOR_WHITE},
                            },
                            initial_option = 1,
                            on_change = self:callback('onConvictsFilterChange'),
                            visible = function() return self.subviews.pages:getSelected() == 3 end,
                        },
                        -- Network sort
                        widgets.CycleHotkeyLabel{
                            view_id = 'network_sort',
                            frame = {l = 0, t = 0},
                            key = 'CUSTOM_F',
                            label = 'Show:',
                            options = {
                                {label = 'All Networks', value = 1, pen = COLOR_WHITE},
                            },
                            initial_option = 1,
                            visible = function() return self.subviews.pages:getSelected() == 4 end,
                        },
                        widgets.CycleHotkeyLabel{
                            view_id = 'network_sort_cycle',
                            frame = {l = 30, t = 0, w = 28},
                            key = 'CUSTOM_S',
                            label = 'Sort:',
                            options = {
                                {label = 'Network Size', value = 1, pen = COLOR_WHITE},
                                {label = 'Mastermind Name', value = 2, pen = COLOR_WHITE},
                            },
                            initial_option = 1,
                            on_change = function() self:rebuildActiveTab() end,
                            visible = function() return self.subviews.pages:getSelected() == 4 end,
                        },
                        -- ACTIONS
                        widgets.HotkeyLabel{
                            frame = {l = 0, t = 1, w = 15},
                            key = 'CUSTOM_I',
                            label = 'Interrogate',
                            text_pen = COLOR_LIGHTGREEN,
                            disabled_pen = COLOR_DARKGREY,
                            disabled = false,
                            visible = true,
                            on_activate = self:callback('onInterrogate'),
                        },
                        widgets.HotkeyLabel{
                            frame = {l = 16, t = 1, w = 11},
                            key = 'CUSTOM_P',
                            label = 'Pardon',
                            text_pen = COLOR_LIGHTCYAN,
                            visible = true,
                            on_activate = self:callback('onPardon'),
                        },
                        widgets.HotkeyLabel{
                            frame = {l = 28, t = 1, w = 12},
                            key = 'CUSTOM_K',
                            label = 'Execute',
                            text_pen = COLOR_RED,
                            visible = true,
                            on_activate = self:callback('onExecute'),
                        },
                        widgets.HotkeyLabel{
                            frame = {l = 41, t = 1, w = 11},
                            key = 'CUSTOM_D',
                            label = 'Detain',
                            text_pen = COLOR_LIGHTMAGENTA,
                            visible = function()
                                if self.selected_suspect and self.selected_suspect.unit then
                                    return not self.selected_suspect.unit.flags1.chained
                                end
                                return true
                            end,
                            on_activate = self:callback('onDetain'),
                        },
                        widgets.HotkeyLabel{
                            frame = {l = 41, t = 1, w = 12},
                            key = 'CUSTOM_U',
                            label = 'Release',
                            text_pen = COLOR_LIGHTGREEN,
                            visible = function()
                                if self.selected_suspect and self.selected_suspect.unit then
                                    return self.selected_suspect.unit.flags1.chained
                                end
                                return false
                            end,
                            on_activate = self:callback('onRelease'),
                        },
                        widgets.HotkeyLabel{
                            frame = {l = 53, t = 1, w = 11},
                            key = 'CUSTOM_C',
                            label = 'Export',
                            text_pen = COLOR_GREY,
                            visible = true,
                            on_activate = self:callback('exportTabToFile'),
                        },
                        widgets.HotkeyLabel{
                            frame = {l = 65, t = 1, w = 16},
                            key = 'CUSTOM_CTRL_C',
                            label = 'Copy',
                            text_pen = COLOR_GREY,
                            visible = true,
                            on_activate = self:callback('copyTabToClipboard'),
                        },
                    },
                },
            },
        },
    }
    
    if self.selected_suspect then
        self.subviews.pages:setSelected(5)
        self:onOpenCaseFile(nil, {data = self.selected_suspect})
    else
        self.subviews.pages:setSelected(1)
    end
    self.init_complete = true
end

-- ===========================
-- Evidence Scoring
-- ===========================

function getCrimeName(mode)
    local manual_fallback = {
        [0] = "Murder", [1] = "Assault", [2] = "Blood Drinking", [3] = "Theft", 
        [4] = "Vandalism", [5] = "Battery", [6] = "Disorderly Conduct", 
        [7] = "Conspiracy", [8] = "Production Mandate Violation", 
        [9] = "Export Mandate Violation", [17] = "Treason / Artifact Theft"
    }
    if manual_fallback[mode] then return manual_fallback[mode] end

    local raw = df.crime_type and df.crime_type[mode]
    if raw then
        raw = string.gsub(raw, "_", " ")
        raw = string.gsub(raw, "(%a)([%w]*)", function(a,b) return string.upper(a)..string.lower(b) end)
        return raw
    end
    
    return "Unknown Crime (Type " .. tostring(mode) .. ")"
end

function JusticeHQ:buildEvidence(s)
    local evidence = {}
    local score = 0

    -- 1. Intrigue perspective (Fort Mode espionage data)
    local hf = df.historical_figure.find(s.unit.hist_figure_id)
    local idata = hf and getHfIntrigueData(hf)
    if hf then
        if idata and idata.is_villain then
            -- Score active plots
            for _, plot in ipairs(idata.plots) do
                if not plot.on_hold then
                    local pts = 100
                    score = score + pts
                    table.insert(evidence, {
                        text = "Active plot: " .. plot.type_name:gsub("_", " "),
                        detail = "This person is actively running an espionage operation against your fortress.",
                        pts = pts, color = COLOR_LIGHTRED,
                    })
                else
                    local pts = 20
                    score = score + pts
                    table.insert(evidence, {
                        text = "Plot on hold: " .. plot.type_name:gsub("_", " "),
                        detail = "A dormant plot that could reactivate at any time.",
                        pts = pts, color = COLOR_YELLOW,
                    })
                end
            end
            -- Score network size
            if idata.actor_count > 0 then
                local pts = math.min(idata.actor_count * 10, 50)
                score = score + pts
                table.insert(evidence, {
                    text = "Maintains intelligence network (" .. idata.actor_count .. " actors)",
                    detail = "This person coordinates other agents operating in your fortress.",
                    pts = pts, color = COLOR_YELLOW,
                })
            end
        end
    end

    -- 2. Crime accusations
    if s.crime_data and s.crime_data.times_accused > 0 then
        for _, crime in ipairs(s.crime_data.crimes_list) do
            local crime_name = getCrimeName(crime.mode)
            local pts = 0
            local color = COLOR_YELLOW
            local status_text = ""
            
            -- High severity crimes
            if crime_name == "Murder" or crime_name == "Treason" or crime_name == "Espionage" or crime_name == "Theft" then
                pts = 50
                color = COLOR_LIGHTRED
            else
                -- Vandalism, Production Order, etc.
                pts = 5
                color = COLOR_YELLOW
            end
            
            -- Case Status Modifiers
            if crime.flags.sentenced then
                status_text = " [Closed/Sentenced]"
                pts = 0
                color = COLOR_DARKGRAY
            elseif crime.flags.needs_trial then
                status_text = " [Open Case]"
                pts = pts + 50
                color = COLOR_LIGHTRED
            elseif crime.flags.discovered then
                status_text = " [Cold Case]"
                pts = pts + 20
            end
            
            score = score + pts
            local detail = nil
            if crime.flags.needs_trial then
                detail = "An active criminal investigation — this person is a suspect."
            elseif crime.flags.sentenced then
                detail = "Case closed. Sentence has been served or is in progress."
            end
            table.insert(evidence, {
                text = crime_name .. status_text,
                detail = detail,
                pts = pts, color = color,
            })
        end
    end
    if s.crime_data and s.crime_data.times_convicted > 0 then
        local pts = s.crime_data.times_convicted * 5
        score = score + pts
        table.insert(evidence, {
            text = "Convicted of " .. s.crime_data.times_convicted .. " crime(s)",
            pts = pts, color = COLOR_LIGHTRED,
        })
    end

    -- 3. Non-citizen status
    if s.category == 'visitor' then
        local pts = 15
        score = score + pts
        table.insert(evidence, {
            text = "Non-citizen: Visiting the fortress",
            detail = "Foreign nationals cannot be sentenced through normal dwarven justice.",
            pts = pts, color = COLOR_LIGHTCYAN,
        })
    elseif s.category == 'resident' then
        local pts = 5
        score = score + pts
        table.insert(evidence, {
            text = "Non-citizen: Resident",
            detail = "Long-term foreign resident. May have limited justice coverage.",
            pts = pts, color = COLOR_CYAN,
        })
    end

    -- 4. Risky profession
    local risky_profs = {THIEF=true, MASTER_THIEF=true, CRIMINAL=true}
    pcall(function()
        if risky_profs[df.profession[s.unit.profession]] then
            local pts = 20
            score = score + pts
            table.insert(evidence, {
                text = "Risky profession: " .. s.prof,
                pts = pts, color = COLOR_LIGHTRED,
            })
        end
    end)

    -- ===========================
    -- MITIGATING FACTORS (negative points)
    -- ===========================

    -- 5. Long-term resident / citizen loyalty
    if s.category == 'citizen' then
        local years_in_fort = 0
        pcall(function()
            if s.unit.birth_year > 0 then
                years_in_fort = df.global.cur_year - s.unit.birth_year
            end
        end)
        if years_in_fort > 20 then
            local pts = -15
            score = score + pts
            table.insert(evidence, {
                text = "Long-serving citizen (" .. years_in_fort .. " years)",
                pts = pts, color = COLOR_GREEN,
            })
        end
    end

    -- 6. No active plots (intrigue perspective exists but all plots on hold or none)
    if idata then
        if idata.has_intrigues and idata.plot_count == 0 and idata.actor_count == 0 then
            local pts = -20
            score = score + pts
            table.insert(evidence, {
                text = "No active plots detected",
                pts = pts, color = COLOR_GREEN,
            })
        end
    end

    -- 7. Custody status (reduces urgency)
    if s.crime_data then
        if s.crime_data.is_caged then
            local pts = -30
            score = score + pts
            table.insert(evidence, {
                text = "Currently CAGED (secured)",
                detail = "Secured in a cage — not an immediate escape risk.",
                pts = pts, color = COLOR_GREEN,
            })
        elseif s.crime_data.is_chained then
            local pts = -20
            score = score + pts
            table.insert(evidence, {
                text = "Currently CHAINED (secured)",
                detail = "Restrained at a chain — limited movement.",
                pts = pts, color = COLOR_GREEN,
            })
        end
    end

    -- 8. Currently serving sentence (already being punished)
    local serving_sentence = false
    for _, punishment in ipairs(df.global.plotinfo.punishments) do
        if punishment.criminal == s.unit.id then
            if punishment.prison_counter > 0 or punishment.beating > 0 or punishment.hammer_strikes > 0 then
                serving_sentence = true
                break
            end
        end
    end
    if serving_sentence then
        local pts = -25
        score = score + pts
        table.insert(evidence, {
            text = "Currently serving sentence (contained)",
            pts = pts, color = COLOR_GREEN,
        })
    end

    -- 9. Interrogation outcome modifiers
    local watch = interrogation_watchlist[s.unit.id]
    if watch then
        if watch.status == 'active' or watch.status == 'dispatched' then
            table.insert(evidence, {
                text = "Interrogation dispatched. Awaiting report.",
                detail = "Captain of the Guard is en route or currently interrogating.",
                pts = 0, color = COLOR_LIGHTGREEN,
            })
        elseif watch.status == 'confessed' then
            local pts = -50
            score = score + pts
            table.insert(evidence, {
                text = "CONFESSED — intelligence extracted",
                detail = "The suspect broke under interrogation and revealed information.",
                pts = pts, color = COLOR_GREEN,
            })
        elseif watch.status == 'concluded' then
            local pts = 10
            score = score + pts
            table.insert(evidence, {
                text = "SUSPECT RESISTED " .. (watch.retries or '?') .. " interrogation(s)",
                detail = "Subject withstood all interrogation attempts without revealing information.",
                pts = pts, color = COLOR_YELLOW,
            })
        end
    end

    -- 10. Game-native interrogation history (from Justice > Intelligence tab)
    if hf then
        local interrogation_count = INTERROGATION_HISTORY_CACHE and INTERROGATION_HISTORY_CACHE[hf.id] or 0
        if interrogation_count > 0 then
            local pts = -10 * interrogation_count
            score = score + pts
            table.insert(evidence, {
                text = "Interrogated " .. interrogation_count .. "x by fortress guard",
                pts = pts, color = COLOR_GREEN,
            })
        end
    end

    -- Sort evidence by points (highest first)
    table.sort(evidence, function(a, b) return a.pts > b.pts end)

    return evidence, score
end

-- ===========================
-- Build ranked suspect list
-- ===========================

function JusticeHQ:buildChoices()
    local list_choices = {}

    -- Score and rank all suspects
    local scored = {}
    for _, s in ipairs(self.suspects) do
        if not s.evidence then
            local evidence, score = self:buildEvidence(s)
            s.evidence = evidence
            s.score = score
        end
        table.insert(scored, s)
    end

    -- Sort
    local sort_mode = self.subviews.suspect_sort and self.subviews.suspect_sort:getOptionValue() or 1
    if sort_mode == 1 then
        table.sort(scored, function(a, b) return a.score > b.score end)
    elseif sort_mode == 2 then
        table.sort(scored, function(a, b) return a.first_name < b.first_name end)
    end

    local rank = 0
    for _, s in ipairs(scored) do
        -- Apply filter
        local show = false
        local detained = s.crime_data and (s.crime_data.is_caged or s.crime_data.is_chained)
        if self.filter_level == 1 and s.threat == 'High' and not detained then show = true end
        if self.filter_level == 2 and (s.threat == 'High' or s.threat == 'Medium') and not detained then show = true end
        if self.filter_level == 3 and (s.threat == 'High' or s.threat == 'Medium') then show = true end
        if self.filter_level == 4 then show = true end

        if show then
            rank = rank + 1

            local threat_color = COLOR_DARKGREY
            if s.threat == 'High' then threat_color = COLOR_LIGHTRED
            elseif s.threat == 'Medium' then threat_color = COLOR_YELLOW end
            
            local cat_badge = string.upper(s.category)
            local badge_color = COLOR_DARKGREY
            if s.category == 'visitor' then badge_color = COLOR_LIGHTCYAN
            elseif s.category == 'resident' then badge_color = COLOR_CYAN end
            
            -- Network info
            local hf = df.historical_figure.find(s.unit.hist_figure_id)
            local cell_str = ""
            local idata = hf and getHfIntrigueData(hf)
            if idata and idata.is_villain then
                if idata.plot_count > 0 then
                    cell_str = "Plots: " .. idata.plot_count
                elseif idata.actor_count > 0 then
                    cell_str = "Actors: " .. idata.actor_count
                end
            end
            
            -- Extract most dangerous strategy against any target
            local top_strategy = ""
            if idata and idata.is_villain and #idata.actors > 0 then
                local priority = {Assassinate=3, Corrupt=2, Obey=1}
                local best = 0
                for _, actor in ipairs(idata.actors) do
                    local strat = actor.strategy_name:gsub("_", " ")
                    if (priority[strat] or 0) > best then
                        best = priority[strat] or 0
                        top_strategy = strat
                    end
                end
            end
            
            -- Crimes summary
            local crimes_summary = "No crimes on file"
            if s.crime_data and #s.crime_data.crimes_list > 0 then
                local t = {}
                for i, c in ipairs(s.crime_data.crimes_list) do
                    if i <= 2 then table.insert(t, getCrimeName(c.mode)) end
                end
                crimes_summary = table.concat(t, ", ")
                if #s.crime_data.crimes_list > 2 then crimes_summary = crimes_summary .. " (+" .. (#s.crime_data.crimes_list - 2) .. ")" end
            end
            
            -- Append earliest crime date if available
            local earliest_year = nil
            if s.crime_data and s.crime_data.crimes_list then
                for _, crime in ipairs(s.crime_data.crimes_list) do
                    if crime.event_year > 0 then
                        if not earliest_year or crime.event_year < earliest_year then
                            earliest_year = crime.event_year
                        end
                    end
                end
            end

            local text_arr = {
                {text = " " .. string.char(30) .. " ", pen = threat_color},
                {text = string.format("%-40s", s.first_name .. ", " .. s.prof), pen = COLOR_WHITE},
                {text = string.format("%2s  ", s.gender), pen = COLOR_GREY},
                {text = cat_badge, pen = badge_color},
                NEWLINE,
                {text = "   Threat: ", pen = COLOR_GREY},
                {text = string.upper(s.threat), pen = threat_color},
                {text = string.format(" [%d pts]                     ", s.score), pen = COLOR_GREY},
                {text = (earliest_year and ("Y." .. earliest_year) or ""), pen = COLOR_GREY},
                NEWLINE,
                {text = string.format("   %-35s", crimes_summary), pen = COLOR_DARKGREY},
                {text = top_strategy ~= "" and top_strategy or "", pen = top_strategy == "Assassinate" and COLOR_LIGHTRED or COLOR_YELLOW},
                {text = cell_str ~= "" and ("  " .. cell_str) or "", pen = COLOR_DARKGREY},
            }
            local searchable = string.lower(s.name .. " " .. s.prof .. " " .. crimes_summary)
            table.insert(list_choices, {
                text = text_arr,
                search_key = searchable,
                data = s,
            })
        end
    end

    if #list_choices == 0 then
        table.insert(list_choices, {
            text = {{text = "  No threats at this filter level.", pen = COLOR_GREY}},
            search_key = "",
            data = nil,
        })
    end
    return list_choices
end

function JusticeHQ:onFilterChange(new_val)
    self.filter_level = new_val
    local list = self.subviews.suspect_list
    list:setChoices(self:buildChoices())
    local choices = list:getChoices()
    if #choices > 0 then
        self:onSelectSuspect(list:getSelected(), choices[list:getSelected()])
    end
end

function JusticeHQ:onCasesFilterChange(new_val)
    if new_val then self.case_filter_level = new_val end
    local list = self.subviews.cases_list
    list:setChoices(self:buildCaseChoices())
end

function JusticeHQ:onConvictsFilterChange(new_val)
    if new_val then self.convict_filter_level = new_val end
    local list = self.subviews.convicts_list
    if list then
        list:setChoices(self:buildConvictChoices())
    end
end

function JusticeHQ:onSearchChange(text)
    -- Remove manual search logic; FilteredList handles it natively.
end

function JusticeHQ:rebuildActiveTab()
    local page = self.subviews.pages:getSelected()
    if page == 1 then
        self.subviews.suspect_list:setChoices(self:buildChoices())
    elseif page == 2 then
        self.subviews.cases_list:setChoices(self:buildCaseChoices())
    elseif page == 3 then
        self.subviews.convicts_list:setChoices(self:buildConvictChoices())
    elseif page == 4 then
        self.subviews.network_list:setChoices(self:buildNetworkChoices())
    end
end

-- ===========================
-- Build Fortress Cases List
-- ===========================

function JusticeHQ:buildCaseChoices()
    local list_choices = {}
    local filter = self.case_filter_level or 1
    
    local cases_data = {}
    
    for _, crime in ipairs(df.global.world.crimes.all) do
        local is_open = crime.flags.needs_trial
        local is_cold = crime.flags.discovered and not crime.flags.needs_trial and not crime.flags.sentenced
        local is_closed = crime.flags.sentenced
        
        local show = false
        if filter == 1 and is_open then show = true end
        if filter == 2 and is_cold then show = true end
        if filter == 3 and is_closed then show = true end
        if filter == 4 then show = true end
        
        if show then
            local crime_name = getCrimeName(crime.mode)
            
            local status = ""
            local color = COLOR_WHITE
            if is_open then status = "[OPEN]"; color = COLOR_LIGHTRED
            elseif is_cold then status = "[COLD]"; color = COLOR_CYAN
            elseif is_closed then status = "[CLOSED]"; color = COLOR_DARKGREY
            end
            
            local details = {}
            local accused_name = "Unknown"
            if crime.accused ~= -1 then
                local hf = df.historical_figure.find(crime.accused)
                if hf then 
                    accused_name = dfhack.units.getReadableName(hf)
                    table.insert(details, "Accused: " .. accused_name)
                end
            end
            
            local victim_name = "Unknown"
            if crime.victim ~= -1 then
                local hf = df.historical_figure.find(crime.victim)
                if hf then 
                    victim_name = dfhack.units.getReadableName(hf)
                    table.insert(details, "Victim: " .. victim_name)
                end
            end
            
            local detail_str = ""
            if #details > 0 then
                detail_str = table.concat(details, "   ")
            end
            
            local crime_date = dfDateString(crime.event_year, crime.event_time)
            
            local text_arr = {
                {text = " " .. string.format("%-8s", status), pen = color},
                {text = string.format("%-45s", crime_name), pen = COLOR_WHITE},
                {text = crime_date, pen = COLOR_GREY},
                NEWLINE,
                {text = "         "},
                {text = detail_str, pen = COLOR_DARKGREY},
            }
            local searchable = string.lower(crime_name .. " " .. accused_name .. " " .. victim_name)
            
            table.insert(cases_data, {
                crime = crime,
                crime_name = crime_name,
                accused_name = accused_name,
                victim_name = victim_name,
                display_arr = text_arr,
                searchable = searchable,
            })
        end
    end
    
    -- Sort
    local sort_mode = self.subviews.cases_sort and self.subviews.cases_sort:getOptionValue() or 1
    if sort_mode == 1 then
        -- Newest Cases (descending id)
        table.sort(cases_data, function(a, b) return a.crime.id > b.crime.id end)
    elseif sort_mode == 2 then
        table.sort(cases_data, function(a, b) return a.crime_name < b.crime_name end)
    elseif sort_mode == 3 then
        table.sort(cases_data, function(a, b) return a.accused_name < b.accused_name end)
    elseif sort_mode == 4 then
        table.sort(cases_data, function(a, b) return a.victim_name < b.victim_name end)
    end
    
    for _, c in ipairs(cases_data) do
        table.insert(list_choices, {
            text = c.display_arr,
            search_key = c.searchable,
            data = c.crime,
        })
    end
    
    if #list_choices == 0 then
        table.insert(list_choices, {
            text = {{text = "  No cases at this filter level.", pen = COLOR_GREY}},
            search_key = "",
            data = nil,
        })
    end
    return list_choices
end

-- ===========================
-- Build Active Convicts List
-- ===========================

function JusticeHQ:buildConvictChoices()
    local list_choices = {}
    
    local TICKS_PER_SEASON_TICK = 10
    local TICKS_PER_DAY = 1200
    local filter = self.convict_filter_level or 1
    
    local convicts_data = {}
    
    for _, punishment in ipairs(df.global.plotinfo.punishments) do
        local unit = df.unit.find(punishment.criminal)
        if unit then
            local is_active = (punishment.prison_counter > 0) or (punishment.beating > 0) or (punishment.hammer_strikes > 0)
            
            -- Filter logic
            local show = false
            if filter == 1 and is_active then show = true end
            if filter == 2 and punishment.prison_counter > 0 then show = true end
            if filter == 3 and (punishment.beating > 0 or punishment.hammer_strikes > 0) then show = true end
            
            if show then
                local days = math.ceil((punishment.prison_counter * TICKS_PER_SEASON_TICK) / TICKS_PER_DAY)
                local name = dfhack.units.getReadableName(unit)
                
                local sentence_str = ""
                if punishment.prison_counter > 0 then sentence_str = sentence_str .. days .. " days in prison. " end
                if punishment.beating > 0 then sentence_str = sentence_str .. punishment.beating .. " beatings pending. " end
                if punishment.hammer_strikes > 0 then sentence_str = sentence_str .. punishment.hammer_strikes .. " hammer strikes pending. " end
                
                -- Find most recent crime date for this convict
                local crime_date_str = ""
                for _, crime in ipairs(df.global.world.crimes.all) do
                    if crime.criminal == unit.id or crime.accused == unit.id then
                        crime_date_str = dfDateString(crime.event_year, crime.event_time)
                    end
                end
                if crime_date_str ~= "" then
                    crime_date_str = " [" .. crime_date_str .. "]"
                end
                
                local display = string.format("%-25s | %s%s", name, sentence_str, crime_date_str)
                
                local race_name = "unknown"
                pcall(function()
                    local raw = df.creature_raw.find(unit.race)
                    if raw then race_name = raw.name[0] end
                end)
                local gender = ""
                if unit.sex == 0 then gender = string.char(12)
                elseif unit.sex == 1 then gender = string.char(11)
                end
                
                -- Fake suspect wrapper so 'onSelectSuspect' handles it properly
                local suspect_data = {
                    unit = unit,
                    first_name = name,
                    name = name,
                    short_name = name,
                    prof = dfhack.units.getProfessionName(unit),
                    race = race_name,
                    gender = gender,
                    threat = "Medium",
                    reason_lines = {"Serving sentence."},
                    category = dfhack.units.isCitizen(unit) and "citizen" or "visitor",
                    evidence = {{text = "Serving Sentence: " .. sentence_str, pts = 0, color = COLOR_LIGHTRED}},
                    score = 0,
                    crime_data = getUnitCrimeData(unit)
                }
                
                local cat_badge = string.upper(suspect_data.category)
                local badge_color = COLOR_DARKGREY
                if suspect_data.category == 'visitor' then badge_color = COLOR_LIGHTCYAN
                elseif suspect_data.category == 'resident' then badge_color = COLOR_CYAN end
                
                local text_arr = {
                    {text = string.format(" %-40s", name), pen = COLOR_WHITE},
                    {text = "  ", pen = COLOR_GREY},
                    {text = cat_badge, pen = badge_color},
                    NEWLINE,
                    {text = " " .. string.char(23) .. " ", pen = COLOR_YELLOW},
                    {text = string.format("%-45s", sentence_str), pen = COLOR_LIGHTRED},
                    {text = crime_date_str, pen = COLOR_DARKGREY},
                }
                local searchable = string.lower(name .. " " .. suspect_data.prof)

                table.insert(convicts_data, {
                    display_arr = text_arr,
                    searchable = searchable,
                    suspect_data = suspect_data,
                    raw_punishment = punishment,
                    days = days,
                    name = name,
                })
            end
        end
    end
    
    -- Sort
    local sort_mode = self.subviews.convicts_sort and self.subviews.convicts_sort:getOptionValue() or 1
    if sort_mode == 1 then
        -- Time Left descending
        table.sort(convicts_data, function(a, b) return a.days > b.days end)
    elseif sort_mode == 2 then
        table.sort(convicts_data, function(a, b) return a.name < b.name end)
    end
    
    for _, c in ipairs(convicts_data) do
        table.insert(list_choices, {
            text = c.display_arr,
            search_key = c.searchable,
            data = c.suspect_data,
            raw_punishment = c.raw_punishment
        })
    end
    
    if #list_choices == 0 then
        table.insert(list_choices, {
            text = {{text = "  No convicts currently serving sentences.", pen = COLOR_GREY}},
            search_key = "",
            data = nil,
        })
    end
    return list_choices
end

-- ===========================
-- Person of Interest: Algorithm
-- Uses only verified data: suspect.score, interrogation_watchlist, INTERROGATION_HISTORY_CACHE
-- ===========================

function JusticeHQ:calculatePOI()
    if not self.suspects or #self.suspects == 0 then return nil end
    
    -- Build hf_id -> suspect lookup for cross-referencing
    local hf_to_suspect = {}
    for _, s in ipairs(self.suspects) do
        if s.unit.hist_figure_id ~= -1 then
            hf_to_suspect[s.unit.hist_figure_id] = s
        end
    end
    
    -- Phase 1: Score all active suspects
    local poi_scores = {}  -- suspect -> adjusted score
    for _, s in ipairs(self.suspects) do
        if dfhack.units.isDead(s.unit) then goto skip_poi end
        
        local score = s.score or 0
        
        -- Penalize already confessed (from CI-HQ watchlist)
        local watch = interrogation_watchlist[s.unit.id]
        if watch then
            if watch.status == 'confessed' then
                score = score - 500
            elseif watch.status == 'active' or watch.status == 'dispatched' then
                score = score - 100
            elseif watch.status == 'concluded' then
                score = score - 200
            end
        end
        
        -- Penalize already-interrogated by game history
        local hf = df.historical_figure.find(s.unit.hist_figure_id)
        if hf and INTERROGATION_HISTORY_CACHE and INTERROGATION_HISTORY_CACHE[hf.id] then
            score = score - (INTERROGATION_HISTORY_CACHE[hf.id] * 50)
        end
        
        poi_scores[s] = score
        ::skip_poi::
    end
    
    -- Phase 2: Scan convicted villain networks
    -- Find masterminds who are sentenced but whose actors are still active suspects
    local seen_criminals = {}
    for _, crime in ipairs(df.global.world.crimes.all) do
        if crime.flags.sentenced and crime.criminal ~= -1 and not seen_criminals[crime.criminal] then
            seen_criminals[crime.criminal] = true
            local cunit = df.unit.find(crime.criminal)
            if cunit and cunit.hist_figure_id ~= -1 then
                local chf = df.historical_figure.find(cunit.hist_figure_id)
                if chf then
                    local cidata = getHfIntrigueData(chf)
                    if cidata.is_villain and cidata.actor_count > 0 then
                        local mname = dfhack.units.getReadableName(cunit)
                        -- Determine mastermind status
                        local mstatus = "CONVICTED"
                        if dfhack.units.isDead(cunit) then
                            mstatus = "DEAD"
                        elseif cunit.flags1.caged then
                            mstatus = "CONVICTED/CAGED"
                        end
                        -- Check if any of this mastermind's actors are active suspects
                        for _, actor in ipairs(cidata.actors) do
                            local actor_suspect = hf_to_suspect[actor.hf_1]
                            if actor_suspect and poi_scores[actor_suspect] then
                                -- Boost this suspect: they're part of a convicted villain's network
                                poi_scores[actor_suspect] = poi_scores[actor_suspect] + 200
                                -- Tag with mastermind context (keep the highest-scoring mastermind)
                                if not actor_suspect.mastermind_name or not actor_suspect._mastermind_score
                                   or cidata.plot_count > (actor_suspect._mastermind_score or 0) then
                                    actor_suspect.mastermind_name = mname
                                    actor_suspect.mastermind_status = mstatus
                                    actor_suspect._mastermind_score = cidata.plot_count
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    
    -- Phase 3: Pick the best POI
    local best_poi = nil
    local best_score = -9999
    for s, score in pairs(poi_scores) do
        if score > best_score then
            best_score = score
            best_poi = s
        end
    end
    
    -- Only recommend if the POI has a meaningful positive score
    if best_poi and best_score > 0 then
        return best_poi
    end
    return nil
end

-- ===========================
-- Person of Interest: Card Builder
-- Renders the POI section at the top of the Network tab
-- ===========================

function JusticeHQ:buildPOICard(poi)
    local choices = {}
    if not poi then return choices end
    
    -- Investigation status from CI-HQ watchlist
    local watch = interrogation_watchlist[poi.unit.id]
    local status_text = "NOT YET INVESTIGATED"
    local status_color = COLOR_YELLOW
    local rec_text = "Press [i] to begin interrogation"
    local rec_color = COLOR_LIGHTGREEN
    
    if watch then
        if watch.status == 'active' or watch.status == 'dispatched' then
            status_text = "INTERROGATION IN PROGRESS"
            status_color = COLOR_LIGHTGREEN
            rec_text = "Captain dispatched. Awaiting results."
            rec_color = COLOR_DARKGREY
        elseif watch.status == 'confessed' then
            status_text = "CONFESSED"
            status_color = COLOR_GREEN
            rec_text = "Intel extracted. Press [k] to execute or [p] to pardon."
            rec_color = COLOR_CYAN
        elseif watch.status == 'concluded' then
            status_text = "CONCLUDED"
            status_color = COLOR_CYAN
            rec_text = "Investigation complete."
            rec_color = COLOR_DARKGREY
        end
    end
    
    -- Check implicated count from game history events
    local hf = df.historical_figure.find(poi.unit.hist_figure_id)
    local implicated_count = 0
    if hf then
        local events = df.global.world.history.events
        for i = #events - 1, 0, -1 do
            local event = events[i]
            if event.year < df.global.cur_year - 5 then break end
            if df.history_event_hf_interrogatedst:is_instance(event) then
                if event.target_hf == hf.id then
                    implicated_count = implicated_count + #event.implicated_hfs
                end
            end
        end
    end
    if implicated_count > 0 and watch and watch.status == 'confessed' then
        rec_text = "IMPLICATED " .. implicated_count .. " associate(s)! Continue investigation."
        rec_color = COLOR_LIGHTRED
    end
    
    -- Intrigue summary
    local idata = hf and getHfIntrigueData(hf)
    local strategy_text = ""
    if idata and idata.is_villain then
        -- Find the most dangerous strategy among actors
        local danger_map = {assassinate=3, corrupt=2, obey=1}
        local worst_strategy = ""
        local worst_rank = 0
        for _, actor in ipairs(idata.actors) do
            local sname = actor.strategy_name:lower()
            if danger_map[sname] and danger_map[sname] > worst_rank then
                worst_rank = danger_map[sname]
                worst_strategy = actor.strategy_name:gsub("_", " ")
            end
        end
        if worst_strategy ~= "" then
            strategy_text = "Strategy: " .. worst_strategy
        end
    end
    
    -- Category badge
    local cat_badge = string.upper(poi.category or "")
    local badge_color = COLOR_DARKGREY
    if poi.category == 'visitor' then badge_color = COLOR_LIGHTCYAN
    elseif poi.category == 'resident' then badge_color = COLOR_CYAN end
    
    -- Threat display
    local threat_color = COLOR_DARKGREY
    if poi.threat == 'High' then threat_color = COLOR_LIGHTRED
    elseif poi.threat == 'Medium' then threat_color = COLOR_YELLOW end
    
    -- Build the card rows
    local border = string.char(205):rep(78)
    
    -- Top border
    table.insert(choices, {
        text = {{text = border, pen = COLOR_YELLOW}},
        data = poi,  -- Selectable: sets selected_suspect
    })
    
    -- Name row
    table.insert(choices, {
        text = {
            {text = " " .. string.char(15) .. " PERSON OF INTEREST: ", pen = COLOR_YELLOW},
            {text = poi.name, pen = COLOR_WHITE},
            {text = "  ", pen = COLOR_DARKGREY},
            {text = cat_badge, pen = badge_color},
        },
        data = poi,
    })
    
    -- Mastermind context row (Option C: convicted network link)
    if poi.mastermind_name then
        table.insert(choices, {
            text = {
                {text = "   Part of: ", pen = COLOR_DARKGREY},
                {text = poi.mastermind_name, pen = COLOR_LIGHTMAGENTA},
                {text = "'s network", pen = COLOR_DARKGREY},
                {text = "  (" .. (poi.mastermind_status or "CONVICTED") .. ")", pen = COLOR_LIGHTRED},
            },
            data = poi,
        })
    end
    
    -- Threat + Strategy row
    local threat_row = {
        {text = "   Threat: ", pen = COLOR_DARKGREY},
        {text = string.upper(poi.threat or "Unknown"), pen = threat_color},
        {text = "  [" .. (poi.score or 0) .. " pts]", pen = COLOR_DARKGREY},
    }
    if strategy_text ~= "" then
        table.insert(threat_row, {text = "  |  ", pen = COLOR_DARKGREY})
        table.insert(threat_row, {text = strategy_text, pen = COLOR_YELLOW})
    end
    table.insert(choices, {text = threat_row, data = poi})
    
    -- Status row
    table.insert(choices, {
        text = {
            {text = "   Status: ", pen = COLOR_DARKGREY},
            {text = status_text, pen = status_color},
        },
        data = poi,
    })
    
    -- Override recommendation for network-linked POI
    if poi.mastermind_name and (not watch or watch.status ~= 'confessed') then
        rec_text = "Interrogate to dismantle " .. poi.mastermind_name .. "'s network. Press [i]."
        rec_color = COLOR_LIGHTGREEN
    end
    
    -- Recommendation row
    table.insert(choices, {
        text = {
            {text = "   " .. string.char(16) .. " ", pen = COLOR_YELLOW},
            {text = rec_text, pen = rec_color},
        },
        data = poi,
    })
    
    -- Bottom border
    table.insert(choices, {
        text = {{text = border, pen = COLOR_YELLOW}},
        data = poi,
    })
    
    -- Spacer
    table.insert(choices, {text = NEWLINE, data = nil})
    
    return choices
end

-- ===========================
-- Build Network List
-- ===========================


function JusticeHQ:buildNetworkChoices()
    local list_choices = {}
    
    -- Person of Interest card at the top
    local poi = self:calculatePOI()
    local poi_card = self:buildPOICard(poi)
    for _, c in ipairs(poi_card) do
        table.insert(list_choices, c)
    end
    
    local villain_networks = {}  -- keyed by villain hf_id
    local unaffiliated = {}
    
    -- Build a lookup: hf_id -> suspect data
    local hf_to_suspect = {}
    for _, s in ipairs(self.suspects) do
        if s.unit.hist_figure_id ~= -1 then
            hf_to_suspect[s.unit.hist_figure_id] = s
        end
    end
    
    -- For each suspect, check if they have an intrigue perspective (meaning they ARE a villain/mastermind)
    for _, s in ipairs(self.suspects) do
        local hf = df.historical_figure.find(s.unit.hist_figure_id)
        if hf then
            local idata = getHfIntrigueData(hf)
            if idata.is_villain and (idata.plot_count > 0 or idata.actor_count > 0) then
                -- This suspect IS a villain mastermind with their own perspective
                local network = {
                    mastermind = s,
                    plots = idata.plots,
                    actors = idata.actors,
                    plot_count = idata.plot_count,
                }
                villain_networks[s.unit.hist_figure_id] = network
            else
                -- Check if this suspect appears as a target in another villain's network
                local found_in_network = false
                for _, other_s in ipairs(self.suspects) do
                    if other_s ~= s then
                        local other_hf = df.historical_figure.find(other_s.unit.hist_figure_id)
                        if other_hf then
                            local other_idata = getHfIntrigueData(other_hf)
                            for _, actor in ipairs(other_idata.actors) do
                                if actor.hf_1 == s.unit.hist_figure_id or actor.hf_2 == s.unit.hist_figure_id then
                                    found_in_network = true
                                    break
                                end
                            end
                        end
                        if found_in_network then break end
                    end
                end
                if not found_in_network then
                    table.insert(unaffiliated, s)
                end
            end
        end
    end
    
    -- Sort villain networks into an ordered list
    local sorted_networks = {}
    for hf_id, network in pairs(villain_networks) do
        table.insert(sorted_networks, network)
    end
    local sort_mode = self.subviews.network_sort_cycle and self.subviews.network_sort_cycle:getOptionValue() or 1
    if sort_mode == 1 then
        table.sort(sorted_networks, function(a, b) return #a.actors > #b.actors end)
    elseif sort_mode == 2 then
        table.sort(sorted_networks, function(a, b) return a.mastermind.first_name < b.mastermind.first_name end)
    end
    
    -- Render villain networks
    local net_idx = 0
    for _, network in ipairs(sorted_networks) do
        net_idx = net_idx + 1
        local plot_summary = network.plot_count > 0 and (network.plot_count .. " Active Plot(s)") or "No Active Plots"
        local header = string.format(" %s NETWORK #%d: %s %s %s ",
            string.char(196):rep(3),
            net_idx,
            network.mastermind.first_name,
            string.char(196):rep(3),
            plot_summary)
        if #header < 80 then header = header .. string.char(196):rep(80 - #header) end
        table.insert(list_choices, {
            text = {{text = header, pen = COLOR_LIGHTBLUE}},
            data = nil,
        })
        
        -- Show plots
        for _, plot in ipairs(network.plots) do
            local status = plot.on_hold and " [ON HOLD]" or " [ACTIVE]"
            local status_color = plot.on_hold and COLOR_DARKGREY or COLOR_LIGHTRED
            local plot_text = {
                {text = "   " .. string.char(16) .. " Plot: ", pen = COLOR_DARKGREY},
                {text = plot.type_name:gsub("_", " "), pen = COLOR_YELLOW},
                {text = status, pen = status_color},
            }
            table.insert(list_choices, {text = plot_text, data = nil, tooltip_info = {type = 'plot', plot_type = plot.type_name, on_hold = plot.on_hold}})
        end
        
        -- Show actors in this network
        for _, actor in ipairs(network.actors) do
            local target_name = "Unknown"
            local target_s = nil
            -- Try to resolve the actor to a known suspect
            if hf_to_suspect[actor.hf_1] then
                target_name = hf_to_suspect[actor.hf_1].first_name
                target_s = hf_to_suspect[actor.hf_1]
            elseif actor.hf_1 ~= -1 then
                local target_hf = df.historical_figure.find(actor.hf_1)
                if target_hf then
                    pcall(function() target_name = dfhack.units.getReadableName(df.unit.find(target_hf.unit_id)) end)
                    if target_name == "Unknown" then
                        pcall(function() target_name = dfhack.translation.translateName(target_hf.name) end)
                    end
                end
            end
            
            local role_display = actor.role_name:gsub("_", " ")
            local strategy_display = actor.strategy_name:gsub("_", " ")
            
            local cat_badge = ""
            local badge_color = COLOR_DARKGREY
            if target_s then
                cat_badge = string.upper(target_s.category)
                if target_s.category == 'visitor' then badge_color = COLOR_LIGHTCYAN
                elseif target_s.category == 'resident' then badge_color = COLOR_CYAN end
            end
            
            local text_arr = {
                {text = string.format("   %s %-30s", string.char(16), target_name), pen = COLOR_WHITE},
                {text = string.format("%-22s ", role_display), pen = COLOR_LIGHTRED},
                {text = cat_badge, pen = badge_color},
                NEWLINE,
                {text = string.format("       Strategy: %s", strategy_display), pen = COLOR_DARKGREY},
            }
            -- Investigation progress markers
            local marker_added = false
            if target_s then
                local watch = interrogation_watchlist[target_s.unit.id]
                if watch then
                    local status_tag = ""
                    local status_color = COLOR_DARKGREY
                    if watch.status == 'active' or watch.status == 'dispatched' then
                        status_tag = "  [INTERROGATING]"
                        status_color = COLOR_LIGHTGREEN
                    elseif watch.status == 'confessed' then
                        status_tag = "  [CONFESSED]"
                        status_color = COLOR_GREEN
                    elseif watch.status == 'concluded' then
                        status_tag = "  [CONCLUDED]"
                        status_color = COLOR_CYAN
                    end
                    if status_tag ~= "" then
                        table.insert(text_arr, {text = status_tag, pen = status_color})
                        marker_added = true
                    end
                elseif dfhack.units.isDead(target_s.unit) then
                    table.insert(text_arr, {text = "  [DEAD]", pen = COLOR_RED})
                    marker_added = true
                end
            end
            -- Fallback: check game-native interrogation history for actors not in watchlist
            if not marker_added then
                local check_hf_id = actor.hf_1 ~= -1 and actor.hf_1 or actor.hf_2
                if check_hf_id and check_hf_id ~= -1 and INTERROGATION_HISTORY_CACHE then
                    local icount = INTERROGATION_HISTORY_CACHE[check_hf_id]
                    if icount and icount > 0 then
                        table.insert(text_arr, {text = "  [INTERROGATED x" .. icount .. "]", pen = COLOR_GREY})
                    end
                end
            end
            table.insert(list_choices, {text = text_arr, data = target_s, tooltip_info = {type = 'actor', role = actor.role_name, strategy = actor.strategy_name}})
        end
        table.insert(list_choices, {text = NEWLINE, data = nil})
    end
    
    if #unaffiliated > 0 then
        local header = string.format(" %s UNAFFILIATED SUSPECTS %s", string.char(196):rep(3), string.char(196):rep(50))
        table.insert(list_choices, {text = {{text = header, pen = COLOR_LIGHTBLUE}}, data = nil})
        for _, s in ipairs(unaffiliated) do
            local cat_badge = string.upper(s.category)
            local badge_color = COLOR_DARKGREY
            if s.category == 'visitor' then badge_color = COLOR_LIGHTCYAN
            elseif s.category == 'resident' then badge_color = COLOR_CYAN end
            
            local crimes_summary = "No crimes on file"
            if s.crime_data and #s.crime_data.crimes_list > 0 then
                local t = {}
                for i, c in ipairs(s.crime_data.crimes_list) do
                    if i <= 2 then table.insert(t, getCrimeName(c.mode)) end
                end
                crimes_summary = table.concat(t, ", ")
                if #s.crime_data.crimes_list > 2 then crimes_summary = crimes_summary .. " (+" .. (#s.crime_data.crimes_list - 2) .. ")" end
            end
            
            local text_arr = {
                {text = string.format("   %-40s", s.first_name .. ", " .. s.prof), pen = COLOR_WHITE},
                {text = "           "},
                {text = cat_badge, pen = badge_color},
                NEWLINE,
                {text = string.format("       Crimes: %s", crimes_summary), pen = COLOR_DARKGREY},
            }
            table.insert(list_choices, {text = text_arr, data = s})
        end
    end
    
    if #list_choices == 0 then
        table.insert(list_choices, {
            text = {{text = "  No networks detected.", pen = COLOR_GREY}},
            data = nil,
        })
    end
    
    return list_choices
end

function JusticeHQ:onSelectSuspect(idx, choice)
    -- Don't let auto-select during init overwrite the saved suspect
    if not self.init_complete and GLOBAL_SELECTED_SUSPECT_ID then return end
    if not choice or not choice.data then
        self.selected_suspect = nil
        GLOBAL_SELECTED_SUSPECT_ID = nil
        return
    end
    self.selected_suspect = choice.data
    GLOBAL_SELECTED_SUSPECT_ID = choice.data.unit.id
end

function JusticeHQ:onSubmitSuspect(idx, choice)
    self:onSelectSuspect(idx, choice)
    if self.selected_suspect then
        self:onOpenCaseFile(idx, choice)
    end
end

function JusticeHQ:onSelectCase(idx, choice)
    -- Cases store a crime object in choice.data
    -- We try to find the accused unit and set them as selected_suspect
    if not choice or not choice.data then return end
    local crime = choice.data
    if crime.accused and crime.accused ~= -1 then
        local hf = df.historical_figure.find(crime.accused)
        if hf then
            -- Find the unit in the world
            for _, unit in ipairs(df.global.world.units.active) do
                if unit.hist_figure_id == hf.id then
                    -- Build a minimal suspect wrapper
                    self.selected_suspect = {
                        unit = unit,
                        first_name = dfhack.units.getReadableName(unit),
                        name = dfhack.units.getReadableName(unit),
                        prof = dfhack.units.getProfessionName(unit),
                        race = dfhack.units.getRaceName(unit),
                        gender = "",
                        threat = "Medium",
                        category = dfhack.units.isCitizen(unit) and "citizen" or "visitor",
                        score = 0,
                        crime_data = getUnitCrimeData(unit),
                    }
                    local evidence, score = self:buildEvidence(self.selected_suspect)
                    self.selected_suspect.evidence = evidence
                    self.selected_suspect.score = score
                    GLOBAL_SELECTED_SUSPECT_ID = self.selected_suspect.unit.id
                    return
                end
            end
        end
    end
end

function JusticeHQ:onSubmitCase(idx, choice)
    self:onSelectCase(idx, choice)
    if self.selected_suspect then
        self:onOpenCaseFile(idx, {data = self.selected_suspect})
    else
        dfhack.gui.showAnnouncement("CI-HQ: No accused found for this case. The suspect may have left the map.", COLOR_YELLOW)
    end
end

function JusticeHQ:onSelectConvict(idx, choice)
    if not self.init_complete and GLOBAL_SELECTED_SUSPECT_ID then return end
    if not choice or not choice.data then
        self.selected_suspect = nil
        GLOBAL_SELECTED_SUSPECT_ID = nil
        return
    end
    self.selected_suspect = choice.data
    GLOBAL_SELECTED_SUSPECT_ID = choice.data.unit.id
end

function JusticeHQ:onSubmitConvict(idx, choice)
    self:onSelectConvict(idx, choice)
    if self.selected_suspect then
        self:onOpenCaseFile(idx, choice)
    end
end

function JusticeHQ:onSelectNetwork(idx, choice)
    if not self.init_complete and GLOBAL_SELECTED_SUSPECT_ID then return end
    if not choice or not choice.data then
        self.selected_suspect = nil
        GLOBAL_SELECTED_SUSPECT_ID = nil
    else
        self.selected_suspect = choice.data
        GLOBAL_SELECTED_SUSPECT_ID = choice.data.unit.id
    end
    -- Dynamic tooltip: update guidance header based on selected row
    local guidance = self.subviews.network_guidance
    if guidance then
        local default_text = 'Select an actor and press Enter for dossier, or use actions below.'
        if choice and choice.tooltip_info then
            local info = choice.tooltip_info
            if info.type == 'plot' then
                local desc = PLOT_TOOLTIPS[info.plot_type]
                if desc then
                    local display_name = info.plot_type:gsub('_', ' ')
                    guidance:setText({{text = display_name .. ': ', pen = COLOR_YELLOW}, {text = desc, pen = COLOR_DARKGREY}})
                    return
                end
            elseif info.type == 'actor' then
                local role_desc = ROLE_TOOLTIPS[info.role]
                if role_desc then
                    local display_role = info.role:gsub('_', ' ')
                    guidance:setText({{text = display_role .. ': ', pen = COLOR_LIGHTRED}, {text = role_desc, pen = COLOR_DARKGREY}})
                    return
                end
            end
        end
        guidance:setText({{text = default_text, pen = COLOR_DARKGREY}})
    end
end

function JusticeHQ:onSubmitNetwork(idx, choice)
    if not choice or not choice.data then
        dfhack.gui.showAnnouncement("CI-HQ: Select a specific person, not a header or plot row.", COLOR_YELLOW)
        return
    end
    self.selected_suspect = choice.data
    self:onOpenCaseFile(idx, choice)
end

function JusticeHQ:onOpenCaseFile(idx, choice)
    if not choice or not choice.data then return end
    local s = choice.data

    -- Build case file text
    local lines = {}

    -- Header
    table.insert(lines, {text = "CASE FILE: ", pen = COLOR_LIGHTBLUE})
    table.insert(lines, {text = s.name, pen = COLOR_WHITE})
    table.insert(lines, NEWLINE)
    table.insert(lines, {text = s.prof, pen = COLOR_CYAN})
    table.insert(lines, {text = " | ", pen = COLOR_DARKGREY})
    table.insert(lines, {text = s.race, pen = COLOR_GREY})
    table.insert(lines, {text = " ", pen = COLOR_GREY})
    table.insert(lines, {text = s.gender, pen = COLOR_GREY})
    if s.category ~= 'citizen' then
        table.insert(lines, {text = " | ", pen = COLOR_DARKGREY})
        table.insert(lines, {text = string.upper(s.category), pen = COLOR_LIGHTCYAN})
    end
    table.insert(lines, NEWLINE)
    if s.category and s.category ~= 'citizen' then
        table.insert(lines, {text = string.char(16) .. " Foreign national — cannot be sentenced through normal justice.", pen = COLOR_YELLOW})
        table.insert(lines, NEWLINE)
        table.insert(lines, {text = "  Use [p] Pardon to release, or [k] Execute for permanent removal.", pen = COLOR_DARKGREY})
        table.insert(lines, NEWLINE)
    end

    -- Threat score
    table.insert(lines, NEWLINE)
    local threat_color = COLOR_DARKGREY
    if s.threat == 'High' then threat_color = COLOR_LIGHTRED
    elseif s.threat == 'Medium' then threat_color = COLOR_YELLOW end
    table.insert(lines, {text = "Threat Level: ", pen = COLOR_GREY})
    table.insert(lines, {text = string.upper(s.threat), pen = threat_color})
    table.insert(lines, {text = "  (Score: " .. s.score .. ")", pen = COLOR_GREY})
    table.insert(lines, NEWLINE)

    -- Network Connections (Intrigue Data)
    local hf = df.historical_figure.find(s.unit.hist_figure_id)
    if hf then
        local idata = getHfIntrigueData(hf)
        if idata.is_villain then
            table.insert(lines, NEWLINE)
            table.insert(lines, {text = string.char(196):rep(40), pen = COLOR_DARKGREY})
            table.insert(lines, NEWLINE)
            table.insert(lines, {text = "INTELLIGENCE NETWORK:", pen = COLOR_LIGHTBLUE})
            table.insert(lines, NEWLINE)
            
            -- Show plots
            if idata.plot_count > 0 then
                table.insert(lines, NEWLINE)
                table.insert(lines, {text = " Active Plots:", pen = COLOR_CYAN})
                table.insert(lines, NEWLINE)
                for _, plot in ipairs(idata.plots) do
                    local status = plot.on_hold and " [ON HOLD]" or " [ACTIVE]"
                    local status_color = plot.on_hold and COLOR_DARKGREY or COLOR_LIGHTRED
                    table.insert(lines, {text = " " .. string.char(16) .. " ", pen = COLOR_DARKGREY})
                    table.insert(lines, {text = plot.type_name:gsub("_", " "), pen = COLOR_YELLOW})
                    table.insert(lines, {text = status, pen = status_color})
                    table.insert(lines, NEWLINE)
                end
            end
            
            -- Show known actors
            if idata.actor_count > 0 then
                table.insert(lines, NEWLINE)
                table.insert(lines, {text = " Known Actors (" .. idata.actor_count .. "):", pen = COLOR_CYAN})
                table.insert(lines, NEWLINE)
                for _, actor in ipairs(idata.actors) do
                    local target_name = "Unknown"
                    if actor.hf_1 ~= -1 then
                        local target_hf = df.historical_figure.find(actor.hf_1)
                        if target_hf then
                            local target_unit = df.unit.find(target_hf.unit_id)
                            if target_unit then
                                pcall(function() target_name = dfhack.units.getReadableName(target_unit) end)
                            end
                            if target_name == "Unknown" then
                                pcall(function() target_name = dfhack.translation.translateName(target_hf.name) end)
                            end
                        end
                    end
                    local role_display = actor.role_name:gsub("_", " ")
                    local strategy_display = actor.strategy_name:gsub("_", " ")
                    table.insert(lines, {text = " " .. string.char(16) .. " ", pen = COLOR_DARKGREY})
                    table.insert(lines, {text = target_name, pen = COLOR_WHITE})
                    table.insert(lines, {text = " <" .. role_display .. ">", pen = COLOR_LIGHTRED})
                    table.insert(lines, NEWLINE)
                    table.insert(lines, {text = "   Strategy: ", pen = COLOR_DARKGREY})
                    table.insert(lines, {text = strategy_display, pen = COLOR_GREY})
                    table.insert(lines, NEWLINE)
                end
            end
        end
    end

    -- Chronological summary from crime records
    if s.crime_data and #s.crime_data.crimes_list > 0 then
        table.insert(lines, NEWLINE)
        table.insert(lines, {text = string.char(196):rep(40), pen = COLOR_DARKGREY})
        table.insert(lines, NEWLINE)
        table.insert(lines, {text = "CHRONOLOGY:", pen = COLOR_LIGHTBLUE})
        table.insert(lines, NEWLINE)
        table.insert(lines, NEWLINE)
        for _, crime in ipairs(s.crime_data.crimes_list) do
            local crime_name = getCrimeName(crime.mode)
            local committed = dfDateString(crime.event_year, crime.event_time)
            local discovered = dfDateString(crime.discovered_year, crime.discovered_time)
            table.insert(lines, {text = " " .. string.char(16) .. " ", pen = COLOR_DARKGREY})
            table.insert(lines, {text = crime_name, pen = COLOR_WHITE})
            table.insert(lines, NEWLINE)
            table.insert(lines, {text = "   Committed: ", pen = COLOR_DARKGREY})
            table.insert(lines, {text = committed, pen = COLOR_YELLOW})
            table.insert(lines, NEWLINE)
            table.insert(lines, {text = "   Discovered: ", pen = COLOR_DARKGREY})
            table.insert(lines, {text = discovered, pen = COLOR_CYAN})
            table.insert(lines, NEWLINE)
        end
    end

    -- Evidence
    table.insert(lines, NEWLINE)
    table.insert(lines, {text = string.char(196):rep(40), pen = COLOR_DARKGREY})
    table.insert(lines, NEWLINE)
    table.insert(lines, {text = "EVIDENCE:", pen = COLOR_LIGHTBLUE})
    table.insert(lines, NEWLINE)
    table.insert(lines, NEWLINE)

    if s.evidence and #s.evidence > 0 then
        for i, ev in ipairs(s.evidence) do
            local prefix = " " .. string.char(16) .. " "
            if ev.pts > 0 then
                prefix = prefix .. "[+" .. ev.pts .. "] "
            elseif ev.pts < 0 then
                prefix = prefix .. "[" .. ev.pts .. "] "
            else
                prefix = prefix .. "[---] "
            end
            table.insert(lines, {text = prefix, pen = COLOR_DARKGREY})
            table.insert(lines, {text = ev.text, pen = ev.color})
            table.insert(lines, NEWLINE)
            if ev.detail then
                table.insert(lines, {text = "       " .. ev.detail, pen = COLOR_DARKGREY})
                table.insert(lines, NEWLINE)
            end
        end
    else
        table.insert(lines, {text = "  No evidence on file.", pen = COLOR_DARKGREY})
        table.insert(lines, NEWLINE)
    end

    -- Witnesses
    local has_witnesses = false
    if s.crime_data and #s.crime_data.crimes_list > 0 then
        for _, crime in ipairs(s.crime_data.crimes_list) do
            pcall(function()
                if crime.witnesses and #crime.witnesses > 0 then
                    if not has_witnesses then
                        table.insert(lines, NEWLINE)
                        table.insert(lines, {text = string.char(196):rep(40), pen = COLOR_DARKGREY})
                        table.insert(lines, NEWLINE)
                        table.insert(lines, {text = "WITNESSES:", pen = COLOR_LIGHTBLUE})
                        table.insert(lines, NEWLINE)
                        has_witnesses = true
                    end
                    local crime_name = getCrimeName(crime.mode)
                    table.insert(lines, {text = " " .. string.char(16) .. " For " .. crime_name .. " (Y." .. crime.event_year .. "):", pen = COLOR_CYAN})
                    table.insert(lines, NEWLINE)
                    for _, w in ipairs(crime.witnesses) do
                        local w_name = "Witness report filed"
                        pcall(function()
                            if w.witness_id and w.witness_id ~= -1 then
                                local whf = df.historical_figure.find(w.witness_id)
                                if whf then w_name = dfhack.units.getReadableName(whf) end
                            elseif w.reporter and w.reporter ~= -1 then
                                local whf = df.historical_figure.find(w.reporter)
                                if whf then w_name = dfhack.units.getReadableName(whf) end
                            end
                        end)
                        table.insert(lines, {text = "     - ", pen = COLOR_DARKGREY})
                        table.insert(lines, {text = w_name, pen = COLOR_WHITE})
                        table.insert(lines, NEWLINE)
                    end
                end
            end)
        end
    end

    -- Sentence / Conviction status
    local has_sentence = false
    for _, punishment in ipairs(df.global.plotinfo.punishments) do
        if punishment.criminal == s.unit.id then
            local is_active = (punishment.prison_counter > 0) or (punishment.beating > 0) or (punishment.hammer_strikes > 0)
            if is_active then
                if not has_sentence then
                    table.insert(lines, NEWLINE)
                    table.insert(lines, {text = string.char(196):rep(40), pen = COLOR_DARKGREY})
                    table.insert(lines, NEWLINE)
                    table.insert(lines, {text = "SENTENCE STATUS:", pen = COLOR_LIGHTBLUE})
                    table.insert(lines, NEWLINE)
                    has_sentence = true
                end
                local TICKS_PER_SEASON_TICK = 10
                local TICKS_PER_DAY = 1200
                if punishment.prison_counter > 0 then
                    local days = math.ceil((punishment.prison_counter * TICKS_PER_SEASON_TICK) / TICKS_PER_DAY)
                    table.insert(lines, {text = "  " .. string.char(16) .. " Prison: " .. days .. " day(s) remaining", pen = COLOR_YELLOW})
                    table.insert(lines, NEWLINE)
                end
                if punishment.beating > 0 then
                    table.insert(lines, {text = "  " .. string.char(16) .. " Beatings pending: " .. punishment.beating, pen = COLOR_LIGHTRED})
                    table.insert(lines, NEWLINE)
                end
                if punishment.hammer_strikes > 0 then
                    table.insert(lines, {text = "  " .. string.char(16) .. " Hammer strikes pending: " .. punishment.hammer_strikes, pen = COLOR_RED})
                    table.insert(lines, NEWLINE)
                end
            end
        end
    end

    -- Interrogation Log (combines CI-HQ watchlist status + game history)
    local hf = df.historical_figure.find(s.unit.hist_figure_id)
    local has_log = false
    
    -- CI-HQ dispatch status
    local watch = interrogation_watchlist[s.unit.id]
    if watch and watch.status then
        if not has_log then
            table.insert(lines, NEWLINE)
            table.insert(lines, {text = string.char(196):rep(40), pen = COLOR_DARKGREY})
            table.insert(lines, NEWLINE)
            table.insert(lines, {text = "INTERROGATION LOG:", pen = COLOR_LIGHTBLUE})
            table.insert(lines, NEWLINE)
            has_log = true
        end
        if watch.status == 'active' or watch.status == 'dispatched' then
            table.insert(lines, {text = "  Status: ACTIVE (Captain dispatched)", pen = COLOR_LIGHTGREEN})
            table.insert(lines, NEWLINE)
        elseif watch.status == 'confessed' then
            table.insert(lines, {text = "  Status: RESOLVED — Subject confessed.", pen = COLOR_LIGHTGREEN})
            table.insert(lines, NEWLINE)
        elseif watch.status == 'concluded' then
            table.insert(lines, {text = "  Status: CONCLUDED", pen = COLOR_CYAN})
            table.insert(lines, NEWLINE)
        end
    end
    
    -- Game-native interrogation reports from history events
    if hf then
        local events = df.global.world.history.events
        local reports = {}
        for i = #events - 1, 0, -1 do
            local event = events[i]
            if event.year < df.global.cur_year - 5 then break end
            if df.history_event_hf_interrogatedst:is_instance(event) then
                if event.target_hf == hf.id then
                    table.insert(reports, event)
                end
            end
        end
        if #reports > 0 then
            if not has_log then
                table.insert(lines, NEWLINE)
                table.insert(lines, {text = string.char(196):rep(40), pen = COLOR_DARKGREY})
                table.insert(lines, NEWLINE)
                table.insert(lines, {text = "INTERROGATION LOG:", pen = COLOR_LIGHTBLUE})
                table.insert(lines, NEWLINE)
                has_log = true
            end
            for _, report in ipairs(reports) do
                local interrogator_name = "Unknown"
                pcall(function()
                    local int_hf = df.historical_figure.find(report.interrogator_hf)
                    if int_hf then interrogator_name = dfhack.units.getReadableName(int_hf) end
                end)
                local season = ""
                local ticks = report.seconds or 0
                if ticks < 100800 then season = "Spring"
                elseif ticks < 201600 then season = "Summer"
                elseif ticks < 302400 then season = "Autumn"
                else season = "Winter" end
                
                local implicated = #report.implicated_hfs
                local result_text = "No new intel."
                local result_color = COLOR_DARKGREY
                if implicated > 0 then
                    result_text = "IMPLICATED " .. implicated .. " associate(s)!"
                    result_color = COLOR_LIGHTRED
                end
                
                table.insert(lines, {text = "  " .. string.char(16) .. " ", pen = COLOR_DARKGREY})
                table.insert(lines, {text = season .. " " .. report.year, pen = COLOR_WHITE})
                table.insert(lines, {text = " by ", pen = COLOR_DARKGREY})
                table.insert(lines, {text = interrogator_name, pen = COLOR_CYAN})
                table.insert(lines, NEWLINE)
                table.insert(lines, {text = "    Result: ", pen = COLOR_DARKGREY})
                table.insert(lines, {text = result_text, pen = result_color})
                table.insert(lines, NEWLINE)
            end
        end
    end

    -- Set text and switch to Case File tab
    local case_file = self.subviews.case_file
    if case_file then
        case_file:setText(lines)
        -- Only updateLayout if widget is already part of view hierarchy
        if case_file.frame_body then
            case_file:updateLayout()
        end
    end
    self.subviews.pages:setSelected(5)
end

function JusticeHQ:gatherSuspects()
    initCrimeCache() -- Rebuild cache to avoid O(N*M) lag
    local suspects = {}
    for _, unit in ipairs(df.global.world.units.active) do
        if dfhack.units.isDead(unit) or not dfhack.units.isActive(unit) then goto skip_unit end
        
        -- Scan citizens, visitors, AND residents — spies can be any of these
        local dominated = dfhack.units.isCitizen(unit)
            or dfhack.units.isVisiting(unit)
            or (dfhack.units.isOwnCiv(unit) and dfhack.units.isAlive(unit))
        if dominated and not dfhack.units.isInvader(unit) then
            local hf = df.historical_figure.find(unit.hist_figure_id)
            local is_suspect = false
            local intrigue_data = nil
            
            -- Check intrigue perspective (Fort Mode espionage data)
            if hf then
                intrigue_data = getHfIntrigueData(hf)
                if intrigue_data.is_villain then
                    is_suspect = true
                end
            end
            
            -- Check crime records
            local unit_crimes = getUnitCrimeData(unit)
            if unit_crimes.times_accused > 0 then
                is_suspect = true
            end
            
            if is_suspect then
                local is_child = dfhack.units.isBaby(unit) or dfhack.units.isChild(unit)
                
                local threat = "Low"
                local reason_lines = {
                    "Has a criminal record.",
                    "Review case files for more information."
                }
                local next_plot = "None"
                
                if intrigue_data and intrigue_data.is_villain then
                    if intrigue_data.plot_count > 0 then
                        -- Check if any plots are active (not on hold)
                        local active_plots = 0
                        for _, p in ipairs(intrigue_data.plots) do
                            if not p.on_hold then active_plots = active_plots + 1 end
                        end
                        if active_plots > 0 then
                            threat = "High"
                            reason_lines = {
                                "Running " .. active_plots .. " active intrigue plot(s) against the fortress.",
                                "Immediate threat to fortress security."
                            }
                            next_plot = "Active"
                        else
                            threat = "Medium"
                            reason_lines = {
                                "Has " .. intrigue_data.plot_count .. " intrigue plot(s) on hold.",
                                "Dormant threat — may reactivate."
                            }
                        end
                    elseif intrigue_data.actor_count > 0 then
                        threat = "Medium"
                        reason_lines = {
                            "Maintains an intelligence network of " .. intrigue_data.actor_count .. " known actors.",
                            "Likely a handler or mastermind coordinating espionage."
                        }
                    end
                end
                
                -- Low-threat suspects with no crimes are just notable figures
                if threat == "Low" and not is_child and unit_crimes.times_accused == 0 then
                    reason_lines = {
                        "Flagged by intelligence but no active plots or crimes.",
                        "Likely just a well-known local figure."
                    }
                end
                
                -- Get species and gender
                local race_name = "unknown"
                pcall(function()
                    local raw = df.creature_raw.find(unit.race)
                    if raw then race_name = raw.name[0] end
                end)
                local gender = ""
                if unit.sex == 0 then gender = string.char(12)
                elseif unit.sex == 1 then gender = string.char(11)
                end
                
                -- Category label
                local category = "citizen"
                if dfhack.units.isVisiting(unit) then category = "visitor"
                elseif not dfhack.units.isCitizen(unit) then category = "resident" end
                
                local full_name = dfhack.units.getReadableName(unit)
                local first_name = full_name:match("^(%S+)") or full_name
                local short_name = first_name .. " (" .. race_name .. ")"
                
                table.insert(suspects, {
                    unit = unit,
                    name = full_name,
                    short_name = short_name,
                    first_name = first_name,
                    prof = dfhack.units.getProfessionName(unit),
                    race = race_name,
                    gender = gender,
                    category = category,
                    threat = threat,
                    reason_lines = reason_lines,
                    next_plot = next_plot,
                    crime_data = getUnitCrimeData(unit),
                })
            end
        end
        ::skip_unit::
    end
    
    -- Sort High -> Medium -> Low
    local threat_val = {High = 3, Medium = 2, Low = 1}
    table.sort(suspects, function(a, b)
        if threat_val[a.threat] ~= threat_val[b.threat] then
            return threat_val[a.threat] > threat_val[b.threat]
        end
        return a.name < b.name
    end)
    
    return suspects
end

function JusticeHQ:invalidateEvidenceCache()
    for _, s in ipairs(self.suspects) do
        s.evidence = nil
        s.score = nil
    end
end

function JusticeHQ:refreshCurrentDossier()
    if not self.selected_suspect then return end
    local uid = self.selected_suspect.unit.id
    self:invalidateEvidenceCache()
    
    -- Refresh lists to get updated evidence/status data
    local list = self.subviews.suspect_list
    if list then
        list:setChoices(self:buildChoices())
        for idx, choice in ipairs(list:getChoices()) do
            if choice.data and choice.data.unit.id == uid then
                self.selected_suspect = choice.data
                if self.subviews.pages:getSelected() == 5 then
                    self:onOpenCaseFile(idx, choice)
                end
                return
            end
        end
    end
    
    local clist = self.subviews.convicts_list
    if clist then
        clist:setChoices(self:buildConvictChoices())
        for idx, choice in ipairs(clist:getChoices()) do
            if choice.data and choice.data.unit.id == uid then
                self.selected_suspect = choice.data
                if self.subviews.pages:getSelected() == 5 then
                    self:onOpenCaseFile(idx, choice)
                end
                return
            end
        end
    end
end

-- ===========================
-- CP437→UTF-8 converter (mixed-encoding aware)
-- DF names use CP437 single bytes; our Lua literals use UTF-8 multi-byte.
-- Scans bytes: valid UTF-8 sequences pass through, standalone high bytes → CP437 lookup.
-- ===========================

local CP437 = {
    [11]="\226\153\130",  -- ♂
    [12]="\226\153\128",  -- ♀
    [15]="\226\152\188",  -- ☼
    [16]="\226\150\186",  -- ►
    [23]="\226\134\149",  -- ↕
    [30]="\226\150\178",  -- ▲
    [31]="\226\150\188",  -- ▼
    [128]="\195\135",[129]="\195\188",[130]="\195\169",[131]="\195\162",
    [132]="\195\164",[133]="\195\160",[134]="\195\165",[135]="\195\167",
    [136]="\195\170",[137]="\195\171",[138]="\195\168",[139]="\195\175",
    [140]="\195\174",[141]="\195\172",[142]="\195\132",[143]="\195\133",
    [144]="\195\137",[145]="\195\166",[146]="\195\134",[147]="\195\180",
    [148]="\195\182",[149]="\195\178",[150]="\195\187",[151]="\195\185",
    [152]="\195\191",[153]="\195\150",[154]="\195\156",[155]="\194\162",
    [156]="\194\163",[157]="\194\165",[158]="\226\130\167",[159]="\198\146",
    [160]="\195\161",[161]="\195\173",[162]="\195\179",[163]="\195\186",
    [164]="\195\177",[165]="\195\145",[166]="\194\170",[167]="\194\186",
    [168]="\194\191",[169]="\226\140\144",[170]="\194\172",[171]="\194\189",
    [172]="\194\188",[173]="\194\161",[174]="\194\171",[175]="\194\187",
    [176]="\226\150\145",[177]="\226\150\146",[178]="\226\150\147",
    [179]="\226\148\130",[180]="\226\148\164",[181]="\226\149\161",
    [182]="\226\149\162",[183]="\226\149\150",[184]="\226\149\149",
    [185]="\226\149\163",[186]="\226\149\145",[187]="\226\149\151",
    [188]="\226\149\157",[189]="\226\149\156",[190]="\226\149\155",
    [191]="\226\148\144",[192]="\226\148\148",[193]="\226\148\180",
    [194]="\226\148\172",[195]="\226\148\156",[196]="\226\148\128",
    [197]="\226\148\188",[198]="\226\149\158",[199]="\226\149\159",
    [200]="\226\149\154",[201]="\226\149\148",[202]="\226\149\169",
    [203]="\226\149\166",[204]="\226\149\160",[205]="\226\149\144",
    [206]="\226\149\172",[207]="\226\149\167",[208]="\226\149\168",
    [209]="\226\149\164",[210]="\226\149\165",[211]="\226\149\153",
    [212]="\226\149\152",[213]="\226\149\146",[214]="\226\149\147",
    [215]="\226\149\171",[216]="\226\149\170",[217]="\226\148\152",
    [218]="\226\148\140",[219]="\226\150\136",[220]="\226\150\132",
    [221]="\226\150\140",[222]="\226\150\144",[223]="\226\150\128",
    [224]="\206\177",[225]="\195\159",[226]="\206\147",[227]="\207\128",
    [228]="\206\163",[229]="\207\131",[230]="\194\181",[231]="\207\132",
    [232]="\206\166",[233]="\206\152",[234]="\206\169",[235]="\206\180",
    [236]="\226\136\158",[237]="\207\134",[238]="\206\181",[239]="\226\136\169",
    [240]="\226\137\161",[241]="\194\177",[242]="\226\137\165",[243]="\226\137\164",
    [244]="\226\140\160",[245]="\226\140\161",[246]="\195\183",[247]="\226\137\136",
    [248]="\194\176",[249]="\226\136\153",[250]="\194\183",[251]="\226\136\154",
    [252]="\226\129\191",[253]="\194\178",[254]="\226\150\160",[255]="\194\160",
}

local function convertMixedToUtf8(raw)
    local out = {}
    local i, len = 1, #raw
    while i <= len do
        local b = raw:byte(i)
        if b < 128 then
            -- Check for CP437 graphic chars in control range (♀=12, ☼=15, ►=16)
            out[#out+1] = CP437[b] or raw:sub(i,i); i = i+1
        elseif b >= 0xC2 and b <= 0xDF and i+1 <= len then
            local b2 = raw:byte(i+1)
            if b2 >= 0x80 and b2 <= 0xBF then
                out[#out+1] = raw:sub(i,i+1); i = i+2  -- valid 2-byte UTF-8
            else
                out[#out+1] = CP437[b] or '?'; i = i+1
            end
        elseif b >= 0xE0 and b <= 0xEF and i+2 <= len then
            local b2, b3 = raw:byte(i+1), raw:byte(i+2)
            if b2 >= 0x80 and b2 <= 0xBF and b3 >= 0x80 and b3 <= 0xBF then
                out[#out+1] = raw:sub(i,i+2); i = i+3  -- valid 3-byte UTF-8
            else
                out[#out+1] = CP437[b] or '?'; i = i+1
            end
        elseif b >= 0xF0 and b <= 0xF7 and i+3 <= len then
            local b2, b3, b4 = raw:byte(i+1), raw:byte(i+2), raw:byte(i+3)
            if b2 >= 0x80 and b2 <= 0xBF and b3 >= 0x80 and b3 <= 0xBF and b4 >= 0x80 and b4 <= 0xBF then
                out[#out+1] = raw:sub(i,i+3); i = i+4  -- valid 4-byte UTF-8
            else
                out[#out+1] = CP437[b] or '?'; i = i+1
            end
        else
            out[#out+1] = CP437[b] or '?'; i = i+1  -- standalone high byte → CP437
        end
    end
    return table.concat(out)
end

-- ===========================
-- Clipboard Export: O(n) serialization
-- Tokens on the same line are concatenated; NEWLINE creates line breaks.
-- Uses table.concat (single allocation) to avoid O(n^2) string concat.
-- ===========================

function JusticeHQ:serializeChoiceToLine(text_tokens)
    -- Serialize a choice's text tokens into a single line string.
    -- NEWLINE tokens within a choice become " | " separators (sub-rows).
    if text_tokens == NEWLINE then return '' end
    if type(text_tokens) ~= 'table' then return '' end
    
    local parts = {}
    for _, token in ipairs(text_tokens) do
        if type(token) == 'table' and token.text then
            local t = tostring(token.text)
            if t ~= '' then table.insert(parts, t) end
        elseif token == NEWLINE then
            table.insert(parts, ' | ')
        end
    end
    -- Trim trailing whitespace from each part, then join
    local line = table.concat(parts)
    return line:match('^(.-)%s*$') or line
end

function JusticeHQ:serializeLabelTokens(token_list)
    -- Serialize a Label's flat token array into clean lines.
    -- Consecutive tokens are concatenated; NEWLINE creates a line break.
    local lines = {}
    local current = {}
    
    for _, token in ipairs(token_list) do
        if token == NEWLINE then
            local line = table.concat(current)
            -- Skip empty lines that would create double-spacing
            if line:match('%S') then
                table.insert(lines, line)
            end
            current = {}
        elseif type(token) == 'table' and token.text then
            table.insert(current, tostring(token.text))
        end
    end
    -- Flush remaining
    if #current > 0 then
        local line = table.concat(current)
        if line:match('%S') then
            table.insert(lines, line)
        end
    end
    
    return lines
end

-- Shared: serialize current tab to a UTF-8 string
function JusticeHQ:serializeCurrentTab()
    local page = self.subviews.pages:getSelected()
    local lines = {}
    local tab_name = "Unknown"
    
    local list_map = {
        [1] = {name = "Suspects", view = 'suspect_list'},
        [2] = {name = "Cases", view = 'cases_list'},
        [3] = {name = "Convicts", view = 'convicts_list'},
        [4] = {name = "Network", view = 'network_list'},
    }
    
    if list_map[page] then
        tab_name = list_map[page].name
        local list = self.subviews[list_map[page].view]
        if list then
            for _, choice in ipairs(list:getChoices()) do
                if choice.text then
                    local line = self:serializeChoiceToLine(choice.text)
                    if line ~= '' then
                        table.insert(lines, line)
                    end
                end
            end
        end
    elseif page == 5 then
        tab_name = "Case File"
        local case_file = self.subviews.case_file
        if case_file and case_file.text then
            lines = self:serializeLabelTokens(case_file.text)
        end
    end
    
    if #lines == 0 then
        return nil, nil, "Nothing to copy."
    end
    
    -- O(n) join: single allocation
    local raw = "=== CI-HQ: " .. tab_name .. " ===\n" .. table.concat(lines, '\n')
    local output = convertMixedToUtf8(raw)
    return output, tab_name, nil, raw  -- raw = original CP437 mixed for clipboard API
end

-- Export to file (c key)
function JusticeHQ:exportTabToFile()
    local output, tab_name, err = self:serializeCurrentTab()
    if not output then
        dfhack.gui.showAnnouncement("CI-HQ: " .. err, COLOR_GREY)
        return
    end
    
    local export_path = dfhack.getHackPath() .. '/ci-hq-export.txt'
    local f = io.open(export_path, 'wb')
    if f then
        f:write('\239\187\191')  -- UTF-8 BOM
        f:write(output)
        f:close()
        dialogs.showMessage(
            'CI-HQ: Export Complete',
            tab_name .. ' tab exported successfully.\n\n' ..
            'File: ' .. export_path,
            COLOR_LIGHTGREEN
        )
    else
        dialogs.showMessage(
            'CI-HQ: Export Failed',
            'Could not write to ' .. export_path,
            COLOR_RED
        )
    end
end

-- Copy to clipboard (Ctrl+C key) — uses DFHack's native clipboard API
-- NOTE: May freeze briefly on very large exports due to CP437 conversion
function JusticeHQ:copyTabToClipboard()
    local output, tab_name, err, raw = self:serializeCurrentTab()
    if not output then
        dfhack.gui.showAnnouncement("CI-HQ: " .. err, COLOR_GREY)
        return
    end
    
    -- The clipboard API expects pure CP437 but our raw text has UTF-8 literals
    -- from Lua source (e.g. em dash —). Replace them with ASCII equivalents
    -- before passing to the API, to prevent double-encoding garble (ΓÇö).
    local clipboard_text = raw:gsub('\226\128\148', '--')  -- — (em dash) → --
    dfhack.internal.setClipboardTextCp437Multiline(clipboard_text)
    dialogs.showMessage(
        'CI-HQ: Copied',
        tab_name .. ' tab copied to clipboard.\n\n' ..
        'Note: For large exports, use [c] Export for instant file output.',
        COLOR_LIGHTGREEN
    )
end

function JusticeHQ:onInput(keys)
    if keys.LEAVESCREEN or keys._MOUSE_R then
        self:dismiss()
        return true
    end
    if keys.CUSTOM_CTRL_C then
        self:copyTabToClipboard()
        return true
    end
    return self:inputToSubviews(keys)
end

function JusticeHQ:onDetain()
    if not self.selected_suspect then
        dfhack.gui.showAnnouncement("CI-HQ: Select a suspect first.", COLOR_YELLOW)
        return
    end
    
    local unit = self.selected_suspect.unit
    if not unit then return end
    
    if unit.flags1.chained then
        dfhack.gui.showAnnouncement("CI-HQ: " .. dfhack.units.getReadableName(unit) .. " is already detained.", COLOR_YELLOW)
        return
    end
    local name = dfhack.units.getReadableName(unit)
    local self_ref = self
    dialogs.showYesNoPrompt(
        'CI-HQ: Force Detainment',
        'Target: ' .. name .. '\n\n' ..
        'This action bypasses the normal Dwarf Fortress job queue.\n' ..
        'The suspect will be instantly teleported to a dungeon chain and\n' ..
        'forcibly restrained by editing their memory state.\n\n' ..
        'Authorize forced detainment?',
        COLOR_LIGHTMAGENTA,
        function()
            local ok, err = detainUnit(unit)
            if ok then
                dfhack.gui.showAnnouncement("CI-HQ: " .. name .. " has been forcibly detained in the dungeon.", COLOR_LIGHTMAGENTA, true)
                self_ref:refreshCurrentDossier()
            else
                dfhack.gui.showAnnouncement("CI-HQ: Detainment failed. " .. tostring(err), COLOR_RED, true)
            end
        end
    )
end

function JusticeHQ:onRelease()
    if not self.selected_suspect then return end
    local unit = self.selected_suspect.unit
    if not unit or not unit.flags1.chained then return end

    local name = dfhack.units.getReadableName(unit)
    local self_ref = self
    dialogs.showYesNoPrompt(
        'CI-HQ: Force Release',
        'Target: ' .. name .. '\n\n' ..
        'This action bypasses the normal Dwarf Fortress job queue.\n' ..
        'The suspect will be instantly released from their chains\n' ..
        'by editing their memory state.\n\n' ..
        'Authorize forced release?',
        COLOR_LIGHTGREEN,
        function()
            local ok, err = releaseUnit(unit)
            if ok then
                dfhack.gui.showAnnouncement("CI-HQ: " .. name .. " has been forcibly released.", COLOR_LIGHTGREEN, true)
                self_ref:refreshCurrentDossier()
            else
                dfhack.gui.showAnnouncement("CI-HQ: Release failed. " .. tostring(err), COLOR_RED, true)
            end
        end
    )
end

function JusticeHQ:onPardon()
    if not self.selected_suspect then
        dfhack.gui.showAnnouncement("CI-HQ: Select a suspect first.", COLOR_YELLOW)
        return
    end
    local unit = self.selected_suspect.unit
    
    local pardoned = false
    for _, punishment in ipairs(df.global.plotinfo.punishments) do
        if punishment.criminal == unit.id then
            punishment.prison_counter = 0
            punishment.beating = 0
            punishment.hammer_strikes = 0
            pardoned = true
        end
    end
    
    if pardoned then
        dfhack.gui.showAnnouncement("CI-HQ: Suspect " .. dfhack.units.getReadableName(unit) .. " has been fully pardoned.", COLOR_LIGHTCYAN, true)
        self:refreshCurrentDossier()
    else
        dfhack.gui.showAnnouncement("CI-HQ: Suspect is not currently serving a sentence.", COLOR_GREY, true)
    end
end

function JusticeHQ:onExecute()
    if not self.selected_suspect then
        dfhack.gui.showAnnouncement("CI-HQ: Select a suspect first.", COLOR_YELLOW)
        return
    end
    local unit = self.selected_suspect.unit
    
    if not dfhack.units.isActive(unit) then
        dfhack.gui.showAnnouncement("CI-HQ: Cannot execute — target has left the map!", COLOR_RED)
        return
    end
    
    if dfhack.units.isCitizen(unit) then
        -- Citizens go through the vanilla punishment queue
        local executor_name = "Hammerer"
        local hammer_strikes = 50
        local beatings = 0
        
        if not findHammerer() then
            hammer_strikes = 0
            beatings = 100
            executor_name = "Captain of the Guard"
        end
        
        df.global.plotinfo.punishments:insert('#', {
            criminal = unit.id,
            officer = -1,
            beating = beatings,
            hammer_strikes = hammer_strikes,
            prison_counter = 0,
            time_to_assign = 10,
            chain = -1
        })
        
        dfhack.gui.showAnnouncement("CI-HQ: EXECUTION ORDERED for " .. dfhack.units.getReadableName(unit) .. ". " .. executor_name .. " dispatched.", COLOR_RED, true)
    else
        -- Non-citizens: the vanilla punishment queue ignores foreign visitors entirely.
        -- Show a confirmation dialog explaining why and requesting player approval.
        local name = dfhack.units.getReadableName(unit)
        local unit_id = unit.id
        local self_ref = self
        dialogs.showYesNoPrompt(
            'CI-HQ: Extrajudicial Execution',
            'Target: ' .. name .. '\n\n' ..
            'This suspect is a non-citizen visitor. The dwarven justice\n' ..
            'system cannot sentence foreign nationals — any punishment\n' ..
            'order will be ignored by the Hammerer.\n\n' ..
            'CI-HQ can bypass the justice system and execute this\n' ..
            'suspect directly. This action cannot be undone.\n\n' ..
            'Authorize extrajudicial execution?',
            COLOR_LIGHTRED,
            function()
                local target = df.unit.find(unit_id)
                if not target or not dfhack.units.isActive(target) then
                    dfhack.gui.showAnnouncement("CI-HQ: Target has left the map. Execution aborted.", COLOR_RED)
                    return
                end
                local exterminate = reqscript('exterminate')
                exterminate.killUnit(target, exterminate.killMethod.INSTANT)
                dfhack.gui.showAnnouncement("CI-HQ: " .. name .. " has been executed by order of the fortress!", COLOR_LIGHTRED, true)
                CRIME_CACHE = nil
                self_ref:refreshCurrentDossier()
            end
        )
        return -- Don't refresh yet, wait for player confirmation
    end
    self:refreshCurrentDossier()
end

function JusticeHQ:onInterrogate()
    local suspect = self.selected_suspect
    if not suspect then
        -- Try to get from list selection
        local list = self.subviews.suspect_list
        if list then
            local choice = list:getChoices()[list:getSelected()]
            if choice and choice.data then
                suspect = choice.data
            end
        end
    end
    if not suspect then
        dfhack.gui.showAnnouncement("CI-HQ: No suspect selected.", COLOR_YELLOW)
        return
    end
    
    local uid = suspect.unit.id
    
    if not dfhack.units.isActive(suspect.unit) then
        dfhack.gui.showAnnouncement("CI-HQ: Cannot interrogate " .. suspect.first_name .. " — they have left the map!", COLOR_RED)
        return
    end
    
    -- Early guard check with actionable guidance
    local guard = findCaptainOfGuard()
    if not guard then
        dfhack.gui.showAnnouncement(
            "CI-HQ: No Captain of the Guard or Sheriff is assigned! Open the Nobles screen (n) and appoint one.",
            COLOR_LIGHTRED, true)
        return
    end
    
    -- Prevent interrogating the Captain themselves
    if guard.id == uid then
        dfhack.gui.showAnnouncement("CI-HQ: The Captain of the Guard cannot interrogate themselves!", COLOR_LIGHTRED)
        return
    end
    
    -- If already on watchlist and active/dispatched, treat as CANCEL
    if interrogation_watchlist[uid] then
        local watch = interrogation_watchlist[uid]
        if watch.status == 'active' or watch.status == 'dispatched' then
            dialogs.showYesNoPrompt(
                'Cancel Interrogation?',
                'Are you sure you want to cancel the interrogation loop on ' .. suspect.first_name .. '?\n\n' ..
                'Status: ' .. watch.status:upper() .. '\n' ..
                'Attempts so far: ' .. (watch.retries or 0) .. '/' .. watch.max_retries .. '\n\n' ..
                'The Captain of the Guard will stop re-dispatching to this suspect.',
                COLOR_YELLOW,
                function()
                    watch.status = 'cancelled'
                    dfhack.gui.showAnnouncement("CI-HQ: Interrogation of " .. suspect.first_name .. " cancelled.", COLOR_YELLOW)
                    persist_state()
                    self:refreshCurrentDossier()
                end
            )
            return
        elseif watch.status == 'gave_up' or watch.status == 'escaped' or watch.status == 'concluded' or watch.status == 'cancelled' or watch.status == 'confessed' then
            -- Allow re-interrogation from any terminal state
            watch.retries = 0
            watch.consecutive_duds = 0
            watch.status = 'active'
            dfhack.gui.showAnnouncement("Resuming interrogation of " .. suspect.first_name .. "!", COLOR_LIGHTGREEN)
        end
    else
        interrogation_watchlist[uid] = {
            name = suspect.first_name,
            full_name = suspect.name,
            retries = 0,
            max_retries = MAX_RETRIES,
            status = 'active',
            unit_id = uid,
            hf_id = suspect.unit.hist_figure_id,
        }
    end
    persist_state()
    
    -- Try to create a real interrogation job
    local ok, err = tryCreateInterrogationJob(suspect.unit)
    if ok then
        -- Snapshot report count NOW so the monitor can detect the first interrogation's results
        local watch = interrogation_watchlist[uid]
        local hf = df.historical_figure.find(suspect.unit.hist_figure_id)
        if hf and hf.info and hf.info.relationships and hf.info.relationships.intrigues then
            watch.last_report_count = #hf.info.relationships.intrigues.intrigue
        else
            watch.last_report_count = 0
        end
        watch.status = 'dispatched'
        watch.dispatched_tick = df.global.cur_year_tick
        dfhack.gui.showAnnouncement("CI-HQ: Captain dispatched to interrogate " .. suspect.first_name .. "!", COLOR_LIGHTGREEN)
    else
        dfhack.gui.showAnnouncement("CI-HQ: Could not auto-dispatch (" .. tostring(err) .. ")", COLOR_YELLOW)
        dfhack.gui.showAnnouncement("CI-HQ: Use Justice tab to manually order interrogation.", COLOR_CYAN)
    end
    
    startInterrogationMonitor()
    
    -- Refresh the dossier to show updated status
    self:refreshCurrentDossier()
end

-- ===========================
-- Interrogation Monitor Loop
-- ===========================

monitor_running = monitor_running or false
monitor_last_scheduled_tick = monitor_last_scheduled_tick or nil



function isSuspectStillThreat(uid)
    local unit = df.unit.find(uid)
    if not unit or not dfhack.units.isAlive(unit) then return false end
    
    -- Check intrigue perspective (primary indicator)
    local hf = df.historical_figure.find(unit.hist_figure_id)
    if not hf then return false end
    
    local idata = getHfIntrigueData(hf)
    local has_intrigue_threat = idata.is_villain
    
    -- Also check crime data: if ALL crimes are sentenced, they're fully processed
    local cd = getUnitCrimeData(unit)
    local has_unsolved = cd.times_accused > cd.times_convicted
    
    -- Only fully resolved if all crimes convicted AND no active intrigue plots remain.
    -- A mastermind with a convicted theft but 3 active assassination plots is still a threat.
    if cd.times_accused > 0 and not has_unsolved and not has_intrigue_threat then
        return false  -- All crimes resolved and no intrigue threat
    end
    
    return has_intrigue_threat
end

function dispatchGuardToSuspect(uid)
    local unit = df.unit.find(uid)
    if not unit then return false end
    
    local guard = findCaptainOfGuard()
    if not guard then return false end
    
    if guard.id == uid then return false end
    
    -- Check if guard is already interrogating THIS suspect
    if guard.job.current_job then
        if guard.job.current_job.job_type == df.job_type.InterrogateSubject then
            -- Already interrogating someone — don't interrupt
            return false
        end
        
        -- Cancel interruptable civilian jobs to prioritize interrogation
        if INTERRUPTABLE_JOBS[guard.job.current_job.job_type] then
            local ok = pcall(function()
                dfhack.job.removeJob(guard.job.current_job)
            end)
            if not ok then return false end
        else
            -- Non-interruptable job (eating, sleeping, etc.) — wait
            return false
        end
    end
    
    -- Dispatch using proper engine linkage (same pattern as tryCreateInterrogationJob)
    local ok, err = pcall(function()
        local job = df.job:new()
        job.job_type = df.job_type.InterrogateSubject
        
        job.pos.x = unit.pos.x
        job.pos.y = unit.pos.y
        job.pos.z = unit.pos.z
        
        local target_ref = df.general_ref_unit_interrogateest:new()
        target_ref.unit_id = unit.id
        job.general_refs:insert('#', target_ref)
        
        -- Link into world properly so the DF engine manages the job lifecycle
        dfhack.job.linkIntoWorld(job, true)
        dfhack.job.addWorker(job, guard)
    end)
    
    return ok
end

function interrogationMonitorTick()
    local ok, err = pcall(function()
        local any_active = false
        
        for uid, watch in pairs(interrogation_watchlist) do
            if watch.status == 'active' or watch.status == 'dispatched' then
                -- Check if suspect confessed
                if not isSuspectStillThreat(uid) then
                    watch.status = 'confessed'
                    dfhack.gui.showAnnouncement(
                        "CI-HQ: " .. watch.name .. " has confessed! Intelligence extracted.",
                        COLOR_LIGHTGREEN)
                    CRIME_CACHE = nil
                    INTERROGATION_HISTORY_CACHE = nil
                    persist_state()
                else
                    local unit = df.unit.find(uid)
                    if not unit or not dfhack.units.isActive(unit) then
                        watch.status = 'escaped'
                        dfhack.gui.showAnnouncement(
                            "CI-HQ: " .. watch.name .. " has left the map! Interrogation aborted.",
                            COLOR_RED)
                        persist_state()
                    else
                        any_active = true
                        
                        -- Check if Captain is currently interrogating
                        local guard = findCaptainOfGuard()
                        local guard_is_interrogating = false
                        if guard and guard.job.current_job then
                            guard_is_interrogating = guard.job.current_job.job_type == df.job_type.InterrogateSubject
                        end
                        
                        if watch.status == 'active' then
                            if not guard_is_interrogating then
                                -- Snapshot the current report count before dispatching
                                local hf = df.historical_figure.find(unit.hist_figure_id)
                                if hf and hf.info and hf.info.relationships and hf.info.relationships.intrigues then
                                    watch.last_report_count = #hf.info.relationships.intrigues.intrigue
                                else
                                    watch.last_report_count = 0
                                end
                                
                                if dispatchGuardToSuspect(uid) then
                                    watch.status = 'dispatched'
                                    watch.dispatched_tick = df.global.cur_year_tick
                                    dfhack.gui.showAnnouncement(
                                        "CI-HQ: Captain dispatched! Interrogating " .. watch.name .. ".",
                                        COLOR_LIGHTGREEN)
                                end
                            end
                        elseif watch.status == 'dispatched' then
                            -- Check if the job finished
                            local elapsed = df.global.cur_year_tick - (watch.dispatched_tick or 0)
                            -- Handle year rollover: if dispatched_tick > cur_year_tick, year wrapped
                            if elapsed < 0 then elapsed = 999 end
                            
                            -- Wait for guard to finish or grace period to expire
                            if not guard_is_interrogating and elapsed >= 100 then
                                -- Guard is idle and enough time passed for the job to have completed.
                                -- Check if new intrigue reports appeared.
                                local hf = df.historical_figure.find(unit.hist_figure_id)
                                local reports_found = false
                                local is_dud = false
                                
                                if hf and hf.info and hf.info.relationships and hf.info.relationships.intrigues then
                                    local i_list = hf.info.relationships.intrigues.intrigue
                                    if #i_list > (watch.last_report_count or 0) then
                                        reports_found = true
                                        local last = i_list[#i_list-1]
                                        if last.role == -1 and last.strategy == -1 then
                                            is_dud = true
                                        end
                                    end
                                end

                                watch.retries = (watch.retries or 0) + 1
                                
                                if reports_found and not is_dud then
                                    -- New intel extracted! Reset dud counter, continue.
                                    watch.consecutive_duds = 0
                                    if watch.retries >= watch.max_retries then
                                        watch.status = 'concluded'
                                        dfhack.gui.showAnnouncement(
                                            "CI-HQ: " .. watch.name .. " reached max attempts (" .. watch.retries .. "). Concluded.",
                                            COLOR_YELLOW)
                                        persist_state()
                                    else
                                        watch.status = 'active'
                                        watch.dispatched_tick = nil
                                        dfhack.gui.showAnnouncement(
                                            "CI-HQ: " .. watch.name .. " spilled some intel! Re-dispatching (" .. watch.retries .. "/" .. watch.max_retries .. ")...",
                                            COLOR_LIGHTGREEN)
                                        persist_state()
                                    end
                                else
                                    -- No new intel this round (suspect refused or had nothing new).
                                    -- DF produces no intrigue entry for either case, so we can't
                                    -- distinguish them. Count toward the consecutive dud limit.
                                    watch.consecutive_duds = (watch.consecutive_duds or 0) + 1
                                    if watch.consecutive_duds >= MAX_CONSECUTIVE_DUDS then
                                        watch.status = 'concluded'
                                        dfhack.gui.showAnnouncement(
                                            "CI-HQ: " .. watch.name .. " revealed no new intel after " .. watch.consecutive_duds .. " consecutive attempts. Concluded.",
                                            COLOR_YELLOW)
                                        persist_state()
                                    elseif watch.retries >= watch.max_retries then
                                        watch.status = 'concluded'
                                        dfhack.gui.showAnnouncement(
                                            "CI-HQ: " .. watch.name .. " reached max attempts (" .. watch.retries .. "). Concluded.",
                                            COLOR_YELLOW)
                                        persist_state()
                                    else
                                        watch.status = 'active'
                                        watch.dispatched_tick = nil
                                        dfhack.gui.showAnnouncement(
                                            "CI-HQ: " .. watch.name .. " revealed no new intel (" .. watch.consecutive_duds .. "/" .. MAX_CONSECUTIVE_DUDS .. "). Retrying (" .. watch.retries .. "/" .. watch.max_retries .. ")...",
                                            COLOR_CYAN)
                                        persist_state()
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
        
        if any_active then
            monitor_last_scheduled_tick = df.global.cur_year_tick
            dfhack.timeout(MONITOR_INTERVAL, 'ticks', interrogationMonitorTick)
        else
            monitor_running = false
            monitor_last_scheduled_tick = nil
        end
    end)
    
    if not ok then
        -- Catch and report any error, then keep the monitor alive
        dfhack.gui.showAnnouncement("CI-HQ: Monitor error: " .. tostring(err), COLOR_LIGHTRED)
        print("CI-HQ MONITOR ERROR: " .. tostring(err))
        -- Reschedule even on error so monitoring doesn't die silently
        monitor_last_scheduled_tick = df.global.cur_year_tick
        dfhack.timeout(MONITOR_INTERVAL, 'ticks', interrogationMonitorTick)
    end
end


function startInterrogationMonitor()
    -- Always force-start the monitor. The old liveness check was unreliable
    -- because dfhack.timeout callbacks die on script reload and monitor_running
    -- stays stale. Just always restart — duplicate starts are harmless since
    -- the old callback chain is already dead.
    monitor_running = true
    monitor_last_scheduled_tick = df.global.cur_year_tick
    dfhack.timeout(MONITOR_INTERVAL, 'ticks', interrogationMonitorTick)
end

--
-- JusticeHQOverlay
--
local overlay = require('plugins.overlay')
local repeatUtil = require('repeat-util')

GLOBAL_ALERTED_UNITS = GLOBAL_ALERTED_UNITS or {}
GLOBAL_ALERTED_CRIMES = GLOBAL_ALERTED_CRIMES or {}

JusticeHQOverlay = defclass(JusticeHQOverlay, overlay.OverlayWidget)
JusticeHQOverlay.ATTRS{
    desc='Adds a button to launch Counter-Intelligence HQ from the Justice tab.',
    default_pos={x=58, y=5},
    default_enabled=true,
    viewscreens='dwarfmode/Info/JUSTICE',
    frame={w=22, h=3},
    frame_style=gui.FRAME_MEDIUM,
    frame_background=gui.CLEAR_PEN,
}

function JusticeHQOverlay:init()
    self:addviews{
        widgets.HotkeyLabel{
            frame={t=0, l=0},
            key='CUSTOM_J',
            label='Launch CI-HQ',
            on_activate=function() dfhack.run_script('gui/justice-hq') end,
            text_pen=COLOR_LIGHTGREEN,
        }
    }
end

OVERLAY_WIDGETS = {hq_button=JusticeHQOverlay}

--
-- Background Monitor Daemon
--


GLOBAL_INITIAL_SCAN_DONE = GLOBAL_INITIAL_SCAN_DONE or false

function ci_alert_monitor_tick()
    -- Restart the interrogation monitor if any watches are active/dispatched
    -- (Don't call interrogationMonitorTick directly — it self-schedules on a 50-tick loop.
    --  Calling it here would create a dual execution path, double-counting retries.)
    for _, watch in pairs(interrogation_watchlist) do
        if watch.status == 'active' or watch.status == 'dispatched' then
            startInterrogationMonitor()
            break
        end
    end
    
    local is_initial_scan = not GLOBAL_INITIAL_SCAN_DONE
    
    for _, unit in ipairs(df.global.world.units.active) do
        if dfhack.units.isDead(unit) or not dfhack.units.isActive(unit) then goto skip_mon end
        if GLOBAL_ALERTED_UNITS[unit.id] then goto skip_mon end
        
        -- Check if relevant to fort
        local dominated = dfhack.units.isCitizen(unit)
            or dfhack.units.isResident(unit)
            or dfhack.units.isVisiting(unit)
            
        if dominated and not dfhack.units.isInvader(unit) then
            -- Exclude babies, children, and pets
            if unit.profession == df.profession.BABY or unit.profession == df.profession.CHILD then goto skip_mon end
            if unit.flags1.tame then goto skip_mon end

            local is_suspect = false
            
            -- Check intrigue perspective (Fort Mode espionage data)
            local hf = df.historical_figure.find(unit.hist_figure_id)
            if hf then
                local intrigue_data = getHfIntrigueData(hf)
                if intrigue_data.is_villain then
                    is_suspect = true
                end
            end
            
            -- Check Crime Record
            if not is_suspect then
                local crimes = getUnitCrimeData(unit)
                if crimes.times_accused > 0 then
                    is_suspect = true
                end
            end
            
            if is_suspect then
                if not is_initial_scan then
                    local name = dfhack.units.getReadableName(unit)
                    dfhack.gui.showAnnouncement("CI-HQ ALERT: A suspect with criminal/intelligence activity (" .. name .. ") has been detected!", COLOR_LIGHTRED, true)
                end
                GLOBAL_ALERTED_UNITS[unit.id] = true
            end
        end
        ::skip_mon::
    end
    
    -- Scan for new theft/treason crimes (artifact theft alerts)
    for _, crime in ipairs(df.global.world.crimes.all) do
        if not GLOBAL_ALERTED_CRIMES[crime.id] then
            if crime.mode == 3 or crime.mode == 17 then -- Theft or Treason/Artifact Theft
                if not is_initial_scan then
                    local crime_name = getCrimeName(crime.mode)
                    dfhack.gui.showAnnouncement(
                        "CI-HQ ALERT: " .. crime_name .. " detected! Check Cases tab for details.",
                        COLOR_LIGHTRED, true)
                    CRIME_CACHE = nil -- Invalidate cache so new crime data appears
                end
                GLOBAL_ALERTED_CRIMES[crime.id] = true
            end
        end
    end
    
    GLOBAL_INITIAL_SCAN_DONE = true
end

-- ===========================
-- State Change Handler
-- ===========================

dfhack.onStateChange[GLOBAL_KEY] = function(sc)
    if sc == SC_MAP_UNLOADED then
        enabled = false
        return
    end

    if sc ~= SC_MAP_LOADED or df.global.gamemode ~= df.game_mode.DWARF then
        return
    end

    load_state()
    if enabled then
        repeatUtil.scheduleUnlessAlreadyScheduled('ci-hq-monitor', 1200, 'ticks', ci_alert_monitor_tick)
    end
end

-- ===========================

if dfhack_flags.module then
    return
end

-- Handle enable/disable from gui/control-panel or command line
local args = {...}
if dfhack_flags and dfhack_flags.enable then
    args = {dfhack_flags.enable_state and 'enable' or 'disable'}
end

if args[1] == 'enable' or args[1] == '1' then
    enabled = true
    persist_state()
    repeatUtil.scheduleUnlessAlreadyScheduled('ci-hq-monitor', 1200, 'ticks', ci_alert_monitor_tick)
    print("CI-HQ: Background suspect alert monitor ENABLED.")
    return
elseif args[1] == 'disable' or args[1] == '0' then
    enabled = false
    persist_state()
    repeatUtil.cancel('ci-hq-monitor')
    print("CI-HQ: Background suspect alert monitor DISABLED.")
    return
end

local screen = JusticeHQ()
screen:show()
