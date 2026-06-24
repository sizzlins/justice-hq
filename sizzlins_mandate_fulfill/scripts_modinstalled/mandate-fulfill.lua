-- Auto-queue work orders for active noble production mandates.
--@ enable=true
--@ module=true
--[====[

mandate-fulfill
===============
Scans all active production mandates from your nobles and automatically
queues manager work orders to fulfill them. Existing matching orders
are detected and skipped to avoid duplicates.

Can be run continuously in the background to automate this process.

Usage::

    gui/control-panel         Enable/disable the daemon from the "UI Overlays" tab (Recommended)

    enable mandate-fulfill    (CLI) Enable the script to run daily in the background.
    disable mandate-fulfill   (CLI) Disable the background script.
    mandate-fulfill status    (CLI) Show current status.
    
    mandate-fulfill           (CLI) Run once right now.
    mandate-fulfill --dry     (CLI) Dry run: show what would be queued without actually queuing.
    mandate-fulfill --list    (CLI) Only list active mandates, don't queue anything.

]====]

local json = require('json')
local utils = require('utils')
local argparse = require('argparse')
local repeatutil = require('repeat-util')
local workorder = reqscript('workorder')

local GLOBAL_KEY = 'mandate-fulfill'
if enabled == nil then enabled = true end

-- ============================================================
-- Item type -> Job type mapping
-- ============================================================
local item_to_job = {
    [df.item_type.DOOR]           = 'ConstructDoor',
    [df.item_type.FLOODGATE]      = 'ConstructFloodgate',
    [df.item_type.BED]            = 'ConstructBed',
    [df.item_type.CHAIR]          = 'ConstructThrone',
    [df.item_type.TABLE]          = 'ConstructTable',
    [df.item_type.COFFIN]         = 'ConstructCoffin',
    [df.item_type.STATUE]         = 'ConstructStatue',
    [df.item_type.BOX]            = 'ConstructChest',
    [df.item_type.CABINET]        = 'ConstructCabinet',
    [df.item_type.ARMORSTAND]     = 'ConstructArmorStand',
    [df.item_type.WEAPONRACK]     = 'ConstructWeaponRack',
    [df.item_type.BLOCKS]         = 'ConstructBlocks',
    [df.item_type.HATCH_COVER]    = 'ConstructHatchCover',
    [df.item_type.GRATE]          = 'ConstructGrate',
    [df.item_type.QUERN]          = 'ConstructQuern',
    [df.item_type.MILLSTONE]      = 'ConstructMillstone',
    [df.item_type.SLAB]           = 'ConstructSlab',
    [df.item_type.TRACTION_BENCH] = 'ConstructTractionBench',
    [df.item_type.SPLINT]         = 'ConstructSplint',
    [df.item_type.CRUTCH]         = 'ConstructCrutch',
    [df.item_type.ANVIL]          = 'ForgeAnvil',
    [df.item_type.WEAPON]         = 'MakeWeapon',
    [df.item_type.ARMOR]          = 'MakeArmor',
    [df.item_type.SHOES]          = 'MakeShoes',
    [df.item_type.HELM]           = 'MakeHelm',
    [df.item_type.GLOVES]         = 'MakeGloves',
    [df.item_type.PANTS]          = 'MakePants',
    [df.item_type.SHIELD]         = 'MakeShield',
    [df.item_type.AMMO]           = 'MakeAmmo',
    [df.item_type.CAGE]           = 'MakeCage',
    [df.item_type.BARREL]         = 'MakeBarrel',
    [df.item_type.BUCKET]         = 'MakeBucket',
    [df.item_type.CHAIN]          = 'MakeChain',
    [df.item_type.FLASK]          = 'MakeFlask',
    [df.item_type.GOBLET]         = 'MakeGoblet',
    [df.item_type.TOY]            = 'MakeToy',
    [df.item_type.ANIMALTRAP]     = 'MakeAnimalTrap',
    [df.item_type.WINDOW]         = 'MakeWindow',
    [df.item_type.BAG]            = 'ConstructBag',
    [df.item_type.BIN]            = 'ConstructBin',
    [df.item_type.BACKPACK]       = 'MakeBackpack',
    [df.item_type.QUIVER]         = 'MakeQuiver',
    [df.item_type.PIPE_SECTION]   = 'MakePipeSection',
    [df.item_type.TOOL]           = 'MakeTool',
    [df.item_type.FIGURINE]       = 'MakeFigurine',
    [df.item_type.AMULET]         = 'MakeAmulet',
    [df.item_type.SCEPTER]        = 'MakeScepter',
    [df.item_type.CROWN]          = 'MakeCrown',
    [df.item_type.RING]           = 'MakeRing',
    [df.item_type.EARRING]        = 'MakeEarring',
    [df.item_type.BRACELET]       = 'MakeBracelet',
    [df.item_type.GEM]            = 'MakeGem',
    [df.item_type.CATAPULTPARTS]  = 'ConstructCatapultParts',
    [df.item_type.BALLISTAPARTS]  = 'ConstructBallistaParts',
    [df.item_type.BALLISTAARROWHEAD] = 'MakeBallistaArrowHead',
    [df.item_type.TRAPPARTS]      = 'ConstructMechanisms',
    [df.item_type.TRAPCOMP]       = 'MakeTrapComponent',
    [df.item_type.TOTEM]          = 'MakeTotem',
    [df.item_type.SIEGEAMMO]      = 'AssembleSiegeAmmo',
    [df.item_type.BOLT_THROWER_PARTS] = 'ConstructBoltThrowerParts',
    [df.item_type.COIN]           = 'MintCoins',
    [df.item_type.CHEESE]         = 'MakeCheese',
    [df.item_type.CLOTH]          = 'WeaveCloth',
}

