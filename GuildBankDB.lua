--REMINDER: backreferences are cleared after save action to the guld bank and only faulty references are ever removed.
do
local ERR_NOT_IN_GUILD = "Not in a guild"
local version = '1.0'
local frame = CreateFrame("Frame", "GuildBankDB")
local _debug = true

local function print(x)
	return DEFAULT_CHAT_FRAME:AddMessage(x)
end

local function msg(x, ...)
	if not x then
		return
	end
	print("GBDB: " .. x)
	return msg(...)
end

local function log(...)
	if not _debug then
		return
	end
	return msg(...)
end

-- helper functions
local SetCurrentGuildBankTab
do
	local clickFunctions = {
		function() GuildBankTab1Button:Click() end,
		function() GuildBankTab2Button:Click() end,
		function() GuildBankTab3Button:Click() end,
		function() GuildBankTab4Button:Click() end,
		function() GuildBankTab5Button:Click() end,
		function() GuildBankTab6Button:Click() end,
		function() GuildBankTab7Button:Click() end
	}
	SetCurrentGuildBankTab = function(tab)
		local func = clickFunctions[tab]
		if func then
			return func()
		else
			error(string.format("Tab %s cannot be clicked!", tab), 2)
		end
	end
end

local modalEventHandlers = nil
local now = 0
local realm = nil
local charName = nil
local guildName = nil
local getGuildID
local clearGuildID
do
	local guildID = nil
	getGuildID = function()
		if guildName == nil then
			error(ERR_NOT_IN_GUILD)
		end
		if guildID == nil then
			for k,v in pairs(GuildBankDB_Save.guilds) do
				if v == guildName then
					guildID = k
					break
				end
			end
			if guildID == nil then
				guildID = GuildBankDB_Save.nextGuildID
				GuildBankDB_Save.nextGuildID = guildID + 1
				GuildBankDB_Save.guilds[guildID] = guildName
			end
		end
		return guildID
	end
	clearGuildID = function()
		guildID = nil
	end
end
local getRealmID
do
	local realmID = nil
	getRealmID = function()
		if realmID == nil then
			for k,v in pairs(GuildBankDB_Save.realms) do
				if v == realm then
					realmID = k
					break
				end
			end
			if realmID == nil then
				realmID = GuildBankDB_Save.nextRealmID
				GuildBankDB_Save.nextRealmID = realmID + 1
				GuildBankDB_Save.realms[realmID] = realm
			end
		end
		return realmID
	end
end
local getCharID
do
	local charID = nil
	getCharID = function()
		if charID == nil then
			for k,v in pairs(GuildBankDB_Save.chars) do
				if v == charName then
					charID = k
					break
				end
			end
			if charID == nil then
				charID = GuildBankDB_Save.nextCharID
				GuildBankDB_Save.nextCharID = charID + 1
				GuildBankDB_Save.chars[charID] = charName
			end
		end
		return charID
	end
end
local currentGBankTab = 0
local refreshActionStep = nil
	
local modes = {}
do
	local modeList = {
		"idle",
		"waiting_for_tab_update_timeout",
		"listening",
		"refreshing",
		"verify_guild_is_same_as_saved"
	}
	for k, v in ipairs(modeList) do
		modes[v] = k
	end
	modeList = nil
end
local mode = modes.idle
local modeChangedAt = now

local function getCurrentGBankLag() -- inSeconds
	--log_("getCurrentGBankLag")
	-- TODO: determine which lag factor is the most prevalent
	local lagHome, lagWorld
	_, _, lagHome, lagWorld = GetNetStats()
	return math.max(lagHome, lagWorld)/1000
end

local isTableEmpty
do
	local next = next
	isTableEmpty = function(t)
		if t == nil then
			return true
		end
		local _, v = next(t)
		return v == nil
	end
end

