-- Prep
-- Highlights action bar buttons for missing buff, food, weapon enchant, flask, rune, and cosmetic pet.

local ADDON_NAME = "Prep"

local defaults = {
    checkGroup = true,
    flashAlpha = 1.0,
    flashR     = 1.0,
    flashG     = 0.3,
    flashB     = 0.3,
    slotBuff   = nil,
    slotFood   = nil,
    slotWeapon = nil,
    slotFlask  = nil,
    slotRune   = nil,
    slotPet    = nil,
}

local db
local activeGlows = {}
local pendingUpdate = false

--#region ─── Slot → button frame ─────────────────────────────────────────────────────

local function GetButtonForActionSlot(slot)
    local btnName
    if slot <= 12 then
        btnName = "ActionButton" .. slot
    elseif slot <= 24 then
        btnName = "ActionButton" .. (slot - 12)
    elseif slot <= 36 then
        btnName = "MultiBarRightButton" .. (slot - 24)
    elseif slot <= 48 then
        btnName = "MultiBarLeftButton" .. (slot - 36)
    elseif slot <= 60 then
        btnName = "MultiBarBottomRightButton" .. (slot - 48)
    elseif slot <= 72 then
        btnName = "MultiBarBottomLeftButton" .. (slot - 60)
    elseif slot >= 145 and slot <= 156 then
        btnName = "MultiBar5Button" .. (slot - 144)
    elseif slot >= 157 and slot <= 168 then
        btnName = "MultiBar6Button" .. (slot - 156)
    elseif slot >= 169 and slot <= 180 then
        btnName = "MultiBar7Button" .. (slot - 168)
    end
    if not btnName then return nil end
    local btn = _G[btnName]
    if btn and btn:IsVisible() then return btn end
    return nil
end

--#endregion

--#region ─── Find button on bar ──────────────────────────────────────────────────────

local function FindButtonForSpell(spellID)
    for actionSlot = 1, 180 do
        local actionType, id = GetActionInfo(actionSlot)
        if (actionType == "spell" or actionType == "macro") and id == spellID then
            local btn = GetButtonForActionSlot(actionSlot)
            if btn then return btn end
        end
    end
    return nil
end

local function FindButtonForItem(itemID)
    if (GetItemCount(itemID) or 0) == 0 then return nil end
    for actionSlot = 1, 180 do
        local actionType, id = GetActionInfo(actionSlot)
        if (actionType == "item" or actionType == "macro") and id == itemID then
            local btn = GetButtonForActionSlot(actionSlot)
            if btn then return btn end
        end
    end
    return nil
end

local function FindButtonForPet(petGUID)
    for actionSlot = 1, 180 do
        local actionType, id = GetActionInfo(actionSlot)
        if actionType == "summonpet" and id == petGUID then
            local btn = GetButtonForActionSlot(actionSlot)
            if btn then return btn end
        end
    end
    return nil
end

local function FindButton(slot)
    if not slot then return nil end
    if slot.petGUID then return FindButtonForPet(slot.petGUID) end
    if slot.spellID then return FindButtonForSpell(slot.spellID) end
    if slot.itemID then return FindButtonForItem(slot.itemID) end
    return nil
end

--#endregion

--#region ─── Buff / aura checks ──────────────────────────────────────────────────────

local function HasAura(name, checkGroup)
    local playerHas = AuraUtil.FindAuraByName(name, "player", "HELPFUL") ~= nil
    if checkGroup then
        local groupSize = GetNumGroupMembers()
        if groupSize > 0 then
            local prefix = IsInRaid() and "raid" or "party"
            for i = 1, groupSize do
                local unit = prefix .. i
                if UnitExists(unit) and not AuraUtil.FindAuraByName(name, unit, "HELPFUL") then
                    return false
                end
            end
        end
    end
    return playerHas
end

local function HasBuff(slot)
    if not slot or not slot.spellID then return true end
    local name = C_Spell.GetSpellName(slot.spellID)
    if not name then return true end
    return HasAura(name, db.checkGroup)
end

local WELL_FED_NAMES = { "Well Fed", "Hearty Well Fed" }
local function HasFood()
    for _, name in ipairs(WELL_FED_NAMES) do
        if AuraUtil.FindAuraByName(name, "player", "HELPFUL") then return true end
    end
    return false
