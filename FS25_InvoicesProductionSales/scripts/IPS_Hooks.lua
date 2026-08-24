-- Copyright © 2026 Squallqt. All rights reserved.
---Narrow engine hooks for confirmed paid production loading and receipt display.
IPS_Hooks = {
    installed = false
}

---Returns the manager owned by the current mission.
-- @return table|nil manager Production sales manager
local function getManager()
    return g_currentMission ~= nil and g_currentMission.invoicesProductionSalesManager or nil
end

---Returns the farm currently associated with a trigger target.
-- @param table trigger Load trigger
-- @return integer|nil farmId Target farm
local function getTriggerFarmId(trigger)
    local targetObject = trigger.validFillableObject or trigger.currentFillableObject
    if targetObject ~= nil and trigger.farmIdForFillableObject ~= nil then
        return trigger:farmIdForFillableObject(targetObject)
    end
    if g_currentMission ~= nil and g_currentMission.getFarmId ~= nil then
        return g_currentMission:getFarmId()
    end
    return nil
end

---Restores an instance method after a protected synchronous call.
-- @param table object Target object
-- @param string methodName Method field name
-- @param function replacement Temporary method
-- @param function callback Synchronous callback
-- @return any result Callback result
local function callWithTemporaryMethod(object, methodName, replacement, callback)
    local previousOwnMethod = rawget(object, methodName)
    object[methodName] = replacement
    local success, result = pcall(callback)
    object[methodName] = previousOwnMethod
    if not success then
        error(result)
    end
    return result
end

---Extends station access only while a public bulk offer exists.
local function loadingStationGetIsFillAllowedToFarm(self, superFunc, farmId)
    if superFunc(self, farmId) then
        return true
    end

    local manager = getManager()
    return manager ~= nil and manager:stationHasBulkOfferForExternalFarm(self, farmId)
end

---Returns whether a fill unit accepts at least one currently offered product.
-- @param table manager Production sales manager
-- @param table trigger Load trigger
-- @param integer buyerFarmId Buyer farm
-- @param table fillableObject Target vehicle
-- @param integer fillUnitIndex Target fill unit
-- @return boolean True when a paid product can be loaded
local function getHasCompatiblePaidFillType(manager, trigger, buyerFarmId, fillableObject, fillUnitIndex)
    local offeredFillLevels = manager:getOfferedFillLevels(trigger, buyerFarmId)
    for fillTypeIndex, fillLevel in pairs(offeredFillLevels or {}) do
        if fillLevel > IPS_Util.EPSILON
            and fillableObject:getFillUnitSupportsFillType(fillUnitIndex, fillTypeIndex)
            and fillableObject:getFillUnitAllowsFillType(fillUnitIndex, fillTypeIndex) then
            return true
        end
    end
    return false
end

---Finds a valid manual target after native farm access rejected an external buyer.
-- @param table trigger Load trigger
-- @param table manager Production sales manager
-- @return boolean True when a public paid target was selected
local function selectPaidFillableObject(trigger, manager)
    if trigger.isLoading or next(trigger.fillableObjects or {}) == nil then
        return false
    end

    local hasLowPriorityObject = false
    local objectCount = 0
    for _, fillable in pairs(trigger.fillableObjects) do
        hasLowPriorityObject = hasLowPriorityObject or fillable.lastWasFilled == true
        objectCount = objectCount + 1
    end
    hasLowPriorityObject = hasLowPriorityObject and objectCount > 1

    for _, fillable in pairs(trigger.fillableObjects) do
        local object = fillable.object
        local fillUnitIndex = fillable.fillUnitIndex
        if (not fillable.lastWasFilled or not hasLowPriorityObject)
            and object ~= nil
            and fillUnitIndex ~= nil
            and trigger:getAllowsActivation(object)
            and object:getFillUnitSupportsToolType(fillUnitIndex, ToolType.TRIGGER)
            and object:getFillUnitFreeCapacity(fillUnitIndex, nil, nil) > IPS_Util.EPSILON then
            local buyerFarmId = trigger:farmIdForFillableObject(object)
            if manager:stationHasBulkOfferForExternalFarm(trigger.source, buyerFarmId)
                and getHasCompatiblePaidFillType(manager, trigger, buyerFarmId, object, fillUnitIndex) then
                trigger.validFillableObject = object
                trigger.validFillableFillUnitIndex = fillUnitIndex
                return true
            end
        end
    end
    return false
end

