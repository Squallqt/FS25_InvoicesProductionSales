-- Copyright © 2026 Squallqt. All rights reserved.
---Runtime-only extension of the existing InvoicesFrame instance.
IPS_FrameExtension = {
    controller = nil,
    frame = nil,
    manager = nil,
    retryTimer = 0,
    isUpdateable = false,
    failed = false
}

local Controller = {}
local Controller_mt = Class(Controller)

Controller.VIEW_MARKET = 1
Controller.VIEW_OFFERS = 2
Controller.VIEW_BATCHES = 3
Controller.REFRESH_INTERVAL = 5000

local CONTROL_IDS = {
    "ipsSubCategoryTab",
    "ipsSubCategoryPage",
    "ipsPrimaryViewBox",
    "ipsPrimaryViewPaging",
    "ipsMarketTab",
    "ipsOffersTab",
    "ipsBatchesTab",
    "ipsMarketContent",
    "ipsMarketList",
    "ipsMarketEmpty",
    "ipsPurchasesList",
    "ipsOffersContent",
    "ipsOutputsList",
    "ipsOutputsEmpty",
    "ipsBatchesContent",
    "ipsBatchesList",
    "ipsBatchesEmpty",
    "ipsSliderBox",
    "ipsSlider"
}

local CALLBACK_FIELDS = {
    "ipsProductionSalesController",
    "ipsOnClickSalesTopTab",
    "ipsOnInternalViewPaging",
    "ipsOnClickMarketView",
    "ipsOnClickOffersView",
    "ipsOnClickBatchesView"
}

local REQUIRED_PROFILES = {
    "fs25_subCategorySelectorTabbedBox",
    "fs25_subCategorySelectorTabbed",
    "fs25_subCategorySelectorTabbedTab",
    "fs25_subCategorySelectorTabbedTabBg",
    "fs25_subCategorySelectorTabbedContainer",
    "fs25_lineSeparatorTop",
    "fs25_lineSeparatorTopHighlighted",
    "fs25_statisticsHeaderBox",
    "invSliderDockedBg",
    "invSliderDockedBox",
    "invSliderDocked",
    "invColumnHeaderBtn",
    "ipsSectionHeader",
    "invListContentArea",
    "invInvoiceList",
    "invInvoiceListItem",
    "invListItemGradient",
    "invRowCellLeft",
    "invRowCellDim",
    "invRowCellCenter",
    "invRowCellRight",
    "invEmptyStateText",
    "emptyPanel",
    "ftdCellIcon"
}

local function getInvoicesFrame(manager)
    local invoiceRoot = manager ~= nil and manager.invoiceRoot or nil
    if invoiceRoot ~= nil and invoiceRoot.frame ~= nil then
        return invoiceRoot.frame
    end

    local inGameMenu = g_inGameMenu
    if inGameMenu == nil and g_gui ~= nil and g_gui.screenControllers ~= nil and InGameMenu ~= nil then
        inGameMenu = g_gui.screenControllers[InGameMenu]
    end
    return inGameMenu ~= nil and inGameMenu.pageInvoices or nil
end

local function showInfoText(text)
    if text ~= nil and InfoDialog ~= nil and type(InfoDialog.show) == "function" then
        InfoDialog.show(text)
    end
end

local function showInfo(manager, key)
    if manager ~= nil then showInfoText(manager:getText(key)) end
end

local function validateFrameContract(frame)
    if frame == nil then
        return false, "missing frame"
    end
    if frame.name ~= "InvoicesFrame" then
        return false, "unexpected frame name"
    end
    if type(frame.controlIDs) ~= "table" or type(frame.exposeControlsAsFields) ~= "function" then
        return false, "missing frame control contract"
    end
    if type(frame.subCategoryTabs) ~= "table" or #frame.subCategoryTabs ~= 2 then
        return false, "unexpected tab contract"
    end
    if type(frame.subCategoryPages) ~= "table" or #frame.subCategoryPages ~= 2 then
        return false, "unexpected page contract"
    end
    if frame.subCategoryBox == nil
        or type(frame.subCategoryBox.elements) ~= "table"
        or type(frame.subCategoryBox.invalidateLayout) ~= "function" then
        return false, "missing tab layout"
    end
    if frame.subCategoryPages[1] == nil or frame.subCategoryPages[1].parent == nil
        or frame.subCategoryPages[2] == nil
        or frame.subCategoryPages[2].parent ~= frame.subCategoryPages[1].parent then
        return false, "unexpected page parent"
    end
    if type(frame.subCategoryPages[1].parent.elements) ~= "table" then
        return false, "missing page element contract"
    end
    if frame.subCategoryPaging == nil
        or type(frame.subCategoryPaging.getState) ~= "function"
        or type(frame.subCategoryPaging.setState) ~= "function"
        or type(frame.subCategoryPaging.setTexts) ~= "function"
        or type(frame.subCategoryPaging.onClickCallback) ~= "function" then
        return false, "missing paging contract"
    end
    if type(frame.menuButtonInfo) ~= "table"
        or frame.btnBack == nil
        or frame.btnNextPage == nil
        or frame.btnPrevPage == nil
        or type(frame.setMenuButtonInfoDirty) ~= "function" then
        return false, "missing menu button contract"
    end
    if type(frame.updateSubCategoryPages) ~= "function"
        or type(frame.onFrameOpen) ~= "function"
        or type(frame.onFrameClose) ~= "function"
        or type(frame.update) ~= "function"
        or type(frame.onClickDetails) ~= "function"
        or type(frame.delete) ~= "function" then
        return false, "missing lifecycle contract"
    end
    if g_gui == nil
        or type(g_gui.loadGuiRec) ~= "function"
        or type(g_gui.profiles) ~= "table" then
        return false, "missing GUI loading contract"
    end
    if FocusManager == nil
        or type(FocusManager.setGui) ~= "function"
        or type(FocusManager.linkElements) ~= "function" then
        return false, "missing focus contract"
    end
    for _, profileName in ipairs(REQUIRED_PROFILES) do
        if g_gui.profiles[profileName] == nil then
            return false, string.format("missing GUI profile '%s'", profileName)
        end
    end
    if TextInputDialog == nil or type(TextInputDialog.show) ~= "function"
        or YesNoDialog == nil or type(YesNoDialog.show) ~= "function" then
        return false, "missing dialog contract"
    end
    if frame.ipsExtensionInstalled == true then
        return false, "extension already installed"
    end
    for _, fieldName in ipairs(CONTROL_IDS) do
        if frame[fieldName] ~= nil or frame.controlIDs[fieldName] ~= nil then
            return false, string.format("field collision '%s'", fieldName)
        end
    end
    for _, fieldName in ipairs(CALLBACK_FIELDS) do
        if frame[fieldName] ~= nil then
            return false, string.format("callback collision '%s'", fieldName)
        end
    end
    return true, nil