local onUpdate
local TimedEvent
local getNextEventID
local dumpEventQueue
local dumpModalEventQueue
local isEventInQueue
local dequeueEvent
local enqueueEvent
local isEventQueueEmpty
do
	local timedEvents = {}
	local keys = {}
	local keySize = 0
	onUpdate = function(self, elapsed)
		now = now + elapsed
		if now < 0 then
			-- TODO: handle wrap around
		end
		if not isTableEmpty(timedEvents) then
			-- abstracting keys from the event set iterator
			-- modifying the table while iterating over it
			-- using native lua iterators can randomly break!
			local keyIdx = 0
			for k, _ in pairs(timedEvents) do
				keyIdx = keyIdx + 1
				keys[keyIdx] = k
			end
			if keyIdx < keySize then
				for idx=keyIdx+1,keySize,1 do
					keys[keyIdx] = nil
				end
			end
			keySize = keyIdx
			for _, k in ipairs(keys) do
				local event = timedEvents[k]
				if event ~= nil then
					local runAt = event.runAt(event)
					if rawequal(event, timedEvents[k]) and runAt <= now then
						event(now)
					end
				end
			end
		end
	end
	isEventQueueEmpty = function()
		return isTableEmpty(timedEvents)
	end
	isEventInQueue = function(eventID)
		if timedEvents[eventID] == nil then
			return false
		end
		return true
	end
	dequeueEvent = function(eventID)
		timedEvents[eventID] = nil
	end
	dumpEventQueue = function()
		if not isTableEmpty(timedEvents) then
			--log_("Non-empty event queue dumped")
			timedEvents = {}
		end
	end
	dumpModalEventQueue = function()
		local numDropped = 0
		if not isTableEmpty(timedEvents) then
			local dropables = {}
			for k, v in pairs(timedEvents) do
				if v.isModal then
					table.insert(dropables, k)
				end
			end
			for _, k in ipairs(dropables) do
				numDropped = numDropped + 1
				timedEvents[k] = nil
			end
		end
		if numDropped > 0 then
			--log_(string.format("%s modal events dropped", numDropped))
		end
	end
	do
		do
			local eventID = 0
			getNextEventID = function()
				repeat
					eventID = eventID + 1
				until not timedEvents[eventID]
				return eventID
			end
		end
		local meta = {}
		function meta:__call(...)
			if self.runOnce() then
				if _debug and timedEvents[self.id] ~= nil then
					--log_(string.format("Event %s auto-dequeued", self.id))
				end
				timedEvents[self.id] = nil
			end
			self.run(self, ...)
		end
		enqueueEvent = function(evt)
			if not rawequal(meta, getmetatable(evt)) then
				error("Not an event", 2)
			end
			timedEvents[evt.id] = evt
		end
		TimedEvent = function(runAtFuncOrNum, actionFunc, onlyRunsOnce, autoQueue, isModalEvent)
			if onlyRunsOnce == nil then
				onlyRunsOnce = true
			end
			if autoQueue == nil then
				autoQueue = true
			end
			if isModalEvent == nil then
				isModalEvent = true
			else
				isModalEvent = isModalEvent and true or false
			end
			local thisEventID
			if autoQueue then
				thisEventID = getNextEventID()
			end
			local t = type(runAtFuncOrNum)
			if t == 'number' then
				local num = runAtFuncOrNum
				runAtFuncOrNum = function() return num end
			elseif t ~= 'function' then
				error('Not a function or number', 2)
			end
			
			if type(onlyRunsOnce) ~= 'function' then
				local bool = onlyRunsOnce and true or false
				onlyRunsOnce = function() return bool end
			end
			
			local evt = {
				id = thisEventID,
				runAt = runAtFuncOrNum,
				run = actionFunc,
				runOnce = onlyRunsOnce,
				isModal = isModalEvent
			}
			setmetatable(evt, meta)
			if autoQueue then
				--log_(string.format("event %s autoqueued", thisEventID))
				enqueueEvent(evt)
			end
			return evt
		end
	end
end

local stringBuffer
do
local meta = {}
do
	local helper
	helper = function(list, times, x, ...)
		if type(x) ~= 'string' then
			error('Not a string')
		end
		table.insert(list, x)
		times = times - 1
		if times ~= 0 then
			return helper(list, times, ...)
		end
	end
	function meta:__call(...) -- append
		local n = select('#', ...)
		if n > 0 then
			helper(self.list, n, ...)
		end
	end
end
function meta:__concat(sep) -- toString w/ options
	if getmetatable(self) ~= meta then
		self, sep = sep, self
	end
	return table.concat(self.list, sep or self.default_sep)
end
function meta:__unm() -- toString w/ default separator
	return table.concat(self.list, self.default_sep)
end
stringBuffer = function(str_or_buff, sep)
	local self = {list = {}, default_sep = (sep or '')}
	setmetatable(self, meta)
	if str_or_buff ~= nil then
		local t = type(str_or_buff)
		if t == 'table' then
			if getmetatable(str_or_buff) == meta then
				for _, v in ipairs(str_or_buff.list) do
					if string.len(v) then
						self(v)
					end
				end
			end
		elseif t == 'string' then
			self(str_or_buff)
		end
	end
	return self
end
end

local toString -- helper function to convert anything (not function/userdata) to a string
do
	local transposables = {
		["string"] = function(x) return x end,
		["number"] = function(x) return "" .. x end,
		["boolean"] = function(x) return x and 'true' or 'false' end,
		["nil"] = function() return 'nil' end
	}
	toString = function(x, t)
		if t == nil then
			t = type(x)
		end
		local func = transposables[t]
		if func then
			return func(x)
		end
		error(string.format("Cannot turn %s into a string", t), 2)
	end
	-- begin table to string support
	local escapeString
		do
		local threadsToNeedles = {
			[string.byte("\\")] = "\\\\",
			[string.byte('"')] = "\\\"",
			[string.byte("\r")] = "\\r",
			[string.byte("\n")] = "\\n"
		}
		escapeString =  function(x)
			local length = x:len()
			if length == 0 then
				return '""'
			end
			local sBuff = stringBuffer()
			sBuff('"')
			local startIdx = 1
			do
				local lastIdx = 0
				for idx=1,length,1 do
					local replacement = threadsToNeedles[string.byte(x, idx)]
					if replacement then
						if lastIdx >= startIdx then
							sBuff(string.sub(x, startIdx, lastIdx))
						end
						sBuff(replacement)
						startIdx = idx + 1
					end
					lastIdx = idx
				end
			end
			if startIdx < length then
				if startIdx == 1 then
					sBuff(x)
				else
					sBuff(string.sub(x, startIdx, length))
				end
			end
			sBuff('"')
			
			return -sBuff
		end
	end
	local tableToString
	local function cyclicTableSafeToString(x, y, t)
		if t == "table" then
			if y[x] then
				error("Cyclic reference detected")
			end
			y[x] = true
			t = tableToString(x, y)
			y[x] = nil
			return t
		elseif t == "string" then
			return escapeString(x)
		else
			return toString(x, t)
		end
	end
	do
		local invalidTableKeyTypes = {
			["thread"] = true,
			["userdata"] = true,
			["table"] = true,
			["function"] = true,
		}
		tableToString = function(x, y)
			if y == nil then
				y = {}
			end
			local rval = stringBuffer(nil, ',')
			local maxIdx = 0
			for _,v in ipairs(x) do
				maxIdx = maxIdx + 1
				local vType = type(v)
				if vType == "string" then
					v = escapeString(v)
				else
					v = cyclicTableSafeToString(v, y, vType)
				end
				rval(v)
			end
			for k,v in pairs(x) do
				local kType = type(k)
				if maxIdx <= 0 or kType ~= "number" or k ~= math.floor(k) or k <= 0 or k > maxIdx then
					if invalidTableKeyTypes[kType] then
						error(string.format("Invalid table key of type %s", kType))
					elseif kType == "string" then
						k = escapeString(k)
					else
						k = toString(k, kType)
					end
					local vType = type(v)
					if vType == "string" then
						v = escapeString(v)
					else
						v = cyclicTableSafeToString(v, y, vType)
					end
					rval(string.format('[%s]=%s', k, v))
				end
			end
			return string.format('{%s}', -rval)
		end
	end
	transposables["table"] = tableToString
	-- end table to string support
	
