-- Copyright © 2026 Squallqt. All rights reserved.
---SmoothList data source and delegate for production sales pages.
IPS_ListRenderer = {}
local IPS_ListRenderer_mt = Class(IPS_ListRenderer)

IPS_ListRenderer.MODE_MARKET = "market"
IPS_ListRenderer.MODE_OUTPUTS = "outputs"
IPS_ListRenderer.MODE_BATCHES = "batches"
IPS_ListRenderer.MODE_PURCHASES = "purchases"

local function populateIcon(cell, iconFilename)
    local icon = cell:getDescendantByName("cellProductIcon")
    if icon == nil then
        return
    end
    local visible = iconFilename ~= nil and iconFilename ~= ""
    if visible then
        icon:setImageFilename(iconFilename)
    end
    icon:setVisible(visible)
end

local function applyStatusColor(manager, element, colorName, selectedColorName)
    local renderer = manager.invoiceEnvironment ~= nil and manager.invoiceEnvironment.InvoicesListRenderer or nil
    local color = renderer ~= nil and renderer[colorName] or nil
    local selectedColor = renderer ~= nil and renderer[selectedColorName] or nil
    if element ~= nil and color ~= nil and selectedColor ~= nil then
        element:setTextColor(unpack(color))
        element.textSelectedColor = selectedColor
    end
end

---Creates a production sales list renderer.
-- @param string mode Row presentation mode
-- @param table controller Owning frame extension controller
-- @return table Renderer instance
function IPS_ListRenderer.new(mode, controller)
    local self = setmetatable({}, IPS_ListRenderer_mt)
    self.mode = mode
    self.controller = controller
    self.data = {}
    self.selectedRow = -1
    return self
end

---Returns the stable identity used to preserve a selected row across snapshots.
-- @param table? row Snapshot row
-- @return string|nil Stable row identity
function IPS_ListRenderer:getRowIdentity(row)
    if row == nil then
        return nil
    end
    if self.mode == IPS_ListRenderer.MODE_MARKET or self.mode == IPS_ListRenderer.MODE_OUTPUTS then
        return row.key
    end
    if self.mode == IPS_ListRenderer.MODE_BATCHES then
        return string.format("%s:%d", row.reference or "", row.fillTypeIndex or 0)
    end
    return row.reference
end

---Replaces the displayed rows and restores selection by stable identity.
-- @param table? data Snapshot rows
-- @return integer Selected row index or -1
function IPS_ListRenderer:setData(data)
    local selectedIdentity = self:getRowIdentity(self:getSelectedRow())
    self.data = data or {}
    self.selectedRow = -1
    if selectedIdentity ~= nil then
        for index, row in ipairs(self.data) do
            if self:getRowIdentity(row) == selectedIdentity then
                self.selectedRow = index
                break
            end
        end
    end
    return self.selectedRow
end

---Returns the selected snapshot row.
-- @return table|nil Selected row
function IPS_ListRenderer:getSelectedRow()
    if self.selectedRow > 0 and self.selectedRow <= #self.data then
        return self.data[self.selectedRow]
    end
    return nil
end

---Returns the number of list sections.
-- @return integer Section count
function IPS_ListRenderer:getNumberOfSections()
    return 1
end

---Returns the number of rows in a section.
-- @param table list SmoothList element
-- @param integer section Section index
-- @return integer Row count
function IPS_ListRenderer:getNumberOfItemsInSection(list, section)
    return #self.data
end

---Formats one output transport mode.
-- @param integer mode Output mode bit field
-- @return string Localized mode
function IPS_ListRenderer:formatMode(mode)
    local manager = self.controller.manager
    if mode == IPS_Manager.MODE_BULK then
        return manager:getText("ips_mode_bulk")
    elseif mode == IPS_Manager.MODE_PALLET then
        return manager:getText("ips_mode_pallets")
    elseif mode == IPS_Manager.MODE_BOTH then
        return string.format("%s / %s", manager:getText("ips_mode_bulk"), manager:getText("ips_mode_pallets"))
    end
    return "—"
