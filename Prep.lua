-- Prep: highlights action bar buttons for missing buff, food, weapon enchant, flask, rune, pet, and combat pet.
-- Combat pet check is automatic for Hunter, Warlock, and Death Knight — no configuration needed.

local ADDON_NAME = "Prep"

local defaults = {
	checkGroup = true,
	flashAlpha = 1.0,
	flashR = 1.0,
	flashG = 0.3,
	flashB = 0.3,
	slotBuff = nil,
	slotFood = nil,
	slotWeapon = nil,
	slotFlask = nil,
	slotRune = nil,
	slotPet = nil,
}

local db = {}

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

local function GetButtonForActionSlot(slot)
	for _, r in ipairs(BAR_RANGES) do
		if slot >= r[1] and slot <= r[2] then
			local btn = _G[r[3] .. (slot + r[4])]
			return btn and btn:IsVisible() and btn or nil
		end
	end
end

-- ── Find button on bar ────────────────────────────────────────────────────────

local function FindButtonForType(matchType, matchID)
	for s = 1, 180 do
		local t, id = GetActionInfo(s)
		if (t == matchType or t == "macro") and id == matchID then
			local btn = GetButtonForActionSlot(s)
			if btn then return btn end
		end
	end
end

local function FindButton(slot)
	if not slot then return nil end
	if slot.petGUID then
		for s = 1, 180 do
			local t, id = GetActionInfo(s)
			if t == "summonpet" and id == slot.petGUID then
				local btn = GetButtonForActionSlot(s)
				if btn then return btn end
			end
		end
	elseif slot.spellID then
		return FindButtonForType("spell", slot.spellID)
	elseif slot.itemID then
		if (GetItemCount(slot.itemID) or 0) == 0 then return nil end
		return FindButtonForType("item", slot.itemID)
	end
end

-- ── Buff / aura checks ────────────────────────────────────────────────────────

local function HasAura(name, checkGroup)
	if not AuraUtil.FindAuraByName(name, "player", "HELPFUL") then return false end
	if checkGroup then
		local n = GetNumGroupMembers()
		if n > 0 then
			local pfx = IsInRaid() and "raid" or "party"
			for i = 1, n do
				if UnitExists(pfx .. i) and not AuraUtil.FindAuraByName(name, pfx .. i, "HELPFUL") then
					return false
				end
			end
		end
	end
	return true
end

local function HasFlask()
	if not db.slotFlask or not db.slotFlask.itemID then return true end
	local name = C_Item.GetItemNameByID(db.slotFlask.itemID)
	if not name then return true end
	return AuraUtil.FindAuraByName(name, "player", "HELPFUL") ~= nil
end

local function HasRune()
	if not db.slotRune or not db.slotRune.itemID then return true end
	local itemName = C_Item.GetItemNameByID(db.slotRune.itemID)
	if not itemName then return true end

	local searchTerm = itemName:lower():gsub("%s*%S+%s*$", ""):gsub("%s*%S+%s*$", "")
	if searchTerm == "" then return true end

	local i = 1
	while true do
		local aura = C_UnitAuras.GetAuraDataByIndex("player", i, "HELPFUL")
		if not aura then break end
		if aura.name and not issecretvalue(aura.name) then
			if aura.name:lower():find(searchTerm, 1, true) then
				return true
			end
		end
		i = i + 1
	end
	return false
end

local checks = {
	{
		key = "slotBuff",
		fn = function()
			if not db.slotBuff or not db.slotBuff.spellID then return true end
			local name = C_Spell.GetSpellName(db.slotBuff.spellID)
			return not name or HasAura(name, db.checkGroup)
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
		-- FIX: check both hands, but only require offhand enchant if the offhand slot
		-- holds an actual weapon (not a shield or offhand frill).
		key = "slotWeapon",
		fn = function()
			-- Use expiry values (2nd and 4th returns) instead of the boolean returns
			-- (1st and 3rd), which unreliably return 0 instead of true/false.
			local _, mhExp, _, ohExp = GetWeaponEnchantInfo()
			if not mhExp or mhExp == 0 then return false end
			local ohItem = GetInventoryItemID("player", 17)
			if ohItem then
				local _, _, _, _, _, _, _, _, slot = GetItemInfo(ohItem)
				local ohIsWeapon = slot == "INVTYPE_WEAPONOFFHAND" or slot == "INVTYPE_2HWEAPON"
				if ohIsWeapon and (not ohExp or ohExp == 0) then return false end
			end
			return true
		end
	},
	{ key = "slotFlask", fn = HasFlask },
	{ key = "slotRune",  fn = HasRune },
	{
		key = "slotPet",
		fn = function()
			if not db.slotPet then return true end
			local g = C_PetJournal.GetSummonedPetGUID()
			return g ~= nil and g ~= ""
		end
	},
}

