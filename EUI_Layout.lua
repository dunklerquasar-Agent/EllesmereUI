if EUI_CLIENT_BLOCKED then return end -- pre-12.1 client failsafe (EllesmereUI_ClientGate.lua)
-------------------------------------------------------------------------------
--  EUI_Layout.lua  --  Layout Ownership Registry  (Layout Center, step B1)
--
--  One place that answers, for every element registered with Unlock Mode:
--    * which CATEGORY it belongs to (for listing, filtering and reporting)
--    * WHO owns its layout state (element accessor / module DB / core global)
--    * how to READ that state without touching the live UI
--
--  Ownership map (derived, no module cooperation required):
--    position  elem.loadPosition/savePosition  -> owned by the element's own DB
--              neither accessor                -> self-positioning (noInitHook /
--                                                 ownsPosition), read-only here
--    anchor    always EllesmereUIDB.unlockAnchors[key] (the core global, the
--              same table the modules read directly)
--    match     always EllesmereUIDB.unlock{Width,Height}Match(+Extra), read
--              through the public getters on EllesmereUI
--    size      elem.getSize / setWidth / setHeight (module DB behind it)
--    grow      module-owned; only reported as a flag (never written here)
--
--  STRICTLY READ-ONLY (plus the per-element lock flag). Every WRITE in the
--  Layout Center must go through the unlock-mode sinks -- pendingPositions,
--  UM.SaveBarPosition, UM.SetAnchorInfo, UM.MatchH, elem.savePosition -- or the
--  spec-override harvest, the login apply and the snap cascades stop agreeing
--  with what the panel shows.
--
--  Costs nothing until first use: the index builds on the first call and
--  rebuilds only when the registration registry changed.
-------------------------------------------------------------------------------
local EllesmereUI = _G.EllesmereUI
if not EllesmereUI then return end

-- Already loaded (another copy of the core, or a standalone build): registration
-- API and listeners below must exist only once.
if EllesmereUI.Layout then return end

local Layout = {}
EllesmereUI.Layout = Layout

-------------------------------------------------------------------------------
--  Categories -- one bucket per suite folder. Registrations without a folder
--  land in "Other" (outside addons, and suite files that register without
--  stamping one); the unlock core's own screen-edge strips get "Core".
-------------------------------------------------------------------------------
local CATEGORY_LIST = {
    { "EllesmereUIUnitFrames",          10,  "Unit Frames" },
    { "EllesmereUIRaidFrames",          20,  "Raid & Party Frames" },
    { "EllesmereUIPartyMode",           25,  "Party Mode" },
    { "EllesmereUIActionBars",          30,  "Action Bars" },
    { "EllesmereUICooldownManager",     40,  "Cooldown Manager" },
    { "EllesmereUIResourceBars",        50,  "Resource Bars" },
    { "EllesmereUIAuraBuffReminders",   60,  "Auras & Reminders" },
    { "EllesmereUINameplates",          70,  "Nameplates" },
    { "EllesmereUIMinimap",             80,  "Minimap" },
    { "EllesmereUIChat",                90,  "Chat" },
    { "EllesmereUIDataBars",           100,  "DataBars" },
    { "EllesmereUIBags",               110,  "Bags" },
    { "EllesmereUIFriends",            120,  "Friends List" },
    { "EllesmereUIDamageMeters",       130,  "Damage Meters" },
    { "EllesmereUIMythicTimer",        140,  "Mythic+ Tools" },
    { "EllesmereUIQuestTracker",       150,  "Quest Tracker" },
    { "EllesmereUIQuickdraw",          160,  "Quickdraw" },
    { "EllesmereUILoadoutManager",     170,  "Loadout Manager" },
    { "EllesmereUISimpleLootCouncil",  180,  "Loot Council" },
    { "EllesmereUIQoL",                200,  "Quality of Life" },
    { "EllesmereUIForeverEssentials",  210,  "Forever Essentials" },
    { "EllesmereUIBlizzardSkin",       220,  "Blizzard Skin" },
    { "EllesmereUI",                   900,  "Core" },
}

local CATEGORY_BY_FOLDER = {}
for i = 1, #CATEGORY_LIST do
    local entry = CATEGORY_LIST[i]
    CATEGORY_BY_FOLDER[entry[1]] = { order = entry[2], label = entry[3] }
end

--- Bucket for everything the folder map does not cover: outside addons and
--- core/module files that register without stamping a folder.
local CATEGORY_OTHER = { order = 950, label = "Other" }

--- The unlock core's own screen-edge strips: registered from the core, never
--- dragged, never part of a layout fork. They get their own bucket so a listing
--- can hide them behind one switch instead of hiding "Core" as a whole.
local CATEGORY_CORE = { order = 900, label = "Core" }

