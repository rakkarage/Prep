-- BattleShoutAlert
-- Glows action bar buttons when key buffs are missing.
-- Five fixed slots: buff, food, weapon, flask, rune.
-- Compatible with WoW: Midnight

local ADDON_NAME    = "BattleShoutAlert"

local defaults      = {
    onlyInCombat = false,
    checkGroup   = true,
    flashAlpha   = 1.0,
    flashR       = 1.0,
    flashG       = 0.1,
    flashB       = 0.1,
    -- Each slot stores: { spellID=n } or { itemID=n } or nil if unset
    slotBuff     = nil,
    slotFood     = nil,
    slotWeapon   = nil,
    slotFlask    = nil,
    slotRune     = nil,
}

local db
local activeGlows   = {}
local pendingUpdate = false

-- ─── Slot → button frame (AssKey-style, correct for Midnight) ────────────────

local function GetButtonForActionSlot(actionSlot)
    local btnName
    if actionSlot <= 12 then
        btnName = "ActionButton" .. actionSlot
    elseif actionSlot <= 24 then
        btnName = "ActionButton" .. (actionSlot - 12)              -- bonus bar (same frames as main)
    elseif actionSlot <= 36 then
        btnName = "MultiBarBottomLeftButton" .. (actionSlot - 24)  -- bar 3
    elseif actionSlot <= 48 then
        btnName = "MultiBarBottomRightButton" .. (actionSlot - 36) -- bar 4
    elseif actionSlot <= 60 then
        btnName = "MultiBarRightButton" .. (actionSlot - 48)       -- bar 5
    elseif actionSlot <= 72 then
        btnName = "MultiBarLeftButton" .. (actionSlot - 60)        -- bar 6
    elseif actionSlot >= 145 and actionSlot <= 156 then
        btnName = "MultiBar5Button" .. (actionSlot - 144)
    elseif actionSlot >= 157 and actionSlot <= 168 then
        btnName = "MultiBar6Button" .. (actionSlot - 156)
    elseif actionSlot >= 169 and actionSlot <= 180 then
        btnName = "MultiBar7Button" .. (actionSlot - 168)
    end
    if not btnName then return nil end
    local btn = _G[btnName]
    if btn and btn:IsVisible() then return btn end
    return nil
end

-- ─── Find button on bar ───────────────────────────────────────────────────────

local function FindButtonForSpell(spellID)
    for actionSlot = 1, 180 do
        local actionType, id = GetActionInfo(actionSlot)
        if actionType == "spell" and id == spellID then
            local btn = GetButtonForActionSlot(actionSlot)
            if btn then return btn end
        end
    end
    return nil
end

local function FindButtonForItem(itemID)
    for actionSlot = 1, 180 do
        local actionType, id = GetActionInfo(actionSlot)
        if actionType == "item" and id == itemID then
            local btn = GetButtonForActionSlot(actionSlot)
            if btn then return btn end
        end
    end
    return nil
end

local function FindButton(slot)
    if not slot then return nil end
    if slot.spellID then return FindButtonForSpell(slot.spellID) end
    if slot.itemID then return FindButtonForItem(slot.itemID) end
    return nil
end

-- ─── Buff presence checks ─────────────────────────────────────────────────────

-- Generic: check player (and optionally group) for a named aura
local function HasAura(name, checkGroup)
    if AuraUtil.FindAuraByName(name, "player", "HELPFUL") then return true end
    if checkGroup then
        local groupSize = GetNumGroupMembers()
        if groupSize > 0 then
            local prefix = IsInRaid() and "raid" or "party"
            for i = 1, groupSize do
                local unit = prefix .. i
                if UnitExists(unit) and AuraUtil.FindAuraByName(name, unit, "HELPFUL") then
                    return true
                end
            end
        end
    end
    return false
end

-- Buff slot: any spell whose buff name matches the spell name
local function HasBuff(slot)
    if not slot or not slot.spellID then return true end
    local name = C_Spell.GetSpellName(slot.spellID)
    if not name then return true end -- unknown, don't false-alarm
    return HasAura(name, db.checkGroup)