end

local function removeInjectedControls(frame, tabParent, tabStart, pageParent, pageStart)
    if tabParent ~= nil then
        for index = #tabParent.elements, tabStart + 1, -1 do
            tabParent.elements[index]:delete()
        end
    end
    if pageParent ~= nil then
        for index = #pageParent.elements, pageStart + 1, -1 do
            pageParent.elements[index]:delete()
        end
    end
    if frame ~= nil then
        for _, id in ipairs(CONTROL_IDS) do
            frame[id] = nil
            if frame.controlIDs ~= nil then
                frame.controlIDs[id] = nil
            end
        end
    end
end

---Creates an instance-bound frame controller.
-- @param table frame Resolved InvoicesFrame instance
-- @param table manager Production sales manager
-- @return table Controller
function Controller.new(frame, manager)
    local self = setmetatable({}, Controller_mt)
    self.frame = frame
    self.manager = manager
    self.tabIndex = 3
    self.currentView = Controller.VIEW_MARKET
    self.refreshTimer = 0
    self.originals = {}
    self.wrappers = {}
    self.renderers = {}
    self.detached = false
    return self
end

---Registers namespaced callbacks required while loading the extension XML.
function Controller:installCallbackAliases()
    local frame = self.frame
    frame.ipsProductionSalesController = self
    frame.ipsOnClickSalesTopTab = function(target)
        target.ipsProductionSalesController:onClickSalesTopTab()
    end
    frame.ipsOnInternalViewPaging = function(target)
        target.ipsProductionSalesController:onInternalViewPaging()
    end
    frame.ipsOnClickMarketView = function(target)
        target.ipsProductionSalesController:selectView(Controller.VIEW_MARKET)
    end
    frame.ipsOnClickOffersView = function(target)
        target.ipsProductionSalesController:selectView(Controller.VIEW_OFFERS)
    end
    frame.ipsOnClickBatchesView = function(target)
        target.ipsProductionSalesController:selectView(Controller.VIEW_BATCHES)
    end
end

---Initializes loaded controls, renderers and contextual buttons.
function Controller:initializeControls()
    local frame = self.frame
    local tab = frame.ipsSubCategoryTab
    local background = tab ~= nil and tab:getDescendantByName("background") or nil
    if tab == nil or background == nil then
        error("production sales tab controls are incomplete")
    end

    background.getIsSelected = function()
        return frame.subCategoryPaging:getState() == self.tabIndex
    end
    tab.getIsSelected = function()
        return frame.subCategoryPaging:getState() == self.tabIndex
    end

    local function bindInternalTab(button, isSelected)
        local tabBackground = button ~= nil and button:getDescendantByName("background") or nil
        if button == nil or tabBackground == nil then
            error("production sales internal tab controls are incomplete")
        end
        button.getIsSelected = isSelected
        tabBackground.getIsSelected = isSelected
    end
    bindInternalTab(frame.ipsMarketTab, function() return self.currentView == Controller.VIEW_MARKET end)
    bindInternalTab(frame.ipsOffersTab, function() return self.currentView == Controller.VIEW_OFFERS end)
    bindInternalTab(frame.ipsBatchesTab, function() return self.currentView == Controller.VIEW_BATCHES end)

    local viewPaging = frame.ipsPrimaryViewPaging
    if viewPaging == nil then
        error("production sales internal paging control is incomplete")
    end
    frame.ipsPrimaryViewBox:invalidateLayout()
    viewPaging:setTexts({"1", "2", "3"})
    if frame.ipsPrimaryViewBox.maxFlowSize ~= nil and viewPaging.setSize ~= nil then
        viewPaging:setSize(frame.ipsPrimaryViewBox.maxFlowSize + 140 * g_pixelSizeScaledX)
    end
    viewPaging:setState(self.currentView, false)

    local priceHeaderText = string.format(
        "%s (%s)",
        self.manager:getText("ips_col_price"),
        self.manager:getText("ips_label_taxIncluded")
    )
    for _, content in ipairs({frame.ipsMarketContent, frame.ipsOffersContent}) do
        local priceHeader = content:getDescendantByName(
            content == frame.ipsMarketContent and "ipsMarketPriceHeader" or "ipsOffersPriceHeader"
        )
        if priceHeader ~= nil then priceHeader:setText(priceHeaderText) end
    end

    self.renderers.market = IPS_ListRenderer.new(IPS_ListRenderer.MODE_MARKET, self)
    self.renderers.outputs = IPS_ListRenderer.new(IPS_ListRenderer.MODE_OUTPUTS, self)
    self.renderers.batches = IPS_ListRenderer.new(IPS_ListRenderer.MODE_BATCHES, self)
    self.renderers.purchases = IPS_ListRenderer.new(IPS_ListRenderer.MODE_PURCHASES, self)

    frame.ipsMarketList:setDataSource(self.renderers.market)
    frame.ipsMarketList:setDelegate(self.renderers.market)
    frame.ipsOutputsList:setDataSource(self.renderers.outputs)
    frame.ipsOutputsList:setDelegate(self.renderers.outputs)
    frame.ipsBatchesList:setDataSource(self.renderers.batches)
    frame.ipsBatchesList:setDelegate(self.renderers.batches)
    frame.ipsPurchasesList:setDataSource(self.renderers.purchases)
    frame.ipsPurchasesList:setDelegate(self.renderers.purchases)

    self.btnRefresh = {
        text = self.manager:getText("ips_btn_refresh"),
        inputAction = InputAction.MENU_EXTRA_2,
        callback = function() self:onClickRefresh() end
    }
    self.btnBuyPallets = {
        text = self.manager:getText("ips_btn_buyPallets"),
        inputAction = InputAction.MENU_ACCEPT,
        disabled = true,
        callback = function() self:onClickBuyPallets() end
    }
    self.btnToggleOffer = {
        text = self.manager:getText("ips_btn_activate"),
        inputAction = InputAction.MENU_ACCEPT,
        disabled = true,
        callback = function() self:onClickToggleOffer() end
    }
    self.btnEditPrice = {
        text = self.manager:getText("ips_btn_editPrice"),
        inputAction = InputAction.MENU_EXTRA_1,
        disabled = true,
        callback = function() self:onClickEditPrice() end
    }
    self.btnCloseBatch = {
        text = self.manager:getText("ips_btn_closeBatch"),
        inputAction = InputAction.MENU_ACCEPT,
        disabled = true,
        callback = function() self:onClickCloseBatch() end
    }

    self:showView(Controller.VIEW_MARKET)
    self:applySnapshot()