end

local function HasWeaponEnchant()
    local hasEnchant = GetWeaponEnchantInfo()
    return hasEnchant == true
end

local function HasFlask()
    if not db.slotFlask or not db.slotFlask.itemID then return true end
    local name = C_Item.GetItemNameByID(db.slotFlask.itemID)
    if not name then return true end
    return AuraUtil.FindAuraByName(name, "player", "HELPFUL") ~= nil
end

local function HasRune()
    for i = 1, 40 do
        local ok, aura = pcall(C_UnitAuras.GetAuraDataByIndex, "player", i, "HELPFUL")
        if not ok or not aura then break end
        local ok2, name = pcall(function() return aura.name end)
        if ok2 and name and not issecretvalue(name) then
            if name:lower():find("augment") then return true end
        end
    end
    return false
end

local function HasPet()
    if not db.slotPet then return true end
    local guid = C_PetJournal.GetSummonedPetGUID()
    return guid ~= nil and guid ~= ""
end

local checks = {
    { key = "slotBuff",   hasFunc = function() return HasBuff(db.slotBuff) end },
    { key = "slotFood",   hasFunc = HasFood },
    { key = "slotWeapon", hasFunc = HasWeaponEnchant },
    { key = "slotFlask",  hasFunc = HasFlask },
    { key = "slotRune",   hasFunc = HasRune },
    { key = "slotPet",    hasFunc = HasPet },
}

--#endregion

--#region ─── Glow / Flash ────────────────────────────────────────────────────────────

local function ApplyGlow(btn)
    if not btn then return end
    if btn.SpellHighlightTexture then
        btn.SpellHighlightTexture:Show()
        btn.SpellHighlightTexture:SetAlpha(db.flashAlpha)
        btn.SpellHighlightTexture:SetVertexColor(db.flashR, db.flashG, db.flashB)
    end
    if btn.Flash then
        btn.Flash:Show()
        btn.Flash:SetAlpha(db.flashAlpha)
        btn.Flash:SetVertexColor(db.flashR, db.flashG, db.flashB)
    end
end

local function RemoveGlow(btn)
    if not btn then return end
    if btn.SpellHighlightTexture then
        btn.SpellHighlightTexture:Hide()
        btn.SpellHighlightTexture:SetVertexColor(1, 1, 1)
        btn.SpellHighlightTexture:SetAlpha(1)
    end
    if btn.Flash then
        btn.Flash:Hide()
        btn.Flash:SetVertexColor(1, 1, 1)
        btn.Flash:SetAlpha(1)
    end
end

--#endregion

--#region ─── Main update ─────────────────────────────────────────────────────────────

local function ScheduleUpdate()
    if InCombatLockdown() then
        for _, btn in pairs(activeGlows) do RemoveGlow(btn) end
        wipe(activeGlows)
        return
    end
    if EditModeManagerFrame and EditModeManagerFrame:IsEditModeActive() then
        for _, btn in pairs(activeGlows) do RemoveGlow(btn) end
        wipe(activeGlows)
        return
    end
    if pendingUpdate then return end
    pendingUpdate = true
    C_Timer.After(0.1, function()
        pendingUpdate = false
        if EditModeManagerFrame and EditModeManagerFrame:IsEditModeActive() then return end
        for _, btn in pairs(activeGlows) do RemoveGlow(btn) end
        wipe(activeGlows)
        for _, check in ipairs(checks) do
            local slot = db[check.key]
            if slot then
                local btn = FindButton(slot)
                if btn and not check.hasFunc() then
                    ApplyGlow(btn)
                    activeGlows[check.key] = btn
                end
            end
        end
    end)
end

--#endregion

--#region ─── Events ──────────────────────────────────────────────────────────────────

