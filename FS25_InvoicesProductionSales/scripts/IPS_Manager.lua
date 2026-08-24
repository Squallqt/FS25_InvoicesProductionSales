-- Copyright © 2026 Squallqt. All rights reserved.
---Server-authoritative offers, transactions, receipts and persistence.
IPS_Manager = {}
local IPS_Manager_mt = Class(IPS_Manager)

IPS_Manager.SAVE_VERSION = 3
IPS_Manager.MIN_INVOICE_VERSION = {1, 2, 0, 0}
IPS_Manager.WORK_TYPE_PRODUCT = 55
IPS_Manager.MODE_NONE = 0
IPS_Manager.MODE_BULK = 1
IPS_Manager.MODE_PALLET = 2
IPS_Manager.MODE_BOTH = 3
IPS_Manager.SCAN_INTERVAL = 1000
IPS_Manager.SNAPSHOT_REQUEST_INTERVAL = 1000
IPS_Manager.COMMAND_REFILL_INTERVAL = 1000
IPS_Manager.COMMAND_BUCKET_CAPACITY = 3
IPS_Manager.MAX_PALLET_PURCHASE = 250
IPS_Manager.MAX_PALLET_COUNT = 65535
IPS_Manager.MAX_BATCH_LINES = 32767
IPS_Manager.MAX_EXACT_FLOAT32_INTEGER = 16777216
IPS_Manager.MAX_INT32 = IPS_Util.MAX_INT32

---Creates a mission-scoped manager.
-- @return IPS_Manager New manager
function IPS_Manager.new()
    local self = setmetatable({}, IPS_Manager_mt)
    self.offers = {}
    self.clientOffersByProduction = {}
    self.openBatches = {}
    self.openBatchByPair = {}
    self.closedReceipts = {}
    self.activeSessions = {}
    self.startAuthorizations = {}
    self.batchLineReservations = {}
    self.productionByUniqueId = {}
    self.productionByStation = {}
    self.productionByTrigger = {}
    self.snapshotRequestTimes = setmetatable({}, {__mode = "k"})
    self.pendingSnapshotRequests = setmetatable({}, {__mode = "k"})
    self.commandRequestTimes = setmetatable({}, {__mode = "k"})
    self.snapshot = {compatible = false, market = {}, outputs = {}, batches = {}, purchases = {}}
    self.nextBatchId = 1
    self.scanTimer = 0
    self.integrationAvailable = false
    self.integrationErrorKey = nil
    self.integrationErrorShown = false
    self.invoiceEnvironment = nil
    self.invoiceClass = nil
    self.invoiceRoot = nil
    self.invoiceManager = nil
    return self
end

---Resolves the isolated FS25_Invoices script environment.
-- @param table? modData Invoice mod metadata
-- @return table|nil Invoice script environment
function IPS_Manager.getInvoiceEnvironment(modData)
    local environment = nil
    if g_thGlobalEnv ~= nil then
        environment = g_thGlobalEnv["FS25_Invoices"]
    end
    if environment == nil then
        local globalMetaTable = getmetatable(_G)
        local globalEnvironment = globalMetaTable ~= nil and type(globalMetaTable.__index) == "table"
            and globalMetaTable.__index or _G
        environment = globalEnvironment ~= nil and globalEnvironment["FS25_Invoices"] or nil
    end
    if environment == nil and modData ~= nil then
        environment = modData.environment or modData._G
    end
    if environment ~= nil and environment._G ~= nil then
        environment = environment._G
    end
    return environment
end

---Returns a localized companion text.
-- @param string key Localization key
-- @return string Localized value
function IPS_Manager:getText(key)
    return g_i18n:getText(key, InvoicesProductionSales.modName)
end

---Returns the active savegame directory with a trailing slash.
-- @return string Savegame directory
function IPS_Manager:getSavegameDirectory()
    local path = g_currentMission.missionInfo.savegameDirectory
    if path == nil then
        path = ("%ssavegame%d"):format(getUserProfileAppPath(), g_currentMission.missionInfo.savegameIndex)
    end
    return path .. "/"
end

---Compares a dotted version against the minimum supported Invoice version.
-- @param string version Version text
-- @return boolean True when version is at least the minimum
function IPS_Manager:isInvoiceVersionSupported(version)
    if type(version) ~= "string" then
        return false
    end
    local parsed = {}
    for part in string.gmatch(version, "(%d+)") do
        table.insert(parsed, tonumber(part))
    end
    if #parsed < 4 then
        return false
    end
    for index = 1, 4 do
        local current = parsed[index] or 0
        local minimum = IPS_Manager.MIN_INVOICE_VERSION[index]
        if current > minimum then
            return true
        elseif current < minimum then
            return false
        end
    end
    return true
end

---Resolves and validates the public Invoice 1.2.0.0+ integration contract.
-- @return boolean True when every required symbol is available
function IPS_Manager:resolveInvoiceContract()
    if g_modManager == nil or g_modManager.getModByName == nil then
        self.integrationErrorKey = "ips_error_invoiceIncompatible"
        return false
    end

    local modData = g_modManager:getModByName("FS25_Invoices")
    if modData == nil then
        self.integrationErrorKey = "ips_error_invoiceIncompatible"
        return false
    end
    self.detectedInvoiceVersion = modData.version
    if not self:isInvoiceVersionSupported(modData.version) then
        self.integrationErrorKey = "ips_error_invoiceIncompatible"
        return false
    end

    local environment = IPS_Manager.getInvoiceEnvironment(modData)
    local invoiceClass = environment ~= nil and environment.Invoice or nil
    local invoiceRoot = environment ~= nil and environment.Invoices or nil
    local invoiceManager = g_currentMission.invoicesManager

    local valid = invoiceClass ~= nil
        and invoiceClass.STATE ~= nil
        and invoiceClass.STATE.PAID ~= nil
        and invoiceClass.UNIT_LITER ~= nil
        and type(invoiceClass.new) == "function"
        and type(invoiceClass.computeLineGross) == "function"
        and type(invoiceClass.computeTotals) == "function"
        and type(invoiceClass.populateFromData) == "function"
        and type(invoiceClass.writeStream) == "function"
        and type(invoiceClass.readStream) == "function"
        and invoiceRoot ~= nil
        and invoiceManager ~= nil
        and invoiceManager.repository ~= nil
        and type(invoiceManager.repository.add) == "function"
        and type(invoiceManager.repository.getById) == "function"
        and type(invoiceManager.repository.getAll) == "function"
        and invoiceManager.service ~= nil
        and type(invoiceManager.service.isVatEnabled) == "function"
        and type(invoiceManager.service.getVatRateForWorkType) == "function"
        and type(invoiceManager.service.notifyUI) == "function"
        and MoneyType.INVOICE_INCOME ~= nil
        and MoneyType.INVOICE_EXPENSE ~= nil

    if not valid then
        self.integrationErrorKey = "ips_error_invoiceIncompatible"
        return false
    end

    self.invoiceEnvironment = environment
    self.invoiceClass = invoiceClass
    self.invoiceRoot = invoiceRoot
    self.invoiceManager = invoiceManager
    return true
end

---Initializes persistence, subscriptions and compatibility state.
function IPS_Manager:initialize()
    self.integrationAvailable = self:resolveInvoiceContract()
    self:rebuildProductionIndex()

    if g_currentMission:getIsServer() then
        self:loadFromXML(self:getSavegameDirectory())
        self:reconcileReceiptReferences()
        self:validateOffers()
        g_messageCenter:subscribe(MessageType.PERIOD_CHANGED, self.onPeriodChanged, self)
        if MessageType.PLACEABLE_ADDED ~= nil then
            g_messageCenter:subscribe(MessageType.PLACEABLE_ADDED, self.onPlaceableAdded, self)
        end
        if MessageType.PLACEABLE_REMOVED ~= nil then
            g_messageCenter:subscribe(MessageType.PLACEABLE_REMOVED, self.onPlaceableRemoved, self)
        end
        g_currentMission:addUpdateable(self)
    end

    if MessageType.PLAYER_FARM_CHANGED ~= nil then
        g_messageCenter:subscribe(MessageType.PLAYER_FARM_CHANGED, self.onPlayerFarmChanged, self)
    end

    if not self.integrationAvailable then
        self:disableAllOffersForIntegrationFailure()
        self:showIntegrationError()
    end
end

---Releases subscriptions and active sessions.
function IPS_Manager:delete()
    self:stopAllSessions(false)
    if g_messageCenter ~= nil then
        g_messageCenter:unsubscribeAll(self)
    end
    if g_currentMission ~= nil and g_currentMission.removeUpdateable ~= nil then
        g_currentMission:removeUpdateable(self)
    end
    self.startAuthorizations = {}
    self.batchLineReservations = {}
    self.clientOffersByProduction = {}
    self.productionByUniqueId = {}
    self.productionByStation = {}
    self.productionByTrigger = {}
    self.snapshotRequestTimes = {}
    self.pendingSnapshotRequests = {}
    self.commandRequestTimes = {}
end

---Performs periodic owner/deletion validation on the server.
-- @param number dt Delta time in milliseconds
function IPS_Manager:update(dt)
    if g_server == nil then
        return
    end
    self:flushPendingSnapshotRequests()
    self.scanTimer = self.scanTimer - dt
    if self.scanTimer <= 0 then
        self.scanTimer = IPS_Manager.SCAN_INTERVAL
        self:rebuildProductionIndex()
        self:validateOffers()
        self:validateActiveSessions()
    end
end

---Shows the fail-closed integration error once on a local client.
function IPS_Manager:showIntegrationError()
    if self.integrationErrorShown then
        return
    end
    self.integrationErrorShown = true
    local key = self.integrationErrorKey or "ips_error_invoiceIncompatible"
    local text = self:getText(key)
    if key == "ips_error_invoiceIncompatible" then
        text = string.format(text, tostring(self.detectedInvoiceVersion or "?"))
    end
    Logging.error("[InvoicesProductionSales] %s", text)
    if g_currentMission ~= nil and g_currentMission.addIngameNotification ~= nil and g_localPlayer ~= nil then
        g_currentMission:addIngameNotification(FSBaseMission.INGAME_NOTIFICATION_CRITICAL, text)
    end
end

---Disables public offers after an integration failure.
function IPS_Manager:disableAllOffersForIntegrationFailure()
    self:stopAllSessions(true)
    self.clientOffersByProduction = {}
    if g_server ~= nil then
        for _, offer in pairs(self.offers) do
            if offer.enabled then
                offer.enabled = false
                offer.revision = (offer.revision or 0) + 1
            end
        end
    end
end

---Rebuilds runtime indexes from registered production points.
function IPS_Manager:rebuildProductionIndex()
    self.productionByUniqueId = {}
    self.productionByStation = {}
    self.productionByTrigger = {}

    local chain = g_currentMission ~= nil and g_currentMission.productionChainManager or nil
    for _, productionPoint in ipairs(chain ~= nil and chain.productionPoints or {}) do
        local placeable = productionPoint.owningPlaceable
        local uniqueId = placeable ~= nil and placeable.getUniqueId ~= nil and placeable:getUniqueId() or nil
        if uniqueId ~= nil and uniqueId ~= "" then
            self.productionByUniqueId[uniqueId] = productionPoint
            local station = productionPoint.loadingStation
            if station ~= nil and station.owningPlaceable == placeable then
                self.productionByStation[station] = productionPoint
                for _, trigger in ipairs(station.loadTriggers or {}) do
                    if trigger.source == station then
                        self.productionByTrigger[trigger] = productionPoint
                    end
                end
            end
        end
    end
end

---Returns production identity and current owner.
-- @param table productionPoint Production point
-- @return string|nil uniqueId Stable placeable identifier
-- @return integer|nil ownerFarmId Current owner farm
function IPS_Manager:getProductionIdentity(productionPoint)
    local placeable = productionPoint ~= nil and productionPoint.owningPlaceable or nil
    local uniqueId = placeable ~= nil and placeable.getUniqueId ~= nil and placeable:getUniqueId() or nil
    local ownerFarmId = placeable ~= nil and placeable.getOwnerFarmId ~= nil and placeable:getOwnerFarmId() or nil
    if ownerFarmId == nil and productionPoint ~= nil and productionPoint.getOwnerFarmId ~= nil then
        ownerFarmId = productionPoint:getOwnerFarmId()
    end
    return uniqueId, ownerFarmId
end

---Returns whether an output currently uses the native Store mode.
-- @param table productionPoint Production point
-- @param integer fillTypeIndex Fill type identifier
-- @return boolean True when stored
function IPS_Manager:isOutputStored(productionPoint, fillTypeIndex)
    return productionPoint ~= nil
        and productionPoint.outputFillTypeIds ~= nil
        and productionPoint.outputFillTypeIds[fillTypeIndex] == true
        and not (productionPoint.outputFillTypeIdsDirectSell or {})[fillTypeIndex]
        and not (productionPoint.outputFillTypeIdsAutoDeliver or {})[fillTypeIndex]
end

---Returns whether a trigger can safely host confirmed paid loading.
-- @param table trigger Load trigger
-- @return boolean True for manual triggers
function IPS_Manager:isPaidBulkTrigger(trigger)
    return trigger ~= nil and not trigger.autoStart and not trigger.automaticFilling
end

---Returns supported public sale modes for an output.
-- @param table productionPoint Production point
-- @param integer fillTypeIndex Fill type identifier
-- @return integer Mode constant
function IPS_Manager:getOutputMode(productionPoint, fillTypeIndex)
    local hasBulk = false
    local station = productionPoint ~= nil and productionPoint.loadingStation or nil
    if station ~= nil then
        for _, trigger in ipairs(station.loadTriggers or {}) do
            if self:isPaidBulkTrigger(trigger)
                and (trigger.fillTypes == nil or trigger.fillTypes[fillTypeIndex]) then
                hasBulk = true
                break
            end
        end
    end
    local hasPallet = productionPoint ~= nil
        and productionPoint.palletSpawner ~= nil
        and (productionPoint.outputFillTypeIdsToPallets or {})[fillTypeIndex] ~= nil

    if hasBulk and hasPallet then return IPS_Manager.MODE_BOTH end
    if hasBulk then return IPS_Manager.MODE_BULK end
    if hasPallet then return IPS_Manager.MODE_PALLET end
    return IPS_Manager.MODE_NONE
end

---Returns a production display name.
-- @param table productionPoint Production point
-- @return string Display name
function IPS_Manager:getProductionName(productionPoint)
    local placeable = productionPoint ~= nil and productionPoint.owningPlaceable or nil
    if placeable ~= nil and placeable.getName ~= nil then
        return placeable:getName() or ""
    end
    return ""
end

