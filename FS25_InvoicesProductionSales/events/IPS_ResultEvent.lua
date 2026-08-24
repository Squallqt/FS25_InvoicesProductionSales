-- Copyright © 2026 Squallqt. All rights reserved.
---Localized command result and catalog invalidation.
IPS_ResultEvent = {}
local IPS_ResultEvent_mt = Class(IPS_ResultEvent, Event)

InitEventClass(IPS_ResultEvent, "IPS_ResultEvent")

function IPS_ResultEvent.emptyNew()
    return Event.new(IPS_ResultEvent_mt)
end

function IPS_ResultEvent.new(success, key, refresh, targetFarmId)
    local self = IPS_ResultEvent.emptyNew()
    self.success = success
    self.key = key
    self.refresh = refresh
    self.targetFarmId = targetFarmId
    return self
end

function IPS_ResultEvent:writeStream(streamId, connection)
    streamWriteBool(streamId, self.success == true)
    streamWriteString(streamId, self.key or "")
    streamWriteBool(streamId, self.refresh == true)
    streamWriteInt32(streamId, self.targetFarmId or 0)
end

function IPS_ResultEvent:readStream(streamId, connection)
    if not connection:getIsServer() then return end
    self.success = streamReadBool(streamId)
    self.key = streamReadString(streamId)
    self.refresh = streamReadBool(streamId)
    self.targetFarmId = streamReadInt32(streamId)
    self:run(connection)
end

function IPS_ResultEvent:run(connection)
    local manager = g_currentMission.invoicesProductionSalesManager
    if manager ~= nil then manager:applyResult(self.success, self.key, self.refresh, self.targetFarmId) end
end
