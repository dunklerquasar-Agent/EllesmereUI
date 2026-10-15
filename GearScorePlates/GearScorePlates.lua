if EUI_CLIENT_BLOCKED then return end -- pre-12.1 client failsafe (EllesmereUI_ClientGate.lua)
-------------------------------------------------------------------------------
--  GearScorePlates.lua  (standalone personal plugin, v1.6.0)
--  Shows the inspected average item level ("gear score") on the ELLESMEREUI
--  UNIT FRAMES: the number sits inside the right end of the target frame's
--  health bar (same visual language as the old plate sketch). The focus
--  frame displays the value from cache only (no own query) - a focused
--  player was almost always targeted recently, so the display is free.
--
--  v1.3.0 (29.09., user request): nameplate rendering REMOVED - the number
--  now lives on the unit frames, not on the plates. The addon keeps its
--  historic name (folder = SavedVariables identity); versions 1.0-1.2
--  rendered on Platynator/EllesmereUI nameplates.
--  v1.4.0: display fully adjustable via /gsp (position, font size, color
--  incl. class color, delta mode versus your own ilvl); all live-applied.
--  v1.4.1: public read/write API (_G.GearScorePlates) for the EllesmereUI
--  options integration - the personal suite build shows a "GearScore" block
--  under Unit Frames > Main Frames (target/focus) that edits the very same
--  SavedVariables; slash and options stay in sync, either way works.
--  v1.4.2: Midnight API fix - the global GetInspectItemLevel no longer
--  exists on 12.x ("attempt to call a nil value" at INSPECT_READY, which
--  also wedged the pipeline because ClearInspectPlayer never ran). Reads
--  now go through C_PaperDollInfo.GetInspectItemLevel via a GUID-derived
--  unit token, pcall-hardened; delta mode compares against the EQUIPPED
--  average (GetAverageItemLevel's 2nd return), matching the inspect value.
--  v1.4.3 (user request): group-only mode, default ON - queries AND the
--  display are limited to party/raid members; strangers are never
--  inspected and never show a number. /gsp group <on|off>, options cog
--  toggle "Only Group & Raid Members". Queued entries for units that left
--  the group are discarded at fire time; the 5s sweep hides stale texts.
--  v1.4.5: query and display ordinary party/raid members on visible
--  Blizzard CompactUnitFrames; target/focus support remains available.
--  v1.4.6: fallback scan of the live party/raid compact-frame pools when
--  the public unit-frame resolver is unavailable or incomplete.
--  v1.4.7: recursive scan of compact-frame roots for nested member frames.
--  v1.4.8: use EllesmereUI.GetUnitFrame(unit) as the primary party/raid
--  v1.5.0: class-colour lookup is secret-safe (secret class tokens are
--          never used as a table key); verified against EUI 9.5.4.
--  v1.6.0: registers its own section in the EllesmereUI options panel through
--          the suite plugin API (PLUGIN_API_VERSION 1); combat retries use the
--          suite combat queue; /gsp opens the panel.
--  integration path; generic Blizzard-frame scanning remains fallback only.
--
--  Frame resolution is pure duck typing against the public module registry
--  EllesmereUI._ModuleNS["EllesmereUIUnitFrames"]: ns.frames[unitKey] carries
--  the built frame with .Health and ._textOverlay (the module anchors its
--  own extra texts - threat % - exactly the same way). If EllesmereUI is
--  absent or its internals change, the plugin goes dormant instead of
--  erroring; a 5s sweep heals frame rebuilds (profile switch / reload).
--
--  Blizzard only exposes other players' item level through the inspect
--  pipeline (NotifyInspect -> INSPECT_READY -> C_PaperDollInfo.
--  GetInspectItemLevel; the pre-Midnight global is still honored when
--  present), which is range-limited, combat-locked and server-throttled. Every query is
--  therefore disciplined:
--    * per-GUID cache: a unit is re-queried at most every cacheMin minutes
--      (default 5, /gsp cache 1-30);
--    * single-flight queue: one inspect in flight at a time, next one starts
--      from INSPECT_READY (or a 6s timeout), so the server throttle is never
--      fought;
--    * target swap guard: when the target changes while an inspect is in
--      flight, the pending request is cancelled (a late INSPECT_READY would
--      otherwise read GetInspectItemLevel("target") on the NEW unit and
--      cache it under the OLD guid);
--    * combat defer: CanInspect() is false in combat, so GUIDs are deferred
--      and retried at combat end (through the suite combat queue) / the slow
--      sweep, never forced;
--    * suite synergy: INSPECT_READY carries the inspected GUID, so a foreign
--      completion (EllesmereUI tooltip inspect pacing, M+ run summary,
--      Blizzard UI) is never consumed for our pending unit; and
--      EllesmereUI._inspectCache (every completed inspect, any source) is
--      seeded from when present, so already-inspected players display with
--      NO own query;
--    * zero cost when disabled: no frame events, no OnUpdate, no texts.
--
--  Settings live in own SavedVariables (GearScorePlatesDB), controlled via
--  /gsp:
--    on | off                  master switch
--    cache <1-30>              re-query window per player, minutes
--    pos <right|left|center|outside>
--                              right (default) = inside the right end of the
--                              health bar; left/center = the bar's other
--                              slots; outside = right of the whole frame
--    size <8-24>               font size (default 10)
--    color <white|gold|green|red|blue|cyan|class>
--                              text color; "class" = the target's class color
--    delta <on|off>            show +/- versus your OWN average ilvl instead
--                              of the plain number (auto green/red/white;
--                              overrides the color setting while on)
--    status                    prints everything
--  All display settings re-apply live (no reload). Default: OFF, 5 min cache,
--  pos right, size 10, color white, delta off.
-------------------------------------------------------------------------------

local addonName = ...

local pairs = pairs
local floor = math.floor
local GetTime = GetTime
local UnitExists, UnitGUID, UnitIsPlayer, UnitIsUnit = UnitExists, UnitGUID, UnitIsPlayer, UnitIsUnit

-- Midnight can return a secret GUID for restricted target frames. Secret
-- values must never be used as Lua table keys; they are not inspectable here,
-- so leave that unit dormant until a public GUID is available.
local function PublicGUID(unit)
    local ok, guid = pcall(UnitGUID, unit)
    if not ok or not guid then return nil end
    if issecretvalue and issecretvalue(guid) then return nil end
    return guid
end
local CanInspect, NotifyInspect, ClearInspectPlayer =
    CanInspect, NotifyInspect, ClearInspectPlayer
local UnitTokenFromGUID = _G.UnitTokenFromGUID
local CPDI = C_PaperDollInfo

-------------------------------------------------------------------------------
--  Settings (own SavedVariables, independent of the suite)
-------------------------------------------------------------------------------
local SV_NAME = "GearScorePlatesDB"
GearScorePlatesDB = GearScorePlatesDB or {}

local function SV() return _G[SV_NAME] end

-- Whitelists for the display settings (validated here and in the slash cmd).
local POS_VALID = { right = true, left = true, center = true, outside = true }
local COLORS = {
    white = { 1.00, 1.00, 1.00 },
    gold  = { 1.00, 0.84, 0.00 },
    green = { 0.25, 1.00, 0.25 },
    red   = { 1.00, 0.30, 0.25 },
    blue  = { 0.30, 0.60, 1.00 },
    cyan  = { 0.00, 1.00, 1.00 },
}
-- "class" is the one non-table color key (resolved per target at paint).
local function ColorValid(v) return v == "class" or COLORS[v] ~= nil end

local function SVDefaults()
    local db = SV()
    -- Private-build default: the feature is opt-in and costs nothing while off.
    if db.enabled == nil then db.enabled = false end
    local m = db.cacheMin
    if type(m) ~= "number" or m < 1 or m > 30 then db.cacheMin = 5 end
    if not POS_VALID[db.pos or ""] then db.pos = "right" end
    local sz = db.size
    if type(sz) ~= "number" or sz < 8 or sz > 24 then db.size = 10 end
    if not ColorValid(db.color) then db.color = "white" end
    if db.delta == nil then db.delta = false end
    -- v1.4.3 (user request): default to group/raid members ONLY - strangers
    -- are never inspected and never show a number. nil counts as ON.
    if db.groupOnly == nil then db.groupOnly = true end
end

-- Group/raid gate: with groupOnly (default), resolve the target/focus GUID
-- against the actual party/raid roster. UnitInParty("target") and
-- UnitInRaid("target") are not reliable roster tests for every unit-token
-- path, especially when the target is a group member. GUID matching works
-- for target, focus, party and raid unit tokens alike.
local function GroupOnly()
    return SV().groupOnly ~= false
end

local function GroupOK(unit)
    if not GroupOnly() then return true end
    local guid = PublicGUID(unit)
    if not guid then return false end
    if PublicGUID("player") == guid then return true end
    for i = 1, 4 do
        if PublicGUID("party" .. i) == guid then return true end
    end
    for i = 1, 40 do
        if PublicGUID("raid" .. i) == guid then return true end
    end
    return false
end

local function CacheSeconds()
    local db = SV()
    local m = db and db.cacheMin or 5
    if type(m) ~= "number" or m < 1 then m = 1 end
    if m > 30 then m = 30 end
    return m * 60
end

-------------------------------------------------------------------------------
--  EllesmereUI unit frame resolution (lazy, defensive)
-------------------------------------------------------------------------------
-- Unit frames namespace via the public module registry. ns.frames is
-- published by the module's setup pass and may appear a moment after login;
-- the resolution below is polled by the slow sweep until it lands.
local UFNS
local function ResolveUF()
    if UFNS then return UFNS end
    local E = _G["EllesmereUI"]
    if E and E._ModuleNS then
        UFNS = E._ModuleNS["EllesmereUIUnitFrames"]
    end
    return UFNS
end

local function CompactFrameByScan(unitKey)
    -- Some client builds do not expose a working resolver for every visible
    -- party/raid frame. First inspect the documented pools, then walk the
    -- live compact-frame roots so nested member frames are also found.
    local function Match(candidate)
        if not candidate or type(candidate.IsShown) ~= "function" then return nil end
        local unit = candidate.unit
        if not unit and candidate.GetAttribute then
            local ok, attr = pcall(candidate.GetAttribute, candidate, "unit")
            if ok then unit = attr end
        end
        if unit == unitKey then return candidate end
        return nil
    end
    local pools = {
        _G.CompactPartyFrame and _G.CompactPartyFrame.memberUnitFrames,
        _G.CompactRaidFrameContainer and _G.CompactRaidFrameContainer.memberUnitFrames,
        _G.CompactRaidFrameContainer and _G.CompactRaidFrameContainer.displayedUnitFrames,
    }
    for _, pool in pairs(pools) do
        if type(pool) == "table" then
            for _, candidate in pairs(pool) do
                local found = Match(candidate)
                if found then return found end
            end
        end
    end
    local seen = {}
    local function Walk(root, depth)
        if not root or seen[root] or depth > 4 then return nil end
        seen[root] = true
        local found = Match(root)
        if found then return found end
        if type(root.GetChildren) ~= "function" then return nil end
        local children = { root:GetChildren() }
        for i = 1, #children do
            found = Walk(children[i], depth + 1)
            if found then return found end
        end
        return nil
    end
    local roots = {
        _G.CompactPartyFrame,
        _G.CompactRaidFrameContainer,
    }
    for i = 1, #roots do
        local found = Walk(roots[i], 0)
        if found then return found end
    end
    return nil
end

local function UnitFrame(unitKey)
    -- First use EllesmereUI's public party/raid-frame provider. This is the
    -- stable integration path: EUI resolves its own secure party/raid button
    -- from the assigned unit attribute, without exposing frame internals.
    local E = _G["EllesmereUI"]
    if E and type(E.GetUnitFrame) == "function" then
        local ok, euiFrame = pcall(E.GetUnitFrame, unitKey)
        if ok and euiFrame and type(euiFrame.IsShown) == "function" then
            return euiFrame
        end
    end
    local ns = ResolveUF()
    local frames = ns and ns.frames
    local f = type(frames) == "table" and frames[unitKey]
    if f and type(f) == "table" and type(f.IsShown) == "function" then
        return f
    end
    local getCompact = _G.CompactUnitFrame_GetUnitFrame
    if type(getCompact) == "function" then
        local ok, compact = pcall(getCompact, unitKey)
        if ok and compact and type(compact.IsShown) == "function" then
            return compact
        end
    end
    return CompactFrameByScan(unitKey)
end

-- Suite-wide inspect cache (EllesmereUIBlizzardSkin): every completed inspect,
-- whoever requested it, lands there as guid -> { ilvl = n, time = GetTime() }.
-- Read-only synergy: seeding from it costs no query at all. Internal to the
-- suite today, so it is resolved defensively and may vanish without breakage.
local IC
local function InspectCache()
    if IC then return IC end
    local E = _G["EllesmereUI"]
    if E and E._inspectCache then IC = E._inspectCache end
    return IC
end

-- Midnight secret-value guard: comparisons on secret values error, so filter
-- through issecretvalue (absent on older clients -> plain type check).
local issecret = issecretvalue
local function SafeNumber(v)
    if v == nil then return nil end
    if issecret and issecret(v) then return nil end
    if type(v) ~= "number" then return nil end
    if v <= 0 then return nil end
    return floor(v)
end

-- Midnight API relocation (v1.4.2, field error): the global
-- GetInspectItemLevel is GONE on the 12.x client; the suite reads
-- C_PaperDollInfo.GetInspectItemLevel, which returns the ilvl of whichever
-- player the client currently has inspect-cached - our single-flight queue
-- guarantees that is ours. The read goes through a GUID-derived unit token
-- when available (the suite's pattern: correct even if the cursor/unit
-- already moved on), never raises (pcall), and falls back to the legacy
-- global on older clients. A nil answer just defers the GUID; the pipeline
-- (ClearInspectPlayer + ProcessQueue) always keeps running.
local function InspectIlvl(unit, guid)
    local read = (CPDI and CPDI.GetInspectItemLevel) or GetInspectItemLevel
    if type(read) ~= "function" then return nil end
    local u = unit
    if guid and UnitTokenFromGUID then
        local tok = UnitTokenFromGUID(guid)
        if tok and not (issecret and issecret(tok)) then u = tok end
    end
    if not (u and UnitExists(u)) then return nil end
    local ok, val = pcall(read, u)
    if not ok then return nil end
    return val
end

-------------------------------------------------------------------------------
--  State
-------------------------------------------------------------------------------
local enabled = false
local cache = {}   -- guid -> { ilvl = n, t = GetTime() }
local defer = {}   -- guid -> earliest retry time (combat/inspect refusals)
local queue = {}   -- [1..n] = { unit = u, guid = g }
local queued = {}  -- guid -> true while in queue (O(1) dup check)
local pending = nil -- { unit = u, guid = g, t = GetTime() }
-- unitKey -> { frame = f, fs = FontString, size, r, g, b }: the frame
-- identity is tracked so a module rebuild (profile switch, style reload)
-- re-creates the text on the NEW frame instead of painting a dead one;
-- size/rgb memoize the last applied style so repaints stay free.
local texts = {}
local frame = nil
local sweepAt = 0

-- Adopt a suite-cache entry as our own when it is fresh inside our window:
-- the player was inspected by somebody else (tooltip hover, M+ summary, ...)
-- less than cacheMin minutes ago, so WE must not query again.
local function SeedFromSuite(guid)
    local ic = InspectCache()
    local e = ic and ic[guid]
    if not e then return false end
    local ilvl = SafeNumber(e.ilvl)
    local t = e.time
    if not (ilvl and type(t) == "number") then return false end
    local now = GetTime()
    if t > now or (now - t) >= CacheSeconds() then return false end
    cache[guid] = { ilvl = ilvl, t = t }
    return true
end

-------------------------------------------------------------------------------
--  Unit frame text element
-------------------------------------------------------------------------------
-- Parent: the module's own text overlay when present (its extra texts live
-- there, so draw order above the bars is guaranteed), else the frame itself.
local function GetText(unitKey, uf)
    local db = SV()
    local size = db.size or 10
    local rec = texts[unitKey]
    if rec and rec.frame == uf and rec.fs then
        if rec.size ~= size then
            local f, _, fl = GameFontNormal:GetFont()
            rec.fs:SetFont(f, size, "OUTLINE")
            rec.size = size
        end
        return rec.fs
    end
    if rec and rec.fs then rec.fs:Hide() end
    local parent = uf._textOverlay or uf
    local fs = parent:CreateFontString(nil, "OVERLAY")
    fs:SetJustifyV("MIDDLE")
    local f, _, fl = GameFontNormal:GetFont()
    fs:SetFont(f, size, "OUTLINE")
    fs:SetTextColor(1, 1, 1, 0.95)
    fs:SetShadowOffset(1, -1)
    fs:SetShadowColor(0, 0, 0, 1.0)
    fs:Hide()
    -- Anchor + justify are re-applied by AnchorText on every paint pass, so
    -- bar re-layouts and setting changes heal without bookkeeping here.
    texts[unitKey] = { frame = uf, fs = fs, size = size }
    return fs
