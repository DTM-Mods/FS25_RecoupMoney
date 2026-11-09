-- RecoupMoney
-- When a placeable is sold, pays its owner the market value of everything still stored in it: silos, silo
-- extensions, production points, animal storages and feed, manure heaps, bunker silos and any mod placeable that
-- keeps its goods in a standard storage.
-- Each fill type is paid at the best price any selling point currently offers (the same prices the game's price
-- list shows), or at the base price when no selling point buys it.
-- Console commands: rmList

RecoupMoney = {}
RecoupMoney.MOD_NAME = g_currentModName

-- Share of the market value that is paid out (1 = 100 %)
RecoupMoney.PAYOUT_FACTOR = 1.0
-- Pay the base price for goods no selling point buys (chaff, manure, ...); false pays nothing for them
RecoupMoney.PAY_UNSOLD_AT_BASE_PRICE = true
-- Smaller amounts (liters) are ignored
RecoupMoney.MIN_FILL_LEVEL = 0.5
-- Fill types listed by name in the sale notification, the rest go to the log
RecoupMoney.NOTIFICATION_MAX_ITEMS = 3

-- ---------------------------------------------------------------------------------------------
-- Contents
-- ---------------------------------------------------------------------------------------------

-- fillTypeIndex -> liters of a Storage (or anything shaped like one), nil if it has no fill levels
function RecoupMoney.getStorageFillLevels(storage)
    if type(storage) ~= "table" then
        return nil
    end
    if type(storage.getFillLevels) == "function" then
        local ok, fillLevels = pcall(storage.getFillLevels, storage)
        if ok and type(fillLevels) == "table" then
            return fillLevels
        end
    end
    if type(storage.fillLevels) == "table" then
        return storage.fillLevels
    end
    return nil
end

-- Everything stored in a placeable: fillTypeIndex -> liters
function RecoupMoney.getContents(placeable)
    local contents = {}
    local seenStorages = {}

    local function addFillLevel(fillTypeIndex, fillLevel)
        if type(fillTypeIndex) == "number" and fillTypeIndex ~= FillType.UNKNOWN
            and type(fillLevel) == "number" and fillLevel > RecoupMoney.MIN_FILL_LEVEL then
            contents[fillTypeIndex] = (contents[fillTypeIndex] or 0) + fillLevel
        end
    end

    -- Several specializations can point at the same storage (husbandry milk, straw, manure...), count it once
    local function addStorage(storage)
        if type(storage) ~= "table" or seenStorages[storage] then
            return
        end
        seenStorages[storage] = true
        local fillLevels = RecoupMoney.getStorageFillLevels(storage)
        if fillLevels ~= nil then
            for fillTypeIndex, fillLevel in pairs(fillLevels) do
                addFillLevel(fillTypeIndex, fillLevel)
            end
        end
    end

    -- Silos (storages), silo extensions and husbandries (storage), production points (productionPoint.storage),
    -- manure heaps (manureHeap), and mod specializations that follow the same layout
    for key, spec in pairs(placeable) do
        if type(key) == "string" and key:sub(1, 5) == "spec_" and type(spec) == "table" then
            addStorage(spec.storage)
            if type(spec.storages) == "table" then
                for _, storage in pairs(spec.storages) do
                    addStorage(storage)
                end
            end
            if type(spec.productionPoint) == "table" then
                addStorage(spec.productionPoint.storage)
            end
            addStorage(spec.manureHeap)
        end
    end

    -- Feed in the trough is kept by the specialization itself, not in a storage
    local foodSpec = placeable.spec_husbandryFood
    if foodSpec ~= nil and foodSpec.storage == nil and type(foodSpec.fillLevels) == "table" then
        for fillTypeIndex, fillLevel in pairs(foodSpec.fillLevels) do
            addFillLevel(fillTypeIndex, fillLevel)
        end
    end

    -- Bunker silo: chaff until it has fermented, silage after
    local bunkerSilo = placeable.spec_bunkerSilo ~= nil and placeable.spec_bunkerSilo.bunkerSilo or nil
    if type(bunkerSilo) == "table" and type(bunkerSilo.fillLevel) == "number" then
        local fillTypeIndex = bunkerSilo.inputFillType
        if BunkerSilo ~= nil and bunkerSilo.state ~= nil
            and (bunkerSilo.state == BunkerSilo.STATE_FERMENTED or bunkerSilo.state == BunkerSilo.STATE_DRAIN) then
            fillTypeIndex = bunkerSilo.outputFillType
        end
        addFillLevel(fillTypeIndex, bunkerSilo.fillLevel)
    end

    return contents
