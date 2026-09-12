-- Copyright © 2026 Squallqt. All rights reserved.
---Server-authoritative seller and pallet market commands.
IPS_CommandEvent = {}
local IPS_CommandEvent_mt = Class(IPS_CommandEvent, Event)

InitEventClass(IPS_CommandEvent, "IPS_CommandEvent")

IPS_CommandEvent.ACTION_SET_OFFER = 1
IPS_CommandEvent.ACTION_CLOSE_BATCH = 2
IPS_CommandEvent.ACTION_BUY_PALLETS = 3

function IPS_CommandEvent.emptyNew()
    return Event.new(IPS_CommandEvent_mt)
end

function IPS_CommandEvent.newSetOffer(productionUniqueId, fillTypeIndex, enabled, price, listedQuantity)
    local self = IPS_CommandEvent.emptyNew()
    self.action = IPS_CommandEvent.ACTION_SET_OFFER
    self.productionUniqueId = productionUniqueId
    self.fillTypeIndex = fillTypeIndex
    self.enabled = enabled
    self.price = price
    self.listedQuantity = listedQuantity
    return self
end

function IPS_CommandEvent.newCloseBatch(reference)
    local self = IPS_CommandEvent.emptyNew()
    self.action = IPS_CommandEvent.ACTION_CLOSE_BATCH
    self.reference = reference
    return self
end

function IPS_CommandEvent.newBuyPallets(offerKey, revision, quantity, palletToken, quotedGross)
    local self = IPS_CommandEvent.emptyNew()
    self.action = IPS_CommandEvent.ACTION_BUY_PALLETS
    self.offerKey = offerKey
    self.revision = revision
    self.quantity = quantity
    self.palletToken = palletToken
    self.quotedGross = quotedGross
    return self
end

function IPS_CommandEvent:writeStream(streamId, connection)
    streamWriteUInt8(streamId, self.action)
    if self.action == IPS_CommandEvent.ACTION_SET_OFFER then
        streamWriteString(streamId, self.productionUniqueId or "")
        streamWriteInt16(streamId, self.fillTypeIndex or 0)
        streamWriteBool(streamId, self.enabled == true)
        streamWriteInt32(streamId, self.price or 0)
        streamWriteInt32(streamId, self.listedQuantity or 0)
    elseif self.action == IPS_CommandEvent.ACTION_CLOSE_BATCH then
        streamWriteString(streamId, self.reference or "")
    elseif self.action == IPS_CommandEvent.ACTION_BUY_PALLETS then
        streamWriteString(streamId, self.offerKey or "")
        streamWriteInt32(streamId, self.revision or 0)
        streamWriteUInt16(streamId, self.quantity or 0)
        streamWriteString(streamId, self.palletToken or "")
        streamWriteInt32(streamId, self.quotedGross or 0)
    end
end

function IPS_CommandEvent:readStream(streamId, connection)
    self.action = streamReadUInt8(streamId)
    if self.action == IPS_CommandEvent.ACTION_SET_OFFER then
        self.productionUniqueId = streamReadString(streamId)
        self.fillTypeIndex = streamReadInt16(streamId)
        self.enabled = streamReadBool(streamId)
        self.price = streamReadInt32(streamId)
        self.listedQuantity = streamReadInt32(streamId)
    elseif self.action == IPS_CommandEvent.ACTION_CLOSE_BATCH then
        self.reference = streamReadString(streamId)
    elseif self.action == IPS_CommandEvent.ACTION_BUY_PALLETS then
        self.offerKey = streamReadString(streamId)
        self.revision = streamReadInt32(streamId)
        self.quantity = streamReadUInt16(streamId)
        self.palletToken = streamReadString(streamId)
        self.quotedGross = streamReadInt32(streamId)
    end
    self:run(connection)
end

function IPS_CommandEvent:run(connection)
    if connection:getIsServer() then return end
    local manager = g_currentMission.invoicesProductionSalesManager
    if manager == nil then return end
    if not manager:canProcessCommand(connection) then
        manager:sendResult(connection, false, "ips_error_transactionFailed", false)
        return
    end

    local success, resultKey, changed = false, "ips_error_transactionFailed", false
    if self.action == IPS_CommandEvent.ACTION_SET_OFFER then
        success, resultKey, changed = manager:setOffer(
            connection,
            self.productionUniqueId,
            self.fillTypeIndex,
            self.enabled,
            self.price,
            self.listedQuantity
        )
    elseif self.action == IPS_CommandEvent.ACTION_CLOSE_BATCH then
        success, resultKey = manager:closeBatchByRequest(connection, self.reference)
        changed = success
    elseif self.action == IPS_CommandEvent.ACTION_BUY_PALLETS then
        success, resultKey = manager:buyPallets(
            connection,
            self.offerKey,
            self.revision,
            self.quantity,
            self.palletToken,
            self.quotedGross
        )
        changed = success
    end

    manager:sendResult(connection, success, resultKey, false)
    if success and changed then
        manager:sendSnapshot(connection)
        manager:broadcastRefresh(connection)
    end
end