local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:SetScript("OnEvent", function(self, event, arg1)
    if event == "ADDON_LOADED" then
        if arg1 ~= ADDON_NAME then return end
        PrepDB = PrepDB or {}
        db = PrepDB
        for k, v in pairs(defaults) do
            if db[k] == nil then db[k] = v end
        end
        self:RegisterEvent("EDIT_MODE_LAYOUTS_UPDATED")
        self:RegisterEvent("ACTIVE_TALENT_GROUP_CHANGED")
        self:RegisterEvent("PLAYER_ENTERING_WORLD")
        self:RegisterEvent("PLAYER_REGEN_ENABLED")
        self:RegisterEvent("PLAYER_REGEN_DISABLED")
        self:RegisterEvent("UNIT_AURA")
        self:RegisterEvent("ACTIONBAR_SLOT_CHANGED")
        self:RegisterEvent("GROUP_ROSTER_UPDATE")
        self:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")
        self:RegisterEvent("UNIT_PET")
        self:RegisterEvent("PET_JOURNAL_LIST_UPDATE")
        self:RegisterEvent("ACTIONBAR_PAGE_CHANGED")
        self:UnregisterEvent("ADDON_LOADED")
    elseif event == "PLAYER_REGEN_ENABLED" then
        C_Timer.After(1.0, function()
            if not InCombatLockdown() then ScheduleUpdate() end
        end)
    elseif event == "UNIT_AURA" then
        local unit = arg1
        if unit == "player" or (db.checkGroup and (unit:find("party") or unit:find("raid"))) then
            ScheduleUpdate()
        end
    else
        ScheduleUpdate()
    end
end)

--#endregion

--#region ─── Name/link → ID helpers ──────────────────────────────────────────────────

local function FindSpellIDByName(searchName)
    searchName = searchName:lower()
    for i = 1, 1000 do
        local info = C_SpellBook.GetSpellBookItemInfo(i, Enum.SpellBookSpellBank.Player)
        if not info then break end
        if info.spellID and info.spellID > 0 then
            local name = C_Spell.GetSpellName(info.spellID)
            if name and name:lower() == searchName then
                return info.spellID
            end
        end
    end
    if C_Spell.GetSpellIDForSpellIdentifier then
        local id = C_Spell.GetSpellIDForSpellIdentifier(searchName)
        if id and id > 0 then return id end
    end
    return nil
end

local function FindItemIDByName(searchName)
    searchName = searchName:lower()
    for bag = 0, NUM_BAG_SLOTS do
        for slot = 1, C_Container.GetContainerNumSlots(bag) do
            local info = C_Container.GetContainerItemInfo(bag, slot)
            if info and info.itemID then
                local name = C_Item.GetItemNameByID(info.itemID)
                if name and name:lower() == searchName then
                    return info.itemID
                end
            end
        end
    end
    return nil
end

local function ParseItemArg(arg)
    local linkID = arg:match("|Hitem:(%d+):")
    if linkID then return tonumber(linkID) end
    local bracketed = arg:match("^%[(.+)%]$")
    if bracketed then arg = bracketed end
    local id = tonumber(arg)
    if id then return id end
    return FindItemIDByName(arg)
end

local function ParseSpellArg(arg)
    local linkID = arg:match("|Hspell:(%d+)")
    if linkID then return tonumber(linkID) end
    local id = tonumber(arg)
    if id then return id end
    return FindSpellIDByName(arg)
end

local function FindPetGUIDByName(searchName)
    searchName = searchName:lower()
    local numPets = C_PetJournal.GetNumPets()
    for i = 1, numPets do
        local petGUID, _, _, customName, _, _, _, speciesName = C_PetJournal.GetPetInfoByIndex(i)
        if petGUID then
            local matchCustom  = customName and customName:lower() == searchName
            local matchSpecies = speciesName and speciesName:lower() == searchName
            if matchCustom or matchSpecies then
                local displayName = (customName and customName ~= "") and customName or speciesName
                local _, spellID = C_PetJournal.GetPetInfoByPetID(petGUID)
                return petGUID, displayName, spellID
            end
        end
    end
    return nil, nil, nil
end

--#endregion

--#region ─── Status display ──────────────────────────────────────────────────────────

local function SlotStatus(key, label)
    local slot = db[key]
    if not slot then
        return label .. ": |cffaaaaaa(not set)|r"
    elseif slot.spellID then
        local name = C_Spell.GetSpellName(slot.spellID) or ("spell " .. slot.spellID)
        return label .. ": |cffffff00" .. name .. "|r (spell " .. slot.spellID .. ")"
    elseif slot.itemID then
        local name = C_Item.GetItemNameByID(slot.itemID) or ("item " .. slot.itemID)
        return label .. ": |cffffff00" .. name .. "|r (item " .. slot.itemID .. ")"
    elseif slot.petGUID then
        local _, _, _, cn, _, _, _, sn = C_PetJournal.GetPetInfoByPetID(slot.petGUID)
        local petName = (cn and cn ~= "") and cn or sn or "unknown pet"
        return label .. ": |cffffff00" .. petName .. "|r (pet journal)"
    end
    return label .. ": |cffff4444(unknown)|r"
