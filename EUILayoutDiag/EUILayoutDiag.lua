if EUI_CLIENT_BLOCKED then return end -- pre-12.1 client failsafe (EllesmereUI_ClientGate.lua)
-------------------------------------------------------------------------------
--  EUILayoutDiag
--  Read-only diagnostic helper for EllesmereUI profile / spec / layout state.
--  Prints what EllesmereUI has stored for THIS character so a login problem
--  ("tank layout on my Balance druid") can be traced to a concrete cause.
--
--  Writes nothing, changes nothing, safe to remove at any time.
--  Commands:  /elayout            -- short summary
--             /elayout full       -- adds group + layout layer detail
--             /elayout spec       -- spec-profile resolution only
-------------------------------------------------------------------------------
local addonName = ...
local PREFIX = "|cff0cd29fEUI-Diag|r "

local function out(msg)
    if DEFAULT_CHAT_FRAME then DEFAULT_CHAT_FRAME:AddMessage(PREFIX .. tostring(msg)) end
end

local function SpecName(id)
    if type(id) ~= "number" then return tostring(id) end
    -- GetSpecializationInfoByID is native on retail and absent on Forever: call it
    -- only behind a presence test and fall through to the raw id.
    if type(GetSpecializationInfoByID) == "function" then
        local ok, _, name = pcall(GetSpecializationInfoByID, id)
        if ok and type(name) == "string" then return name end
    end
    return "specID " .. id
end

local function count(t)
    local n = 0
    if type(t) == "table" then for _ in pairs(t) do n = n + 1 end end
    return n
end

local function CharKey()
    return (UnitName("player") or "?") .. " - " .. (GetRealmName() or "?")
end

local function LiveSpecID()
    if not C_SpecializationInfo or not C_SpecializationInfo.GetSpecialization then return nil end
    local idx = C_SpecializationInfo.GetSpecialization() or 0
    if idx <= 0 then return nil end
    return C_SpecializationInfo.GetSpecializationInfo(idx)
end

local function GetDB()
    return _G.EllesmereUIDB
end

local function GetActiveProfileData()
    local db = GetDB()
    if not db or not db.profiles then return nil, nil end
    local name = db.activeProfile or "Default"
    return db.profiles[name], name
end