---Returns fill type display metadata.
-- @param integer fillTypeIndex Fill type identifier
-- @return string title Display title
-- @return string iconFilename HUD icon path
function IPS_Manager:getFillTypeMetadata(fillTypeIndex)
    local fillType = g_fillTypeManager ~= nil and g_fillTypeManager:getFillTypeByIndex(fillTypeIndex) or nil
    if fillType == nil then
        return tostring(fillTypeIndex), ""
    end
    return fillType.title or fillType.name or tostring(fillTypeIndex), fillType.hudOverlayFilename or ""
end

---Returns a farm display name.
-- @param integer farmId Farm identifier
-- @return string Farm name
function IPS_Manager:getFarmName(farmId)
    local farm = g_farmManager ~= nil and g_farmManager:getFarmById(farmId) or nil
    return farm ~= nil and farm.name or tostring(farmId)
end

---Returns current seller stock, including native storage extensions.
-- @param table productionPoint Production point
-- @param integer fillTypeIndex Fill type identifier
-- @param integer sellerFarmId Seller farm
-- @return number Liters in storage
function IPS_Manager:getOutputStock(productionPoint, fillTypeIndex, sellerFarmId)
    local station = productionPoint ~= nil and productionPoint.loadingStation or nil
    if station ~= nil and station.getAllFillLevels ~= nil then
        local levels = station:getAllFillLevels(sellerFarmId) or {}
        if levels[fillTypeIndex] ~= nil then
            return math.max(levels[fillTypeIndex], 0)
        end
    end
    local storage = productionPoint ~= nil and productionPoint.storage or nil
    if storage ~= nil and storage.getFillLevel ~= nil then
        return math.max(storage:getFillLevel(fillTypeIndex) or 0, 0)
    end
    return 0
end

---Returns a deterministic vehicle identifier.
-- @param table vehicle Vehicle
-- @return string Unique identifier
function IPS_Manager:getVehicleUniqueId(vehicle)
    if vehicle ~= nil and vehicle.getUniqueId ~= nil then
        return vehicle:getUniqueId() or ""
    end
    return ""
end

---Enumerates full seller-owned pallets still inside the exact spawner area.
-- @param table productionPoint Production point
-- @param integer fillTypeIndex Fill type identifier
-- @param integer sellerFarmId Seller farm
-- @return table Pallet records sorted by unique identifier
function IPS_Manager:getFullPallets(productionPoint, fillTypeIndex, sellerFarmId)
    local records = {}
    local spawner = productionPoint ~= nil and productionPoint.palletSpawner or nil
    if spawner == nil or spawner.getAllPallets == nil then
        return records
    end

    spawner:getAllPallets(fillTypeIndex, function(_, pallets)
        for _, pallet in ipairs(pallets or {}) do
            local fillUnitIndex = pallet.spec_pallet ~= nil and pallet.spec_pallet.fillUnitIndex or nil
            local ownerFarmId = pallet.getOwnerFarmId ~= nil and pallet:getOwnerFarmId() or pallet.ownerFarmId
            if fillUnitIndex ~= nil
                and ownerFarmId == sellerFarmId
                and pallet:getFillUnitFillType(fillUnitIndex) == fillTypeIndex then
                local fillLevel = pallet:getFillUnitFillLevel(fillUnitIndex) or 0
                local capacity = pallet:getFillUnitCapacity(fillUnitIndex) or 0
                if capacity > 0 and capacity - fillLevel <= IPS_Util.EPSILON then
                    local uniqueId = self:getVehicleUniqueId(pallet)
                    if uniqueId ~= "" then
                        table.insert(records, {
                            vehicle = pallet,
                            uniqueId = uniqueId,
                            fillUnitIndex = fillUnitIndex,
                            liters = fillLevel
                        })
                    end
                end
            end
        end
    end, self)

    table.sort(records, function(a, b) return a.uniqueId < b.uniqueId end)
    return records
end

---Returns the exact volume contained in a whole number of sorted pallet records.
-- @param table records Available full pallet records
-- @param integer quantity Requested pallet count
-- @return number|nil Exact liters or nil when the quantity is invalid
function IPS_Manager:getPalletLitersForQuantity(records, quantity)
    quantity = IPS_Util.sanitizeQuantity(quantity)
    if quantity == nil or quantity > #(records or {}) then
        return nil
    end

    local totalLiters = 0
    for index = 1, quantity do
        local liters = records[index] ~= nil and records[index].liters or nil
        if not IPS_Util.isFiniteNumber(liters) or liters <= IPS_Util.EPSILON then
            return nil
        end
        totalLiters = totalLiters + liters
    end
    return totalLiters
end

---Returns the volume that can be listed for the output's supported sale modes.
-- @param table productionPoint Production point
-- @param integer fillTypeIndex Fill type identifier
-- @param integer sellerFarmId Seller farm
-- @param table? fullPallets Already enumerated full pallets
-- @return number Offerable liters
function IPS_Manager:getOfferableLiters(productionPoint, fillTypeIndex, sellerFarmId, fullPallets)
    local mode = self:getOutputMode(productionPoint, fillTypeIndex)
    local liters = 0
    if mode == IPS_Manager.MODE_BULK or mode == IPS_Manager.MODE_BOTH then
        liters = liters + self:getOutputStock(productionPoint, fillTypeIndex, sellerFarmId)
    end
    if mode == IPS_Manager.MODE_PALLET or mode == IPS_Manager.MODE_BOTH then
        for _, record in ipairs(fullPallets or self:getFullPallets(productionPoint, fillTypeIndex, sellerFarmId)) do
            liters = liters + math.max(record.liters or 0, 0)
        end
    end
    return math.max(liters, 0)
end