---Extends manual availability without allowing automatic paid loading.
local function loadTriggerGetIsFillableObjectAvailable(self, superFunc)
    local available = superFunc(self)
    local manager = getManager()
    if available then
        if (self.autoStart or self.automaticFilling) and manager ~= nil then
            local buyerFarmId = getTriggerFarmId(self)
            if manager:stationHasBulkOfferForExternalFarm(self.source, buyerFarmId) then
                if not self.isLoading then
                    self.validFillableObject = nil
                    self.validFillableFillUnitIndex = nil
                end
                return false
            end
        end
        return true
    end

    if manager == nil or self.autoStart or self.automaticFilling then
        return false
    end
    return selectPaidFillableObject(self, manager)
end

---Filters the native fill-type dialog to public production offers.
local function loadTriggerToggleLoading(self, superFunc)
    self.ipsPendingBulkSelection = nil
    if self.isLoading then
        return superFunc(self)
    end

    local manager = getManager()
    local source = self.source
    local buyerFarmId = getTriggerFarmId(self)
    if manager == nil
        or source == nil
        or source.getAllFillLevels == nil
        or not manager:stationHasBulkOfferForExternalFarm(source, buyerFarmId) then
        return superFunc(self)
    end

    if self.autoStart or self.automaticFilling then
        return
    end

    local offeredFillLevels = manager:getOfferedFillLevels(self, buyerFarmId) or {}
    if next(offeredFillLevels) == nil then
        manager:applyResult(false, "ips_error_noStock", true, 0)
        return
    end

    local revisions = {}
    for fillTypeIndex in pairs(offeredFillLevels) do
        local offer = manager:getOfferForTrigger(self, fillTypeIndex, buyerFarmId)
        if offer ~= nil then
            revisions[fillTypeIndex] = offer.revision
        end
    end
    self.ipsPendingBulkSelection = {
        buyerFarmId = buyerFarmId,
        revisions = revisions
    }

    return callWithTemporaryMethod(source, "getAllFillLevels", function()
        return offeredFillLevels
    end, function()
        return superFunc(self)
    end)
end

---Sends a confirmed loading request to the authoritative server.
-- @param table context Confirmation context
-- @param boolean confirmed User response
function IPS_Hooks.onBulkLoadingConfirmed(context, confirmed)
    if not confirmed or context == nil or g_client == nil then
        return
    end
    local connection = g_client:getServerConnection()
    if connection == nil then
        return
    end
    connection:sendEvent(IPS_StartLoadingEvent.new(
        context.trigger,
        context.targetObject,
        context.fillUnitIndex,
        context.fillTypeIndex,
        context.offerRevision
    ))
end

---Replaces a paid selection with a confirmation and custom server request.
local function loadTriggerOnFillTypeSelection(self, superFunc, fillTypeIndex)
    local pending = self.ipsPendingBulkSelection
    self.ipsPendingBulkSelection = nil
    if fillTypeIndex == nil or fillTypeIndex == FillType.UNKNOWN then
        return superFunc(self, fillTypeIndex)
    end

    local manager = getManager()
    local buyerFarmId = pending ~= nil and pending.buyerFarmId or getTriggerFarmId(self)
    local offer, productionPoint = nil, nil
    if manager ~= nil then
        offer, productionPoint = manager:getOfferForTrigger(self, fillTypeIndex, buyerFarmId)
    end
    if pending == nil and offer == nil then
        return superFunc(self, fillTypeIndex)
    end

    local pendingRevision = pending ~= nil and pending.revisions[fillTypeIndex] or nil
    if offer == nil or (pending ~= nil and pendingRevision ~= offer.revision) then
        if manager ~= nil and manager.applyResult ~= nil then
            manager:applyResult(false, "ips_error_offerChanged", true, 0)
        end
        return
    end

    local targetObject = self.validFillableObject
    local fillUnitIndex = self.validFillableFillUnitIndex
    if targetObject == nil or fillUnitIndex == nil or g_client == nil then
        return
    end

    local productName = manager:getFillTypeMetadata(fillTypeIndex)
    local productionName = manager:getProductionName(productionPoint)
    local sellerName = manager:getFarmName(offer.sellerFarmId)
    local priceText = string.format(
        "%s (%s)",
        g_i18n:formatMoney(offer.price, 0, true, false),
        manager:getText("ips_label_taxIncluded")
    )
    local confirmationText = string.format(
        manager:getText("ips_confirm_bulk"),
        productName,
        productionName,
        sellerName,
        priceText
    )
    local context = {
        trigger = self,
        targetObject = targetObject,
        fillUnitIndex = fillUnitIndex,
        fillTypeIndex = fillTypeIndex,
        offerRevision = offer.revision
    }
    YesNoDialog.show(IPS_Hooks.onBulkLoadingConfirmed, context, confirmationText)
