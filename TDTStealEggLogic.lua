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
    AutoStealAll = "HopValue",
    AutoEquipBestPets = "ResolvePlot",
    AutoServerHop = "1289",
    HopThreshold = "921",
}

local Modules = {}
local carrying = false
local running = false
local lastTaskRun = {}

local function log(msg)
    print("[TDT Farm]", msg)
end

local function loadModules()
    if Modules.loaded then
        return Modules.ok
    end
    Modules.loaded = true

    local ok, err = pcall(function()
        local shared = ReplicatedStorage:WaitForChild("Shared", 20)
        local client = shared:WaitForChild("Client", 20)
        Modules.EggState = require(client:WaitForChild("EggState"))
        Modules.Constants = require(shared:WaitForChild("Globals"):WaitForChild("Constants"))
        pcall(function()
            Modules.Eggs = require(shared:WaitForChild("Types"):WaitForChild("Eggs"))
        end)
        pcall(function()
            Modules.Save = require(shared:WaitForChild("Save"))
        end)
        pcall(function()
            Modules.BaseUpgrade = require(client:WaitForChild("BaseUpgrade"))
        end)
        Modules.AreaEggClient = ReplicatedStorage:FindFirstChild("AreaEggSlotsClient")
            or client:FindFirstChild("AreaEggSlotsClient")
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
    return Config.AutoStealSelected == true or Config.AutoStealAll == true or Config.HopValue == true
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
    local ok, data = pcall(function()
        return Modules.EggState.ReadFieldEggs()
    end)
    if ok and type(data) == "table" then
        return flattenEggs(data)
    end
    return {}
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
    local ok, save = pcall(Modules.Save.ReadSnapshot)
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
    local areas = Workspace:FindFirstChild("__OBJECTS")
    areas = areas and areas:FindFirstChild("Areas")
    if areas and record.AreaId then
        local area = areas:FindFirstChild(record.AreaId)
        if area then
            if area:IsA("BasePart") then
                return area.Position
            end
            local part = area:FindFirstChildWhichIsA("BasePart", true)
            if part then
                return part.Position
            end
        end
    end
    return nil
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
        local step = math.min(dist, speed * 0.03)
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

    return (root.Position - position).Magnitude <= 10
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
    if not stealingEnabled() or carrying or eggInventoryFull() then
        return false
    end

    syncFieldEggs()
    local records = readFieldEggs()
    local target = pickEgg(records)
    if not target then
        return false
    end

    local pos = getEggPosition(target)
    if not pos then
        return false
    end

    if not moveTo(pos) then
        return false
    end

    local uid = target.Uid or target.uid
    if tryCarry(target) then
        log("Steal egg: " .. tostring(uid))
        task.wait(0.55)
        return true
    end
    return false
end

local function runReturnBase()
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
    local ok, save = pcall(Modules.Save.ReadSnapshot)
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
    local ok, save = pcall(Modules.Save.ReadSnapshot)
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
        return false
    end
    bindCarryEvent()
    running = true
    task.spawn(priorityLoop)
    log("Farm loop started.")
    return true
end

function TDTStealEggLogic.stop()
    running = false
end

return TDTStealEggLogic
