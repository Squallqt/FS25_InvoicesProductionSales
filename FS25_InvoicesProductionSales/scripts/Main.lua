-- Copyright © 2026 Squallqt. All rights reserved.
---Production sales companion bootstrap.
InvoicesProductionSales = {
    modDirectory = g_currentModDirectory,
    modName = g_currentModName,
    manager = nil,
    version = "1.0.0.0"
}

local modDirectory = InvoicesProductionSales.modDirectory

---Loads the production sales GUI profiles once.
local function loadGuiAssets()
    if not InvoicesProductionSales._guiProfilesLoaded then
        g_gui:loadProfiles(modDirectory .. "gui/guiProfiles.xml")
        InvoicesProductionSales._guiProfilesLoaded = true
    end
end

source(modDirectory .. "scripts/IPS_Util.lua")
source(modDirectory .. "scripts/IPS_Manager.lua")
source(modDirectory .. "events/IPS_DataRequestEvent.lua")
source(modDirectory .. "events/IPS_DataSyncEvent.lua")
source(modDirectory .. "events/IPS_CommandEvent.lua")
source(modDirectory .. "events/IPS_StartLoadingEvent.lua")
source(modDirectory .. "events/IPS_ResultEvent.lua")
source(modDirectory .. "events/IPS_ReceiptEvent.lua")
source(modDirectory .. "events/IPS_PalletOwnershipEvent.lua")
source(modDirectory .. "scripts/IPS_Hooks.lua")
source(modDirectory .. "gui/IPS_ListRenderer.lua")
source(modDirectory .. "gui/IPS_FrameExtension.lua")

---Initializes the companion after the mission and Invoice manager are ready.
local function onMissionLoaded()
    loadGuiAssets()
    local manager = IPS_Manager.new()
    InvoicesProductionSales.manager = manager
    g_currentMission.invoicesProductionSalesManager = manager
    manager:initialize()
    IPS_Hooks.install()
    IPS_FrameExtension.install()
end

---Saves production sales state with the savegame.
local function onSaveSavegame()
    local manager = InvoicesProductionSales.manager
    if manager ~= nil and g_currentMission ~= nil and g_currentMission:getIsServer() then
        manager:saveToXML(manager:getSavegameDirectory())
    end
end

---Sends the companion snapshot to a joining client.
-- @param table self Mission instance
-- @param Connection connection Joining connection
-- @param table user Joining user data
-- @param table farm Joining farm data
local function onSendInitialClientState(self, connection, user, farm)
    local manager = InvoicesProductionSales.manager
    if g_server ~= nil and manager ~= nil and connection ~= nil then
        manager:sendSnapshot(connection, farm ~= nil and farm.farmId or nil)
    end
end

---Cleans up mission-scoped state.
local function onMissionDelete()
    IPS_FrameExtension.delete()
    if InvoicesProductionSales.manager ~= nil then
        InvoicesProductionSales.manager:delete()
        InvoicesProductionSales.manager = nil
    end
    if g_currentMission ~= nil then
        g_currentMission.invoicesProductionSalesManager = nil
    end
end

Mission00.loadMission00Finished = Utils.appendedFunction(Mission00.loadMission00Finished, onMissionLoaded)
FSBaseMission.saveSavegame = Utils.appendedFunction(FSBaseMission.saveSavegame, onSaveSavegame)
FSBaseMission.sendInitialClientState = Utils.appendedFunction(FSBaseMission.sendInitialClientState, onSendInitialClientState)
BaseMission.delete = Utils.appendedFunction(BaseMission.delete, onMissionDelete)