end

-- Food: any "Well Fed" variant
local function HasFood()
    for i = 1, 40 do
        local aura = C_UnitAuras.GetBuffDataByIndex("player", i)
        if not aura then break end
        if aura.name then
            local lower = aura.name:lower()
            if lower:find("well fed") then return true end
        end
    end
    return false
end

-- Weapon: main hand enchant
local function HasWeaponEnchant()
    local hasEnchant = GetWeaponEnchantInfo()
    return hasEnchant == true or hasEnchant == 1
end

-- Flask: any flask or phial aura
local function HasFlask()
    for i = 1, 40 do
        local aura = C_UnitAuras.GetBuffDataByIndex("player", i)
        if not aura then break end
        if aura.name then
            local lower = aura.name:lower()
            if lower:find("flask") or lower:find("phial") then return true end
        end
    end
    return false
end

-- Rune: any augment rune aura
local function HasRune()
    for i = 1, 40 do
        local aura = C_UnitAuras.GetBuffDataByIndex("player", i)
        if not aura then break end
        if aura.name then
            local lower = aura.name:lower()
            if lower:find("rune") or lower:find("augment") then return true end
        end
    end
    return false
end

-- ─── Checks table ────────────────────────────────────────────────────────────

local checks = {
    { key = "slotBuff",   label = "Buff",   hasFunc = function() return HasBuff(db.slotBuff) end },
    { key = "slotFood",   label = "Food",   hasFunc = HasFood },
    { key = "slotWeapon", label = "Weapon", hasFunc = HasWeaponEnchant },
    { key = "slotFlask",  label = "Flask",  hasFunc = HasFlask },
    { key = "slotRune",   label = "Rune",   hasFunc = HasRune },
}

-- ─── Glow / Flash ────────────────────────────────────────────────────────────

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

-- ─── Main update ─────────────────────────────────────────────────────────────

local function ScheduleUpdate()
    if pendingUpdate then return end
    pendingUpdate = true
    C_Timer.After(0.1, function()
        pendingUpdate = false
        for _, btn in pairs(activeGlows) do RemoveGlow(btn) end
        wipe(activeGlows)
        if db.onlyInCombat and not InCombatLockdown() then return end
        for _, check in ipairs(checks) do
            local slot = db[check.key]
            if slot then -- only check if this slot is configured
                if not check.hasFunc() then
                    local btn = FindButton(slot)
                    if btn then
                        ApplyGlow(btn)
                        activeGlows[check.key] = btn
                    end
                end
            end
        end
    end)
end

-- ─── Events ──────────────────────────────────────────────────────────────────

local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:SetScript("OnEvent", function(self, event, arg1)
    if event == "ADDON_LOADED" then
        if arg1 ~= ADDON_NAME then return end
        BattleShoutAlertDB = BattleShoutAlertDB or {}
        db = BattleShoutAlertDB
        for k, v in pairs(defaults) do
            if db[k] == nil then db[k] = v end
        end
        self:RegisterEvent("PLAYER_ENTERING_WORLD")
        self:RegisterEvent("PLAYER_REGEN_ENABLED")
        self:RegisterEvent("PLAYER_REGEN_DISABLED")
        self:RegisterEvent("UNIT_AURA")
        self:RegisterEvent("ACTIONBAR_SLOT_CHANGED")
        self:RegisterEvent("GROUP_ROSTER_UPDATE")
        self:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")
        self:UnregisterEvent("ADDON_LOADED")
    elseif event == "UNIT_AURA" then
        local unit = arg1
        if unit == "player" or (db.checkGroup and (unit:find("party") or unit:find("raid"))) then
            ScheduleUpdate()
        end
    else
        ScheduleUpdate()
    end
end)

-- ─── Name/link → ID helpers ───────────────────────────────────────────────────

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
    -- Strip item link: |cff...|Hitem:12345:...|h[Name]|h|r
    local linkID = arg:match("|Hitem:(%d+):")
    if linkID then return tonumber(linkID) end
    -- Strip plain [Name] brackets
    local bracketed = arg:match("^%[(.+)%]$")
    if bracketed then arg = bracketed end
    -- Try numeric
    local id = tonumber(arg)
    if id then return id end
    -- Bag name search
    return FindItemIDByName(arg)
