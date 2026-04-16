-- ✨️ Prep: Highlights missing configured actions on action bars.

local addonName, ns = ...

ns.Prep = CreateFrame("Frame")
local Prep = ns.Prep
Prep.name = addonName

Prep.defaults = {
	group = true,
	combat = false,
	flashAlpha = 1.0,
	flashR = 1.0,
	flashG = 0.3,
	flashB = 0.3,
	warnR = 1.0,
	warnG = 1.0,
	warnB = 0.3,
	slotBuff = nil,
	slotFood = nil,
	slotWeapon = nil,
	slotFlask = nil,
	slotRune = nil,
	slotPet = nil,
}
Prep.db = {}
Prep.isMatchActive = false
Prep.activeGlows = {}
Prep.pendingUpdate = false
Prep.pendingUpdateSlow = false
Prep.autoCombatPetSpellIDs = nil
Prep.needsPetRefresh = false
Prep.petRefreshAttempts = 0
Prep.petRefreshMaxAttempts = 12

function Prep:IsRestrictedMode()
	local pvpState = C_PvP.GetActiveMatchState()
	local isMatchInProgress = (pvpState == Enum.PvPMatchState.Engaged)

	if self.isMatchActive or isMatchInProgress or UnitOnTaxi("player") or
		(EditModeManagerFrame and EditModeManagerFrame:IsEditModeActive()) then
		return true
	end

	if InCombatLockdown() and not self.db.combat then
		return true
	end

	return false
end

-- ── Slot → button frame ───────────────────────────────────────────────────────

local BAR_RANGES = {
	{ 1,   12,  "ActionButton",              0 },
	{ 13,  24,  "ActionButton",              -12 },
	{ 25,  36,  "MultiBarRightButton",       -24 },
	{ 37,  48,  "MultiBarLeftButton",        -36 },
	{ 49,  60,  "MultiBarBottomRightButton", -48 },
	{ 61,  72,  "MultiBarBottomLeftButton",  -60 },
	{ 145, 156, "MultiBar5Button",           -144 },
	{ 157, 168, "MultiBar6Button",           -156 },
	{ 169, 180, "MultiBar7Button",           -168 },
}

function Prep:GetButtonForActionSlot(slot)
	for _, r in ipairs(BAR_RANGES) do
		if slot >= r[1] and slot <= r[2] then
			local btn = _G[r[3] .. (slot + r[4])]
			return btn and btn:IsVisible() and btn or nil
		end
	end
end

-- ── Find button on bar ────────────────────────────────────────────────────────

