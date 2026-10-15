if EUI_CLIENT_BLOCKED then return end
if not EllesmereUI or not EllesmereUI.RegisterModule then return end

local function DB()
    local d = _G._EUI_AutoToast_DB and _G._EUI_AutoToast_DB()
    return d or {}
end

local function BuildPage(_, parent, yOffset)
    local W = EllesmereUI.Widgets
    local y = yOffset
    local _, h
    local d = DB()
    _, h = W:SectionHeader(parent, "SOCIAL QUEUE AUTOTOAST", y); y = y - h
    _, h = W:DualRow(parent, y,
        { type="toggle", text="Enable AutoToast", tooltip="Shows a notification when a guild member or friend joins a Social Queue.", getValue=function() return DB().enabled == true end, setValue=function(v) DB().enabled = v == true; EllesmereUI:RefreshPage(true) end },
        { type="toggle", text="Guild Members", tooltip="Include guild members.", disabled=function() return DB().enabled ~= true end, getValue=function() return DB().guild ~= false end, setValue=function(v) DB().guild = v == true end }); y = y - h
    _, h = W:DualRow(parent, y,
        { type="toggle", text="Friends", tooltip="Include friends.", disabled=function() return DB().enabled ~= true end, getValue=function() return DB().friends ~= false end, setValue=function(v) DB().friends = v == true end },
        { type="toggle", text="Show Toast", tooltip="Show an EllesmereUI popup.", disabled=function() return DB().enabled ~= true end, getValue=function() return DB().toast ~= false end, setValue=function(v) DB().toast = v == true end }); y = y - h
    _, h = W:DualRow(parent, y,
        { type="toggle", text="Play Sound", tooltip="Play a short notification sound.", disabled=function() return DB().enabled ~= true end, getValue=function() return DB().sound ~= false end, setValue=function(v) DB().sound = v == true end },
        { type="toggle", text="Chat Message", tooltip="Also print the notification in the EllesmereUI chat output.", disabled=function() return DB().enabled ~= true end, getValue=function() return DB().chat == true end, setValue=function(v) DB().chat = v == true end }); y = y - h
    _, h = W:DualRow(parent, y,
        { type="slider", text="Repeat Cooldown (seconds)", min=30, max=900, step=30, disabled=function() return DB().enabled ~= true end, getValue=function() return DB().cooldown or 300 end, setValue=function(v) DB().cooldown = v end },
        EllesmereUI.BlankRowCfg()); y = y - h
    return math.abs(y)
end

EllesmereUI:RegisterModule("EllesmereUIAutoToast", {
    title="Social Queue AutoToast",
    description="Optional notifications when guild members or friends join a Social Queue.",
    pages={"Chat"},
    buildPage=BuildPage,
    onReset=function()
        local d=DB(); d.enabled=false; d.guild=true; d.friends=true; d.toast=true; d.sound=true; d.chat=false; d.cooldown=300
        EllesmereUI:InvalidatePageCache()
    end,
})
