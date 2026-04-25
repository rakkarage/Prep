-- ✨️ Prep: Highlights missing configured actions on action bars.

local _addonName = ...

local _frame = CreateFrame("Frame")

local _defaults = {
	group = true,
	combat = true,
	flashR = 1.0,
	flashG = 0.3,
	flashB = 0.3,
	flashA = 1.0,
	warnR = 1.0,
	warnG = 1.0,
	warnB = 0.3,
	warnA = 1.0,
	slotBuff = nil,
	slotFood = nil,
	slotWeapon = nil,
	slotFlask = nil,
	slotRune = nil,
	slotPet = nil,
}

local _isMatchActive = false
local _activeGlows = {}
local _pendingUpdate = false
local _pendingUpdateSlow = false
local _autoCombatPetSpellIDs = nil
local _needsPetRefresh = false
local _petRefreshAttempts = 0
local _petRefreshMaxAttempts = 12

-- ── Slot cache: raw action data ───────────────────────────────────────────────
-- slotCache[s] = { type=t, id=id } for s in 1..180
-- Only rebuilt on structural bar changes (login, page flip, talent swap).
-- ACTIONBAR_SLOT_CHANGED updates individual entries and bails early if unchanged.
local _slotCache = {}
local _slotCacheDirty = true

-- ── Button cache: resolved frame references ───────────────────────────────────
-- buttonCache["slotBuff"] = frame (or false if not found)
-- Rebuilt lazily on next ScheduleUpdate tick after any bar change.
-- Avoids re-scanning 180 slots × N configured slots on every update.
local _buttonCache = {}
local _buttonCacheDirty = true

local _itemSlots = { food = "slotFood", weapon = "slotWeapon", flask = "slotFlask", rune = "slotRune" }

local EXPIRING_WARNING_THRESHOLD = 180
local NUM_BUTTONS = 180
local ICON_SIZE = 16
local ALL_CMDS = {
	"buff", "food", "weapon", "flask", "rune", "pet", "clear", "reset", "group", "combat", "alpha", "color", "warncolor", "status",
}
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
local COMBAT_PET_SPELLS = {
	HUNTER      = { "Call Pet 1", "Call Pet 2", "Call Pet 3", "Call Pet 4", "Call Pet 5" },
	WARLOCK     = { "Summon Imp", "Summon Voidwalker", "Summon Succubus", "Summon Felhunter",
		"Summon Felguard", "Summon Incubus", "Summon Darkglare",
		"Summon Demonic Tyrant", "Summon Infernal", "Summon Sayaad" },
	DEATHKNIGHT = { "Raise Dead" },
}

-- ── Slot cache ────────────────────────────────────────────────────────────────

local function RebuildSlotCache()
	wipe(_slotCache)
	for s = 1, NUM_BUTTONS do
		local t, id = GetActionInfo(s)
		if t then _slotCache[s] = { type = t, id = id } end
	end
	_slotCacheDirty = false
end

local function GetCachedActionInfo(s)
	if _slotCacheDirty then RebuildSlotCache() end
	local e = _slotCache[s]
	return e and e.type, e and e.id
end

local function IsRestrictedMode()
	return _isMatchActive
		or (C_PvP.GetActiveMatchState() == Enum.PvPMatchState.Engaged)
		or (EditModeManagerFrame and EditModeManagerFrame:IsEditModeActive())
		or (InCombatLockdown() and not PrepDB.combat)
		or UnitIsDeadOrGhost("player")
		or UnitOnTaxi("player")
end

local function GetMacroSpellID(macroID)
	local spellID = GetMacroSpell(macroID)
	if spellID and spellID > 0 then
		return spellID
	end
	return nil
end

local function IsBonusBarSlot(slot)
	return slot >= 121 and slot <= 144
end

local function IsSlotActiveForCurrentBar(slot)
	if HasBonusActionBar() then
		return IsBonusBarSlot(slot)
	end
	return not IsBonusBarSlot(slot)
end

local function GetPrimaryBarButtonForBonusSlot(slot)
	local buttonIndex
	if slot >= 121 and slot <= 132 then
		buttonIndex = slot - 120
	elseif slot >= 133 and slot <= 144 then
		buttonIndex = slot - 132
	end
	if not buttonIndex then return nil end
	local btn = _G["ActionButton" .. buttonIndex]
	return btn and btn:IsVisible() and btn or nil