end

-- note that table to string function ONLY HANDLES converting string keys/value characters [\"]
-- Also note that the table cannot have cyclic references and it must only use non-table/userdata data types as keys


local function setMode(newMode)
	if mode == newMode then
		return
	end
	dumpModalEventQueue()
	mode = newMode
	modeChangedAt = now
	--log_("new mode " .. mode)
end

local datetime
do
	local date = date
	datetime = function()
		return date("%Y-%m-%d %H:%M:%S")
	end
end

local function getItemNameFromDeflatedLink(x)
	if type(x) == 'string' then
		x = GetItemInfo('item:' .. x)
	else
		x = GetItemInfo(x)
	end
	return x
end

local function getItemIDFromDeflatedLink(x)
	if type(x) == 'string' then
		x = tonumber(string.match(x, "^([0-9]+):"))
	end
	return x
end

local function deflateItemLink(x)
	-- extract item string
	x = string.match(x, "item[%-?%d:]+")
	-- extract item id if and only if all options are zero, any uniqueId, any link level, reforgeID is zero
	local y = string.match(x, "^item:(%-?[0-9]+):[0:]+:%-?[0-9]+:%-?[0-9]+:0$")
	if y then
		x = tonumber(y)
	else
		-- remove "item:" prefix
		x = string.match(x, "^item:(.+)$")
		-- if string ends in ":0", that means that there is no reforge ID and can be trimmed of it
		-- also set the link level to max level
		local noUseEnd = string.match(x, ":[:0]+:%-?[0-9]+:%-?[0-9]+:0$")
		if not noUseEnd then
			noUseEnd = string.match(x, ":%-?[0-9]+:%-?[0-9]+:0$")
		end
		if noUseEnd then
			-- truncate no use end
			x = string.sub(x, 1, strlen(x) - strlen(noUseEnd))
		else
			-- reforge id must be non-zero now
			-- just make the link level 1 always
			-- also make uniqueId 0
			local head, uniqueID, linkLevel, tail = string.match(x, "^([%-:0-9]+:)(%-?[0-9]+):(%-?[0-9]+)(:%-?[0-9]+)$")
			if uniqueID and linkLevel and (tonumber(uniqueID) ~= 0 or tonumber(linkLevel) ~= 1) then
				x = string.format("%s%s%s", head, '0:1', tail)
			end
		end
	end
	return x
end

local function deflateItemLinkFromGBank(...)
	local itemLink = GetGuildBankItemLink(...)
	if itemLink == nil then
		return
	end
	return deflateItemLink(itemLink)
end

local function inflateItemLink(x)
	if type(x) == 'string' then
		_, x = GetItemInfo('item:' .. x)
	else
		_, x = GetItemInfo(x)
	end
	return x
end

-- end helper functions


--[[
do
	local testTable = {"I have a lovely", 1234, "bunch of coconuts", {"diddly", "dee", {[1.45] = 56}}}
	--log_(toString(testTable))
end
]]--


local eventHandlers
do
	-- BEGIN: REAL EVENT HANDLERS
	
	
	local function cacheGBank(rid, gid, flatHash, numNames, tabs)
		local cache = GuildBankDB_Save.itemCache
		local itemRefs = GuildBankDB_Save.itemRefs
		
		for id, name in pairs(cache) do
			if flatHash[name] then
				local refs = flatHash[name]
				flatHash[name] = nil
				if not itemRefs[id] then
					itemRefs[id] = {}
				end
				if not itemRefs[id][rid] then
					itemRefs[id][rid] = {}
				end
				local savePoint
				if itemRefs[id][rid][gid] then
					savePoint = itemRefs[id][rid][gid]
				else
					savePoint = {}
					itemRefs[id][rid][gid] = savePoint
				end
				for tabID, slots in pairs(refs) do
					savePoint[tabID] = 1
					for _, slotID in ipairs(slots) do
						local slotHolder = tabs[tabID]
						local slot = slotHolder[slotID]
						if type(slot) == 'table' then
							slot[1] = id
						else
							slotHolder[slotID] = id
						end
					end
				end
				numNames = numNames - 1
				if numNames == 0 then
					break
				end
			end
		end
		
		if numNames ~= 0 then
			local nextID = GuildBankDB_Save.nextItemID
			for name, tabIDs in pairs(flatHash) do
				local id = nextID
				nextID = nextID + 1
				cache[id] = name
				local ref = {}
				itemRefs[id] = ref
				local ref2 = {}
				ref[rid] = ref2
				ref = {}
				ref2[gid] = ref
				for tabID, slotIDs in pairs(tabIDs) do
					ref[tabID] = 1
					for _, slotID in ipairs(slotIDs) do
						local slotHolder = tabs[tabID]
						local slot = slotHolder[slotID]
						if type(slot) == 'table' then
							slot[1] = id
						else
							slotHolder[slotID] = id
						end
					end
				end
			end
			GuildBankDB_Save.nextItemID = nextID
		end
	end
	
	local function cacheGBankTab(rid, gid, tabID, flatHash, numNames, slots)
		local cache = GuildBankDB_Save.itemCache
		local itemRefs = GuildBankDB_Save.itemRefs
		
		for id, name in pairs(cache) do
			local refs = flatHash[name]
			if refs then
				flatHash[name] = nil
				if not itemRefs[id] then
					itemRefs[id] = {}
				end
				if not itemRefs[id][rid] then
					itemRefs[id][rid] = {}
				end
				local savePoint
				if itemRefs[id][rid][gid] then
					savePoint = itemRefs[id][rid][gid]
				else
					savePoint = {}
					itemRefs[id][rid][gid] = savePoint
				end
				savePoint[tabID] = 1
				for _, slotID in ipairs(refs) do
					local slot = slots[slotID]
					if type(slot) == 'table' then
						slot[1] = id
					else
						slots[slotID] = id
					end
				end
				numNames = numNames - 1
				if numNames == 0 then
					break
				end
			end
		end
		
		if numNames ~= 0 then
			local nextID = GuildBankDB_Save.nextItemID
			for name, slotIDs in pairs(flatHash) do
				local id = nextID
				nextID = nextID + 1
				cache[id] = name
				local ref = {}
				itemRefs[id] = ref
				local ref2 = {}
				ref[rid] = ref2
				ref = {}
				ref2[gid] = ref
				ref[tabID] = 1
				for _, slotID in ipairs(slotIDs) do
					local slot = slots[slotID]
					if type(slot) == 'table' then
						slot[1] = id
					else
						slots[slotID] = id
					end
				end
			end
			GuildBankDB_Save.nextItemID = nextID
		end
	end
	
	local function getGBank(setupOnly, newGBank)
		local gbankRef
		do
			local rid = getRealmID()
			if GuildBankDB_Save.guildBanks[rid] then
				gbankRef = GuildBankDB_Save.guildBanks[rid]
			else
				gbankRef = {}
				GuildBankDB_Save.guildBanks[rid] = gbankRef
			end
		end
		do
			local gid = getGuildID()
			if setupOnly then
				return gbankRef[gid]
			elseif not newGBank and gbankRef[gid] then
				gbankRef = gbankRef[gid]
			else
				gbankRef[gid] = newGBank or {}
				gbankRef = gbankRef[gid]
			end
		end
		return gbankRef
	end
	
	local function removeBackRef(rid, gid, tabs, flatHash)
		local cache = GuildBankDB_Save.itemCache
		local itemRefs = GuildBankDB_Save.itemRefs
		local handledCodes = {}
		for _, slots in pairs(tabs) do
			for _, slot in pairs(slots) do
				local code
				if type(slot) == 'table' then
					code = slot[1]
				else
					code = slot
				end
				if not handledCodes[code] then
					handledCodes[code] = true
					local ref = itemRefs[code]
					if ref then
						local rref = ref[rid]
						if rref then
							rref[gid] = nil
							if isTableEmpty(rref) then
								ref[rid] = nil
								if isTableEmpty(ref) then
									itemRefs[code] = nil
									if not flatHash or (cache[code] and not flatHash[cache[code]]) then
										cache[code] = nil
									end
								end
							end
						end
					end
				end
			end
		end
	end
	
	local function removeBackRefTab(rid, gid, tabID, slots, flatHash)
		local cache = GuildBankDB_Save.itemCache
		local itemRefs = GuildBankDB_Save.itemRefs
		local handledCodes = {}
		for _, slot in pairs(slots) do
			local code
			if type(slot) == 'table' then
				code = slot[1]
			else
				code = slot
			end
			if not handledCodes[code] then
				handledCodes[code] = true
				local ref = itemRefs[code]
				if ref then
					local rref = ref[rid]
					if rref then
						local gref = rref[gid]
						if gref then
							gref[tabID] = nil
							if isTableEmpty(gref) then
								rref[gid] = nil
								if isTableEmpty(rref) then
									ref[rid] = nil
									if isTableEmpty(ref) then
										itemRefs[code] = nil
										if not flatHash or (cache[code] and not flatHash[cache[code]]) then
											cache[code] = nil
										end
									end
								end
							end
						end
					end
				end
			end
		end
	end
	
	local function setGBank(newGBank)
		-- largest cache transaction unit
		local oldGBank = getGBank(true)
		-- construct flatHash of new elements by name => position
		local numNames = 0
		local flatHash = nil
		if newGBank and newGBank.items and not isTableEmpty(newGBank.items) then
			flatHash = {}
			for tabID, slots in pairs(newGBank.items) do
				local info = slots.info
				slots.info = nil
				if not isTableEmpty(slots) then
					for slotID, slot in pairs(slots) do
						local name = (type(slot) == 'table' and slot[1] or slot)
						if not flatHash[name] then
							flatHash[name] = {}
							numNames = numNames + 1
						end
						if not flatHash[name][tabID] then
							flatHash[name][tabID] = {}
						end
						table.insert(flatHash[name][tabID], slotID)
					end
				end
				slots.info = info
			end
		end
		if oldGBank then
			oldGBank = oldGBank.items
			if oldGBank and not isTableEmpty(oldGBank) then
				removeBackRef(getRealmID(), getGuildID(), oldGBank, flatHash)
			end
		end
		getGBank(false, newGBank)
		if numNames ~= 0 then
			return cacheGBank(getRealmID(), getGuildID(), flatHash, numNames, newGBank.items)
		end
	end
	
	local function setGBankTab(tabID, newTab)
		-- smallest cache transaction unit
		local oldGBank = getGBank(true)
		local flatHash = nil
		local numNames = 0
		if newTab then
			local info = newTab.info
			newTab.info = nil
			if not isTableEmpty(newTab) then
				flatHash = {}
				for slotID, slot in pairs(newTab) do
					local name = (type(slot) == 'table' and slot[1] or slot)
					if not flatHash[name] then
						flatHash[name] = {}
						numNames = numNames + 1
					end
					table.insert(flatHash[name], slotID)
				end
			end
			newTab.info = info
		end
		local oldTab = oldGBank.items[tabID]
		if oldTab and not isTableEmpty(oldTab) then
			removeBackRefTab(getRealmID(), getGuildID(), tabID, oldTab, flatHash)
		end
		oldGBank.items[tabID] = newTab
		if numNames ~= 0 then
			cacheGBankTab(getRealmID(), getGuildID(), tabID, flatHash, numNames, newTab)
		end
	end
	
	
	local playerUnit = 'player'
	
	local refreshGBank
	local resetVerboseGBankRefresh
	do
		local isFirstTime = true
		resetVerboseGBankRefresh = function()
			isFirstTime = true
		end
		refreshGBank = function()
			--log_("refreshGBank")
			if mode == modes.refreshing then
				--log_("Refresh already in progress!")
				return
			end
			local originalTab = GetCurrentGuildBankTab()
			if currentGBankTab == 0 then
				currentGBankTab = originalTab
			end
			if _debug and guildName == nil then
				error("Guild name not set!")
			end
			local numTabs = GetNumGuildBankTabs()
			-- numTabs == 0 means that the contents are hidden!
			if numTabs == 0 then
				return
			end
			setMode(modes.refreshing)
			local gbank = {money = GetGuildBankMoney(), ['numTabs'] = numTabs, canWithdraw = (CanWithdrawGuildBankMoney() and GetGuildBankWithdrawGoldLimit() or nil)}
			
			local items = {}
			for tab=1,numTabs,1 do
				-- Store tab level permissions and other info
				-- {name, icon, isViewable, canDeposit, numWithdrawals, remainingWithdrawals}
				items[tab] = {['info'] = {GetGuildBankTabInfo(tab)}}
			end
			local getNextTab
			do
				local nextTab = 0
				local originalTab = originalTab
				getNextTab = function()
					repeat
						nextTab = nextTab + 1
					until not items[nextTab] or (originalTab ~= nextTab and items[nextTab].info[3])
					if not items[nextTab] then
						nextTab = nil
					end
					return nextTab
				end
			end
			local numTabsUpperBound = numTabs + 1
			local tabShouldBe = originalTab
			local function getCurrentTabItems()
				local _tab = items[tabShouldBe]
				-- continue scanning only if viewable
				if _tab.info[3] then
					for slot=1,98,1 do
						local _, mult = GetGuildBankItemInfo(tabShouldBe, slot)
						if type(mult) == 'number' then
							if mult > 1 then
								_tab[slot] = {deflateItemLinkFromGBank(tabShouldBe, slot), mult}
							else
								_tab[slot] = deflateItemLinkFromGBank(tabShouldBe, slot)
							end
						end
					end
				end
			end
			if not isFirstTime then
				getCurrentTabItems()
				setGBankTab(tabShouldBe, items[tabShouldBe])
				TimedEvent(getCurrentGBankLag() + 0.5, function()
					--log_("Single tab refresh done: Another refresh can be ran!")
					setMode(modes.listening)
				end)
				return
			end
			local function setNextTab()
				tabShouldBe = getNextTab()
				--log_("New Tab Should Be: " .. toString(tabShouldBe))
				if tabShouldBe == nil then
					refreshActionStep = nil
					--log_("refreshActionStep made nil")
					if not isTableEmpty(items) then
						--log_("gbank had items")
						gbank.items = items
					end
					gbank.scanned = {datetime(), getCharID()}
					setGBank(gbank)
					--log_("Bank Info Saved!")
					if currentGBankTab ~= originalTab then
						--log_("Restoring Saved Tab: " .. originalTab .. " from " .. currentGBankTab)
						SetCurrentGuildBankTab(originalTab)
					end
					isFirstTime = false
					TimedEvent(getCurrentGBankLag() + 0.5, function()
						--log_("Another refresh can be ran!")
						setMode(modes.listening)
					end)
				else
					return SetCurrentGuildBankTab(tabShouldBe)
				end
			end
			refreshActionStep = function()
				--log_('refreshActionStep')
				getCurrentTabItems()
				return setNextTab()
			end
			return refreshActionStep()
		end
	end
	
	local function onJoinedGuild()
		--log_("onJoinedGuild")
		guildName = GetGuildInfo(playerUnit)
		GuildBankDB_SaveChar.guild = guildName
	end
	
	local function onLeftGuild()
		--log_("onLeftGuild")
		guildName = nil
		clearGuildID()
	end
	
	local function onLogin(regEvt)
		--log_("onLogin")
		realm = GetRealmName()
		charName = GetUnitName(playerUnit)
		--log_(string.format("%s:%s", realm, charName))
		frame:UnregisterEvent(regEvt)
		if IsInGuild() then
			return setMode(modes.verify_guild_is_same_as_saved)
		elseif guildName ~= nil then
			return onLeftGuild()
		end
	end
	
	local function refreshGuildStatus()
		--log_("refreshGuildStatus")
		local isInGuild = IsInGuild()
		if mode == modes.verify_guild_is_same_as_saved then
			if isInGuild then
				if guildName == nil then
					onJoinedGuild()
				elseif guildName ~= GetGuildInfo(playerUnit) then
					onLeftGuild()
					onJoinedGuild()
				end
				return setMode(modes.idle)
			else
				setMode(modes.idle)
			end
		end
		if guildName == nil then
			if isInGuild then
				onJoinedGuild()
			end
		elseif not isInGuild then
			onLeftGuild()
		end
	end
	
	local handleSlash
	do
		local function findBy(input, validationFunction, options)
			local dateNow = date("%Y-%m-%d")
			local cache = GuildBankDB_Save.itemCache
			local chars = GuildBankDB_Save.chars
			local realms = GuildBankDB_Save.realms
			local guilds = GuildBankDB_Save.guilds
			local itemRefs = GuildBankDB_Save.itemRefs
			local gbanks = GuildBankDB_Save.guildBanks
			local hits = {}
			local numHits = 0
			for itemCode, deflatedItemLink in pairs(cache) do
				if validationFunction(deflatedItemLink) then
					local refs = itemRefs[itemCode]
					local validHit = false
					if refs then
						for rid, gids in pairs(refs) do
							local ref = hits[rid]
							if not ref then
								ref = {}
								hits[rid] = ref
							end
							for gid, tabIDs in pairs(gids) do
								local ref2 = ref[gid]
								if not ref2 then
									ref2 = {}
									ref[gid] = ref2
								end
								ref2[itemCode] = 0
								local ref3 = ref2.tabs
								if not ref3 then
									ref3 = {}
									ref2.tabs = ref3
								end
								if options and options.canWithdraw then
									for tabID, _ in pairs(tabIDs) do
										local gbank = gbanks[rid][gid]
										local info = gbank.items[tabID].info
										-- (-1) means infinite withdrawals
										if info[6] ~= 0 or (info[5] ~= 0 and gbank.scanned[1]:find(dateNow, 1, true) ~= 1) then
											ref3[tabID] = true
											validHit = true
										end
									end
								else
									for tabID, _ in pairs(tabIDs) do
										ref3[tabID] = true
										validHit = true
									end
								end
							end
						end
						if validHit then
							numHits = numHits + 1
						end
					end
				end
			end
			if numHits == 0 then
				print(string.format("Failed to find item \"%s\"", input))
			else
				print(string.format("Search results for \"%s\"", input))
				for rid, gids in pairs(hits) do
					for gid, codeAndTotals in pairs(gids) do
						-- for each slot to scan in scannable guild tabs
						for tabID, _ in pairs(codeAndTotals.tabs) do
							if gbanks[rid] and gbanks[rid][gid] and gbanks[rid][gid].items and gbanks[rid][gid].items[tabID] then
								for slotID, slot in pairs(gbanks[rid][gid].items[tabID]) do
									if slotID ~= 'info' then
										if type(slot) == 'table' then
											local itemCode = slot[1]
											local numOfItem = codeAndTotals[itemCode]
											if numOfItem ~= nil then
												codeAndTotals[itemCode] = numOfItem + slot[2]
											end
										else
											-- slot is actually itemCode
											local numOfItem = codeAndTotals[slot]
											if numOfItem ~= nil then
												codeAndTotals[slot] = numOfItem + 1
											end
										end
									end
								end
							end
						end
						codeAndTotals.tabs = nil
						for itemCode, total in pairs(codeAndTotals) do
							if total ~= 0 then
								print(string.format("%s |cfffff569x%s|r in \"%s\" of %s", inflateItemLink(cache[itemCode]), total, guilds[gid], chars[gbanks[rid][gid].scanned[2]])) -- , realms[rid]
							end
						end
					end
				end
			end
		end
		local function findByItemID(itemID, ...)
			return findBy(itemID, function(...)
				return (getItemIDFromDeflatedLink(...) == itemID)
			end, ...)
		end
		local function findByItemString(itemLink, itemString, ...)
			return findBy(itemLink, function(test)
				return (test == itemString)
			end, ...)
		end
		local function findByItemName(itemName, ...)
			local success, itemString = pcall(deflateItemLink, itemName)
			if success and itemString then
				return findByItemString(itemName, itemString, ...)
			end
			local toLower = string.lower
			local lowItemName = toLower(itemName)
			return findBy(itemName, function(...)
				-- TODO: find out why I need to check for nils
				local nameHere = getItemNameFromDeflatedLink(...)
				if nameHere then
					return toLower(nameHere):find(lowItemName, 1, false)
				end
			end, ...)
		end
		local function find(str, ...)
			if type(str) ~= 'string' then
				return
			end
			if str:find("^#[1-9]+[0-9]*$") then
				return findByItemID(tonumber(string.sub(str, 2)), ...)
			else
				return findByItemName(str, ...)
			end
		end
		-- find with withdrawable constraint
		local function findw(...)
			return find(..., {canWithdraw = true})
		end
		local commands = {
			['find'] = find,
			['findw'] = findw
		}
		handleSlash = function(cmdstr, editBox)
			--log_("handleSlash")
			local cmd, other
			cmd = cmdstr:match("^%s*([^%s]+)%s*$")
			if not cmd then
				--log_("command with params")
				cmd, other = cmdstr:match("^%s*([^%s]+)%s*(.*)$")
				if not cmd then
					return msg(string.format("No command present: %s", cmdstr))
				end
				if other == '' then
					other = nil
				end
			end
			local func = commands[cmd]
			if func then
				return func(other)
			else
				return msg(string.format("Not a valid command: %s", cmd))
			end
		end
	end
	
	local function onVarLoad()
		--log_("onVarLoad")
		if GuildBankDB_Save == nil or GuildBankDB_Save.version ~= version then
			GuildBankDB_Save = {
				['version'] = version,
				nextRealmID = 1,
				realms = {},
				nextGuildID = 1,
				guilds = {},
				nextCharID = 1,
				chars = {},
				nextItemID = 1,
				itemCache = {},
				itemRefs = {},
				guildBanks = {}
			}
		end
		if GuildBankDB_SaveChar == nil or GuildBankDB_SaveChar.version ~= version then
			GuildBankDB_SaveChar = {
				['version'] = version,
				settings = {
					enabled = true
				}
			}
		else
			guildName = GuildBankDB_SaveChar.guild
		end
		SLASH_GBDB1 = "/gdb"
		SlashCmdList.GBDB = handleSlash
	end
	
	local function onGBankOpen()
		--log_("onGBankOpen")
		for k, _ in pairs(modalEventHandlers) do
			frame:RegisterEvent(k)
		end
		if not GuildBankDB_SaveChar.settings.enabled then
			return
		end
		if guildName == nil then
			refreshGuildStatus()
		end
		setMode(modes.waiting_for_tab_update_timeout)
		TimedEvent(
			function(event) -- check if should run by returning value less than 'now'
				return modeChangedAt + 0.5
			end,
			function(event, firedAt) -- run
				return refreshGBank()
			end
		)
	end
	
	local function onTabUpdate()
		--log_("onTabUpdate")
		if mode == modes.waiting_for_tab_update_timeout then
			modeChangedAt = now
		elseif mode == modes.listening then
			return refreshGBank() -- may be too intensive, look into making an event queue that operates after a timeout
		end
	end
	
	local itemLocked = false
	local function onGBankClose()
		--log_("onGBankClose")
		for k, _ in pairs(modalEventHandlers) do
			frame:UnregisterEvent(k)
		end
		currentGBankTab = 0
		itemLocked = false
		resetVerboseGBankRefresh()
		return setMode(modes.idle)
	end
	local onContentChangeOrLoad
	do
		local reusableSyncTimedEvent = nil
		local syncNetLag = 0
		local function getReusableSyncTimedEvent()
			if reusableSyncTimedEvent == nil then
				reusableSyncTimedEvent = TimedEvent(
					function(event) -- check if should run by returning value less than 'now'
						return modeChangedAt + syncNetLag
					end,
					function(event, firedAt) -- run
						--log_(event.id .. " onContentChangeOrLoad: refreshing gbank now: " .. now)
						refreshGBank()
						-- clear the reusableSyncTimedEvent item after 60 seconds
						if reusableSyncTimedEvent ~= nil and reusableSyncTimedEvent.id ~= nil and reusableSyncTimedEvent.id == event.id then
							local currentEventID = reusableSyncTimedEvent.id
							local runAt = now + 60
							TimedEvent(
								function(event)
									if reusableSyncTimedEvent == nil or reusableSyncTimedEvent.id ~= currentEventID then
										dequeueEvent(event.id)
									else
										return runAt
									end
								end,
								function()
									if reusableSyncTimedEvent ~= nil and reusableSyncTimedEvent.id == currentEventID then
										reusableSyncTimedEvent = nil
									end
								end,
								true,
								true,
								false
							)
						end
					end,
					true, -- runOnce
					false -- autoqueue
				)
			end
			return reusableSyncTimedEvent
		end
		local reusableRefreshTimedEvent = nil
		local refreshNetLag = 0
		local function getReusableRefreshInProgressTimedEvent()
			if reusableRefreshTimedEvent == nil then
				reusableRefreshTimedEvent = TimedEvent(
					function(event) -- check if should run by returning value less than 'now'
						return modeChangedAt + refreshNetLag
					end,
					function(event, firedAt) -- run
						refreshActionStep()
						-- clear the reusableRefreshTimedEvent item after 60 seconds
						if reusableRefreshTimedEvent ~= nil and reusableRefreshTimedEvent.id ~= nil and reusableRefreshTimedEvent.id == event.id then
							local currentEventID = reusableRefreshTimedEvent.id
							local runAt = now + 60
							TimedEvent(
								function(event)
									if reusableRefreshTimedEvent == nil or reusableRefreshTimedEvent.id ~= currentEventID then
										dequeueEvent(event.id)
									else
										return runAt
									end
								end,
								function()
									if reusableRefreshTimedEvent ~= nil and reusableRefreshTimedEvent.id == currentEventID then
										reusableRefreshTimedEvent = nil
									end
								end,
								true,
								true,
								false
							)
						end
					end,
					true, -- runOnce
					false -- autoqueue
				)
			end
			return reusableRefreshTimedEvent
		end
		local function queueOrRefreshDelayedGBankSync()
			modeChangedAt = now
			local event = getReusableSyncTimedEvent()
			if isEventInQueue(event.id) then -- event already in the queue!
				return
			end
			syncNetLag = getCurrentGBankLag()
			event.id = getNextEventID()
			enqueueEvent(event)
			--log_("Event " .. event.id .. " queueOrRefreshDelayedGBankSync: " .. syncNetLag)
		end
		local function queueOrRefreshDelayedRefresh()
			modeChangedAt = now
			local event = getReusableRefreshInProgressTimedEvent()
			if isEventInQueue(event.id) then -- event already in the queue!
				return
			end
			refreshNetLag = getCurrentGBankLag()
			event.id = getNextEventID()
			enqueueEvent(event)
			--log_("Event " .. event.id .. " queueOrRefreshDelayedRefresh: " .. refreshNetLag)
		end
		onContentChangeOrLoad = function(event)
			--log_("onContentChangeOrLoad")
			if mode == modes.waiting_for_tab_update_timeout then
				modeChangedAt = now
				return
			end
			local newGBankTab = GetCurrentGuildBankTab()
			if currentGBankTab == newGBankTab then -- content changed
				--log_("ContentChanged: " .. now)
				--log_("now: " .. now)
				if mode == modes.listening then
					queueOrRefreshDelayedGBankSync()
				--elseif mode == modes.refreshing then
				--	dumpEventQueue()
				--	queueOrRefreshDelayedGBankSync()
				end
			else -- first load of this tab
				--log_("FirstTabLoad: " .. now)
				currentGBankTab = newGBankTab
				if mode == modes.refreshing then
					queueOrRefreshDelayedRefresh()
				end
			end
		end
	end
	
	local function onItemLockChange()
		--log_("onItemLockChange")
		itemLocked = not itemLocked
		--log_(toString(itemLocked))
	end
	
	local onAvailMoneyChange
	local onWithdrawMoneyChange
	do
		onAvailMoneyChange = function()
			--log_('onAvailMoneyChange')
			if not GuildBankDB_SaveChar.settings.enabled then
				return
			end
			refreshGuildStatus()
			local gbank = getGBank()
			gbank.money = GetGuildBankMoney()
		end
		
		local onWithdrawMoneyChangeDo = function()
			refreshGuildStatus()
			local gbank = getGBank()
			gbank.canWithdraw = (CanWithdrawGuildBankMoney() and GetGuildBankWithdrawGoldLimit() or nil)
		end
		
		onWithdrawMoneyChange = function()
			--log_('onWithdrawMoneyChange')
			if not GuildBankDB_SaveChar.settings.enabled then
				return
			end
			-- getting failures to refresh guild status on this event when clearly the user must be in a guild to get the event...
			local success, msg = pcall(onWithdrawMoneyChangeDo)
			if not success then
				if string.sub(msg,-string.len(ERR_NOT_IN_GUILD)) == ERR_NOT_IN_GUILD then
					-- note that this could be an inifite loop and the event will be dropped if there is a mode change
					return TimedEvent(now + 1000, onWithdrawMoneyChange)
				else
					error("RETHROWN: " .. (msg and msg or 'UNKNOWN'))
				end
			end
		end
	end
	
	
	-- END: REAL EVENT HANDLERS


	eventHandlers = {
		["PLAYER_LOGIN"] = onLogin, -- initialize player descriptors
		["PLAYER_GUILD_UPDATE"] = refreshGuildStatus, -- fired on guild join/quit events
		["VARIABLES_LOADED"] = onVarLoad, -- fired when saved data becomes available
		["GUILDBANKBAGSLOTS_CHANGED"] = onContentChangeOrLoad, --Fired when the guild-bank contents change
		["GUILDBANKFRAME_CLOSED"] = onGBankClose, -- Fired when the guild-bank frame is closed
		["GUILDBANKFRAME_OPENED"] = onGBankOpen, -- Fired when the guild-bank frame is opened
		["GUILDBANK_ITEM_LOCK_CHANGED"] = onItemLockChange, -- Fires when an item in the guild bank is locked for moving or unlocked afterward
		["GUILDBANK_UPDATE_MONEY"] = onAvailMoneyChange, -- Fires when the amount of money in the guild bank changes
		["GUILDBANK_UPDATE_TABS"] = onTabUpdate, -- Fires when information about guild bank tabs becomes available
		["GUILDBANK_UPDATE_WITHDRAWMONEY"] = onWithdrawMoneyChange -- Fires when the amount of money the player can withdraw from the guild bank changes. Also fires when the player deposits money.
	}
	
	modalEventHandlers = {
		["GUILDBANKFRAME_CLOSED"]       = true,
		["GUILDBANKBAGSLOTS_CHANGED"]   = true,
		["GUILDBANK_ITEM_LOCK_CHANGED"] = true,
		["GUILDBANK_UPDATE_TABS"]       = true
	}
end

local onLoad
do
	local function onEvent(self, event, ...)
		-- --log_("onEvent")
		local handler = eventHandlers[event]
		if handler == nil then
			return
		end
		return handler(event, ...)
	end
	
	onLoad = function()
		--log_("onLoad")
		frame:SetScript("OnEvent", onEvent)
		frame:SetScript("OnUpdate", onUpdate)
		for k,v in pairs(eventHandlers) do
			if not modalEventHandlers[k] then
				frame:RegisterEvent(k)
				if _debug then
					if type(v) == 'function' then
						--log_("Debug: function registered for " .. k)
						eventHandlers[k] = v
					else
						--log_("placeholder registered for " .. k)
						eventHandlers[k] = function()
							return --log_(string.format("Missing event handler for: %s", k))
						end
					end
				else
					--log_("function registered for " .. k)
					eventHandlers[k] = v
				end
			end
		end
	end
end

if not rawequal(frame:GetScript("OnLoad"), onLoad) then
	frame:SetScript("OnLoad", onLoad)
	onLoad()
end
end