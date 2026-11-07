 -------------------------------------------------------------------------------
--  PetNickname
--  Shows a nickname of your choice for your own pet, client side only: on
--  every unit frame that shows the pet (Blizzard's default frames, EllesmereUI
--  and other unit frame addons), on its nameplate and in its tooltip. The
--  floating name above the pet in the 3D world is drawn by the engine and
--  cannot be changed by addons.
--
--  How it works: unit frames are found by their unit (the `unit` attribute or
--  field). Every font string inside such a frame gets a post-hook on SetText
--  and SetFormattedText; when the frame shows your pet, the pet's real name in
--  that text is swapped for the nickname. No frame layout is touched.
--
--  /petname <name>   give your current pet a nickname
--  /petname reset    remove the nickname of your current pet
--  /petname list     list all nicknames on this character
--
--  Saved per character, keyed by the pet's real name, so every demon keeps
--  its own nickname.
-------------------------------------------------------------------------------
local ADDON = ...

local PREFIX = "|cff9482c9PetNickname|r: "
-- Frames scanned on every target or focus change. Everything else is found
-- by the full scan (FullScan) on login, pet summon and /petname.
local KNOWN_FRAMES = {
    "PetFrame", "TargetFrame", "TargetFrameToT", "FocusFrame", "FocusFrameToT",
    "EllesmereUIUnitFrames_Pet",
    "EllesmereUIUnitFrames_Target",
    "EllesmereUIUnitFrames_TargetTarget",
    "EllesmereUIUnitFrames_Focus",
    "EllesmereUIUnitFrames_FocusTarget",
}

local DB
local hooked = setmetatable({}, { __mode = "k" }) -- FontString -> function() return unit end
local busy = false

local function Print(msg) print(PREFIX .. msg) end

local function IsSecret(v)
    return issecretvalue ~= nil and issecretvalue(v) == true
end

local function IsMyPet(unit)
    if not unit or IsSecret(unit) or not UnitExists("pet") then return false end
    local ok, res = pcall(UnitIsUnit, unit, "pet")
    if not ok or IsSecret(res) then return false end
    return res == true
end

local function PetRealName()
    if not UnitExists("pet") then return nil end
    local name = UnitName("pet")
    if not name or IsSecret(name) or name == "" or name == UNKNOWNOBJECT then return nil end
    return name
end

local function NickFor(real)
    return real and DB and DB.names[real] or nil
end

