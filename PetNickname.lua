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
--  Companions (collection pets) work the same way. Your own summoned companion
--  is recognised by its owner (UnitIsOwnerOrControllerOfUnit) and its name, so
--  other players' companions of the same kind keep their names.
--
--  /petname <name>   give your current pet a nickname (your targeted
--                    companion, else your combat pet, else your companion)
--  /petname reset    remove that nickname
--  /petname list     list all nicknames on this character
--  /petname check    debug: what PetNickname sees on your target
--
--  Saved per character, keyed by the real name (combat pets in names,
--  companions in companions), so every demon and every critter keeps its own.
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

-- The summoned companion's name, cached: Fix runs on every text change of a
-- watched frame (health text too), so the journal is asked only on events.
local companionName

local function UpdateCompanion()
    companionName = nil
    if not (C_PetJournal and C_PetJournal.GetSummonedPetGUID and C_PetJournal.GetPetInfoByPetID) then return end
    local ok, guid = pcall(C_PetJournal.GetSummonedPetGUID)
    if not ok or not guid or IsSecret(guid) then return end
    local ok2, _, customName, _, _, _, _, _, name = pcall(C_PetJournal.GetPetInfoByPetID, guid)
    if not ok2 then return end
    local real = (type(customName) == "string" and customName ~= "" and customName) or name
    if type(real) == "string" and real ~= "" and not IsSecret(real) then companionName = real end
end

local function IsMyCompanion(unit)
    if not companionName or not unit or IsSecret(unit) or not UnitIsOwnerOrControllerOfUnit then return false end
    local ok, exists = pcall(UnitExists, unit)
    if not ok or IsSecret(exists) or not exists then return false end
    local okP, isPlayer = pcall(UnitIsPlayer, unit)
    if not okP or IsSecret(isPlayer) or isPlayer then return false end
    local okO, mine = pcall(UnitIsOwnerOrControllerOfUnit, "player", unit)
    if not okO or IsSecret(mine) or mine ~= true then return false end
    if IsMyPet(unit) then return false end
    local okN, name = pcall(UnitName, unit)
    if not okN or IsSecret(name) then return false end
    return name == companionName
end

-- The real name and the nickname for a unit, if it is your pet or companion.
local function RealAndNick(unit)
    if not DB then return nil end
    if IsMyPet(unit) then
        local real = PetRealName()
        return real, real and DB.names[real] or nil
    end
    if IsMyCompanion(unit) then
        return companionName, DB.companions[companionName]
    end
    return nil
end

local function IsMine(unit)
    return IsMyPet(unit) or IsMyCompanion(unit)
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
    if not getUnit then return end
    local real, nick = RealAndNick(getUnit())
    if not nick then return end
    local text = fs:GetText()
    if not text or IsSecret(text) then return end
    -- Already swapped? Only a question when the nickname contains the real
    -- name ("Coco" -> "Coco the Cat"). A nickname inside the real name
    -- ("Panda Cub" -> "Panda") is fine: the swapped text has no real name left.
    if string.find(nick, real, 1, true) and string.find(text, nick, 1, true) then return end
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
    if not IsMine(unit) or not C_NamePlate or not C_NamePlate.GetNamePlateForUnit then return end
    local ok, plate = pcall(C_NamePlate.GetNamePlateForUnit, unit)
    if not ok or not plate then return end
    Collect(plate, function() return plate.namePlateUnitToken end)
end

-- Re-applies the nickname on every watched font string that shows your pet or
-- companion, optionally turning an old nickname of `oldReal` back into the
-- real name first.
local function RefreshAll(oldNick, oldReal)
    for fs, getUnit in pairs(hooked) do
        local unit = getUnit()
        if IsMine(unit) then
            local real = RealAndNick(unit)
            if oldNick and real and real == oldReal then
                local text = fs:GetText()
                -- Only text that shows the old nickname, not the real name that
                -- contains it ("Panda Cub" must not become "Panda Cub Cub").
                if text and not IsSecret(text) and string.find(text, oldNick, 1, true)
                    and (not string.find(text, real, 1, true) or string.find(oldNick, real, 1, true)) then
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
        if not ok then return end
        local real, nick = RealAndNick(unit)
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

-- Who /petname talks about: your targeted companion, else your combat pet,
-- else your summoned companion. Returns the saved table and the real name.
local function Subject()
    UpdateCompanion()
    if IsMyCompanion("target") then return DB.companions, companionName end
    local real = PetRealName()
    if real then return DB.names, real end
    if companionName then return DB.companions, companionName end
    return nil
end

local function Check()
    UpdateCompanion()
    local function yesno(f, ...)
        if not f then return "n/a" end
        local ok, v = pcall(f, ...)
        if not ok then return "error" end
        if IsSecret(v) then return "secret" end
        return tostring(v)
    end
    Print("summoned companion: " .. tostring(companionName))
    Print("target name: " .. yesno(UnitName, "target")
        .. ", owned by you: " .. yesno(UnitIsOwnerOrControllerOfUnit, "player", "target")
        .. ", your combat pet: " .. tostring(IsMyPet("target"))
        .. ", your companion: " .. tostring(IsMyCompanion("target")))
end

SLASH_PETNICKNAME1 = "/petname"
SlashCmdList.PETNICKNAME = function(msg)
    msg = Trim(msg or "")
    local lower = string.lower(msg)

    if lower == "list" then
        local any = false
        for r, n in pairs(DB.names) do
            Print(r .. " is called " .. n)
            any = true
        end
        for r, n in pairs(DB.companions) do
            Print(r .. " (companion) is called " .. n)
            any = true
        end
        if not any then Print("No nicknames set yet.") end
        return
    end

    if lower == "check" then
        Check()
        return
    end

    local list, real = Subject()
    if not real then
        Print("No pet or companion out. Summon one first, then type /petname <name>.")
        return
    end

    if msg == "" then
        local nick = list[real]
        if nick then
            Print(real .. " is called " .. nick .. ". Remove it with /petname reset")
        else
            Print("Usage: /petname <name>, /petname reset, /petname list")
        end
        return
    end

    if lower == "reset" then
        local old = list[real]
        if not old then
            Print(real .. " has no nickname.")
            return
        end
        list[real] = nil
        RefreshAll(old, real)
        Print(real .. " is called " .. real .. " again.")
        return
    end

    local old = list[real]
    list[real] = msg
    FullScan()
    RefreshAll(old, real)
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
ev:RegisterEvent("COMPANION_UPDATE")
ev:SetScript("OnEvent", function(_, event, arg1)
    if event == "ADDON_LOADED" then
        if arg1 == ADDON then
            PetNicknameDB = PetNicknameDB or {}
            PetNicknameDB.names = PetNicknameDB.names or {}
            PetNicknameDB.companions = PetNicknameDB.companions or {}
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
    elseif event == "COMPANION_UPDATE" then
        -- Fires for mounts too; the journal knows whether a companion is out.
        C_Timer.After(0.5, function()
            UpdateCompanion()
            RefreshAll()
        end)
    elseif event == "PLAYER_ENTERING_WORLD" then
        C_Timer.After(1, function()
            UpdateCompanion()
            FullScan()
            RefreshAll()
        end)
    else
        -- Target or focus changed: the companion may have changed without
        -- COMPANION_UPDATE, so ask the journal again before the frames update.
        UpdateCompanion()
        ScanKnownFrames()
    end
end)