end

local function AnchorText(fs, uf)
    local pos = SV().pos or "right"
    local bar = nil
    if uf.Health and type(uf.Health) == "table" and uf.Health.SetPoint then
        bar = uf.Health
    elseif uf.healthBar and uf.healthBar.SetPoint then
        bar = uf.healthBar
    end
    fs:ClearAllPoints()
    if pos == "left" then
        fs:SetJustifyH("LEFT")
        if bar then fs:SetPoint("LEFT", bar, "LEFT", 4, 0)
        else fs:SetPoint("TOPLEFT", uf, "TOPLEFT", 4, -4) end
    elseif pos == "center" then
        fs:SetJustifyH("CENTER")
        if bar then fs:SetPoint("CENTER", bar, "CENTER", 0, 0)
        else fs:SetPoint("CENTER", uf, "CENTER", 0, 0) end
    elseif pos == "outside" then
        -- Right of the whole frame: never collides with in-bar tag texts.
        fs:SetJustifyH("LEFT")
        fs:SetPoint("LEFT", uf, "RIGHT", 6, 0)
    else
        -- right (default): inside the right end of the health bar - the old
        -- plate sketch's position; frames without a bar use their own corner.
        fs:SetJustifyH("RIGHT")
        if bar then fs:SetPoint("RIGHT", bar, "RIGHT", -4, 0)
        else fs:SetPoint("TOPRIGHT", uf, "TOPRIGHT", -4, -4) end
    end