end

-- ---------------------------------------------------------------------------------------------
-- Prices
-- ---------------------------------------------------------------------------------------------

-- Selling points listed in the game's price list, except the ones belonging to the placeable being valued
function RecoupMoney.getSellingStations(excludePlaceable)
    local stations = {}
    local storageSystem = g_currentMission.storageSystem
    if storageSystem == nil or storageSystem.getUnloadingStations == nil then
        return stations
    end
    for _, station in pairs(storageSystem:getUnloadingStations()) do
        if type(station) == "table" and station.isSellingPoint and not station.hideFromPricesMenu
            and station.acceptedFillTypes ~= nil and station.getEffectiveFillTypePrice ~= nil
            and (excludePlaceable == nil or station.owningPlaceable ~= excludePlaceable) then
            table.insert(stations, station)
        end
    end
    return stations
end

function RecoupMoney.getBasePricePerLiter(fillTypeIndex)
    local economyManager = g_currentMission.economyManager
    if economyManager ~= nil and economyManager.getPricePerLiter ~= nil then
        local ok, price = pcall(economyManager.getPricePerLiter, economyManager, fillTypeIndex)
        if ok and type(price) == "number" then
            return price
        end
    end
    local fillType = g_fillTypeManager:getFillTypeByIndex(fillTypeIndex)
    return (fillType ~= nil and fillType.pricePerLiter) or 0
end

-- Best current price per liter and whether a selling point offers it (false = base price fallback)
function RecoupMoney.getPricePerLiter(fillTypeIndex, stations)
    local bestPrice = 0
    for _, station in ipairs(stations) do
        if station.acceptedFillTypes[fillTypeIndex] then
            local ok, price = pcall(station.getEffectiveFillTypePrice, station, fillTypeIndex)
            if ok and type(price) == "number" and price > bestPrice then
                bestPrice = price
            end
        end
    end
    if bestPrice > 0 then
        return bestPrice, true
    end
    if RecoupMoney.PAY_UNSOLD_AT_BASE_PRICE then
        return math.max(RecoupMoney.getBasePricePerLiter(fillTypeIndex), 0), false
    end
    return 0, false
end

function RecoupMoney.getFillTypeTitle(fillTypeIndex)
    local fillType = g_fillTypeManager:getFillTypeByIndex(fillTypeIndex)
    if fillType == nil then
        return tostring(fillTypeIndex)
    end
    return fillType.title or fillType.name
end

-- Total payout for a placeable's contents and the lines it is made of, highest value first:
-- {fillTypeIndex, title, fillLevel, pricePerLiter, atMarket, value}
function RecoupMoney.getContentsValue(placeable)
    local stations = RecoupMoney.getSellingStations(placeable)
    local lines = {}
    local total = 0

    for fillTypeIndex, fillLevel in pairs(RecoupMoney.getContents(placeable)) do
        local pricePerLiter, atMarket = RecoupMoney.getPricePerLiter(fillTypeIndex, stations)
        local value = fillLevel * pricePerLiter * RecoupMoney.PAYOUT_FACTOR
        total = total + value
        table.insert(lines, {fillTypeIndex = fillTypeIndex, title = RecoupMoney.getFillTypeTitle(fillTypeIndex),
            fillLevel = fillLevel, pricePerLiter = pricePerLiter, atMarket = atMarket, value = value})
    end

    table.sort(lines, function(a, b)
        if a.value ~= b.value then
            return a.value > b.value
        end
        return a.title < b.title
    end)

    return math.floor(total), lines
end

-- ---------------------------------------------------------------------------------------------
-- Selling
-- ---------------------------------------------------------------------------------------------

function RecoupMoney.formatNumber(value)
    local str = tostring(math.floor(value + 0.5))
    local sign, digits = str:match("^(-?)(%d+)$")
    if digits == nil then
        return str
    end
    digits = digits:reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", "")
    return sign .. digits
end