end

---Requires the one-shot server authorization for every offered external start.
local function loadTriggerSetIsLoading(self, superFunc, isLoading, targetObject, fillUnitIndex, fillTypeIndex, noEventSend)
    if isLoading and self.isServer then
        local manager = getManager()
        local buyerFarmId = targetObject ~= nil and self:farmIdForFillableObject(targetObject) or nil
        if manager ~= nil and manager:stationHasBulkOfferForExternalFarm(self.source, buyerFarmId) then
            local offer = manager:getOfferForTrigger(self, fillTypeIndex, buyerFarmId)
            if offer ~= nil then
                if not manager:consumeStartAuthorization(self, targetObject, fillUnitIndex, fillTypeIndex) then
                    return
                end
            else
                return
            end
        end
    end
    return superFunc(self, isLoading, targetObject, fillUnitIndex, fillTypeIndex, noEventSend)
end

---Calls the native transfer with seller storage access and an affordable cap.
-- @param table source Loading station
-- @param function nativeAddFill Native transfer method
-- @param table session Paid loading session
-- @param table fillableObject Target vehicle
-- @param integer fillUnitIndex Target fill unit
-- @param integer fillTypeIndex Selected fill type
-- @param number requestedLiters Native requested volume
-- @param table fillInfo Native fill information
-- @param integer toolType Native tool type
-- @return number|nil exactLiters Native transferred volume
local function transferPaidFill(source, nativeAddFill, session, fillableObject, fillUnitIndex, fillTypeIndex, requestedLiters, fillInfo, toolType)
    local manager = getManager()
    if manager == nil
        or not manager:isSessionValid(session)
        or fillableObject ~= session.targetObject
        or fillUnitIndex ~= session.fillUnitIndex
        or fillTypeIndex ~= session.fillTypeIndex
        or not IPS_Util.isFiniteNumber(requestedLiters) then
        session.stopInvalid = true
        return 0
    end
    if requestedLiters <= IPS_Util.EPSILON then
        return 0
    end

    local affordableLiters, limitedByFunds, limitedByReceipt, limitedByQuantity = manager:getAffordableSessionLiters(
        session,
        requestedLiters
    )
    if affordableLiters <= IPS_Util.EPSILON then
        session.stopForFunds = limitedByFunds
        session.stopForReceipt = limitedByReceipt
        session.stopForQuantity = limitedByQuantity
        if not limitedByFunds and not limitedByReceipt and not limitedByQuantity then session.stopInvalid = true end
        return 0
    end

    local nativeFarmAccess = source.getIsFillAllowedToFarm
    local nativeStorageAccess = source.hasFarmAccessToStorage
    local function executeWithStorageAccess()
        return nativeAddFill(
            source,
            fillableObject,
            fillUnitIndex,
            fillTypeIndex,
            affordableLiters,
            fillInfo,
            toolType
        )
    end

    local function executeNativeTransfer()
        if nativeStorageAccess == nil then
            return executeWithStorageAccess()
        end
        return callWithTemporaryMethod(source, "hasFarmAccessToStorage", function(station, farmId, storage)
            if farmId == session.buyerFarmId then
                return nativeStorageAccess(station, session.sellerFarmId, storage)
            end
            return nativeStorageAccess(station, farmId, storage)
        end, executeWithStorageAccess)
    end

    local exactLiters
    if nativeFarmAccess ~= nil then
        exactLiters = callWithTemporaryMethod(source, "getIsFillAllowedToFarm", function(station, farmId)
            if farmId == session.buyerFarmId then
                return true
            end
            return nativeFarmAccess(station, farmId)
        end, executeNativeTransfer)
    else
        exactLiters = executeNativeTransfer()
    end

    if IPS_Util.isFiniteNumber(exactLiters) and exactLiters > IPS_Util.EPSILON then
        manager:onBulkTransferred(session, exactLiters)
        if limitedByFunds and exactLiters + IPS_Util.EPSILON >= affordableLiters then
            session.stopForFunds = true
        end
        if limitedByReceipt and exactLiters + IPS_Util.EPSILON >= affordableLiters then
            session.stopForReceipt = true
        end
        if limitedByQuantity and exactLiters + IPS_Util.EPSILON >= affordableLiters then
            session.stopForQuantity = true
        end
    end
    return exactLiters
end