end

-- Own average ilvl for the delta mode. Player-only read, no inspect needed.
-- SECOND return value = EQUIPPED average (total, equipped, pvp) - the same
-- measure GetInspectItemLevel reports for other players, so the +/- delta
-- compares like with like (the suite's own reads do exactly this).
local function OwnIlvl()
    if type(GetAverageItemLevel) ~= "function" then return nil end
    local ok, total, equipped = pcall(GetAverageItemLevel)
    if not ok then return nil end
    return SafeNumber(equipped) or SafeNumber(total)
end

local function ColorRGB(unitKey, e, own, db)
    if db.delta == true and own then
        local d = e.ilvl - own
        if d > 0 then return 0.25, 1.00, 0.25 end
        if d < 0 then return 1.00, 0.30, 0.25 end
        return 1.00, 1.00, 1.00
    end
    local key = db.color or "white"
    if key == "class" then
        local okc, cls = pcall(UnitClassBase, unitKey)
        -- Midnight: a restricted unit can answer with a SECRET class token.
        -- Indexing RAID_CLASS_COLORS with it raises "attempted to index a table
        -- that cannot be indexed with secret keys" (in-game report: target swap
        -- from an action-bar macro while a secret unit was on the frame).
        -- A secret token is never compared and never used as a key: the colour
        -- simply falls through to the plain setting.
        local rc
        if okc and type(cls) == "string" and not (issecret and issecret(cls)) then
            rc = RAID_CLASS_COLORS and RAID_CLASS_COLORS[cls]
        end
        if rc and type(rc.r) == "number" then return rc.r, rc.g, rc.b end
    end
    local c = COLORS[key] or COLORS.white
    return c[1], c[2], c[3]
