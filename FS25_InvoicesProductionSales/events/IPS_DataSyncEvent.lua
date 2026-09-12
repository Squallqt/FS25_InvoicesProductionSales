-- Copyright © 2026 Squallqt. All rights reserved.
---Server snapshot for the production sales interface.
IPS_DataSyncEvent = {}
local IPS_DataSyncEvent_mt = Class(IPS_DataSyncEvent, Event)

InitEventClass(IPS_DataSyncEvent, "IPS_DataSyncEvent")

local function writeCatalogRow(streamId, row)
    streamWriteString(streamId, row.key or "")
    NetworkUtil.writeNodeObject(streamId, row.productionPoint)
    streamWriteString(streamId, row.productionUniqueId or "")
    streamWriteInt16(streamId, row.fillTypeIndex or 0)
    streamWriteInt32(streamId, row.sellerFarmId or 0)
    streamWriteString(streamId, row.sellerName or "")
    streamWriteString(streamId, row.productionName or "")
    streamWriteString(streamId, row.productName or "")
    streamWriteString(streamId, NetworkUtil.convertToNetworkFilename(row.iconFilename or ""))
    streamWriteUInt8(streamId, row.mode or 0)
    streamWriteBool(streamId, row.stored == true)
    streamWriteFloat32(streamId, row.stock or 0)
    streamWriteFloat32(streamId, row.offerableLiters or 0)
    streamWriteFloat32(streamId, row.listedLiters or 0)
    streamWriteFloat32(streamId, row.remainingLiters or 0)
    streamWriteUInt16(streamId, row.listedPallets or 0)
    streamWriteUInt16(streamId, row.remainingPallets or 0)
    streamWriteUInt16(streamId, row.palletCount or 0)
    streamWriteString(streamId, row.palletToken or "")
    local palletQuotes = row.palletQuotes or {}
    local quoteCount = math.min(#palletQuotes, 65535)
    streamWriteUInt16(streamId, quoteCount)
    for index = 1, quoteCount do
        local quote = palletQuotes[index] or {}
        streamWriteFloat32(streamId, quote.liters or 0)
        streamWriteInt32(streamId, quote.gross or 0)
    end
    streamWriteInt32(streamId, row.price or 0)
    streamWriteBool(streamId, row.enabled == true)
    streamWriteInt32(streamId, row.revision or 0)
end

local function readCatalogRow(streamId)
    local row = {
        key = streamReadString(streamId),
        productionPoint = NetworkUtil.readNodeObject(streamId),
        productionUniqueId = streamReadString(streamId),
        fillTypeIndex = streamReadInt16(streamId),
        sellerFarmId = streamReadInt32(streamId),
        sellerName = streamReadString(streamId),
        productionName = streamReadString(streamId),
        productName = streamReadString(streamId),
        iconFilename = NetworkUtil.convertFromNetworkFilename(streamReadString(streamId)),
        mode = streamReadUInt8(streamId),
        stored = streamReadBool(streamId),
        stock = streamReadFloat32(streamId),
        offerableLiters = streamReadFloat32(streamId),
        listedLiters = streamReadFloat32(streamId),
        remainingLiters = streamReadFloat32(streamId),
        listedPallets = streamReadUInt16(streamId),
        remainingPallets = streamReadUInt16(streamId),
        palletCount = streamReadUInt16(streamId),
        palletToken = streamReadString(streamId)
    }
    row.palletQuotes = {}
    local quoteCount = streamReadUInt16(streamId)
    for index = 1, quoteCount do
        row.palletQuotes[index] = {
            liters = streamReadFloat32(streamId),
            gross = streamReadInt32(streamId)
        }
    end
    row.price = streamReadInt32(streamId)
    row.enabled = streamReadBool(streamId)
    row.revision = streamReadInt32(streamId)
    return row
end

local function writeBatchRow(streamId, row)
    streamWriteString(streamId, row.reference or "")
    streamWriteInt32(streamId, row.sellerFarmId or 0)
    streamWriteInt32(streamId, row.buyerFarmId or 0)
    streamWriteString(streamId, row.sellerName or "")
    streamWriteString(streamId, row.buyerName or "")
    streamWriteInt16(streamId, row.fillTypeIndex or 0)
    streamWriteString(streamId, row.productName or "")
    streamWriteString(streamId, NetworkUtil.convertToNetworkFilename(row.iconFilename or ""))
    streamWriteInt16(streamId, row.year or 0)
    streamWriteUInt8(streamId, row.period or 0)
    streamWriteFloat32(streamId, row.totalLiters or 0)
    streamWriteInt32(streamId, row.totalGross or 0)
    streamWriteInt32(streamId, row.totalNet or 0)
    streamWriteInt32(streamId, row.totalVat or 0)
    streamWriteInt32(streamId, row.batchTotalGross or row.totalGross or 0)
    streamWriteBool(streamId, row.closed == true)
end

local function readBatchRow(streamId)
    return {
        reference = streamReadString(streamId),
        sellerFarmId = streamReadInt32(streamId),
        buyerFarmId = streamReadInt32(streamId),
        sellerName = streamReadString(streamId),
        buyerName = streamReadString(streamId),
        fillTypeIndex = streamReadInt16(streamId),
        productName = streamReadString(streamId),
        iconFilename = NetworkUtil.convertFromNetworkFilename(streamReadString(streamId)),
        year = streamReadInt16(streamId),
        period = streamReadUInt8(streamId),
        totalLiters = streamReadFloat32(streamId),
        totalGross = streamReadInt32(streamId),
        totalNet = streamReadInt32(streamId),
        totalVat = streamReadInt32(streamId),
        batchTotalGross = streamReadInt32(streamId),
        closed = streamReadBool(streamId)
    }
end

local function writeRows(streamId, rows, writer)
    streamWriteInt16(streamId, math.min(#(rows or {}), 32767))
    for index = 1, math.min(#(rows or {}), 32767) do writer(streamId, rows[index]) end
end

local function readRows(streamId, reader)
    local rows = {}
    local count = streamReadInt16(streamId)
    for index = 1, count do rows[index] = reader(streamId) end
    return rows
end

function IPS_DataSyncEvent.emptyNew()
    return Event.new(IPS_DataSyncEvent_mt)
end

function IPS_DataSyncEvent.new(snapshot)
    local self = IPS_DataSyncEvent.emptyNew()
    self.snapshot = snapshot
    return self
end

function IPS_DataSyncEvent:writeStream(streamId, connection)
    local snapshot = self.snapshot or {compatible = false}
    streamWriteBool(streamId, snapshot.compatible == true)
    writeRows(streamId, snapshot.market or {}, writeCatalogRow)
    writeRows(streamId, snapshot.outputs or {}, writeCatalogRow)
    writeRows(streamId, snapshot.batches or {}, writeBatchRow)
    writeRows(streamId, snapshot.purchases or {}, writeBatchRow)
end

function IPS_DataSyncEvent:readStream(streamId, connection)
    if not connection:getIsServer() then return end
    self.snapshot = {
        compatible = streamReadBool(streamId),
        market = readRows(streamId, readCatalogRow),
        outputs = readRows(streamId, readCatalogRow),
        batches = readRows(streamId, readBatchRow),
        purchases = readRows(streamId, readBatchRow)
    }
    self:run(connection)
end

function IPS_DataSyncEvent:run(connection)
    local manager = g_currentMission.invoicesProductionSalesManager
    if manager ~= nil then manager:applySnapshot(self.snapshot) end
end