end

local function ShowStatus()
    print("|cff00ccff[Prep]|r Current status:")
    print("  " .. SlotStatus("slotBuff", "Buff"))
    print("  " .. SlotStatus("slotFood", "Food"))
    print("  " .. SlotStatus("slotWeapon", "Weapon"))
    print("  " .. SlotStatus("slotFlask", "Flask"))
    print("  " .. SlotStatus("slotRune", "Rune"))
    print("  " .. SlotStatus("slotPet", "Pet"))
    print("  Group check: " .. tostring(db.checkGroup))
    print(string.format("  Highlight: alpha=%.2f  color=%.2f/%.2f/%.2f", db.flashAlpha, db.flashR, db.flashG,
        db.flashB))
end

--#endregion

--#region ─── Slash commands ──────────────────────────────────────────────────────────

local function ResetToDefaults()
    -- Clear all current glows first
    for _, btn in pairs(activeGlows) do
        RemoveGlow(btn)
    end
    wipe(activeGlows)

    -- Completely wipe and rebuild the database
    wipe(PrepDB)
    db = PrepDB

    -- Set all defaults
    for k, v in pairs(defaults) do
        db[k] = v
    end

    -- Force a full update after a short delay
    C_Timer.After(0.2, function()
        ScheduleUpdate()
        -- Show status after reset
        ShowStatus()
    end)

    print("|cff00ccff[Prep]|r All settings reset to defaults")
end

local function PrintHelp()
    print("|cff00ccff[Prep]|r Commands:")
    print("  |cffffff00/prep buff <spell id/name/link>|r - Battle Shout, Arcane Intellect, etc")
    print("  |cffffff00/prep food <item id/name/link>|r - food item")
    print("  |cffffff00/prep weapon <item id/name/link>|r - weapon enchant item")
    print("  |cffffff00/prep flask <item id/name/link>|r - flask item")
    print("  |cffffff00/prep rune <item id/name/link>|r - augment rune item")
    print("  |cffffff00/prep pet <name>|r - cosmetic pet (custom or species name)")
    print("  |cffffff00/prep clear <slot>|r - buff/food/weapon/flask/rune/pet")
    print("  |cffffff00/prep reset|r - reset all settings to defaults (shows status)")
    print("  |cffffff00/prep group|r - toggle group buff check")
    print("  |cffffff00/prep alpha <0.1-1.0>|r - highlight alpha")
    print("  |cffffff00/prep color <r> <g> <b>|r - highlight color (0.0-1.0)")
    print("  |cffffff00/prep status|r - show current settings")
end

