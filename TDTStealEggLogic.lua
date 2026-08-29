--[[
    TDT Steal an Egg — Farm logic (doc tu kaitundemo_decompiled.lua)
    Dung EggState + priority loop giong Ouroboros hub.
]]

local TDTStealEggLogic = {}

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local LocalPlayer = Players.LocalPlayer

local Config = {
    AutoStealSelected = false,
    AutoStealAll = false,
    AutoReturn = true,
    AutoDropEgg = false,
    AutoPlaceSelected = false,
    AutoPlaceAll = false,
    AutoOpenReadyEggs = false,
    AutoEquipBestPets = false,
    AutoTreadmill = false,
    AutoFusePets = false,
    AutoSellPets = false,
    AutoSellEggs = false,
    AutoUpgrades = false,
    AutoClaimIndex = false,
    AutoClaimOffline = false,
    StealSpeed = 300,
    StealBigEggs = false,
    StealBigEggScale = 1.5,
    StealPriority = "Nearest",
    WalkSpeed = 32,
    WalkSpeedEnabled = false,
    NoClip = false,
}

local RARITY_RANK = {
    Common = 1,
    Uncommon = 2,
    Rare = 3,
    Epic = 4,
    Legendary = 5,
    Mythic = 6,
    Cosmic = 7,
    Secret = 8,
    Eternal = 9,
    Divine = 10,
}

local OPTION_ALIASES = {
    AutoEquipBestPets = "ResolvePlot",
    AutoServerHop = "1289",
    HopThreshold = "921",
}

local Modules = {}
local carrying = false
local running = false
local lastTaskRun = {}
local moveTarget = nil
local debugEnabled = function()
    return getgenv and getgenv().TDT_FARM_DEBUG == true
end

local function log(msg)
    print("[TDT Farm]", msg)
end

local function debugLog(msg)
    if debugEnabled() then
        print("[TDT Farm DEBUG]", msg)
    end
end

local function loadModules()
    if Modules.loaded then
        return Modules.ok
    end
    Modules.loaded = true

    local ok, err = pcall(function()
        local root = ReplicatedStorage:WaitForChild("Shared", 25)
        local client = root:WaitForChild("Client", 25)
        Modules.EggState = require(client:WaitForChild("EggState"))
        Modules.BaseUpgrade = require(client:WaitForChild("BaseUpgrade"))

        local inner = root:FindFirstChild("Shared") or root
        Modules.Constants = require(inner:WaitForChild("Globals"):WaitForChild("Constants"))
        Modules.Eggs = require(inner:WaitForChild("Types"):WaitForChild("Eggs"))
        Modules.Save = require(inner:WaitForChild("Save"))

        local slotMod = client:FindFirstChild("AreaEggSlotsClient")
        if slotMod and slotMod:IsA("ModuleScript") then
            Modules.AreaEggClient = require(slotMod)
        end
    end)

    Modules.ok = ok
    if not ok then
        warn("[TDT Farm] Load modules failed:", err)
    end
    return ok
end

local function bindCarryEvent()
    if Modules.carryBound or not Modules.EggState then
        return
    end
    local event = Modules.EggState.CarryChanged
    if event and event.Connect then
        Modules.carryBound = true
        event:Connect(function(state)
            if type(state) == "table" then
                carrying = state.IsCarrying == true
            end
        end)
    end
end

function TDTStealEggLogic.setOption(key, value)
    local id = OPTION_ALIASES[key] or key
    Config[id] = value
    Config[key] = value
    if key == "AutoStealAll" or key == "AutoStealSelected" then
        debugLog(string.format("Steal toggle %s = %s | enabled = %s", key, tostring(value), tostring(stealingEnabled())))
    end
end

function TDTStealEggLogic.getConfig()
    return Config
end

local function getCharacter()
    return LocalPlayer.Character
end

local function getRoot()
    local char = getCharacter()
    return char and char:FindFirstChild("HumanoidRootPart")
end

local function getHumanoid()
    local char = getCharacter()
    return char and char:FindFirstChildOfClass("Humanoid")
end

local function stealingEnabled()
    return Config.AutoStealSelected == true or Config.AutoStealAll == true
end

local function syncCarryingState()
    pcall(function()
        if Modules.EggState then
            if Modules.EggState.GetCarryState then
                local state = Modules.EggState.GetCarryState()
                if type(state) == "table" then
                    carrying = state.IsCarrying == true
                    return
                end
            end
            if Modules.EggState.IsCarrying then
                carrying = Modules.EggState.IsCarrying() == true
            end
        end
    end)
end

local function placingEnabled()
    return Config.AutoPlaceSelected == true or Config.AutoPlaceAll == true