---Captures the exact server transfer delta without replacing native update logic.
local function loadTriggerUpdate(self, superFunc, dt)
    local manager = getManager()
    local session = self.isServer and manager ~= nil and manager:getSession(self) or nil
    local source = self.source
    if session == nil or source == nil or source.addFillLevelToFillableObject == nil then
        return superFunc(self, dt)
    end

    local nativeAddFill = source.addFillLevelToFillableObject
    local result = callWithTemporaryMethod(source, "addFillLevelToFillableObject", function(_, fillableObject, fillUnitIndex, fillTypeIndex, requestedLiters, fillInfo, toolType)
        return transferPaidFill(
            source,
            nativeAddFill,
            session,
            fillableObject,
            fillUnitIndex,
            fillTypeIndex,
            requestedLiters,
            fillInfo,
            toolType
        )
    end, function()
        return superFunc(self, dt)
    end)

    local stoppedForFunds = session.stopForFunds == true
    local stoppedForReceipt = session.stopForReceipt == true
    local stoppedForQuantity = session.stopForQuantity == true
    local stoppedAsInvalid = session.stopInvalid == true
    if stoppedForFunds or stoppedForReceipt or stoppedForQuantity or stoppedAsInvalid then
        session.stopForFunds = false
        session.stopForReceipt = false
        session.stopForQuantity = false
        session.stopInvalid = false
        if self.isLoading then
            self:setIsLoading(false)
        end
        local receiptClosed = true
        if stoppedForReceipt then
            receiptClosed = manager:closeCurrentBatchForPair(session.sellerFarmId, session.buyerFarmId)
        end
        local resultKey = "ips_error_offerUnavailable"
        local resultSuccess = false
        if stoppedForReceipt then
            resultKey = receiptClosed and "ips_notice_batchClosed" or "ips_error_transactionFailed"
            resultSuccess = receiptClosed
        elseif stoppedForFunds then
            resultKey = "ips_notice_loadingStoppedFunds"
        end
        if not stoppedForQuantity or stoppedForFunds or stoppedForReceipt or stoppedAsInvalid then
            manager:sendResult(
                session.connection,
                resultSuccess,
                resultKey,
                true
            )
        end
    end
    return result
end

---Removes the server session after every native stop path.
local function loadTriggerStopLoading(self, superFunc)
    local manager = getManager()
    local session = self.isServer and manager ~= nil and manager:getSession(self) or nil
    local result = superFunc(self)
    if session ~= nil then
        if session.hasMoneyMovement and g_currentMission.showMoneyChange ~= nil then
            g_currentMission:showMoneyChange(MoneyType.INVOICE_EXPENSE, nil, false, session.buyerFarmId)
            g_currentMission:showMoneyChange(MoneyType.INVOICE_INCOME, nil, false, session.sellerFarmId)
        end
        manager:removeSession(self)
    end
    return result
end

---Invalidates offers before native production ownership changes.
local function productionPointSetOwnerFarmId(self, superFunc, farmId, ...)
    local manager = getManager()
    if self.isServer and manager ~= nil then
        manager:onProductionOwnerChanging(self, farmId)
    end
    local result = superFunc(self, farmId, ...)
    if manager ~= nil then
        manager:rebuildProductionIndex()
    end
    return result
end

---Installs global wrappers once while resolving the mission manager dynamically.
function IPS_Hooks.install()
    if IPS_Hooks.installed then
        return
    end

    LoadingStation.getIsFillAllowedToFarm = Utils.overwrittenFunction(
        LoadingStation.getIsFillAllowedToFarm,
        loadingStationGetIsFillAllowedToFarm
    )
    LoadTrigger.getIsFillableObjectAvailable = Utils.overwrittenFunction(
        LoadTrigger.getIsFillableObjectAvailable,
        loadTriggerGetIsFillableObjectAvailable
    )
    LoadTrigger.toggleLoading = Utils.overwrittenFunction(LoadTrigger.toggleLoading, loadTriggerToggleLoading)
    LoadTrigger.onFillTypeSelection = Utils.overwrittenFunction(
        LoadTrigger.onFillTypeSelection,
        loadTriggerOnFillTypeSelection
    )
    LoadTrigger.setIsLoading = Utils.overwrittenFunction(LoadTrigger.setIsLoading, loadTriggerSetIsLoading)
    LoadTrigger.update = Utils.overwrittenFunction(LoadTrigger.update, loadTriggerUpdate)
    LoadTrigger.stopLoading = Utils.overwrittenFunction(LoadTrigger.stopLoading, loadTriggerStopLoading)
    ProductionPoint.setOwnerFarmId = Utils.overwrittenFunction(
        ProductionPoint.setOwnerFarmId,
        productionPointSetOwnerFarmId
    )
    IPS_Hooks.installed = true
end