-- ── Auto combat pet (Hunter / Warlock / Death Knight) ─────────────────────────

-- Ordered by preference: the first spell found on bars wins.
local COMBAT_PET_SPELLS = {
	HUNTER      = { "Call Pet 1", "Call Pet 2", "Call Pet 3", "Call Pet 4", "Call Pet 5" },
	WARLOCK     = { "Summon Imp", "Summon Voidwalker", "Summon Succubus", "Summon Felhunter",
		"Summon Felguard", "Summon Incubus", "Summon Darkglare",
		"Summon Demonic Tyrant", "Summon Infernal", "Summon Sayaad" },
	DEATHKNIGHT = { "Raise Dead" },
}

local autoCombatPetSpellIDs = nil -- nil = not a pet class; {} = pet class, populated on first update

local function InitAutoCombatPet()
	local class = UnitClassBase("player")
	local spellNames = COMBAT_PET_SPELLS[class]
	if not spellNames then
		autoCombatPetSpellIDs = nil
		return
	end
	autoCombatPetSpellIDs = {}
	for _, name in ipairs(spellNames) do
		local id = C_Spell.GetSpellIDForSpellIdentifier and C_Spell.GetSpellIDForSpellIdentifier(name)
		if not id then
			-- fall back to spellbook scan
			for i = 1, 1000 do
				local info = C_SpellBook.GetSpellBookItemInfo(i, Enum.SpellBookSpellBank.Player)
				if not info then break end
				if info.spellID and C_Spell.GetSpellName(info.spellID) == name then
					id = info.spellID; break
				end
			end
		end
		if id and id > 0 then
			autoCombatPetSpellIDs[#autoCombatPetSpellIDs + 1] = id
		end
	end
end

-- Returns the first visible bar button matching any known summon spell, or nil.
local function FindCombatPetButton()
	if not autoCombatPetSpellIDs or #autoCombatPetSpellIDs == 0 then return nil end
	for s = 1, 180 do
		local t, id = GetActionInfo(s)
		if t == "spell" then
			for _, sid in ipairs(autoCombatPetSpellIDs) do
				if id == sid then
					local btn = GetButtonForActionSlot(s)
					if btn then return btn end
				end
			end
		end
	end
end

-- ── Glow ──────────────────────────────────────────────────────────────────────

local function SetGlow(btn, show)
	if not btn then return end
	for _, k in ipairs({ "SpellHighlightTexture", "Flash" }) do
		local t = btn[k]
		if t then
			if show then
				t:Show(); t:SetAlpha(db.flashAlpha); t:SetVertexColor(db.flashR, db.flashG, db.flashB)
			else
				t:Hide(); t:SetVertexColor(1, 1, 1); t:SetAlpha(1)
			end
		end
	end
end

-- ── Main update ───────────────────────────────────────────────────────────────

local activeGlows, pendingUpdate, pendingUpdateSlow = {}, false, false

local function ClearGlows()
	for _, btn in pairs(activeGlows) do SetGlow(btn, false) end
	wipe(activeGlows)
end

local function ScheduleUpdate()
	if InCombatLockdown() or UnitOnTaxi("player") or (EditModeManagerFrame and EditModeManagerFrame:IsEditModeActive()) then
		ClearGlows(); return
	end
	if pendingUpdate then return end
	pendingUpdate = true
	C_Timer.After(0.1, function()
		pendingUpdate = false
		-- FIX: re-check combat inside the callback, since we may have entered
		-- combat in the 0.1s window between scheduling and execution
		if InCombatLockdown() or UnitOnTaxi("player") or (EditModeManagerFrame and EditModeManagerFrame:IsEditModeActive()) then
			ClearGlows(); return
		end
		ClearGlows()
		for _, c in ipairs(checks) do
			if db[c.key] then
				local btn = FindButton(db[c.key])
				if btn and not c.fn() then
					SetGlow(btn, true)
					activeGlows[c.key] = btn
				end
			end
		end
		-- Auto combat pet: highlight summon button if pet is missing
		if autoCombatPetSpellIDs and not UnitExists("pet") then
			local btn = FindCombatPetButton()
			if btn then
				SetGlow(btn, true)
				activeGlows["__combatPet"] = btn
			end
		end
	end)
end

local function ScheduleUpdateSlow()
	if InCombatLockdown() or UnitOnTaxi("player") or (EditModeManagerFrame and EditModeManagerFrame:IsEditModeActive()) then
		ClearGlows(); return
	end
	if pendingUpdateSlow then return end
	pendingUpdateSlow = true
	C_Timer.After(0.5, function()
		pendingUpdateSlow = false
		if pendingUpdate then return end -- a fast update is already queued, let it handle it
		if InCombatLockdown() or UnitOnTaxi("player") or (EditModeManagerFrame and EditModeManagerFrame:IsEditModeActive()) then
			ClearGlows(); return
		end
		ScheduleUpdate() -- just kick off the normal fast update from here
	end)
end

-- ── Pet GUID re-resolution ────────────────────────────────────────────────────

-- FIX: GUIDs can go stale between sessions. On load, re-resolve the stored pet
-- by name (using petName as the source of truth) so we always have a fresh GUID.
-- This is deferred to PET_JOURNAL_LIST_UPDATE because the journal may not be
-- populated yet at ADDON_LOADED time.
local function RefreshPetGUID()
	if not db.slotPet then return end
	local lookupName = db.slotPet.petName
	if not lookupName then
		-- legacy entry with no stored name: try to recover the name from the GUID
		if db.slotPet.petGUID then
			local _, cn, _, _, _, _, _, sn = C_PetJournal.GetPetInfoByPetID(db.slotPet.petGUID)
			lookupName = (cn and cn ~= "") and cn or sn
		end
		if not lookupName then
			db.slotPet = nil
			print("|cff00ccff[Prep]|r Stored pet could not be identified, cleared.")
			return
		end
	end

	-- FindPetGUIDByName is defined later but called after ADDON_LOADED fires,
	-- so forward reference is fine here.
	local freshGUID = FindPetGUIDByName(lookupName)
	if freshGUID then
		db.slotPet.petGUID = freshGUID
	else
		db.slotPet = nil
		print("|cff00ccff[Prep]|r Pet '" .. lookupName .. "' no longer found in journal, cleared.")
	end
end

-- ── Events ────────────────────────────────────────────────────────────────────

-- FIX: flag set at ADDON_LOADED, consumed on the first PET_JOURNAL_LIST_UPDATE.
-- This ensures RefreshPetGUID runs only after the journal is fully populated,
-- avoiding false "pet not found" clears that happened when the journal wasn't
-- ready yet at ADDON_LOADED time.
local needsPetRefresh = false

local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:SetScript("OnEvent", function(self, event, arg1)
	if event == "ADDON_LOADED" then
		if arg1 ~= ADDON_NAME then return end
		PrepDB = PrepDB or {}
		-- FIX: set db once and never reassign it, so all closures always see the
		-- live table. Reset uses wipe() + repopulation instead of reassignment.
		db = PrepDB
		for k, v in pairs(defaults) do if db[k] == nil then db[k] = v end end
		-- FIX: defer pet GUID refresh until PET_JOURNAL_LIST_UPDATE fires,
		-- because the journal is not reliably populated at ADDON_LOADED time.
		needsPetRefresh = true
		InitAutoCombatPet()
		for _, e in ipairs({
			"EDIT_MODE_LAYOUTS_UPDATED", "ACTIVE_TALENT_GROUP_CHANGED", "PLAYER_ENTERING_WORLD",
			"PLAYER_REGEN_ENABLED", "PLAYER_REGEN_DISABLED", "UNIT_AURA", "ACTIONBAR_SLOT_CHANGED",
			"GROUP_ROSTER_UPDATE", "PLAYER_EQUIPMENT_CHANGED", "UNIT_FLAGS", "UNIT_PET",
			"PET_JOURNAL_LIST_UPDATE", "ACTIONBAR_PAGE_CHANGED",
		}) do self:RegisterEvent(e) end
		self:UnregisterEvent("ADDON_LOADED")
	elseif event == "PLAYER_REGEN_DISABLED" then
		ClearGlows() -- entering combat: just clear and do nothing
	elseif event == "PLAYER_REGEN_ENABLED" then
		C_Timer.After(1.0, function() if not InCombatLockdown() then ScheduleUpdate() end end)
	elseif event == "PET_JOURNAL_LIST_UPDATE" then
		if needsPetRefresh then
			needsPetRefresh = false
			RefreshPetGUID()
		end
		ScheduleUpdate()
	elseif event == "UNIT_AURA" then
		if arg1 == "player" then
			ScheduleUpdate()
		elseif db.checkGroup and (arg1:find("party") or arg1:find("raid")) then
			ScheduleUpdateSlow()
		end
	elseif event == "ACTIVE_TALENT_GROUP_CHANGED" then
		InitAutoCombatPet()
		ScheduleUpdate()
	elseif event == "UNIT_FLAGS" then
		if arg1 == "player" then
			if UnitOnTaxi("player") then
				ClearGlows()
			else
				ScheduleUpdate()
			end
		end
	else
		ScheduleUpdate()
	end
end)

-- ── Lookup helpers ────────────────────────────────────────────────────────────

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
end

local function ParseItemArg(arg)
	return tonumber(arg:match("|Hitem:(%d+):")) or
		tonumber(arg:match("^%[(.+)%]$") and arg:match("^%[(.+)%]$") or arg) or
		FindItemIDByName(arg)
end

local function ParseSpellArg(arg)
	return tonumber(arg:match("|Hspell:(%d+)")) or tonumber(arg) or FindSpellIDByName(arg)
end

function FindPetGUIDByName(search) -- note: global so RefreshPetGUID can call it before definition order matters
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

local function SlotStatus(key, label)
	local s = db[key]
	if not s then return label .. ": |cffaaaaaa(not set)|r" end
	if s.petGUID then
		local _, customName, _, _, _, _, _, speciesName = C_PetJournal.GetPetInfoByPetID(s.petGUID)
		local name = (customName and customName ~= "") and customName or speciesName or "unknown"
		return label .. ": " .. PetIcon(s.petGUID) .. "|cffffff00" .. name .. "|r"
	elseif s.spellID then
		local name = C_Spell.GetSpellName(s.spellID) or ("spell " .. s.spellID)
		return label .. ": " .. SpellIcon(s.spellID) .. "|cffffff00" .. name .. "|r"
	elseif s.itemID then
		local name = C_Item.GetItemNameByID(s.itemID) or ("item " .. s.itemID)
		return label .. ": " .. ItemIcon(s.itemID) .. "|cffffff00" .. name .. "|r"
	end
	return label .. ": |cffff4444(unknown)|r"
end

local function ShowStatus()
	print("|cff00ccff[Prep]|r Current settings:")
	for _, t in ipairs({
		{ "slotBuff",  "Buff" }, { "slotFood", "Food" }, { "slotWeapon", "Weapon" },
		{ "slotFlask", "Flask" }, { "slotRune", "Rune" }, { "slotPet", "Pet" },
	}) do
		print("  " .. SlotStatus(t[1], t[2]))
	end
	if autoCombatPetSpellIDs then
		print("  Combat pet: |cff00ff00auto (enabled)|r")
	end
	print("  Group check: " .. tostring(db.checkGroup))
	print(("  Highlight: alpha=%.2f  color=%.2f/%.2f/%.2f"):format(db.flashAlpha, db.flashR, db.flashG, db.flashB))
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
		"/prep group  - toggle group buff check",
		"/prep alpha <0.1-1.0>",
		"/prep color <r> <g> <b>  (0.0-1.0)",
		"/prep status  (combat pet check is automatic for Hunter/Warlock/DK)",
	}) do print("  |cffffff00" .. l .. "|r") end