end

---Adds the third tab to the arrays used by InvoicesFrame.
function Controller:registerTabAndPage()
    local frame = self.frame
    table.insert(frame.subCategoryTabs, frame.ipsSubCategoryTab)
    table.insert(frame.subCategoryPages, frame.ipsSubCategoryPage)
    frame.ipsSubCategoryPage:setVisible(false)
    frame.ipsSubCategoryTab:setVisible(true)

    local texts = {}
    for index, tab in ipairs(frame.subCategoryTabs) do
        tab:setVisible(true)
        texts[index] = tostring(index)
    end
    frame.subCategoryBox:invalidateLayout()
    frame.subCategoryPaging:setTexts(texts)
    if frame.subCategoryBox.maxFlowSize ~= nil and frame.subCategoryPaging.setSize ~= nil then
        frame.subCategoryPaging:setSize(frame.subCategoryBox.maxFlowSize + 140 * g_pixelSizeScaledX)
    end
end

---Installs lifecycle wrappers only on the resolved frame instance.
function Controller:installInstanceWrappers()
    local frame = self.frame
    self.originals.updateSubCategoryPages = frame.updateSubCategoryPages
    self.originals.pagingCallback = frame.subCategoryPaging.onClickCallback
    self.originals.onFrameOpen = frame.onFrameOpen
    self.originals.onFrameClose = frame.onFrameClose
    self.originals.update = frame.update
    self.originals.onClickDetails = frame.onClickDetails
    self.originals.delete = frame.delete

    self.wrappers.updateSubCategoryPages = function(target, ...)
        local state = target.subCategoryPaging:getState()
        if state == self.tabIndex then
            target.currentTab = state
            for index, page in pairs(target.subCategoryPages) do
                page:setVisible(index == state)
            end
            if type(target.updateSliderVisibility) == "function" then
                target:updateSliderVisibility()
            end
            self:onTopTabActivated()
            target:setMenuButtonInfoDirty()
            return
        end
        self:onTopTabDeactivated()
        return self.originals.updateSubCategoryPages(target, ...)
    end
    frame.updateSubCategoryPages = self.wrappers.updateSubCategoryPages
    frame.subCategoryPaging.onClickCallback = self.wrappers.updateSubCategoryPages

    self.wrappers.onFrameOpen = function(target, ...)
        local result = self.originals.onFrameOpen(target, ...)
        self:onFrameOpen()
        return result
    end
    frame.onFrameOpen = self.wrappers.onFrameOpen

    self.wrappers.onFrameClose = function(target, ...)
        self:onFrameClose()
        return self.originals.onFrameClose(target, ...)
    end
    frame.onFrameClose = self.wrappers.onFrameClose

    self.wrappers.update = function(target, dt, ...)
        local result = self.originals.update(target, dt, ...)
        self:update(dt)
        return result
    end
    frame.update = self.wrappers.update

    self.wrappers.onClickDetails = function(target, ...)
        local invoice = target.selectedInvoice
        local reference = self.manager:getReceiptReference(invoice)
        local markerItem = nil
        local marker = reference ~= nil and string.format("[IPS:%s]", reference) or nil
        if marker ~= nil then
            for _, item in ipairs(invoice.lineItems or {}) do
                if item.note == marker then
                    markerItem = item
                    break
                end
            end
        end
        if markerItem == nil then
            return self.originals.onClickDetails(target, ...)
        end

        markerItem.note = self.manager:getText("ips_receipt_noteAutomatic")
        local success, result = pcall(self.originals.onClickDetails, target, ...)
        markerItem.note = marker
        if not success then
            error(result)
        end
        return result
    end
    frame.onClickDetails = self.wrappers.onClickDetails

    self.wrappers.delete = function(target, ...)
        self:detach(false)
        return self.originals.delete(target, ...)
    end
    frame.delete = self.wrappers.delete
end

---Returns whether the extension page is currently active.
-- @return boolean True while visible
function Controller:getIsPageVisible()
    return self.frame ~= nil
        and self.frame.currentTab == self.tabIndex
        and self.frame.ipsSubCategoryPage ~= nil
        and self.frame.ipsSubCategoryPage:getIsVisible()
end

---Requests fresh data when the Invoice frame opens.
function Controller:onFrameOpen()
    self.refreshTimer = 0
    self.manager:requestSnapshot()
end

---Stops the visible-page refresh timer.
function Controller:onFrameClose()
    self.refreshTimer = 0
end

---Returns the list controlled by the shared docked Invoice slider.
-- @return table Active SmoothList
function Controller:getActiveSliderList()
    local frame = self.frame
    if self.currentView == Controller.VIEW_OFFERS then
        return frame.ipsOutputsList
    elseif self.currentView == Controller.VIEW_BATCHES then
        return frame.ipsBatchesList
    end

    local focused = FocusManager.currentFocusData ~= nil and FocusManager:getFocusedElement() or nil
    if focused == frame.ipsMarketList or focused == frame.ipsPurchasesList then
        self.marketSliderList = focused
    end
    return self.marketSliderList or frame.ipsMarketList
end

---Binds the shared docked Invoice slider to the active list.
function Controller:updateSliderBinding()
    local slider = self.frame ~= nil and self.frame.ipsSlider or nil
    local list = self.frame ~= nil and self:getActiveSliderList() or nil
    if slider ~= nil and list ~= nil and slider.dataElement ~= list then
        slider:setDataElement(list)
    end
end

---Shows the extension slider only while its Invoice tab is active.
function Controller:updateSliderVisibility()
    local sliderBox = self.frame ~= nil and self.frame.ipsSliderBox or nil
    if sliderBox ~= nil then
        sliderBox:setVisible(self:getIsPageVisible())
    end
end