end

local function ParseSpellArg(arg)
    local id = tonumber(arg)
    if id then return id end
    return FindSpellIDByName(arg)
end

-- ─── Slash commands ───────────────────────────────────────────────────────────

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
    end
    return label .. ": |cffff4444(unknown)|r"
end

local function PrintHelp()
    print("|cff00ccff[BSA]|r Commands:")
    print("  |cffffff00/bsa buff <spell id/name>|r    - set buff slot (Battle Shout, Arcane Intellect, etc)")
    print("  |cffffff00/bsa food <item id/name/link>|r - set food slot")
    print("  |cffffff00/bsa weapon <item id/name/link>|r - set weapon enchant slot")
    print("  |cffffff00/bsa flask <item id/name/link>|r - set flask slot")
    print("  |cffffff00/bsa rune <item id/name/link>|r  - set rune slot")
    print("  |cffffff00/bsa clear <buff|food|weapon|flask|rune>|r - clear a slot")
    print("  |cffffff00/bsa combat|r                  - toggle combat-only mode")
    print("  |cffffff00/bsa group|r                   - toggle group buff check")
    print("  |cffffff00/bsa alpha <0.1-1.0>|r         - set flash alpha")
    print("  |cffffff00/bsa color <r> <g> <b>|r       - set flash color (0-1 each)")
    print("  |cffffff00/bsa status|r                  - show current config")
end

