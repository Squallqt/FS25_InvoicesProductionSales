-- Copyright © 2026 Squallqt. All rights reserved.
---Validated request to start one paid bulk loading session.
IPS_StartLoadingEvent = {}
local IPS_StartLoadingEvent_mt = Class(IPS_StartLoadingEvent, Event)

InitEventClass(IPS_StartLoadingEvent, "IPS_StartLoadingEvent")

function IPS_StartLoadingEvent.emptyNew()
    return Event.new(IPS_StartLoadingEvent_mt)
end

function IPS_StartLoadingEvent.new(trigger, targetObject, fillUnitIndex, fillTypeIndex, offerRevision)
    local self = IPS_StartLoadingEvent.emptyNew()
    self.trigger = trigger
    self.targetObject = targetObject
    self.fillUnitIndex = fillUnitIndex
    self.fillTypeIndex = fillTypeIndex
    self.offerRevision = offerRevision
    return self
end

function IPS_StartLoadingEvent:writeStream(streamId, connection)
    NetworkUtil.writeNodeObject(streamId, self.trigger)
    NetworkUtil.writeNodeObject(streamId, self.targetObject)
    streamWriteInt16(streamId, self.fillUnitIndex or 0)
    streamWriteInt16(streamId, self.fillTypeIndex or 0)
    streamWriteInt32(streamId, self.offerRevision or 0)
end

function IPS_StartLoadingEvent:readStream(streamId, connection)
    self.trigger = NetworkUtil.readNodeObject(streamId)
    self.targetObject = NetworkUtil.readNodeObject(streamId)
    self.fillUnitIndex = streamReadInt16(streamId)
    self.fillTypeIndex = streamReadInt16(streamId)
    self.offerRevision = streamReadInt32(streamId)
    self:run(connection)
end

function IPS_StartLoadingEvent:run(connection)
    if connection:getIsServer() then return end
    local manager = g_currentMission.invoicesProductionSalesManager
    if manager == nil then return end
    local success, resultKey = manager:createLoadingSession(
        self.trigger,
        self.targetObject,
        self.fillUnitIndex,
        self.fillTypeIndex,
        self.offerRevision,
        connection
    )
    if success then
        self.trigger:setIsLoading(true, self.targetObject, self.fillUnitIndex, self.fillTypeIndex)
        if not self.trigger.isLoading then
            manager:removeSession(self.trigger)
            success = false
            resultKey = "ips_error_transactionFailed"
        end
    end
    manager:sendResult(connection, success, resultKey, success)
end