end

local function ApplyText(unitKey)
    if not enabled then return end
    local uf = UnitFrame(unitKey)
    if not uf then
        local rec = texts[unitKey]
        if rec and rec.fs then rec.fs:Hide() end
        return
    end
    local guid = UnitExists(unitKey) and PublicGUID(unitKey)
    local own = guid and cache[guid]
    if guid and not (own and (GetTime() - own.t) < CacheSeconds()) then
        SeedFromSuite(guid) -- free hit: display without any own query
    end
    local e = guid and cache[guid]
    local rec = texts[unitKey]
    if e and e.ilvl and e.ilvl > 0 and UnitIsPlayer(unitKey)
       and GroupOK(unitKey) then
        local db = SV()
        local ownIlvl = db.delta == true and OwnIlvl() or nil
        local label = tostring(e.ilvl)
        if ownIlvl then
            local d = e.ilvl - ownIlvl
            if d == 0 then label = "0" else label = string.format("%+d", d) end
        end
        local fs = GetText(unitKey, uf)
        AnchorText(fs, uf)
        if fs:GetText() ~= label then fs:SetText(label) end
        local r, g, b = ColorRGB(unitKey, e, ownIlvl, db)
        rec = texts[unitKey]
        if not (rec.r == r and rec.g == g and rec.b == b) then
            fs:SetTextColor(r, g, b, 0.95)
            rec.r, rec.g, rec.b = r, g, b
        end
        fs:Show()
    elseif rec and rec.fs then
        rec.fs:Hide()
    end
