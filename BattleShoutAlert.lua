-- BattleShoutAlert
-- Applies a native WoW proc glow to the Battle Shout action button when the buff is missing.
-- Compatible with WoW: The War Within / Midnight

local ADDON_NAME = "BattleShoutAlert"
local BATTLE_SHOUT_ID = 6673

local defaults = {
    onlyInCombat = false,
    checkGroup   = true,
}

local db
local glowActive = false
local currentGlowButton = nil  -- the actual action button frame we're glowing

-- ─── Helpers ─────────────────────────────────────────────────────────────────

local function HasBattleShout()
    local name = C_Spell.GetSpellName(BATTLE_SHOUT_ID)
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

local function ShouldGlow()
    if db.onlyInCombat and not InCombatLockdown() then return false end
    return not HasBattleShout()
end

-- ─── Find the action button for Battle Shout ─────────────────────────────────
-- Scans all visible action bar buttons for one whose action resolves to Battle Shout.

local slotToButtonName = {
    -- Main bar
    [1]="ActionButton1",[2]="ActionButton2",[3]="ActionButton3",[4]="ActionButton4",
    [5]="ActionButton5",[6]="ActionButton6",[7]="ActionButton7",[8]="ActionButton8",
    [9]="ActionButton9",[10]="ActionButton10",[11]="ActionButton11",[12]="ActionButton12",
    -- MultiBarBottomLeft (slots 13-24)
    [13]="MultiBarBottomLeftButton1",[14]="MultiBarBottomLeftButton2",
    [15]="MultiBarBottomLeftButton3",[16]="MultiBarBottomLeftButton4",
    [17]="MultiBarBottomLeftButton5",[18]="MultiBarBottomLeftButton6",
    [19]="MultiBarBottomLeftButton7",[20]="MultiBarBottomLeftButton8",
    [21]="MultiBarBottomLeftButton9",[22]="MultiBarBottomLeftButton10",
    [23]="MultiBarBottomLeftButton11",[24]="MultiBarBottomLeftButton12",
    -- MultiBarBottomRight (slots 25-36)
    [25]="MultiBarBottomRightButton1",[26]="MultiBarBottomRightButton2",
    [27]="MultiBarBottomRightButton3",[28]="MultiBarBottomRightButton4",
    [29]="MultiBarBottomRightButton5",[30]="MultiBarBottomRightButton6",
    [31]="MultiBarBottomRightButton7",[32]="MultiBarBottomRightButton8",
    [33]="MultiBarBottomRightButton9",[34]="MultiBarBottomRightButton10",
    [35]="MultiBarBottomRightButton11",[36]="MultiBarBottomRightButton12",
    -- MultiBarRight (slots 37-48)
    [37]="MultiBarRightButton1",[38]="MultiBarRightButton2",
    [39]="MultiBarRightButton3",[40]="MultiBarRightButton4",
    [41]="MultiBarRightButton5",[42]="MultiBarRightButton6",
    [43]="MultiBarRightButton7",[44]="MultiBarRightButton8",
    [45]="MultiBarRightButton9",[46]="MultiBarRightButton10",
    [47]="MultiBarRightButton11",[48]="MultiBarRightButton12",
    -- MultiBarLeft (slots 49-60)
    [49]="MultiBarLeftButton1",[50]="MultiBarLeftButton2",
    [51]="MultiBarLeftButton3",[52]="MultiBarLeftButton4",
    [53]="MultiBarLeftButton5",[54]="MultiBarLeftButton6",
    [55]="MultiBarLeftButton7",[56]="MultiBarLeftButton8",
    [57]="MultiBarLeftButton9",[58]="MultiBarLeftButton10",
    [59]="MultiBarLeftButton11",[60]="MultiBarLeftButton12",
}
-- MultiBar5-7 (TWW+)
for i = 1, 12 do
    slotToButtonName[144 + i] = "MultiBar5Button" .. i
    slotToButtonName[156 + i] = "MultiBar6Button" .. i
    slotToButtonName[168 + i] = "MultiBar7Button" .. i
end

local function FindBattleShoutButton()
    for slot, btnName in pairs(slotToButtonName) do
        local actionType, id = GetActionInfo(slot)
        if actionType == "spell" and id == BATTLE_SHOUT_ID then
            local btn = _G[btnName]
            if btn and btn:IsVisible() then
                return btn
            end
        end
    end
    return nil
end

-- ─── Glow API ────────────────────────────────────────────────────────────────
-- Uses Blizzard's built-in ActionButton_ShowOverlayGlow / ActionButton_HideOverlayGlow,
-- the same pulse animation used for proc highlights (yellow by default).
-- We tint it red so it's clearly "missing buff" rather than "proc ready".

local function ApplyGlow(button)
    if not button then return end
    ActionButton_ShowOverlayGlow(button)
    -- Tint overlay red (default is yellow/gold)
    if button.overlay then
        button.overlay:SetVertexColor(1, 0.1, 0.1, 1)
    end
    currentGlowButton = button
    glowActive = true
end

local function RemoveGlow()
    if currentGlowButton then
        ActionButton_HideOverlayGlow(currentGlowButton)
        -- Restore default white tint (Blizzard multiplies this with the texture)
        if currentGlowButton.overlay then
            currentGlowButton.overlay:SetVertexColor(1, 1, 1, 1)
        end
    end
    currentGlowButton = nil
    glowActive = false
end

-- ─── Main update ─────────────────────────────────────────────────────────────

local pendingUpdate = false
local function ScheduleUpdate()
    if pendingUpdate then return end
    pendingUpdate = true
    C_Timer.After(0.1, function()
        pendingUpdate = false
        local btn = FindBattleShoutButton()
        if btn and ShouldGlow() then
            if currentGlowButton ~= btn then RemoveGlow() end
            ApplyGlow(btn)
        else
            RemoveGlow()
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

SLASH_BSALERT1 = "/bsa"
SLASH_BSALERT2 = "/battleshout"

SlashCmdList["BSALERT"] = function(msg)
    msg = (msg or ""):lower():trim()
    if msg == "combat" then
        db.onlyInCombat = not db.onlyInCombat
        print("|cff00ccff[BattleShoutAlert]|r Combat-only: " .. (db.onlyInCombat and "|cff00ff00ON|r" or "|cffff4444OFF|r"))
        ScheduleUpdate()
    elseif msg == "group" then
        db.checkGroup = not db.checkGroup
        print("|cff00ccff[BattleShoutAlert]|r Check group: " .. (db.checkGroup and "|cff00ff00ON|r" or "|cffff4444OFF|r"))
        ScheduleUpdate()
    elseif msg == "test" then
        local btn = FindBattleShoutButton()
        if btn then
            if glowActive then RemoveGlow() else ApplyGlow(btn) end
        else
            print("|cff00ccff[BattleShoutAlert]|r Battle Shout not found on any visible action bar.")
        end
    else
        print("|cff00ccff[BattleShoutAlert]|r Commands:")
        print("  |cffffff00/bsa test|r    - Toggle glow preview")
        print("  |cffffff00/bsa combat|r  - Toggle combat-only mode")
        print("  |cffffff00/bsa group|r   - Toggle group aura check")
    end
end