---Pins the extension slider to the same screen edge as Invoice sliders.
function Controller:updateScreenEdgeSlider()
    local frame = self.frame
    local sliderBox = frame ~= nil and frame.ipsSliderBox or nil
    if sliderBox == nil
        or sliderBox.absPosition == nil
        or sliderBox.absSize == nil
        or sliderBox.absSize[1] == nil then
        return
    end

    sliderBox:updateAbsolutePosition()
    local marginX = tonumber(frame.SCREEN_EDGE_SLIDER_MARGIN_X) or 0
    local offsetY = tonumber(frame.NATIVE_DOCKED_SLIDER_OFFSET_Y) or 0
    local x = 1 - sliderBox.absSize[1] - marginX
    local y = sliderBox.absPosition[2] + offsetY * (g_pixelSizeScaledY or 0)
    sliderBox:setAbsolutePosition(x, y)
    for _, child in ipairs(sliderBox.elements or {}) do
        child:updateAbsolutePosition()
    end
end

---Requests a snapshot every five seconds while the extension page is visible.
-- @param number dt Delta time in milliseconds
function Controller:update(dt)
    if not self:getIsPageVisible() then
        self.refreshTimer = 0
        self:updateSliderVisibility()
        return
    end
    self:updateSliderBinding()
    self:updateSliderVisibility()
    self:updateScreenEdgeSlider()
    self.refreshTimer = self.refreshTimer + (dt or 0)
    if self.refreshTimer >= Controller.REFRESH_INTERVAL then
        self.refreshTimer = 0
        self.manager:requestSnapshot()
    end
end

---Activates the production sales page.
function Controller:onTopTabActivated()
    self.refreshTimer = 0
    self.frame.ipsSubCategoryPage:setVisible(true)
    if not self.outerPagingFocusLinked then
        self.originals.outerPagingBottomFocus = self.frame.subCategoryPaging.focusChangeData[FocusManager.BOTTOM]
        self.outerPagingFocusLinked = true
    end
    FocusManager:linkElements(self.frame.subCategoryPaging, FocusManager.BOTTOM, self.frame.ipsPrimaryViewPaging)
    FocusManager:linkElements(self.frame.ipsPrimaryViewPaging, FocusManager.TOP, self.frame.subCategoryPaging)
    self:showView(self.currentView)
    self.manager:requestSnapshot()
end

---Deactivates the production sales page.
function Controller:onTopTabDeactivated()
    self.refreshTimer = 0
    if self.outerPagingFocusLinked then
        self.frame.subCategoryPaging.focusChangeData[FocusManager.BOTTOM] = self.originals.outerPagingBottomFocus
        self.outerPagingFocusLinked = false
    end
    if self.frame ~= nil and self.frame.ipsSubCategoryPage ~= nil then
        self.frame.ipsSubCategoryPage:setVisible(false)
    end
    self:updateSliderVisibility()
end

---Selects the third Invoice subcategory.
function Controller:onClickSalesTopTab()
    self.frame.subCategoryPaging:setState(self.tabIndex, true)
end

---Selects an internal production sales view through the native paging control.
-- @param integer view Internal view identifier
function Controller:selectView(view)
    self.frame.ipsPrimaryViewPaging:setState(view, true)
end

---Applies the view selected by the native paging control.
function Controller:onInternalViewPaging()
    self:showView(self.frame.ipsPrimaryViewPaging:getState())
end

---Links controller focus to the lists currently containing rows.
function Controller:updateFocusNavigation()
    local frame = self.frame
    local paging = frame ~= nil and frame.ipsPrimaryViewPaging or nil
    if paging == nil then
        return
    end

    local activeList = nil
    if self.currentView == Controller.VIEW_MARKET then
        local marketList = frame.ipsMarketList
        local purchasesList = frame.ipsPurchasesList
        local marketAvailable = marketList:canReceiveFocus()
        local purchasesAvailable = purchasesList:canReceiveFocus()
        activeList = marketAvailable and marketList or (purchasesAvailable and purchasesList or nil)
        FocusManager:linkElements(marketList, FocusManager.TOP, paging)
        FocusManager:linkElements(marketList, FocusManager.BOTTOM, purchasesAvailable and purchasesList or nil)
        FocusManager:linkElements(purchasesList, FocusManager.TOP, marketAvailable and marketList or paging)
    elseif self.currentView == Controller.VIEW_OFFERS then
        activeList = frame.ipsOutputsList:canReceiveFocus() and frame.ipsOutputsList or nil
        FocusManager:linkElements(frame.ipsOutputsList, FocusManager.TOP, paging)
    else
        activeList = frame.ipsBatchesList:canReceiveFocus() and frame.ipsBatchesList or nil
        FocusManager:linkElements(frame.ipsBatchesList, FocusManager.TOP, paging)
    end

    FocusManager:linkElements(paging, FocusManager.BOTTOM, activeList)
    local focused = FocusManager.currentFocusData ~= nil and FocusManager:getFocusedElement() or nil
    if self:getIsPageVisible()
        and (focused == frame.ipsMarketList
            or focused == frame.ipsPurchasesList
            or focused == frame.ipsOutputsList
            or focused == frame.ipsBatchesList)
        and not focused:canReceiveFocus() then
        FocusManager:setFocus(paging)
    end
end

---Shows one internal page and updates contextual actions.
-- @param integer view Internal view identifier
function Controller:showView(view)
    self.currentView = view
    local isMarket = view == Controller.VIEW_MARKET
    local isOffers = view == Controller.VIEW_OFFERS
    local isBatches = view == Controller.VIEW_BATCHES

    self.frame.ipsMarketContent:setVisible(isMarket)
    self.frame.ipsOffersContent:setVisible(isOffers)
    self.frame.ipsBatchesContent:setVisible(isBatches)
    if self.frame.ipsPrimaryViewPaging:getState() ~= view then
        self.frame.ipsPrimaryViewPaging:setState(view, false)
    end
    self:updateFocusNavigation()
    self:updateSliderBinding()
    self:updateSliderVisibility()
    self:updateScreenEdgeSlider()
    self:updateButtonStates()
end

---Updates selection-dependent actions.
-- @param table renderer Renderer whose selection changed
function Controller:onSelectionChanged(renderer)
    self:updateButtonStates()
end

---Returns whether the local player can manage the current farm.
-- @return boolean True when farm manager permission is available
function Controller:getHasManagerPermission()
    local invoiceManager = self.manager.invoiceManager
    if invoiceManager ~= nil and type(invoiceManager.getHasFarmManagerPermission) == "function" then
        return invoiceManager:getHasFarmManagerPermission()
    end
    return g_currentMission ~= nil
        and g_currentMission.getHasPlayerPermission ~= nil
        and g_currentMission:getHasPlayerPermission("farmManager")
end