end

local function GetButtonForActionSlot(slot)
	if IsBonusBarSlot(slot) then
		return GetPrimaryBarButtonForBonusSlot(slot)
	end
	for _, r in ipairs(BAR_RANGES) do
		if slot >= r[1] and slot <= r[2] then
			local btn = _G[r[3] .. (slot + r[4])]
			return btn and btn:IsVisible() and btn or nil
		end
	end
end

-- ── Aura helpers ──────────────────────────────────────────────────────────────

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

local function FindPlayerHelpfulAuraByName(name)
	if not name or name == "" then return nil end
	return FindPlayerHelpfulAura(function(aura)
		return aura.name and not issecretvalue(aura.name) and aura.name == name
	end)
end

local function FindFoodAura()
	return FindPlayerHelpfulAuraByName("Well Fed") or FindPlayerHelpfulAuraByName("Hearty Well Fed")
end

-- ── Group helpers ─────────────────────────────────────────────────────────────

local function ShouldCheckGroupUnit(unit)
	if not UnitExists(unit) or not UnitIsConnected(unit) or UnitIsDeadOrGhost(unit) then
		return false
	end

	local inRange = UnitInRange(unit)
	if issecretvalue(inRange) then
		return false
	end

	return inRange
end

local function AllGroupMembersHaveAura(hasAura)
	local n = GetNumGroupMembers()
	if n == 0 then return true end

	local pfx = IsInRaid() and "raid" or "party"
	for i = 1, n do
		local unit = pfx .. i
		if ShouldCheckGroupUnit(unit) and not hasAura(unit) then
			return false
		end
	end

	return true
end

-- ── Buff/consumable checks ────────────────────────────────────────────────────

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

local function HasRune()
	if not PrepDB.slotRune or not PrepDB.slotRune.itemID then return true end
	return FindRuneAuraByItemID(PrepDB.slotRune.itemID) ~= nil
end

local function HasAura(name, group)
	if not FindPlayerHelpfulAuraByName(name) then return false end
	if group then
		return AllGroupMembersHaveAura(function(unit)
			return AuraUtil.FindAuraByName(name, unit, "HELPFUL") ~= nil
		end)
	end
	return true
end

local function HasFlask()
	if not PrepDB.slotFlask or not PrepDB.slotFlask.itemID then return true end
	local name = C_Item.GetItemNameByID(PrepDB.slotFlask.itemID)
	if not name then return false end
	return FindPlayerHelpfulAuraByName(name) ~= nil
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

-- Each check function returns TRUE if the condition is MET (good), FALSE if MISSING (bad → glow).
-- Only checks that are configured in the DB (e.g., PrepDB.slotFlask is set) will be evaluated.
local checks = {
	{
		key = "slotBuff",
		fn = function()
			if not PrepDB.slotBuff or not PrepDB.slotBuff.spellID then return true end
			local name = C_Spell.GetSpellName(PrepDB.slotBuff.spellID)
			if not name then return true end
			return HasAura(name, PrepDB.group)
		end
	},
	{
		key = "slotFood",
		fn = function()
			return FindPlayerHelpfulAuraByName("Well Fed") ~= nil
				or FindPlayerHelpfulAuraByName("Hearty Well Fed") ~= nil
		end
	},
	{
		key = "slotWeapon",
		fn = function()
			return GetRequiredWeaponEnchantRemainSeconds() ~= nil
		end
	},
	{ key = "slotFlask", fn = function() return HasFlask() end },
	{ key = "slotRune",  fn = function() return HasRune() end },
	{
		key = "slotPet",
		fn = function()
			if not PrepDB.slotPet then return true end
			if not PrepDB.slotPet.petGUID then return false end
			local g = C_PetJournal.GetSummonedPetGUID()
			return g ~= nil and g ~= "" and g == PrepDB.slotPet.petGUID
		end
	},
}

-- ── Duration helpers ──────────────────────────────────────────────────────────

local function GetSlotRemainingSeconds(key, s)
	if not s then return nil end

	if key == "slotWeapon" then
		return GetRequiredWeaponEnchantRemainSeconds()
	end

	local aura = nil
	if key == "slotBuff" and s.spellID then
		local spellName = C_Spell.GetSpellName(s.spellID)
		aura = spellName and FindPlayerHelpfulAuraByName(spellName)
	elseif key == "slotFood" then
		aura = FindFoodAura()
	elseif key == "slotFlask" and s.itemID then
		local itemName = C_Item.GetItemNameByID(s.itemID)
		aura = itemName and FindPlayerHelpfulAuraByName(itemName)
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