SLASH_BSALERT1 = "/bsa"
SLASH_BSALERT2 = "/battleshout"
SlashCmdList["BSALERT"] = function(msg)
    local origMsg = (msg or ""):trim()
    local cmd, origArg = origMsg:match("^(%S+)%s*(.*)$")
    cmd = cmd and cmd:lower() or ""
    local arg = origArg and origArg:lower() or ""

    if cmd == "buff" then
        if origArg == "" then
            print("|cff00ccff[BSA]|r Usage: /bsa buff <spell id or name>")
            return
        end
        local id = ParseSpellArg(origArg)
        if not id then
            print("|cff00ccff[BSA]|r Spell not found in spellbook: |cffffff00" .. origArg .. "|r")
            return
        end
        db.slotBuff = { spellID = id }
        local name = C_Spell.GetSpellName(id) or ("spell " .. id)
        print("|cff00ccff[BSA]|r Buff slot set to: |cffffff00" .. name .. "|r")
        ScheduleUpdate()
    elseif cmd == "food" then
        if origArg == "" then
            print("|cff00ccff[BSA]|r Usage: /bsa food <item id, name, or shift-click link>")
            return
        end
        local id = ParseItemArg(origArg)
        if not id then
            print("|cff00ccff[BSA]|r Item not found: |cffffff00" .. origArg .. "|r  (make sure it's in your bags)")
            return
        end
        db.slotFood = { itemID = id }
        local name = C_Item.GetItemNameByID(id) or ("item " .. id)
        print("|cff00ccff[BSA]|r Food slot set to: |cffffff00" .. name .. "|r")
        ScheduleUpdate()
    elseif cmd == "weapon" then
        if origArg == "" then
            print("|cff00ccff[BSA]|r Usage: /bsa weapon <item id, name, or shift-click link>")
            return
        end
        local id = ParseItemArg(origArg)
        if not id then
            print("|cff00ccff[BSA]|r Item not found: |cffffff00" .. origArg .. "|r  (make sure it's in your bags)")
            return
        end
        db.slotWeapon = { itemID = id }
        local name = C_Item.GetItemNameByID(id) or ("item " .. id)
        print("|cff00ccff[BSA]|r Weapon slot set to: |cffffff00" .. name .. "|r")
        ScheduleUpdate()
    elseif cmd == "flask" then
        if origArg == "" then
            print("|cff00ccff[BSA]|r Usage: /bsa flask <item id, name, or shift-click link>")
            return
        end
        local id = ParseItemArg(origArg)
        if not id then
            print("|cff00ccff[BSA]|r Item not found: |cffffff00" .. origArg .. "|r  (make sure it's in your bags)")
            return
        end
        db.slotFlask = { itemID = id }
        local name = C_Item.GetItemNameByID(id) or ("item " .. id)
        print("|cff00ccff[BSA]|r Flask slot set to: |cffffff00" .. name .. "|r")
        ScheduleUpdate()
    elseif cmd == "rune" then
        if origArg == "" then
            print("|cff00ccff[BSA]|r Usage: /bsa rune <item id, name, or shift-click link>")
            return
        end
        local id = ParseItemArg(origArg)
        if not id then
            print("|cff00ccff[BSA]|r Item not found: |cffffff00" .. origArg .. "|r  (make sure it's in your bags)")
            return
        end
        db.slotRune = { itemID = id }
        local name = C_Item.GetItemNameByID(id) or ("item " .. id)
        print("|cff00ccff[BSA]|r Rune slot set to: |cffffff00" .. name .. "|r")
        ScheduleUpdate()
    elseif cmd == "clear" then
        local slotKey = "slot" .. arg:sub(1, 1):upper() .. arg:sub(2)
        if db[slotKey] ~= nil then
            db[slotKey] = nil
            print("|cff00ccff[BSA]|r Cleared: " .. arg)
            ScheduleUpdate()
        else
            print("|cff00ccff[BSA]|r Unknown slot: " .. arg .. "  (buff, food, weapon, flask, rune)")
        end
    elseif cmd == "combat" then
        db.onlyInCombat = not db.onlyInCombat
        print("|cff00ccff[BSA]|r Combat-only: " .. (db.onlyInCombat and "|cff00ff00ON|r" or "|cffff4444OFF|r"))
        ScheduleUpdate()
    elseif cmd == "group" then
        db.checkGroup = not db.checkGroup
        print("|cff00ccff[BSA]|r Group buff check: " .. (db.checkGroup and "|cff00ff00ON|r" or "|cffff4444OFF|r"))
        ScheduleUpdate()
    elseif cmd == "alpha" then
        local v = tonumber(origArg)
        if not v or v < 0.1 or v > 1.0 then
            print("|cff00ccff[BSA]|r Usage: /bsa alpha <0.1 - 1.0>")
            return
        end
        db.flashAlpha = v
        print("|cff00ccff[BSA]|r Flash alpha set to " .. v)
        ScheduleUpdate()
    elseif cmd == "color" then
        local r, g, b = origArg:match("^(%S+)%s+(%S+)%s+(%S+)$")
        r, g, b = tonumber(r), tonumber(g), tonumber(b)
        if not r or not g or not b then
            print("|cff00ccff[BSA]|r Usage: /bsa color <r> <g> <b>  (values 0.0 - 1.0)")
            return
        end
        db.flashR, db.flashG, db.flashB = r, g, b
        print(string.format("|cff00ccff[BSA]|r Flash color set to %.2f %.2f %.2f", r, g, b))
        ScheduleUpdate()
    elseif cmd == "status" then
        print("|cff00ccff[BSA]|r Current config:")
        print("  " .. SlotStatus("slotBuff", "Buff"))
        print("  " .. SlotStatus("slotFood", "Food"))
        print("  " .. SlotStatus("slotWeapon", "Weapon"))
        print("  " .. SlotStatus("slotFlask", "Flask"))
        print("  " .. SlotStatus("slotRune", "Rune"))
        print("  Combat-only: " .. tostring(db.onlyInCombat))
        print("  Group check: " .. tostring(db.checkGroup))
        print(string.format("  Flash: alpha=%.2f  color=%.2f/%.2f/%.2f", db.flashAlpha, db.flashR, db.flashG, db.flashB))
    else
        PrintHelp()
    end
end

-- ─── Addon compartment ───────────────────────────────────────────────────────

function BattleShoutAlert_OnAddonCompartmentClick(addonName)
    if addonName == ADDON_NAME then
        PrintHelp()
    end
end
