--@ module=true
--@ enable=true

-- Version guard: bail early if key DF structures are missing
if not df.global.plotinfo or not df.global.plotinfo.punishments then
    qerror('CI-HQ requires Dwarf Fortress v50+ with DFHack. Unsupported version detected.')
end

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

-- Persistent UI state (survives close/reopen within same session)
PERSISTENT_UI = PERSISTENT_UI or {
    filter_level = 1,
    case_filter_level = 1,
    convict_filter_level = 1,
    suspect_sort = 1,
    cases_sort = 1,
    convicts_sort = 1,
    network_sort = 1,
    intel_filter_level = 1,
    intel_sort = 1,
    search_text = {},
    active_tab = 1,
}

-- CI-HQ Notification overlay queue (survives close/reopen)
CIHQ_NOTIFICATIONS = CIHQ_NOTIFICATIONS or {}
local CIHQ_MAX_NOTIFICATIONS = 6
local CIHQ_NOTIFICATION_LIFETIME_MS = 6000  -- 6 seconds real-time

-- Wrapper: pushes to the colored overlay queue AND fires the native announcement
local function cihq_announce(text, color, show_popup)
    table.insert(CIHQ_NOTIFICATIONS, 1, {
        text = text,
        color = color or COLOR_GREY,
        time = dfhack.getTickCount(),   -- real-time ms (works even when paused)
    })
    while #CIHQ_NOTIFICATIONS > CIHQ_MAX_NOTIFICATIONS do
        table.remove(CIHQ_NOTIFICATIONS)
    end
    
    -- The v50 vanilla UI ignores LIGHT colors (8-15) for generic announcements,
    -- defaulting them to dark gray/black. We must map them to base colors (0-7).
    local native_color = color or COLOR_GREY
    if native_color == COLOR_LIGHTGREEN then native_color = COLOR_GREEN
    elseif native_color == COLOR_LIGHTRED then native_color = COLOR_RED
    elseif native_color == COLOR_LIGHTCYAN then native_color = COLOR_CYAN
    elseif native_color == COLOR_LIGHTMAGENTA then native_color = COLOR_MAGENTA
    elseif native_color == COLOR_YELLOW then native_color = COLOR_BROWN
    elseif native_color == COLOR_WHITE then native_color = COLOR_GREY
    elseif native_color == COLOR_LIGHTBLUE then native_color = COLOR_BLUE
    end
    
    dfhack.gui.showAnnouncement(text, native_color, show_popup)
end

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