---Builds a compact token detecting changes to a pallet catalog.
-- @param table records Pallet records
-- @return string Deterministic token
function IPS_Manager:getPalletToken(records)
    local checksum = 0
    local totalLiters = 0
    for _, record in ipairs(records or {}) do
        local text = record.uniqueId or ""
        for index = 1, #text do
            checksum = (checksum * 33 + string.byte(text, index)) % 2147483647
        end
        totalLiters = totalLiters + (record.liters or 0)
    end
    return string.format("%d:%d:%.3f", #records, checksum, totalLiters)
end

---Returns current game market price per 1000 liters.
-- @param integer fillTypeIndex Fill type identifier
-- @return number Valid price
function IPS_Manager:getDefaultPrice(fillTypeIndex)
    local economy = g_currentMission ~= nil and g_currentMission.economyManager or nil
    local price = economy ~= nil and economy:getPricePerLiter(fillTypeIndex) or 0
    return math.max(IPS_Util.roundCurrency((price or 0) * 1000), 1)
end

---Returns the unsold quantity remaining on an offer.
-- @param table? offer Offer data
-- @return number Remaining liters
function IPS_Manager:getOfferRemainingLiters(offer)
    local remaining = offer ~= nil and offer.remainingLiters or 0
    if not IPS_Util.isFiniteNumber(remaining) then
        return 0
    end
    return math.max(remaining, 0)
end

---Returns the unsold pallet count for a pallet-quantity offer.
-- @param table? offer Offer data
-- @return integer Remaining full pallets
function IPS_Manager:getOfferRemainingPallets(offer)
    local remaining = offer ~= nil and offer.remainingPallets or 0
    if not IPS_Util.isFiniteNumber(remaining) or remaining < 0 or remaining ~= math.floor(remaining) then
        return 0
    end
    return remaining
end

---Returns whether an offer still has quantity in its authoritative sale unit.
-- @param table? offer Offer data
-- @param integer mode Output sale mode
-- @return boolean True while the offer has unsold quantity
function IPS_Manager:getOfferHasRemainingQuantity(offer, mode)
    if mode == IPS_Manager.MODE_PALLET and (offer ~= nil and offer.listedPallets or 0) > 0 then
        return self:getOfferRemainingPallets(offer) > 0
    end
    return self:getOfferRemainingLiters(offer) > IPS_Util.EPSILON
end

---Returns the quantity currently available to external buyers.
-- @param table offer Active offer
-- @param table productionPoint Production point
-- @return number Available liters
function IPS_Manager:getAvailableOfferLiters(offer, productionPoint)
    local physicalStock = self:getOutputStock(productionPoint, offer.fillTypeIndex, offer.sellerFarmId)
    return math.min(math.max(physicalStock or 0, 0), self:getOfferRemainingLiters(offer))
end

---Limits full pallets to the unsold quantity of an offer.
-- @param table offer Active offer
-- @param table productionPoint Production point
-- @param table? fullPallets Already enumerated full pallets
-- @return table Purchasable pallet records
function IPS_Manager:getAvailableOfferPallets(offer, productionPoint, fullPallets)
    local records = fullPallets or self:getFullPallets(productionPoint, offer.fillTypeIndex, offer.sellerFarmId)
    local result = {}
    if (offer.listedPallets or 0) > 0 then
        local remainingPallets = self:getOfferRemainingPallets(offer)
        for _, record in ipairs(records) do
            if #result >= remainingPallets then break end
            table.insert(result, record)
        end
        return result
    end

    local remaining = self:getOfferRemainingLiters(offer)
    for _, record in ipairs(records) do
        if record.liters <= remaining + IPS_Util.EPSILON then
            table.insert(result, record)
            remaining = remaining - record.liters
        end
    end
    return result
end

---Consumes full pallets and closes an exhausted pallet-quantity offer.
-- @param table offer Active offer
-- @param number liters Exact sold volume
-- @param integer quantity Sold pallet count
-- @return boolean True when the offer was exhausted
function IPS_Manager:consumeOfferPallets(offer, liters, quantity)
    offer.remainingLiters = math.max(self:getOfferRemainingLiters(offer) - math.max(liters or 0, 0), 0)
    offer.remainingPallets = math.max(self:getOfferRemainingPallets(offer) - math.max(quantity or 0, 0), 0)
    if offer.remainingPallets <= 0 then
        offer.remainingLiters = 0
        offer.remainingPallets = 0
        offer.enabled = false
        offer.revision = (offer.revision or 0) + 1
        return true
    end
    return false
end

---Consumes sold liters and closes an exhausted offer.
-- @param table offer Active offer
-- @param number liters Sold volume
-- @return boolean True when the offer was exhausted
function IPS_Manager:consumeOfferLiters(offer, liters)
    offer.remainingLiters = math.max(self:getOfferRemainingLiters(offer) - math.max(liters or 0, 0), 0)
    if offer.remainingLiters <= IPS_Util.EPSILON then
        offer.remainingLiters = 0
        offer.enabled = false
        offer.revision = (offer.revision or 0) + 1
        return true
    end
    return false
end

---Closes offers only when their persisted business state is durably invalid.
function IPS_Manager:validateOffers()
    local changed = false
    for _, offer in pairs(self.offers) do
        local productionPoint = self.productionByUniqueId[offer.productionUniqueId]
        local _, ownerFarmId = self:getProductionIdentity(productionPoint)
        local mode = productionPoint ~= nil and self:getOutputMode(productionPoint, offer.fillTypeIndex) or IPS_Manager.MODE_NONE
        local invalid = not self.integrationAvailable
            or not self:getOfferHasRemainingQuantity(offer, mode)
            or (productionPoint ~= nil and ownerFarmId ~= offer.sellerFarmId)
        if offer.enabled and invalid then
            offer.enabled = false
            offer.revision = (offer.revision or 0) + 1
            self:stopSessionsForOffer(offer.key, true)
            changed = true
        end
    end
    if changed then
        self:broadcastRefresh()
    end
end

---Returns a valid active offer for a production output.
-- @param table productionPoint Production point
-- @param integer fillTypeIndex Fill type identifier
-- @return table|nil Offer
function IPS_Manager:getActiveOffer(productionPoint, fillTypeIndex)
    if not self.integrationAvailable then
        return nil
    end
    local uniqueId, ownerFarmId = self:getProductionIdentity(productionPoint)
    local offer
    if g_server == nil then
        local productionOffers = self.clientOffersByProduction[productionPoint]
        offer = productionOffers ~= nil and productionOffers[fillTypeIndex] or nil
    elseif uniqueId ~= nil then
        offer = self.offers[IPS_Util.makeOfferKey(uniqueId, fillTypeIndex)]
    end
    local mode = g_server == nil and offer ~= nil and offer.mode or self:getOutputMode(productionPoint, fillTypeIndex)
    if offer == nil
        or not offer.enabled
        or offer.sellerFarmId ~= ownerFarmId
        or not self:getOfferHasRemainingQuantity(offer, mode) then
        return nil
    end
    if not self:isOutputStored(productionPoint, fillTypeIndex) then
        return nil
    end
    if mode == nil or mode == IPS_Manager.MODE_NONE then
        return nil
    end
    return offer
end

---Refreshes client catalog authorization and active server sessions after a farm switch.
function IPS_Manager:onPlayerFarmChanged()
    if g_server ~= nil then
        self:validateActiveSessions()
    end
    if g_client ~= nil then
        self.clientOffersByProduction = {}
        self:requestSnapshot()
    end
end

---Returns a paid offer at a trigger for an external buyer.
-- @param table trigger Load trigger
-- @param integer fillTypeIndex Fill type identifier
-- @param integer buyerFarmId Buyer farm
-- @return table|nil offer Active offer
-- @return table|nil productionPoint Production point
function IPS_Manager:getOfferForTrigger(trigger, fillTypeIndex, buyerFarmId)
    local productionPoint = self.productionByTrigger[trigger]
    local offer = self:getActiveOffer(productionPoint, fillTypeIndex)
    if offer == nil or buyerFarmId == nil or buyerFarmId == offer.sellerFarmId then
        return nil, productionPoint
    end
    if buyerFarmId == FarmManager.SPECTATOR_FARM_ID or not self:isPaidBulkTrigger(trigger) then
        return nil, productionPoint
    end
    if trigger.fillTypes ~= nil and not trigger.fillTypes[fillTypeIndex] then
        return nil, productionPoint
    end
    return offer, productionPoint
end

---Returns whether a production station has a bulk offer for an external farm.
-- @param table station Loading station
-- @param integer buyerFarmId Buyer farm
-- @return boolean True when access may be exposed
function IPS_Manager:stationHasBulkOfferForExternalFarm(station, buyerFarmId)
    local productionPoint = self.productionByStation[station]
    if productionPoint == nil or buyerFarmId == nil or buyerFarmId == FarmManager.SPECTATOR_FARM_ID then
        return false
    end
    for fillTypeIndex in pairs(productionPoint.outputFillTypeIds or {}) do
        local offer = self:getActiveOffer(productionPoint, fillTypeIndex)
        if offer ~= nil and offer.sellerFarmId ~= buyerFarmId then
            local mode = self:getOutputMode(productionPoint, fillTypeIndex)
            if mode == IPS_Manager.MODE_BULK or mode == IPS_Manager.MODE_BOTH then
                return true
            end
        end
    end
    return false
end

---Builds the SiloDialog fill levels restricted to public offers.
-- @param table trigger Load trigger
-- @param integer buyerFarmId Buyer farm
-- @return table|nil Offered fill levels, or nil when native behavior applies
function IPS_Manager:getOfferedFillLevels(trigger, buyerFarmId)
    local productionPoint = self.productionByTrigger[trigger]
    if productionPoint == nil then return nil end
    local _, ownerFarmId = self:getProductionIdentity(productionPoint)
    if ownerFarmId == buyerFarmId then return nil end

    local result = {}
    for fillTypeIndex in pairs(productionPoint.outputFillTypeIds or {}) do
        local offer = self:getActiveOffer(productionPoint, fillTypeIndex)
        if offer ~= nil
            and (trigger.fillTypes == nil or trigger.fillTypes[fillTypeIndex])
            and self:isPaidBulkTrigger(trigger) then
            local stock = g_server == nil and offer.stock
                or self:getAvailableOfferLiters(offer, productionPoint)
            stock = IPS_Util.isFiniteNumber(stock) and math.max(stock, 0) or 0
            if stock > IPS_Util.EPSILON then
                result[fillTypeIndex] = stock
            end
        end
    end
    if next(result) == nil then
        return nil
    end
    return result
end

---Checks manager permission for a connection.
-- @param Connection connection Client connection
-- @return boolean True when permitted
function IPS_Manager:connectionHasFarmManagerPermission(connection)
    return connection ~= nil and g_currentMission:getHasPlayerPermission("farmManager", connection)
end

---Derives a farm identifier from a client connection.
-- @param Connection connection Client connection
-- @return integer|nil Farm identifier
function IPS_Manager:getFarmIdForConnection(connection)
    local player = connection ~= nil and g_currentMission.connectionsToPlayer[connection] or nil
    return player ~= nil and player.farmId or nil
end

---Creates or edits a seller offer after authoritative validation.
-- @param Connection connection Requesting connection
-- @param string productionUniqueId Production identifier
-- @param integer fillTypeIndex Fill type identifier
-- @param boolean enabled Desired active state
-- @param number price Desired seller price
-- @param number listedQuantity Fixed liters or full pallets when opening an offer, or zero otherwise
-- @return boolean success True on success
-- @return string resultKey Localization result key
-- @return boolean changed True when the authoritative offer changed
function IPS_Manager:setOffer(connection, productionUniqueId, fillTypeIndex, enabled, price, listedQuantity)
    if not self.integrationAvailable then return false, "ips_error_invoiceIncompatible" end
    if not self:connectionHasFarmManagerPermission(connection) then return false, "ips_error_noPermission" end
    local farmId = self:getFarmIdForConnection(connection)
    local productionPoint = self.productionByUniqueId[productionUniqueId]
    local _, ownerFarmId = self:getProductionIdentity(productionPoint)
    if farmId == nil or farmId ~= ownerFarmId then return false, "ips_error_noPermission" end
    if productionPoint.outputFillTypeIds == nil or productionPoint.outputFillTypeIds[fillTypeIndex] ~= true then
        return false, "ips_error_transactionFailed"
    end
    local nextEnabled = enabled == true
    if nextEnabled and not self:isOutputStored(productionPoint, fillTypeIndex) then return false, "ips_error_outputMode" end
    local outputMode = self:getOutputMode(productionPoint, fillTypeIndex)
    if nextEnabled and outputMode == IPS_Manager.MODE_NONE then return false, "ips_error_transactionFailed" end

    local key = IPS_Util.makeOfferKey(productionUniqueId, fillTypeIndex)
    local offer = self.offers[key]
    local created = false
    local validatedPrice = IPS_Util.sanitizePrice(price)
    local validatedListedQuantity = IPS_Util.sanitizeQuantity(listedQuantity)
    if price ~= nil and price ~= 0 and validatedPrice == nil then
        return false, "ips_error_invalidPrice"
    end
    if listedQuantity ~= nil and listedQuantity ~= 0 and validatedListedQuantity == nil then
        return false, "ips_error_invalidQuantity"
    end
    local wasEnabled = offer ~= nil and offer.enabled == true
    local validatedListedLiters = nil
    if nextEnabled and not wasEnabled then
        if validatedListedQuantity == nil then
            return false, "ips_error_invalidQuantity"
        end

        if outputMode == IPS_Manager.MODE_PALLET then
            if validatedListedQuantity > IPS_Manager.MAX_PALLET_COUNT then
                return false, "ips_error_invalidQuantity"
            end
            local pallets = self:getFullPallets(productionPoint, fillTypeIndex, farmId)
            validatedListedLiters = self:getPalletLitersForQuantity(pallets, validatedListedQuantity)
            if validatedListedLiters == nil then
                return false, "ips_error_offerChanged"
            end
        else
            local stock = self:getOfferableLiters(productionPoint, fillTypeIndex, farmId)
            validatedListedLiters = validatedListedQuantity
            if stock < 1 or validatedListedLiters > stock + IPS_Util.EPSILON then
                return false, "ips_error_invalidQuantity"
            end
        end
    elseif nextEnabled and wasEnabled and validatedListedQuantity ~= nil then
        return false, "ips_error_invalidQuantity"
    end
    if offer == nil then
        validatedPrice = validatedPrice or self:getDefaultPrice(fillTypeIndex)
        offer = {
            key = key,
            productionUniqueId = productionUniqueId,
            fillTypeIndex = fillTypeIndex,
            sellerFarmId = farmId,
            price = validatedPrice,
            listedLiters = 0,
            remainingLiters = 0,
            listedPallets = 0,
            remainingPallets = 0,
            enabled = false,
            revision = 0
        }
        self.offers[key] = offer
        created = true
    end

    local nextPrice = validatedPrice or offer.price
    if IPS_Util.sanitizePrice(nextPrice) == nil then
        return false, "ips_error_invalidPrice"
    end
    if not created
        and offer.sellerFarmId == farmId
        and offer.enabled == nextEnabled
        and math.abs(offer.price - nextPrice) <= IPS_Util.EPSILON then
        return true, "ips_notice_offerSaved", false
    end

    local priceChanged = math.abs(offer.price - nextPrice) > IPS_Util.EPSILON
    offer.price = nextPrice
    offer.enabled = nextEnabled
    offer.sellerFarmId = farmId
    if nextEnabled and not wasEnabled then
        offer.listedLiters = validatedListedLiters
        offer.remainingLiters = validatedListedLiters
        if outputMode == IPS_Manager.MODE_PALLET then
            offer.listedPallets = validatedListedQuantity
            offer.remainingPallets = validatedListedQuantity
        else
            offer.listedPallets = 0
            offer.remainingPallets = 0
        end
    end
    offer.revision = (offer.revision or 0) + 1
    if wasEnabled and not offer.enabled then
        self:stopSessionsForOffer(key, true)
    end
    local resultKey = "ips_notice_offerSaved"
    if wasEnabled and not offer.enabled then
        resultKey = "ips_notice_offerClosed"
    elseif not created and wasEnabled == offer.enabled and priceChanged then
        resultKey = "ips_notice_priceUpdated"
    end
    return true, resultKey, true
end

---Returns the VAT rate applicable to new transactions.
-- @return number VAT rate as fraction
function IPS_Manager:getCurrentVatRate()
    if not self.integrationAvailable or not self.invoiceManager.service:isVatEnabled() then
        return 0
    end
    return self.invoiceManager.service:getVatRateForWorkType(IPS_Manager.WORK_TYPE_PRODUCT) or 0
end

---Returns current period identifiers.
-- @return integer year Environment year
-- @return integer period Environment period
function IPS_Manager:getCurrentPeriod()
    local environment = g_currentMission.environment
    return environment.currentYear or 1, environment.currentPeriod or 1
end

---Converts an environment period to the calendar month/year used by Invoice.
-- @param integer year Environment year
-- @param integer period Environment period
-- @return integer invoiceYear Calendar year stored by Invoice
-- @return integer invoicePeriod Calendar month stored by Invoice
function IPS_Manager:getInvoicePeriodStamp(year, period)
    local invoiceYear = year or 1
    local invoicePeriod = (period or 1) + 2
    if invoicePeriod > 12 then
        invoicePeriod = invoicePeriod - 12
    end
    if invoicePeriod < 3 then
        invoiceYear = invoiceYear + 1
    end
    return invoiceYear, invoicePeriod
end

---Returns the pair key used for one currently open seller/buyer lot.
-- @param integer sellerFarmId Seller farm
-- @param integer buyerFarmId Buyer farm
-- @return string Pair key
function IPS_Manager:getBatchPairKey(sellerFarmId, buyerFarmId)
    return string.format("%d:%d", sellerFarmId, buyerFarmId)
end

---Creates an empty open batch when needed.
-- @param integer sellerFarmId Seller farm
-- @param integer buyerFarmId Buyer farm
-- @return table Batch
function IPS_Manager:getOrCreateBatch(sellerFarmId, buyerFarmId)
    local pairKey = self:getBatchPairKey(sellerFarmId, buyerFarmId)
    local reference = self.openBatchByPair[pairKey]
    local batch = reference ~= nil and self.openBatches[reference] or nil
    if batch ~= nil then return batch end

    local year, period = self:getCurrentPeriod()
    reference = string.format("IPS-%06d", self.nextBatchId)
    self.nextBatchId = self.nextBatchId + 1
    batch = {
        reference = reference,
        sellerFarmId = sellerFarmId,
        buyerFarmId = buyerFarmId,
        year = year,
        period = period,
        totalLiters = 0,
        totalGross = 0,
        totalNet = 0,
        totalVat = 0,
        lines = {},
        lineOrder = {}
    }
    self.openBatches[reference] = batch
    self.openBatchByPair[pairKey] = reference
    return batch
end

---Returns current cumulative liters without mutating a batch.
-- @param integer sellerFarmId Seller farm
-- @param integer buyerFarmId Buyer farm
-- @param string lineKey Aggregation key
-- @return number Existing liters
function IPS_Manager:getExistingLineLiters(sellerFarmId, buyerFarmId, lineKey)
    local reference = self.openBatchByPair[self:getBatchPairKey(sellerFarmId, buyerFarmId)]
    local batch = reference ~= nil and self.openBatches[reference] or nil
    local line = batch ~= nil and batch.lines[lineKey] or nil
    return line ~= nil and line.liters or 0
end

---Counts reserved line keys that are not yet present in a batch.
-- @param table batch Open batch
-- @return integer Reserved new line count
function IPS_Manager:getReservedNewLineCount(batch)
    local pairKey = self:getBatchPairKey(batch.sellerFarmId, batch.buyerFarmId)
    local reservations = self.batchLineReservations[pairKey] or {}
    local count = 0
    for lineKey, reservationCount in pairs(reservations) do
        if reservationCount > 0 and batch.lines[lineKey] == nil then count = count + 1 end
    end
    return count
end

---Reserves one aggregate line for a loading session.
-- @param integer sellerFarmId Seller farm
-- @param integer buyerFarmId Buyer farm
-- @param string lineKey Aggregate line key
function IPS_Manager:reserveBatchLine(sellerFarmId, buyerFarmId, lineKey)
    local pairKey = self:getBatchPairKey(sellerFarmId, buyerFarmId)
    local reservations = self.batchLineReservations[pairKey]
    if reservations == nil then
        reservations = {}
        self.batchLineReservations[pairKey] = reservations
    end
    reservations[lineKey] = (reservations[lineKey] or 0) + 1
end

---Releases one aggregate line reservation.
-- @param integer sellerFarmId Seller farm
-- @param integer buyerFarmId Buyer farm
-- @param string lineKey Aggregate line key
function IPS_Manager:releaseBatchLine(sellerFarmId, buyerFarmId, lineKey)
    local pairKey = self:getBatchPairKey(sellerFarmId, buyerFarmId)
    local reservations = self.batchLineReservations[pairKey]
    if reservations == nil then return end
    local remaining = (reservations[lineKey] or 0) - 1
    if remaining > 0 then
        reservations[lineKey] = remaining
    else
        reservations[lineKey] = nil
    end
    if next(reservations) == nil then self.batchLineReservations[pairKey] = nil end
end

---Ensures a new line can be represented by Invoice network serialization.
-- @param integer sellerFarmId Seller farm
-- @param integer buyerFarmId Buyer farm
-- @param string lineKey Aggregate line key
-- @return boolean True when the line exists or capacity is available
-- @return boolean closed True when the previous batch was closed
function IPS_Manager:ensureBatchLineCapacity(sellerFarmId, buyerFarmId, lineKey)
    local pairKey = self:getBatchPairKey(sellerFarmId, buyerFarmId)
    local reservations = self.batchLineReservations[pairKey] or {}
    if (reservations[lineKey] or 0) > 0 then return true, false end
    local reference = self.openBatchByPair[pairKey]
    local batch = reference ~= nil and self.openBatches[reference] or nil
    if batch == nil then
        local reservedCount = 0
        for _, reservationCount in pairs(reservations) do
            if reservationCount > 0 then reservedCount = reservedCount + 1 end
        end
        return reservedCount < IPS_Manager.MAX_BATCH_LINES, false
    end
    if batch.lines[lineKey] ~= nil then return true, false end
    if #batch.lineOrder + self:getReservedNewLineCount(batch) < IPS_Manager.MAX_BATCH_LINES then return true, false end

    local _, carryOrder = self:partitionBatchLines(batch)
    if #carryOrder >= IPS_Manager.MAX_BATCH_LINES then return false, false end
    if not self:closeBatch(batch, true) then return false, false end
    self:broadcastRefresh()

    reference = self.openBatchByPair[pairKey]
    batch = reference ~= nil and self.openBatches[reference] or nil
    local available = batch == nil
        or batch.lines[lineKey] ~= nil
        or #batch.lineOrder + self:getReservedNewLineCount(batch) < IPS_Manager.MAX_BATCH_LINES
    return available, true
end

---Computes a transfer candidate against one open batch.
-- @param table? batch Open batch or nil
-- @param string lineKey Aggregate line key
-- @param number price Locked price
-- @param number vatRate Locked VAT rate
-- @param number addedLiters Candidate volume
-- @return table delta Candidate cumulative line
-- @return number totalGross Candidate batch gross
-- @return number totalNet Candidate batch net
-- @return number totalVat Candidate batch VAT
function IPS_Manager:getTransferCandidate(batch, lineKey, price, vatRate, addedLiters)
    local line = batch ~= nil and batch.lines[lineKey] or nil
    local oldLiters = line ~= nil and line.liters or 0
    local oldGross = line ~= nil and line.gross or 0
    local oldNet = line ~= nil and line.net or 0
    local oldVat = line ~= nil and line.vat or 0
    local delta = IPS_Util.computeCumulativeDelta(price, oldLiters, addedLiters, vatRate, self.invoiceClass)
    return delta,
        (batch ~= nil and batch.totalGross or 0) - oldGross + delta.gross,
        (batch ~= nil and batch.totalNet or 0) - oldNet + delta.net,
        (batch ~= nil and batch.totalVat or 0) - oldVat + delta.vat
end

---Returns whether Invoice can serialize the resulting financial values exactly.
-- @param table? batch Open batch or nil
-- @param string lineKey Aggregate line key
-- @param number price Locked price
-- @param number vatRate Locked VAT rate
-- @param number addedLiters Candidate volume
-- @return boolean True when every monetary field remains representable
function IPS_Manager:isTransferRepresentable(batch, lineKey, price, vatRate, addedLiters)
    local delta, totalGross, totalNet, totalVat = self:getTransferCandidate(batch, lineKey, price, vatRate, addedLiters)
    return IPS_Util.isFiniteNumber(delta.gross)
        and IPS_Util.isFiniteNumber(delta.net)
        and IPS_Util.isFiniteNumber(delta.vat)
        and IPS_Util.isFiniteNumber(totalGross)
        and IPS_Util.isFiniteNumber(totalNet)
        and IPS_Util.isFiniteNumber(totalVat)
        and delta.gross >= 0
        and delta.net >= 0
        and delta.vat >= 0
        and totalGross >= 0
        and totalNet >= 0
        and totalVat >= 0
        and delta.gross <= IPS_Manager.MAX_EXACT_FLOAT32_INTEGER
        and totalGross <= IPS_Manager.MAX_INT32
        and totalNet <= IPS_Manager.MAX_INT32
        and totalVat <= IPS_Manager.MAX_INT32
end

---Finds the largest transfer volume representable by Invoice.
-- @param table? batch Open batch or nil
-- @param string lineKey Aggregate line key
-- @param number price Locked price
-- @param number vatRate Locked VAT rate
-- @param number requestedLiters Requested volume
-- @return number Representable volume
function IPS_Manager:getRepresentableLiters(batch, lineKey, price, vatRate, requestedLiters)
    requestedLiters = math.max(requestedLiters or 0, 0)
    if requestedLiters <= IPS_Util.EPSILON then return 0 end
    if self:isTransferRepresentable(batch, lineKey, price, vatRate, requestedLiters) then return requestedLiters end

    local low, high = 0, requestedLiters
    for _ = 1, 52 do
        local middle = (low + high) * 0.5
        if self:isTransferRepresentable(batch, lineKey, price, vatRate, middle) then
            low = middle
        else
            high = middle
        end
    end
    return low > IPS_Util.EPSILON and low or 0
end

---Prepares a complete atomic transfer, closing the current batch when required.
-- @param integer sellerFarmId Seller farm
-- @param integer buyerFarmId Buyer farm
-- @param string lineKey Aggregate line key
-- @param number price Locked price
-- @param number vatRate Locked VAT rate
-- @param number addedLiters Complete atomic volume
-- @return boolean True when the full transfer is representable
-- @return boolean closed True when the previous batch was closed
function IPS_Manager:prepareAtomicTransfer(sellerFarmId, buyerFarmId, lineKey, price, vatRate, addedLiters)
    local pairKey = self:getBatchPairKey(sellerFarmId, buyerFarmId)
    local reference = self.openBatchByPair[pairKey]
    local batch = reference ~= nil and self.openBatches[reference] or nil
    if self:isTransferRepresentable(batch, lineKey, price, vatRate, addedLiters) then return true, false end
    if batch == nil then return false, false end

    local _, carryOrder = self:partitionBatchLines(batch)
    local projected = #carryOrder > 0 and self:buildBatchView(batch, carryOrder) or nil
    if not self:isTransferRepresentable(projected, lineKey, price, vatRate, addedLiters) then return false, false end
    if not self:closeBatch(batch, true) then return false, false end
    self:broadcastRefresh()

    reference = self.openBatchByPair[pairKey]
    batch = reference ~= nil and self.openBatches[reference] or nil
    return self:isTransferRepresentable(batch, lineKey, price, vatRate, addedLiters), true
end

---Computes the exact buyer charge for an atomic transfer without mutating batch state.
-- @param integer sellerFarmId Seller farm
-- @param integer buyerFarmId Buyer farm
-- @param string lineKey Aggregate line key
-- @param number price Locked price
-- @param number vatRate Locked VAT rate
-- @param number addedLiters Complete atomic volume
-- @return table|nil Quote containing liters and gross charge
function IPS_Manager:getAtomicTransferQuote(sellerFarmId, buyerFarmId, lineKey, price, vatRate, addedLiters)
    if not IPS_Util.isFiniteNumber(addedLiters) or addedLiters <= IPS_Util.EPSILON then
        return nil
    end

    local pairKey = self:getBatchPairKey(sellerFarmId, buyerFarmId)
    local reference = self.openBatchByPair[pairKey]
    local batch = reference ~= nil and self.openBatches[reference] or nil
    local projectedBatch = batch
    local requiresClose = false
    local reservations = self.batchLineReservations[pairKey] or {}

    local function projectAfterClose(sourceBatch)
        local _, carryOrder = self:partitionBatchLines(sourceBatch)
        if #carryOrder >= IPS_Manager.MAX_BATCH_LINES then
            return false, nil
        end
        return true, #carryOrder > 0 and self:buildBatchView(sourceBatch, carryOrder) or nil
    end

    if (reservations[lineKey] or 0) <= 0 then
        if projectedBatch == nil then
            local reservedCount = 0
            for _, reservationCount in pairs(reservations) do
                if reservationCount > 0 then reservedCount = reservedCount + 1 end
            end
            if reservedCount >= IPS_Manager.MAX_BATCH_LINES then return nil end
        elseif projectedBatch.lines[lineKey] == nil
            and #projectedBatch.lineOrder + self:getReservedNewLineCount(projectedBatch) >= IPS_Manager.MAX_BATCH_LINES then
            local canClose
            canClose, projectedBatch = projectAfterClose(projectedBatch)
            if not canClose then return nil end
            requiresClose = true
            if projectedBatch == nil then
                local reservedCount = 0
                for _, reservationCount in pairs(reservations) do
                    if reservationCount > 0 then reservedCount = reservedCount + 1 end
                end
                if reservedCount >= IPS_Manager.MAX_BATCH_LINES then return nil end
            elseif projectedBatch.lines[lineKey] == nil
                and #projectedBatch.lineOrder + self:getReservedNewLineCount(projectedBatch) >= IPS_Manager.MAX_BATCH_LINES then
                return nil
            end
        end
    end

    if not self:isTransferRepresentable(projectedBatch, lineKey, price, vatRate, addedLiters) then
        if projectedBatch == nil or requiresClose then return nil end
        local canClose
        canClose, projectedBatch = projectAfterClose(projectedBatch)
        if not canClose or not self:isTransferRepresentable(projectedBatch, lineKey, price, vatRate, addedLiters) then
            return nil
        end
    end

    local delta = self:getTransferCandidate(projectedBatch, lineKey, price, vatRate, addedLiters)
    return {
        liters = addedLiters,
        gross = delta.deltaGross
    }
end

---Closes the current batch for one farm pair after a safe loading stop.
-- @param integer sellerFarmId Seller farm
-- @param integer buyerFarmId Buyer farm
-- @return boolean True when an existing batch was closed
function IPS_Manager:closeCurrentBatchForPair(sellerFarmId, buyerFarmId)
    local reference = self.openBatchByPair[self:getBatchPairKey(sellerFarmId, buyerFarmId)]
    local batch = reference ~= nil and self.openBatches[reference] or nil
    if batch == nil then return false end
    local success = self:closeBatch(batch, true)
    if success then self:broadcastRefresh() end
    return success
end

---Records exact transferred liters and applies cumulative money differences.
-- @param table offer Locked offer data
-- @param table productionPoint Production point
-- @param integer buyerFarmId Buyer farm
-- @param number liters Exact transferred volume
-- @param number lockedPrice Session or purchase price
-- @param number lockedVatRate Session or purchase VAT rate
-- @param boolean deferMoneyDisplay Whether HUD money changes are displayed when the bulk session stops
-- @return table|nil delta Applied cumulative delta
function IPS_Manager:recordTransfer(offer, productionPoint, buyerFarmId, liters, lockedPrice, lockedVatRate, deferMoneyDisplay)
    if liters == nil or liters <= IPS_Util.EPSILON then return nil end
    local pairKey = self:getBatchPairKey(offer.sellerFarmId, buyerFarmId)
    local reference = self.openBatchByPair[pairKey]
    local batch = reference ~= nil and self.openBatches[reference] or nil
    local lineKey = IPS_Util.makeLineKey(offer.productionUniqueId, offer.fillTypeIndex, lockedPrice, lockedVatRate)
    if not self:isTransferRepresentable(batch, lineKey, lockedPrice, lockedVatRate, liters) then
        Logging.error("[InvoicesProductionSales] Refusing an unrepresentable transfer for batch %s", reference or "new")
        return nil
    end
    batch = batch or self:getOrCreateBatch(offer.sellerFarmId, buyerFarmId)
    local line = batch.lines[lineKey]
    if line == nil then
        if #batch.lineOrder >= IPS_Manager.MAX_BATCH_LINES then
            Logging.error("[InvoicesProductionSales] Refusing to exceed Invoice line serialization capacity for batch %s", batch.reference)
            return nil
        end
        local productName, iconFilename = self:getFillTypeMetadata(offer.fillTypeIndex)
        line = {
            key = lineKey,
            productionUniqueId = offer.productionUniqueId,
            productionName = self:getProductionName(productionPoint),
            fillTypeIndex = offer.fillTypeIndex,
            productName = productName,
            iconFilename = iconFilename,
            price = lockedPrice,
            vatRate = lockedVatRate,
            liters = 0,
            gross = 0,
            net = 0,
            vat = 0
        }
        batch.lines[lineKey] = line
        table.insert(batch.lineOrder, lineKey)
    end

    local delta = IPS_Util.computeCumulativeDelta(line.price, line.liters, liters, line.vatRate, self.invoiceClass)
    if delta.deltaGross > 0 then
        local hasDetails = delta.deltaVat > 0
        g_currentMission:addMoney(
            -delta.deltaGross,
            buyerFarmId,
            MoneyType.INVOICE_EXPENSE,
            true,
            not deferMoneyDisplay and not hasDetails
        )
    end
    if delta.deltaNet > 0 then
        local hasDetails = delta.deltaVat > 0
        g_currentMission:addMoney(
            delta.deltaNet,
            offer.sellerFarmId,
            MoneyType.INVOICE_INCOME,
            true,
            not deferMoneyDisplay and not hasDetails
        )
    end

    batch.totalLiters = batch.totalLiters - line.liters + delta.liters
    batch.totalGross = batch.totalGross - line.gross + delta.gross
    batch.totalNet = batch.totalNet - line.net + delta.net
    batch.totalVat = batch.totalVat - line.vat + delta.vat
    line.liters = delta.liters
    line.gross = delta.gross
    line.net = delta.net
    line.vat = delta.vat
    return delta
end

---Creates a server-side paid loading session.
-- @param table trigger Load trigger
-- @param table targetObject Buyer vehicle
-- @param integer fillUnitIndex Target fill unit
-- @param integer fillTypeIndex Fill type
-- @param integer offerRevision Client catalog revision
-- @param Connection connection Buyer connection
-- @return boolean success True when authorized
-- @return string resultKey Localization key
function IPS_Manager:createLoadingSession(trigger, targetObject, fillUnitIndex, fillTypeIndex, offerRevision, connection)
    if not self.integrationAvailable then return false, "ips_error_invoiceIncompatible" end
    if trigger == nil or targetObject == nil then return false, "ips_error_transactionFailed" end
    local buyerFarmId = self:getFarmIdForConnection(connection)
    if buyerFarmId == nil or buyerFarmId == FarmManager.SPECTATOR_FARM_ID then return false, "ips_error_noFarm" end
    local offer, productionPoint = self:getOfferForTrigger(trigger, fillTypeIndex, buyerFarmId)
    if offer == nil or offer.revision ~= offerRevision then return false, "ips_error_offerChanged" end
    if trigger.isLoading then return false, "ips_error_transactionFailed" end

    local targetFound = false
    for _, fillable in pairs(trigger.fillableObjects or {}) do
        if fillable.object == targetObject and fillable.fillUnitIndex == fillUnitIndex then
            targetFound = true
            break
        end
    end
    if not targetFound
        or trigger:farmIdForFillableObject(targetObject) ~= buyerFarmId
        or targetObject:getFillUnitFreeCapacity(fillUnitIndex, nil, nil) <= IPS_Util.EPSILON
        or not targetObject:getFillUnitSupportsFillType(fillUnitIndex, fillTypeIndex)
        or not targetObject:getFillUnitAllowsFillType(fillUnitIndex, fillTypeIndex)
        or self:getOutputStock(productionPoint, fillTypeIndex, offer.sellerFarmId) <= IPS_Util.EPSILON then
        return false, "ips_error_transactionFailed"
    end

    local vatRate = self:getCurrentVatRate()
    local lineKey = IPS_Util.makeLineKey(offer.productionUniqueId, offer.fillTypeIndex, offer.price, vatRate)
    if not self:ensureBatchLineCapacity(offer.sellerFarmId, buyerFarmId, lineKey) then
        return false, "ips_error_transactionFailed"
    end
    self:reserveBatchLine(offer.sellerFarmId, buyerFarmId, lineKey)

    local session = {
        trigger = trigger,
        targetObject = targetObject,
        fillUnitIndex = fillUnitIndex,
        fillTypeIndex = fillTypeIndex,
        offerKey = offer.key,
        productionUniqueId = offer.productionUniqueId,
        offerRevision = offer.revision,
        sellerFarmId = offer.sellerFarmId,
        buyerFarmId = buyerFarmId,
        price = offer.price,
        vatRate = vatRate,
        reservedLineKey = lineKey,
        productionPoint = productionPoint,
        connection = connection,
        stopForFunds = false,
        stopForReceipt = false,
        stopForQuantity = false
    }
    self.activeSessions[trigger] = session
    self.startAuthorizations[trigger] = session
    return true, ""
end

---Consumes the one-shot token allowing the native loading start.
-- @param table trigger Load trigger
-- @param table targetObject Target vehicle
-- @param integer fillUnitIndex Fill unit
-- @param integer fillTypeIndex Fill type
-- @return boolean True only for the matching custom request
function IPS_Manager:consumeStartAuthorization(trigger, targetObject, fillUnitIndex, fillTypeIndex)
    local authorization = self.startAuthorizations[trigger]
    self.startAuthorizations[trigger] = nil
    return authorization ~= nil
        and authorization.targetObject == targetObject
        and authorization.fillUnitIndex == fillUnitIndex
        and authorization.fillTypeIndex == fillTypeIndex
end

---Returns the active paid session for a trigger.
-- @param table trigger Load trigger
-- @return table|nil Session
function IPS_Manager:getSession(trigger)
    return self.activeSessions[trigger]
end

---Validates an active session without changing its locked price.
-- @param table session Paid session
-- @return boolean True while sale may continue
function IPS_Manager:isSessionValid(session)
    if session == nil or not self.integrationAvailable then return false end
    local offer = self.offers[session.offerKey]
    local productionPoint = self.productionByUniqueId[offer ~= nil and offer.productionUniqueId or ""]
    local _, ownerFarmId = self:getProductionIdentity(productionPoint)
    local connectionFarmId = self:getFarmIdForConnection(session.connection)
    local targetFarmId = session.trigger ~= nil
        and session.targetObject ~= nil
        and session.trigger.farmIdForFillableObject ~= nil
        and session.trigger:farmIdForFillableObject(session.targetObject) or nil
    return offer ~= nil
        and offer.enabled
        and ownerFarmId == session.sellerFarmId
        and connectionFarmId == session.buyerFarmId
        and targetFarmId == session.buyerFarmId
        and productionPoint == session.productionPoint
        and self:getOfferRemainingLiters(offer) > IPS_Util.EPSILON
        and self:isOutputStored(productionPoint, session.fillTypeIndex)
end

---Validates and stops stale active sessions.
function IPS_Manager:validateActiveSessions()
    local stale = {}
    for trigger, session in pairs(self.activeSessions) do
        if not self:isSessionValid(session) then
            table.insert(stale, trigger)
        end
    end
    for _, trigger in ipairs(stale) do
        if trigger.isLoading then trigger:setIsLoading(false) end
        self:removeSession(trigger)
    end
end

---Returns the maximum affordable request for a session.
-- @param table session Paid session
-- @param number requestedLiters Requested liters
-- @return number Affordable liters
-- @return boolean limitedByFunds True when funds imposed a cap
-- @return boolean limitedByReceipt True when Invoice representation imposed a cap
-- @return boolean limitedByQuantity True when the listed quantity imposed a cap
function IPS_Manager:getAffordableSessionLiters(session, requestedLiters)
    local farm = g_farmManager:getFarmById(session.buyerFarmId)
    if farm == nil then return 0, true, false, false end
    local lineKey = IPS_Util.makeLineKey(session.productionUniqueId, session.fillTypeIndex, session.price, session.vatRate)
    local oldLiters = self:getExistingLineLiters(session.sellerFarmId, session.buyerFarmId, lineKey)
    local affordable = IPS_Util.getAffordableLiters(session.price, oldLiters, requestedLiters, farm.money or 0, self.invoiceClass)
    local reference = self.openBatchByPair[self:getBatchPairKey(session.sellerFarmId, session.buyerFarmId)]
    local batch = reference ~= nil and self.openBatches[reference] or nil
    local representable = self:getRepresentableLiters(batch, lineKey, session.price, session.vatRate, requestedLiters)
    local offer = self.offers[session.offerKey]
    local listed = self:getOfferRemainingLiters(offer)
    local result = math.min(affordable, representable, listed)
    return result,
        affordable + IPS_Util.EPSILON < requestedLiters
            and affordable <= representable + IPS_Util.EPSILON
            and affordable <= listed + IPS_Util.EPSILON,
        representable + IPS_Util.EPSILON < requestedLiters
            and representable <= affordable + IPS_Util.EPSILON
            and representable <= listed + IPS_Util.EPSILON,
        listed + IPS_Util.EPSILON < requestedLiters
            and listed <= affordable + IPS_Util.EPSILON
            and listed <= representable + IPS_Util.EPSILON
end

---Applies exact bulk transfer accounting.
-- @param table session Paid session
-- @param number exactLiters Native returned delta
function IPS_Manager:onBulkTransferred(session, exactLiters)
    local offer = self.offers[session.offerKey]
    if offer ~= nil then
        local delta = self:recordTransfer(
            offer,
            session.productionPoint,
            session.buyerFarmId,
            exactLiters,
            session.price,
            session.vatRate,
            true
        )
        if delta ~= nil and (delta.deltaGross > 0 or delta.deltaNet > 0) then
            session.hasMoneyMovement = true
        end
        if delta ~= nil and self:consumeOfferLiters(offer, exactLiters) then
            session.stopForQuantity = true
            self:broadcastRefresh()
        end
    end
end

---Removes a paid session after loading stops.
-- @param table trigger Load trigger
function IPS_Manager:removeSession(trigger)
    local session = self.activeSessions[trigger] or self.startAuthorizations[trigger]
    if session ~= nil and session.reservedLineKey ~= nil then
        self:releaseBatchLine(session.sellerFarmId, session.buyerFarmId, session.reservedLineKey)
        session.reservedLineKey = nil
    end
    self.activeSessions[trigger] = nil
    self.startAuthorizations[trigger] = nil
end

---Stops all sessions using one offer.
-- @param string offerKey Offer identifier
-- @param boolean notifyBuyer Whether to notify buyers
function IPS_Manager:stopSessionsForOffer(offerKey, notifyBuyer)
    local targets = {}
    for trigger, session in pairs(self.activeSessions) do
        if session.offerKey == offerKey then table.insert(targets, {trigger = trigger, session = session}) end
    end
    for _, target in ipairs(targets) do
        if target.trigger.isLoading then target.trigger:setIsLoading(false) end
        self:removeSession(target.trigger)
        if notifyBuyer then self:sendResult(target.session.connection, false, "ips_error_offerUnavailable", false) end
    end
end

---Stops sessions associated with a production point.
-- @param table productionPoint Production point
-- @param boolean notifyBuyer Whether to notify buyers
function IPS_Manager:stopSessionsForProduction(productionPoint, notifyBuyer)
    local targets = {}
    for trigger, session in pairs(self.activeSessions) do
        if session.productionPoint == productionPoint then table.insert(targets, {trigger = trigger, session = session}) end
    end
    for _, target in ipairs(targets) do
        if target.trigger.isLoading then target.trigger:setIsLoading(false) end
        self:removeSession(target.trigger)
        if notifyBuyer then self:sendResult(target.session.connection, false, "ips_error_offerUnavailable", false) end
    end
end

---Stops every paid loading session.
-- @param boolean notifyBuyer Whether to notify buyers
function IPS_Manager:stopAllSessions(notifyBuyer)
    local targets = {}
    for trigger, session in pairs(self.activeSessions) do
        table.insert(targets, {trigger = trigger, session = session})
    end
    for _, target in ipairs(targets) do
        if target.trigger.isLoading then target.trigger:setIsLoading(false) end
        self:removeSession(target.trigger)
        if notifyBuyer then self:sendResult(target.session.connection, false, "ips_error_offerUnavailable", false) end
    end
end

---Stops sessions contributing to one seller/buyer batch.
-- @param integer sellerFarmId Seller farm
-- @param integer buyerFarmId Buyer farm
function IPS_Manager:stopSessionsForBatch(sellerFarmId, buyerFarmId)
    local targets = {}
    for trigger, session in pairs(self.activeSessions) do
        if session.sellerFarmId == sellerFarmId and session.buyerFarmId == buyerFarmId then
            table.insert(targets, trigger)
        end
    end
    for _, trigger in ipairs(targets) do
        if trigger.isLoading then trigger:setIsLoading(false) end
        self:removeSession(trigger)
    end
end

---Invalidates offers before a production owner changes.
-- @param table productionPoint Production point
-- @param integer newFarmId New owner farm
function IPS_Manager:onProductionOwnerChanging(productionPoint, newFarmId)
    local placeable = productionPoint ~= nil and productionPoint.owningPlaceable or nil
    local uniqueId = placeable ~= nil and placeable.getUniqueId ~= nil and placeable:getUniqueId() or nil
    local oldFarmId = productionPoint ~= nil and productionPoint.getOwnerFarmId ~= nil
        and productionPoint:getOwnerFarmId() or nil
    if uniqueId == nil or oldFarmId == newFarmId then return end
    local changed = false
    for _, offer in pairs(self.offers) do
        if offer.productionUniqueId == uniqueId
            and offer.sellerFarmId == oldFarmId
            and offer.enabled then
            offer.enabled = false
            offer.revision = (offer.revision or 0) + 1
            changed = true
        end
    end
    if changed then
        self:stopSessionsForProduction(productionPoint, true)
        self:broadcastRefresh()
    end
end

---Handles production registration changes.
function IPS_Manager:onPlaceableAdded()
    self:rebuildProductionIndex()
    self:validateOffers()
end

---Handles production deletion before references disappear.
-- @param table placeable Removed placeable
function IPS_Manager:onPlaceableRemoved(placeable)
    local uniqueId = placeable ~= nil and placeable.getUniqueId ~= nil and placeable:getUniqueId() or nil
    local productionPoint = uniqueId ~= nil and self.productionByUniqueId[uniqueId] or nil
    if productionPoint ~= nil then
        self:onProductionOwnerChanging(productionPoint, AccessHandler.EVERYONE)
    end
    self:rebuildProductionIndex()
end

---Returns an Invoice receipt carrying a readable batch reference.
-- @param table batch Closed batch
-- @return table Invoice instance
function IPS_Manager:createReceipt(batch)
    if not self.integrationAvailable or self.invoiceClass == nil then
        return nil
    end
    if #batch.lineOrder > IPS_Manager.MAX_BATCH_LINES then
        Logging.error("[InvoicesProductionSales] Batch %s exceeds Invoice line serialization capacity", batch.reference)
        return nil
    end
    if not IPS_Util.isFiniteNumber(batch.totalGross)
        or not IPS_Util.isFiniteNumber(batch.totalNet)
        or not IPS_Util.isFiniteNumber(batch.totalVat)
        or batch.totalGross < 0
        or batch.totalNet < 0
        or batch.totalVat < 0
        or batch.totalGross > IPS_Manager.MAX_INT32
        or batch.totalNet > IPS_Manager.MAX_INT32
        or batch.totalVat > IPS_Manager.MAX_INT32 then
        Logging.error("[InvoicesProductionSales] Batch %s exceeds Invoice monetary serialization capacity", batch.reference)
        return nil
    end
    local items = {}
    table.sort(batch.lineOrder)
    for index, lineKey in ipairs(batch.lineOrder) do
        local line = batch.lines[lineKey]
        if line == nil
            or not IPS_Util.isFiniteNumber(line.gross)
            or line.gross < 0
            or line.gross > IPS_Manager.MAX_EXACT_FLOAT32_INTEGER then
            Logging.error("[InvoicesProductionSales] Batch %s contains an unrepresentable Invoice line", batch.reference)
            return nil
        end
        local note = string.format("[IPS:%s]", batch.reference)
        if index > 1 then note = "" end
        table.insert(items, {
            workTypeId = IPS_Manager.WORK_TYPE_PRODUCT,
            amount = line.gross,
            quantity = line.liters,
            unitType = self.invoiceClass.UNIT_LITER,
            fieldId = 0,
            fieldArea = 0,
            note = note,
            vatRate = line.vatRate,
            discountRate = 0,
            name = string.format("%s - %s", line.productionName, line.productName),
            iconFilename = line.iconFilename or "",
            price = line.price,
            vehicleUniqueId = "",
            consumableXmlFilename = "",
            consumableFillTypeIndex = line.fillTypeIndex,
            consumableFillLevel = line.liters
        })
    end

    local invoice = self.invoiceClass.new()
    invoice:populateFromData(0, items, batch.buyerFarmId, batch.sellerFarmId)
    if invoice.totalAmount ~= batch.totalGross
        or invoice.totalHT ~= batch.totalNet
        or invoice.vatAmount ~= batch.totalVat then
        Logging.error("[InvoicesProductionSales] Batch %s does not match Invoice monetary calculations", batch.reference)
        return nil
    end
    local invoiceYear, invoicePeriod = self:getInvoicePeriodStamp(batch.year, batch.period)
    invoice.createdAt = invoice.createdAt or {}
    invoice.createdAt.year = invoiceYear
    invoice.createdAt.period = invoicePeriod
    invoice.state = self.invoiceClass.STATE.PAID
    invoice.penaltyAmount = 0
    return invoice
end

---Returns the companion batch reference stored in an Invoice receipt.
-- @param table invoice Candidate Invoice
-- @return string|nil Batch reference or nil
function IPS_Manager:getReceiptReference(invoice)
    if invoice == nil then return nil end
    for _, item in ipairs(invoice.lineItems or {}) do
        if type(item.note) == "string" then
            local reference = string.match(item.note, "^%[IPS:([^%]]+)%]$")
            if reference ~= nil and reference ~= "" then
                return reference
            end
        end
    end
    return nil
end

---Notifies a local seller or buyer when an already-paid receipt is created.
-- @param table invoice Created Invoice receipt
-- @param string? reference Known batch reference
function IPS_Manager:notifyReceiptCreated(invoice, reference)
    if invoice == nil or g_localPlayer == nil or g_currentMission == nil then return end
    local farmId = g_localPlayer.farmId
    if farmId ~= invoice.senderFarmId and farmId ~= invoice.recipientFarmId then return end
    reference = reference or self:getReceiptReference(invoice)
    if reference == nil or reference == "" then return end
    local notificationKey = farmId == invoice.senderFarmId
        and "ips_notice_receiptCreated"
        or "ips_notice_receiptPaid"
    local text = string.format(self:getText(notificationKey), reference)
    g_currentMission:addIngameNotification(FSBaseMission.INGAME_NOTIFICATION_OK, text)
end

---Returns whether an Invoice exactly matches an already-paid companion batch.
-- @param table invoice Candidate Invoice
-- @param table batch Expected batch
-- @return boolean True for the matching generated receipt
function IPS_Manager:isReceiptForBatch(invoice, batch)
    if invoice == nil
        or batch == nil
        or invoice.state ~= self.invoiceClass.STATE.PAID
        or invoice.senderFarmId ~= batch.sellerFarmId
        or invoice.recipientFarmId ~= batch.buyerFarmId
        or invoice.totalAmount ~= batch.totalGross
        or invoice.totalHT ~= batch.totalNet
        or invoice.vatAmount ~= batch.totalVat
        or #(invoice.lineItems or {}) ~= #batch.lineOrder then
        return false
    end

    local marker = string.format("[IPS:%s]", batch.reference)
    local markerCount = 0
    local actual = {}
    for _, item in ipairs(invoice.lineItems or {}) do
        if item.note == marker then
            markerCount = markerCount + 1
        elseif item.note ~= nil and item.note ~= "" then
            return false
        end
        table.insert(actual, item)
    end
    if markerCount ~= 1 then return false end

    local expected = {}
    for _, lineKey in ipairs(batch.lineOrder) do
        local line = batch.lines[lineKey]
        if line == nil then return false end
        table.insert(expected, {
            workTypeId = IPS_Manager.WORK_TYPE_PRODUCT,
            unitType = self.invoiceClass.UNIT_LITER,
            amount = line.gross,
            quantity = line.liters,
            price = line.price,
            vatRate = line.vatRate,
            discountRate = 0,
            name = string.format("%s - %s", line.productionName, line.productName),
            consumableFillTypeIndex = line.fillTypeIndex
        })
    end

    local sortFields = {"consumableFillTypeIndex", "price", "vatRate", "amount", "quantity", "workTypeId", "unitType", "discountRate"}
    local function less(left, right)
        local leftName, rightName = tostring(left.name or ""), tostring(right.name or "")
        if leftName ~= rightName then return leftName < rightName end
        for _, field in ipairs(sortFields) do
            local leftValue, rightValue = left[field] or 0, right[field] or 0
            if leftValue ~= rightValue then return leftValue < rightValue end
        end
        return false
    end
    table.sort(actual, less)
    table.sort(expected, less)

    for index, item in ipairs(actual) do
        local line = expected[index]
        if item.workTypeId ~= line.workTypeId
            or item.unitType ~= line.unitType
            or item.amount ~= line.amount
            or math.abs((item.quantity or 0) - line.quantity) > IPS_Util.EPSILON
            or math.abs((item.price or 0) - line.price) > IPS_Util.EPSILON
            or math.abs((item.vatRate or 0) - line.vatRate) > IPS_Util.EPSILON
            or (item.discountRate or 0) ~= 0
            or item.name ~= line.name
            or (item.consumableFillTypeIndex or 0) ~= line.consumableFillTypeIndex then
            return false
        end
    end
    return true
end

---Finds an existing receipt by companion batch reference and exact contents.
-- @param string reference Batch reference
-- @param table batch Expected batch
-- @return table|nil Existing invoice
function IPS_Manager:findReceipt(reference, batch)
    if batch == nil or reference ~= batch.reference then return nil end
    for _, invoice in ipairs(self.invoiceManager ~= nil and self.invoiceManager.repository:getAll() or {}) do
        if self:isReceiptForBatch(invoice, batch) then return invoice end
    end
    return nil
end

---Splits a batch into billable lines and zero-rounded lines that must carry forward.
-- @param table batch Source batch
-- @return table billableOrder Billable line keys
-- @return table carryOrder Zero-rounded line keys
function IPS_Manager:partitionBatchLines(batch)
    local billableOrder = {}
    local carryOrder = {}
    for _, lineKey in ipairs(batch ~= nil and batch.lineOrder or {}) do
        local line = batch.lines[lineKey]
        if line ~= nil and line.liters > IPS_Util.EPSILON and line.gross <= 0 then
            table.insert(carryOrder, lineKey)
        else
            table.insert(billableOrder, lineKey)
        end
    end
    return billableOrder, carryOrder
end

---Builds a non-mutating batch view containing selected line keys.
-- @param table batch Source batch
-- @param table lineOrder Selected line keys
-- @return table Batch view
function IPS_Manager:buildBatchView(batch, lineOrder)
    local view = {
        reference = batch.reference,
        sellerFarmId = batch.sellerFarmId,
        buyerFarmId = batch.buyerFarmId,
        year = batch.year,
        period = batch.period,
        totalLiters = 0,
        totalGross = 0,
        totalNet = 0,
        totalVat = 0,
        lines = {},
        lineOrder = IPS_Util.copyArray(lineOrder)
    }
    for _, lineKey in ipairs(view.lineOrder) do
        local line = batch.lines[lineKey]
        view.lines[lineKey] = line
        view.totalLiters = view.totalLiters + line.liters
        view.totalGross = view.totalGross + line.gross
        view.totalNet = view.totalNet + line.net
        view.totalVat = view.totalVat + line.vat
    end
    return view
end

---Carries zero-rounded lines into the current period without resetting their rounding basis.
-- @param table sourceBatch Original batch
-- @param table carryOrder Line keys to carry
function IPS_Manager:carryBatchLinesForward(sourceBatch, carryOrder)
    local carryBatch = self:getOrCreateBatch(sourceBatch.sellerFarmId, sourceBatch.buyerFarmId)
    for _, lineKey in ipairs(carryOrder) do
        local line = sourceBatch.lines[lineKey]
        carryBatch.lines[lineKey] = line
        table.insert(carryBatch.lineOrder, lineKey)
        carryBatch.totalLiters = carryBatch.totalLiters + line.liters
        carryBatch.totalGross = carryBatch.totalGross + line.gross
        carryBatch.totalNet = carryBatch.totalNet + line.net
        carryBatch.totalVat = carryBatch.totalVat + line.vat
    end
end

---Closes one open batch and inserts an already-paid Invoice receipt.
-- @param table batch Open batch
-- @param boolean? carryUnrounded Whether zero-rounded lines must carry into the new period
-- @return boolean True when closed
-- @return boolean announcedReceipt True when a new receipt was created and announced
-- @return boolean hasReceipt True when the closure is backed by an Invoice receipt
function IPS_Manager:closeBatch(batch, carryUnrounded)
    if batch == nil or not self.integrationAvailable or self.invoiceManager == nil then return false end
    local billableOrder, carryOrder = self:partitionBatchLines(batch)
    if #carryOrder > 0 and carryUnrounded ~= true then
        return false
    end

    self:stopSessionsForBatch(batch.sellerFarmId, batch.buyerFarmId)
    local closingBatch = #carryOrder > 0 and self:buildBatchView(batch, billableOrder) or batch
    local invoice = self:findReceipt(closingBatch.reference, closingBatch)
    local announcedReceipt = false
    if invoice == nil and closingBatch.totalGross > 0 then
        invoice = self:createReceipt(closingBatch)
        if invoice == nil then
            return false
        end
        if not self.invoiceManager.repository:add(invoice) then
            return false
        end
        self.invoiceManager.service:notifyUI()
        self:notifyReceiptCreated(invoice, closingBatch.reference)
        if g_server ~= nil then
            g_server:broadcastEvent(IPS_ReceiptEvent.new(invoice))
        end
        announcedReceipt = true
    end

    if invoice ~= nil then
        self.closedReceipts[closingBatch.reference] = invoice.id
    end
    self.openBatches[batch.reference] = nil
    local pairKey = self:getBatchPairKey(batch.sellerFarmId, batch.buyerFarmId)
    if self.openBatchByPair[pairKey] == batch.reference then
        self.openBatchByPair[pairKey] = nil
    end
    if #carryOrder > 0 then
        self:carryBatchLinesForward(batch, carryOrder)
    end
    return true, announcedReceipt, invoice ~= nil
end

---Closes a selected batch after seller manager validation.
-- @param Connection connection Requesting connection
-- @param string reference Batch reference
-- @return boolean success True on success
-- @return string resultKey Localization key
function IPS_Manager:closeBatchByRequest(connection, reference)
    if not self.integrationAvailable then return false, "ips_error_invoiceIncompatible" end
    if not self:connectionHasFarmManagerPermission(connection) then return false, "ips_error_noPermission" end
    local farmId = self:getFarmIdForConnection(connection)
    local batch = self.openBatches[reference]
    if batch == nil or batch.sellerFarmId ~= farmId then return false, "ips_error_offerUnavailable" end
    local closed, announcedReceipt, hasReceipt = self:closeBatch(batch, true)
    if not closed then return false, "ips_error_transactionFailed" end
    if announcedReceipt then return true, "" end
    if hasReceipt then return true, "ips_notice_batchClosed" end
    return true, "ips_notice_batchClosedEmpty"
end

---Stops sessions and closes all batches at a period boundary.
function IPS_Manager:onPeriodChanged()
    if g_server == nil or not self.integrationAvailable then return end
    self:stopAllSessions(false)
    local batches = {}
    for _, batch in pairs(self.openBatches) do table.insert(batches, batch) end
    table.sort(batches, function(a, b) return a.reference < b.reference end)
    for _, batch in ipairs(batches) do self:closeBatch(batch, true) end
    self:broadcastRefresh()
end

---Reconciles saved open batches against receipts already persisted by Invoice.
function IPS_Manager:reconcileReceiptReferences()
    if not self.integrationAvailable then return end
    local alreadyClosed = {}
    for _, batch in pairs(self.openBatches) do
        local billableOrder, carryOrder = self:partitionBatchLines(batch)
        local receiptBatch = #carryOrder > 0 and self:buildBatchView(batch, billableOrder) or batch
        local invoice = #billableOrder > 0 and self:findReceipt(batch.reference, receiptBatch) or nil
        if invoice ~= nil then
            self.closedReceipts[batch.reference] = invoice.id
            table.insert(alreadyClosed, {batch = batch, carryOrder = carryOrder})
        end
    end
    for _, record in ipairs(alreadyClosed) do
        local batch = record.batch
        self.openBatches[batch.reference] = nil
        local pairKey = self:getBatchPairKey(batch.sellerFarmId, batch.buyerFarmId)
        if self.openBatchByPair[pairKey] == batch.reference then self.openBatchByPair[pairKey] = nil end
        if #record.carryOrder > 0 then
            self:carryBatchLinesForward(batch, record.carryOrder)
        end
    end
end

---Builds exact purchase quotes for the currently available full pallets.
-- @param table offer Active offer
-- @param table productionPoint Production point
-- @param integer buyerFarmId Buyer farm
-- @param table records Purchasable pallet records
-- @return table Quotes indexed by pallet quantity
function IPS_Manager:getPalletPurchaseQuotes(offer, productionPoint, buyerFarmId, records)
    local quotes = {}
    if offer == nil or productionPoint == nil or buyerFarmId == nil or offer.sellerFarmId == buyerFarmId then
        return quotes
    end

    local vatRate = self:getCurrentVatRate()
    local lineKey = IPS_Util.makeLineKey(offer.productionUniqueId, offer.fillTypeIndex, offer.price, vatRate)
    local totalLiters = 0
    for index = 1, math.min(#(records or {}), IPS_Manager.MAX_PALLET_PURCHASE) do
        totalLiters = totalLiters + math.max(records[index].liters or 0, 0)
        local quote = self:getAtomicTransferQuote(
            offer.sellerFarmId,
            buyerFarmId,
            lineKey,
            offer.price,
            vatRate,
            totalLiters
        )
        if quote == nil then break end
        quotes[index] = quote
    end
    return quotes
end

---Purchases a quantity of full pallets using a catalog token and exact quote.
-- @param Connection connection Buyer connection
-- @param string offerKey Offer key
-- @param integer offerRevision Offer revision
-- @param integer quantity Requested pallets
-- @param string palletToken Client catalog token
-- @param integer quotedGross Exact server snapshot charge confirmed by the buyer
-- @return boolean success True on success
-- @return string resultKey Localization result key
function IPS_Manager:buyPallets(connection, offerKey, offerRevision, quantity, palletToken, quotedGross)
    if not self.integrationAvailable then return false, "ips_error_invoiceIncompatible" end
    local buyerFarmId = self:getFarmIdForConnection(connection)
    if buyerFarmId == nil or buyerFarmId == FarmManager.SPECTATOR_FARM_ID then return false, "ips_error_noFarm" end
    quantity = math.floor(tonumber(quantity) or 0)
    if quantity < 1 or quantity > IPS_Manager.MAX_PALLET_PURCHASE then return false, "ips_error_transactionFailed" end
    quotedGross = IPS_Util.sanitizeQuantity(quotedGross) or (quotedGross == 0 and 0 or nil)
    if quotedGross == nil then return false, "ips_error_transactionFailed" end

    local offer = self.offers[offerKey]
    local productionPoint = offer ~= nil and self.productionByUniqueId[offer.productionUniqueId] or nil
    if offer == nil
        or not offer.enabled
        or self:getActiveOffer(productionPoint, offer.fillTypeIndex) ~= offer
        or offer.revision ~= offerRevision
        or offer.sellerFarmId == buyerFarmId
        or not self:isOutputStored(productionPoint, offer.fillTypeIndex) then
        return false, "ips_error_offerChanged"
    end
    local mode = self:getOutputMode(productionPoint, offer.fillTypeIndex)
    if mode ~= IPS_Manager.MODE_PALLET and mode ~= IPS_Manager.MODE_BOTH then return false, "ips_error_noFullPallets" end

    local available = self:getAvailableOfferPallets(offer, productionPoint)
    if self:getPalletToken(available) ~= palletToken then return false, "ips_error_offerChanged" end
    if #available < quantity then return false, "ips_error_noFullPallets" end

    local selected = {}
    local selectedIds = {}
    for index = 1, quantity do
        selected[index] = available[index]
        selectedIds[available[index].uniqueId] = true
    end
    local totalLiters = self:getPalletLitersForQuantity(available, quantity)
    if totalLiters == nil then return false, "ips_error_offerChanged" end

    local revalidated = self:getAvailableOfferPallets(offer, productionPoint)
    local revalidatedById = {}
    for _, record in ipairs(revalidated) do revalidatedById[record.uniqueId] = record end
    for uniqueId in pairs(selectedIds) do
        if revalidatedById[uniqueId] == nil then return false, "ips_error_offerChanged" end
    end

    local vatRate = self:getCurrentVatRate()
    local lineKey = IPS_Util.makeLineKey(offer.productionUniqueId, offer.fillTypeIndex, offer.price, vatRate)
    local farm = g_farmManager:getFarmById(buyerFarmId)
    local availableMoney = farm ~= nil and math.floor(farm.money or 0) or -1
    local quote = self:getAtomicTransferQuote(
        offer.sellerFarmId,
        buyerFarmId,
        lineKey,
        offer.price,
        vatRate,
        totalLiters
    )
    if quote == nil or quote.gross ~= quotedGross then return false, "ips_error_offerChanged" end
    if availableMoney < quotedGross then
        return false, "ips_error_insufficientFunds"
    end
    local lineCapacity, lineBatchClosed = self:ensureBatchLineCapacity(offer.sellerFarmId, buyerFarmId, lineKey)
    if not lineCapacity then
        return false, "ips_error_transactionFailed"
    end
    local representable, receiptBatchClosed = self:prepareAtomicTransfer(
        offer.sellerFarmId,
        buyerFarmId,
        lineKey,
        offer.price,
        vatRate,
        totalLiters
    )
    if not representable then return false, "ips_error_transactionFailed" end

    if lineBatchClosed or receiptBatchClosed then
        offer = self.offers[offerKey]
        productionPoint = offer ~= nil and self.productionByUniqueId[offer.productionUniqueId] or nil
        if offer == nil
            or not offer.enabled
            or self:getActiveOffer(productionPoint, offer.fillTypeIndex) ~= offer
            or offer.revision ~= offerRevision
            or offer.sellerFarmId == buyerFarmId
            or not self:isOutputStored(productionPoint, offer.fillTypeIndex) then
            return false, "ips_error_offerChanged"
        end
        available = self:getAvailableOfferPallets(offer, productionPoint)
        if self:getPalletToken(available) ~= palletToken then return false, "ips_error_offerChanged" end
        if #available < quantity then return false, "ips_error_noFullPallets" end
        selected = {}
        for index = 1, quantity do selected[index] = available[index] end
        totalLiters = self:getPalletLitersForQuantity(available, quantity)
        if totalLiters == nil then return false, "ips_error_offerChanged" end
        if not self:isTransferRepresentable(
            self.openBatches[self.openBatchByPair[self:getBatchPairKey(offer.sellerFarmId, buyerFarmId)]],
            lineKey,
            offer.price,
            vatRate,
            totalLiters
        ) then
            return false, "ips_error_transactionFailed"
        end
    end

    local oldLiters = self:getExistingLineLiters(offer.sellerFarmId, buyerFarmId, lineKey)
    local expected = IPS_Util.computeCumulativeDelta(offer.price, oldLiters, totalLiters, vatRate, self.invoiceClass)
    if expected.deltaGross ~= quotedGross then return false, "ips_error_offerChanged" end
    if farm == nil or math.floor(farm.money or 0) < expected.deltaGross then return false, "ips_error_insufficientFunds" end

    if self:recordTransfer(offer, productionPoint, buyerFarmId, totalLiters, offer.price, vatRate) == nil then
        return false, "ips_error_transactionFailed"
    end
    if (offer.listedPallets or 0) > 0 then
        self:consumeOfferPallets(offer, totalLiters, quantity)
    else
        self:consumeOfferLiters(offer, totalLiters)
    end
    local vehicles = {}
    for _, record in ipairs(selected) do
        record.vehicle:setOwnerFarmId(buyerFarmId, true)
        table.insert(vehicles, record.vehicle)
    end
    if g_server ~= nil then
        g_server:broadcastEvent(IPS_PalletOwnershipEvent.new(vehicles, offer.sellerFarmId, buyerFarmId))
    end
    return true, "ips_notice_palletsPurchased"
end

---Builds one client-authorized catalog snapshot.
-- @param integer farmId Requesting farm
-- @return table Snapshot
function IPS_Manager:buildSnapshot(farmId)
    self:rebuildProductionIndex()
    self:validateOffers()
    local result = {compatible = self.integrationAvailable, market = {}, outputs = {}, batches = {}, purchases = {}}
    if not self.integrationAvailable then return result end

    for _, productionPoint in pairs(self.productionByUniqueId) do
        local uniqueId, ownerFarmId = self:getProductionIdentity(productionPoint)
        if ownerFarmId == farmId then
            for _, fillTypeIndex in ipairs(productionPoint.outputFillTypeIdsArray or {}) do
                local key = IPS_Util.makeOfferKey(uniqueId, fillTypeIndex)
                local offer = self.offers[key]
                local productName, iconFilename = self:getFillTypeMetadata(fillTypeIndex)
                local activeOffer = offer ~= nil and self:getActiveOffer(productionPoint, fillTypeIndex) or nil
                local mode = self:getOutputMode(productionPoint, fillTypeIndex)
                local hasPallets = mode == IPS_Manager.MODE_PALLET or mode == IPS_Manager.MODE_BOTH
                local pallets = hasPallets and self:getFullPallets(productionPoint, fillTypeIndex, ownerFarmId) or {}
                local offerableLiters = self:getOfferableLiters(productionPoint, fillTypeIndex, ownerFarmId, pallets)
                if activeOffer ~= nil and hasPallets then
                    pallets = self:getAvailableOfferPallets(offer, productionPoint, pallets)
                end
                table.insert(result.outputs, {
                    key = key,
                    productionPoint = productionPoint,
                    productionUniqueId = uniqueId,
                    fillTypeIndex = fillTypeIndex,
                    sellerFarmId = ownerFarmId,
                    sellerName = self:getFarmName(ownerFarmId),
                    productionName = self:getProductionName(productionPoint),
                    productName = productName,
                    iconFilename = iconFilename,
                    mode = mode,
                    stored = self:isOutputStored(productionPoint, fillTypeIndex),
                    stock = activeOffer ~= nil
                        and self:getAvailableOfferLiters(offer, productionPoint)
                        or self:getOutputStock(productionPoint, fillTypeIndex, ownerFarmId),
                    offerableLiters = offerableLiters,
                    listedLiters = offer ~= nil and offer.listedLiters or 0,
                    remainingLiters = offer ~= nil and offer.remainingLiters or 0,
                    listedPallets = offer ~= nil and offer.listedPallets or 0,
                    remainingPallets = offer ~= nil and offer.remainingPallets or 0,
                    palletCount = #pallets,
                    palletToken = self:getPalletToken(pallets),
                    palletQuotes = {},
                    price = offer ~= nil and offer.price or self:getDefaultPrice(fillTypeIndex),
                    enabled = activeOffer ~= nil,
                    revision = offer ~= nil and offer.revision or 0
                })
            end
        end
    end

    for _, offer in pairs(self.offers) do
        local productionPoint = self.productionByUniqueId[offer.productionUniqueId]
        if offer.enabled and self:getActiveOffer(productionPoint, offer.fillTypeIndex) ~= nil then
            local pallets = self:getAvailableOfferPallets(offer, productionPoint)
            local palletQuotes = self:getPalletPurchaseQuotes(offer, productionPoint, farmId, pallets)
            local productName, iconFilename = self:getFillTypeMetadata(offer.fillTypeIndex)
            table.insert(result.market, {
                key = offer.key,
                productionPoint = productionPoint,
                productionUniqueId = offer.productionUniqueId,
                fillTypeIndex = offer.fillTypeIndex,
                sellerFarmId = offer.sellerFarmId,
                sellerName = self:getFarmName(offer.sellerFarmId),
                productionName = self:getProductionName(productionPoint),
                productName = productName,
                iconFilename = iconFilename,
                mode = self:getOutputMode(productionPoint, offer.fillTypeIndex),
                stored = true,
                stock = self:getAvailableOfferLiters(offer, productionPoint),
                offerableLiters = offer.remainingLiters,
                listedLiters = offer.listedLiters,
                remainingLiters = offer.remainingLiters,
                listedPallets = offer.listedPallets or 0,
                remainingPallets = offer.remainingPallets or 0,
                palletCount = #pallets,
                palletToken = self:getPalletToken(pallets),
                palletQuotes = palletQuotes,
                price = offer.price,
                enabled = true,
                revision = offer.revision
            })
        end
    end

    for _, batch in pairs(self.openBatches) do
        local purchaseRow = {
            reference = batch.reference,
            sellerFarmId = batch.sellerFarmId,
            buyerFarmId = batch.buyerFarmId,
            sellerName = self:getFarmName(batch.sellerFarmId),
            buyerName = self:getFarmName(batch.buyerFarmId),
            fillTypeIndex = 0,
            productName = "",
            iconFilename = "",
            year = batch.year,
            period = batch.period,
            totalLiters = batch.totalLiters,
            totalGross = batch.totalGross,
            totalNet = batch.totalNet,
            totalVat = batch.totalVat,
            batchTotalGross = batch.totalGross,
            closed = false
        }
        if batch.buyerFarmId == farmId then table.insert(result.purchases, purchaseRow) end
        if batch.sellerFarmId == farmId then
            local products = {}
            for _, lineKey in ipairs(batch.lineOrder) do
                local line = batch.lines[lineKey]
                local product = products[line.fillTypeIndex]
                if product == nil then
                    product = {
                        fillTypeIndex = line.fillTypeIndex,
                        productName = line.productName,
                        iconFilename = line.iconFilename or "",
                        totalLiters = 0,
                        totalGross = 0,
                        totalNet = 0,
                        totalVat = 0
                    }
                    products[line.fillTypeIndex] = product
                end
                product.totalLiters = product.totalLiters + line.liters
                product.totalGross = product.totalGross + line.gross
                product.totalNet = product.totalNet + line.net
                product.totalVat = product.totalVat + line.vat
            end
            for _, product in pairs(products) do
                table.insert(result.batches, {
                    reference = batch.reference,
                    sellerFarmId = batch.sellerFarmId,
                    buyerFarmId = batch.buyerFarmId,
                    sellerName = purchaseRow.sellerName,
                    buyerName = purchaseRow.buyerName,
                    fillTypeIndex = product.fillTypeIndex,
                    productName = product.productName,
                    iconFilename = product.iconFilename,
                    year = batch.year,
                    period = batch.period,
                    totalLiters = product.totalLiters,
                    totalGross = product.totalGross,
                    totalNet = product.totalNet,
                    totalVat = product.totalVat,
                    batchTotalGross = batch.totalGross,
                    closed = false
                })
            end
        end
    end

    local currentYear, currentPeriod = self:getCurrentPeriod()
    local invoiceYear, invoicePeriod = self:getInvoicePeriodStamp(currentYear, currentPeriod)
    local invoicesById = {}
    if next(self.closedReceipts) ~= nil then
        for _, invoice in ipairs(self.invoiceManager.repository:getAll()) do
            invoicesById[invoice.id] = invoice
        end
    end
    for reference, invoiceId in pairs(self.closedReceipts) do
        local invoice = invoicesById[invoiceId]
        local createdAt = invoice ~= nil and invoice.createdAt or nil
        if invoice ~= nil
            and invoice.state == self.invoiceClass.STATE.PAID
            and invoice.recipientFarmId == farmId
            and createdAt ~= nil
            and createdAt.year == invoiceYear
            and createdAt.period == invoicePeriod then
            local marker = string.format("[IPS:%s]", reference)
            local markerCount = 0
            local validMarker = true
            local totalLiters = 0
            for _, item in ipairs(invoice.lineItems or {}) do
                if item.note == marker then
                    markerCount = markerCount + 1
                elseif item.note ~= nil and item.note ~= "" then
                    validMarker = false
                end
                if item.unitType == self.invoiceClass.UNIT_LITER then
                    totalLiters = totalLiters + math.max(item.quantity or 0, 0)
                end
            end
            if validMarker and markerCount == 1 then
                table.insert(result.purchases, {
                    reference = reference,
                    sellerFarmId = invoice.senderFarmId,
                    buyerFarmId = invoice.recipientFarmId,
                    sellerName = self:getFarmName(invoice.senderFarmId),
                    buyerName = self:getFarmName(invoice.recipientFarmId),
                    fillTypeIndex = 0,
                    productName = "",
                    iconFilename = "",
                    year = currentYear,
                    period = currentPeriod,
                    totalLiters = totalLiters,
                    totalGross = invoice.totalAmount or 0,
                    totalNet = invoice.totalHT or 0,
                    totalVat = invoice.vatAmount or 0,
                    batchTotalGross = invoice.totalAmount or 0,
                    closed = true
                })
            end
        end
    end

    local function sortRows(rows, first, second)
        table.sort(rows, function(a, b)
            local av, bv = tostring(a[first] or ""), tostring(b[first] or "")
            if av == bv then return tostring(a[second] or "") < tostring(b[second] or "") end
            return av < bv
        end)
    end
    sortRows(result.market, "sellerName", "productName")
    sortRows(result.outputs, "productionName", "productName")
    sortRows(result.batches, "buyerName", "productName")
    sortRows(result.purchases, "sellerName", "reference")
    return result
end

---Applies a server snapshot on a client.
-- @param table snapshot Authoritative data
function IPS_Manager:applySnapshot(snapshot)
    self.snapshot = snapshot or {compatible = false, market = {}, outputs = {}, batches = {}, purchases = {}}
    self.clientOffersByProduction = {}
    if self.snapshot.compatible == true then
        for _, row in ipairs(self.snapshot.market or {}) do
            if row.productionPoint ~= nil and row.fillTypeIndex ~= nil then
                local productionOffers = self.clientOffersByProduction[row.productionPoint]
                if productionOffers == nil then
                    productionOffers = {}
                    self.clientOffersByProduction[row.productionPoint] = productionOffers
                end
                productionOffers[row.fillTypeIndex] = row
            end
        end
    end
    self:rebuildProductionIndex()
    if IPS_FrameExtension ~= nil then IPS_FrameExtension.onSnapshotUpdated() end
end

---Sends one personalized snapshot to a client.
-- @param Connection connection Target connection
-- @param integer? farmId Known farm identifier during late join
function IPS_Manager:sendSnapshot(connection, farmId)
    if g_server == nil or connection == nil then return end
    self.pendingSnapshotRequests[connection] = nil
    self.snapshotRequestTimes[connection] = g_time or 0
    farmId = farmId or self:getFarmIdForConnection(connection) or FarmManager.SPECTATOR_FARM_ID
    connection:sendEvent(IPS_DataSyncEvent.new(self:buildSnapshot(farmId)))
end

---Rate-limits client-initiated snapshot scans per connection.
-- @param Connection connection Requesting connection
function IPS_Manager:sendRequestedSnapshot(connection)
    if g_server == nil or connection == nil then return end
    local now = g_time or 0
    local previous = self.snapshotRequestTimes[connection]
    if previous ~= nil and now >= previous and now - previous < IPS_Manager.SNAPSHOT_REQUEST_INTERVAL then
        if self.pendingSnapshotRequests[connection] == nil then
            self.pendingSnapshotRequests[connection] = previous + IPS_Manager.SNAPSHOT_REQUEST_INTERVAL
        end
        return
    end
    self.pendingSnapshotRequests[connection] = nil
    self.snapshotRequestTimes[connection] = now
    self:sendSnapshot(connection)
end

---Sends rate-limited requests once their per-connection delay expires.
function IPS_Manager:flushPendingSnapshotRequests()
    local now = g_time or 0
    for connection, dueTime in pairs(self.pendingSnapshotRequests) do
        if now >= dueTime then
            self.pendingSnapshotRequests[connection] = nil
            local players = g_currentMission ~= nil and g_currentMission.connectionsToPlayer or nil
            if players ~= nil and players[connection] ~= nil then
                self.snapshotRequestTimes[connection] = now
                self:sendSnapshot(connection)
            end
        end
    end
end

---Limits state-changing client commands per connection.
-- @param Connection connection Requesting connection
-- @return boolean True when the command may run
function IPS_Manager:canProcessCommand(connection)
    if connection == nil then return false end
    local now = g_time or 0
    local state = self.commandRequestTimes[connection]
    if state == nil or now < state.lastRefill then
        state = {tokens = IPS_Manager.COMMAND_BUCKET_CAPACITY, lastRefill = now}
        self.commandRequestTimes[connection] = state
    else
        local elapsedIntervals = math.floor((now - state.lastRefill) / IPS_Manager.COMMAND_REFILL_INTERVAL)
        if elapsedIntervals > 0 then
            state.tokens = math.min(IPS_Manager.COMMAND_BUCKET_CAPACITY, state.tokens + elapsedIntervals)
            state.lastRefill = state.lastRefill + elapsedIntervals * IPS_Manager.COMMAND_REFILL_INTERVAL
        end
    end
    if state.tokens < 1 then return false end
    state.tokens = state.tokens - 1
    return true
end

---Requests a fresh personalized snapshot from the server.
function IPS_Manager:requestSnapshot()
    if g_server ~= nil then
        local farmId = g_localPlayer ~= nil and g_localPlayer.farmId or FarmManager.SPECTATOR_FARM_ID
        self:applySnapshot(self:buildSnapshot(farmId))
    elseif g_client ~= nil then
        g_client:getServerConnection():sendEvent(IPS_DataRequestEvent.new())
    end
end

---Sends a localized result to one client.
-- @param Connection connection Target connection
-- @param boolean success Result status
-- @param string key Localization key
-- @param boolean refresh Whether client should request a snapshot
function IPS_Manager:sendResult(connection, success, key, refresh)
    if connection ~= nil then
        connection:sendEvent(IPS_ResultEvent.new(success, key or "", refresh == true, 0))
    end
end

---Asks clients to refresh their visible catalog.
-- @param Connection? excludedConnection Connection already synchronized directly
function IPS_Manager:broadcastRefresh(excludedConnection)
    if g_server ~= nil then
        g_server:broadcastEvent(IPS_ResultEvent.new(true, "", true, 0), false, excludedConnection)
    end
end

---Displays a result event locally.
-- @param boolean success Result status
-- @param string key Localization key
-- @param boolean refresh Whether to refresh
-- @param integer targetFarmId Optional target farm
function IPS_Manager:applyResult(success, key, refresh, targetFarmId)
    local localFarmId = g_localPlayer ~= nil and g_localPlayer.farmId or FarmManager.SPECTATOR_FARM_ID
    if targetFarmId ~= nil and targetFarmId > 0 and targetFarmId ~= localFarmId then return end
    if key ~= nil and key ~= "" and g_currentMission ~= nil then
        local notificationType = success and FSBaseMission.INGAME_NOTIFICATION_OK or FSBaseMission.INGAME_NOTIFICATION_CRITICAL
        local text = self:getText(key)
        if key == "ips_error_invoiceIncompatible" then
            text = string.format(text, tostring(self.detectedInvoiceVersion or "?"))
        end
        g_currentMission:addIngameNotification(notificationType, text)
    end
    if refresh then self:requestSnapshot() end
end

---Writes offers, open batches and receipt references to the companion XML.
-- @param string savegamePath Savegame directory
function IPS_Manager:saveToXML(savegamePath)
    if g_server == nil then return end
    local path = savegamePath .. "invoicesProductionSales.xml"
    local xmlFile = createXMLFile("invoicesProductionSales", path, "invoicesProductionSales")
    if xmlFile == nil then
        Logging.error("[InvoicesProductionSales] Failed to create save file: %s", path)
        return
    end
    setXMLInt(xmlFile, "invoicesProductionSales#version", IPS_Manager.SAVE_VERSION)
    setXMLInt(xmlFile, "invoicesProductionSales#nextBatchId", self.nextBatchId)

    local offerKeys = {}
    for key in pairs(self.offers) do table.insert(offerKeys, key) end
    table.sort(offerKeys)
    for index, key in ipairs(offerKeys) do
        local offer = self.offers[key]
        local xmlKey = string.format("invoicesProductionSales.offers.offer(%d)", index - 1)
        setXMLString(xmlFile, xmlKey .. "#productionUniqueId", offer.productionUniqueId)
        setXMLInt(xmlFile, xmlKey .. "#fillTypeIndex", offer.fillTypeIndex)
        setXMLInt(xmlFile, xmlKey .. "#sellerFarmId", offer.sellerFarmId)
        setXMLInt(xmlFile, xmlKey .. "#price", offer.price)
        setXMLFloat(xmlFile, xmlKey .. "#listedLiters", offer.listedLiters or 0)
        setXMLFloat(xmlFile, xmlKey .. "#remainingLiters", offer.remainingLiters or 0)
        setXMLInt(xmlFile, xmlKey .. "#listedPallets", offer.listedPallets or 0)
        setXMLInt(xmlFile, xmlKey .. "#remainingPallets", offer.remainingPallets or 0)
        setXMLBool(xmlFile, xmlKey .. "#enabled", offer.enabled)
        setXMLInt(xmlFile, xmlKey .. "#revision", offer.revision)
    end

    local batchKeys = {}
    for key in pairs(self.openBatches) do table.insert(batchKeys, key) end
    table.sort(batchKeys)
    for batchIndex, reference in ipairs(batchKeys) do
        local batch = self.openBatches[reference]
        local batchKey = string.format("invoicesProductionSales.openBatches.batch(%d)", batchIndex - 1)
        setXMLString(xmlFile, batchKey .. "#reference", batch.reference)
        setXMLInt(xmlFile, batchKey .. "#sellerFarmId", batch.sellerFarmId)
        setXMLInt(xmlFile, batchKey .. "#buyerFarmId", batch.buyerFarmId)
        setXMLInt(xmlFile, batchKey .. "#year", batch.year)
        setXMLInt(xmlFile, batchKey .. "#period", batch.period)
        for lineIndex, lineKey in ipairs(batch.lineOrder) do
            local line = batch.lines[lineKey]
            local xmlKey = string.format("%s.line(%d)", batchKey, lineIndex - 1)
            setXMLString(xmlFile, xmlKey .. "#productionUniqueId", line.productionUniqueId)
            setXMLString(xmlFile, xmlKey .. "#productionName", line.productionName)
            setXMLInt(xmlFile, xmlKey .. "#fillTypeIndex", line.fillTypeIndex)
            setXMLString(xmlFile, xmlKey .. "#productName", line.productName)
            setXMLString(xmlFile, xmlKey .. "#iconFilename", line.iconFilename or "")
            setXMLFloat(xmlFile, xmlKey .. "#price", line.price)
            setXMLFloat(xmlFile, xmlKey .. "#vatRate", line.vatRate)
            setXMLFloat(xmlFile, xmlKey .. "#liters", line.liters)
            setXMLInt(xmlFile, xmlKey .. "#gross", line.gross)
            setXMLInt(xmlFile, xmlKey .. "#net", line.net)
            setXMLInt(xmlFile, xmlKey .. "#vat", line.vat)
        end
    end

    local receiptKeys = {}
    for key in pairs(self.closedReceipts) do table.insert(receiptKeys, key) end
    table.sort(receiptKeys)
    for index, reference in ipairs(receiptKeys) do
        local xmlKey = string.format("invoicesProductionSales.receipts.receipt(%d)", index - 1)
        setXMLString(xmlFile, xmlKey .. "#reference", reference)
        setXMLInt(xmlFile, xmlKey .. "#invoiceId", self.closedReceipts[reference])
    end
    saveXMLFile(xmlFile)
    delete(xmlFile)
end

---Loads companion state from the savegame.
-- @param string savegamePath Savegame directory
function IPS_Manager:loadFromXML(savegamePath)
    local path = savegamePath .. "invoicesProductionSales.xml"
    if not fileExists(path) then return end
    local xmlFile = loadXMLFile("invoicesProductionSales", path)
    if xmlFile == nil then
        Logging.warning("[InvoicesProductionSales] Failed to load save file: %s", path)
        return
    end
    local version = getXMLInt(xmlFile, "invoicesProductionSales#version") or 1
    if version > IPS_Manager.SAVE_VERSION then
        Logging.warning("[InvoicesProductionSales] Save version %d is newer than supported version %d", version, IPS_Manager.SAVE_VERSION)
    end
    self.nextBatchId = math.max(getXMLInt(xmlFile, "invoicesProductionSales#nextBatchId") or 1, 1)

    local index = 0
    while hasXMLProperty(xmlFile, string.format("invoicesProductionSales.offers.offer(%d)", index)) do
        local xmlKey = string.format("invoicesProductionSales.offers.offer(%d)", index)
        local productionUniqueId = getXMLString(xmlFile, xmlKey .. "#productionUniqueId") or ""
        local fillTypeIndex = getXMLInt(xmlFile, xmlKey .. "#fillTypeIndex") or 0
        local savedPrice = getXMLFloat(xmlFile, xmlKey .. "#price")
        local price = savedPrice ~= nil and IPS_Util.sanitizePrice(IPS_Util.roundCurrency(savedPrice)) or nil
        if productionUniqueId ~= "" and fillTypeIndex > 0 and price ~= nil then
            local key = IPS_Util.makeOfferKey(productionUniqueId, fillTypeIndex)
            local sellerFarmId = getXMLInt(xmlFile, xmlKey .. "#sellerFarmId") or 0
            local enabled = getXMLBool(xmlFile, xmlKey .. "#enabled") == true
            local listedLiters = getXMLFloat(xmlFile, xmlKey .. "#listedLiters")
            local remainingLiters = getXMLFloat(xmlFile, xmlKey .. "#remainingLiters")
            local listedPallets = version >= 3 and (getXMLInt(xmlFile, xmlKey .. "#listedPallets") or 0) or 0
            local remainingPallets = version >= 3 and (getXMLInt(xmlFile, xmlKey .. "#remainingPallets") or 0) or 0
            if version < 2 or listedLiters == nil or remainingLiters == nil then
                local productionPoint = self.productionByUniqueId[productionUniqueId]
                local migratedStock = enabled
                    and math.floor(math.max(self:getOutputStock(productionPoint, fillTypeIndex, sellerFarmId), 0))
                    or 0
                listedLiters = migratedStock
                remainingLiters = migratedStock
            end
            local validListedLiters = listedLiters == 0 or IPS_Util.sanitizeQuantity(listedLiters) ~= nil
            local validRemainingLiters = IPS_Util.isFiniteNumber(remainingLiters)
                and remainingLiters >= 0
                and remainingLiters <= listedLiters + IPS_Util.EPSILON
            local validPallets = listedPallets >= 0
                and listedPallets == math.floor(listedPallets)
                and remainingPallets >= 0
                and remainingPallets == math.floor(remainingPallets)
                and remainingPallets <= listedPallets
            if not validListedLiters or not validRemainingLiters or not validPallets then
                listedLiters = 0
                remainingLiters = 0
                listedPallets = 0
                remainingPallets = 0
                enabled = false
            end
            if enabled and ((listedPallets > 0 and remainingPallets <= 0)
                or (listedPallets <= 0 and remainingLiters <= IPS_Util.EPSILON)) then
                enabled = false
            end
            self.offers[key] = {
                key = key,
                productionUniqueId = productionUniqueId,
                fillTypeIndex = fillTypeIndex,
                sellerFarmId = sellerFarmId,
                price = price,
                listedLiters = listedLiters,
                remainingLiters = remainingLiters,
                listedPallets = listedPallets,
                remainingPallets = remainingPallets,
                enabled = enabled,
                revision = math.max(getXMLInt(xmlFile, xmlKey .. "#revision") or 0, 0)
            }
        end
        index = index + 1
    end

    index = 0
    while hasXMLProperty(xmlFile, string.format("invoicesProductionSales.openBatches.batch(%d)", index)) do
        local batchKey = string.format("invoicesProductionSales.openBatches.batch(%d)", index)
        local reference = getXMLString(xmlFile, batchKey .. "#reference") or ""
        local batch = {
            reference = reference,
            sellerFarmId = getXMLInt(xmlFile, batchKey .. "#sellerFarmId") or 0,
            buyerFarmId = getXMLInt(xmlFile, batchKey .. "#buyerFarmId") or 0,
            year = getXMLInt(xmlFile, batchKey .. "#year") or 1,
            period = getXMLInt(xmlFile, batchKey .. "#period") or 1,
            totalLiters = 0,
            totalGross = 0,
            totalNet = 0,
            totalVat = 0,
            lines = {},
            lineOrder = {}
        }
        local lineIndex = 0
        while hasXMLProperty(xmlFile, string.format("%s.line(%d)", batchKey, lineIndex)) do
            local xmlKey = string.format("%s.line(%d)", batchKey, lineIndex)
            local productionUniqueId = getXMLString(xmlFile, xmlKey .. "#productionUniqueId") or ""
            local fillTypeIndex = getXMLInt(xmlFile, xmlKey .. "#fillTypeIndex") or 0
            local price = getXMLFloat(xmlFile, xmlKey .. "#price") or 0
            local vatRate = getXMLFloat(xmlFile, xmlKey .. "#vatRate") or 0
            local lineKey = IPS_Util.makeLineKey(productionUniqueId, fillTypeIndex, price, vatRate)
            local line = {
                key = lineKey,
                productionUniqueId = productionUniqueId,
                productionName = getXMLString(xmlFile, xmlKey .. "#productionName") or "",
                fillTypeIndex = fillTypeIndex,
                productName = getXMLString(xmlFile, xmlKey .. "#productName") or "",
                iconFilename = getXMLString(xmlFile, xmlKey .. "#iconFilename") or "",
                price = price,
                vatRate = vatRate,
                liters = getXMLFloat(xmlFile, xmlKey .. "#liters") or 0,
                gross = getXMLInt(xmlFile, xmlKey .. "#gross") or 0,
                net = getXMLInt(xmlFile, xmlKey .. "#net") or 0,
                vat = getXMLInt(xmlFile, xmlKey .. "#vat") or 0
            }
            batch.lines[lineKey] = line
            table.insert(batch.lineOrder, lineKey)
            batch.totalLiters = batch.totalLiters + line.liters
            batch.totalGross = batch.totalGross + line.gross
            batch.totalNet = batch.totalNet + line.net
            batch.totalVat = batch.totalVat + line.vat
            lineIndex = lineIndex + 1
        end
        if reference ~= "" and batch.sellerFarmId > 0 and batch.buyerFarmId > 0 then
            self.openBatches[reference] = batch
            self.openBatchByPair[self:getBatchPairKey(batch.sellerFarmId, batch.buyerFarmId)] = reference
        end
        index = index + 1
    end

    index = 0
    while hasXMLProperty(xmlFile, string.format("invoicesProductionSales.receipts.receipt(%d)", index)) do
        local xmlKey = string.format("invoicesProductionSales.receipts.receipt(%d)", index)
        local reference = getXMLString(xmlFile, xmlKey .. "#reference") or ""
        if reference ~= "" then self.closedReceipts[reference] = getXMLInt(xmlFile, xmlKey .. "#invoiceId") or 0 end
        index = index + 1
    end
    delete(xmlFile)
end
