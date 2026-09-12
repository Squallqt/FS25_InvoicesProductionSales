-- Copyright © 2026 Squallqt. All rights reserved.
---Replicates purchased pallet ownership from server to clients.
IPS_PalletOwnershipEvent = {}
local IPS_PalletOwnershipEvent_mt = Class(IPS_PalletOwnershipEvent, Event)

InitEventClass(IPS_PalletOwnershipEvent, "IPS_PalletOwnershipEvent")

function IPS_PalletOwnershipEvent.emptyNew()
    return Event.new(IPS_PalletOwnershipEvent_mt)
end

function IPS_PalletOwnershipEvent.new(vehicles, sellerFarmId, buyerFarmId)
    local self = IPS_PalletOwnershipEvent.emptyNew()
    self.vehicles = vehicles or {}
    self.sellerFarmId = sellerFarmId
    self.buyerFarmId = buyerFarmId
    return self
end

function IPS_PalletOwnershipEvent:writeStream(streamId, connection)
    streamWriteUInt16(streamId, #self.vehicles)
    for _, vehicle in ipairs(self.vehicles) do NetworkUtil.writeNodeObject(streamId, vehicle) end
    streamWriteInt32(streamId, self.sellerFarmId or 0)
    streamWriteInt32(streamId, self.buyerFarmId or 0)
end

function IPS_PalletOwnershipEvent:readStream(streamId, connection)
    if not connection:getIsServer() then return end
    self.vehicles = {}
    local count = streamReadUInt16(streamId)
    for index = 1, count do self.vehicles[index] = NetworkUtil.readNodeObject(streamId) end
    self.sellerFarmId = streamReadInt32(streamId)
    self.buyerFarmId = streamReadInt32(streamId)
    self:run(connection)
end

function IPS_PalletOwnershipEvent:run(connection)
    for _, vehicle in ipairs(self.vehicles) do
        if vehicle ~= nil then vehicle:setOwnerFarmId(self.buyerFarmId, true) end
    end
end