end

---Formats a production catalog row.
-- @param table row Snapshot row
-- @param table cell SmoothList cell
function IPS_ListRenderer:populateCatalogCell(row, cell)
    local manager = self.controller.manager
    local statusKey = row.enabled and "ips_status_active" or "ips_status_inactive"
    local values = {
        cellSeller = row.sellerName or "",
        cellProduction = row.productionName or "",
        cellProduct = row.productName or "",
        cellMode = self:formatMode(row.mode),
        cellStock = row.mode == IPS_Manager.MODE_PALLET and "—" or g_i18n:formatVolume(math.max(row.stock or 0, 0), 0),
        cellPallets = row.mode == IPS_Manager.MODE_BULK and "—" or tostring(math.max(math.floor(row.palletCount or 0), 0)),
        cellPrice = g_i18n:formatMoney(row.price or 0, 0, true, false),
        cellStatus = manager:getText(statusKey)
    }

    for name, value in pairs(values) do
        local element = cell:getDescendantByName(name)
        if element ~= nil then
            element:setText(value)
        end
    end
    populateIcon(cell, row.iconFilename)
    local statusElement = cell:getDescendantByName("cellStatus")
    if row.enabled then
        applyStatusColor(manager, statusElement, "COLOR_PAID", "COLOR_PAID_SELECTED")
    else
        applyStatusColor(manager, statusElement, "COLOR_UNPAID", "COLOR_UNPAID_SELECTED")
    end
end

---Formats an open sales batch or purchase row.
-- @param table row Snapshot row
-- @param table cell SmoothList cell
function IPS_ListRenderer:populateBatchCell(row, cell)
    local manager = self.controller.manager
    local counterparty = self.mode == IPS_ListRenderer.MODE_PURCHASES and row.sellerName or row.buyerName
    local statusKey = row.closed == true and "ips_status_paid" or "ips_status_pending"
    local status = manager:getText(statusKey)
    local values = {
        cellCounterparty = counterparty or "",
        cellProduct = row.productName or "",
        cellVolume = g_i18n:formatVolume(math.max(row.totalLiters or 0, 0), 0),
        cellAmount = g_i18n:formatMoney(row.totalGross or 0, 0, true, false),
        cellStatus = status
    }

    for name, value in pairs(values) do
        local element = cell:getDescendantByName(name)
        if element ~= nil then
            element:setText(value)
        end
    end
    populateIcon(cell, row.iconFilename)
    local statusElement = cell:getDescendantByName("cellStatus")
    if row.closed == true then
        applyStatusColor(manager, statusElement, "COLOR_PAID", "COLOR_PAID_SELECTED")
    else
        applyStatusColor(manager, statusElement, "COLOR_PROPOSED", "COLOR_PROPOSED_SELECTED")
    end
end

---Populates one visible SmoothList cell.
-- @param table list SmoothList element
-- @param integer section Section index
-- @param integer index Row index
-- @param table cell Cell element
function IPS_ListRenderer:populateCellForItemInSection(list, section, index, cell)
    local row = self.data[index]
    if row == nil then
        return
    end

    if self.mode == IPS_ListRenderer.MODE_MARKET or self.mode == IPS_ListRenderer.MODE_OUTPUTS then
        self:populateCatalogCell(row, cell)
    else
        self:populateBatchCell(row, cell)
    end
end

---Tracks list selection and refreshes contextual buttons.
-- @param table list SmoothList element
-- @param integer section Section index
-- @param integer index Row index
function IPS_ListRenderer:onListSelectionChanged(list, section, index)
    self.selectedRow = index
    if self.controller ~= nil then
        self.controller:onSelectionChanged(self)
    end
end

---Releases references owned by the renderer.
function IPS_ListRenderer:delete()
    self.controller = nil
    self.data = nil
end