end

-- Prefix-match input against all valid commands.
-- Returns: matched string (success), false (ambiguous, already printed), nil (no match → show help)
local ALL_CMDS = {
	"buff", "food", "weapon", "flask", "rune", "pet",
	"clear", "reset", "group", "alpha", "color", "status",
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
		db[itemSlots[cmd]] = { itemID = id }
		local name = C_Item.GetItemNameByID(id) or tostring(id)
		local label = (cmd or ""):sub(1, 1):upper() .. (cmd or ""):sub(2)
		print("|cff00ccff[Prep]|r " .. label .. " set to: " .. ItemIcon(id) .. "|cffffff00" .. name .. "|r")
		ScheduleUpdate()
	elseif cmd == "buff" then
		if origArg == "" then
			print("|cff00ccff[Prep]|r Usage: /prep buff <spell id, name, or link>"); return
		end
		local id = ParseSpellArg(origArg)
		if not id then
			print("|cff00ccff[Prep]|r Spell not found: |cffffff00" .. origArg .. "|r"); return
		end
		db.slotBuff = { spellID = id }
		local name = C_Spell.GetSpellName(id) or tostring(id)
		print("|cff00ccff[Prep]|r Buff set to: " .. SpellIcon(id) .. "|cffffff00" .. name .. "|r")
		ScheduleUpdate()
	elseif cmd == "pet" then
		if origArg == "" then
			print("|cff00ccff[Prep]|r Usage: /prep pet <name>"); return
		end
		-- FIX: store petName alongside petGUID so re-resolution on next login works
		-- even if the GUID itself goes stale.
		local guid, name = FindPetGUIDByName(origArg)
		if not guid then
			print("|cff00ccff[Prep]|r Pet not found: |cffffff00" .. origArg .. "|r"); return
		end
		db.slotPet = { petGUID = guid, petName = origArg }
		print("|cff00ccff[Prep]|r Pet set to: " .. PetIcon(guid) .. "|cffffff00" .. name .. "|r")
		ScheduleUpdate()
	elseif cmd == "clear" then
		local k = "slot" .. arg:sub(1, 1):upper() .. arg:sub(2)
		if db[k] ~= nil then
			db[k] = nil
			print("|cff00ccff[Prep]|r Cleared: " .. arg)
			ScheduleUpdate()
		else
			print("|cff00ccff[Prep]|r Unknown slot: " .. arg .. "  (buff/food/weapon/flask/rune/pet)")
		end
	elseif cmd == "reset" then
		-- FIX: wipe and repopulate in-place rather than reassigning db, so all
		-- closures that captured db upvalue continue pointing at the live table.
		ClearGlows()
		wipe(PrepDB)
		for k, v in pairs(defaults) do PrepDB[k] = v end
		C_Timer.After(0.2, function()
			ScheduleUpdate(); ShowStatus()
		end)
		print("|cff00ccff[Prep]|r All settings reset to defaults")
	elseif cmd == "group" then
		db.checkGroup = not db.checkGroup
		print("|cff00ccff[Prep]|r Group buff check: " .. (db.checkGroup and "|cff00ff00ON|r" or "|cffff4444OFF|r"))
		ScheduleUpdate()
	elseif cmd == "alpha" then
		local v = tonumber(origArg)
		if not v or v < 0.1 or v > 1.0 then
			print("|cff00ccff[Prep]|r Usage: /prep alpha <0.1-1.0>"); return
		end
		db.flashAlpha = v
		print("|cff00ccff[Prep]|r Alpha set to " .. v)
		ScheduleUpdate()
	elseif cmd == "color" then
		local r, g, b = origArg:match("^(%S+)%s+(%S+)%s+(%S+)$")
		r, g, b = tonumber(r), tonumber(g), tonumber(b)
		if not r or not g or not b then
			print("|cff00ccff[Prep]|r Usage: /prep color <r> <g> <b>"); return
		end
		db.flashR, db.flashG, db.flashB = r, g, b
		print(("|cff00ccff[Prep]|r Color set to %.2f %.2f %.2f"):format(r, g, b))
		ScheduleUpdate()
	elseif cmd == "status" then
		ShowStatus()
	else
		PrintHelp()
	end
end