-------------------------------------------------------------------------------
--  Reports
-------------------------------------------------------------------------------
local function ReportSpec()
    local db = GetDB()
    if not db then out("EllesmereUIDB fehlt -- EllesmereUI ist nicht geladen."); return end

    local specID = LiveSpecID()
    local key = CharKey()
    out("Charakter: " .. key .. " | Klasse: " .. tostring(UnitClass("player")))
    out("Aktive Spec (live): " .. (specID and (SpecName(specID) .. " [ID " .. specID .. "]") or "nicht verfuegbar"))

    local cached = db.lastSpecByChar and db.lastSpecByChar[key]
    if cached then
        local mark = (specID and cached == specID) and "|cff40c040passt|r" or "|cffff4040WEICHT AB|r"
        out("Zuletzt gespeicherte Spec (lastSpecByChar): " .. SpecName(cached) .. " [ID " .. cached .. "] -- " .. mark)
    else
        out("lastSpecByChar: kein Eintrag fuer diesen Charakter")
    end

    local map = db.specProfiles
    if type(map) ~= "table" or not next(map) then
        out("specProfiles: keine Spec-Zuordnung vorhanden (kein Profil ist einer Spec zugewiesen)")
    else
        out("specProfiles (kontoweit, nicht pro Charakter):")
        local ids = {}
        for id in pairs(map) do if type(id) == "number" then ids[#ids + 1] = id end end
        table.sort(ids)
        for _, id in ipairs(ids) do
            local mark = (specID and id == specID) and "  <== gilt fuer diese Spec" or ""
            out("   " .. SpecName(id) .. " [ID " .. id .. "] -> Profil \"" .. tostring(map[id]) .. "\"" .. mark)
        end
    end

    local _, activeName = GetActiveProfileData()
    out("Aktives Profil: \"" .. tostring(activeName) .. "\"")

    -- Does the current spec force a profile (i.e. is manual switching blocked)?
    local forced = specID and map and map[specID]
    if forced then
        out("|cffffd200Hinweis:|r Diese Spec hat ein zugewiesenes Profil. EllesmereUI laesst dann keinen manuellen Profilwechsel zu und laedt beim Login genau dieses Profil.")
    end
end

local function ReportLayout()
    local prof, name = GetActiveProfileData()
    if not prof then out("Kein Profil aktiv."); return end
    out("Profil \"" .. tostring(name) .. "\": Layout-Speicher")

    local legacy = prof.unlockLayout
    out("   unlockLayout (Basis-Snapshot im Profil): " .. (type(legacy) == "table" and (count(legacy.anchors) .. " Anker") or "nicht vorhanden"))

    local s = prof.specUnlockOverrides
    if type(s) ~= "table" then
        out("   specUnlockOverrides: keine Spec-Layout-Ebenen")
    else
        out("   specUnlockOverrides: baselineLayout =" .. (type(s.baselineLayout) == "table" and (count(s.baselineLayout.anchors) .. " Anker") or "nein")
            .. " | layouts-Ebenen = " .. count(s.layouts) .. " | live aktiv = " .. tostring(s.active))
        for gid, layer in pairs(s.layouts or {}) do
            out("      Ebene Gruppe-ID " .. tostring(gid) .. ": " .. (type(layer) == "table" and (count(layer.anchors) .. " Anker") or "leer"))
        end
    end

    local c = prof.condUnlockOverrides
    if type(c) == "table" and count(c.layouts) > 0 then
        out("   condUnlockOverrides: " .. count(c.layouts) .. " Bedingungs-Ebenen (Dungeon/Raid/Arena/BG/Keybind/Dark Mode)")
        for gid in pairs(c.layouts) do out("      Ebene Bedingungs-Gruppe-ID " .. tostring(gid)) end
    else
        out("   condUnlockOverrides: keine Layout-Ebenen")
    end
end

local function ReportGroups()
    local prof = GetActiveProfileData()
    if not prof then return end
    local specID = LiveSpecID()

    local groups = prof.specOverrideGroups
    if type(groups) ~= "table" or #groups == 0 then
        out("Spec-Gruppen: keine")
    else
        out("Spec-Gruppen (pro Profil):")
        for _, g in ipairs(groups) do
            local member, names = false, {}
            for _, id in ipairs(g.specs or {}) do
                names[#names + 1] = SpecName(id) .. "[" .. tostring(id) .. "]"
                if specID and id == specID then member = true end
            end
            local s = prof.specUnlockOverrides
            local hasLayer = type(s) == "table" and type(s.layouts) == "table" and s.layouts[g.id] ~= nil
            out("   \"" .. tostring(g.name) .. "\" (ID " .. tostring(g.id) .. "): " .. (#names > 0 and table.concat(names, ", ") or "keine Specs")
                .. " | eigenes Layout: " .. (hasLayer and "ja" or "nein")
                .. (member and "  <== enthaelt DEINE Spec" or ""))
        end
    end

    local cg = prof.condOverrideGroups
    if type(cg) == "table" and #cg > 0 then
        out("Bedingungs-Gruppen (pro Profil):")
        for _, g in ipairs(cg) do
            local names = {}
            for id in pairs(g.conds or {}) do names[#names + 1] = tostring(id) end
            table.sort(names)
            local c = prof.condUnlockOverrides
            local hasLayer = type(c) == "table" and type(c.layouts) == "table" and c.layouts[g.id] ~= nil
            out("   \"" .. tostring(g.name) .. "\" (ID " .. tostring(g.id) .. "): " .. (#names > 0 and table.concat(names, ", ") or "keine Bedingungen")
                .. " | eigenes Layout: " .. (hasLayer and "ja" or "nein"))
        end
    end
end

local function ReportProfiles()
    local db = GetDB()
    if not db or not db.profiles then return end
    local assigned = {}
    for _, pName in pairs(db.specProfiles or {}) do assigned[pName] = true end
    local order = db.profileOrder or {}
    out("Profile: " .. #order .. " | aktives: \"" .. tostring(db.activeProfile) .. "\"")
    for _, n in ipairs(order) do
        out("   \"" .. tostring(n) .. "\"" .. (assigned[n] and "  (einer Spec zugewiesen)" or "") .. (n == db.activeProfile and "  (aktiv)" or ""))
    end
    out("lastNonSpecProfile: " .. tostring(db.lastNonSpecProfile))
end

-------------------------------------------------------------------------------
--  Slash command
-------------------------------------------------------------------------------
SLASH_EUILAYOUTDIAG1 = "/elayout"
SLASH_EUILAYOUTDIAG2 = "/layoutdiag"
SlashCmdList["EUILAYOUTDIAG"] = function(msg)
    msg = tostring(msg or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
    out("---- Diagnose " .. date("%Y-%m-%d %H:%M") .. " ----")
    if msg == "spec" then
        ReportSpec()
    elseif msg == "full" then
        ReportSpec(); ReportLayout(); ReportGroups(); ReportProfiles()
    else
        ReportSpec(); ReportLayout()
    end
    out("---- Ende. Fuer alles: /elayout full ----")
end

local f = CreateFrame("Frame")
f:RegisterEvent("PLAYER_LOGIN")
f:SetScript("OnEvent", function()
    out("geladen -- /elayout fuer die Profil- und Layout-Diagnose (/elayout full fuer Details).")
end)