function RecoupMoney.formatLine(line)
    return string.format("%-24s %12s l  x %s/1000 l%s = %s", line.title, RecoupMoney.formatNumber(line.fillLevel),
        g_i18n:formatMoney(line.pricePerLiter * 1000, 0, true, true), line.atMarket and "" or " (base price)",
        g_i18n:formatMoney(line.value, 0, true, true))
end

function RecoupMoney.getMoneyType()
    return MoneyType.HARVEST_INCOME or MoneyType.OTHER
end

-- Server only: runs just before the placeable's own onSell, while its storages are still full
function RecoupMoney.payOut(placeable)
    if placeable.recoupMoneyPaid or not g_currentMission:getIsServer() then
        return
    end

    local farmId = placeable:getOwnerFarmId()
    if farmId == nil or farmId == FarmManager.SPECTATOR_FARM_ID or farmId == FarmlandManager.NO_OWNER_FARM_ID then
        return
    end

    local total, lines = RecoupMoney.getContentsValue(placeable)
    if total < 1 then
        return
    end
    placeable.recoupMoneyPaid = true

    g_currentMission:addMoney(total, farmId, RecoupMoney.getMoneyType(), true, true)

    local name = placeable:getName() or "?"
    print(string.format("RecoupMoney: sold contents of '%s' (farm %d) for %s", name, farmId, g_i18n:formatMoney(total, 0, true, true)))
    for _, line in ipairs(lines) do
        print("  " .. RecoupMoney.formatLine(line))
    end

    if g_currentMission:getFarmId() == farmId and g_currentMission.addIngameNotification ~= nil then
        local items = {}
        for i, line in ipairs(lines) do
            if i > RecoupMoney.NOTIFICATION_MAX_ITEMS then
                table.insert(items, string.format(g_i18n:getText("recoupMoney_more"), #lines - RecoupMoney.NOTIFICATION_MAX_ITEMS))
                break
            end
            table.insert(items, string.format("%s %s l", line.title, RecoupMoney.formatNumber(line.fillLevel)))
        end
        local text = string.format(g_i18n:getText("recoupMoney_notification"), name, g_i18n:formatMoney(total, 0, true, true),
            table.concat(items, ", "))
        g_currentMission:addIngameNotification(FSBaseMission.INGAME_NOTIFICATION_OK, text)
    end
end

function RecoupMoney.onPlaceableSell(placeable)
    -- Never let a problem here stop the sale itself
    local ok, err = pcall(RecoupMoney.payOut, placeable)
    if not ok then
        Logging.error("RecoupMoney: could not pay out the contents of a sold placeable: %s", tostring(err))
    end
end

Placeable.onSell = Utils.prependedFunction(Placeable.onSell, RecoupMoney.onPlaceableSell)

-- ---------------------------------------------------------------------------------------------
-- Console
-- ---------------------------------------------------------------------------------------------

-- Every placeable of the farm holding goods, and what selling it would pay
function RecoupMoney:consoleList(farmIdText)
    local farmId = tonumber(farmIdText) or g_currentMission:getFarmId()
    local placeableSystem = g_currentMission.placeableSystem
    if placeableSystem == nil then
        return "No placeables"
    end

    local count, grandTotal = 0, 0
    print(string.format("RecoupMoney - farm %d", farmId))
    for _, placeable in ipairs(placeableSystem.placeables) do
        if placeable:getOwnerFarmId() == farmId then
            local total, lines = RecoupMoney.getContentsValue(placeable)
            if #lines > 0 then
                count = count + 1
                grandTotal = grandTotal + total
                print(string.format("%s: %s", placeable:getName() or "?", g_i18n:formatMoney(total, 0, true, true)))
                for _, line in ipairs(lines) do
                    print("  " .. RecoupMoney.formatLine(line))
                end
            end
        end
    end
    return string.format("%d placeable(s) holding goods worth %s in total", count, g_i18n:formatMoney(grandTotal, 0, true, true))
end

function RecoupMoney:loadMap(name)
    addConsoleCommand("rmList", "Recoup Money: what selling each placeable's contents would pay", "consoleList", RecoupMoney, "[farmId]")
end

function RecoupMoney:deleteMap()
    removeConsoleCommand("rmList")
end

addModEventListener(RecoupMoney)