SLASH_PREP1 = "/prep"
SlashCmdList["PREP"] = function(msg)
    local origMsg = (msg or ""):trim()
    local cmd, origArg = origMsg:match("^(%S+)%s*(.*)$")
    cmd = cmd and cmd:lower() or ""
    local arg = origArg and origArg:lower() or ""

    if cmd == "buff" then
        if origArg == "" then
            print("|cff00ccff[Prep]|r Usage: /prep buff <spell id, name, or link>")
            return
        end
        local id = ParseSpellArg(origArg)
        if not id then
            print("|cff00ccff[Prep]|r Spell not found: |cffffff00" .. origArg .. "|r")
            return
        end
        db.slotBuff = { spellID = id }
        print("|cff00ccff[Prep]|r Buff set to: |cffffff00" .. (C_Spell.GetSpellName(id) or id) .. "|r")
        ScheduleUpdate()
    elseif cmd == "food" then
        if origArg == "" then
            print("|cff00ccff[Prep]|r Usage: /prep food <item id, name, or link>")
            return
        end
        local id = ParseItemArg(origArg)
        if not id then
            print("|cff00ccff[Prep]|r Item not found: |cffffff00" .. origArg .. "|r  (must be in bags)")
            return
        end
        db.slotFood = { itemID = id }
        print("|cff00ccff[Prep]|r Food set to: |cffffff00" .. (C_Item.GetItemNameByID(id) or id) .. "|r")
        ScheduleUpdate()
    elseif cmd == "weapon" then
        if origArg == "" then
            print("|cff00ccff[Prep]|r Usage: /prep weapon <item id, name, or link>")
            return
        end
        local id = ParseItemArg(origArg)
        if not id then
            print("|cff00ccff[Prep]|r Item not found: |cffffff00" .. origArg .. "|r  (must be in bags)")
            return
        end
        db.slotWeapon = { itemID = id }
        print("|cff00ccff[Prep]|r Weapon set to: |cffffff00" .. (C_Item.GetItemNameByID(id) or id) .. "|r")
        ScheduleUpdate()
    elseif cmd == "flask" then
        if origArg == "" then
            print("|cff00ccff[Prep]|r Usage: /prep flask <item id, name, or link>")
            return
        end
        local id = ParseItemArg(origArg)
        if not id then
            print("|cff00ccff[Prep]|r Item not found: |cffffff00" .. origArg .. "|r  (must be in bags)")
            return
        end
        db.slotFlask = { itemID = id }
        print("|cff00ccff[Prep]|r Flask set to: |cffffff00" .. (C_Item.GetItemNameByID(id) or id) .. "|r")
        ScheduleUpdate()
    elseif cmd == "rune" then
        if origArg == "" then
            print("|cff00ccff[Prep]|r Usage: /prep rune <item id, name, or link>")
            return
        end
        local id = ParseItemArg(origArg)
        if not id then
            print("|cff00ccff[Prep]|r Item not found: |cffffff00" .. origArg .. "|r  (must be in bags)")
            return
        end
        db.slotRune = { itemID = id }
        print("|cff00ccff[Prep]|r Rune set to: |cffffff00" .. (C_Item.GetItemNameByID(id) or id) .. "|r")
        ScheduleUpdate()
    elseif cmd == "pet" then
        if origArg == "" then
            print("|cff00ccff[Prep]|r Usage: /prep pet <name>  e.g. /prep pet Zergling")
            return
        end
        local petGUID, petName, spellID = FindPetGUIDByName(origArg)
        if not petGUID then
            print("|cff00ccff[Prep]|r Pet not found: |cffffff00" ..
                origArg .. "|r  (check spelling, must be in your collection)")
            return
        end
        db.slotPet = { petGUID = petGUID, spellID = spellID }
        print("|cff00ccff[Prep]|r Pet set to: |cffffff00" .. petName .. "|r")
        ScheduleUpdate()
    elseif cmd == "clear" then
        local slotKey = "slot" .. arg:sub(1, 1):upper() .. arg:sub(2)
        if db[slotKey] ~= nil then
            db[slotKey] = nil
            print("|cff00ccff[Prep]|r Cleared: " .. arg)
            ScheduleUpdate()
        else
            print("|cff00ccff[Prep]|r Unknown slot: " .. arg .. "  (buff / food / weapon / flask / rune / pet)")
        end
    elseif cmd == "reset" then
        ResetToDefaults()
    elseif cmd == "group" then
        db.checkGroup = not db.checkGroup
        print("|cff00ccff[Prep]|r Group buff check: " .. (db.checkGroup and "|cff00ff00ON|r" or "|cffff4444OFF|r"))
        ScheduleUpdate()
    elseif cmd == "alpha" then
        local v = tonumber(origArg)
        if not v or v < 0.1 or v > 1.0 then
            print("|cff00ccff[Prep]|r Usage: /prep alpha <0.1-1.0>")
            return
        end
        db.flashAlpha = v
        print("|cff00ccff[Prep]|r Alpha set to " .. v)
        ScheduleUpdate()
    elseif cmd == "color" then
        local r, g, b = origArg:match("^(%S+)%s+(%S+)%s+(%S+)$")
        r, g, b = tonumber(r), tonumber(g), tonumber(b)
        if not r or not g or not b then
            print("|cff00ccff[Prep]|r Usage: /prep color <r> <g> <b>  (0.0-1.0)")
            return
        end
        db.flashR, db.flashG, db.flashB = r, g, b
        print(string.format("|cff00ccff[Prep]|r Color set to %.2f %.2f %.2f", r, g, b))
        ScheduleUpdate()
    elseif cmd == "status" then
        ShowStatus()
    else
        PrintHelp()
    end
end

--#endregion