local function CategoryFor(folder)
    local cat = folder and CATEGORY_BY_FOLDER[folder]
    if cat then return cat end
    return CATEGORY_OTHER
end

-------------------------------------------------------------------------------
--  Per-element locks -- core SavedVariables, created on first use so no
--  migration pass is needed and an untouched install gains no new table.
-------------------------------------------------------------------------------
local function LockDB(create)
    if type(EllesmereUIDB) ~= "table" then return nil end
    local store = EllesmereUIDB.layoutCenter
    if not store then
        if not create then return nil end
        store = {}
        EllesmereUIDB.layoutCenter = store
    end
    if not store.locks then
        if not create then return nil end
        store.locks = {}
    end
    return store.locks
end

function Layout.IsLocked(key)
    local locks = LockDB(false)
    return (locks and locks[key] == true) or false
end

function Layout.SetLock(key, on)
    if type(key) ~= "string" or key == "" then return false end
    local locks = LockDB(on == true)
    if not locks then return false end
    if on == true then
        locks[key] = true
    else
        locks[key] = nil
    end
    Layout._Notify("lock", key)
    return true
end

function Layout.GetLockedKeys()
    local locks = LockDB(false)
    if not locks then return nil end
    return locks
end

-------------------------------------------------------------------------------
--  Change notifications -- a thin fan-out so the Layout Center page (B2) can
--  refresh a single row without polling. Same shape as the unlock-mode
--  listeners so both can be driven from one place later.
-------------------------------------------------------------------------------
local listeners = {}

function Layout.RegisterListener(owner, fn)
    if type(fn) ~= "function" then return end
    listeners[owner or fn] = fn
end

function Layout.UnregisterListener(owner)
    listeners[owner] = nil
end

function Layout._Notify(what, key)
    for _, fn in pairs(listeners) do
        pcall(fn, what, key)
    end
end

-------------------------------------------------------------------------------
--  Index -- rows for every registered element, sorted for the listing.
-------------------------------------------------------------------------------
local index = nil          -- array of rows including the internal elements
local view = nil           -- array of rows without them (the default listing)
local indexCount, indexStamp = -1, -1

-- Fresh registrations are detected through our OWN stamp, never through the
-- unlock core's _unlockRegistrationDirty: EUI_UnlockMode consumes that flag to
-- rebuild its element order (EUI_UnlockMode.lua:469-481) and EUI_UnlockMode_Session
-- reads it for its late-registrant retry (:2249), so clearing it here would make
-- the core skip its own rebuild. The wrappers below only observe.
local registrationStamp = 0

local function BumpStamp() registrationStamp = registrationStamp + 1 end

do
    local register = EllesmereUI.RegisterUnlockElements
    if type(register) == "function" then
        EllesmereUI.RegisterUnlockElements = function(self, elements, folder)
            BumpStamp()
            return register(self, elements, folder)
        end
    end
    local unregister = EllesmereUI.UnregisterUnlockElement
    if type(unregister) == "function" then
        EllesmereUI.UnregisterUnlockElement = function(self, key)
            BumpStamp()
            return unregister(self, key)
        end
    end
end

--- Element count plus our own stamp: any register/unregister call changes one
--- of the two, so the index rebuilds exactly when the registry changed.
local function RegistrationPoll()
    local count = 0
    local reg = EllesmereUI._unlockRegisteredElements
    if reg then
        for _ in pairs(reg) do count = count + 1 end
    end
    if count ~= indexCount or registrationStamp ~= indexStamp then return false end
    return true
end

local function RememberStamp()
    local count = 0
    local reg = EllesmereUI._unlockRegisteredElements
    if reg then
        for _ in pairs(reg) do count = count + 1 end
    end
    indexCount, indexStamp = count, registrationStamp
end

local function SortRows(a, b)
    if a.catOrder ~= b.catOrder then return a.catOrder < b.catOrder end
    if a.order ~= b.order then return a.order < b.order end
    if a.label ~= b.label then return a.label < b.label end
    return a.key < b.key
end