function Prep:FindButtonForType(matchType, matchID)
	local matchName = (matchType == "spell") and C_Spell.GetSpellName(matchID) or C_Item.GetItemNameByID(matchID)
	if not matchName then return end

	for s = 1, 180 do
		local t, id = GetActionInfo(s)

		if t then
			local found = false

			-- 1. Direct Match (Spell/Item dragged to bar)
			if t == matchType and id == matchID then
				found = true

				-- 2. Macro Match (The Issue #495 Workaround)
			elseif t == "macro" then
				-- Step A: Get the name written on the button (The "Label")
				local label = GetActionText(s)

				if label then
					-- Step B: Ask the game for the macro body using the NAME, not the ID
					local _, _, body = GetMacroInfo(label)

					if body and body:lower():find(matchName:lower(), 1, true) then
						found = true
					end
				end

				-- Step C: Fallback to standard API if Label search failed
				if not found then
					local _, link = GetMacroItem(id)
					local apiID = link and tonumber(link:match("item:(%d+)"))
					if apiID == matchID then found = true end
				end
			end

			if found then
				local btn = self:GetButtonForActionSlot(s)
				if btn then return btn end
			end
		end
	end
end

function Prep:FindButton(slot)
	if not slot then return nil end
	if slot.petGUID then
		for s = 1, 180 do
			local t, id = GetActionInfo(s)
			if t == "summonpet" and id == slot.petGUID then
				local btn = self:GetButtonForActionSlot(s)
				if btn then return btn end
			end
		end
	elseif slot.spellID then
		return self:FindButtonForType("spell", slot.spellID)
	elseif slot.itemID then
		if (C_Item.GetItemCount(slot.itemID) or 0) == 0 then return nil end
		return self:FindButtonForType("item", slot.itemID)
	end
end

-- ── Buff / aura checks ────────────────────────────────────────────────────────

function Prep:ShouldCheckGroupUnit(unit)
	if not UnitExists(unit) or not UnitIsConnected(unit) or UnitIsDeadOrGhost(unit) then
		return false
	end

	local inRange = UnitInRange(unit)
	if issecretvalue(inRange) then
		return false
	end

	return inRange
end

function Prep:AllGroupMembersHaveAura(hasAura)
	local n = GetNumGroupMembers()
	if n == 0 then return true end

	local pfx = IsInRaid() and "raid" or "party"
	for i = 1, n do
		local unit = pfx .. i
		if self:ShouldCheckGroupUnit(unit) and not hasAura(unit) then
			return false
		end
	end

	return true
end

function Prep:HasAura(name, group)
	-- Check if player has the aura. Always required.
	if not AuraUtil.FindAuraByName(name, "player", "HELPFUL") then return false end
	if group then
		return self:AllGroupMembersHaveAura(function(unit)
			return AuraUtil.FindAuraByName(name, unit, "HELPFUL") ~= nil
		end)
	end
	return true
end

function Prep:HasFlask()
	if not self.db.slotFlask or not self.db.slotFlask.itemID then return true end
	local name = C_Item.GetItemNameByID(self.db.slotFlask.itemID)
	if not name then return false end
	return AuraUtil.FindAuraByName(name, "player", "HELPFUL") ~= nil
end

local function FindPlayerHelpfulAura(matchFn)
	local i = 1
	while true do
		local aura = C_UnitAuras.GetAuraDataByIndex("player", i, "HELPFUL")
		if not aura then break end
		if matchFn(aura) then return aura end
		i = i + 1
	end
	return nil
end

local function GetRuneSearchTerm(itemID)
	if not itemID then return nil end
	local itemName = C_Item.GetItemNameByID(itemID)
	if not itemName then return nil end
	local searchTerm = itemName:lower():gsub("%s*%S+%s*$", ""):gsub("%s*%S+%s*$", "")
	if searchTerm == "" then return nil end
	return searchTerm
end

local function FindRuneAuraByItemID(itemID)
	local searchTerm = GetRuneSearchTerm(itemID)
	if not searchTerm then return nil end
	return FindPlayerHelpfulAura(function(aura)
		return aura.name and not issecretvalue(aura.name) and aura.name:lower():find(searchTerm, 1, true)
	end)
end

local function IsWeaponInOffhand()
	local ohItem = GetInventoryItemID("player", 17)
	if not ohItem then return false end
	local _, _, _, _, _, itemClassID = GetItemInfoInstant(ohItem)
	return itemClassID == Enum.ItemClass.Weapon
end

local function GetRequiredWeaponEnchantRemainSeconds()
	local hasMH, mhMs, _, _, hasOH, ohMs = GetWeaponEnchantInfo()
	if not hasMH then return nil end

	local minRemain = nil
	if mhMs and mhMs > 0 then
		minRemain = mhMs / 1000
	end

	if IsWeaponInOffhand() then
		if not hasOH then return nil end
		if ohMs and ohMs > 0 then
			local ohRemain = ohMs / 1000
			if not minRemain or ohRemain < minRemain then
				minRemain = ohRemain
			end
		end
	end

	return minRemain
end

function Prep:HasRune()
	if not self.db.slotRune or not self.db.slotRune.itemID then return true end
	return FindRuneAuraByItemID(self.db.slotRune.itemID) ~= nil
end

-- Each check function returns TRUE if the condition is MET (good), FALSE if MISSING (bad → glow).
-- Only checks that are configured in the DB (e.g., self.db.slotFlask is set) will be evaluated.
local checks = {
	{
		key = "slotBuff",
		fn = function()
			-- Check if player has the configured buff active.
			-- Return true if buff exists OR if no buff is configured.
			if not Prep.db.slotBuff or not Prep.db.slotBuff.spellID then return true end
			local name = C_Spell.GetSpellName(Prep.db.slotBuff.spellID)
			if not name then return true end -- Spell doesn't exist, don't glow
			return Prep:HasAura(name, Prep.db.group)
		end
	},
	{
		key = "slotFood",
		fn = function()
			return AuraUtil.FindAuraByName("Well Fed", "player", "HELPFUL") ~= nil
				or AuraUtil.FindAuraByName("Hearty Well Fed", "player", "HELPFUL") ~= nil
		end
	},
	{
		key = "slotWeapon",
		fn = function()
			return GetRequiredWeaponEnchantRemainSeconds() ~= nil
		end
	},
	{ key = "slotFlask", fn = function() return Prep:HasFlask() end },
	{ key = "slotRune",  fn = function() return Prep:HasRune() end },
	{
		key = "slotPet",
		fn = function()
			if not Prep.db.slotPet then return true end
			if not Prep.db.slotPet.petGUID then return false end
			local g = C_PetJournal.GetSummonedPetGUID()
			return g ~= nil and g ~= "" and g == Prep.db.slotPet.petGUID
		end
	},
}

local EXPIRING_WARNING_THRESHOLD = 180

local function FindPlayerHelpfulAuraByName(name)
	if not name or name == "" then return nil end
	return FindPlayerHelpfulAura(function(aura)
		return aura.name and not issecretvalue(aura.name) and aura.name == name
	end)
end

local function FindFoodAura()
	return FindPlayerHelpfulAuraByName("Well Fed") or FindPlayerHelpfulAuraByName("Hearty Well Fed")
end

local function GetSlotRemainingSeconds(key, s)
	if not s then return nil end

	if key == "slotWeapon" then
		return GetRequiredWeaponEnchantRemainSeconds()
	end

	local aura = nil
	if key == "slotBuff" and s.spellID then
		local spellName = C_Spell.GetSpellName(s.spellID)
		aura = spellName and FindPlayerHelpfulAuraByName(spellName) or nil
	elseif key == "slotFood" then
		aura = FindFoodAura()
	elseif key == "slotFlask" and s.itemID then
		local itemName = C_Item.GetItemNameByID(s.itemID)
		aura = itemName and FindPlayerHelpfulAuraByName(itemName) or nil
	elseif key == "slotRune" and s.itemID then
		aura = FindRuneAuraByItemID(s.itemID)
	end

	if not aura or not aura.expirationTime or aura.expirationTime <= 0 then return nil end
	local remain = aura.expirationTime - GetTime()
	if remain <= 0 then return nil end
	return remain
end

local function IsExpiringSoon(key, s)
	local remain = GetSlotRemainingSeconds(key, s)
	return remain ~= nil and remain < EXPIRING_WARNING_THRESHOLD
end

-- ── Auto combat pet (Hunter / Warlock / Death Knight) ─────────────────────────

local COMBAT_PET_SPELLS = {
	HUNTER      = { "Call Pet 1", "Call Pet 2", "Call Pet 3", "Call Pet 4", "Call Pet 5" },
	WARLOCK     = { "Summon Imp", "Summon Voidwalker", "Summon Succubus", "Summon Felhunter",
		"Summon Felguard", "Summon Incubus", "Summon Darkglare",
		"Summon Demonic Tyrant", "Summon Infernal", "Summon Sayaad" },
	DEATHKNIGHT = { "Raise Dead" },
}

Prep.COMBAT_PET_SPELLS = COMBAT_PET_SPELLS

function Prep:InitAutoCombatPet()
	local class = UnitClassBase("player")
	local spellNames = self.COMBAT_PET_SPELLS[class]
	if not spellNames then
		self.autoCombatPetSpellIDs = nil
		return
	end
	self.autoCombatPetSpellIDs = {}
	for _, name in ipairs(spellNames) do
		local id = C_Spell.GetSpellIDForSpellIdentifier and C_Spell.GetSpellIDForSpellIdentifier(name)
		if not id then
			for i = 1, 1000 do
				local info = C_SpellBook.GetSpellBookItemInfo(i, Enum.SpellBookSpellBank.Player)
				if not info then break end
				if info.spellID and C_Spell.GetSpellName(info.spellID) == name then
					id = info.spellID; break
				end
			end
		end
		if id and id > 0 then
			self.autoCombatPetSpellIDs[#self.autoCombatPetSpellIDs + 1] = id
		end
	end
end

function Prep:FindCombatPetButton()
	if not self.autoCombatPetSpellIDs or #self.autoCombatPetSpellIDs == 0 then return nil end
	for s = 1, 180 do
		local t, id = GetActionInfo(s)
		local spellID = (t == "spell") and id or (t == "macro" and GetMacroSpell(id))

		if spellID then
			for _, sid in ipairs(self.autoCombatPetSpellIDs) do
				if spellID == sid then
					local btn = self:GetButtonForActionSlot(s)
					if btn then return btn end
				end
			end
		end
	end
end

-- ── Glow ──────────────────────────────────────────────────────────────────────

function Prep:SetGlow(btn, show, r, g, b)
	if not btn then return end
	local cr = r or self.db.flashR
	local cg = g or self.db.flashG
	local cb = b or self.db.flashB
	for _, k in ipairs({ "SpellHighlightTexture", "Flash" }) do
		local t = btn[k]
		if t then
			if show then
				t:Show(); t:SetAlpha(self.db.flashAlpha); t:SetVertexColor(cr, cg, cb)
			else
				t:Hide(); t:SetVertexColor(1, 1, 1); t:SetAlpha(1)
			end
		end
	end
end

-- ── Main update ───────────────────────────────────────────────────────────────

function Prep:ClearGlows()
	for _, btn in pairs(self.activeGlows) do self:SetGlow(btn, false) end
	wipe(self.activeGlows)
end

function Prep:ScheduleUpdate()
	-- Fast update (0.1s cadence) triggered by combat/aura/bar changes.
	-- Only checks slots that are configured in the DB to avoid wasting CPU iterating all 180 bars.
	if self:IsRestrictedMode() then
		self:ClearGlows(); return
	end
	if self.pendingUpdate then return end
	self.pendingUpdate = true
	C_Timer.After(0.1, function()
		self.pendingUpdate = false
		if self:IsRestrictedMode() then
			self:ClearGlows()
			return
		end
		self:ClearGlows()
		-- Iterate checks and glow buttons for missing OR expiring-soon slots.
		for _, c in ipairs(checks) do
			if self.db[c.key] then
				local slotSetting = self.db[c.key]
				local btn = self:FindButton(slotSetting)
				if btn then
					local passed = c.fn()
					if not passed then
						self:SetGlow(btn, true)
						self.activeGlows[c.key] = btn
					elseif IsExpiringSoon(c.key, slotSetting) then
						self:SetGlow(btn, true, self.db.warnR, self.db.warnG, self.db.warnB)
						self.activeGlows[c.key] = btn
					end
				end
			end
		end
		-- Auto-summon pet: if class has combat pet summons and no pet is out, glow the summon button.
		if self.autoCombatPetSpellIDs and not UnitExists("pet") then
			local btn = self:FindCombatPetButton()
			if btn then
				self:SetGlow(btn, true)
				self.activeGlows["__combatPet"] = btn
			end
		end
	end)
end

function Prep:ScheduleUpdateSlow() -- Slower update (0.5s cadence) for less urgent checks like group member aura changes.
	-- Defers to the fast update if one is already pending to avoid doubling up work.
	if self:IsRestrictedMode() then
		self:ClearGlows(); return
	end
	if self.pendingUpdateSlow then return end
	self.pendingUpdateSlow = true
	C_Timer.After(0.5, function()
		self.pendingUpdateSlow = false
		if self.pendingUpdate then return end
		if self:IsRestrictedMode() then
			self:ClearGlows(); return
		end
		self:ScheduleUpdate()
	end)
end

-- ── Pet GUID re-resolution ────────────────────────────────────────────────────

function Prep:FindPetGUIDByName(search)
	search = search:lower()
	for i = 1, C_PetJournal.GetNumPets() do
		local guid, _, _, cn, _, _, _, sn = C_PetJournal.GetPetInfoByIndex(i)
		if guid then
			local cnl = cn and cn:lower() or ""
			local snl = sn and sn:lower() or ""
			if cnl == search or snl == search then
				local displayName = (cn and cn ~= "") and cn or sn
				return guid, displayName
			end
		end
	end
end

function Prep:RefreshPetGUID()
	-- Pet GUIDs become stale when you re-log, switch specs, or change pet.
	-- This function re-resolves the pet by NAME against the current journal to get a fresh GUID.
	-- Useful after talent swaps or when the stored GUID no longer exists.
	if not self.db.slotPet then return true end
	local lookupName = self.db.slotPet.petName
	if not lookupName then
		-- If no name stored, try to extract it from the old GUID (if it still exists in journal).
		if self.db.slotPet.petGUID then
			local _, cn, _, _, _, _, _, sn = C_PetJournal.GetPetInfoByPetID(self.db.slotPet.petGUID)
			lookupName = (cn and cn ~= "") and cn or sn
		end
		if not lookupName then
			-- Journal data may not be fully available yet; let retry logic handle this.
			return false
		end
	end

	-- Fuzzy-match the name in the current journal to find the fresh GUID.
	local freshGUID = self:FindPetGUIDByName(lookupName)
	if freshGUID then
		self.db.slotPet.petGUID = freshGUID
		return true
	end
	return false
end

function Prep:AttemptPetRefresh()
	if not self.needsPetRefresh then return end
	if not self.db.slotPet then
		self.needsPetRefresh = false
		self.petRefreshAttempts = 0
		return
	end

	self.petRefreshAttempts = (self.petRefreshAttempts or 0) + 1
	if self:RefreshPetGUID() then
		self.needsPetRefresh = false
		self.petRefreshAttempts = 0
		return
	end

	if self.petRefreshAttempts >= (self.petRefreshMaxAttempts or 12) then
		local failedName = self.db.slotPet.petName or "(unknown)"
		self.db.slotPet = nil
		self.needsPetRefresh = false
		self.petRefreshAttempts = 0
		print("|cff00ccff[Prep]|r Pet '" .. failedName .. "' no longer found after journal sync, cleared.")
		return
	end

	-- Retry with a short delay while the pet journal continues to populate after login.
	C_Timer.After(0.5, function()
		if Prep.needsPetRefresh then
			Prep:AttemptPetRefresh()
		end
	end)
end

Prep:RegisterEvent("ADDON_LOADED")
Prep:RegisterEvent("PLAYER_ENTERING_WORLD")
Prep:RegisterEvent("CHALLENGE_MODE_START")
Prep:RegisterEvent("CHALLENGE_MODE_COMPLETED")
Prep:RegisterEvent("CHALLENGE_MODE_RESET")
Prep:RegisterEvent("PVP_MATCH_ACTIVE")
Prep:RegisterEvent("PVP_MATCH_COMPLETE")
Prep:RegisterEvent("PVP_MATCH_STATE_CHANGED")
Prep:RegisterEvent("ZONE_CHANGED_NEW_AREA")
Prep:SetScript("OnEvent", function(self, event, arg1)
	if event == "ADDON_LOADED" then
		if arg1 ~= Prep.name then return end
		PrepDB = PrepDB or {}
		Prep.db = PrepDB
		for k, v in pairs(Prep.defaults) do if Prep.db[k] == nil then Prep.db[k] = v end end
		Prep.needsPetRefresh = true
		Prep.petRefreshAttempts = 0
		Prep:InitAutoCombatPet()
		for _, e in ipairs({
			"EDIT_MODE_LAYOUTS_UPDATED",
			"ACTIVE_TALENT_GROUP_CHANGED",
			"PLAYER_REGEN_ENABLED",
			"PLAYER_REGEN_DISABLED",
			"UNIT_AURA",
			"ACTIONBAR_SLOT_CHANGED",
			"GROUP_ROSTER_UPDATE",
			"PLAYER_EQUIPMENT_CHANGED",
			"UNIT_FLAGS",
			"UNIT_PET",
			"PET_JOURNAL_LIST_UPDATE",
			"ACTIONBAR_PAGE_CHANGED",
		}) do self:RegisterEvent(e) end
		self:UnregisterEvent("ADDON_LOADED")
	elseif event == "PLAYER_ENTERING_WORLD" then
		Prep.isMatchActive = false
		if Prep.needsPetRefresh then
			C_Timer.After(1.0, function()
				if Prep.needsPetRefresh then
					Prep:AttemptPetRefresh()
				end
			end)
		end
		Prep:ScheduleUpdate()
	elseif event == "CHALLENGE_MODE_START" then
		Prep.isMatchActive = true
		Prep:ClearGlows()
	elseif event == "PVP_MATCH_ACTIVE" then
		-- Arena/BG activation happens during Preparation; keep updates allowed until Engaged state.
		Prep:ScheduleUpdate()
	elseif event == "CHALLENGE_MODE_COMPLETED" or event == "CHALLENGE_MODE_RESET" or event == "PVP_MATCH_COMPLETE" then
		Prep.isMatchActive = false
		Prep:ScheduleUpdate()
	elseif event == "PVP_MATCH_STATE_CHANGED" or event == "ZONE_CHANGED_NEW_AREA" then
		-- Force a re-check of the restricted mode
		Prep:ScheduleUpdate()
	elseif event == "PLAYER_REGEN_DISABLED" then
		if not Prep.db.combat then
			Prep:ClearGlows()
		else
			Prep:ScheduleUpdate()
		end
	elseif event == "PLAYER_REGEN_ENABLED" then
		C_Timer.After(1.0, function()
			if not Prep:IsRestrictedMode() then Prep:ScheduleUpdate() end
		end)
	elseif event == "PET_JOURNAL_LIST_UPDATE" then
		if Prep.needsPetRefresh then
			Prep:AttemptPetRefresh()
		end
		Prep:ScheduleUpdate()
	elseif event == "UNIT_AURA" then
		if arg1 == "player" then
			Prep:ScheduleUpdate()
		elseif Prep.db.group and (arg1:find("party") or arg1:find("raid")) then
			Prep:ScheduleUpdateSlow()
		end
	elseif event == "ACTIVE_TALENT_GROUP_CHANGED" then
		Prep:InitAutoCombatPet()
		Prep:ScheduleUpdate()
	elseif event == "UNIT_FLAGS" then
		if arg1 == "player" then
			if UnitOnTaxi("player") then
				Prep:ClearGlows()
			else
				Prep:ScheduleUpdate()
			end
		elseif Prep.db.group and (arg1:find("party") or arg1:find("raid")) then
			Prep:ScheduleUpdateSlow()
		end
	elseif event == "EDIT_MODE_LAYOUTS_UPDATED" then
		Prep:ScheduleUpdate()
	else
		Prep:ScheduleUpdate()
	end
end)

local function FindSpellIDByName(search)
	-- Search the player's spellbook for a spell by name.
	-- Returns the spell ID if found, or nil if not found (spell not learned or typo).
	search = search:lower()
	for i = 1, 1000 do
		local info = C_SpellBook.GetSpellBookItemInfo(i, Enum.SpellBookSpellBank.Player)
		if not info then break end
		if info.spellID and info.spellID > 0 then
			local name = C_Spell.GetSpellName(info.spellID)
			if name and name:lower() == search then return info.spellID end
		end
	end
	-- Fallback: try the newer spell identifier API.
	if C_Spell.GetSpellIDForSpellIdentifier then
		local id = C_Spell.GetSpellIDForSpellIdentifier(search)
		if id and id > 0 then return id end
	end
	-- Not found.
	return nil
end

local function FindItemIDByName(search)
	-- Search the player's inventory for an item by name.
	-- Returns the item ID if found, or nil if not in bags (not looted or wrong name).
	search = search:lower()
	for bag = 0, NUM_BAG_SLOTS do
		for slot = 1, C_Container.GetContainerNumSlots(bag) do
			local info = C_Container.GetContainerItemInfo(bag, slot)
			if info and info.itemID then
				local name = C_Item.GetItemNameByID(info.itemID)
				if name and name:lower() == search then return info.itemID end
			end
		end
	end
	-- Not found.
	return nil
end

local function ParseItemArg(arg)
	return tonumber(arg:match("|Hitem:(%d+):")) or
		tonumber(arg:match("^%[(.+)%]$") and arg:match("^%[(.+)%]$") or arg) or
		FindItemIDByName(arg)
end

local function ParseSpellArg(arg)
	return tonumber(arg:match("|Hspell:(%d+)")) or tonumber(arg) or FindSpellIDByName(arg)
end

-- ── Icon helpers ──────────────────────────────────────────────────────────────

local ICON_SIZE = 16

local function IconTag(tex)
	if not tex then return "" end
	return ("|T%s:%d|t "):format(tex, ICON_SIZE)
end

local function SpellIcon(id) return IconTag(id and C_Spell.GetSpellTexture(id)) end
local function ItemIcon(id) return IconTag(id and select(10, GetItemInfo(id))) end
local function PetIcon(guid)
	if not guid then return "" end
	local _, _, _, _, _, _, _, _, icon = C_PetJournal.GetPetInfoByPetID(guid)
	return IconTag(icon)
end

-- ── Status display ────────────────────────────────────────────────────────────

local function FormatRemainingShort(seconds)
	if not seconds or seconds <= 0 then return nil end
	local s = math.floor(seconds + 0.5)
	if s < 1 then s = 1 end
	if s >= 3600 then
		local h = math.floor(s / 3600)
		local m = math.floor((s % 3600) / 60)
		return ("%dh %02dm"):format(h, m)
	end
	if s >= 60 then
		return ("%dm"):format(math.floor(s / 60))
	end
	return ("%ds"):format(s)
end

local function StatusDurationSuffix(key, s)
	local remain = GetSlotRemainingSeconds(key, s)
	local txt = FormatRemainingShort(remain)
	if not txt then return "" end
	return " |cffaaaaaa(" .. txt .. " left)|r"
end

local function ShouldShowRuneCount(itemID)
	if not itemID then return false end
	local stackCount = select(8, GetItemInfo(itemID))
	if stackCount and stackCount > 1 then return true end
	local _, _, _, _, _, classID = GetItemInfoInstant(itemID)
	return classID == Enum.ItemClass.Consumable
end

local function StatusCountSuffix(key, s)
	if not s.itemID then return "" end
	if key == "slotRune" and not ShouldShowRuneCount(s.itemID) then return "" end
	local count = C_Item.GetItemCount(s.itemID)
	if not count then return "" end
	return " |cffaaaaaa[x" .. count .. "]|r"
end

local function StatusMarker(isConfigured, passed)
	if not isConfigured then return "" end
	return passed and "|cff00ff00[OK]|r " or "|cffff4444[MISS]|r "
end

local function EvaluateSlotState(key)
	local s = Prep.db[key]
	if not s then
		return { configured = false, passed = true, countSuffix = "", durationSuffix = "", buttonSuffix = "" }
	end
	local passed = true
	for _, c in ipairs(checks) do
		if c.key == key then
			passed = c.fn()
			break
		end
	end
	local btn = Prep:FindButton(s)
	local buttonFound = btn ~= nil
	local buttonSuffix = (not buttonFound) and " |cffff8888[no button]|r" or ""
	return {
		configured = true,
		passed = passed,
		countSuffix = StatusCountSuffix(key, s),
		durationSuffix = StatusDurationSuffix(key, s),
		buttonSuffix = buttonSuffix,
	}
end

local function SlotStatus(key, label)
	local s = Prep.db[key]
	if not s then return label .. ": |cffaaaaaa(not set)|r" end
	local state = EvaluateSlotState(key)
	local marker = StatusMarker(state.configured, state.passed)
	if s.petGUID then
		local link = C_PetJournal.GetBattlePetLink(s.petGUID)
		if not link then
			local _, customName, _, _, _, _, _, speciesName = C_PetJournal.GetPetInfoByPetID(s.petGUID)
			local name = (customName and customName ~= "") and customName or speciesName or "unknown"
			link = "|cffffff00" .. name .. "|r"
		end
		return label .. ": " .. marker .. PetIcon(s.petGUID) .. link .. state.buttonSuffix, state.configured, state.passed
	elseif s.spellID then
		local link = C_Spell.GetSpellLink(s.spellID) or ("|cffffff00" .. (C_Spell.GetSpellName(s.spellID) or ("spell " .. s.spellID)) .. "|r")
		return label .. ": " .. marker .. SpellIcon(s.spellID) .. link .. state.durationSuffix .. state.buttonSuffix, state.configured, state.passed
	elseif s.itemID then
		local link = select(2, GetItemInfo(s.itemID)) or ("|cffffff00" .. (C_Item.GetItemNameByID(s.itemID) or ("item " .. s.itemID)) .. "|r")
		return label .. ": " .. marker .. ItemIcon(s.itemID) .. link .. state.countSuffix .. state.durationSuffix .. state.buttonSuffix, state.configured, state.passed
	end
	return label .. ": " .. marker .. "|cffff4444(unknown)|r" .. state.buttonSuffix, state.configured, state.passed
end

local function ShowStatus()
	print("|cff00ccff[Prep]|r Current settings (Group: " .. tostring(Prep.db.group) .. " | Combat: " .. tostring(Prep.db.combat) .. "):")
	local missing = {}
	for _, t in ipairs({
		{ "slotBuff",  "Buff" }, { "slotFood", "Food" }, { "slotWeapon", "Weapon" },
		{ "slotFlask", "Flask" }, { "slotRune", "Rune" }, { "slotPet", "Pet" },
	}) do
		local line, configured, passed = SlotStatus(t[1], t[2])
		print("  " .. line)
		if configured and not passed then
			missing[#missing + 1] = t[2]
		end
	end
	if #missing > 0 then
		print("  Missing: |cffff4444" .. table.concat(missing, ", ") .. "|r")
	else
		print("  |cff00ff00All good!|r")
	end
	if Prep.autoCombatPetSpellIDs then
		print("  Combat pet: |cff00ff00auto (enabled)|r")
	end
end

-- ── Slash commands ────────────────────────────────────────────────────────────

local function PrintHelp()
	print("|cff00ccff[Prep]|r Commands (unique prefix shorthand works, e.g. /prep st, /prep b):")
	for _, l in ipairs({
		"/prep buff <spell id/name/link>",
		"/prep food <item id/name/link>",
		"/prep weapon <item id/name/link>",
		"/prep flask <item id/name/link>",
		"/prep rune <item id/name/link>",
		"/prep pet <name>",
		"/prep clear <buff/food/weapon/flask/rune/pet>  (combat pet is automatic)",
		"/prep reset",
		"/prep group - toggle check group buff",
		"/prep combat - toggle enabled in combat (not m+ or pvp)",
		"/prep alpha <0.1-1.0>",
		"/prep color <r> <g> <b>  (0.0-1.0)",
		"/prep status",
	}) do print("  |cffffff00" .. l .. "|r") end
end

local ALL_CMDS = {
	"buff", "food", "weapon", "flask", "rune", "pet", "clear", "reset", "group", "combat", "alpha", "color", "status",
}

local function ResolveCmd(input)
	if input == "" then return nil end
	local matches = {}
	for _, c in ipairs(ALL_CMDS) do
		if c:sub(1, #input) == input then matches[#matches + 1] = c end
	end
	if #matches == 1 then return matches[1] end
	if #matches > 1 then
		for _, c in ipairs(matches) do if c == input then return c end end
		print("|cff00ccff[Prep]|r Ambiguous: '|cffffff00" .. input .. "|r' matches: " .. table.concat(matches, ", "))
		return false
	end
	return nil
end

local itemSlots = { food = "slotFood", weapon = "slotWeapon", flask = "slotFlask", rune = "slotRune" }

SLASH_PREP1 = "/prep"
SlashCmdList["PREP"] = function(msg)
	local origMsg = (msg or ""):trim()
	local rawCmd, origArg = origMsg:match("^(%S+)%s*(.*)$")
	rawCmd = rawCmd and rawCmd:lower() or ""
	local arg = origArg and origArg:lower() or ""

	local cmd = ResolveCmd(rawCmd)
	if cmd == false then return end
	if cmd == nil then
		PrintHelp(); return
	end

	if itemSlots[cmd] then
		if origArg == "" then
			print("|cff00ccff[Prep]|r Usage: /prep " .. cmd .. " <item id, name, or link>"); return
		end
		local id = ParseItemArg(origArg)
		if not id then
			print("|cff00ccff[Prep]|r Item not found: |cffffff00" .. origArg .. "|r  (must be in bags)"); return
		end
		Prep.db[itemSlots[cmd]] = { itemID = id }
		local link = select(2, GetItemInfo(id)) or ("|cffffff00" .. (C_Item.GetItemNameByID(id) or tostring(id)) .. "|r")
		local label = (cmd or ""):sub(1, 1):upper() .. (cmd or ""):sub(2)
		print("|cff00ccff[Prep]|r " .. label .. " set to: " .. ItemIcon(id) .. link)
		Prep:ScheduleUpdate()
	elseif cmd == "buff" then
		if origArg == "" then
			print("|cff00ccff[Prep]|r Usage: /prep buff <spell id, name, or link>"); return
		end
		local id = ParseSpellArg(origArg)
		if not id then
			print("|cff00ccff[Prep]|r Spell not found: |cffffff00" .. origArg .. "|r"); return
		end
		Prep.db.slotBuff = { spellID = id }
		local link = C_Spell.GetSpellLink(id) or ("|cffffff00" .. (C_Spell.GetSpellName(id) or tostring(id)) .. "|r")
		print("|cff00ccff[Prep]|r Buff set to: " .. SpellIcon(id) .. link)
		Prep:ScheduleUpdate()
	elseif cmd == "pet" then
		if origArg == "" then
			print("|cff00ccff[Prep]|r Usage: /prep pet <name>"); return
		end
		local guid, name = Prep:FindPetGUIDByName(origArg)
		if not guid then
			print("|cff00ccff[Prep]|r Pet not found: |cffffff00" .. origArg .. "|r"); return
		end
		Prep.db.slotPet = { petGUID = guid, petName = origArg }
		local petLink = C_PetJournal.GetBattlePetLink(guid) or ("|cffffff00" .. name .. "|r")
		print("|cff00ccff[Prep]|r Pet set to: " .. PetIcon(guid) .. petLink)
		Prep:ScheduleUpdate()
	elseif cmd == "clear" then
		local k = "slot" .. arg:sub(1, 1):upper() .. arg:sub(2)
		if Prep.db[k] ~= nil then
			Prep.db[k] = nil
			print("|cff00ccff[Prep]|r Cleared: " .. arg)
			Prep:ScheduleUpdate()
		else
			print("|cff00ccff[Prep]|r Unknown slot: " .. arg .. "  (buff/food/weapon/flask/rune/pet)")
		end
	elseif cmd == "reset" then
		Prep:ClearGlows()
		wipe(PrepDB)
		for k, v in pairs(Prep.defaults) do PrepDB[k] = v end
		C_Timer.After(0.2, function()
			Prep:ScheduleUpdate(); ShowStatus()
		end)
		print("|cff00ccff[Prep]|r All settings reset to defaults")
	elseif cmd == "group" then
		Prep.db.group = not Prep.db.group
		print("|cff00ccff[Prep]|r Group buff check: " .. (Prep.db.group and "|cff00ff00ON|r" or "|cffff4444OFF|r"))
		Prep:ScheduleUpdate()
	elseif cmd == "alpha" then
		local v = tonumber(origArg)
		if not v or v < 0.1 or v > 1.0 then
			print("|cff00ccff[Prep]|r Usage: /prep alpha <0.1-1.0>"); return
		end
		Prep.db.flashAlpha = v
		print("|cff00ccff[Prep]|r Alpha set to " .. v)
		Prep:ScheduleUpdate()
	elseif cmd == "color" then
		local r, g, b = origArg:match("^(%S+)%s+(%S+)%s+(%S+)$")
		r, g, b = tonumber(r), tonumber(g), tonumber(b)
		if not r or not g or not b then
			print("|cff00ccff[Prep]|r Usage: /prep color <r> <g> <b>"); return
		end
		Prep.db.flashR, Prep.db.flashG, Prep.db.flashB = r, g, b
		print(("|cff00ccff[Prep]|r Color set to %.2f %.2f %.2f"):format(r, g, b))
		Prep:ScheduleUpdate()
	elseif cmd == "status" then
		ShowStatus()
	elseif cmd == "combat" then
		Prep.db.combat = not Prep.db.combat
		local state = Prep.db.combat and "|cff00ff00Enabled|r" or "|cffff4444Disabled|r"
		print("|cff00ccff[Prep]|r Combat: " .. state)
		Prep:ScheduleUpdate()
	else
		PrintHelp()
	end
end