-- ============================================================
-- Helpers
-- ============================================================

local function get_item_name(item_type, item_subtype)
    if item_subtype >= 0 then
        local st = dfhack.items.getSubtypeDef(item_type, item_subtype)
        if st and st.name then return st.name end
    end
    return (df.item_type[item_type] or tostring(item_type)):lower()
end

local function find_existing_order(job_type_id, item_subtype)
    for _, order in ipairs(df.global.world.manager_orders.all) do
        if order.job_type == job_type_id and order.item_subtype == item_subtype then
            -- Mandates require immediate fulfillment. We must ignore existing orders
            -- that have conditions, as they might be paused/inactive standing orders.
            if #order.item_conditions == 0 and #order.order_conditions == 0 then
                if order.amount_left > 0 then
                    return order
                end
            end
        end
    end
    return nil
end

-- ============================================================
-- Background Service State
-- ============================================================

function isEnabled()
    local has_overlay, overlay = pcall(require, 'plugins.overlay')
    if has_overlay and overlay and overlay.isOverlayEnabled then
        return overlay.isOverlayEnabled('mandate-fulfill.daemon')
    end
    return enabled
end

local function process_mandates(dry_run, list_only, quiet)
    local mandates = df.global.world.mandates.all
    local make_mandates = {}

    for i = 0, #mandates - 1 do
        local m = mandates[i]
        if m.mode == 1 and m.amount_remaining > 0 then
            table.insert(make_mandates, m)
        end
    end

    if #make_mandates == 0 then
        if not quiet then print('No active production mandates found.') end
        return
    end

    if not quiet then
        print(string.format('Found %d active production mandate(s):', #make_mandates))
        print()
    end

    local queued = 0

    for _, m in ipairs(make_mandates) do
        local noble_name = dfhack.units.getReadableName(m.unit)
        local item_name = get_item_name(m.item_type, m.item_subtype)
        local job_name = item_to_job[m.item_type]
        local ticks_left = m.timeout_limit - m.timeout_counter
        local pct_left = math.floor((ticks_left / m.timeout_limit) * 100)

        local urgency = 'OK'
        if pct_left < 10 then urgency = '!!CRITICAL!!'
        elseif pct_left < 25 then urgency = '!URGENT!'
        elseif pct_left < 50 then urgency = 'Soon'
        end

        if not quiet then
            print(string.format('  [%s] %s demands %d %s  (%d%% time remaining)',
                urgency, noble_name, m.amount_remaining, item_name, pct_left))
        end

        if not job_name then
            if not quiet then
                print(string.format('    -> SKIP: No known job type for item type %s (%d)',
                    df.item_type[m.item_type] or '?', m.item_type))
            end
            goto skip_mandate
        end

        local job_type_id = df.job_type[job_name]
        local existing = find_existing_order(job_type_id, m.item_subtype >= 0 and m.item_subtype or -1)
        if existing then
            if not quiet then
                print(string.format('    -> SKIP: Matching order already queued (%d remaining)',
                    existing.amount_left))
            end
            goto skip_mandate
        end

        if list_only then
            print(string.format('    -> Would queue: %s x%d', job_name, m.amount_remaining))
            goto skip_mandate
        end

        local order = { job = job_name, amount_total = m.amount_remaining, frequency = 'OneTime' }

        if m.item_subtype >= 0 then
            order.item_subtype = m.item_subtype
        end

        if m.mat_type >= 0 then
            local mat = dfhack.matinfo.decode(m.mat_type, m.mat_index)
            if mat then
                order.material = mat:getToken()
            end
        else
            local job_defaults = {
                ConstructBed = 'wood', ConstructDoor = 'stone', ConstructCabinet = 'stone',
                ConstructTable = 'stone', ConstructThrone = 'stone', ConstructChest = 'stone',
                ConstructArmorStand = 'stone', ConstructWeaponRack = 'stone', ConstructStatue = 'stone',
                ConstructCoffin = 'stone', ConstructHatchCover = 'stone', ConstructGrate = 'stone',
                ConstructQuern = 'stone', ConstructMillstone = 'stone', ConstructTractionBench = 'wood',
                ConstructSlab = 'stone', ForgeAnvil = 'iron', MakeWindow = 'glass', MakeCage = 'wood',
                MakeBarrel = 'wood', MakeBucket = 'wood', MakeAnimalTrap = 'wood', MakeChain = 'iron',
                MakeFlask = 'iron', MakeGoblet = 'stone', ConstructBlocks = 'stone', MakeWeapon = 'iron',
                MakeArmor = 'iron', MakeShoes = 'leather', MakeHelm = 'iron', MakeGloves = 'leather',
                MakePants = 'leather', MakeShield = 'wood', MakeAmmo = 'wood', MakeFigurine = 'stone',
                MakeAmulet = 'stone', MakeScepter = 'stone', MakeCrown = 'stone', MakeRing = 'stone',
                MakeEarring = 'stone', MakeBracelet = 'stone', MakeGem = 'stone', MakeTool = 'stone',
                ConstructFloodgate = 'stone', ConstructSplint = 'wood', ConstructCrutch = 'wood',
                MakeToy = 'stone', ConstructBag = 'leather', ConstructBin = 'wood',
                MakeBackpack = 'leather', MakeQuiver = 'leather', MakePipeSection = 'glass',
                ConstructCatapultParts = 'wood', ConstructBallistaParts = 'wood', MakeBallistaArrowHead = 'iron',
                ConstructMechanisms = 'stone', MakeTrapComponent = 'iron', MakeTotem = 'bone',
                AssembleSiegeAmmo = 'wood', ConstructBoltThrowerParts = 'wood', MintCoins = 'iron',
                MakeCheese = 'plant', WeaveCloth = 'plant'
            }
            local def_cat = job_defaults[job_name] or 'stone' -- Ultimate fallback to prevent 'unknown'
            local valid_mat_cats = {
                wood=true, bone=true, shell=true, horn=true, pearl=true, tooth=true,
                leather=true, silk=true, yarn=true, cloth=true, plant=true
            }
            if valid_mat_cats[def_cat] then
                order.material_category = {def_cat}
            elseif def_cat == 'stone' then
                order.material = 'INORGANIC'
            elseif def_cat == 'glass' then
                order.material = 'GLASS_GREEN'
            elseif def_cat == 'iron' then
                order.material = 'IRON'
            end
        end

        if dry_run then
            print(string.format('    -> DRY RUN: Would queue %s x%d (json: %s)',
                job_name, m.amount_remaining, json.encode(order)))
        else
            local orders = workorder.preprocess_orders({order})
            workorder.fillin_defaults(orders)
            workorder.create_orders(orders, true)
            queued = queued + 1
            
            local readable_job = job_name:gsub('%u', ' %1'):sub(2)
            local msg = string.format('Mandate Fulfill: Automatically queued %s x%d for noble %s',
                readable_job, m.amount_remaining, noble_name)
                
            -- Show in-game announcement (mapping light colors to base colors for v50 compatibility)
            dfhack.gui.showAnnouncement(msg, COLOR_GREEN, false)

            if quiet then
                print(msg)
            else
                print(string.format('    -> QUEUED: %s x%d', readable_job, m.amount_remaining))
            end
        end
        ::skip_mandate::
    end

    if not quiet then
        print()
        if list_only then
            print('List only mode. No orders were queued.')
        elseif dry_run then
            print('Dry run complete. No orders were actually queued.')
        else
            print(string.format('Done! Queued %d work order(s).', queued))
        end
    end
end

local function event_loop()
    if not dfhack.isMapLoaded() then return end
    if not isEnabled() then return end

    process_mandates(false, false, true) -- Background loop is always quiet

    -- Check daily (1200 ticks = 1 in-game day)
    repeatutil.scheduleUnlessAlreadyScheduled(GLOBAL_KEY, 1, 'days', event_loop)
end

-- ============================================================
-- Overlay Widget (for DFHack Control Panel integration)
-- ============================================================
local has_overlay, overlay = pcall(require, 'plugins.overlay')
if has_overlay and overlay then
    MandateFulfillOverlay = defclass(MandateFulfillOverlay, overlay.OverlayWidget)
    MandateFulfillOverlay.ATTRS = {
        desc = 'Auto-Fulfill Mandates daemon. Leave enabled to automate workorders for nobles mandates.',
        default_pos = {x=0,y=0},
        default_enabled = true,
        viewscreens = 'dwarfmode',
        frame = {w=0, h=0},
    }
    function MandateFulfillOverlay:init()
        if not repeatutil.isScheduled(GLOBAL_KEY) then
            event_loop()
        end
    end
    function MandateFulfillOverlay:onRenderFrame(dc, rect)
        -- Invisible daemon
    end
    OVERLAY_WIDGETS = { daemon = MandateFulfillOverlay }
end

if dfhack_flags.module then
    return
end


local function print_status()
    print(('mandate-fulfill is currently %s.'):format(isEnabled() and 'enabled' or 'disabled'))
end

local args = {...}
if dfhack_flags and dfhack_flags.enable then
    args = {dfhack_flags.enable_state and 'enable' or 'disable'}
end

local dry_run, list_only = false, false

local positionals = argparse.processArgsGetopt(args, {
    { 'h', 'help', handler = function() print(dfhack.script_help()) end },
    { 'n', 'dry', handler = function() dry_run = true end },
    { 'l', 'list', handler = function() list_only = true end },
})

if positionals[1] == 'enable' then
    local has_overlay, overlay = pcall(require, 'plugins.overlay')
    if has_overlay and overlay and overlay.overlay_command then
        overlay.overlay_command({'enable', 'mandate-fulfill.daemon'})
    end
    enabled = true
    event_loop()
    print_status()
elseif positionals[1] == 'disable' then
    local has_overlay, overlay = pcall(require, 'plugins.overlay')
    if has_overlay and overlay and overlay.overlay_command then
        overlay.overlay_command({'disable', 'mandate-fulfill.daemon'})
    end
    enabled = false
    repeatutil.cancel(GLOBAL_KEY)
    print_status()
elseif positionals[1] == 'status' then
    print_status()
elseif positionals[1] == nil and not dry_run and not list_only then
    -- Interactive run
    process_mandates(false, false, false)
elseif dry_run or list_only then
    process_mandates(dry_run, list_only, false)
end