local function BuildIndex()
    local reg = EllesmereUI._unlockRegisteredElements
    if not reg then
        index, view = {}, {}
        RememberStamp()
        return
    end

    local rows, n = {}, 0
    for key, elem in pairs(reg) do
        if type(key) == "string" and type(elem) == "table" then
            n = n + 1
            local internal = (EllesmereUI.IsScreenEdgeKey ~= nil
                              and EllesmereUI.IsScreenEdgeKey(key)) or false
            local cat = internal and CATEGORY_CORE or CategoryFor(elem.folder)
            -- label / order / group are optional at the call site: a listing
            -- must never show a blank row or sort everything onto one tie.
            local label = elem.label
            if type(label) ~= "string" or label == "" then label = key end
            rows[n] = {
                key           = key,
                label         = label,
                group         = elem.group,
                folder        = elem.folder,
                elem          = elem,
                catOrder      = cat.order,
                catLabel      = cat.label,
                order         = tonumber(elem.order) or 0,
                -- The four screen-edge strips the unlock core registers itself:
                -- anchor targets, never dragged, never part of a layout fork.
                internal      = internal,
                -- Can this element's position be read AND written through the
                -- element API? Elements without accessors are self-positioning
                -- (module draws them from its own settings), so the Layout
                -- Center must show them read-only.
                canPosition   = (elem.loadPosition ~= nil or elem.savePosition ~= nil),
                canResize     = (elem.noResize ~= true
                                 and (elem.setWidth ~= nil or elem.setHeight ~= nil)),
                selfPositioned = (elem.noInitHook == true or elem.ownsPosition == true),
                anchored      = (EllesmereUI.IsUnlockAnchored ~= nil
                                 and EllesmereUI.IsUnlockAnchored(key)) or false,
            }
        end
    end

    table.sort(rows, SortRows)
    index = rows

    -- Default view: everything a layout fork may touch. Rebuilt with the index
    -- so repeat calls hand back the same array (no per-call allocation).
    local keep, m = {}, 0
    for i = 1, n do
        if not rows[i].internal then
            m = m + 1
            keep[m] = rows[i]
        end
    end
    view = keep

    RememberStamp()
end

--- Rows for every registered element.
--- Called with no filter this is the default listing (internal screen-edge
--- strips excluded) and returns the cached array; with a filter it returns a
--- fresh array:
---   filter.internal   true -> include the core's screen-edge strips
---   filter.category   only rows of this category label, e.g. "Action Bars"
---   filter.folder     only rows stamped with this addon folder
---   filter.predicate  extra predicate(row) -> boolean
--- Returned arrays are live index rows: callers iterate, never mutate.
function Layout.GetIndex(filter)
    if not index or not RegistrationPoll() then BuildIndex() end

    if filter == nil then return view end

    local out, n = {}, 0
    for i = 1, #index do
        local row = index[i]
        local keep = true
        if row.internal and filter.internal ~= true then
            keep = false
        elseif filter.category and row.catLabel ~= filter.category then
            keep = false
        elseif filter.folder and row.folder ~= filter.folder then
            keep = false
        elseif filter.predicate and not filter.predicate(row) then
            keep = false
        end
        if keep then
            n = n + 1
            out[n] = row
        end
    end
    return out
end

--- Category labels that currently hold at least one element, in display order.
function Layout.GetCategories()
    local rows = Layout.GetIndex({ internal = true })
    local seen, out, n = {}, {}, 0
    for i = 1, #rows do
        local row = rows[i]
        if not seen[row.catLabel] then
            seen[row.catLabel] = true
            n = n + 1
            out[n] = row.catLabel
        end
    end
    return out
end

function Layout.GetElement(key)
    local reg = EllesmereUI._unlockRegisteredElements
    return reg and reg[key] or nil
end

function Layout.GetRow(key)
    local rows = Layout.GetIndex({ internal = true })
    for i = 1, #rows do
        if rows[i].key == key then return rows[i] end
    end
    return nil
end

function Layout.Count()
    return #Layout.GetIndex({ internal = true })
end

-------------------------------------------------------------------------------
--  State -- a snapshot of everything the Layout Center needs for one element.
--  Never returns live references into the SavedVariables (except elem itself,
--  which callers must treat as read-only).
-------------------------------------------------------------------------------
local function ReadPosition(elem, key)
    local reader = elem.loadPosition or elem.loadRawPosition
    if not reader then return nil end
    local ok, a, b, c, d = pcall(reader, key)
    if not ok then return nil end
    if type(a) == "table" then
        return a.point, a.relPoint or a.point, a.x, a.y
    end
    if a == nil then return nil end
    return a, b or a, c, d
end