---Returns whether a catalog mode supports pallets.
-- @param integer mode Catalog mode
-- @return boolean True when pallet sales are supported
function Controller:getModeHasPallets(mode)
    return mode == IPS_Manager.MODE_PALLET or mode == IPS_Manager.MODE_BOTH
end

---Returns the server-authoritative maximum quantity for a new offer.
-- @param table row Output catalog row
-- @return integer Maximum whole liters or full pallets
function Controller:getOfferMaximum(row)
    if row ~= nil and row.mode == IPS_Manager.MODE_PALLET then
        return math.min(math.floor(math.max(row.palletCount or 0, 0)), IPS_Manager.MAX_PALLET_COUNT)
    end
    return math.floor(math.max(row ~= nil and (row.offerableLiters or row.stock) or 0, 0))
end

---Rebuilds the lower menu actions for the active internal view.
function Controller:updateButtonStates()
    local frame = self.frame
    if frame == nil or frame.menuButtonInfo == nil then
        return
    end

    local snapshot = self.manager.snapshot or {}
    local available = self.manager.integrationAvailable == true and snapshot.compatible == true
    self.btnRefresh.disabled = self.manager.integrationAvailable ~= true

    if self.currentView == Controller.VIEW_MARKET then
        local row = self.renderers.market:getSelectedRow()
        local localFarmId = g_localPlayer ~= nil and g_localPlayer.farmId or -1
        local canBuy = localFarmId > 0 and localFarmId ~= FarmManager.SPECTATOR_FARM_ID
        local quoteCount = row ~= nil and #(row.palletQuotes or {}) or 0
        self.btnBuyPallets.disabled = not available
            or not canBuy
            or row == nil
            or not self:getModeHasPallets(row.mode)
            or (row.palletCount or 0) < 1
            or quoteCount < 1
            or row.palletToken == nil
            or row.palletToken == ""
        frame.menuButtonInfo[self.tabIndex] = {
            frame.btnBack, frame.btnNextPage, frame.btnPrevPage, self.btnRefresh, self.btnBuyPallets
        }
    elseif self.currentView == Controller.VIEW_OFFERS then
        local row = self.renderers.outputs:getSelectedRow()
        local canManage = available and self:getHasManagerPermission() and row ~= nil
        self.btnToggleOffer.text = self.manager:getText(row ~= nil and row.enabled and "ips_btn_deactivate" or "ips_btn_activate")
        self.btnToggleOffer.disabled = not canManage
            or (row.enabled ~= true and row.mode == IPS_Manager.MODE_NONE)
        self.btnEditPrice.disabled = not canManage or row.enabled ~= true
        frame.menuButtonInfo[self.tabIndex] = {
            frame.btnBack, frame.btnNextPage, frame.btnPrevPage, self.btnRefresh, self.btnToggleOffer, self.btnEditPrice
        }
    else
        local row = self.renderers.batches:getSelectedRow()
        self.btnCloseBatch.disabled = not available or not self:getHasManagerPermission() or row == nil
        frame.menuButtonInfo[self.tabIndex] = {
            frame.btnBack, frame.btnNextPage, frame.btnPrevPage, self.btnRefresh, self.btnCloseBatch
        }
    end
    frame:setMenuButtonInfoDirty()
end