end

-------------------------------------------------------------------------------
--  Query pipeline (target/focus plus ordinary party and raid members)
-------------------------------------------------------------------------------
local function IsQueryCandidate(unit, guid)
    if not (unit and guid) then return false end
    if not UnitIsPlayer(unit) or UnitIsUnit(unit, "player") then return false end
    if not GroupOK(unit) then return false end -- strangers: never queried
    local e = cache[guid]
    if e and e.ilvl and e.ilvl > 0 and (GetTime() - e.t) < CacheSeconds() then
        return false -- fresh cache: the 5-minute discipline
    end
    if SeedFromSuite(guid) then return false -- somebody else inspected recently
    end
    return true
end

local function QueueAdd(unit)
    local guid = UnitExists(unit) and PublicGUID(unit)
    if not IsQueryCandidate(unit, guid) then return end
    if queued[guid] then return end
    if pending and pending.guid == guid then return end
    local d = defer[guid]
    if d and GetTime() < d then return end
    queue[#queue + 1] = { unit = unit, guid = guid }
    queued[guid] = true
end

local function QueueDropHead()
    local head = queue[1]
    if head then
        for i = 2, #queue do queue[i - 1] = queue[i] end
        queue[#queue] = nil
        queued[head.guid] = nil
    end
    return head
end

local function ProcessQueue()
    if not enabled or pending then return end
    while #queue > 0 do
        local head = queue[1]
        if not (UnitExists(head.unit) and PublicGUID(head.unit) == head.guid) then
            QueueDropHead() -- unit gone or swapped: discard silently
        elseif not GroupOK(head.unit) then
            QueueDropHead() -- left the group / group-only toggled on: discard
        elseif CanInspect(head.unit) then
            QueueDropHead()
            NotifyInspect(head.unit)
            pending = { unit = head.unit, guid = head.guid, t = GetTime() }
            return
        else
            -- combat / out of range: back off 10s, keep the text from cache,
            -- and ask the suite for a retry the moment combat ends
            QueueDropHead()
            defer[head.guid] = GetTime() + 10
            DeferAfterCombat("GearScorePlatesRetry")
        end
    end
end

local function FinishPending(ok)
    if not pending then return end
    local u, g = pending.unit, pending.guid
    pending = nil
    if ok then
        local ilvl = SafeNumber(InspectIlvl(u, g))
        if ilvl then
            cache[g] = { ilvl = ilvl, t = GetTime() }
            ApplyText(u)
        end
    else
        defer[g] = GetTime() + 10
    end
    ClearInspectPlayer()
    ProcessQueue()
end

-- Visit all ordinary party/raid unit tokens. Target/focus remain supported
-- for the EUI frames; party/raid values are painted on visible compact frames.
local function ForGroupUnits(fn)
    for i = 1, 4 do fn("party" .. i) end
    for i = 1, 40 do fn("raid" .. i) end
end

-- Slow sweep (1x / 5s): re-applies texts, heals frame rebuilds/re-anchors,
-- and retries target plus group-member queries after deferral windows.
local function Sweep()
    ApplyText("target")
    ApplyText("focus")
    ForGroupUnits(function(unit)
        ApplyText(unit)
        if UnitExists(unit) and UnitIsPlayer(unit) then QueueAdd(unit) end
    end)
    if UnitExists("target") and UnitIsPlayer("target")
       and not UnitIsUnit("target", "player") then
        QueueAdd("target")
    end
    ProcessQueue()
end

-------------------------------------------------------------------------------
--  Enable / disable (zero cost when off)
-------------------------------------------------------------------------------
local function OnEvent(self, event, arg1)
    if event == "INSPECT_READY" then
        -- Payload is the inspected unit's GUID. Other inspect sources exist
        -- (suite tooltip pacing, M+ summary, Blizzard UI): consume ONLY the
        -- completion that belongs to our pending request. A crowded-out
        -- request never fires its own event; the 6s stall timeout re-queues.
        if pending then
            if type(arg1) ~= "string" or arg1 == pending.guid then
                FinishPending(true)
            end
        end
    elseif event == "PLAYER_TARGET_CHANGED" then
        -- Target swap guard: a pending inspect belongs to the OLD target;
        -- letting it finish would read the NEW unit's ilvl into the OLD
        -- guid's cache slot. Cancel (the old guid gets the standard 10s
        -- backoff and is re-queued when targeted again).
        if pending and pending.unit == "target" then
            local g = UnitExists("target") and PublicGUID("target")
            if g ~= pending.guid then FinishPending(false) end
        end
        ApplyText("target")
        QueueAdd("target")
        ProcessQueue()
    elseif event == "PLAYER_FOCUS_CHANGED" then
        ApplyText("focus")
    elseif event == "GROUP_ROSTER_UPDATE" then
        Sweep()
    end
end

-- Retry at combat end. The suite's rule is that work deferred past combat goes
-- through its shared queue rather than a raw PLAYER_REGEN_ENABLED listener, so
-- that is what this uses whenever EllesmereUI is there. Standalone the 10s
-- backoff written on a refused inspect is picked up by the running sweep.
local function DeferAfterCombat(key)
    local E = _G["EllesmereUI"]
    local q = E and E.CombatQueue
    if not (q and type(q.Defer) == "function") then return false end
    q.Defer(key, function()
        if not enabled then return end
        defer = {}
        Sweep()
    end)
    return true
end

local function OnUpdate(self, elapsed)
    self._acc = (self._acc or 0) + elapsed
    if self._acc < 1 then return end
    self._acc = 0
    if pending and (GetTime() - pending.t) > 6 then
        FinishPending(false) -- inspect stalled: release the pipeline
    end
    ProcessQueue()
    local now = GetTime()
    if now >= sweepAt then
        sweepAt = now + 5
        Sweep()
    end
end

local function SetEnabled(on)
    on = (on == true)
    if on == enabled then return end
    enabled = on
    if on then
        if not frame then
            frame = CreateFrame("Frame")
            frame:SetScript("OnEvent", OnEvent)
            frame:SetScript("OnUpdate", OnUpdate)
        end
        frame:RegisterEvent("INSPECT_READY")
        frame:RegisterEvent("PLAYER_TARGET_CHANGED")
        frame:RegisterEvent("PLAYER_FOCUS_CHANGED")
        frame:RegisterEvent("GROUP_ROSTER_UPDATE")
        frame:SetScript("OnUpdate", OnUpdate)
        Sweep()
    else
        if frame then
            frame:UnregisterAllEvents()
            frame:SetScript("OnUpdate", nil)
        end
        if pending then ClearInspectPlayer() pending = nil end
        for i = #queue, 1, -1 do queued[queue[i].guid] = nil queue[i] = nil end
        defer = {}
        for _, rec in pairs(texts) do
            if rec.fs then rec.fs:Hide() end
        end
    end
end

-------------------------------------------------------------------------------
--  Chat output + slash commands
-------------------------------------------------------------------------------
local PREFIX = "|cff0cd29fGearScorePlates|r:"
local USAGE = "Usage: /gsp | options | on | off | reset | cache <1-30> | pos <right|left|center|outside> | size <8-24> | color <white|gold|green|red|blue|cyan|class> | delta <on|off> | group <on|off>"

local function Say(fmt, ...)
    DEFAULT_CHAT_FRAME:AddMessage(PREFIX .. " " .. (fmt or ""):format(...))
end

-- Live re-apply after a display-setting change (no reload needed).
local function Repaint()
    ApplyText("target")
    ApplyText("focus")
    ForGroupUnits(function(unit) ApplyText(unit) end)
end

-- Reset used by the options page's Reset button, /gsp reset and the module's
-- own Reset in the panel footer. Declared before the slash commands, which
-- call it.
local function ResetSettings()
    local db = SV()
    db.enabled = false
    db.cacheMin = 5
    db.pos = "right"
    db.size = 10
    db.color = "white"
    db.delta = false
    db.groupOnly = true
    if enabled then SetEnabled(false) end
end

SLASH_GEARSCOREPLATES1 = "/gsp"
SLASH_GEARSCOREPLATES2 = "/gearscoreplates"
SlashCmdList["GEARSCOREPLATES"] = function(msg)
    local db = SV()
    msg = (msg or ""):trim():lower()
    local cmd, rest = msg:match("^(%S*)%s*(.*)$")
    if cmd == "" then
        -- Bare /gsp opens the options page when the suite is there; the status
        -- line stays the answer everywhere else.
        if GearScorePlates.OpenOptions() then return end
        cmd = "status"
    end
    if cmd == "options" or cmd == "config" then
        if not GearScorePlates.OpenOptions() then
            Say("EllesmereUI options are not available - use the chat commands below.")
        end
        return
    end
    if cmd == "status" then
        Say("%s, cache %d min, pos %s, size %d, color %s, delta %s, group-only %s, UnitFrames: %s",
            db.enabled == true and "ON" or "OFF", db.cacheMin or 5,
            db.pos or "right", db.size or 10, db.color or "white",
            db.delta == true and "ON" or "OFF",
            db.groupOnly ~= false and "ON" or "OFF",
            UnitFrame("target") and "EllesmereUI (target/focus)"
                or "noch nicht aufgeloest (Plugin schlaeft)")
        Say(USAGE)
    elseif cmd == "on" or cmd == "enable" then
        db.enabled = true
        SetEnabled(true)
        Say("enabled - ilvl on target/focus and visible party/raid frames.")
    elseif cmd == "off" or cmd == "disable" then
        db.enabled = false
        SetEnabled(false)
        Say("disabled.")
    elseif cmd == "reset" then
        ResetSettings()
        Say("settings reset to defaults (display off).")
    elseif cmd == "cache" then
        local n = tonumber(rest)
        if n then
            n = floor(n)
            if n < 1 then n = 1 elseif n > 30 then n = 30 end
            db.cacheMin = n
            Say("cache set to %d min.", n)
        else
            Say("cache is %d min. Set with /gsp cache <1-30>.", db.cacheMin or 5)
        end
    elseif cmd == "pos" or cmd == "position" then
        if POS_VALID[rest] then
            db.pos = rest
            Repaint()
            Say("position: %s (live).", rest)
        else
            Say("position is '%s'. Usage: /gsp pos <right|left|center|outside>",
                db.pos or "right")
        end
    elseif cmd == "size" then
        local n = tonumber(rest)
        if n then
            n = floor(n)
            if n < 8 then n = 8 elseif n > 24 then n = 24 end
            db.size = n
            Repaint()
            Say("font size: %d (live).", n)
        else
            Say("font size is %d. Set with /gsp size <8-24>.", db.size or 10)
        end
    elseif cmd == "color" then
        if ColorValid(rest) then
            db.color = rest
            Repaint()
            Say("color: %s (live).", rest)
        else
            Say("color is '%s'. Usage: /gsp color <white|gold|green|red|blue|cyan|class>",
                db.color or "white")
        end
    elseif cmd == "delta" or cmd == "diff" then
        if rest == "on" or rest == "off" then
            db.delta = (rest == "on")
            Repaint()
            if db.delta then
                Say("delta ON: shows +/- versus your own average ilvl (green above, red below, white equal).")
            else
                Say("delta OFF: shows the plain ilvl number.")
            end
        else
            Say("delta is %s. Usage: /gsp delta <on|off>",
                db.delta == true and "ON" or "OFF")
        end
    elseif cmd == "group" or cmd == "grouponly" then
        if rest == "on" or rest == "off" then
            db.groupOnly = (rest == "on")
            Repaint()
            if db.groupOnly then
                Say("group-only ON: ilvl shows and queries only for group & raid members.")
            else
                Say("group-only OFF: any player target is queried and shown.")
            end
        else
            Say("group-only is %s. Usage: /gsp group <on|off>",
                db.groupOnly ~= false and "ON" or "OFF")
        end
    else
        Say("unknown command. " .. USAGE)
    end
end

-------------------------------------------------------------------------------
--  Public API (surface for the EllesmereUI options integration)
-------------------------------------------------------------------------------
-- The personal EllesmereUI build shows a "GearScore" block on the Unit
-- Frames > Main Frames options page: it reads/writes GearScorePlatesDB
-- directly and calls into this table. Everything the integration needs,
-- nothing more; without it (stock suite) the slash commands still work.
-- Key sets MUST match POS_VALID / COLORS above (validated there).
GearScorePlates = {
    version = "1.6.0",
    Repaint = Repaint,
    -- Master switch: writes the SV flag AND flips the runtime state, so the
    -- options page and /gsp on|off can never disagree.
    SetEnabled = function(on)
        SV().enabled = (on == true)
        SetEnabled(on == true)
    end,
    POS_VALUES = {
        right   = "Inside Right",
        left    = "Inside Left",
        center  = "Inside Center",
        outside = "Outside Right",
    },
    POS_ORDER = { "right", "left", "center", "outside" },
    COLOR_VALUES = {
        white = "White",
        gold  = "Gold",
        green = "Green",
        red   = "Red",
        blue  = "Blue",
        cyan  = "Cyan",
        class = "Class Color",
    },
    COLOR_ORDER = { "white", "gold", "green", "red", "blue", "cyan", "class" },
}

-------------------------------------------------------------------------------
--  EllesmereUI options page (the suite's public plugin API)
--  The addon plugs INTO the suite instead of patching its files: it registers
--  its own sidebar section, EUI draws the page with the same widget factory its
--  own pages use, and every callback runs protected by EUI. Without
--  EllesmereUI -- or on a suite older than the plugin API -- none of this runs
--  and /gsp stays the only way in.
--  Contract: buildPage must stay free of side effects while
--  EllesmereUI.IsSearchPrebuild() is true (the global search pre-builds every
--  page with a stub widget factory), and no EUI function may be hooked.
-------------------------------------------------------------------------------
local function BuildOptionsPage(_, parent, yOffset)
    local W = EllesmereUI.Widgets
    local y = yOffset
    local _, h
    local function DB() return SV() end
    local function Off() return DB().enabled ~= true end
    local OFF_TIP = "Turn the GearScore display on first."
    -- Repaint live; `rebuild` re-runs the page too, so the gated rows follow the
    -- master switch. Never during the search's pre-build pass.
    local function Live(rebuild)
        if EllesmereUI.IsSearchPrebuild and EllesmereUI.IsSearchPrebuild() then return end
        Repaint()
        if rebuild then EllesmereUI:RefreshPage(true) end
    end

    _, h = W:SectionHeader(parent, "GEARSCORE", y); y = y - h
    _, h = W:DualRow(parent, y,
        { type = "toggle", text = "Show GearScore / Item Level",
          tooltip = "Shows the inspected average item level on the suite's target, focus and visible party/raid frames.",
          getValue = function() return DB().enabled == true end,
          setValue = function(v)
              DB().enabled = (v == true)
              SetEnabled(v == true)
              Live(true)
          end },
        { type = "dropdown", text = "Position", values = GearScorePlates.POS_VALUES,
          order = GearScorePlates.POS_ORDER,
          disabled = Off, disabledTooltip = OFF_TIP,
          getValue = function() return DB().pos or "right" end,
          setValue = function(v) DB().pos = v; Live() end }); y = y - h
    _, h = W:DualRow(parent, y,
        { type = "dropdown", text = "Color", values = GearScorePlates.COLOR_VALUES,
          order = GearScorePlates.COLOR_ORDER,
          disabled = Off, disabledTooltip = OFF_TIP,
          getValue = function() return DB().color or "white" end,
          setValue = function(v) DB().color = v; Live() end },
        { type = "toggle", text = "Delta (versus You)",
          tooltip = "Shows the difference to your own average item level instead of the plain number: green above, red below, white for equal.",
          disabled = Off, disabledTooltip = OFF_TIP,
          getValue = function() return DB().delta == true end,
          setValue = function(v) DB().delta = (v == true); Live() end }); y = y - h

    _, h = W:SectionHeader(parent, "QUERYING", y); y = y - h
    _, h = W:DualRow(parent, y,
        { type = "toggle", text = "Only Group & Raid Members",
          tooltip = "On: only group and raid members are inspected. Off: any player target is inspected as well.",
          disabled = Off, disabledTooltip = OFF_TIP,
          getValue = function() return DB().groupOnly ~= false end,
          setValue = function(v) DB().groupOnly = (v == true); Live() end },
        { type = "slider", text = "Text Size", min = 8, max = 24, step = 1,
          disabled = Off, disabledTooltip = OFF_TIP,
          getValue = function() return DB().size or 10 end,
          setValue = function(v) DB().size = v; Live() end }); y = y - h
    _, h = W:DualRow(parent, y,
        { type = "slider", text = "Re-Inspect Cache (min)", min = 1, max = 30, step = 1,
          tooltip = "How long an inspected item level is reused before that player is inspected again.",
          getValue = function() return DB().cacheMin or 5 end,
          setValue = function(v) DB().cacheMin = v end },
        EllesmereUI.BlankRowCfg()); y = y - h

    _, h = W:Spacer(parent, y, 8); y = y - h
    _, h = W:WideDualButton(parent, "Re-Inspect Now", "Reset Settings", y,
        function()
            if not enabled then SetEnabled(true) end
            defer = {}
            Sweep()
            Say("re-inspecting group and raid members.")
        end,
        function()
            ResetSettings()
            Say("settings reset to defaults (display off).")
            if EllesmereUI:GetActiveModule() == EllesmereUI.GetPluginModuleKey("GearScorePlates", "General") then
                EllesmereUI:RefreshPage(true)
            end
        end); y = y - h

    return math.abs(y)
end

-- Registration. The id is the addon folder name, as the plugin guide asks;
-- `position = "bottom"` keeps the section below the suite's own.
GearScorePlates.PLUGIN_ID = "GearScorePlates"
GearScorePlates.OPTIONS_PAGE = "Settings"

function GearScorePlates.RegisterOptions()
    if not (EllesmereUI and EllesmereUI.RegisterPlugin) then return false end
    if EllesmereUI.IsPluginRegistered and EllesmereUI.IsPluginRegistered(GearScorePlates.PLUGIN_ID) then
        return true
    end
    return EllesmereUI.RegisterPlugin(GearScorePlates.PLUGIN_ID, {
        label = "GearScore",
        position = "bottom",
        modules = { {
            key = "General",
            title = "GearScore",
            description = "Inspected average item level on the EllesmereUI unit frames.",
            pages = { GearScorePlates.OPTIONS_PAGE },
            buildPage = BuildOptionsPage,
            onReset = ResetSettings,
        } },
    }) == true
end

-- Opens the suite's panel on our page. False when EUI (or its plugin API) is
-- not there, so callers can fall back to the chat commands.
function GearScorePlates.OpenOptions()
    if not (EllesmereUI and EllesmereUI.OpenPlugin) then return false end
    return EllesmereUI.OpenPlugin(GearScorePlates.PLUGIN_ID) == true
end

GearScorePlates.RegisterOptions()

-------------------------------------------------------------------------------
--  Init: apply SavedVariables defaults, then start if enabled
-------------------------------------------------------------------------------
local init = CreateFrame("Frame")
init:RegisterEvent("ADDON_LOADED")
init:RegisterEvent("PLAYER_LOGIN")
init:SetScript("OnEvent", function(self, event, arg1)
    if event == "ADDON_LOADED" then
        if arg1 == addonName then SVDefaults() end
        return
    end
    -- PLAYER_LOGIN: one-shot gate, then the frame is torn down.
    -- No hard dependency on the suite: resolution is lazy and polled, and a
    -- missing/renamed internals set just leaves the plugin dormant.
    self:UnregisterAllEvents()
    self:SetScript("OnEvent", nil)
    SVDefaults()
    local db = SV()
    if db.enabled == true then
        SetEnabled(true)
    end
end)