function Layout.GetState(key)
    local elem = Layout.GetElement(key)
    if not elem then return nil end

    local point, relPoint, x, y = ReadPosition(elem, key)

    -- Anchors and matches live in the core SavedVariables. Both are read
    -- defensively: GetState is reachable from a debug command before login.
    local hasDB = type(EllesmereUIDB) == "table"
    local link = hasDB and EllesmereUIDB.unlockAnchors and EllesmereUIDB.unlockAnchors[key]
    local anchor
    if type(link) == "table" then
        anchor = {
            target  = link.target,
            side    = link.side,
            offsetX = link.offsetX,
            offsetY = link.offsetY,
        }
    end

    local width, height
    if elem.getSize then
        local ok, w, h = pcall(elem.getSize, key)
        if ok then width, height = w, h end
    elseif elem.getFrame then
        local ok, frame = pcall(elem.getFrame, key)
        if ok and frame then
            width, height = frame:GetWidth(), frame:GetHeight()
        end
    end

    local hidden = false
    if elem.isHidden then
        local ok, value = pcall(elem.isHidden, key)
        if ok then hidden = value == true end
    end

    return {
        key          = key,
        label        = elem.label or key,
        group        = elem.group,
        folder       = elem.folder,
        point        = point,
        relPoint     = relPoint,
        x            = x,
        y            = y,
        anchor       = anchor,
        widthMatch   = hasDB and EllesmereUI.GetWidthMatchTarget
                       and EllesmereUI.GetWidthMatchTarget(key) or nil,
        heightMatch  = hasDB and EllesmereUI.GetHeightMatchTarget
                       and EllesmereUI.GetHeightMatchTarget(key) or nil,
        widthExtra   = hasDB and EllesmereUI.GetMatchExtra
                       and EllesmereUI.GetMatchExtra("w", key) or nil,
        heightExtra  = hasDB and EllesmereUI.GetMatchExtra
                       and EllesmereUI.GetMatchExtra("h", key) or nil,
        width        = width,
        height       = height,
        hidden       = hidden,
        anchored     = (hasDB and EllesmereUI.IsUnlockAnchored ~= nil
                        and EllesmereUI.IsUnlockAnchored(key)) or false,
        locked       = Layout.IsLocked(key),
        canPosition  = (elem.loadPosition ~= nil or elem.savePosition ~= nil),
        canResize    = (elem.noResize ~= true
                        and (elem.setWidth ~= nil or elem.setHeight ~= nil)),
    }
end

--- One-line description, for diagnostics, bug reports and tooltips.
function Layout.Describe(key)
    local state = Layout.GetState(key)
    if not state then return nil end
    local parts = {}
    if state.point then
        parts[#parts + 1] = string.format("%s %s/%s (%s, %s)",
            state.point, tostring(state.relPoint), tostring(state.point),
            tostring(state.x), tostring(state.y))
    else
        parts[#parts + 1] = "self-positioned"
    end
    if state.anchor then
        parts[#parts + 1] = string.format("anchored to %s (%s, %s, %s)",
            tostring(state.anchor.target), tostring(state.anchor.side),
            tostring(state.anchor.offsetX), tostring(state.anchor.offsetY))
    end
    if state.widthMatch then parts[#parts + 1] = "W-Match " .. tostring(state.widthMatch) end
    if state.heightMatch then parts[#parts + 1] = "H-Match " .. tostring(state.heightMatch) end
    if state.hidden then parts[#parts + 1] = "hidden" end
    if state.locked then parts[#parts + 1] = "locked" end
    return table.concat(parts, " | ")
end

-------------------------------------------------------------------------------
--  Reporting -- counts per category and per ownership kind. The first consumer
--  is the "/eui layout" debug command and the Layout Center header; the
--  diagnostic pass (B10) extends it.
-------------------------------------------------------------------------------
function Layout.Summary()
    local rows = Layout.GetIndex({ internal = true })
    local out = {
        total      = 0,
        internal   = 0,
        positionable = 0,
        readOnly   = 0,
        resizable  = 0,
        anchored   = 0,
        locked     = 0,
        categories = {},
    }
    local locks = LockDB(false)
    for i = 1, #rows do
        local row = rows[i]
        out.total = out.total + 1
        if row.internal then out.internal = out.internal + 1 end
        if row.canPosition then out.positionable = out.positionable + 1 else out.readOnly = out.readOnly + 1 end
        if row.canResize then out.resizable = out.resizable + 1 end
        if row.anchored then out.anchored = out.anchored + 1 end
        if locks and locks[row.key] then out.locked = out.locked + 1 end
        out.categories[row.catLabel] = (out.categories[row.catLabel] or 0) + 1
    end
    return out
end

function Layout.PrintSummary()
    local s = Layout.Summary()
    local print = EllesmereUI.Print or print
    print(string.format("Layout Center registry: %d elements (%d internal) | %d positionable, %d read-only, %d resizable, %d anchored, %d locked",
        s.total, s.internal, s.positionable, s.readOnly, s.resizable, s.anchored, s.locked))
    local cats = Layout.GetCategories()
    for i = 1, #cats do
        local label = cats[i]
        print(string.format("  %-24s %d", label, s.categories[label] or 0))
    end
end

--- Rebuild on demand. The index already notices new registrations by itself
--- (wrapper stamp + element count); this is for callers that want the view
--- refreshed right now -- after a profile/spec switch, or from the panel.
function Layout.Refresh()
    BuildIndex()
    Layout._Notify("index")
end