---Loads the latest manager snapshot into all four lists.
function Controller:applySnapshot()
    local snapshot = self.manager.snapshot or {}
    local compatible = self.manager.integrationAvailable == true and snapshot.compatible == true
    local market = compatible and snapshot.market or {}
    local outputs = compatible and snapshot.outputs or {}
    local batches = compatible and snapshot.batches or {}
    local purchases = compatible and snapshot.purchases or {}

    local function apply(list, renderer, rows, emptyElement)
        local selectedIndex = renderer:setData(rows)
        list:reloadData()
        if selectedIndex > 0 and type(list.setSelectedItem) == "function" then
            list:setSelectedItem(1, selectedIndex, false, false)
        end
        list:setVisible(#rows > 0)
        if emptyElement ~= nil then
            emptyElement:setVisible(#rows == 0)
        end
        if list.sliderElement ~= nil then
            list.sliderElement:onBindUpdate(list)
        end
    end

    apply(self.frame.ipsMarketList, self.renderers.market, market, self.frame.ipsMarketEmpty)
    apply(self.frame.ipsOutputsList, self.renderers.outputs, outputs, self.frame.ipsOutputsEmpty)
    apply(self.frame.ipsBatchesList, self.renderers.batches, batches, self.frame.ipsBatchesEmpty)
    apply(self.frame.ipsPurchasesList, self.renderers.purchases, purchases, nil)
    self:updateFocusNavigation()
    self:updateSliderBinding()
    if self.frame.ipsSlider ~= nil and self.frame.ipsSlider.dataElement ~= nil then
        self.frame.ipsSlider:onBindUpdate(self.frame.ipsSlider.dataElement)
    end
    self:updateSliderVisibility()
    self:updateButtonStates()
end

---Requests an immediate authoritative refresh.
function Controller:onClickRefresh()
    self.refreshTimer = 0
    self.manager:requestSnapshot()
end

---Shows the pallet quantity input for the selected market row.
function Controller:onClickBuyPallets()
    local row = self.renderers.market:getSelectedRow()
    local quoteCount = row ~= nil and #(row.palletQuotes or {}) or 0
    if row == nil or (row.palletCount or 0) < 1 or quoteCount < 1 then
        showInfo(self.manager, "ips_error_noFullPallets")
        return
    end
    self.pendingPalletRow = row
    local maximum = math.min(math.floor(row.palletCount or 0), quoteCount, IPS_Manager.MAX_PALLET_PURCHASE)
    local prompt = string.format(self.manager:getText("ips_dialog_pallet_prompt"), maximum)
    TextInputDialog.show(
        self.onPalletQuantityEntered,
        self,
        "1",
        prompt,
        nil,
        3,
        g_i18n:getText("button_ok")
    )
end

---Validates pallet quantity and asks for final confirmation.
-- @param string text Entered quantity
-- @param boolean confirmed True when the dialog was confirmed
function Controller:onPalletQuantityEntered(text, confirmed)
    if not confirmed then
        self.pendingPalletRow = nil
        return
    end
    local row = self.pendingPalletRow
    if row == nil then
        return
    end
    local quantity = tonumber(string.match(text or "", "^%s*(%d+)%s*$"))
    local maximum = math.min(row.palletCount or 0, #(row.palletQuotes or {}), IPS_Manager.MAX_PALLET_PURCHASE)
    if quantity == nil or quantity < 1 or quantity > maximum then
        self.pendingPalletRow = nil
        showInfo(self.manager, "ips_error_transactionFailed")
        return
    end

    quantity = math.floor(quantity)
    local quote = row.palletQuotes[quantity]
    if quote == nil then
        self.pendingPalletRow = nil
        showInfo(self.manager, "ips_error_offerChanged")
        return
    end
    self.pendingPalletPurchase = {
        offerKey = row.key,
        revision = row.revision,
        quantity = quantity,
        palletToken = row.palletToken,
        productName = row.productName,
        sellerName = row.sellerName,
        price = row.price,
        quotedLiters = quote.liters,
        quotedGross = quote.gross
    }
    self.pendingPalletRow = nil
    local confirmation = string.format(
        self.manager:getText("ips_confirm_pallets"),
        quantity,
        row.productName or "",
        row.sellerName or "",
        g_i18n:formatMoney(quote.gross or 0, 0, true, false)
    )
    confirmation = string.format(
        "%s\n%s: %s\n%s: %s %s",
        confirmation,
        self.manager:getText("ips_col_volume"),
        g_i18n:formatVolume(math.max(quote.liters or 0, 0), 0),
        self.manager:getText("ips_label_pricePer1000L"),
        g_i18n:formatMoney(row.price or 0, 0, true, false),
        self.manager:getText("ips_label_taxIncluded")
    )
    YesNoDialog.show(self.onBuyPalletsConfirmed, self, confirmation)
end

---Sends a server-authoritative pallet purchase.
-- @param boolean confirmed True when the user confirmed
function Controller:onBuyPalletsConfirmed(confirmed)
    local pending = self.pendingPalletPurchase
    self.pendingPalletPurchase = nil
    if not confirmed or pending == nil then
        return
    end
    local connection = g_client ~= nil and g_client:getServerConnection() or nil
    if connection == nil then
        showInfo(self.manager, "ips_error_serverUnavailable")
        return
    end
    connection:sendEvent(IPS_CommandEvent.newBuyPallets(
        pending.offerKey,
        pending.revision,
        pending.quantity,
        pending.palletToken,
        pending.quotedGross
    ))
end

---Asks for confirmation before opening or closing an offer.
function Controller:onClickToggleOffer()
    local row = self.renderers.outputs:getSelectedRow()
    if row == nil then
        return
    end
    local enabled = not row.enabled
    if enabled and row.stored ~= true then
        showInfo(self.manager, "ips_error_outputMode")
        return
    end
    if enabled then
        local maximum = self:getOfferMaximum(row)
        if maximum < 1 then
            showInfo(self.manager, "ips_error_noStock")
            return
        end
        self.pendingOfferRow = row
        TextInputDialog.show(
            self.onOfferPriceEntered,
            self,
            tostring(math.floor(row.price or 0)),
            self.manager:getText("ips_dialog_price_prompt"),
            nil,
            10,
            g_i18n:getText("button_ok")
        )
        return
    end
    self.pendingOfferToggle = {
        productionUniqueId = row.productionUniqueId,
        fillTypeIndex = row.fillTypeIndex,
        enabled = enabled,
        price = row.price,
        listedQuantity = 0
    }
    local key = enabled and "ips_confirm_activate" or "ips_confirm_deactivate"
    local confirmation = string.format(
        self.manager:getText(key),
        row.productName or "",
        row.productionName or ""
    )
    YesNoDialog.show(self.onToggleOfferConfirmed, self, confirmation)
end

---Validates the opening price before requesting the listed quantity.
-- @param string text Entered price
-- @param boolean confirmed True when the dialog was confirmed
function Controller:onOfferPriceEntered(text, confirmed)
    local row = self.pendingOfferRow
    if not confirmed or row == nil then
        self.pendingOfferRow = nil
        return
    end
    local price = IPS_Util.sanitizePrice(string.match(text or "", "^%s*(%d+)%s*$"))
    if price == nil then
        self.pendingOfferRow = nil
        showInfo(self.manager, "ips_error_invalidPrice")
        return
    end

    self.pendingOfferPrice = price
    local maximum = self:getOfferMaximum(row)
    local prompt
    if row.mode == IPS_Manager.MODE_PALLET then
        prompt = string.format(
            "%s (%s: %d)",
            self.manager:getText("ips_label_palletQuantity"),
            self.manager:getText("ips_label_availablePallets"),
            maximum
        )
    else
        prompt = string.format(
            self.manager:getText("ips_dialog_offerQuantity_prompt"),
            g_i18n:formatVolume(maximum, 0)
        )
        if row.mode == IPS_Manager.MODE_BOTH then
            prompt = string.format(
                "%s (%s: %s)",
                prompt,
                self.manager:getText("ips_col_mode"),
                self.renderers.outputs:formatMode(row.mode)
            )
        end
    end
    TextInputDialog.show(
        self.onOfferQuantityEntered,
        self,
        tostring(maximum),
        prompt,
        nil,
        10,
        g_i18n:getText("button_ok")
    )
end

---Validates the fixed listed quantity before final offer confirmation.
-- @param string text Entered quantity
-- @param boolean confirmed True when the dialog was confirmed
function Controller:onOfferQuantityEntered(text, confirmed)
    local row = self.pendingOfferRow
    local price = self.pendingOfferPrice
    self.pendingOfferRow = nil
    self.pendingOfferPrice = nil
    if not confirmed or row == nil or price == nil then
        return
    end

    local listedQuantity = IPS_Util.sanitizeQuantity(string.match(text or "", "^%s*(%d+)%s*$"))
    local maximum = self:getOfferMaximum(row)
    if listedQuantity == nil or listedQuantity > maximum then
        if row.mode == IPS_Manager.MODE_PALLET then
            showInfoText(string.format("%s: 1–%d", self.manager:getText("ips_label_palletQuantity"), maximum))
        else
            showInfo(self.manager, "ips_error_invalidQuantity")
        end
        return
    end

    self.pendingOfferToggle = {
        productionUniqueId = row.productionUniqueId,
        fillTypeIndex = row.fillTypeIndex,
        enabled = true,
        price = price,
        listedQuantity = listedQuantity
    }
    local confirmation = string.format(
        self.manager:getText("ips_confirm_activate"),
        row.productName or "",
        row.productionName or ""
    )
    local quantityText
    if row.mode == IPS_Manager.MODE_PALLET then
        quantityText = string.format("%s: %d", self.manager:getText("ips_label_palletQuantity"), listedQuantity)
    else
        quantityText = string.format(
            "%s: %s",
            self.manager:getText("ips_col_volume"),
            g_i18n:formatVolume(listedQuantity, 0)
        )
    end
    local priceText = string.format(
        "%s: %s %s",
        self.manager:getText("ips_label_pricePer1000L"),
        g_i18n:formatMoney(price or 0, 0, true, false),
        self.manager:getText("ips_label_taxIncluded")
    )
    confirmation = string.format(
        "%s\n%s: %s\n%s\n%s",
        confirmation,
        self.manager:getText("ips_col_mode"),
        self.renderers.outputs:formatMode(row.mode),
        quantityText,
        priceText
    )
    YesNoDialog.show(self.onToggleOfferConfirmed, self, confirmation)
end

---Sends an offer state change after confirmation.
-- @param boolean confirmed True when the user confirmed
function Controller:onToggleOfferConfirmed(confirmed)
    local pending = self.pendingOfferToggle
    self.pendingOfferToggle = nil
    if not confirmed or pending == nil then
        return
    end
    local connection = g_client ~= nil and g_client:getServerConnection() or nil
    if connection == nil then
        showInfo(self.manager, "ips_error_serverUnavailable")
        return
    end
    connection:sendEvent(IPS_CommandEvent.newSetOffer(
        pending.productionUniqueId,
        pending.fillTypeIndex,
        pending.enabled,
        pending.price,
        pending.listedQuantity
    ))
end

---Shows the native text input used to edit an output price.
function Controller:onClickEditPrice()
    local row = self.renderers.outputs:getSelectedRow()
    if row == nil then
        return
    end
    self.pendingPriceRow = row
    TextInputDialog.show(
        self.onPriceEntered,
        self,
        tostring(math.floor(row.price or 0)),
        self.manager:getText("ips_dialog_price_prompt"),
        nil,
        10,
        g_i18n:getText("button_ok")
    )
end

---Validates and sends a new tax-inclusive price.
-- @param string text Entered price
-- @param boolean confirmed True when the dialog was confirmed
function Controller:onPriceEntered(text, confirmed)
    local row = self.pendingPriceRow
    self.pendingPriceRow = nil
    if not confirmed or row == nil then
        return
    end
    local price = IPS_Util.sanitizePrice(string.match(text or "", "^%s*(%d+)%s*$"))
    if price == nil then
        showInfo(self.manager, "ips_error_invalidPrice")
        return
    end
    local connection = g_client ~= nil and g_client:getServerConnection() or nil
    if connection == nil then
        showInfo(self.manager, "ips_error_serverUnavailable")
        return
    end
    connection:sendEvent(IPS_CommandEvent.newSetOffer(
        row.productionUniqueId,
        row.fillTypeIndex,
        row.enabled == true,
        price,
        0
    ))
end

---Asks for confirmation before closing a seller batch.
function Controller:onClickCloseBatch()
    local row = self.renderers.batches:getSelectedRow()
    if row == nil then
        return
    end
    self.pendingBatchReference = row.reference
    local confirmation = string.format(
        self.manager:getText("ips_confirm_closeBatch"),
        row.buyerName or "",
        g_i18n:formatMoney(row.batchTotalGross or row.totalGross or 0, 0, true, false)
    )
    YesNoDialog.show(self.onCloseBatchConfirmed, self, confirmation)
end

---Sends a batch closure after confirmation.
-- @param boolean confirmed True when the user confirmed
function Controller:onCloseBatchConfirmed(confirmed)
    local reference = self.pendingBatchReference
    self.pendingBatchReference = nil
    if not confirmed or reference == nil or reference == "" then
        return
    end
    local connection = g_client ~= nil and g_client:getServerConnection() or nil
    if connection == nil then
        showInfo(self.manager, "ips_error_serverUnavailable")
        return
    end
    connection:sendEvent(IPS_CommandEvent.newCloseBatch(reference))
end

---Restores the native frame instance and releases extension controls.
-- @param boolean deleteElements Whether injected elements must be deleted immediately
function Controller:detach(deleteElements)
    if self.detached then
        return
    end
    self.detached = true
    local frame = self.frame
    if frame ~= nil then
        if self.outerPagingFocusLinked and frame.subCategoryPaging ~= nil then
            frame.subCategoryPaging.focusChangeData[FocusManager.BOTTOM] = self.originals.outerPagingBottomFocus
            self.outerPagingFocusLinked = false
        end
        if frame.ipsSlider ~= nil and frame.ipsSlider.setDataElement ~= nil then
            frame.ipsSlider:setDataElement(nil)
        end
        if frame.updateSubCategoryPages == self.wrappers.updateSubCategoryPages then
            frame.updateSubCategoryPages = self.originals.updateSubCategoryPages
        end
        if frame.subCategoryPaging ~= nil and frame.subCategoryPaging.onClickCallback == self.wrappers.updateSubCategoryPages then
            frame.subCategoryPaging.onClickCallback = self.originals.pagingCallback
        end
        for _, methodName in ipairs({"onFrameOpen", "onFrameClose", "update", "onClickDetails", "delete"}) do
            if frame[methodName] == self.wrappers[methodName] then
                frame[methodName] = self.originals[methodName]
            end
        end

        if frame.ipsSubCategoryTab ~= nil
            and frame.subCategoryTabs ~= nil
            and frame.subCategoryTabs[self.tabIndex] == frame.ipsSubCategoryTab then
            table.remove(frame.subCategoryTabs, self.tabIndex)
        end
        if frame.ipsSubCategoryPage ~= nil
            and frame.subCategoryPages ~= nil
            and frame.subCategoryPages[self.tabIndex] == frame.ipsSubCategoryPage then
            table.remove(frame.subCategoryPages, self.tabIndex)
        end
        if frame.menuButtonInfo ~= nil then
            frame.menuButtonInfo[self.tabIndex] = nil
        end

        if deleteElements then
            if frame.ipsSubCategoryTab ~= nil then frame.ipsSubCategoryTab:delete() end
            if frame.ipsSubCategoryPage ~= nil then frame.ipsSubCategoryPage:delete() end
            if frame.ipsSliderBox ~= nil then frame.ipsSliderBox:delete() end
        end
        for _, id in ipairs(CONTROL_IDS) do
            frame[id] = nil
            if frame.controlIDs ~= nil then frame.controlIDs[id] = nil end
        end
        for _, fieldName in ipairs(CALLBACK_FIELDS) do
            frame[fieldName] = nil
        end
        frame.ipsExtensionInstalled = nil
    end

    for _, renderer in pairs(self.renderers or {}) do
        renderer:delete()
    end
    self.pendingPalletRow = nil
    self.pendingPalletPurchase = nil
    self.pendingOfferToggle = nil
    self.pendingOfferRow = nil
    self.pendingOfferPrice = nil
    self.pendingPriceRow = nil
    self.pendingBatchReference = nil
    self.renderers = nil
    self.frame = nil
    IPS_FrameExtension.controller = nil
    IPS_FrameExtension.frame = nil
end

---Marks the complete integration unavailable after a verified UI contract failure.
-- @param string reason Diagnostic detail
function IPS_FrameExtension.failClosed(reason)
    if IPS_FrameExtension.failed then
        return
    end
    IPS_FrameExtension.failed = true
    local manager = IPS_FrameExtension.manager
    Logging.error("[InvoicesProductionSales] Invoices UI integration failed: %s", tostring(reason))
    if manager ~= nil then
        manager.integrationAvailable = false
        manager.integrationErrorKey = "ips_error_invoiceIncompatible"
        if g_server ~= nil and type(manager.disableAllOffersForIntegrationFailure) == "function" then
            manager:disableAllOffersForIntegrationFailure()
        end
        manager:showIntegrationError()
    end
end

---Attempts the atomic runtime graft once the Invoice frame is available.
-- @return boolean True when installed
-- @return boolean True when a terminal incompatibility was detected
function IPS_FrameExtension.tryInstall()
    if IPS_FrameExtension.controller ~= nil and IPS_FrameExtension.frame ~= nil then
        return true, false
    end
    local manager = IPS_FrameExtension.manager
    if manager == nil or manager.integrationAvailable ~= true then
        return false, true
    end
    local frame = getInvoicesFrame(manager)
    if frame == nil then
        return false, false
    end

    local valid, reason = validateFrameContract(frame)
    if not valid then
        IPS_FrameExtension.failClosed(reason)
        return false, true
    end

    local controller = Controller.new(frame, manager)
    local tabParent = frame.subCategoryBox
    local pageParent = frame.subCategoryPages[1].parent
    local tabStart = #tabParent.elements
    local pageStart = #pageParent.elements
    controller:installCallbackAliases()

    local xmlPath = InvoicesProductionSales.modDirectory .. "gui/IPS_ProductionSalesPage.xml"
    local xmlFile = loadXMLFile("IPS_ProductionSalesPage", xmlPath)
    if xmlFile == nil or xmlFile == 0 then
        controller:detach(false)
        IPS_FrameExtension.failClosed("could not load extension XML")
        return false, true
    end

    local previousGui = FocusManager.currentGui
    FocusManager:setGui(frame.name)
    local ok, errorMessage = pcall(function()
        g_gui:loadGuiRec(xmlFile, "InvoicesProductionSalesExtension.TabControls", tabParent, frame)
        g_gui:loadGuiRec(xmlFile, "InvoicesProductionSalesExtension.PageControls", pageParent, frame)
        frame:exposeControlsAsFields(frame.name)

        for index = tabStart + 1, #tabParent.elements do
            tabParent.elements[index]:updateAbsolutePosition()
            tabParent.elements[index]:onGuiSetupFinished()
        end
        for index = pageStart + 1, #pageParent.elements do
            pageParent.elements[index]:updateAbsolutePosition()
            pageParent.elements[index]:onGuiSetupFinished()
        end

        controller:registerTabAndPage()
        controller:initializeControls()
        controller:installInstanceWrappers()
    end)
    delete(xmlFile)
    if previousGui ~= nil and previousGui ~= frame.name then
        FocusManager:setGui(previousGui)
    end

    if not ok then
        controller:detach(false)
        removeInjectedControls(frame, tabParent, tabStart, pageParent, pageStart)
        IPS_FrameExtension.failClosed(errorMessage)
        return false, true
    end

    frame.ipsExtensionInstalled = true
    IPS_FrameExtension.controller = controller
    IPS_FrameExtension.frame = frame
    Logging.info("[InvoicesProductionSales] Production sales tab installed in InvoicesFrame")
    return true, false
end

---Starts the deferred instance-only GUI installation on clients.
function IPS_FrameExtension.install()
    if IPS_FrameExtension.controller ~= nil then
        return
    end
    IPS_FrameExtension.manager = InvoicesProductionSales.manager
    IPS_FrameExtension.failed = false
    IPS_FrameExtension.retryTimer = 0
    if g_client == nil or g_currentMission == nil or IPS_FrameExtension.manager == nil then
        return
    end
    if IPS_FrameExtension.manager.integrationAvailable ~= true then
        return
    end

    local installed, terminal = IPS_FrameExtension.tryInstall()
    if not installed and not terminal then
        g_currentMission:addUpdateable(IPS_FrameExtension)
        IPS_FrameExtension.isUpdateable = true
    end
end

---Retries installation until Invoices has resolved its frame.
-- @param number dt Delta time in milliseconds
function IPS_FrameExtension:update(dt)
    if IPS_FrameExtension.controller ~= nil or IPS_FrameExtension.failed then
        return
    end
    IPS_FrameExtension.retryTimer = IPS_FrameExtension.retryTimer - (dt or 0)
    if IPS_FrameExtension.retryTimer > 0 then
        return
    end
    IPS_FrameExtension.retryTimer = 250
    local installed, terminal = IPS_FrameExtension.tryInstall()
    if installed or terminal then
        if IPS_FrameExtension.isUpdateable and g_currentMission ~= nil then
            g_currentMission:removeUpdateable(IPS_FrameExtension)
            IPS_FrameExtension.isUpdateable = false
        end
    end
end

---Applies a newly synchronized snapshot to the visible extension.
function IPS_FrameExtension.onSnapshotUpdated()
    if IPS_FrameExtension.controller ~= nil then
        IPS_FrameExtension.controller:applySnapshot()
    end
end

---Removes mission-scoped GUI state without touching Invoice source files.
function IPS_FrameExtension.delete()
    if IPS_FrameExtension.isUpdateable and g_currentMission ~= nil then
        g_currentMission:removeUpdateable(IPS_FrameExtension)
        IPS_FrameExtension.isUpdateable = false
    end
    if IPS_FrameExtension.controller ~= nil then
        IPS_FrameExtension.controller:detach(true)
    end
    IPS_FrameExtension.controller = nil
    IPS_FrameExtension.frame = nil
    IPS_FrameExtension.manager = nil
    IPS_FrameExtension.failed = false
end
