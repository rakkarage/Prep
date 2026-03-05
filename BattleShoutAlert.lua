-- BattleShoutAlert
-- Glows action bar buttons when tracked buffs are missing.
-- Generic: watch any spell buff or item buff by ID or name.
-- Configuration via slash commands only.
-- Compatible with WoW: Midnight

local ADDON_NAME       = "BattleShoutAlert"

local defaults         = {
    onlyInCombat = false,
    checkGroup   = true,
    flashAlpha   = 1.0,
    flashR       = 1.0,
    flashG       = 0.1,
    flashB       = 0.1,
}

local db
local activeGlows      = {} -- key -> button frame currently glowing
local pendingUpdate    = false

-- ─── Slot → Button name map ───────────────────────────────────────────────────

local slotToButtonName = {
    [1] = "ActionButton1",
    [2] = "ActionButton2",
    [3] = "ActionButton3",
    [4] = "ActionButton4",
    [5] = "ActionButton5",
    [6] = "ActionButton6",
    [7] = "ActionButton7",
    [8] = "ActionButton8",
    [9] = "ActionButton9",
    [10] = "ActionButton10",
    [11] = "ActionButton11",
    [12] = "ActionButton12",
    [13] = "MultiBarBottomLeftButton1",
    [14] = "MultiBarBottomLeftButton2",
    [15] = "MultiBarBottomLeftButton3",
    [16] = "MultiBarBottomLeftButton4",
    [17] = "MultiBarBottomLeftButton5",
    [18] = "MultiBarBottomLeftButton6",
    [19] = "MultiBarBottomLeftButton7",
    [20] = "MultiBarBottomLeftButton8",
    [21] = "MultiBarBottomLeftButton9",
    [22] = "MultiBarBottomLeftButton10",
    [23] = "MultiBarBottomLeftButton11",
    [24] = "MultiBarBottomLeftButton12",
    [25] = "MultiBarBottomRightButton1",
    [26] = "MultiBarBottomRightButton2",
    [27] = "MultiBarBottomRightButton3",
    [28] = "MultiBarBottomRightButton4",
    [29] = "MultiBarBottomRightButton5",
    [30] = "MultiBarBottomRightButton6",
    [31] = "MultiBarBottomRightButton7",
    [32] = "MultiBarBottomRightButton8",
    [33] = "MultiBarBottomRightButton9",
    [34] = "MultiBarBottomRightButton10",
    [35] = "MultiBarBottomRightButton11",
    [36] = "MultiBarBottomRightButton12",
    [37] = "MultiBarRightButton1",
    [38] = "MultiBarRightButton2",
    [39] = "MultiBarRightButton3",
    [40] = "MultiBarRightButton4",
    [41] = "MultiBarRightButton5",
    [42] = "MultiBarRightButton6",
    [43] = "MultiBarRightButton7",
    [44] = "MultiBarRightButton8",
    [45] = "MultiBarRightButton9",
    [46] = "MultiBarRightButton10",
    [47] = "MultiBarRightButton11",
    [48] = "MultiBarRightButton12",
    [49] = "MultiBarLeftButton1",
    [50] = "MultiBarLeftButton2",
    [51] = "MultiBarLeftButton3",
    [52] = "MultiBarLeftButton4",
    [53] = "MultiBarLeftButton5",
    [54] = "MultiBarLeftButton6",
    [55] = "MultiBarLeftButton7",
    [56] = "MultiBarLeftButton8",
    [57] = "MultiBarLeftButton9",
    [58] = "MultiBarLeftButton10",
    [59] = "MultiBarLeftButton11",
    [60] = "MultiBarLeftButton12",
}
for i = 1, 12 do
    slotToButtonName[144 + i] = "MultiBar5Button" .. i
    slotToButtonName[156 + i] = "MultiBar6Button" .. i
    slotToButtonName[168 + i] = "MultiBar7Button" .. i
end

-- ─── Find button on bar ───────────────────────────────────────────────────────

local function FindButtonForSpell(spellID)
    for slot, btnName in pairs(slotToButtonName) do
        local actionType, id = GetActionInfo(slot)
        if actionType == "spell" and id == spellID then
            local btn = _G[btnName]
            if btn and btn:IsVisible() then return btn end
        end
    end
    return nil
end

local function FindButtonForItem(itemID)
    for slot, btnName in pairs(slotToButtonName) do
        local actionType, id = GetActionInfo(slot)
        if actionType == "item" and id == itemID then
            local btn = _G[btnName]
            if btn and btn:IsVisible() then return btn end
        end
    end
    return nil
end

-- ─── Spell name → ID lookup ───────────────────────────────────────────────────
-- Scans the player's spellbook to find a spell ID by name.

local function FindSpellIDByName(searchName)
    searchName = searchName:lower()
    local bookType = Enum.SpellBookSpellBank.Player
    local numSpells = C_SpellBook.GetNumSpellBookSkillLines and
        select(2, C_SpellBook.GetNumSpellBookSkillLines()) or 0

    -- Scan all spellbook entries
    for i = 1, 1000 do
        local info = C_SpellBook.GetSpellBookItemInfo(i, bookType)
        if not info then break end
        if info.spellID and info.spellID > 0 then
            local name = C_Spell.GetSpellName(info.spellID)
            if name and name:lower() == searchName then
                return info.spellID
            end
        end
    end

    -- Fallback: try C_Spell.GetSpellIDForSpellIdentifier if available
    if C_Spell.GetSpellIDForSpellIdentifier then
        local id = C_Spell.GetSpellIDForSpellIdentifier(searchName)
        if id and id > 0 then return id end
    end

    return nil