-- Replaces every plain-text occurrence of `from` in `text`. nil if nothing matched.
local function ReplacePlain(text, from, to)
    local s, e = string.find(text, from, 1, true)
    if not s then return nil end
    local out, pos = {}, 1
    while s do
        out[#out + 1] = string.sub(text, pos, s - 1)
        out[#out + 1] = to
        pos = e + 1
        s, e = string.find(text, from, pos, true)
    end
    out[#out + 1] = string.sub(text, pos)
    return table.concat(out)
end

local function SetTextSafe(fs, text)
    busy = true
    pcall(fs.SetText, fs, text)
    busy = false
end

-- Runs after every SetText/SetFormattedText on a watched font string.
local function Fix(fs)
    if busy then return end
    local getUnit = hooked[fs]
    if not getUnit or not IsMyPet(getUnit()) then return end
    local real = PetRealName()
    local nick = NickFor(real)
    if not nick then return end
    local text = fs:GetText()
    if not text or IsSecret(text) then return end
    if string.find(text, nick, 1, true) then return end
    local new = ReplacePlain(text, real, nick)
    if new and new ~= text then SetTextSafe(fs, new) end
end

local function HookFontString(fs, getUnit)
    if hooked[fs] then
        hooked[fs] = getUnit
        return
    end
    hooked[fs] = getUnit
    hooksecurefunc(fs, "SetText", Fix)
    hooksecurefunc(fs, "SetFormattedText", Fix)
    Fix(fs)
end

-- The unit a frame shows, or nil if it is no unit frame. EllesmereUI keeps
-- its live token in _euiUnit, Blizzard and most addons in .unit, secure unit
-- buttons in the "unit" attribute.
local function FrameUnit(f)
    if f.IsForbidden and f:IsForbidden() then return nil end
    local u = rawget(f, "_euiUnit")
    if type(u) ~= "string" then u = rawget(f, "unit") end
    if type(u) ~= "string" and f.GetAttribute then
        local ok, a = pcall(f.GetAttribute, f, "unit")
        if ok and type(a) == "string" then u = a end
    end
    if type(u) == "string" and not IsSecret(u) and u ~= "" then return u end
    return nil
end

local function UnitGetter(f)
    return function() return FrameUnit(f) end
end

-- Hooks all font strings below `frame`. A child that is a unit frame of its
-- own (Target of Target inside the Target frame) brings its own unit.
local function Collect(frame, getUnit, depth)
    depth = depth or 0
    if not frame or depth > 8 then return end
    if frame.IsForbidden and frame:IsForbidden() then return end
    if FrameUnit(frame) then getUnit = UnitGetter(frame) end
    if not getUnit then return end
    for _, region in ipairs({ frame:GetRegions() }) do
        if region.GetObjectType and region:GetObjectType() == "FontString" then
            HookFontString(region, getUnit)
        end
    end
    for _, child in ipairs({ frame:GetChildren() }) do
        Collect(child, getUnit, depth + 1)
    end
end

local function ScanKnownFrames()
    for _, name in ipairs(KNOWN_FRAMES) do
        local f = _G[name]
        if type(f) == "table" and f.GetObjectType then Collect(f) end
    end
end

-- Only frames whose unit can ever be your pet: pet frames, target, focus,
-- their targets and mouseover. Player, party, raid, boss and arena frames are
-- left alone, so as few Blizzard frames as possible are touched.
local function RelevantUnit(u)
    u = string.lower(u)
    return string.find(u, "pet", 1, true) or string.find(u, "target", 1, true)
        or string.find(u, "focus", 1, true) or u == "mouseover"
end

-- Walks every frame in the UI and hooks the unit frames that can show your
-- pet. Covers any unit frame addon without knowing its frame names.
local function FullScan()
    local f = EnumerateFrames()
    while f do
        local u = FrameUnit(f)
        if u and RelevantUnit(u) then Collect(f) end
        f = EnumerateFrames(f)
    end
end

local function ScanNameplate(unit)
    if not IsMyPet(unit) or not C_NamePlate or not C_NamePlate.GetNamePlateForUnit then return end
    local ok, plate = pcall(C_NamePlate.GetNamePlateForUnit, unit)
    if not ok or not plate then return end
    Collect(plate, function() return plate.namePlateUnitToken end)
end

-- Re-applies the nickname on every watched font string that shows the pet,
-- optionally turning an old nickname back into the real name first.
local function RefreshAll(oldNick)
    local real = PetRealName()
    for fs, getUnit in pairs(hooked) do
        if IsMyPet(getUnit()) then
            if oldNick and real then
                local text = fs:GetText()
                if text and not IsSecret(text) then
                    local back = ReplacePlain(text, oldNick, real)
                    if back then SetTextSafe(fs, back) end
                end
            end
            Fix(fs)
        end
    end
end

local function HookTooltip()
    if not (TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall
            and Enum and Enum.TooltipDataType) then return end
    TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Unit, function(tt)
        if not tt or not tt.GetUnit or not tt.GetName or not tt:GetName() then return end
        local ok, _, unit = pcall(tt.GetUnit, tt)
        if not ok or not IsMyPet(unit) then return end
        local real = PetRealName()
        local nick = NickFor(real)
        if not nick then return end
        local line = _G[tt:GetName() .. "TextLeft1"]
        local text = line and line:GetText()
        if not text or IsSecret(text) then return end
        local new = ReplacePlain(text, real, nick)
        if new then line:SetText(new) end
    end)
end

-------------------------------------------------------------------------------
--  Slash command
-------------------------------------------------------------------------------
local function Trim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end

SLASH_PETNICKNAME1 = "/petname"
SlashCmdList.PETNICKNAME = function(msg)
    msg = Trim(msg or "")
    local lower = string.lower(msg)
    local real = PetRealName()

    if lower == "list" then
        local any = false
        for r, n in pairs(DB.names) do
            Print(r .. " is called " .. n)
            any = true
        end
        if not any then Print("No nicknames set yet.") end
        return
    end

    if not real then
        Print("No pet active. Summon one first, then type /petname <name>.")
        return
    end

    if msg == "" then
        local nick = NickFor(real)
        if nick then
            Print(real .. " is called " .. nick .. ". Remove it with /petname reset")
        else
            Print("Usage: /petname <name>, /petname reset, /petname list")
        end
        return
    end

    if lower == "reset" then
        local old = NickFor(real)
        if not old then
            Print(real .. " has no nickname.")
            return
        end
        DB.names[real] = nil
        RefreshAll(old)
        Print(real .. " is called " .. real .. " again.")
        return
    end

    local old = NickFor(real)
    DB.names[real] = msg
    FullScan()
    RefreshAll(old)
    Print(real .. " is now called " .. msg .. ".")
end

-------------------------------------------------------------------------------
--  Events
-------------------------------------------------------------------------------
local ev = CreateFrame("Frame")
ev:RegisterEvent("ADDON_LOADED")
ev:RegisterEvent("PLAYER_ENTERING_WORLD")
ev:RegisterEvent("UNIT_PET")
ev:RegisterEvent("PLAYER_TARGET_CHANGED")
ev:RegisterEvent("PLAYER_FOCUS_CHANGED")
ev:RegisterEvent("NAME_PLATE_UNIT_ADDED")
ev:SetScript("OnEvent", function(_, event, arg1)
    if event == "ADDON_LOADED" then
        if arg1 == ADDON then
            PetNicknameDB = PetNicknameDB or {}
            PetNicknameDB.names = PetNicknameDB.names or {}
            DB = PetNicknameDB
            HookTooltip()
        end
        return
    end
    if not DB then return end
    if event == "NAME_PLATE_UNIT_ADDED" then
        ScanNameplate(arg1)
    elseif event == "UNIT_PET" then
        if arg1 == "player" then
            FullScan()
            C_Timer.After(0.5, function() RefreshAll() end)
        end
    elseif event == "PLAYER_ENTERING_WORLD" then
        C_Timer.After(1, function()
            FullScan()
            RefreshAll()
        end)
    else
        ScanKnownFrames()
    end
end)