-- Semantic colors: violent/lethal = red, espionage/stealth = magenta,
-- corruption/political = yellow, resource/economic = brown, defensive = cyan
local PLOT_COLORS = {
    Grow_Funding_Network = COLOR_BROWN,
    Grow_Asset_Network = COLOR_CYAN,
    Acquire_Artifact = COLOR_LIGHTMAGENTA,
    Grow_Corruption_Network = COLOR_YELLOW,
    Attain_Rank = COLOR_YELLOW,
    Assassinate_Actor = COLOR_LIGHTRED,
    Corruptly_Punish_Actor = COLOR_RED,
    Frame_Actor = COLOR_LIGHTMAGENTA,
    Kidnap_Actor = COLOR_LIGHTRED,
    Sabotage_Actor = COLOR_RED,
    Direct_War_To_Actor = COLOR_LIGHTRED,
    Corrupt_Actors_Government = COLOR_YELLOW,
    Counterintelligence = COLOR_LIGHTCYAN,
    Become_Immortal = COLOR_LIGHTMAGENTA,
    Undead_World_Conquest = COLOR_LIGHTRED,
    Infiltrate_Society = COLOR_LIGHTCYAN,
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

-- Roles colored by function: leadership = white, operatives = lightred,
-- logistics/support = brown, targets/victims = yellow, passive = grey
local ROLE_COLORS = {
    Master = COLOR_WHITE,
    Director = COLOR_WHITE,
    Indirect_Director = COLOR_WHITE,
    Lieutenant = COLOR_LIGHTCYAN,
    Handler = COLOR_LIGHTCYAN,
    Asset = COLOR_LIGHTGREEN,
    Usable_Assassin = COLOR_LIGHTRED,
    Usable_Thief = COLOR_LIGHTRED,
    Usable_Snatcher = COLOR_LIGHTRED,
    Plot_Snatcher = COLOR_LIGHTRED,
    Plot_Saboteur = COLOR_RED,
    Source_Of_Funds = COLOR_BROWN,
    Source_Of_Funds_For_Master = COLOR_BROWN,
    Corrupt_Position_Holder = COLOR_YELLOW,
    Delivery_Target = COLOR_LIGHTMAGENTA,
    Underworld_Contact = COLOR_LIGHTMAGENTA,
    Possible_Threat = COLOR_YELLOW,
    Rebuffed = COLOR_GREY,
    Suspected_Criminal = COLOR_YELLOW,
    Potential_Employer = COLOR_GREY,
    Enemy = COLOR_RED,
    None = COLOR_DARKGREY,
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

-- Strategies colored by hostility: lethal = red, exploitative = yellow,
-- passive = grey, cooperative = cyan
local STRATEGY_COLORS = {
    Neutralize = COLOR_LIGHTRED,
    Torment = COLOR_RED,
    Corrupt_And_Pacify = COLOR_YELLOW,
    Use = COLOR_YELLOW,
    Tax = COLOR_BROWN,
    Obey = COLOR_LIGHTCYAN,
    Monitor = COLOR_CYAN,
    Avoid = COLOR_GREY,
    Work_If_Suited = COLOR_LIGHTGREEN,
    None = COLOR_DARKGREY,
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
    CRIME_CACHE_HFID = {}
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
        local function add_to_hf_cache(hfid)
            if hfid ~= -1 then
                CRIME_CACHE_HFID[hfid] = CRIME_CACHE_HFID[hfid] or {}
                table.insert(CRIME_CACHE_HFID[hfid], crime)
            end
        end
        
        add_to_cache(crime.accused)
        if crime.criminal ~= crime.accused then
            add_to_cache(crime.criminal)
        end
        
        if crime.accused_hf and crime.accused_hf.hfid ~= -1 then
            add_to_hf_cache(crime.accused_hf.hfid)
        end
        if crime.criminal_hf and crime.criminal_hf.hfid ~= -1 and crime.criminal_hf.hfid ~= crime.accused_hf.hfid then
            add_to_hf_cache(crime.criminal_hf.hfid)
        end
    end

    local events = df.global.world.history.events
    for i = #events - 1, 0, -1 do
        local event = events[i]
        if event and df.history_event_hf_interrogatedst:is_instance(event) then
            pcall(function()
                local thf = event.target_hf or event.subject_hf
                if thf then
                    INTERROGATION_HISTORY_CACHE[thf] = (INTERROGATION_HISTORY_CACHE[thf] or 0) + 1
                end
            end)
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
-- Helper: Confiscate Stolen Item from Unit
-- ===========================

function confiscateStolenItem(unit, crime)
    local confiscated = {}
    local ok, err = pcall(function()
        if not crime or crime.item_id == -1 then return end
        local target_item_id = crime.item_id
        
        -- Search unit inventory for the stolen item
        for i = #unit.inventory - 1, 0, -1 do
            local inv_item = unit.inventory[i]
            if inv_item and inv_item.item and inv_item.item.id == target_item_id then
                local item = inv_item.item
                local item_name = dfhack.items.getDescription(item, 0, true)
                
                -- Drop item on the ground at unit's current position
                if dfhack.items.moveToGround(item, unit.pos) then
                    -- Mark as forbidden so dwarves don't immediately grab it during chaos
                    item.flags.forbid = false
                    item.flags.dump = false
                    table.insert(confiscated, item_name)
                end
                break
            end
        end
        
        -- Also check if the unit is carrying the item via general_refs (artifact holder)
        if #confiscated == 0 then
            for i = #unit.general_refs - 1, 0, -1 do
                local ref = unit.general_refs[i]
                if df.general_ref_contains_itemst:is_instance(ref) and ref.item_id == target_item_id then
                    local item = df.item.find(ref.item_id)
                    if item then
                        local item_name = dfhack.items.getDescription(item, 0, true)
                        if dfhack.items.moveToGround(item, unit.pos) then
                            item.flags.forbid = false
                            table.insert(confiscated, item_name)
                        end
                    end
                    break
                end
            end
        end
    end)
    
    if not ok then
        dfhack.printerr("CI-HQ: Error confiscating item: " .. tostring(err))
    end
    return confiscated
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
        -- If it's an Open Case but the accused unit has left the map / been garbage collected
        if crime.flags.needs_trial and crime.accused ~= -1 then
            local accused_unit = df.unit.find(crime.accused)
            if not accused_unit or not dfhack.units.isActive(accused_unit) then
                crime.flags.needs_trial = false
                crime.flags.sentenced = true
                fixed_count = fixed_count + 1
            end
        end
    end
    if fixed_count > 0 then
        dfhack.color(COLOR_GREEN)
        dfhack.println("CI-HQ: Auto-fixed " .. fixed_count .. " ghost case(s) where the convict left the map.")
        dfhack.color(COLOR_RESET)
    end
end

-- ===========================
-- Helper: Fog of War check
-- ===========================
function hasConfessedToIntrigue(hf_id)
    if not df.global.world.status.interrogation_reports then return false end
    local reports = df.global.world.status.interrogation_reports
    for i = 0, #reports - 1 do
        local report = reports[i]
        if report and report.subject_hf == hf_id then
            local ok, succ = pcall(function() return report.intcr.flags.successful end)
            local has_reveals = false
            pcall(function()
                if #report.confessed_target_crime_id > 0 or #report.revealed_agreement_id > 0 then
                    has_reveals = true
                end
            end)
            if (ok and succ) or has_reveals then
                return true
            end
        end
    end
    return false
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
        no_armok_locked = false,
    }
    if not hf or not hf.info or not hf.info.relationships then return data end
    local intrigues = hf.info.relationships.intrigues
    if not intrigues then return data end

    data.has_intrigues = true
    
    local no_armok_active = false
    pcall(function()
        no_armok_active = require('plugins.overlay').isOverlayEnabled('gui/justice-hq.no_armok')
    end)
    
    if no_armok_active and not hasConfessedToIntrigue(hf.id) then
        data.no_armok_locked = true
        data.is_villain = false
        return data
    end

    -- Gather plots
    if intrigues.plots then
        for _, plot in ipairs(intrigues.plots) do
            if plot then
                local plot_type_name = "Unknown"
                pcall(function() plot_type_name = df.intrigue_plot_type[plot.plot_type] or "Unknown" end)
                local actor_ids = {}
                if plot.plot_agreements then
                    for _, pa in ipairs(plot.plot_agreements) do
                        if pa then
                            pcall(function() table.insert(actor_ids, pa.actor_id) end)
                        end
                    end
                end
                
                local on_hold = false
                pcall(function() on_hold = plot.flags.on_hold end)
                
                table.insert(data.plots, {
                    type_name = plot_type_name,
                    on_hold = on_hold,
                    actor_ids = actor_ids,
                    parameter = plot.parameter or -1,
                    actor_nemesis_id = plot.actor_nemesis_id or -1,
                    agreement = plot.agreement or -1,
                    parent_plot = plot.parent_plot or -1,
                })
                data.plot_count = data.plot_count + 1
            end
        end
    end

    -- Gather intrigue actors (the villain's perspective on other people)
    if intrigues.intrigue then
        for _, actor in ipairs(intrigues.intrigue) do
            if actor then
                local role_name = "Unknown"
                pcall(function() role_name = df.plot_role_type[actor.role] or "Unknown" end)
                local strategy_name = "Unknown"
                pcall(function() strategy_name = df.plot_strategy_type[actor.strategy] or "Unknown" end)
                
                local hf_1, hf_2, handle_actor_id, active_plot_ids = -1, -1, -1, nil
                pcall(function()
                    hf_1 = actor.hf_1
                    hf_2 = actor.hf_2
                    handle_actor_id = actor.handle_actor_id
                    active_plot_ids = actor.active_plot_id
                end)
                
                table.insert(data.actors, {
                    hf_1 = hf_1,
                    hf_2 = hf_2,
                    role_name = role_name,
                    strategy_name = strategy_name,
                    handle_actor_id = handle_actor_id,
                    active_plot_ids = active_plot_ids,
                })
                data.actor_count = data.actor_count + 1
            end
        end
    end

    data.is_villain = (data.plot_count > 0 or data.actor_count > 0)
    return data
end

IntelReportScreen = defclass(IntelReportScreen, gui.FramedScreen)
IntelReportScreen.ATTRS = {
    frame_style = gui.FRAME_MEDIUM,
    frame_title = "Intel Report",
    frame_width = 85,
    frame_height = 35,
    frame_inset = 1,
    report_text = "",
}

function IntelReportScreen:init()
    self:addviews{
        widgets.Label{
            frame = {t = 0, l = 0, r = 0, b = 2},
            text = self.report_text,
            auto_height = false,
            scroll_keys = {
                UP = -1, DOWN = 1,
                PAGE_UP = -10, PAGE_DOWN = 10,
            },
        },
        widgets.HotkeyLabel{
            frame = {b = 0, l = 0, w = 12},
            key = 'LEAVESCREEN',
            label = 'Close',
            on_activate = function() self:dismiss() end,
        },
        widgets.HotkeyLabel{
            frame = {b = 0, l = 15, w = 14},
            key = 'CUSTOM_CTRL_C',
            label = 'Copy',
            on_activate = self:callback('copyReport'),
        },
        widgets.HotkeyLabel{
            frame = {b = 0, l = 32, w = 11},
            key = 'CUSTOM_C',
            label = 'Export',
            on_activate = self:callback('exportReport'),
        },
    }
end

function IntelReportScreen:copyReport()
    local clipboard_text = self.report_text:gsub('\226\128\148', '--')
    dfhack.internal.setClipboardTextCp437Multiline(clipboard_text)
    cihq_announce("CI-HQ: Intel Report copied to clipboard.", COLOR_LIGHTGREEN, true)
end

function IntelReportScreen:exportReport()
    local export_path = dfhack.getHackPath() .. '/ci-hq-report.txt'
    local f = io.open(export_path, 'wb')
    if f then
        f:write('\239\187\191')
        f:write(self.report_text)
        f:close()
        cihq_announce("CI-HQ: Report exported to " .. export_path, COLOR_LIGHTGREEN, true)
    else
        cihq_announce("CI-HQ: Could not export report.", COLOR_RED, true)
    end
end

function IntelReportScreen:onInput(keys)
    if keys.LEAVESCREEN or keys._MOUSE_R then
        self:dismiss()
        return true
    end
    self.super.onInput(self, keys)
end

JusticeHQ = defclass(JusticeHQ, gui.ZScreen)
JusticeHQ.ATTRS = {
    focus_path = 'justice-hq',
    pass_movement_keys = false,
    pass_mouse_clicks = false,
}

function JusticeHQ:init()
    fixGhostCases()
    self.filter_level = PERSISTENT_UI.filter_level or 1
    self.case_filter_level = PERSISTENT_UI.case_filter_level or 1
    self.convict_filter_level = PERSISTENT_UI.convict_filter_level or 1
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
                    labels = {'Suspects', 'Cases', 'Warrants', 'Prisoners', 'Network', 'Dossier', 'Intel'},
                    on_select = function(idx)
                        PERSISTENT_UI.active_tab = idx
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
                    frame = {t = 3, l = 0, r = 0, b = 5},
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
                                    edit_on_change = function(text) PERSISTENT_UI.search_text[1] = text end,
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
                                    edit_on_change = function(text) PERSISTENT_UI.search_text[2] = text end,
                                    on_select = self:callback('onSelectCase'),
                                    on_submit = self:callback('onSubmitCase'),
                                },
                            },
                        },
                        -- PAGE 3: Warrants (FilteredList, cards)
                        widgets.Panel{
                            frame = {t = 0, l = 0, r = 0, b = 0},
                            frame_style = gui.FRAME_INTERIOR,
                            frame_title = 'Pending Warrants',
                            subviews = {
                                widgets.FilteredList{
                                    view_id = 'warrants_list',
                                    frame = {t = 0, l = 0, r = 0, b = 0},
                                    row_height = 2,
                                    choices = self:buildWarrantsChoices(),
                                    edit_on_change = function(text) PERSISTENT_UI.search_text[3] = text end,
                                    on_select = self:callback('onSelectWarrant'),
                                    on_submit = self:callback('onSubmitWarrant'),
                                },
                            },
                        },
                        -- PAGE 4: Active Prisoners (FilteredList, cards)
                        widgets.Panel{
                            frame = {t = 0, l = 0, r = 0, b = 0},
                            frame_style = gui.FRAME_INTERIOR,
                            frame_title = 'Active Prisoners',
                            subviews = {
                                widgets.FilteredList{
                                    view_id = 'convicts_list',
                                    frame = {t = 0, l = 0, r = 0, b = 0},
                                    row_height = 2,
                                    choices = self:buildConvictChoices(),
                                    edit_on_change = function(text) PERSISTENT_UI.search_text[4] = text end,
                                    on_select = self:callback('onSelectConvict'),
                                    on_submit = self:callback('onSubmitConvict'),
                                },
                            },
                        },
                        -- PAGE 5: Network Map (grouped list)
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
                        -- PAGE 6: Case File (Profile)
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
                        -- PAGE 7: Intel Reports
                        widgets.Panel{
                            frame = {t = 0, l = 0, r = 0, b = 0},
                            frame_style = gui.FRAME_INTERIOR,
                            frame_title = 'Intel Reports',
                            subviews = {
                                widgets.FilteredList{
                                    view_id = 'intel_list',
                                    frame = {t = 0, l = 0, r = 0, b = 0},
                                    row_height = 4,
                                    choices = {},
                                    edit_on_change = function(text) PERSISTENT_UI.search_text[7] = text end,
                                    on_submit = self:callback('onSubmitIntelReport'),
                                },
                            },
                        },
                    },
                },
                -- Bottom Controls
                widgets.Panel{
                    frame = {b = 0, l = 0, r = 0, h = 5},
                    frame_background = gui.CLEAR_PEN,
                    frame_style = gui.FRAME_MEDIUM,
                    subviews = {
                        widgets.CycleHotkeyLabel{
                            view_id = 'filter_cycle',
                            frame = {l = 0, t = 0},
                            key = 'CUSTOM_CTRL_F',
                            label = 'Show:',
                            options = {
                                {label = 'High threats', value = 1, pen = COLOR_RED},
                                {label = 'High + Medium', value = 2, pen = COLOR_YELLOW},
                                {label = 'All + Detained', value = 3, pen = COLOR_CYAN},
                                {label = 'Everyone', value = 4, pen = COLOR_GREEN},
                                {label = 'Convictable', value = 5, pen = COLOR_LIGHTMAGENTA},
                            },
                            initial_option = PERSISTENT_UI.filter_level or 1,
                            on_change = self:callback('onFilterChange'),
                            visible = function() return self.subviews.pages:getSelected() == 1 end,
                        },
                        widgets.CycleHotkeyLabel{
                            view_id = 'cases_filter_cycle',
                            frame = {l = 0, t = 0},
                            key = 'CUSTOM_CTRL_F',
                            label = 'Show:',
                            options = {
                                {label = 'Open Cases', value = 1, pen = COLOR_LIGHTRED},
                                {label = 'Cold Cases', value = 2, pen = COLOR_CYAN},
                                {label = 'Closed Cases', value = 3, pen = COLOR_DARKGREY},
                                {label = 'All Cases', value = 4, pen = COLOR_GREEN},
                            },
                            initial_option = PERSISTENT_UI.case_filter_level or 1,
                            on_change = self:callback('onCasesFilterChange'),
                            visible = function() return self.subviews.pages:getSelected() == 2 end,
                        },
                        widgets.CycleHotkeyLabel{
                            view_id = 'convicts_filter',
                            frame = {l = 0, t = 0},
                            key = 'CUSTOM_CTRL_F',
                            label = 'Show:',
                            options = {
                                {label = 'All Sentences', value = 1, pen = COLOR_WHITE},
                                {label = 'Prison Only', value = 2, pen = COLOR_CYAN},
                                {label = 'Beatings / Executions', value = 3, pen = COLOR_LIGHTRED},
                            },
                            initial_option = PERSISTENT_UI.convict_filter_level or 1,
                            on_change = self:callback('onConvictsFilterChange'),
                            visible = function() return self.subviews.pages:getSelected() == 4 end,
                        },
                        -- SORTS
                        widgets.CycleHotkeyLabel{
                            view_id = 'suspect_sort',
                            frame = {l = 30, t = 0},
                            key = 'CUSTOM_CTRL_S',
                            label = 'Sort:',
                            options = {
                                {label = 'Threat Level', value = 1, pen = COLOR_WHITE},
                                {label = 'Name', value = 2, pen = COLOR_WHITE},
                            },
                            initial_option = PERSISTENT_UI.suspect_sort or 1,
                            on_change = self:callback('onFilterChange'),
                            visible = function() return self.subviews.pages:getSelected() == 1 end,
                        },
                        widgets.CycleHotkeyLabel{
                            view_id = 'cases_sort',
                            frame = {l = 30, t = 0},
                            key = 'CUSTOM_CTRL_S',
                            label = 'Sort:',
                            options = {
                                {label = 'Newest Cases', value = 1, pen = COLOR_WHITE},
                                {label = 'Crime Type', value = 2, pen = COLOR_WHITE},
                                {label = 'Accused Name', value = 3, pen = COLOR_WHITE},
                                {label = 'Victim Name', value = 4, pen = COLOR_WHITE},
                            },
                            initial_option = PERSISTENT_UI.cases_sort or 1,
                            on_change = self:callback('onCasesFilterChange'),
                            visible = function() return self.subviews.pages:getSelected() == 2 end,
                        },
                        widgets.CycleHotkeyLabel{
                            view_id = 'convicts_sort',
                            frame = {l = 30, t = 0},
                            key = 'CUSTOM_CTRL_S',
                            label = 'Sort:',
                            options = {
                                {label = 'Time Left', value = 1, pen = COLOR_WHITE},
                                {label = 'Name', value = 2, pen = COLOR_WHITE},
                            },
                            initial_option = PERSISTENT_UI.convicts_sort or 1,
                            on_change = self:callback('onConvictsFilterChange'),
                            visible = function() return self.subviews.pages:getSelected() == 4 end,
                        },
                        -- Network filter
                        widgets.CycleHotkeyLabel{
                            view_id = 'network_filter_cycle',
                            frame = {l = 0, t = 0},
                            key = 'CUSTOM_CTRL_F',
                            label = 'Show:',
                            options = {
                                {label = 'Active Plots Only', value = 1, pen = COLOR_WHITE},
                                {label = 'Large Networks', value = 2, pen = COLOR_WHITE},
                                {label = 'All Networks', value = 3, pen = COLOR_WHITE},
                            },
                            initial_option = PERSISTENT_UI.network_filter or 1,
                            on_change = function(val)
                                PERSISTENT_UI.network_filter = val
                                self:rebuildActiveTab()
                            end,
                            visible = function() return self.subviews.pages:getSelected() == 5 end,
                        },
                        widgets.CycleHotkeyLabel{
                            view_id = 'network_sort_cycle',
                            frame = {l = 30, t = 0, w = 28},
                            key = 'CUSTOM_CTRL_S',
                            label = 'Sort:',
                            options = {
                                {label = 'Network Size', value = 1, pen = COLOR_WHITE},
                                {label = 'Mastermind Name', value = 2, pen = COLOR_WHITE},
                            },
                            initial_option = PERSISTENT_UI.network_sort or 1,
                            on_change = function(val)
                                PERSISTENT_UI.network_sort = val
                                self:rebuildActiveTab()
                            end,
                            visible = function() return self.subviews.pages:getSelected() == 5 end,
                        },
                        -- Intel Reports filter
                        widgets.CycleHotkeyLabel{
                            view_id = 'intel_filter_cycle',
                            frame = {l = 0, t = 0},
                            key = 'CUSTOM_CTRL_F',
                            label = 'Show:',
                            options = {
                                {label = 'Actionable Intel', value = 1, pen = COLOR_RED},
                                {label = 'New Confessions', value = 2, pen = COLOR_YELLOW},
                                {label = 'Refused / No Info', value = 3, pen = COLOR_DARKGREY},
                                {label = 'All Reports', value = 4, pen = COLOR_GREEN},
                            },
                            initial_option = PERSISTENT_UI.intel_filter_level or 1,
                            on_change = function(val)
                                PERSISTENT_UI.intel_filter_level = val
                                self:rebuildActiveTab()
                            end,
                            visible = function() return self.subviews.pages:getSelected() == 7 end,
                        },
                        widgets.CycleHotkeyLabel{
                            view_id = 'intel_sort_cycle',
                            frame = {l = 36, t = 0, w = 30},
                            key = 'CUSTOM_CTRL_S',
                            label = 'Sort:',
                            options = {
                                {label = 'Newest First', value = 1, pen = COLOR_WHITE},
                                {label = 'Oldest First', value = 2, pen = COLOR_WHITE},
                                {label = 'Subject Name', value = 3, pen = COLOR_WHITE},
                                {label = 'Officer Name', value = 4, pen = COLOR_WHITE},
                                {label = 'Most Intel', value = 5, pen = COLOR_WHITE},
                            },
                            initial_option = PERSISTENT_UI.intel_sort or 1,
                            on_change = function(val)
                                PERSISTENT_UI.intel_sort = val
                                self:rebuildActiveTab()
                            end,
                            visible = function() return self.subviews.pages:getSelected() == 7 end,
                        },
                        -- ACTIONS
                        widgets.HotkeyLabel{
                            frame = {l = 0, t = 1, w = 15},
                            key = 'CUSTOM_I',
                            label = 'Interrogate',
                            text_pen = COLOR_LIGHTGREEN,
                            disabled_pen = COLOR_DARKGREY,
                            disabled = false,
                            visible = function()
                                if self.selected_suspect and self.selected_suspect.unit then
                                    local watch = interrogation_watchlist[self.selected_suspect.unit.id]
                                    return not watch or (watch.status ~= 'active' and watch.status ~= 'dispatched')
                                end
                                return true
                            end,
                            on_activate = self:callback('onInterrogate'),
                        },
                        widgets.HotkeyLabel{
                            frame = {l = 0, t = 1, w = 15},
                            key = 'CUSTOM_I',
                            label = 'Cancel',
                            text_pen = COLOR_YELLOW,
                            visible = function()
                                if self.selected_suspect and self.selected_suspect.unit then
                                    local watch = interrogation_watchlist[self.selected_suspect.unit.id]
                                    return watch and (watch.status == 'active' or watch.status == 'dispatched')
                                end
                                return false
                            end,
                            on_activate = self:callback('onInterrogate'),
                        },
                        widgets.HotkeyLabel{
                            frame = {l = 0, t = 2, w = 15},
                            key = 'SELECT',
                            label = 'Convict',
                            text_pen = COLOR_LIGHTRED,
                            visible = function()
                                return self.selected_suspect and isConvictable(self.selected_suspect)
                            end,
                            on_activate = self:callback('onConvict'),
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
    
    self.subviews.pages:setSelected(PERSISTENT_UI.active_tab or 1)
    if PERSISTENT_UI.active_tab == 6 and self.selected_suspect then
        self:onOpenCaseFile(nil, {data = self.selected_suspect})
    else
        self:rebuildActiveTab()
    end
    self.init_complete = true
end

-- ===========================
-- Evidence Scoring
-- ===========================

function getCrimeName(mode)
    -- Try the enum first (most accurate)
    local raw = df.crime_type and df.crime_type[mode]
    if raw then
        -- Provide readable names for common crime types
        local readable = {
            ProductionOrderViolation = "Production Mandate Violation",
            ExportViolation = "Export Mandate Violation",
            JobOrderViolation = "Job Order Violation",
            ConspiracyToSlowLabor = "Conspiracy to Slow Labor",
            DisorderlyBehavior = "Disorderly Conduct",
            BuildingDestruction = "Building Destruction",
            BloodDrinking = "Blood Drinking",
            AttemptedMurder = "Attempted Murder",
            AttemptedKidnapping = "Attempted Kidnapping",
            AttemptedTheft = "Attempted Theft",
            Treason = "Treason / Artifact Theft",
        }
        return readable[raw] or raw
    end
    
    return "Unknown Crime (Type " .. tostring(mode) .. ")"
end

function JusticeHQ:buildEvidence(s)
    local evidence = {}
    local score = 0

    -- 1. Intrigue perspective (Fort Mode espionage data)
    local hf = df.historical_figure.find(s.unit.hist_figure_id)
    local idata = hf and getHfIntrigueData(hf)
    local player_site = -1
    local player_entity = -1
    pcall(function() player_site = df.global.plotinfo.site_id end)
    pcall(function() player_entity = df.global.plotinfo.civ_id end)

    -- Tiered plot scoring tables
    local PLOT_SCORE = {
        -- Tier 1: Real fort-mode threats
        Acquire_Artifact = 120,       -- verified via artifact.site
        Infiltrate_Society = 60,      -- verified via entity_links
        Grow_Corruption_Network = 40,
        Grow_Asset_Network = 25,
        -- Tier 2: Indirect / political
        Attain_Rank = 30,
        Frame_Actor = 25,
        Corruptly_Punish_Actor = 20,
        Corrupt_Actors_Government = 20,
        Grow_Funding_Network = 10,
        -- Tier 3: World-level (do not execute in fortress mode)
        Assassinate_Actor = 5,
        Kidnap_Actor = 5,
        Direct_War_To_Actor = 5,
        Sabotage_Actor = 5,
        Counterintelligence = 5,
        Become_Immortal = 5,
        Undead_World_Conquest = 5,
    }
    local PLOT_DESC = {
        Acquire_Artifact = "Plotting to steal a specific fortress artifact.",
        Infiltrate_Society = "Embedding covert agents to gather intelligence and undermine governance.",
        Grow_Corruption_Network = "Recruiting corrupt officials to serve as informants and co-conspirators.",
        Grow_Asset_Network = "Building an operative network to provide logistical support for larger operations.",
        Attain_Rank = "Manipulating fortress politics to gain a position of authority.",
        Frame_Actor = "Planting false evidence to trigger wrongful convictions.",
        Corruptly_Punish_Actor = "Abusing a position of authority to unjustly punish someone.",
        Corrupt_Actors_Government = "Undermining civilization-level governance through bribery and coercion.",
        Grow_Funding_Network = "Soliciting financial backing from wealthy contacts.",
        Assassinate_Actor = "World-level assassination plot. Does not execute against fortress residents.",
        Kidnap_Actor = "World-level abduction plot. No in-fortress abductions expected.",
        Direct_War_To_Actor = "World-level military redirection. Does not directly affect fortress defense.",
        Sabotage_Actor = "World-level sabotage operation. No in-fortress destruction expected.",
        Counterintelligence = "Defensive counter-spy operations. Detecting enemy spies, not attacking.",
        Become_Immortal = "Pursuing personal immortality. No direct fortress impact.",
        Undead_World_Conquest = "Raising undead forces on the world stage. Long-term existential threat.",
    }
    local PLOT_COLOR = {
        Acquire_Artifact = COLOR_LIGHTRED,
        Infiltrate_Society = COLOR_LIGHTMAGENTA,
        Grow_Corruption_Network = COLOR_YELLOW,
        Grow_Asset_Network = COLOR_YELLOW,
        Attain_Rank = COLOR_YELLOW,
        Frame_Actor = COLOR_LIGHTMAGENTA,
        Corruptly_Punish_Actor = COLOR_YELLOW,
        Corrupt_Actors_Government = COLOR_YELLOW,
        Grow_Funding_Network = COLOR_BROWN,
        Assassinate_Actor = COLOR_DARKGREY,
        Kidnap_Actor = COLOR_DARKGREY,
        Direct_War_To_Actor = COLOR_DARKGREY,
        Sabotage_Actor = COLOR_DARKGREY,
        Counterintelligence = COLOR_DARKGREY,
        Become_Immortal = COLOR_DARKGREY,
        Undead_World_Conquest = COLOR_DARKGREY,
    }

    if hf then
        if idata and idata.is_villain then
            -- Score plots with tiered system
            for _, plot in ipairs(idata.plots) do
                local type_key = plot.type_name
                local base_pts = PLOT_SCORE[type_key] or 10
                local desc = PLOT_DESC[type_key] or "Unknown plot type."
                local color = PLOT_COLOR[type_key] or COLOR_YELLOW
                local label_prefix = "Active plot: "

                if plot.on_hold then
                    -- On-hold plots get reduced scoring
                    base_pts = math.max(math.floor(base_pts * 0.2), 5)
                    label_prefix = "Plot on hold: "
                    color = COLOR_DARKGREY
                    desc = "Dormant plot. Could reactivate."
                end

                local op_notes = {}
                -- Tier 1 verification: Acquire_Artifact — check if artifact is at our site
                if type_key == "Acquire_Artifact" and plot.parameter > 0 and not plot.on_hold then
                    local art_name = "unknown artifact"
                    local at_our_site = false
                    pcall(function()
                        local artifact = df.artifact_record.find(plot.parameter)
                        if artifact then
                            pcall(function() 
                                local translated = dfhack.translation.translateName(artifact.name, true)
                                local untranslated = dfhack.translation.translateName(artifact.name, false)
                                if translated ~= "" and untranslated ~= "" and translated ~= untranslated then
                                    art_name = translated .. " '" .. untranslated .. "'"
                                elseif translated ~= "" then
                                    art_name = translated
                                elseif untranslated ~= "" then
                                    art_name = untranslated
                                end
                            end)
                            
                            -- Extract the actual item type (e.g. "pig tail turban")
                            pcall(function()
                                if artifact.item then
                                    local item = df.item.find(artifact.item.id)
                                    if item then
                                        local item_desc = dfhack.items.getDescription(item, 0, true)
                                        art_name = art_name .. " (" .. item_desc .. ")"
                                    end
                                elseif artifact.item_id and artifact.item_id >= 0 then
                                    local item = df.item.find(artifact.item_id)
                                    if item then
                                        local item_desc = dfhack.items.getDescription(item, 0, true)
                                        art_name = art_name .. " (" .. item_desc .. ")"
                                    end
                                end
                            end)
                            
                            at_our_site = (artifact.site == player_site)
                        end
                    end)
                    if at_our_site then
                        base_pts = 120
                        desc = "Targeting fortress artifact '" .. art_name .. "' for theft. Immediate interception recommended."
                        color = COLOR_LIGHTRED
                        table.insert(op_notes, "Direct Threat: Targeting an artifact currently at your fortress.")
                    else
                        base_pts = 30
                        desc = "Seeking artifact '" .. art_name .. "' located elsewhere. Not a direct fortress threat."
                        color = COLOR_GREY
                    end
                end

                -- Tier 1 verification: Infiltrate_Society — check if targeting our site government
                if type_key == "Infiltrate_Society" and plot.parameter > 0 and not plot.on_hold then
                    local targets_us = false
                    local ent_name = "unknown"
                    pcall(function()
                        local target_ent = df.historical_entity.find(plot.parameter)
                        if target_ent then
                            pcall(function() ent_name = dfhack.translation.translateName(target_ent.name, true) end)
                            if target_ent.entity_links then
                                for _, link in ipairs(target_ent.entity_links) do
                                    if link.target == player_entity then
                                        targets_us = true
                                        break
                                    end
                                end
                            end
                        end
                    end)
                    if targets_us then
                        base_pts = 60
                        desc = "Infiltrating our site government ('" .. ent_name .. "'). Covert agents are embedding into the population."
                        color = COLOR_LIGHTMAGENTA
                    else
                        base_pts = 15
                        desc = "Infiltrating '" .. ent_name .. "' (external organization)."
                        color = COLOR_GREY
                    end
                end

                -- Context bonuses for active plots
                local context_bonus = 0
                if not plot.on_hold then
                    if plot.actor_nemesis_id > 0 then
                        context_bonus = context_bonus + 20
                        local agent_name = "an operative"
                        pcall(function()
                            local nem = df.nemesis_record.find(plot.actor_nemesis_id)
                            if nem and nem.figure then
                                local translated = dfhack.translation.translateName(nem.figure.name, true)
                                if translated ~= "" then agent_name = "'" .. translated .. "'" end
                            end
                        end)
                        table.insert(op_notes, "Operative Deployed: " .. agent_name .. " is actively executing this plot.")
                    end
                    if plot.agreement > 0 then
                        context_bonus = context_bonus + 15
                        table.insert(op_notes, "Deal Finalized: A concrete agreement is in place.")
                    end
                    if plot.parent_plot > 0 then
                        context_bonus = context_bonus + 10
                        table.insert(op_notes, "Conspiracy Chain: Linked to a larger master operation.")
                    end
                end

                local pts = base_pts + context_bonus
                score = score + pts
                
                table.insert(evidence, {
                    text = label_prefix .. plot.type_name:gsub("_", " "),
                    detail = desc,
                    op_notes = op_notes,
                    pts = pts, color = color,
                })
            end
            -- Score network size
            if idata.actor_count > 0 then
                local pts = math.min(idata.actor_count * 10, 50)
                score = score + pts
                table.insert(evidence, {
                    text = "Maintains intelligence network (" .. idata.actor_count .. " actors)",
                    detail = "This person coordinates other agents operating in your fortress.",
                    op_notes = {},
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
                color = COLOR_DARKGREY
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
                detail = "An active criminal investigation - this person is a suspect."
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
                detail = "Secured in a cage - not an immediate escape risk.",
                pts = pts, color = COLOR_GREEN,
            })
        elseif s.crime_data.is_chained then
            local pts = -20
            score = score + pts
            table.insert(evidence, {
                text = "Currently CHAINED (secured)",
                detail = "Restrained at a chain - limited movement.",
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
                text = "CONFESSED - intelligence extracted",
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
        if self.filter_level == 5 and isConvictable(s) then show = true end

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
            }
            if isConvictable(s) then
                table.insert(text_arr, {text = "  [CONVICTABLE]", pen = COLOR_LIGHTRED})
            end
            table.insert(text_arr, NEWLINE)
            table.insert(text_arr, {text = "   Threat: ", pen = COLOR_DARKGREY})
            table.insert(text_arr, {text = string.upper(s.threat), pen = threat_color})
            table.insert(text_arr, {text = string.format(" [%d pts]                     ", s.score), pen = COLOR_DARKGREY})
            table.insert(text_arr, {text = (earliest_year and ("Y." .. earliest_year) or ""), pen = COLOR_BROWN})
            table.insert(text_arr, NEWLINE)
            table.insert(text_arr, {text = string.format("   %-35s", crimes_summary), pen = COLOR_GREY})
            table.insert(text_arr, {text = top_strategy ~= "" and top_strategy or "", pen = STRATEGY_COLORS[top_strategy and top_strategy:gsub(" ", "_") or ""] or COLOR_YELLOW})
            table.insert(text_arr, {text = cell_str ~= "" and ("  " .. cell_str) or "", pen = COLOR_CYAN})
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
    if self.subviews.filter_cycle then
        PERSISTENT_UI.filter_level = self.subviews.filter_cycle:getOptionValue()
        self.filter_level = PERSISTENT_UI.filter_level
    end
    if self.subviews.suspect_sort then
        PERSISTENT_UI.suspect_sort = self.subviews.suspect_sort:getOptionValue()
    end
    local list = self.subviews.suspect_list
    list:setChoices(self:buildChoices())
    local choices = list:getChoices()
    if #choices > 0 then
        self:onSelectSuspect(list:getSelected(), choices[list:getSelected()])
    end
end

function JusticeHQ:onCasesFilterChange(new_val)
    if self.subviews.cases_filter_cycle then
        PERSISTENT_UI.case_filter_level = self.subviews.cases_filter_cycle:getOptionValue()
        self.case_filter_level = PERSISTENT_UI.case_filter_level
    end
    if self.subviews.cases_sort then
        PERSISTENT_UI.cases_sort = self.subviews.cases_sort:getOptionValue()
    end
    local list = self.subviews.cases_list
    list:setChoices(self:buildCaseChoices())
end

function JusticeHQ:onConvictsFilterChange(new_val)
    if self.subviews.convicts_filter then
        PERSISTENT_UI.convict_filter_level = self.subviews.convicts_filter:getOptionValue()
        self.convict_filter_level = PERSISTENT_UI.convict_filter_level
    end
    if self.subviews.convicts_sort then
        PERSISTENT_UI.convicts_sort = self.subviews.convicts_sort:getOptionValue()
    end
    local list = self.subviews.convicts_list
    if list then
        list:setChoices(self:buildConvictChoices())
    end
end

function JusticeHQ:onSearchChange(text)
    -- Remove manual search logic; FilteredList handles it natively.
end

function JusticeHQ:setListChoices(list_view, choices, id_func)
    local selected_idx = 1
    if GLOBAL_SELECTED_SUSPECT_ID then
        for i, choice in ipairs(choices) do
            local uid
            if id_func then 
                uid = id_func(choice)
            elseif choice.data then
                if type(choice.data) == 'table' then
                    if choice.data.unit then uid = choice.data.unit.id
                    elseif choice.data.accused then uid = choice.data.accused
                    end
                elseif type(choice.data) == 'userdata' then
                    pcall(function()
                        if tostring(choice.data._type):find('crime') then
                            uid = choice.data.accused
                        end
                    end)
                end
            end
            if uid == GLOBAL_SELECTED_SUSPECT_ID then
                selected_idx = i
                break
            end
        end
    end
    self.rebuilding_tab = true
    list_view:setChoices(choices, selected_idx)
    self.rebuilding_tab = false
end

function JusticeHQ:rebuildActiveTab()
    local page = self.subviews.pages:getSelected()
    if page == 1 then
        self:setListChoices(self.subviews.suspect_list, self:buildChoices())
        if PERSISTENT_UI.search_text[1] then self.subviews.suspect_list:setFilter(PERSISTENT_UI.search_text[1]) end
    elseif page == 2 then
        initCrimeCache()  -- Refresh crime cache so new crimes appear
        self:setListChoices(self.subviews.cases_list, self:buildCaseChoices())
        if PERSISTENT_UI.search_text[2] then self.subviews.cases_list:setFilter(PERSISTENT_UI.search_text[2]) end
    elseif page == 3 then
        initCrimeCache()  -- Refresh crime cache so new warrants appear
        self:setListChoices(self.subviews.warrants_list, self:buildWarrantsChoices())
        if PERSISTENT_UI.search_text[3] then self.subviews.warrants_list:setFilter(PERSISTENT_UI.search_text[3]) end
    elseif page == 4 then
        self:setListChoices(self.subviews.convicts_list, self:buildConvictChoices())
        if PERSISTENT_UI.search_text[4] then self.subviews.convicts_list:setFilter(PERSISTENT_UI.search_text[4]) end
    elseif page == 5 then
        self:setListChoices(self.subviews.network_list, self:buildNetworkChoices())
    elseif page == 6 then
        -- Case File tab: content is populated by onOpenCaseFile, not rebuilt on tab switch.
        -- If no suspect is selected, show guidance.
        if not self.selected_suspect then
            local case_file = self.subviews.case_file
            if case_file then
                case_file:setText({{text = '  Select a suspect and press Enter to open their dossier.', pen = COLOR_GREY}})
                if case_file.frame_body then case_file:updateLayout() end
            end
        else
            self:refreshCurrentDossier()
        end
    elseif page == 7 then
        local ok, result = pcall(function() return self:buildIntelChoices() end)
        if not ok then
            dfhack.printerr("Error in buildIntelChoices: " .. tostring(result))
            self.subviews.intel_list:setChoices({{text = "ERROR: " .. tostring(result)}})
        else
            self.subviews.intel_list:setChoices(result)
            if PERSISTENT_UI.search_text[7] then self.subviews.intel_list:setFilter(PERSISTENT_UI.search_text[7]) end
        end
    end
end

-- ===========================
-- Intel Reports Tab
-- ===========================

local INTEL_SEASONS = {'Spring', 'Summer', 'Autumn', 'Winter'}
local INTEL_METHOD_NAMES = {}
do
    local ok, imt = pcall(function() return df.interrogation_method_type end)
    if ok and imt then
        INTEL_METHOD_NAMES[imt.INTIMIDATE] = 'Intimidation'
        INTEL_METHOD_NAMES[imt.FLATTER] = 'Flattery'
        INTEL_METHOD_NAMES[imt.RELIGIOUS_SYMPATHY] = 'Religious Sympathy'
        INTEL_METHOD_NAMES[imt.APPEAL_TO_VALUE] = 'Appeal to Values'
        INTEL_METHOD_NAMES[imt.BUILD_RAPPORT] = 'Build Rapport'
        INTEL_METHOD_NAMES[imt.LIE] = 'Deception'
    else
        -- Fallback: numeric enum values (from df.d_basics.xml)
        INTEL_METHOD_NAMES[0] = 'Intimidation'
        INTEL_METHOD_NAMES[1] = 'Flattery'
        INTEL_METHOD_NAMES[2] = 'Religious Sympathy'
        INTEL_METHOD_NAMES[3] = 'Appeal to Values'
        INTEL_METHOD_NAMES[4] = 'Build Rapport'
        INTEL_METHOD_NAMES[5] = 'Deception'
    end
end

local function intelTickToSeason(tick)
    if not tick or tick < 0 then return '???' end
    return INTEL_SEASONS[math.floor(tick / 100800) % 4 + 1] or '???'
end

local function resolveHFName(hfid)
    if not hfid or hfid < 0 then return 'Unknown', '' end
    local hf = df.historical_figure.find(hfid)
    if not hf then return 'Unknown', '' end
    local name = 'Unknown'
    pcall(function()
        name = dfhack.translation.translateName(hf.name)
        if name == '' then name = dfhack.translation.translateName(hf.name, true) end
    end)
    local unit = hf.unit_id >= 0 and df.unit.find(hf.unit_id) or nil
    local occ = unit and dfhack.units.getProfessionName(unit) or ''
    return name, occ
end

local function computeIntelOutcome(report)
    local has_confessions = #report.confessed_target_crime_id > 0
    local has_identities = #report.confessed_identity_id > 0
    local has_agreements = #report.revealed_agreement_id > 0
    local has_events = #report.revealed_event_id > 0
    local successful = false
    pcall(function() successful = report.intcr.flags.successful end)

    if successful and (has_confessions or has_identities) then
        return 'CONFESSED', COLOR_GREEN
    elseif successful and (has_agreements or has_events) then
        return 'NEW INTEL', COLOR_CYAN
    elseif not successful then
        return 'REFUSED', COLOR_LIGHTRED
    else
        return 'NO NEW INFO', COLOR_DARKGREY
    end
end

function JusticeHQ:buildIntelChoices()
    local list_choices = {}
    local filter = PERSISTENT_UI.intel_filter_level or 1
    local sort_mode = PERSISTENT_UI.intel_sort or 1

    -- Read the global interrogation reports store
    local reports = df.global.world.status.interrogation_reports
    -- (debug line removed for release)

    -- Build raw entries
    local entries = {}
    if reports then
        for i = 0, #reports - 1 do
        local report = reports[i]
        if report then
            local subject_name, subject_occ = resolveHFName(report.subject_hf)
            local outcome_label, outcome_color = computeIntelOutcome(report)
            local is_unread = not report.flags.viewed
            local has_confessions = #report.confessed_target_crime_id > 0
            local has_identities = #report.confessed_identity_id > 0
            local has_agreements = #report.revealed_agreement_id > 0
            local has_events = #report.revealed_event_id > 0
            local intel_count = #report.confessed_target_crime_id + #report.confessed_identity_id + #report.revealed_agreement_id + #report.revealed_event_id
            local method_name = 'Unknown'
            pcall(function() method_name = INTEL_METHOD_NAMES[report.intcr.method] or 'Unknown' end)
            local season_str = intelTickToSeason(report.tick)
            local officer_str = report.officer_name or 'Unknown'

            -- Filter logic
            local include = false
            if filter == 4 then
                include = true
            elseif filter == 1 then
                -- Actionable Intel: unread OR has confessions/identities/agreements
                include = is_unread or has_confessions or has_identities or has_agreements
            elseif filter == 2 then
                -- New Confessions only
                include = has_confessions or has_identities or has_agreements
            elseif filter == 3 then
                -- Refused / No Info
                local intcr_ok, intcr_succ = pcall(function() return report.intcr.flags.successful end)
                include = (intcr_ok and not intcr_succ) or (intcr_ok and intcr_succ and intel_count == 0)
            end

            if include then
                table.insert(entries, {
                    report = report,
                    subject_name = subject_name,
                    subject_occ = subject_occ,
                    officer_str = officer_str,
                    outcome_label = outcome_label,
                    outcome_color = outcome_color,
                    is_unread = is_unread,
                    method_name = method_name,
                    season_str = season_str,
                    year = report.year or 0,
                    tick = report.tick or 0,
                    intel_count = intel_count,
                    has_confessions = has_confessions,
                    has_identities = has_identities,
                    has_agreements = has_agreements,
                })
            end
        end
        end
    end

    -- Sort
    if sort_mode == 1 then
        -- Newest First
        table.sort(entries, function(a, b)
            if a.year ~= b.year then return a.year > b.year end
            return a.tick > b.tick
        end)
    elseif sort_mode == 2 then
        -- Oldest First
        table.sort(entries, function(a, b)
            if a.year ~= b.year then return a.year < b.year end
            return a.tick < b.tick
        end)
    elseif sort_mode == 3 then
        -- Subject Name
        table.sort(entries, function(a, b) return a.subject_name < b.subject_name end)
    elseif sort_mode == 4 then
        -- Officer Name
        table.sort(entries, function(a, b) return a.officer_str < b.officer_str end)
    elseif sort_mode == 5 then
        -- Most Intel
        table.sort(entries, function(a, b) return a.intel_count > b.intel_count end)
    end

    -- Build choices
    for _, e in ipairs(entries) do
        local line1_parts = {}
        if e.is_unread then
            table.insert(line1_parts, {text = string.char(15) .. ' UNREAD  ', pen = COLOR_YELLOW})
        end
        table.insert(line1_parts, {text = e.subject_name, pen = COLOR_WHITE})
        if e.subject_occ ~= '' then
            table.insert(line1_parts, {text = ', ' .. e.subject_occ, pen = COLOR_GREY})
        end
        table.insert(line1_parts, {text = ', ' .. e.season_str .. ' ' .. e.year, pen = COLOR_GREY})

        local confession_summary = ''
        if e.has_confessions then
            confession_summary = confession_summary .. #e.report.confessed_target_crime_id .. ' crimes'
        end
        if e.has_identities then
            if confession_summary ~= '' then confession_summary = confession_summary .. ', ' end
            confession_summary = confession_summary .. #e.report.confessed_identity_id .. ' identities'
        end
        if e.has_agreements then
            if confession_summary ~= '' then confession_summary = confession_summary .. ', ' end
            confession_summary = confession_summary .. #e.report.revealed_agreement_id .. ' plots'
        end
        if e.has_events then
            if confession_summary ~= '' then confession_summary = confession_summary .. ', ' end
            confession_summary = confession_summary .. #e.report.revealed_event_id .. ' events'
        end
        if confession_summary == '' then
            confession_summary = 'No new information'
        end

        local text_arr = {}
        for _, p in ipairs(line1_parts) do table.insert(text_arr, p) end
        table.insert(text_arr, NEWLINE)
        table.insert(text_arr, {text = '   Officer: ', pen = COLOR_DARKGREY})
        table.insert(text_arr, {text = e.officer_str, pen = COLOR_CYAN})
        table.insert(text_arr, NEWLINE)
        table.insert(text_arr, {text = '   ', pen = COLOR_GREY})
        table.insert(text_arr, {text = e.outcome_label, pen = e.outcome_color})
        table.insert(text_arr, {text = '  ' .. e.method_name, pen = COLOR_GREY})
        table.insert(text_arr, {text = '  |  ', pen = COLOR_DARKGREY})
        -- Colorize confession summary items individually
        if e.intel_count > 0 then
            local parts = {}
            if e.has_confessions then
                table.insert(parts, {text = #e.report.confessed_target_crime_id .. ' crimes', pen = COLOR_LIGHTRED})
            end
            if e.has_identities then
                table.insert(parts, {text = #e.report.confessed_identity_id .. ' identities', pen = COLOR_LIGHTMAGENTA})
            end
            if e.has_agreements then
                table.insert(parts, {text = #e.report.revealed_agreement_id .. ' plots', pen = COLOR_YELLOW})
            end
            if e.has_events then
                table.insert(parts, {text = #e.report.revealed_event_id .. ' events', pen = COLOR_LIGHTCYAN})
            end
            for i, p in ipairs(parts) do
                table.insert(text_arr, p)
                if i < #parts then
                    table.insert(text_arr, {text = ', ', pen = COLOR_DARKGREY})
                end
            end
        else
            table.insert(text_arr, {text = 'No new information', pen = COLOR_DARKGREY})
        end
        table.insert(text_arr, NEWLINE)

        local searchable = string.lower(e.subject_name .. ' ' .. e.subject_occ .. ' ' .. e.officer_str .. ' ' .. e.outcome_label)
        table.insert(list_choices, {
            text = text_arr,
            search_key = searchable,
            data = e,
        })
    end

    if #list_choices == 0 then
        local empty_msg = 'No intel reports at this filter level.'
        if filter == 1 then
            empty_msg = 'No actionable intel. Interrogate suspects to generate reports.'
        end
        table.insert(list_choices, {
            text = {{text = '  ' .. empty_msg, pen = COLOR_GREY}},
            search_key = '',
            data = nil,
        })
    end

    return list_choices
end

local function wordWrap(text, max_width)
    local lines = {}
    for line in text:gmatch("([^\n]*)\n?") do
        if line == "" then
            table.insert(lines, "")
        else
            local indent = line:match("^(%s*)")
            local current_line = ""
            for word in line:gmatch("%S+") do
                if #current_line == 0 then
                    current_line = indent .. word
                elseif #current_line + 1 + #word > max_width then
                    table.insert(lines, current_line)
                    current_line = indent .. word
                else
                    current_line = current_line .. " " .. word
                end
            end
            if #current_line > 0 then
                table.insert(lines, current_line)
            end
        end
    end
    return lines
end

function JusticeHQ:onSubmitIntelReport(idx, choice)
    if not choice or not choice.data then return end
    local e = choice.data
    local report = e.report
    if not report then return end

    -- Gather full detail text
    local detail_lines = {}
    table.insert(detail_lines, "    " .. (report.title or 'Interrogation Report'))
    table.insert(detail_lines, "    " .. (report.officer_name or ''))
    table.insert(detail_lines, "")

    if report.details then
        for i = 0, #report.details - 1 do
            local str_ptr = report.details[i]
            if str_ptr then
                local line = type(str_ptr) == 'string' and str_ptr or tostring(str_ptr.value or str_ptr)
                table.insert(detail_lines, "    " .. line)
                if i < #report.details - 1 then
                    table.insert(detail_lines, "")
                end
            end
        end
    end

    if #detail_lines <= 3 then
        table.insert(detail_lines, "    Outcome: " .. e.outcome_label)
        table.insert(detail_lines, "    Method: " .. e.method_name)
        if e.has_confessions then
            table.insert(detail_lines, "    Confessed to " .. #report.confessed_target_crime_id .. " crime(s)")
        end
        if e.has_identities then
            table.insert(detail_lines, "    Revealed " .. #report.confessed_identity_id .. " identity/identities")
        end
        if e.has_agreements then
            table.insert(detail_lines, "    Exposed " .. #report.revealed_agreement_id .. " plot(s)")
        end
        if e.has_events then
            table.insert(detail_lines, "    Revealed " .. #report.revealed_event_id .. " event(s)")
        end
    end

    local full_text = table.concat(detail_lines, '\n')
    local wrapped_lines = wordWrap(full_text, 75)
    local wrapped_text = table.concat(wrapped_lines, '\n')

    -- Mark as read
    report.flags.viewed = true

    IntelReportScreen{
        frame_title = 'Intel Report: ' .. e.subject_name,
        report_text = wrapped_text,
    }:show()
    
    -- Rebuild the tab behind the scenes so the unread counter updates
    self:rebuildActiveTab()
end

-- ===========================
-- Build Warrants List
-- ===========================

function JusticeHQ:buildWarrantsChoices()
    local list_choices = {}

    local scored = {}
    for _, s in ipairs(self.suspects) do
        if isConvictable(s) then
            if not s.evidence then
                local evidence, score = self:buildEvidence(s)
                s.evidence = evidence
                s.score = score
            end
            table.insert(scored, s)
        end
    end

    table.sort(scored, function(a, b) return a.score > b.score end)

    local rank = 0
    for _, s in ipairs(scored) do
        rank = rank + 1

        local threat_color = COLOR_DARKGREY
        if s.threat == 'High' then threat_color = COLOR_LIGHTRED
        elseif s.threat == 'Medium' then threat_color = COLOR_YELLOW end
        
        local cat_badge = string.upper(s.category)
        local badge_color = COLOR_DARKGREY
        if s.category == 'visitor' then badge_color = COLOR_LIGHTCYAN
        elseif s.category == 'resident' then badge_color = COLOR_CYAN end

        local open_crimes = getOpenCrimes(s.unit.hist_figure_id)
        local crime_names = {}
        local added_crimes = {}
        for _, c in ipairs(open_crimes) do
            local cname = getCrimeName(c.mode)
            if not added_crimes[cname] then
                table.insert(crime_names, cname)
                added_crimes[cname] = true
            end
        end
        local crime_str = table.concat(crime_names, ", ")
        if crime_str == "" then crime_str = "Unknown" end
        if #crime_str > 26 then crime_str = string.sub(crime_str, 1, 23) .. "..." end

        local text_blocks = {
            {text = string.format("%3d ", rank), pen = COLOR_DARKGREY},
            {text = string.format("%-22s", string.sub(s.short_name, 1, 22)), pen = COLOR_WHITE},
            {text = " [", pen = COLOR_DARKGREY},
            {text = string.format("%-8s", cat_badge), pen = badge_color},
            {text = "] ", pen = COLOR_DARKGREY},
            {text = "Wanted: ", pen = COLOR_LIGHTRED},
            {text = string.format("%-26s", crime_str), pen = COLOR_YELLOW},
            {text = string.format(" [%d pts]", s.score), pen = COLOR_GREY},
        }

        table.insert(list_choices, {
            text = text_blocks,
            search_key = s.name:lower() .. ' ' .. s.prof:lower() .. ' ' .. s.category:lower(),
            data = s,
        })
    end

    if #list_choices == 0 then
        table.insert(list_choices, {
            text = {{text = '  No pending warrants.', pen = COLOR_GREY}},
            search_key = '',
            data = nil,
        })
    end

    return list_choices
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
            if crime.accused_hf and crime.accused_hf.hfid ~= -1 then
                local hf = df.historical_figure.find(crime.accused_hf.hfid)
                if hf then
                    local aunit = hf.unit_id >= 0 and df.unit.find(hf.unit_id) or nil
                    accused_name = aunit and dfhack.units.getReadableName(aunit) or dfhack.translation.translateName(hf.name)
                    if accused_name == '' then accused_name = dfhack.translation.translateName(hf.name, true) end
                    table.insert(details, "Accused: " .. accused_name)
                end
            end
            
            local victim_name = "Unknown"
            if crime.victim_hf and crime.victim_hf.hfid ~= -1 then
                local hf = df.historical_figure.find(crime.victim_hf.hfid)
                if hf then
                    local vunit = hf.unit_id >= 0 and df.unit.find(hf.unit_id) or nil
                    victim_name = vunit and dfhack.units.getReadableName(vunit) or dfhack.translation.translateName(hf.name)
                    if victim_name == '' then victim_name = dfhack.translation.translateName(hf.name, true) end
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
                {text = crime_date, pen = COLOR_BROWN},
                NEWLINE,
                {text = "         Accused: ", pen = COLOR_DARKGREY},
                {text = accused_name, pen = COLOR_YELLOW},
                {text = victim_name ~= "Unknown" and ("   Victim: ") or "", pen = COLOR_DARKGREY},
                {text = victim_name ~= "Unknown" and victim_name or "", pen = COLOR_LIGHTCYAN},
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
    local convict_map = {}
    
    for _, punishment in ipairs(df.global.plotinfo.punishments) do
        local is_active = (punishment.prison_counter > 0) or (punishment.beating > 0) or (punishment.hammer_strikes > 0)
        if is_active then
            if not convict_map[punishment.criminal] then
                convict_map[punishment.criminal] = {
                    prison = 0,
                    beating = 0,
                    hammer = 0,
                    raw = punishment
                }
            end
            convict_map[punishment.criminal].prison = convict_map[punishment.criminal].prison + punishment.prison_counter
            convict_map[punishment.criminal].beating = convict_map[punishment.criminal].beating + punishment.beating
            convict_map[punishment.criminal].hammer = convict_map[punishment.criminal].hammer + punishment.hammer_strikes
        end
    end
    
    for criminal_id, p_data in pairs(convict_map) do
        local unit = df.unit.find(criminal_id)
        if unit then
            -- Filter logic
            local show = false
            if filter == 1 then show = true end
            if filter == 2 and p_data.prison > 0 then show = true end
            if filter == 3 and (p_data.beating > 0 or p_data.hammer > 0) then show = true end
            
            if show then
                local days = math.ceil((p_data.prison * TICKS_PER_SEASON_TICK) / TICKS_PER_DAY)
                local name = dfhack.units.getReadableName(unit)
                
                local sentence_str = ""
                if p_data.prison > 0 then sentence_str = sentence_str .. days .. " days in prison. " end
                if p_data.beating > 0 then sentence_str = sentence_str .. p_data.beating .. " beatings pending. " end
                if p_data.hammer > 0 then sentence_str = sentence_str .. p_data.hammer .. " hammer strikes pending. " end
                
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
                }
                -- Colorize sentence components individually
                if p_data.prison > 0 then
                    table.insert(text_arr, {text = days .. " days in prison", pen = COLOR_LIGHTCYAN})
                    if p_data.beating > 0 or p_data.hammer > 0 then
                        table.insert(text_arr, {text = ", ", pen = COLOR_DARKGREY})
                    else
                        table.insert(text_arr, {text = " ", pen = COLOR_DARKGREY})
                    end
                end
                if p_data.beating > 0 then
                    table.insert(text_arr, {text = p_data.beating .. " beatings", pen = COLOR_YELLOW})
                    if p_data.hammer > 0 then
                        table.insert(text_arr, {text = ", ", pen = COLOR_DARKGREY})
                    else
                        table.insert(text_arr, {text = " ", pen = COLOR_DARKGREY})
                    end
                end
                if p_data.hammer > 0 then
                    table.insert(text_arr, {text = p_data.hammer .. " hammer strikes", pen = COLOR_LIGHTRED})
                    table.insert(text_arr, {text = " ", pen = COLOR_DARKGREY})
                end
                table.insert(text_arr, {text = crime_date_str, pen = COLOR_BROWN})
                local searchable = string.lower(name .. " " .. suspect_data.prof)

                table.insert(convicts_data, {
                    display_arr = text_arr,
                    searchable = searchable,
                    suspect_data = suspect_data,
                    raw_punishment = p_data.raw,
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
                pcall(function()
                    local evt_hf = event.target_hf or event.subject_hf
                    if evt_hf == hf.id then
                        implicated_count = implicated_count + #event.implicated_hfs
                    end
                end)
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
    
    -- Sort and filter villain networks
    local sorted_networks = {}
    local filter_mode = PERSISTENT_UI.network_filter or 1
    for hf_id, network in pairs(villain_networks) do
        local include = false
        if filter_mode == 3 then
            include = true
        elseif filter_mode == 1 then
            include = network.plot_count > 0
        elseif filter_mode == 2 then
            include = #network.actors >= 3
        end
        if include then
            table.insert(sorted_networks, network)
        end
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
                {text = plot.type_name:gsub("_", " "), pen = PLOT_COLORS[plot.type_name] or COLOR_YELLOW},
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
                    pcall(function() 
                        target_name = dfhack.translation.translateName(target_hf.name)
                        if target_name == "" then target_name = dfhack.translation.translateName(target_hf.name, true) end
                    end)
                    if not target_name or target_name == "" then target_name = "Unknown" end
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
                {text = string.format("   %s %-32s ", string.char(16), target_name), pen = COLOR_WHITE},
                {text = string.format("%-22s ", role_display), pen = ROLE_COLORS[actor.role_name] or COLOR_LIGHTRED},
                {text = cat_badge, pen = badge_color},
                NEWLINE,
                {text = "       Strategy: ", pen = COLOR_DARKGREY},
                {text = strategy_display, pen = STRATEGY_COLORS[actor.strategy_name] or COLOR_GREY},
            }
            -- Investigation progress markers
            local marker_added = false
            if target_s then
                if isConvictable(target_s) then
                    table.insert(text_arr, {text = "  [CONVICTABLE]", pen = COLOR_LIGHTRED})
                    marker_added = true
                end
                
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
    if (not self.init_complete or self.rebuilding_tab) and GLOBAL_SELECTED_SUSPECT_ID then return end
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

function JusticeHQ:onSelectWarrant(idx, choice)
    self:onSelectSuspect(idx, choice)
end

function JusticeHQ:onSubmitWarrant(idx, choice)
    self:onSelectSuspect(idx, choice)
    if self.selected_suspect then
        self:onOpenCaseFile(idx, choice)
    end
end

function JusticeHQ:onSelectCase(idx, choice)
    -- Don't let auto-select during init overwrite the saved suspect
    if (not self.init_complete or self.rebuilding_tab) and GLOBAL_SELECTED_SUSPECT_ID then return end
    
    -- Cases store a crime object in choice.data
    -- We try to find the accused unit and set them as selected_suspect
    if not choice or not choice.data then return end
    local crime = choice.data
    if crime.accused ~= -1 then
        -- Try to find the unit directly by unit ID first
        local unit = df.unit.find(crime.accused)
        -- Fallback: find via HF ID
        if not unit and crime.accused_hf and crime.accused_hf.hfid ~= -1 then
            local hf = df.historical_figure.find(crime.accused_hf.hfid)
            if hf and hf.unit_id >= 0 then
                unit = df.unit.find(hf.unit_id)
            end
        end
        if unit and dfhack.units.isActive(unit) then
            local race_name = 'unknown'
            pcall(function()
                local raw = df.creature_raw.find(unit.race)
                if raw then race_name = raw.name[0] end
            end)
            local gender = ''
            if unit.sex == 0 then gender = string.char(12)
            elseif unit.sex == 1 then gender = string.char(11) end
            local full_name = dfhack.units.getReadableName(unit)
            local first_name = full_name:match('^(%S+)') or full_name
            self.selected_suspect = {
                unit = unit,
                first_name = first_name,
                name = full_name,
                short_name = first_name .. ' (' .. race_name .. ')',
                prof = dfhack.units.getProfessionName(unit),
                race = race_name,
                gender = gender,
                threat = 'Medium',
                reason_lines = {'Accused of a crime.'},
                category = dfhack.units.isCitizen(unit) and 'citizen' or (dfhack.units.isVisiting(unit) and 'visitor' or 'resident'),
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

function JusticeHQ:onSubmitCase(idx, choice)
    self:onSelectCase(idx, choice)
    if self.selected_suspect then
        self:onOpenCaseFile(idx, {data = self.selected_suspect})
    else
        cihq_announce("CI-HQ: No accused found for this case. The suspect may have left the map.", COLOR_YELLOW, true)
    end
end

function JusticeHQ:onSelectConvict(idx, choice)
    if (not self.init_complete or self.rebuilding_tab) and GLOBAL_SELECTED_SUSPECT_ID then return end
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
    if (not self.init_complete or self.rebuilding_tab) and GLOBAL_SELECTED_SUSPECT_ID then return end
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
                    local plot_color = PLOT_COLORS[info.plot_type] or COLOR_YELLOW
                    guidance:setText({{text = display_name .. ': ', pen = plot_color}, {text = desc, pen = COLOR_GREY}})
                    return
                end
            elseif info.type == 'actor' then
                local role_desc = ROLE_TOOLTIPS[info.role]
                if role_desc then
                    local display_role = info.role:gsub('_', ' ')
                    local role_color = ROLE_COLORS[info.role] or COLOR_LIGHTRED
                    guidance:setText({{text = display_role .. ': ', pen = role_color}, {text = role_desc, pen = COLOR_GREY}})
                    return
                end
            end
        end
        guidance:setText({{text = default_text, pen = COLOR_DARKGREY}})
    end
end

function JusticeHQ:onSubmitNetwork(idx, choice)
    if not choice or not choice.data then
        cihq_announce("CI-HQ: Select a specific person, not a header or plot row.", COLOR_YELLOW)
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
        table.insert(lines, {text = string.char(16) .. " Foreign national - cannot be sentenced through normal justice.", pen = COLOR_YELLOW})
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
        if idata.no_armok_locked then
            table.insert(lines, NEWLINE)
            table.insert(lines, {text = string.char(196):rep(40), pen = COLOR_DARKGREY})
            table.insert(lines, NEWLINE)
            table.insert(lines, {text = "INTELLIGENCE NETWORK:", pen = COLOR_LIGHTBLUE})
            table.insert(lines, NEWLINE)
            table.insert(lines, NEWLINE)
            table.insert(lines, {text = "  [ CLASSIFIED ]", pen = COLOR_LIGHTRED})
            table.insert(lines, NEWLINE)
            table.insert(lines, {text = "  Subject has not confessed to espionage.", pen = COLOR_DARKGREY})
            table.insert(lines, NEWLINE)
            table.insert(lines, {text = "  Interrogation required to reveal network.", pen = COLOR_DARKGREY})
            table.insert(lines, NEWLINE)
        elseif idata.is_villain then
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
                    table.insert(lines, {text = plot.type_name:gsub("_", " "), pen = PLOT_COLORS[plot.type_name] or COLOR_YELLOW})
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
                    table.insert(lines, {text = " <" .. role_display .. ">", pen = ROLE_COLORS[actor.role_name] or COLOR_LIGHTRED})
                    table.insert(lines, NEWLINE)
                    table.insert(lines, {text = "   Strategy: ", pen = COLOR_DARKGREY})
                    table.insert(lines, {text = strategy_display, pen = STRATEGY_COLORS[actor.strategy_name] or COLOR_GREY})
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
            -- Fixed-width point prefix for alignment
            local pts_str
            if ev.pts > 0 then
                pts_str = string.format("+%d", ev.pts)
            elseif ev.pts < 0 then
                pts_str = string.format("%d", ev.pts)
            else
                pts_str = "---"
            end
            local prefix = " " .. string.char(16) .. " [" .. string.format("%-4s", pts_str) .. "] "
            -- Color the point bracket by severity
            local pts_color = COLOR_DARKGREY
            if ev.pts >= 100 then pts_color = COLOR_LIGHTRED
            elseif ev.pts >= 50 then pts_color = COLOR_YELLOW
            elseif ev.pts >= 15 then pts_color = COLOR_CYAN
            elseif ev.pts < 0 then pts_color = COLOR_GREEN
            end
            table.insert(lines, {text = prefix, pen = pts_color})
            table.insert(lines, {text = ev.text, pen = ev.color})
            table.insert(lines, NEWLINE)
            if ev.detail then
                -- Word-wrap detail text at ~68 chars to fit window
                local indent = "       "
                local max_w = 68
                local words = {}
                for w in ev.detail:gmatch("%S+") do table.insert(words, w) end
                local cur_line = indent
                for _, w in ipairs(words) do
                    if #cur_line + 1 + #w > max_w and cur_line ~= indent then
                        table.insert(lines, {text = cur_line, pen = COLOR_GREY})
                        table.insert(lines, NEWLINE)
                        cur_line = indent .. w
                    else
                        if cur_line == indent then
                            cur_line = cur_line .. w
                        else
                            cur_line = cur_line .. " " .. w
                        end
                    end
                end
                if cur_line ~= indent then
                    table.insert(lines, {text = cur_line, pen = COLOR_GREY})
                    table.insert(lines, NEWLINE)
                end
            end
            
            if ev.op_notes and #ev.op_notes > 0 then
                for _, note in ipairs(ev.op_notes) do
                    local indent = "         " -- 9 spaces for bullet
                    local max_w = 68
                    local words = {}
                    for w in note:gmatch("%S+") do table.insert(words, w) end
                    local cur_line = "       * " -- starting bullet
                    for _, w in ipairs(words) do
                        if #cur_line + 1 + #w > max_w and cur_line ~= "       * " and cur_line ~= indent then
                            table.insert(lines, {text = cur_line, pen = COLOR_LIGHTGREEN})
                            table.insert(lines, NEWLINE)
                            cur_line = indent .. w
                        else
                            if cur_line == "       * " or cur_line == indent then
                                cur_line = cur_line .. w
                            else
                                cur_line = cur_line .. " " .. w
                            end
                        end
                    end
                    if cur_line ~= "       * " and cur_line ~= indent then
                        table.insert(lines, {text = cur_line, pen = COLOR_LIGHTGREEN})
                        table.insert(lines, NEWLINE)
                    end
                end
            end
            -- Blank line between evidence entries
            table.insert(lines, NEWLINE)
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
            table.insert(lines, {text = "  Status: RESOLVED - Subject confessed.", pen = COLOR_LIGHTGREEN})
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
                local evt_hf = nil
                pcall(function() evt_hf = event.target_hf or event.subject_hf end)
                if evt_hf == hf.id then
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
                    local int_hf = df.historical_figure.find(report.officer_hf)
                    if int_hf then interrogator_name = dfhack.translation.translateName(int_hf.name) end
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
    self.subviews.pages:setSelected(6)
end

function JusticeHQ:gatherSuspects()
    initCrimeCache() -- Rebuild cache to avoid O(N*M) lag
    local suspects = {}
    for _, unit in ipairs(df.global.world.units.active) do
        if dfhack.units.isDead(unit) or not dfhack.units.isActive(unit) then goto skip_unit end
        
        -- Scan citizens, visitors, AND residents - spies can be any of these
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
                                "Dormant threat - may reactivate."
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
                if self.subviews.pages:getSelected() == 6 then
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
                if self.subviews.pages:getSelected() == 6 then
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
        [3] = {name = "Warrants", view = 'warrants_list'},
        [4] = {name = "Prisoners", view = 'convicts_list'},
        [5] = {name = "Network", view = 'network_list'},
    }
    
    if list_map[page] then
        tab_name = list_map[page].name
        local list = self.subviews[list_map[page].view]
        if list then
            for _, choice in ipairs(list:getVisibleChoices()) do
                if choice.text then
                    local line = self:serializeChoiceToLine(choice.text)
                    if line ~= '' then
                        table.insert(lines, line)
                    end
                end
            end
        end
    elseif page == 6 then
        tab_name = "Case File"
        local case_file = self.subviews.case_file
        if case_file and case_file.text then
            lines = self:serializeLabelTokens(case_file.text)
        end
    elseif page == 7 then
        tab_name = "Intel Report"
        local list = self.subviews.intel_list and self.subviews.intel_list.list
        if list then
            local idx, choice = list:getSelected()
            if choice and choice.data and choice.data.report then
                local r = choice.data.report
                local hf = df.historical_figure.find(r.subject_hf)
                local name = hf and dfhack.translation.translateName(hf.name) or "Unknown"
                local date_str = dfDateString(r.year, r.tick)
                local title = "Interrogation Report: " .. name .. ", " .. date_str
                table.insert(lines, title)
                table.insert(lines, "Interrogator: " .. (r.officer_name or 'Unknown'))
                table.insert(lines, "")
                local text = ''
                if r.details then
                    for di = 0, #r.details - 1 do
                        local str_ptr = r.details[di]
                        if str_ptr then text = text .. (di > 0 and '\n' or '') .. tostring(str_ptr.value) end
                    end
                end
                for s in text:gmatch("[^\r\n]+") do
                    table.insert(lines, s)
                end
            else
                table.insert(lines, "No report selected.")
            end
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
        cihq_announce("CI-HQ: " .. err, COLOR_GREY, true)
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

-- Copy to clipboard (Ctrl+C key) - uses DFHack's native clipboard API
-- NOTE: May freeze briefly on very large exports due to CP437 conversion
function JusticeHQ:copyTabToClipboard()
    local output, tab_name, err, raw = self:serializeCurrentTab()
    if not output then
        cihq_announce("CI-HQ: " .. err, COLOR_GREY, true)
        return
    end
    
    -- All text is now pure ASCII (no UTF-8 em dashes), safe for CP437 clipboard
    dfhack.internal.setClipboardTextCp437Multiline(raw)
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
        cihq_announce("CI-HQ: Select a suspect first.", COLOR_YELLOW, true)
        return
    end
    
    local unit = self.selected_suspect.unit
    if not unit then return end
    
    if unit.flags1.chained then
        cihq_announce("CI-HQ: " .. dfhack.units.getReadableName(unit) .. " is already detained.", COLOR_YELLOW, true)
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
                cihq_announce("CI-HQ: " .. name .. " has been forcibly detained in the dungeon.", COLOR_LIGHTMAGENTA, true)
                self_ref:refreshCurrentDossier()
            else
                cihq_announce("CI-HQ: Detainment failed. " .. tostring(err), COLOR_RED, true)
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
                cihq_announce("CI-HQ: " .. name .. " has been forcibly released.", COLOR_LIGHTGREEN, true)
                self_ref:refreshCurrentDossier()
            else
                cihq_announce("CI-HQ: Release failed. " .. tostring(err), COLOR_RED, true)
            end
        end
    )
end

function JusticeHQ:onConvict()
    if not self.selected_suspect then return end
    if not isConvictable(self.selected_suspect) then return end
    local suspect = self.selected_suspect
    local unit = suspect.unit
    
    local open_crimes = getOpenCrimes(unit.hist_figure_id)
    if #open_crimes == 0 then return end
    
    local self_ref = self
    local choices = {}
    
    table.insert(choices, {
        text = "Convict of ALL Open Crimes (" .. #open_crimes .. ")",
        search_key = "all",
        data = {action = 'all'}
    })
    
    for _, crime in ipairs(open_crimes) do
        local cname = getCrimeName(crime.mode)
        local pstr = ""
        pcall(function()
            if crime.punishment.hammerstrikes > 0 then
                pstr = crime.punishment.hammerstrikes .. " strikes"
            end
            if crime.punishment.prison_time > 0 then
                if pstr ~= "" then pstr = pstr .. ", " end
                pstr = pstr .. crime.punishment.prison_time .. "mo prison"
            end
        end)
        if pstr == "" then
            pstr = "no extra penalty"
        end
        
        table.insert(choices, {
            text = "[" .. cname .. "] (Penalty: " .. pstr .. ")",
            search_key = string.lower(cname),
            data = {action = 'single', crime = crime}
        })
    end
    
    dialogs.showListPrompt(
        "Convict Suspect",
        "Select the crime(s) to officially convict " .. suspect.first_name .. " of:",
        COLOR_LIGHTRED,
        choices,
        function(idx, choice)
            -- Gather the crimes being convicted
            local selected_crimes = {}
            if choice.data.action == 'all' then
                for _, crime in ipairs(open_crimes) do
                    table.insert(selected_crimes, crime)
                end
            else
                table.insert(selected_crimes, choice.data.crime)
            end

            -- Tally up total sentences
            local total_beatings = 0
            local total_strikes = 0
            local total_prison_months = 0
            local crime_names = {}
            for _, crime in ipairs(selected_crimes) do
                table.insert(crime_names, getCrimeName(crime.mode))
                pcall(function()
                    if crime.punishment.flags.beating then total_beatings = total_beatings + 1 end
                    total_strikes = total_strikes + crime.punishment.hammerstrikes
                    total_prison_months = total_prison_months + crime.punishment.prison_time
                end)
            end

            -- Build sentence summary lines
            local sentence_lines = {}
            if total_beatings > 0 then
                table.insert(sentence_lines, "  - " .. total_beatings .. " beating(s) by the Captain of the Guard")
            end
            if total_strikes > 0 then
                table.insert(sentence_lines, "  - " .. total_strikes .. " hammer strike(s)")
            end
            if total_prison_months > 0 then
                local days = total_prison_months * 28
                table.insert(sentence_lines, "  - " .. total_prison_months .. " month(s) imprisonment (" .. days .. " days)")
            end
            if #sentence_lines == 0 then
                table.insert(sentence_lines, "  - No additional penalty")
            end

            -- Check diplomatic protection for non-citizens
            local has_diplomatic_protection = false
            local civ_name = "an unknown civilization"
            local is_noncitizen = (suspect.category ~= 'citizen')

            if is_noncitizen then
                -- Scan the HF's entity links for active membership in ANY
                -- foreign civilization. Residents have their unit.civ_id
                -- updated to the player's civ, so we can't rely on that.
                local player_civ = df.global.plotinfo.civ_id
                local hf_id = unit.hist_figure_id
                if hf_id >= 0 then
                    local hf = df.historical_figure.find(hf_id)
                    if hf then
                        for _, link in ipairs(hf.entity_links) do
                            if df.histfig_entity_link_memberst:is_instance(link)
                               and link.entity_id ~= player_civ then
                                -- Verify this entity is a civilization (not a site gov/guild/religion)
                                local ent = df.historical_entity.find(link.entity_id)
                                if ent and ent.type == df.historical_entity_type.Civilization then
                                    has_diplomatic_protection = true
                                    pcall(function() civ_name = dfhack.translation.translateName(ent.name, true) end)
                                    break
                                end
                            end
                        end
                    end
                end
            end

            -- Build the confirmation text
            local cat_str = string.upper(suspect.category)
            local charges_str = ""
            for i, cname in ipairs(crime_names) do
                charges_str = charges_str .. "  " .. i .. ". " .. cname .. "\n"
            end
            local sentence_str = table.concat(sentence_lines, "\n") .. "\n"

            local text = ""
            local dialog_title = "CI-HQ: Convict Suspect"
            local dialog_color = COLOR_LIGHTCYAN

            if has_diplomatic_protection then
                -- CASE 1: Foreign visitor with active citizenship
                dialog_title = "CI-HQ: Convict Foreign National"
                dialog_color = COLOR_LIGHTRED
                text = {
                    {text="WARNING: ", pen=COLOR_RED},
                    {text=suspect.name, pen=COLOR_CYAN},
                    " is a ",
                    {text=cat_str, pen=COLOR_GREEN},
                    "\nand active citizen of ",
                    {text=civ_name, pen=COLOR_YELLOW},
                    ".\n\n",
                    "As a foreign national under diplomatic protection,\n",
                    "your justice system has ",
                    {text="no authority to permanently", pen=COLOR_RED},
                    "\n",
                    {text="incarcerate them.", pen=COLOR_RED},
                    "\n\n",
                    "Any corporal punishment (beatings/hammer strikes)\n",
                    "will be carried out by the Captain of the Guard.\n",
                    "However, the game engine will silently ",
                    {text="void their", pen=COLOR_YELLOW},
                    "\n",
                    {text="prison sentence", pen=COLOR_YELLOW},
                    " because they cannot be assigned\n",
                    "to a jail chain.\n\n",
                    "Charges (" .. #selected_crimes .. "):\n" .. charges_str,
                    "\nSentence if convicted:\n" .. sentence_str,
                    "\nMeaning, any prison sentences for " .. suspect.first_name .. " will\n",
                    "be ",
                    {text="void", pen=COLOR_YELLOW},
                    ". They will only receive the beatings/\n",
                    "hammer strikes, unless you use ",
                    {text="[k] Execute", pen=COLOR_RED},
                    " instead.\n\n",
                    "Do you still want to officially convict them?"
                }

            elseif is_noncitizen then
                -- CASE 2: Outcast / stateless visitor
                dialog_title = "CI-HQ: Convict Stateless Visitor"
                dialog_color = COLOR_LIGHTRED
                text = {
                    {text=suspect.name, pen=COLOR_CYAN},
                    " is a ",
                    {text=cat_str, pen=COLOR_GREEN},
                    " (",
                    {text="Outcast / Stateless", pen=COLOR_GREY},
                    ").\n\n",
                    "This visitor has no diplomatic protection. Your\n",
                    "justice system has full authority over them.\n\n",
                    "All corporal punishment (beatings/hammer strikes)\n",
                    "will be carried out by the Captain of the Guard.\n",
                    "However, the game engine will silently ",
                    {text="void their", pen=COLOR_YELLOW},
                    "\n",
                    {text="prison sentence", pen=COLOR_YELLOW},
                    " because visitors cannot be assigned\n",
                    "to a dwarven jail chain.\n\n",
                    "Charges (" .. #selected_crimes .. "):\n" .. charges_str,
                    "\nSentence if convicted:\n" .. sentence_str,
                    "\nMeaning, any prison sentences for " .. suspect.first_name .. " will\n",
                    "be ",
                    {text="void", pen=COLOR_YELLOW},
                    ". They will only receive the beatings/\n",
                    "hammer strikes, unless you use ",
                    {text="[k] Execute", pen=COLOR_RED},
                    " instead.\n\n",
                    "Authorize conviction?"
                }

            else
                -- CASE 3: Citizen = standard conviction
                dialog_title = "CI-HQ: Convict Citizen"
                dialog_color = COLOR_LIGHTRED
                text = {
                    {text=suspect.name, pen=COLOR_CYAN},
                    "\n\n",
                    "Charges (" .. #selected_crimes .. "):\n" .. charges_str,
                    "\nSentence:\n" .. sentence_str,
                    "\nAll penalties will be enforced through the normal\n",
                    "dwarven justice system. The Captain of the Guard\n",
                    "will carry out any beatings, and the suspect will\n",
                    "be jailed for the full prison duration.\n\n",
                    "Authorize conviction?"
                }
            end

            local function execute_conviction()
                local convicted_count = 0
                
                local function applyPunishment(c, u)
                    local p = df.punishment:new()
                    p.criminal = u.id
                    p.officer = -1
                    p.beating = c.punishment.flags.beating and 50 or 0
                    p.hammer_strikes = c.punishment.hammerstrikes
                    p.prison_counter = c.punishment.prison_time * 3360
                    p.time_to_assign = 0
                    p.chain = -1
                    if c.victim ~= -1 then
                        p.victims:insert('#', c.victim)
                    end
                    df.global.plotinfo.punishments:insert('#', p)
                end

                if choice.data.action == 'all' then
                    for _, crime in ipairs(open_crimes) do
                        crime.accused = unit.id
                        crime.accused_hf.hfid = unit.hist_figure_id
                        crime.flags.needs_trial = false
                        crime.flags.sentenced = true
                        applyPunishment(crime, unit)
                        convicted_count = convicted_count + 1
                    end
                else
                    local crime = choice.data.crime
                    crime.accused = unit.id
                    crime.accused_hf.hfid = unit.hist_figure_id
                    crime.flags.needs_trial = false
                    crime.flags.sentenced = true
                    applyPunishment(crime, unit)
                    convicted_count = 1
                end
                
                cihq_announce("CI-HQ: " .. suspect.first_name .. " was convicted of " .. convicted_count .. " crime(s)! Justice will be served.", COLOR_LIGHTGREEN, true)
                
                initCrimeCache()
                self_ref:refreshCurrentDossier()
                if self_ref.subviews.suspect_list then
                    self_ref.subviews.suspect_list:setChoices(self_ref:buildChoices())
                end
                if self_ref.subviews.network_list then
                    self_ref.subviews.network_list:setChoices(self_ref:buildNetworkChoices())
                end
            end

            dialogs.showYesNoPrompt(
                dialog_title,
                text,
                dialog_color,
                execute_conviction
            )
        end
    )
end

function JusticeHQ:onPardon()
    if not self.selected_suspect then
        cihq_announce("CI-HQ: Select a suspect first.", COLOR_YELLOW, true)
        return
    end
    
    local unit = self.selected_suspect.unit
    local name = dfhack.units.getReadableName(unit)
    local unit_id = unit.id
    local self_ref = self
    
    local dialog
    dialog = dialogs.DialogScreen{
        title = 'CI-HQ: Pardon Suspect',
        message_label_attrs = {
            frame = {t=0, l=0, b=4},
            text = 'Are you sure you want to fully pardon ' .. name .. '?\n\n' ..
                   'This will instantly clear all pending and active sentences,\n' ..
                   'including beatings, hammer strikes, and imprisonment.\n' ..
                   'If the suspect is currently chained, they will be released.\n\n' ..
                   'This action cannot be undone.',
            text_pen = COLOR_LIGHTCYAN,
        },
        accept_hotkey_label_attrs = {
            label = 'Yes, pardon',
            frame = {b=0, l=0},
        },
        on_accept = function()
            local target = df.unit.find(unit_id)
            if not target then return end
            
            local pardoned = false
            for _, punishment in ipairs(df.global.plotinfo.punishments) do
                if punishment.criminal == target.id then
                    punishment.prison_counter = 0
                    punishment.beating = 0
                    punishment.hammer_strikes = 0
                    pardoned = true
                end
            end
            
            -- Also release from chains if detained
            if target.flags1.chained then
                releaseUnit(target)
            end
            
            if pardoned then
                cihq_announce("CI-HQ: Suspect " .. dfhack.units.getReadableName(target) .. " has been fully pardoned.", COLOR_LIGHTCYAN, true)
                self_ref:refreshCurrentDossier()
            else
                cihq_announce("CI-HQ: Suspect is not currently serving a sentence.", COLOR_GREY, true)
            end
        end,
        on_cancel = function() end,
        subviews = {
            widgets.HotkeyLabel{
                frame = {b=0, r=0},
                label = 'No, abort',
                key = 'LEAVESCREEN',
                auto_width = true,
                on_activate = function() dialog:dismiss() end,
            }
        }
    }
    dialog:show()
end

function JusticeHQ:onExecute()
    if not self.selected_suspect then
        cihq_announce("CI-HQ: Select a suspect first.", COLOR_YELLOW, true)
        return
    end
    local unit = self.selected_suspect.unit
    
    if not dfhack.units.isActive(unit) then
        cihq_announce("CI-HQ: Cannot execute - target has left the map!", COLOR_RED, true)
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
        
        local p = df.punishment:new()
        p.criminal = unit.id
        p.officer = -1
        p.beating = beatings
        p.hammer_strikes = hammer_strikes
        p.prison_counter = 0
        p.time_to_assign = 10
        p.chain = -1
        df.global.plotinfo.punishments:insert('#', p)
        
        cihq_announce("CI-HQ: EXECUTION ORDERED for " .. dfhack.units.getReadableName(unit) .. ". " .. executor_name .. " dispatched.", COLOR_RED, true)
    else
        -- Non-citizens: the vanilla punishment queue ignores foreign visitors entirely.
        -- Show a confirmation dialog explaining why and requesting player approval.
        local name = dfhack.units.getReadableName(unit)
        local unit_id = unit.id
        local self_ref = self
        local dialog
        dialog = dialogs.DialogScreen{
            title = 'CI-HQ: Extrajudicial Execution',
            message_label_attrs = {
                frame = {t=0, l=0, b=4},
                text = 'Target: ' .. name .. '\n\n' ..
                       'This suspect is a non-citizen visitor. The dwarven justice\n' ..
                       'system cannot sentence foreign nationals - any punishment\n' ..
                       'order will be ignored by the Hammerer.\n\n' ..
                       'CI-HQ can bypass the justice system and execute this\n' ..
                       'suspect directly. This action cannot be undone.\n\n' ..
                       'Authorize extrajudicial execution?',
                text_pen = COLOR_LIGHTRED,
            },
            accept_hotkey_label_attrs = {
                label = 'Yes, execute',
                frame = {b=0, l=0},
            },
            on_accept = function()
                local target = df.unit.find(unit_id)
                if not target or not dfhack.units.isActive(target) then
                    cihq_announce("CI-HQ: Target has left the map. Execution aborted.", COLOR_RED, true)
                    return
                end
                local exterminate = reqscript('exterminate')
                exterminate.killUnit(target, exterminate.killMethod.INSTANT)
                cihq_announce("CI-HQ: " .. name .. " has been executed by order of the fortress!", COLOR_LIGHTRED, true)
                CRIME_CACHE = nil
                self_ref:refreshCurrentDossier()
            end,
            on_cancel = function() end,
            subviews = {
                widgets.HotkeyLabel{
                    frame = {b=0, r=0},
                    label = 'No, abort',
                    key = 'LEAVESCREEN',
                    auto_width = true,
                    on_activate = function() dialog:dismiss() end,
                }
            }
        }
        dialog:show()
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
        cihq_announce("CI-HQ: No suspect selected.", COLOR_YELLOW, true)
        return
    end
    
    local uid = suspect.unit.id
    
    if dfhack.units.isDead(suspect.unit) or not dfhack.units.isActive(suspect.unit) then
        -- Allow cancelling even if they left the map or died
        if interrogation_watchlist[uid] then
            local watch = interrogation_watchlist[uid]
            if watch.status == 'active' or watch.status == 'dispatched' then
                watch.status = not dfhack.units.isDead(suspect.unit) and 'escaped' or 'dead'
                cihq_announce("CI-HQ: Interrogation aborted. Suspect is no longer available.", COLOR_RED, true)
                persist_state()
                self:refreshCurrentDossier()
            end
        end
        cihq_announce("CI-HQ: Cannot interrogate " .. suspect.first_name .. " - they are dead or gone!", COLOR_RED, true)
        return
    end
    
    -- If already on watchlist and active/dispatched, treat as CANCEL (bypass guard check)
    if interrogation_watchlist[uid] then
        local watch = interrogation_watchlist[uid]
        if watch.status == 'active' or watch.status == 'dispatched' then
            local dialog
            dialog = dialogs.DialogScreen{
                title = 'Cancel Interrogation?',
                message_label_attrs = {
                    frame = {t=0, l=0, b=4},
                    text = 'Are you sure you want to cancel the interrogation loop on ' .. suspect.first_name .. '?\n\n' ..
                           'Reason: Manual cancellation requested.\n' ..
                           'Current Status: ' .. watch.status:upper() .. '\n' ..
                           'Attempts so far: ' .. (watch.retries or 0) .. '/' .. watch.max_retries .. '\n\n' ..
                           'The Captain of the Guard will stop re-dispatching to this suspect.',
                    text_pen = COLOR_YELLOW,
                },
                accept_hotkey_label_attrs = {
                    label = 'Yes, cancel',
                    frame = {b=0, l=0},
                },
                on_accept = function()
                    watch.status = 'cancelled'
                    cihq_announce("CI-HQ: Interrogation of " .. suspect.first_name .. " cancelled.", COLOR_YELLOW, true)
                    persist_state()
                    self:refreshCurrentDossier()
                end,
                on_cancel = function() end,
                subviews = {
                    widgets.HotkeyLabel{
                        frame = {b=0, r=0},
                        label = 'No, abort',
                        key = 'LEAVESCREEN',
                        auto_width = true,
                        on_activate = function() dialog:dismiss() end,
                    }
                }
            }
            dialog:show()
            return
        end
    end
    
    -- Early guard check with actionable guidance
    local guard = findCaptainOfGuard()
    if not guard then
        cihq_announce(
            "CI-HQ: No Captain of the Guard or Sheriff is assigned! Open the Nobles screen (n) and appoint one.", COLOR_LIGHTRED, true)
        return
    end
    
    -- Prevent interrogating the Captain themselves
    if guard.id == uid then
        cihq_announce("CI-HQ: The Captain of the Guard cannot interrogate themselves!", COLOR_LIGHTRED, true)
        return
    end
    
    -- Start or Resume interrogation
    if interrogation_watchlist[uid] then
        local watch = interrogation_watchlist[uid]
        -- Resume from terminal states
        watch.retries = 0
        watch.consecutive_duds = 0
        watch.status = 'active'
        cihq_announce("Resuming interrogation of " .. suspect.first_name .. "!", COLOR_LIGHTGREEN, true)
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
        cihq_announce("CI-HQ: Captain dispatched to interrogate " .. suspect.first_name .. "!", COLOR_LIGHTGREEN, true)
    else
        cihq_announce("CI-HQ: Could not auto-dispatch (" .. tostring(err) .. ")", COLOR_YELLOW)
        cihq_announce("CI-HQ: Use Justice tab to manually order interrogation.", COLOR_CYAN, true)
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



function getOpenCrimes(hfid)
    local open_crimes = {}
    if not CRIME_CACHE_HFID then return open_crimes end
    local hf_crimes = CRIME_CACHE_HFID[hfid]
    if not hf_crimes then return open_crimes end
    
    for _, crime in ipairs(hf_crimes) do
        if crime.flags.needs_trial and crime.flags.discovered and crime.criminal_hf and crime.criminal_hf.hfid == hfid then
            table.insert(open_crimes, crime)
        end
    end
    return open_crimes
end

function isConvictable(suspect)
    if not suspect or not suspect.unit then return false end
    local open_crimes = getOpenCrimes(suspect.unit.hist_figure_id)
    return #open_crimes > 0
end

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
            -- Already interrogating someone - don't interrupt
            return false
        end
        
        -- Cancel interruptable civilian jobs to prioritize interrogation
        if INTERRUPTABLE_JOBS[guard.job.current_job.job_type] then
            local ok = pcall(function()
                dfhack.job.removeJob(guard.job.current_job)
            end)
            if not ok then return false end
        else
            -- Non-interruptable job (eating, sleeping, etc.) - wait
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

local function countIntelReports(hfid)
    local count = 0
    for _, rep in ipairs(df.global.world.status.interrogation_reports) do
        if rep.subject_hf == hfid then
            count = count + 1
        end
    end
    return count
end

function interrogationMonitorTick()
    local ok, err = pcall(function()
        local any_active = false
        
        for uid, watch in pairs(interrogation_watchlist) do
            if watch.status == 'active' or watch.status == 'dispatched' then
                local unit = df.unit.find(uid)
                if not unit or dfhack.units.isDead(unit) or not dfhack.units.isActive(unit) then
                    watch.status = (unit and not dfhack.units.isDead(unit)) and 'escaped' or 'dead'
                    local reason = watch.status == 'escaped' and "has left the map!" or "has died!"
                    cihq_announce("CI-HQ: " .. watch.name .. " " .. reason .. " Interrogation aborted.", COLOR_RED, true)
                    persist_state()
                else
                    -- Check if suspect confessed (alive)
                    if not isSuspectStillThreat(uid) then
                        watch.status = 'confessed'
                        cihq_announce(
                            "CI-HQ: " .. watch.name .. " has confessed! Intelligence extracted.", COLOR_LIGHTGREEN, true)
                        CRIME_CACHE = nil
                        INTERROGATION_HISTORY_CACHE = nil
                        persist_state()
                    else
                        any_active = true
                        
                        -- Check if Captain is currently interrogating
                        local guard = findCaptainOfGuard()
                        local guard_is_interrogating = false
                        local guard_is_busy_justice = false
                        if guard and guard.job.current_job then
                            local jt = guard.job.current_job.job_type
                            if jt == df.job_type.InterrogateSubject then
                                guard_is_interrogating = true
                                guard_is_busy_justice = true
                            elseif jt == df.job_type.BeatCriminal or jt == df.job_type.ExecuteCriminal then
                                guard_is_busy_justice = true
                            end
                        end
                        
                        if watch.status == 'active' then
                            if not guard_is_busy_justice then
                                -- Snapshot the current report count before dispatching
                                watch.last_report_count = countIntelReports(unit.hist_figure_id)
                                
                                if dispatchGuardToSuspect(uid) then
                                    watch.status = 'dispatched'
                                    watch.dispatched_tick = df.global.cur_year_tick
                                    cihq_announce(
                                        "CI-HQ: Captain dispatched! Interrogating " .. watch.name .. ".", COLOR_LIGHTGREEN, true)
                                end
                            end
                        elseif watch.status == 'dispatched' then
                            -- Check if the job finished
                            local elapsed = df.global.cur_year_tick - (watch.dispatched_tick or 0)
                            -- Handle year rollover: if dispatched_tick > cur_year_tick, year wrapped
                            if elapsed < 0 then elapsed = 999 end
                            
                            -- Wait for guard to finish or grace period to expire
                            if not guard_is_busy_justice and elapsed >= 100 then
                                -- Guard is idle and enough time passed for the job to have completed.
                                -- Check if new interrogation reports appeared.
                                local new_count = countIntelReports(unit.hist_figure_id)
                                local reports_found = false
                                local is_dud = true
                                
                                if new_count > (watch.last_report_count or 0) then
                                    reports_found = true
                                    -- Find the newest report for this target
                                    local latest_report = nil
                                    local latest_outcome = nil
                                    for i = #df.global.world.status.interrogation_reports - 1, 0, -1 do
                                        local r = df.global.world.status.interrogation_reports[i]
                                        if r.subject_hf == unit.hist_figure_id then
                                            latest_report = r
                                            break
                                        end
                                    end
                                    
                                    if latest_report then
                                        latest_outcome = computeIntelOutcome(latest_report)
                                        if latest_outcome == 'CONFESSED' or latest_outcome == 'NEW INTEL' then
                                            is_dud = false
                                        end
                                    end
                                    watch.last_report_count = new_count
                                end

                                watch.retries = (watch.retries or 0) + 1
                                
                                if reports_found and not is_dud then
                                    -- New intel extracted! Reset dud counter, continue.
                                    watch.consecutive_duds = 0
                                    if watch.retries >= watch.max_retries then
                                        watch.status = 'concluded'
                                        cihq_announce(
                                            "CI-HQ: " .. watch.name .. " reached max attempts (" .. watch.retries .. "). Concluded.", COLOR_YELLOW, true)
                                        persist_state()
                                    else
                                        watch.status = 'active'
                                        watch.dispatched_tick = nil
                                        cihq_announce(
                                            "CI-HQ: " .. watch.name .. " spilled some intel! Re-dispatching (" .. watch.retries .. "/" .. watch.max_retries .. ")...", COLOR_LIGHTGREEN, true)
                                        persist_state()
                                    end
                                else
                                    -- No new intel this round (suspect refused or had nothing new).
                                    -- We allow up to MAX_CONSECUTIVE_DUDS retries because refusals are stat-based rolls.
                                    watch.consecutive_duds = (watch.consecutive_duds or 0) + 1
                                    
                                    local dud_msg = "revealed no new intel"
                                    if latest_outcome == 'REFUSED' then
                                        dud_msg = "refused to cooperate"
                                    end
                                    
                                    if watch.consecutive_duds >= MAX_CONSECUTIVE_DUDS then
                                        watch.status = 'concluded'
                                        cihq_announce(
                                            "CI-HQ: " .. watch.name .. " " .. dud_msg .. " after " .. watch.consecutive_duds .. " consecutive attempts. Concluded.", COLOR_YELLOW, true)
                                        persist_state()
                                    elseif watch.retries >= watch.max_retries then
                                        watch.status = 'concluded'
                                        cihq_announce(
                                            "CI-HQ: " .. watch.name .. " reached max attempts (" .. watch.retries .. "). Concluded.", COLOR_YELLOW, true)
                                        persist_state()
                                    else
                                        watch.status = 'active'
                                        watch.dispatched_tick = nil
                                        cihq_announce(
                                            "CI-HQ: " .. watch.name .. " " .. dud_msg .. " (" .. watch.consecutive_duds .. "/" .. MAX_CONSECUTIVE_DUDS .. "). Retrying (" .. watch.retries .. "/" .. watch.max_retries .. ")...", COLOR_CYAN, true)
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
        cihq_announce("CI-HQ: Monitor error: " .. tostring(err), COLOR_LIGHTRED, true)
        print("CI-HQ MONITOR ERROR: " .. tostring(err))
        -- Reschedule even on error so monitoring doesn't die silently
        monitor_last_scheduled_tick = df.global.cur_year_tick
        dfhack.timeout(MONITOR_INTERVAL, 'ticks', interrogationMonitorTick)
    end
end


function startInterrogationMonitor()
    -- Always force-start the monitor. The old liveness check was unreliable
    -- because dfhack.timeout callbacks die on script reload and monitor_running
    -- stays stale. Just always restart - duplicate starts are harmless since
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

--
-- CIHQNotifyOverlay: vivid colored notification toasts
--
CIHQNotifyOverlay = defclass(CIHQNotifyOverlay, overlay.OverlayWidget)
CIHQNotifyOverlay.ATTRS{
    desc='Shows CI-HQ action notifications with vivid colors on the game screen.',
    default_pos={x=1, y=1},
    default_enabled=false,
    fullscreen=true,
    viewscreens='dwarfmode/Default',
}

function CIHQNotifyOverlay:preUpdateLayout(parent_rect)
    self.frame.w = parent_rect.width
    self.frame.h = parent_rect.height
end

local CIHQ_NOTIFICATION_LIFETIME_MS = 10000  -- 10 seconds real-time

function CIHQNotifyOverlay:render(dc)
    -- Expire old notifications
    local now = dfhack.getTickCount()
    local i = #CIHQ_NOTIFICATIONS
    while i >= 1 do
        if (now - CIHQ_NOTIFICATIONS[i].time) > CIHQ_NOTIFICATION_LIFETIME_MS then
            table.remove(CIHQ_NOTIFICATIONS, i)
        end
        i = i - 1
    end

    if #CIHQ_NOTIFICATIONS == 0 then return end

    -- Render position: top-left, just below the top menu bar
    local sw, sh = dfhack.screen.getWindowSize()
    local base_y = 6  -- Start drawing at line 6 (below top toolbars)

    for idx, notif in ipairs(CIHQ_NOTIFICATIONS) do
        local y = base_y + idx - 1
        if y >= 0 and y < sh then
            -- Age-based fade: full brightness first, then dim
            local age = now - notif.time
            local color = notif.color
            if age > (CIHQ_NOTIFICATION_LIFETIME_MS * 0.75) then
                color = COLOR_LIGHTRED
            end

            -- Draw a solid background strip for readability (black background)
            local text = notif.text
            local strip_len = math.min(#text + 2, sw - 2)
            for x = 0, strip_len - 1 do
                dc:seek(x, y):char(' ', COLOR_BLACK)
            end

            -- Draw the colored text
            dc:seek(1, y):pen(color):string(text)
        end
    end
end

NoArmokToggleOverlay = defclass(NoArmokToggleOverlay, overlay.OverlayWidget)
NoArmokToggleOverlay.ATTRS = {
    desc = 'Enables Fog-of-War (No Armok) mode for CI-HQ. Hides intrigue networks until a confession is extracted via interrogation.',
    default_enabled = false,
    viewscreens = 'NONE', -- Doesn't render, just a toggle state for gui/control-panel
}

function NoArmokToggleOverlay:init() end
function NoArmokToggleOverlay:render(dc) end

RealisticArrestsToggleOverlay = defclass(RealisticArrestsToggleOverlay, overlay.OverlayWidget)
RealisticArrestsToggleOverlay.ATTRS = {
    desc = 'Requires thieves to be physically seen by a military guard (Line-of-Sight) before the Emergency Detainment popup appears.',
    default_enabled = false,
    viewscreens = 'NONE',
}

function RealisticArrestsToggleOverlay:init() end
function RealisticArrestsToggleOverlay:render(dc) end

VillainEntryAlertsToggleOverlay = defclass(VillainEntryAlertsToggleOverlay, overlay.OverlayWidget)
VillainEntryAlertsToggleOverlay.ATTRS = {
    desc = 'Enables the CI-HQ popup alert whenever a known villain or criminal enters the fortress map.',
    default_enabled = true,
    viewscreens = 'NONE',
}

function VillainEntryAlertsToggleOverlay:init() end
function VillainEntryAlertsToggleOverlay:render(dc) end

OVERLAY_WIDGETS = {
    hq_button = JusticeHQOverlay,
    notifications = CIHQNotifyOverlay,
    no_armok = NoArmokToggleOverlay,
    realistic_arrests = RealisticArrestsToggleOverlay,
    villain_entry_alerts = VillainEntryAlertsToggleOverlay,
}

local function isRealisticArrestsEnabled()
    local ok, plugins_overlay = pcall(require, 'plugins.overlay')
    if ok and plugins_overlay and plugins_overlay.isOverlayEnabled then
        return plugins_overlay.isOverlayEnabled('gui/justice-hq.realistic_arrests')
    end
    return false -- fallback default
end

local function isVillainEntryAlertsEnabled()
    local ok, plugins_overlay = pcall(require, 'plugins.overlay')
    if ok and plugins_overlay and plugins_overlay.isOverlayEnabled then
        return plugins_overlay.isOverlayEnabled('gui/justice-hq.villain_entry_alerts')
    end
    return true -- fallback default
end

--
-- Military Line-of-Sight Check (module-level)
--
local function isNearMilitary(thief_unit, max_distance)
    if not thief_unit or not thief_unit.pos then return false, nil end
    local max_d = max_distance or 20
    for _, u in ipairs(df.global.world.units.active) do
        if dfhack.units.isCitizen(u) and dfhack.units.isActive(u) and not dfhack.units.isDead(u) then
            if u.military.squad_id >= 0 then
                local dx = math.abs(u.pos.x - thief_unit.pos.x)
                local dy = math.abs(u.pos.y - thief_unit.pos.y)
                local dz = math.abs(u.pos.z - thief_unit.pos.z)
                if dz <= 1 and dx <= max_d and dy <= max_d then
                    if dfhack.maps.canWalkBetween(u.pos, thief_unit.pos) then
                        return true, dfhack.units.getReadableName(u)
                    end
                end
            end
        end
    end
    return false, nil
end

--
-- Crime Processing (shared by poll and event hook)
--
local function processNewCrimes(is_initial_scan)
    local showed_popup_this_loop = false
    for _, crime in ipairs(df.global.world.crimes.all) do
        if not GLOBAL_ALERTED_CRIMES[crime.id] then
            local m = crime.mode
            local is_theft = (m == df.crime_type.Theft
                           or m == df.crime_type.AttemptedTheft
                           or m == df.crime_type.Treason
                           or m == df.crime_type.Espionage
                           or m == df.crime_type.Robbery
                           or m == 3 or m == 17)
            
            if is_theft then
                GLOBAL_ALERTED_CRIMES[crime.id] = true
                CRIME_CACHE = nil
                
                if not is_initial_scan and not showed_popup_this_loop then
                    local crime_name = getCrimeName(crime.mode)
                    
                    local accused_unit = nil
                    if crime.accused >= 0 then
                        accused_unit = df.unit.find(crime.accused)
                    end
                    if not accused_unit and crime.criminal >= 0 then
                        accused_unit = df.unit.find(crime.criminal)
                    end
                    
                    local caught = false
                    local guard_name = ""
                    if accused_unit and dfhack.units.isActive(accused_unit) and not dfhack.units.isDead(accused_unit) then
                        if isRealisticArrestsEnabled() then
                            caught, guard_name = isNearMilitary(accused_unit, 20)
                        else
                            caught = true
                            guard_name = "an alert citizen"
                        end
                    end
                    
                    if caught then
                        local thief_name = dfhack.units.getReadableName(accused_unit)
                        
                        local item_desc = ""
                        if crime.item_id >= 0 then
                            pcall(function()
                                local item = df.item.find(crime.item_id)
                                if item then
                                    item_desc = "\nStolen item: " .. dfhack.items.getDescription(item, 0, true)
                                end
                            end)
                        end
                        
                        df.global.pause_state = true
                        pcall(function()
                            if dfhack.gui.revealInDwarfmodeMap then
                                dfhack.gui.revealInDwarfmodeMap(accused_unit.pos, true)
                            elseif dfhack.gui.pauseRecenter then
                                dfhack.gui.pauseRecenter(accused_unit.pos)
                            elseif dfhack.gui.recenterCamera then
                                dfhack.gui.recenterCamera(accused_unit.pos)
                            end
                        end)
                        
                        pcall(function()
                            dfhack.gui.makeAnnouncement(
                                df.announcement_type.MEGABEAST_ARRIVAL,
                                {D_DISPLAY=true}, accused_unit.pos,
                                "JUSTICE HQ: " .. crime_name .. " in progress! " .. thief_name .. " caught by " .. guard_name .. "!",
                                COLOR_LIGHTRED, true)
                        end)
                        
                        local crime_ref = crime
                        local unit_ref = accused_unit
                        
                        local dialog
                        dialog = dialogs.DialogScreen{
                            title = 'CI-HQ: Emergency Detainment',
                            message_label_attrs = {
                                frame = {t=0, l=0, b=4},
                                text = 'CI-HQ EMERGENCY: ' .. thief_name .. ' was caught committing ' .. crime_name .. ' by ' .. guard_name .. '!' ..
                                    item_desc ..
                                    '\n\nDo you authorize emergency detainment?' ..
                                    '\nThe suspect will be chained in the dungeon and any stolen items will be confiscated.',
                                text_pen = COLOR_LIGHTRED,
                            },
                            accept_hotkey_label_attrs = {
                                label = 'Yes, chain them',
                                frame = {b=0, l=0},
                            },
                            on_accept = function()
                                local ok, err = detainUnit(unit_ref)
                                if ok then
                                    local taken = confiscateStolenItem(unit_ref, crime_ref)
                                    local msg = "CI-HQ: " .. thief_name .. " has been chained in the dungeon!"
                                    if #taken > 0 then
                                        msg = msg .. " Confiscated: " .. table.concat(taken, ", ")
                                    end
                                    cihq_announce(msg, COLOR_LIGHTMAGENTA, true)
                                else
                                    cihq_announce("CI-HQ: Emergency detainment FAILED for " .. thief_name .. ". " .. tostring(err), COLOR_RED, true)
                                end
                            end,
                            on_cancel = function() end,
                            subviews = {
                                widgets.HotkeyLabel{
                                    frame = {b=0, r=0},
                                    label = 'No, let them be',
                                    key = 'LEAVESCREEN',
                                    auto_width = true,
                                    on_activate = function()
                                        dialog:dismiss()
                                        cihq_announce("CI-HQ ALERT: " .. crime_name .. " by " .. thief_name .. " — handle manually via CI-HQ.", COLOR_YELLOW, true)
                                    end,
                                }
                            }
                        }
                        dialog:show()
                        showed_popup_this_loop = true
                    elseif accused_unit and dfhack.units.isActive(accused_unit) and not dfhack.units.isDead(accused_unit) then
                        local thief_name = dfhack.units.getReadableName(accused_unit)
                        cihq_announce(
                            "CI-HQ ALERT: " .. crime_name .. " by " .. thief_name .. " detected! (No guards were nearby to intercept). Handle manually via CI-HQ.", COLOR_YELLOW, true)
                    else
                        cihq_announce(
                            "CI-HQ ALERT: " .. crime_name .. " detected! Suspect not found on map. Check Cases tab.", COLOR_LIGHTRED, true)
                    end
                end
            end
        end
    end
end

--
-- Background Monitor Daemon
--

GLOBAL_INITIAL_SCAN_DONE = GLOBAL_INITIAL_SCAN_DONE or false

function ci_alert_monitor_tick()
    -- Restart the interrogation monitor if any watches are active/dispatched
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
        
        local dominated = dfhack.units.isCitizen(unit)
            or dfhack.units.isResident(unit)
            or dfhack.units.isVisiting(unit)
            
        if dominated and not dfhack.units.isInvader(unit) then
            if unit.profession == df.profession.BABY or unit.profession == df.profession.CHILD then goto skip_mon end
            if unit.flags1.tame then goto skip_mon end

            local is_suspect = false
            local hfid = unit.hist_figure_id
            
            if hfid ~= -1 then
                local hf = df.historical_figure.find(hfid)
                if hf then
                    local intrigue_data = getHfIntrigueData(hf)
                    if intrigue_data.is_villain then is_suspect = true end
                end
                
                initCrimeCache()
                local open_crimes = getOpenCrimes(hfid)
                
                if #open_crimes > 0 then
                    if not is_initial_scan and isVillainEntryAlertsEnabled() then
                        local name = dfhack.units.getReadableName(unit)
                        local crime_names = {}
                        for _, c in ipairs(open_crimes) do
                            local cname = getCrimeName(c.mode)
                            table.insert(crime_names, cname)
                        end
                        
                        df.global.pause_state = true
                        pcall(function()
                            if dfhack.gui.revealInDwarfmodeMap then
                                dfhack.gui.revealInDwarfmodeMap(unit.pos, true)
                            elseif dfhack.gui.pauseRecenter then
                                dfhack.gui.pauseRecenter(unit.pos)
                            elseif dfhack.gui.recenterCamera then
                                dfhack.gui.recenterCamera(unit.pos)
                            end
                        end)
                        
                        local text = "Wanted criminal detected inside the fortress: " .. name .. "\n\nWanted for: " .. table.concat(crime_names, ", ") .. "\n\nArrest them immediately before they escape or continue plotting!"
                        require('gui.dialogs').showMessage("Justice HQ Alert", text, COLOR_LIGHTRED)
                        pcall(function() dfhack.gui.makeAnnouncement(df.announcement_type.MEGABEAST_ARRIVAL, {D_DISPLAY=true}, unit.pos, "JUSTICE HQ: Wanted criminal " .. name .. " detected!", COLOR_LIGHTRED, true) end)
                    end
                    GLOBAL_ALERTED_UNITS[unit.id] = true
                    goto skip_mon
                end
            end
            
            if not is_suspect then
                local crimes = getUnitCrimeData(unit)
                if crimes.times_accused > 0 then
                    is_suspect = true
                end
            end
            
            if is_suspect then
                if not is_initial_scan then
                    local name = dfhack.units.getReadableName(unit)
                    cihq_announce("CI-HQ ALERT: A suspect with criminal/intelligence activity (" .. name .. ") has been detected!", COLOR_LIGHTRED, true)
                end
                GLOBAL_ALERTED_UNITS[unit.id] = true
            end
        end
        ::skip_mon::
    end
    
    -- Also poll crimes as fallback
    processNewCrimes(is_initial_scan)
    
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

    if sc == SC_PAUSED and enabled and GLOBAL_INITIAL_SCAN_DONE then
        -- Trigger crime scan instantly when the game pauses (e.g., from vanilla theft announcements)
        processNewCrimes(false)
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

local function handle_enable_disable(action)
    if action == 'enable' or action == '1' then
        enabled = true
        persist_state()
        repeatUtil.scheduleUnlessAlreadyScheduled('ci-hq-monitor', 1200, 'ticks', ci_alert_monitor_tick)
        print("CI-HQ: Background suspect alert monitor ENABLED (with instant pause detection).")
        return true
    elseif action == 'disable' or action == '0' then
        enabled = false
        persist_state()
        repeatUtil.cancel('ci-hq-monitor')
        GLOBAL_INITIAL_SCAN_DONE = false
        GLOBAL_ALERTED_UNITS = {}
        GLOBAL_ALERTED_CRIMES = {}
        print("CI-HQ: Background suspect alert monitor DISABLED.")
        return true
    end
    return false
end

-- Handle enable/disable from gui/control-panel or dfhack_flags
if dfhack_flags and dfhack_flags.enable then
    local action = dfhack_flags.enable_state and 'enable' or 'disable'
    if handle_enable_disable(action) then
        return
    end
end

-- For manual arguments passed to the script via console, we just use the global `args` if available, or just ignore since we use dfhack_flags
if _G.args and type(_G.args) == 'table' and #_G.args > 0 then
    if handle_enable_disable(_G.args[1]) then
        return
    end
end

local screen = JusticeHQ()
screen:show()