-- ── Find button on bar ────────────────────────────────────────────────────────

local function FindButtonForType(matchType, matchID)
	local matchName = (matchType == "spell") and C_Spell.GetSpellName(matchID) or C_Item.GetItemNameByID(matchID)
	if not matchName then return end

	local fallbackBtn = nil
	for s = 1, NUM_BUTTONS do
		local t, id = GetCachedActionInfo(s)
		if t then
			local found = false

			if t == matchType and id == matchID then
				found = true
			elseif t == "macro" then
				local label = GetActionText(s)
				if label then
					local _, _, body = GetMacroInfo(label)
					if body and body:lower():find(matchName:lower(), 1, true) then
						found = true
					end
				end
				if not found then
					if matchType == "spell" then
						local macroSpellID = GetMacroSpellID(id)
						if macroSpellID == matchID then found = true end
					elseif matchType == "item" then
						local _, link = GetMacroItem(id)
						local apiID = link and tonumber(link:match("item:(%d+)"))
						if apiID == matchID then found = true end
					end
				end
			end

			if found then
				local btn = GetButtonForActionSlot(s)
				if btn then
					if IsSlotActiveForCurrentBar(s) then
						return btn
					end
					fallbackBtn = fallbackBtn or btn
				end
			end
		end
	end
	return fallbackBtn
end

local function FindButton(slot)
	if not slot then return nil end
	if slot.petGUID then
		local fallbackBtn = nil
		for s = 1, NUM_BUTTONS do
			local t, id = GetCachedActionInfo(s)
			if t == "summonpet" and id == slot.petGUID then
				local btn = GetButtonForActionSlot(s)
				if btn then
					if IsSlotActiveForCurrentBar(s) then
						return btn
					end
					fallbackBtn = fallbackBtn or btn
				end
			end
		end
		return fallbackBtn
	elseif slot.spellID then
		return FindButtonForType("spell", slot.spellID)
	elseif slot.itemID then
		if (C_Item.GetItemCount(slot.itemID) or 0) == 0 then return nil end
		return FindButtonForType("item", slot.itemID)
	end
end

-- ── Auto combat pet (Hunter / Warlock / Death Knight) ─────────────────────────

