-- Copyright © 2026 Squallqt. All rights reserved.
---Server-to-client synchronization of an already-paid Invoice receipt.
IPS_ReceiptEvent = {}
local IPS_ReceiptEvent_mt = Class(IPS_ReceiptEvent, Event)

InitEventClass(IPS_ReceiptEvent, "IPS_ReceiptEvent")

---Consumes the Invoice 1.2.0 network payload when its class is unavailable.
-- @param integer streamId Network stream identifier
local function discardInvoiceStream(streamId)
    streamReadInt32(streamId)
    streamReadInt32(streamId)
    streamReadInt32(streamId)
    streamReadInt8(streamId)
    streamReadInt32(streamId)
    streamReadInt32(streamId)
    streamReadInt8(streamId)
    streamReadInt8(streamId)
    streamReadInt8(streamId)
    streamReadInt8(streamId)
    streamReadInt16(streamId)
    streamReadInt32(streamId)
    streamReadInt32(streamId)
    local count = streamReadInt16(streamId)
    for _ = 1, count do
        streamReadInt16(streamId)
        streamReadFloat32(streamId)
        streamReadFloat32(streamId)
        streamReadInt8(streamId)
        streamReadInt16(streamId)
        streamReadFloat32(streamId)
        streamReadString(streamId)
        streamReadFloat32(streamId)
        streamReadFloat32(streamId)
        streamReadString(streamId)
        streamReadString(streamId)
        streamReadFloat32(streamId)
        streamReadInt32(streamId)
        streamReadString(streamId)
        streamReadInt16(streamId)
        streamReadFloat32(streamId)
    end
end

function IPS_ReceiptEvent.emptyNew()
    return Event.new(IPS_ReceiptEvent_mt)
end

function IPS_ReceiptEvent.new(invoice)
    local self = IPS_ReceiptEvent.emptyNew()
    self.invoice = invoice
    return self
end

function IPS_ReceiptEvent:writeStream(streamId, connection)
    self.invoice:writeStream(streamId)
end

function IPS_ReceiptEvent:readStream(streamId, connection)
    if not connection:getIsServer() then return end
    local manager = g_currentMission.invoicesProductionSalesManager
    local invoiceClass = manager ~= nil and manager.invoiceClass or nil
    if invoiceClass == nil then
        local modData = g_modManager ~= nil and g_modManager.getModByName ~= nil
            and g_modManager:getModByName("FS25_Invoices") or nil
        local environment = IPS_Manager.getInvoiceEnvironment(modData)
        invoiceClass = environment ~= nil and environment.Invoice or nil
    end
    if invoiceClass == nil or type(invoiceClass.new) ~= "function" then
        discardInvoiceStream(streamId)
        Logging.error("[InvoicesProductionSales] Receipt received without a compatible Invoice contract")
        return
    end
    self.invoice = invoiceClass.new()
    self.invoice:readStream(streamId)
    self:run(connection)
end

function IPS_ReceiptEvent:run(connection)
    local manager = g_currentMission.invoicesProductionSalesManager
    if manager == nil or manager.invoiceManager == nil then return end
    local repository = manager.invoiceManager.repository
    if repository:getById(self.invoice.id) == nil and repository:add(self.invoice) then
        manager:notifyReceiptCreated(self.invoice)
        manager.invoiceManager.service:notifyUI()
    end
end
