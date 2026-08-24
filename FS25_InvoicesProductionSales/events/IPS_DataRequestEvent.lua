-- Copyright © 2026 Squallqt. All rights reserved.
---Client request for a personalized production sales snapshot.
IPS_DataRequestEvent = {}
local IPS_DataRequestEvent_mt = Class(IPS_DataRequestEvent, Event)

InitEventClass(IPS_DataRequestEvent, "IPS_DataRequestEvent")

function IPS_DataRequestEvent.emptyNew()
    return Event.new(IPS_DataRequestEvent_mt)
end

function IPS_DataRequestEvent.new()
    return IPS_DataRequestEvent.emptyNew()
end

function IPS_DataRequestEvent:writeStream(streamId, connection)
end

function IPS_DataRequestEvent:readStream(streamId, connection)
    self:run(connection)
end

function IPS_DataRequestEvent:run(connection)
    if connection:getIsServer() then return end
    local manager = g_currentMission.invoicesProductionSalesManager
    if manager ~= nil then manager:sendRequestedSnapshot(connection) end
end