end

-- ─── Buff presence checks ────────────────────────────────────────────────────

local function PlayerHasAuraFromSpell(spellID)
    local name = C_Spell.GetSpellName(spellID)
    if not name then return true end -- unknown, don't false-alarm
    if AuraUtil.FindAuraByName(name, "player", "HELPFUL") then return true end
    if db.checkGroup then
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

local function PlayerHasAuraFromItem(itemID)
    local itemName = C_Item.GetItemNameByID(itemID)
    if not itemName then return true end -- not cached yet, don't false-alarm
    for i = 1, 40 do
        local aura = C_UnitAuras.GetBuffDataByIndex("player", i)
        if not aura then break end
        if aura.name and aura.name:lower():find(itemName:lower(), 1, true) then
            return true
        end
    end
    return false
end

local function ShouldGlow(entry)
    if db.onlyInCombat and not InCombatLockdown() then return false end
    if entry.kind == "spell" then
        return not PlayerHasAuraFromSpell(entry.id)
    elseif entry.kind == "item" then
        return not PlayerHasAuraFromItem(entry.id)
    end
    return false
end

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
        for _, entry in ipairs(db.watchList) do
            if ShouldGlow(entry) then
                local btn = entry.kind == "spell"
                    and FindButtonForSpell(entry.id)
                    or FindButtonForItem(entry.id)
                if btn then
                    ApplyGlow(btn)
                    activeGlows[entry.label .. entry.id] = btn
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
        if not db.watchList then db.watchList = {} end
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

-- ─── Slash commands ───────────────────────────────────────────────────────────

local function PrintHelp()
    print("|cff00ccff[BSA]|r Commands:")
    print("  |cffffff00/bsa addspell <id or name>|r  - watch a spell buff")
    print("  |cffffff00/bsa additem <id>|r            - watch an item buff")
    print("  |cffffff00/bsa remove <id>|r             - stop watching")
    print("  |cffffff00/bsa list|r                    - show watch list")
    print("  |cffffff00/bsa combat|r                  - toggle combat-only mode")
    print("  |cffffff00/bsa group|r                   - toggle group buff check")
    print("  |cffffff00/bsa alpha <0.1-1.0>|r         - set flash alpha")
    print("  |cffffff00/bsa color <r> <g> <b>|r       - set flash color (0-1 each)")
    print("  |cffffff00/bsa status|r                  - show current settings")
end

SLASH_BSALERT1 = "/bsa"
SLASH_BSALERT2 = "/battleshout"
SlashCmdList["BSALERT"] = function(msg)
    -- preserve original case for name lookup, lower only for cmd
    local origArg = (msg or ""):match("^%S+%s+(.*)$") or ""
    msg = (msg or ""):trim()
    local cmd, arg = msg:match("^(%S+)%s*(.*)$")
    cmd = cmd and cmd:lower() or ""

    if cmd == "addspell" then
        -- Try numeric ID first, then name lookup
        local id = tonumber(origArg)
        if not id then
            -- name lookup
            local found = FindSpellIDByName(origArg)
            if found then
                id = found
            else
                print("|cff00ccff[BSA]|r Spell not found in spellbook: |cffffff00" .. origArg .. "|r")
                print("  Try providing the numeric spell ID instead.")
                return
            end
        end
        local name = C_Spell.GetSpellName(id) or ("Spell " .. id)
        table.insert(db.watchList, { kind = "spell", id = id, label = name })
        print("|cff00ccff[BSA]|r Now watching: |cffffff00" .. name .. "|r (spell " .. id .. ")")
        ScheduleUpdate()
    elseif cmd == "additem" then
        local id = tonumber(origArg)
        if not id then
            print("|cff00ccff[BSA]|r Usage: /bsa additem <itemID>  (numeric ID only)")
            return
        end
        local name = C_Item.GetItemNameByID(id) or ("Item " .. id)
        table.insert(db.watchList, { kind = "item", id = id, label = name })
        print("|cff00ccff[BSA]|r Now watching: |cffffff00" .. name .. "|r (item " .. id .. ")")
        ScheduleUpdate()
    elseif cmd == "remove" then
        local id = tonumber(origArg)
        if not id then
            print("|cff00ccff[BSA]|r Usage: /bsa remove <id>")
            return
        end
        local removed = false
        for i = #db.watchList, 1, -1 do
            if db.watchList[i].id == id then
                print("|cff00ccff[BSA]|r Removed: |cffffff00" .. db.watchList[i].label .. "|r")
                table.remove(db.watchList, i)
                removed = true
            end
        end
        if not removed then
            print("|cff00ccff[BSA]|r No entry found with id " .. id)
        end
        ScheduleUpdate()
    elseif cmd == "list" then
        if #db.watchList == 0 then
            print("|cff00ccff[BSA]|r Watch list is empty.")
        else
            print("|cff00ccff[BSA]|r Watching " .. #db.watchList .. " buff(s):")
            for _, e in ipairs(db.watchList) do
                print(string.format("  [%s] |cffffff00%s|r  (id: %d)", e.kind, e.label, e.id))
            end
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
        print("|cff00ccff[BSA]|r Current settings:")
        print("  Combat-only: " .. tostring(db.onlyInCombat))
        print("  Group check: " .. tostring(db.checkGroup))
        print(string.format("  Flash alpha: %.2f", db.flashAlpha))
        print(string.format("  Flash color: r=%.2f g=%.2f b=%.2f", db.flashR, db.flashG, db.flashB))
        print("  Watching " .. #db.watchList .. " buff(s) — /bsa list for details")
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