end

local function syncFieldEggs()
    pcall(function()
        Modules.EggState.SyncFieldEggs()
    end)
end

local function flattenEggs(data)
    local list = {}
    local function walk(node)
        if type(node) ~= "table" then
            return
        end
        if node.Uid or node.uid or node.AssetCategory then
            table.insert(list, node)
            return
        end
        for _, value in pairs(node) do
            walk(value)
        end
    end
    walk(data)
    return list
end

local function readFieldEggs()
    syncFieldEggs()
    local ok, data = pcall(function()
        return Modules.EggState.ReadFieldEggs()
    end)
    if ok and type(data) == "table" then
        local list = flattenEggs(data)
        debugLog("Field eggs found: " .. tostring(#list))
        return list
    end
    debugLog("ReadFieldEggs failed or empty")
    return {}
end

local function findEggInWorld(uid)
    if type(uid) ~= "string" or uid == "" then
        return nil
    end
    local objects = Workspace:FindFirstChild("__OBJECTS")
    if not objects then
        return nil
    end
    for _, inst in ipairs(objects:GetDescendants()) do
        if inst:IsA("BasePart") or inst:IsA("Model") then
            local match = inst:GetAttribute("Uid") or inst:GetAttribute("UID") or inst:GetAttribute("EggUid")
            if match == uid then
                if inst:IsA("Model") then
                    return inst:GetPivot().Position
                end
                return inst.Position
            end
            if inst.Name == uid then
                if inst:IsA("Model") then
                    return inst:GetPivot().Position
                elseif inst:IsA("BasePart") then
                    return inst.Position
                end
            end
        end
    end
    return nil
end

local function resolveAreaPosition(areaId, slotId)
    local areas = Workspace:FindFirstChild("__OBJECTS")
    areas = areas and areas:FindFirstChild("Areas")
    if not areas or type(areaId) ~= "string" then
        return nil
    end
    local area = areas:FindFirstChild(areaId)
    if not area then
        return nil
    end
    if slotId then
        local slot = area:FindFirstChild(tostring(slotId), true)
            or area:FindFirstChild("Slot" .. tostring(slotId), true)
        if slot then
            if slot:IsA("BasePart") then
                return slot.Position
            elseif slot:IsA("Model") then
                return slot:GetPivot().Position
            end
            local part = slot:FindFirstChildWhichIsA("BasePart", true)
            if part then
                return part.Position
            end
        end
    end
    if area:IsA("BasePart") then
        return area.Position
    end
    local part = area:FindFirstChildWhichIsA("BasePart", true)
    return part and part.Position
end

local function resolveRarity(assetCategory)
    if Modules.Eggs then
        local ok, rarity = pcall(function()
            if Modules.Eggs.GetRarity then
                return Modules.Eggs.GetRarity(assetCategory)
            end
            if Modules.Eggs.Rarity and Modules.Eggs.Rarity[assetCategory] then
                return Modules.Eggs.Rarity[assetCategory]
            end
        end)
        if ok and type(rarity) == "string" then
            return rarity
        end
    end
    return "Common"
end

local function recordMutations(record)
    local list = {}
    if type(record) ~= "table" then
        return list
    end
    if type(record.Mutations) == "table" then
        for _, mut in pairs(record.Mutations) do
            if type(mut) == "string" then
                table.insert(list, mut)
            end
        end
    end
    if type(record.BaseMutation) == "string" then
        table.insert(list, record.BaseMutation)
    end
    return list
end

local function eggInventoryFull()
    if not Modules.Save then
        return false
    end
    local ok, save = pcall(function()
        if Modules.Save.ReadSnapshot then
            return Modules.Save.ReadSnapshot()
        end
        return Modules.Save.ReadSnapshot
    end)
    if not ok or type(save) ~= "table" then
        return false
    end
    local count = 0
    if type(save.EggInventory) == "table" then
        for _ in pairs(save.EggInventory) do
            count += 1
        end
    end
    local max = math.huge
    if Modules.Constants and Modules.Constants.MAX_INVENTORY then
        max = tonumber(Modules.Constants.MAX_INVENTORY) or max
    end
    return count >= max
end

local function getEggPosition(record)
    if type(record) ~= "table" then
        return nil
    end
    if typeof(record.Position) == "Vector3" then
        return record.Position
    end
    if typeof(record.WorldPosition) == "Vector3" then
        return record.WorldPosition
    end
    if typeof(record.CFrame) == "CFrame" then
        return record.CFrame.Position
    end

    local uid = record.Uid or record.uid or record.ID
    if Modules.AreaEggClient then
        local ok, pos = pcall(function()
            if Modules.AreaEggClient.GetSlotPosition then
                return Modules.AreaEggClient.GetSlotPosition(uid)
            end
            if Modules.AreaEggClient.GetWorldPosition then
                return Modules.AreaEggClient.GetWorldPosition(record)
            end
            if Modules.AreaEggClient.FindRecord and uid then
                local enriched = Modules.AreaEggClient.FindRecord(uid)
                if type(enriched) == "table" then
                    return getEggPosition(enriched)
                end
            end
        end)
        if ok and typeof(pos) == "Vector3" then
            return pos
        end
    end

    local worldPos = findEggInWorld(uid)
    if worldPos then
        return worldPos
    end

    return resolveAreaPosition(record.AreaId, record.SlotId or record.Slot or record.Index)
end

local function scoreEgg(record, rootPos)
    local pos = getEggPosition(record)
    if not pos then
        return nil
    end
    local dist = (rootPos - pos).Magnitude
    local rarity = resolveRarity(record.AssetCategory)
    local rank = RARITY_RANK[rarity] or 0
    local scale = tonumber(record.AssetScale) or 1

    local priority = Config.StealPriority or "Nearest"
    if priority == "Highest Value" or priority == "Rarest" then
        return rank * 10000 - dist
    elseif priority == "Biggest Scale" or priority == "Biggest Size" then
        return scale * 1000 - dist
    elseif priority == "Lowest Value" then
        return -rank * 10000 - dist
    end
    return -dist
end

local function pickEgg(records)
    local root = getRoot()
    if not root then
        return nil
    end
    local list = type(records[1]) == "table" and records or flattenEggs(records)
    local best, bestScore
    for _, record in ipairs(list) do
        if type(record) == "table" then
            local scale = tonumber(record.AssetScale) or 1
            if Config.StealBigEggs and scale < (Config.StealBigEggScale or 1.5) then
                continue
            end
            local score = scoreEgg(record, root.Position)
            if score and (not bestScore or score > bestScore) then
                best = record
                bestScore = score
            end
        end
    end
    return best
end

local function moveTo(position)
    local root = getRoot()
    local hum = getHumanoid()
    if not root or not hum then
        return false
    end

    local speed = math.clamp(tonumber(Config.StealSpeed) or 300, 16, 1000)
    if Config.WalkSpeedEnabled then
        hum.WalkSpeed = tonumber(Config.WalkSpeed) or hum.WalkSpeed
    end

    local delta = position - root.Position
    local dist = delta.Magnitude
    if dist <= 6 then
        return true
    end

    if speed >= 80 then
        local step = math.min(dist, math.max(speed * 0.05, 12))
        root.CFrame = CFrame.new(root.Position + delta.Unit * step)
        if Config.NoClip then
            for _, part in ipairs(getCharacter():GetDescendants()) do
                if part:IsA("BasePart") then
                    part.CanCollide = false
                end
            end
        end
    else
        hum:MoveTo(position)
    end

    return (root.Position - position).Magnitude <= 12
end

local function getRespawnPosition()
    if Modules.BaseUpgrade then
        local ok, cf = pcall(Modules.BaseUpgrade.FindRespawnCFrame)
        if ok and typeof(cf) == "CFrame" then
            return cf.Position
        end
    end
    local spawn = Workspace:FindFirstChild("Spawn") or Workspace:FindFirstChild("SpawnLocation")
    if spawn and spawn:IsA("BasePart") then
        return spawn.Position
    end
    return Vector3.new(0, 10, 0)
end

local function tryCarry(record)
    local uid = record.Uid or record.uid or record.ID
    if not uid then
        return false
    end
    local ok, result = pcall(function()
        return Modules.EggState.CarryFieldEgg(uid)
    end)
    return ok and result ~= false
end

local function tryDrop()
    pcall(function()
        Modules.EggState.DropFieldEgg("PlayerRequest")
    end)
end

local function tryPlace(uid)
    pcall(function()
        Modules.EggState.PlantEgg(uid)
    end)
end

local function tryHatch(uid)
    pcall(function()
        if Modules.EggState.IsReadyToHatch(uid) then
            Modules.EggState.BeginHatch(uid)
            task.wait(0.1)
            Modules.EggState.FinishHatch(uid)
        end
    end)
end

local function runAutoSteal()
    syncCarryingState()
    if not stealingEnabled() or carrying or eggInventoryFull() then
        return false
    end

    local records = readFieldEggs()
    if #records == 0 then
        debugLog("No eggs in snapshot")
        return false
    end

    local target = pickEgg(records)
    if not target then
        debugLog("No egg with valid position")
        return false
    end

    local uid = target.Uid or target.uid or target.ID
    local pos = getEggPosition(target)
    if not pos then
        debugLog("Missing position for egg " .. tostring(uid))
        return false
    end

    moveTarget = uid
    local arrived = moveTo(pos)
    if not arrived then
        debugLog("Moving to egg " .. tostring(uid))
        return false
    end

    if tryCarry(target) then
        log("Steal egg: " .. tostring(uid))
        moveTarget = nil
        task.wait(0.55)
        syncCarryingState()
        return true
    end

    debugLog("CarryFieldEgg failed for " .. tostring(uid))
    return false
end

local function runReturnBase()
    syncCarryingState()
    if not carrying or not Config.AutoReturn then
        return false
    end
    return moveTo(getRespawnPosition())
end

local function runAutoDrop()
    if carrying and Config.AutoDropEgg then
        tryDrop()
        return true
    end
    return false
end

local function runAutoPlace()
    if not placingEnabled() or carrying then
        return false
    end
    if not Modules.Save then
        return false
    end
    local ok, save = pcall(function()
        if Modules.Save.ReadSnapshot then
            return Modules.Save.ReadSnapshot()
        end
        return Modules.Save.ReadSnapshot
    end)
    if not ok or type(save) ~= "table" or type(save.EggInventory) ~= "table" then
        return false
    end
    for uid in pairs(save.EggInventory) do
        tryPlace(uid)
        task.wait(0.2)
        return true
    end
    return false
end

local function runAutoHatch()
    if not Config.AutoOpenReadyEggs or not Modules.Save then
        return false
    end
    local ok, save = pcall(function()
        if Modules.Save.ReadSnapshot then
            return Modules.Save.ReadSnapshot()
        end
        return Modules.Save.ReadSnapshot
    end)
    if not ok or type(save) ~= "table" then
        return false
    end
    local slots = save.PlotEggs or save.Eggs or save.SlotEggs
    if type(slots) ~= "table" then
        return false
    end
    for uid in pairs(slots) do
        pcall(function()
            if Modules.EggState.IsReadyToHatch(uid) then
                tryHatch(uid)
            end
        end)
    end
    return false
end

local TASKS = {
    ["Auto Steal Egg"] = { Ready = function()
        return stealingEnabled() and not carrying and not eggInventoryFull()
    end, Run = runAutoSteal, Interval = 0.2 },
    ["Auto Return"] = { Ready = function()
        return carrying and Config.AutoReturn
    end, Run = runReturnBase, Interval = 0.12 },
    ["Auto Drop"] = { Ready = function()
        return carrying and Config.AutoDropEgg
    end, Run = runAutoDrop, Interval = 0.3 },
    ["Auto Place Egg"] = { Ready = function()
        return placingEnabled() and not carrying
    end, Run = runAutoPlace, Interval = 2 },
    ["Auto Hatch"] = { Ready = function()
        return Config.AutoOpenReadyEggs and not carrying
    end, Run = runAutoHatch, Interval = 2 },
}

local TASK_ORDER = { "Auto Steal Egg", "Auto Return", "Auto Drop", "Auto Place Egg", "Auto Hatch" }

local function priorityLoop()
    while running do
        syncCarryingState()
        for _, name in ipairs(TASK_ORDER) do
            local taskDef = TASKS[name]
            if taskDef then
                local now = os.clock()
                local last = lastTaskRun[name] or 0
                if now - last >= taskDef.Interval then
                    local ready = false
                    pcall(function()
                        ready = taskDef.Ready() == true
                    end)
                    if ready then
                        lastTaskRun[name] = now
                        pcall(taskDef.Run)
                    end
                end
            end
        end
        task.wait(0.05)
    end
end

function TDTStealEggLogic.start()
    if running then
        return true
    end
    if not loadModules() then
        warn("[TDT Farm] Khong load duoc game modules — ban co dang o game Steal an Egg khong?")
        return false
    end
    bindCarryEvent()
    syncCarryingState()
    running = true
    task.spawn(priorityLoop)
    log("Farm loop started. Bat Auto Steal All de chay.")
    if debugEnabled() then
        local testEggs = readFieldEggs()
        log("Debug: " .. tostring(#testEggs) .. " eggs in field snapshot")
    end
    return true
end

function TDTStealEggLogic.status()
    return {
        running = running,
        modulesOk = Modules.ok == true,
        carrying = carrying,
        stealEnabled = stealingEnabled(),
        config = Config,
        moveTarget = moveTarget,
    }
end

function TDTStealEggLogic.stop()
    running = false
end

return TDTStealEggLogic
