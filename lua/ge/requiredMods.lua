local M = {}

-- Track our parent mod
local ourParentMod = nil
local ourDependencyIds = {}

local function findRequiredModsFiles(basePath, foundFiles)
    foundFiles = foundFiles or {}
    
    local reqModsPath = basePath .. "/requiredMods.json"
    if FS:fileExists(reqModsPath) then
        table.insert(foundFiles, reqModsPath)
    end

    local items = FS:findFiles(basePath, "*", 0, false, true)
    
    for _, item in ipairs(items) do
        local dirName = item:match("([^/]+)$")
        local fullItemPath = basePath .. "/" .. dirName
        
        if FS:directoryExists(fullItemPath) then
            findRequiredModsFiles(fullItemPath, foundFiles)
        end
    end
    
    return foundFiles
end

local function parseRequiredModsFile(filePath)
    local file = io.open(filePath, "r")
    if not file then
        log("E", "ModConflictResolver", "Could not open file: " .. filePath)
        return {}
    end
    
    local content = file:read("*all")
    file:close()
    
    if not content or content == "" then
        log("W", "ModConflictResolver", "Empty requiredMods.json file: " .. filePath)
        return {}
    end
    
    local success, data = pcall(jsonDecode, content)
    if not success then
        log("E", "ModConflictResolver", "Failed to parse JSON in " .. filePath .. ": " .. tostring(data))
        return {}
    end
    
    if not data or not data.modIds or type(data.modIds) ~= "table" then
        log("W", "ModConflictResolver", "Invalid format in " .. filePath .. " - missing or invalid 'modIds' array")
        return {}
    end
    
    return data.modIds
end

local function collectAllRequiredMods()
    local allModIds = {}
    local modIdSet = {}
    
    local basePath = "/dependencies"

    if FS:directoryExists(basePath) then
        local requiredModsFiles = findRequiredModsFiles(basePath)
        
        for _, filePath in ipairs(requiredModsFiles) do
            local modIds = parseRequiredModsFile(filePath)
            
            for _, modId in ipairs(modIds) do
                if type(modId) == "string" and modId ~= "" and not modIdSet[modId] then
                    table.insert(allModIds, modId)
                    modIdSet[modId] = true
                    ourDependencyIds[modId] = true  -- Track our dependencies
                end
            end
        end
    else
        log("W", "ModConflictResolver", "Directory not found: " .. basePath)
    end
    
    return allModIds
end

-- Check if a mod is already installed and active
local function isModAlreadyActive(modId)
    if not core_modmanager then
        return false
    end
    
    -- Get mod name from ID
    local modName = core_modmanager.getModNameFromID(modId)
    if not modName then
        return false
    end
    
    -- Get mod database entry
    local modData = core_modmanager.getModDB(modName)
    if not modData then
        return false
    end
    
    -- Check if mod is active
    return modData.active == true
end

local function subscribeToAllRequiredMods()
    local allModIds = collectAllRequiredMods()
    
    if #allModIds == 0 then
        return
    end
    
    for _, modId in ipairs(allModIds) do
        -- Check if mod is already installed and active
        if isModAlreadyActive(modId) then
            -- Mod is already active, skip
            log("D", "ModConflictResolver", "Mod " .. modId .. " is already active")
            goto continue
        end
        
        -- Check if mod exists but is not active
        local modName = core_modmanager.getModNameFromID(modId)
        if modName then
            -- Mod exists but is not active, activate it
            log("I", "ModConflictResolver", "Activating existing mod: " .. modId .. " (" .. modName .. ")")
            core_modmanager.activateMod(modName)
        else
            -- Mod doesn't exist, subscribe to it
            log("I", "ModConflictResolver", "Subscribing to mod: " .. modId)
            if core_repository and core_repository.modSubscribe then
                core_repository.modSubscribe(modId)
            end
        end
        
        ::continue::
    end
end

local function onExtensionLoaded()
    log("I", "ModConflictResolver", "ModConflictResolver dependency manager loaded")
    subscribeToAllRequiredMods()
end

-- Identify our parent mod when a non-dependency mod activates
local function onModActivated(modData)
    if ourParentMod then
        return
    end

    if not modData or not modData.modname then
        return
    end
    
    -- Check if this mod has a mod ID (repo mod) or just use the mod name
    local modId = nil
    if modData.modData and modData.modData.tagid then
        modId = modData.modData.tagid
    end
    
    -- If this activated mod is NOT in our dependency list, it must be our parent mod
    if modId and not ourDependencyIds[modId] then
        -- This is not one of our dependencies, so it must be our parent mod
        if not ourParentMod then
            ourParentMod = modData.modname
            log("I", "DependencyManager", "Identified parent mod: " .. ourParentMod .. " (ID: " .. modId .. ")")
        end
    elseif not modId and not ourParentMod then
        -- For non-repo mods, assume first non-dependency mod is our parent
        -- We need to be more careful here to avoid false positives
        ourParentMod = modData.modname
        log("I", "DependencyManager", "Identified parent mod (no repo ID): " .. ourParentMod)
    end
end

-- Clean up dependencies when our parent mod is deactivated
local function onModDeactivated(modData)
    if not modData or not modData.modname then
        return
    end
    
    -- Check if this is our parent mod being deactivated
    if ourParentMod and modData.modname == ourParentMod then
        log("I", "DependencyManager", "Parent mod '" .. ourParentMod .. "' deactivated, cleaning up dependencies")
        
        for modId, _ in pairs(ourDependencyIds) do
            if isModAlreadyActive(modId) then
                if core_modmanager and core_modmanager.deactivateModId then
                    core_modmanager.deactivateModId(modId)
                end
            end
        end
        
        -- Reset our parent mod tracking
        ourParentMod = nil
    end
end

-- Export functions for external use
M.onModDeactivated = onModDeactivated
M.onModActivated = onModActivated
M.getAllRequiredModIds = collectAllRequiredMods
M.subscribeToAllMods = subscribeToAllRequiredMods
M.getParentMod = function() return ourParentMod end
M.onExtensionLoaded = onExtensionLoaded

return M