local function InitAutoCombatPet()
	local class = UnitClassBase("player")
	local spellNames = COMBAT_PET_SPELLS[class]
	if not spellNames then
		_autoCombatPetSpellIDs = nil
		return
	end
	_autoCombatPetSpellIDs = {}
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
			_autoCombatPetSpellIDs[#_autoCombatPetSpellIDs + 1] = id
		end
	end
end

-- ── Button cache ──────────────────────────────────────────────────────────────

local function FindCombatPetButton()
	if not _autoCombatPetSpellIDs or #_autoCombatPetSpellIDs == 0 then return nil end
	local fallbackBtn = nil
	for s = 1, NUM_BUTTONS do
		local t, id = GetCachedActionInfo(s)
		local spellID = (t == "spell" and id) or (t == "macro" and GetMacroSpellID(id))
		if spellID then
			for _, sid in ipairs(_autoCombatPetSpellIDs) do
				if spellID == sid then
					local btn = GetButtonForActionSlot(s)
					if btn then
						if IsSlotActiveForCurrentBar(s) then
							return btn
						end
						fallbackBtn = fallbackBtn or btn
					end
				end
			end
		end
	end
	return fallbackBtn
end

local function RebuildButtonCache()
	wipe(_buttonCache)
	for _, c in ipairs(checks) do
		if PrepDB[c.key] then
			_buttonCache[c.key] = FindButton(PrepDB[c.key]) or false
		end
	end
	if _autoCombatPetSpellIDs then
		_buttonCache["__combatPet"] = FindCombatPetButton() or false
	end
	_buttonCacheDirty = false
end

local function GetCachedButton(key)
	if _buttonCacheDirty then RebuildButtonCache() end
	return _buttonCache[key] ~= false and _buttonCache[key] or nil
end

-- ── Glow ──────────────────────────────────────────────────────────────────────

local function SetGlow(btn, show, r, g, b, a, isWarn)
	if not btn then return end
	local cr, cg, cb, ca
	if isWarn then
		cr = r or PrepDB.warnR
		cg = g or PrepDB.warnG
		cb = b or PrepDB.warnB
		ca = a or PrepDB.warnA or 1.0
	else
		cr = r or PrepDB.flashR
		cg = g or PrepDB.flashG
		cb = b or PrepDB.flashB
		ca = a or PrepDB.flashA or 1.0
	end
	for _, k in ipairs({ "SpellHighlightTexture", "Flash" }) do
		local t = btn[k]
		if t then
			if show then
				t:Show(); t:SetAlpha(ca); t:SetVertexColor(cr, cg, cb)
			else
				t:Hide(); t:SetVertexColor(1, 1, 1); t:SetAlpha(1)
			end
		end
	end
end

-- ── Main update ───────────────────────────────────────────────────────────────

local function ClearGlows()
	for _, btn in pairs(_activeGlows) do SetGlow(btn, false) end
	wipe(_activeGlows)
end

local function ScheduleUpdate()
	if IsRestrictedMode() then
		ClearGlows(); return
	end
	if _pendingUpdate then return end
	_pendingUpdate = true
	C_Timer.After(0.1, function()
		_pendingUpdate = false
		if IsRestrictedMode() then
			ClearGlows()
			return
		end
		ClearGlows()
		for _, c in ipairs(checks) do
			if PrepDB[c.key] then
				local slotSetting = PrepDB[c.key]
				local btn = GetCachedButton(c.key)
				if btn then
					local passed = c.fn()
					if not passed then
						SetGlow(btn, true)
						_activeGlows[c.key] = btn
					elseif IsExpiringSoon(c.key, slotSetting) then
						SetGlow(btn, true, PrepDB.warnR, PrepDB.warnG, PrepDB.warnB, PrepDB.warnA, true)
						_activeGlows[c.key] = btn
					end
				end
			end
		end
		if _autoCombatPetSpellIDs and not UnitExists("pet") then
			local btn = GetCachedButton("__combatPet")
			if btn then
				SetGlow(btn, true)
				_activeGlows["__combatPet"] = btn
			end
		end
	end)
end

local function ScheduleUpdateSlow()
	if IsRestrictedMode() then
		ClearGlows(); return
	end
	if _pendingUpdateSlow then return end
	_pendingUpdateSlow = true
	C_Timer.After(0.5, function()
		_pendingUpdateSlow = false
		if _pendingUpdate then return end
		if IsRestrictedMode() then
			ClearGlows(); return
		end
		ScheduleUpdate()
	end)
end

-- ── Pet GUID re-resolution ────────────────────────────────────────────────────

local function FindPetGUIDByName(search)
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

local function RefreshPetGUID()
	if not PrepDB.slotPet then return true end
	local lookupName = PrepDB.slotPet.petName
	if not lookupName then
		if PrepDB.slotPet.petGUID then
			local _, cn, _, _, _, _, _, sn = C_PetJournal.GetPetInfoByPetID(PrepDB.slotPet.petGUID)
			lookupName = (cn and cn ~= "") and cn or sn
		end
		if not lookupName then
			return false
		end
	end

	local freshGUID = FindPetGUIDByName(lookupName)
	if freshGUID then
		PrepDB.slotPet.petGUID = freshGUID
		return true
	end
	return false
end

local function AttemptPetRefresh()
	if not _needsPetRefresh then return end
	if not PrepDB.slotPet then
		_needsPetRefresh = false
		_petRefreshAttempts = 0
		return
	end

	_petRefreshAttempts = (_petRefreshAttempts or 0) + 1
	if RefreshPetGUID() then
		_needsPetRefresh = false
		_petRefreshAttempts = 0
		return
	end

	if _petRefreshAttempts >= (_petRefreshMaxAttempts or 12) then
		local failedName = PrepDB.slotPet.petName or "(unknown)"
		PrepDB.slotPet = nil
		_needsPetRefresh = false
		_petRefreshAttempts = 0
		print("|cff00ccff[Prep]|r Pet '" .. failedName .. "' no longer found after journal sync, cleared.")
		return
	end

	C_Timer.After(0.5, function()
		if _needsPetRefresh then
			AttemptPetRefresh()
		end
	end)
end

local function HookAllButtons()
	for _, r in ipairs(BAR_RANGES) do
		for s = r[1], r[2] do
			local btn = _G[r[3] .. (s + r[4])]
			if btn and not btn.__prepHooked then
				btn.__prepHooked = true
				btn:HookScript("OnEnter", ScheduleUpdate)
				btn:HookScript("OnLeave", ScheduleUpdate)
			end
		end
	end
end

-- ── Events ────────────────────────────────────────────────────────────────────

_frame:RegisterEvent("ADDON_LOADED")
_frame:RegisterEvent("PLAYER_ENTERING_WORLD")
_frame:RegisterEvent("CHALLENGE_MODE_START")
_frame:RegisterEvent("CHALLENGE_MODE_COMPLETED")
_frame:RegisterEvent("CHALLENGE_MODE_RESET")
_frame:RegisterEvent("PVP_MATCH_ACTIVE")
_frame:RegisterEvent("PVP_MATCH_COMPLETE")
_frame:RegisterEvent("PVP_MATCH_STATE_CHANGED")
_frame:RegisterEvent("ZONE_CHANGED_NEW_AREA")
_frame:SetScript("OnEvent", function(self, event, ...)
	if event == "ADDON_LOADED" then
		local name = ...
		if name ~= _addonName then return end

		PrepDB = PrepDB or {}
		for k, v in pairs(_defaults) do
			if PrepDB[k] == nil then
				PrepDB[k] = v
			end
		end

		_needsPetRefresh = true
		_petRefreshAttempts = 0
		InitAutoCombatPet()
		HookAllButtons()
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
		self:UnregisterEvent(event)
	elseif event == "PLAYER_ENTERING_WORLD" then
		_slotCacheDirty = true
		_buttonCacheDirty = true
		_isMatchActive = false
		if _needsPetRefresh then
			C_Timer.After(1.0, function()
				if _needsPetRefresh then
					AttemptPetRefresh()
				end
			end)
		end
		ScheduleUpdate()
	elseif event == "ACTIONBAR_SLOT_CHANGED" then
		local slot = ...
		if slot == 0 then
			_slotCacheDirty = true
			_buttonCacheDirty = true
			ScheduleUpdate()
			return
		end
		local t, id = GetActionInfo(slot)
		local old = _slotCache[slot]
		local hadAction = old ~= nil
		local hasAction = t ~= nil
		local actionChanged = hadAction and hasAction and (old.type ~= t or old.id ~= id)
		local changed = (hadAction ~= hasAction) or actionChanged
		if not changed then return end
		if t then
			_slotCache[slot] = { type = t, id = id }
		else
			_slotCache[slot] = nil
		end
		_buttonCacheDirty = true
		ScheduleUpdate()
	elseif event == "ACTIONBAR_PAGE_CHANGED" then
		_slotCacheDirty = true
		_buttonCacheDirty = true
		ScheduleUpdate()
	elseif event == "CHALLENGE_MODE_START" then
		_isMatchActive = true
		ClearGlows()
	elseif event == "PVP_MATCH_ACTIVE" then
		ScheduleUpdate()
	elseif event == "CHALLENGE_MODE_COMPLETED" or event == "CHALLENGE_MODE_RESET" or event == "PVP_MATCH_COMPLETE" then
		_isMatchActive = false
		ScheduleUpdate()
	elseif event == "PVP_MATCH_STATE_CHANGED" or event == "ZONE_CHANGED_NEW_AREA" then
		ScheduleUpdate()
	elseif event == "PLAYER_REGEN_DISABLED" then
		if not PrepDB.combat then
			ClearGlows()
		else
			ScheduleUpdate()
		end
	elseif event == "PLAYER_REGEN_ENABLED" then
		C_Timer.After(1.0, function()
			if not IsRestrictedMode() then ScheduleUpdate() end
		end)
	elseif event == "PET_JOURNAL_LIST_UPDATE" then
		if _needsPetRefresh then
			AttemptPetRefresh()
		end
		_buttonCacheDirty = true
		ScheduleUpdate()
	elseif event == "UNIT_AURA" then
		local unit = ...
		if unit == "player" then
			ScheduleUpdate()
		elseif PrepDB.group and (unit:find("party") or unit:find("raid")) then
			ScheduleUpdateSlow()
		end
	elseif event == "ACTIVE_TALENT_GROUP_CHANGED" then
		_slotCacheDirty = true
		_buttonCacheDirty = true
		InitAutoCombatPet()
		HookAllButtons()
		ScheduleUpdate()
	elseif event == "UNIT_FLAGS" then
		local unit = ...
		if unit == "player" then
			if UnitOnTaxi("player") then
				ClearGlows()
			else
				ScheduleUpdate()
			end
		elseif PrepDB.group and (unit:find("party") or unit:find("raid")) then
			ScheduleUpdateSlow()
		end
	elseif event == "EDIT_MODE_LAYOUTS_UPDATED" then
		_buttonCacheDirty = true
		HookAllButtons()
		ScheduleUpdate()
	else
		ScheduleUpdate()
	end
end)

-- ── Slash command helpers ─────────────────────────────────────────────────────

local function FindSpellIDByName(search)
	search = search:lower()
	for i = 1, 1000 do
		local info = C_SpellBook.GetSpellBookItemInfo(i, Enum.SpellBookSpellBank.Player)
		if not info then break end
		if info.spellID and info.spellID > 0 then
			local name = C_Spell.GetSpellName(info.spellID)
			if name and name:lower() == search then return info.spellID end
		end
	end
	if C_Spell.GetSpellIDForSpellIdentifier then
		local id = C_Spell.GetSpellIDForSpellIdentifier(search)
		if id and id > 0 then return id end
	end
	return nil
end

local function FindItemIDByName(search)
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

local function StatusMarker(isConfigured, passed, buy)
	if not isConfigured then return "" end
	if buy then return "|cffffbb00[BUY]|r " end
	return passed and "|cff00ff00[OK]|r " or "|cffff4444[MISS]|r "
end

local function EvaluateSlotState(key)
	local s = PrepDB[key]
	if not s then
		return { configured = false, passed = true, buy = false, countSuffix = "", durationSuffix = "", buttonSuffix = "" }
	end
	local passed = true
	local buy = false
	if s.itemID and (C_Item.GetItemCount(s.itemID) or 0) == 0 then
		buy = true
		passed = false
	else
		for _, c in ipairs(checks) do
			if c.key == key then
				passed = c.fn()
				break
			end
		end
	end
	return {
		configured = true,
		passed = passed,
		buy = buy,
		countSuffix = StatusCountSuffix(key, s),
		durationSuffix = StatusDurationSuffix(key, s),
		buttonSuffix = "",
	}
end

local function SlotStatus(key, label)
	local s = PrepDB[key]
	if not s then return label .. ": |cffaaaaaa(not set)|r" end
	local state = EvaluateSlotState(key)
	local marker = StatusMarker(state.configured, state.passed, state.buy)
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
	print("|cff00ccff[Prep]|r Current settings (Group: " .. tostring(PrepDB.group) .. " | Combat: " .. tostring(PrepDB.combat) .. "):")
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
	if _autoCombatPetSpellIDs then
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
		"/prep color <r> <g> <b> [a]  (0.0-1.0, optional alpha)",
		"/prep warncolor <r> <g> <b> [a]  (0.0-1.0, optional alpha)",
		"/prep status",
	}) do print("  |cffffff00" .. l .. "|r") end
end

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

	if _itemSlots[cmd] then
		if origArg == "" then
			print("|cff00ccff[Prep]|r Usage: /prep " .. cmd .. " <item id, name, or link>"); return
		end
		local id = ParseItemArg(origArg)
		if not id then
			print("|cff00ccff[Prep]|r Item not found: |cffffff00" .. origArg .. "|r  (must be in bags)"); return
		end
		PrepDB[_itemSlots[cmd]] = { itemID = id }
		local link = select(2, GetItemInfo(id)) or ("|cffffff00" .. (C_Item.GetItemNameByID(id) or tostring(id)) .. "|r")
		local label = (cmd or ""):sub(1, 1):upper() .. (cmd or ""):sub(2)
		print("|cff00ccff[Prep]|r " .. label .. " set to: " .. ItemIcon(id) .. link)
		_buttonCacheDirty = true
		ScheduleUpdate()
	elseif cmd == "warncolor" then
		origArg = origArg:gsub(",", " ")
		local r, g, b, a = origArg:match("^(%S+)%s+(%S+)%s+(%S+)%s*(%S*)$")
		r, g, b = tonumber(r), tonumber(g), tonumber(b)
		a = tonumber(a)
		if not r or not g or not b then
			print("|cff00ccff[Prep]|r Usage: /prep warncolor <r> <g> <b> [a]"); return
		end
		PrepDB.warnR, PrepDB.warnG, PrepDB.warnB = r, g, b
		if a then
			PrepDB.warnA = a
			print(("|cff00ccff[Prep]|r Warn color set to %.2f %.2f %.2f %.2f"):format(r, g, b, a))
		else
			print(("|cff00ccff[Prep]|r Warn color set to %.2f %.2f %.2f"):format(r, g, b))
		end
		ScheduleUpdate()
	elseif cmd == "color" then
		origArg = origArg:gsub(",", " ")
		local r, g, b, a = origArg:match("^(%S+)%s+(%S+)%s+(%S+)%s*(%S*)$")
		r, g, b = tonumber(r), tonumber(g), tonumber(b)
		a = tonumber(a)
		if not r or not g or not b then
			print("|cff00ccff[Prep]|r Usage: /prep color <r> <g> <b> [a]"); return
		end
		PrepDB.flashR, PrepDB.flashG, PrepDB.flashB = r, g, b
		if a then
			PrepDB.flashA = a
			print(("|cff00ccff[Prep]|r Color set to %.2f %.2f %.2f %.2f"):format(r, g, b, a))
		else
			print(("|cff00ccff[Prep]|r Color set to %.2f %.2f %.2f"):format(r, g, b))
		end
		ScheduleUpdate()
	elseif cmd == "buff" then
		if origArg == "" then
			print("|cff00ccff[Prep]|r Usage: /prep buff <spell id, name, or link>"); return
		end
		local id = ParseSpellArg(origArg)
		if not id then
			print("|cff00ccff[Prep]|r Spell not found: |cffffff00" .. origArg .. "|r"); return
		end
		PrepDB.slotBuff = { spellID = id }
		local link = C_Spell.GetSpellLink(id) or ("|cffffff00" .. (C_Spell.GetSpellName(id) or tostring(id)) .. "|r")
		print("|cff00ccff[Prep]|r Buff set to: " .. SpellIcon(id) .. link)
		_buttonCacheDirty = true
		ScheduleUpdate()
	elseif cmd == "pet" then
		if origArg == "" then
			print("|cff00ccff[Prep]|r Usage: /prep pet <name>"); return
		end
		local guid, name = FindPetGUIDByName(origArg)
		if not guid then
			print("|cff00ccff[Prep]|r Pet not found: |cffffff00" .. origArg .. "|r"); return
		end
		PrepDB.slotPet = { petGUID = guid, petName = origArg }
		local petLink = C_PetJournal.GetBattlePetLink(guid) or ("|cffffff00" .. name .. "|r")
		print("|cff00ccff[Prep]|r Pet set to: " .. PetIcon(guid) .. petLink)
		_buttonCacheDirty = true
		ScheduleUpdate()
	elseif cmd == "clear" then
		local k = "slot" .. arg:sub(1, 1):upper() .. arg:sub(2)
		if PrepDB[k] ~= nil then
			PrepDB[k] = nil
			print("|cff00ccff[Prep]|r Cleared: " .. arg)
			_buttonCacheDirty = true
			ScheduleUpdate()
		else
			print("|cff00ccff[Prep]|r Unknown slot: " .. arg .. "  (buff/food/weapon/flask/rune/pet)")
		end
	elseif cmd == "reset" then
		ClearGlows()
		wipe(PrepDB)
		for k, v in pairs(_defaults) do PrepDB[k] = v end
		_slotCacheDirty = true
		_buttonCacheDirty = true
		C_Timer.After(0.2, function()
			ScheduleUpdate(); ShowStatus()
		end)
		print("|cff00ccff[Prep]|r All settings reset to defaults")
	elseif cmd == "group" then
		PrepDB.group = not PrepDB.group
		print("|cff00ccff[Prep]|r Group buff check: " .. (PrepDB.group and "|cff00ff00ON|r" or "|cffff4444OFF|r"))
		ScheduleUpdate()
	elseif cmd == "status" then
		ShowStatus()
	elseif cmd == "combat" then
		PrepDB.combat = not PrepDB.combat
		local state = PrepDB.combat and "|cff00ff00Enabled|r" or "|cffff4444Disabled|r"
		print("|cff00ccff[Prep]|r Combat: " .. state)
		ScheduleUpdate()
	else
		PrintHelp()
	end
end
