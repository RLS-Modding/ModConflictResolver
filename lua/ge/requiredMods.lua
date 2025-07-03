local M = {}

-- Track our parent mod
local ourParentMod = nil
local ourDependencyIds = {}

local modsToSubscribe = {}
local activeDownloads = {}

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

-- Batch activate multiple mods efficiently
local function batchActivateMods(modNames)
    if not modNames or #modNames == 0 then
        return
    end
    
    local allMods = core_modmanager.getMods()
    local mountList = {}
    local allMountedFilesChange = {}
    local allModScripts = {}
    local activatedMods = {}
    
    -- Phase 1: Check existence and prepare mounting
    for _, modName in ipairs(modNames) do
        if allMods[modName] then
            local modData = allMods[modName]
            if not modData.active then
                log("I", "ModConflictResolver", "Batch activating mod: " .. modName)
                
                -- Add to mount list if not already mounted
                if not FS:isMounted(modData.fullpath) then
                    local mountEntry = {
                        srcPath = modData.fullpath,
                        mountPath = modData.mountPoint or ""
                    }
                    table.insert(mountList, mountEntry)
                end
                
                -- Collect file change notifications (simplified version)
                if modData.modData and modData.modData.hashes then
                    for _, hashData in ipairs(modData.modData.hashes) do
                        table.insert(allMountedFilesChange, {
                            filename = "/" .. hashData[1]:gsub("\\", ""),
                            type = "added"
                        })
                    end
                end
                
                -- Collect mod scripts (simplified version)
                if modData.modData and modData.modData.hashes then
                    for _, hashData in ipairs(modData.modData.hashes) do
                        local filePath = "/" .. hashData[1]:gsub("\\", "")
                        if (filePath:find("/scripts/") or filePath:find("/mods_data/")) and filePath:find("/modScript.lua") then
                            table.insert(allModScripts, filePath)
                        end
                    end
                end
                
                table.insert(activatedMods, modData)
            end
        else
            log("W", "ModConflictResolver", "Mod not found for batch activation: " .. modName)
        end
    end
    
    -- Phase 2: Mount all mods at once
    if #mountList > 0 then
        if not FS:mountList(mountList) then
            log("E", "ModConflictResolver", "Failed to mount mods in batch")
            return
        end
    end
    
    -- Phase 3: Execute all mod scripts
    for _, scriptPath in ipairs(allModScripts) do
        local status, ret = pcall(dofile, scriptPath)
        if not status then
            log("E", "ModConflictResolver", "Failed to execute mod script: " .. scriptPath)
            log("E", "ModConflictResolver", tostring(ret))
        end
    end
    
    -- Phase 4: Set all mods as active and trigger hooks
    for _, modData in ipairs(activatedMods) do
        modData.active = true
    end
    
    -- Create comprehensive merged modData with all hashes and properties
    if #activatedMods > 0 then
        local mergedHashes = {}
        local mergedModNames = {}
        local mergedModIDs = {}
        local mergedFilePaths = {}
        
        -- Combine all mod data
        for _, modData in ipairs(activatedMods) do
            table.insert(mergedModNames, modData.modname or "unknown")
            
            if modData.modID then
                table.insert(mergedModIDs, modData.modID)
            end
            
            if modData.fullpath then
                table.insert(mergedFilePaths, modData.fullpath)
            end
            
            -- Merge all hashes from this mod
            if modData.modData and modData.modData.hashes then
                for _, hashData in ipairs(modData.modData.hashes) do
                    table.insert(mergedHashes, hashData)
                end
            end
        end
        
        -- Create combined modData structure
        local combinedModData = {
            modname = "BatchActivation_" .. table.concat(mergedModNames, "_"),
            modID = table.concat(mergedModIDs, "_"),
            fullpath = mergedFilePaths,
            active = true,
            batch = true,
            count = #activatedMods,
            originalMods = activatedMods,
            modData = {
                hashes = mergedHashes,
                tagid = table.concat(mergedModIDs, "_"),
                batch_activation = true
            }
        }
        
        extensions.hook('onModActivated', deepcopy(combinedModData))
    end
    
    -- Phase 5: Final cleanup (do expensive operations once)
    if #allMountedFilesChange > 0 then
        _G.onFileChanged(allMountedFilesChange)
    end
    
    -- Load manual unload extensions
    loadManualUnloadExtensions()
end

-- Batch deactivate multiple mods efficiently
local function batchDeactivateMods(modIdentifiers)
    if not modIdentifiers or #modIdentifiers == 0 then
        return
    end
    
    local allMods = core_modmanager.getMods()
    local allMountedFilesChange = {}
    local deactivatedMods = {}
    
    -- Phase 1: Check existence and prepare for unmounting
    for _, identifier in ipairs(modIdentifiers) do
        local modName = identifier
        
        -- Handle mod IDs by converting to mod names
        if not allMods[identifier] then
            modName = core_modmanager.getModNameFromID(identifier)
        end
        
        if modName and allMods[modName] then
            local modData = allMods[modName]
            if modData.active then
                log("I", "ModConflictResolver", "Batch deactivating mod: " .. modName)
                
                -- Collect file change notifications (simplified version)
                if modData.modData and modData.modData.hashes then
                    for _, hashData in ipairs(modData.modData.hashes) do
                        table.insert(allMountedFilesChange, {
                            filename = "/" .. hashData[1]:gsub("\\", ""),
                            type = "deleted"
                        })
                    end
                end
                
                table.insert(deactivatedMods, {name = modName, data = modData})
            end
        else
            log("W", "ModConflictResolver", "Mod not found for batch deactivation: " .. tostring(identifier))
        end
    end
    
    -- Phase 2: Unmount all mods
    for _, mod in ipairs(deactivatedMods) do
        if FS:isMounted(mod.data.fullpath) then
            if not FS:unmount(mod.data.fullpath) then
                log("E", "ModConflictResolver", "Failed to unmount mod: " .. mod.name)
            end
        end
    end
    
    -- Phase 3: Set all mods as inactive and trigger hooks
    for _, mod in ipairs(deactivatedMods) do
        mod.data.active = false
    end
    
    -- Create comprehensive merged modData for batch deactivation
    if #deactivatedMods > 0 then
        local mergedHashes = {}
        local mergedModNames = {}
        local mergedModIDs = {}
        local mergedFilePaths = {}
        local originalMods = {}
        
        -- Combine all mod data
        for _, mod in ipairs(deactivatedMods) do
            table.insert(mergedModNames, mod.data.modname or "unknown")
            table.insert(originalMods, mod.data)
            
            if mod.data.modID then
                table.insert(mergedModIDs, mod.data.modID)
            end
            
            if mod.data.fullpath then
                table.insert(mergedFilePaths, mod.data.fullpath)
            end
            
            -- Merge all hashes from this mod
            if mod.data.modData and mod.data.modData.hashes then
                for _, hashData in ipairs(mod.data.modData.hashes) do
                    table.insert(mergedHashes, hashData)
                end
            end
        end
        
        -- Create combined modData structure
        local combinedModData = {
            modname = "BatchDeactivation_" .. table.concat(mergedModNames, "_"),
            modID = table.concat(mergedModIDs, "_"),
            fullpath = mergedFilePaths,
            active = false,
            batch = true,
            count = #deactivatedMods,
            originalMods = originalMods,
            modData = {
                hashes = mergedHashes,
                tagid = table.concat(mergedModIDs, "_"),
                batch_deactivation = true
            }
        }
        
        extensions.hook('onModDeactivated', deepcopy(combinedModData))
    end
    
    -- Phase 4: Final cleanup (do expensive operations once)
    if #allMountedFilesChange > 0 then
        _G.onFileChanged(allMountedFilesChange)
    end
    
    log("I", "ModConflictResolver", "Batch deactivation completed for " .. #deactivatedMods .. " mods")
end

local function downloadMods()
    if #modsToSubscribe > 0 then
        while #modsToSubscribe > 0 and #activeDownloads <= 2 do
            local modId = modsToSubscribe[1]  -- Get first mod from the list
            table.remove(modsToSubscribe, 1)  -- Remove it from the list
            
            log("I", "ModConflictResolver", "Subscribing to mod: " .. modId)
            if core_repository and core_repository.modSubscribe then
                core_repository.modSubscribe(modId)
            end
            table.insert(activeDownloads, modId)
        end
    else
        log("I", "ModConflictResolver", "Phase 2: No mods to subscribe to")
    end
end

local function subscribeToAllRequiredMods()
    local allModIds = collectAllRequiredMods()
    
    if #allModIds == 0 then
        return
    end
    -- Separate existing mods from mods that need subscription
    local modsToActivate = {}
    
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
            -- Mod exists but is not active, add to batch activation list
            table.insert(modsToActivate, modName)
        else
            -- Mod doesn't exist, add to subscription list
            table.insert(modsToSubscribe, modId)
        end
        
        ::continue::
    end
    
    -- Batch activate all existing mods at once
    if #modsToActivate > 0 then
        log("I", "ModConflictResolver", "Batch activating " .. #modsToActivate .. " existing mods")
        batchActivateMods(modsToActivate)
    end

    downloadMods()
end

local function onExtensionLoaded()
    log("I", "ModConflictResolver", "ModConflictResolver dependency manager loaded")
    subscribeToAllRequiredMods()
end

-- Identify our parent mod when a non-dependency mod activates
local function onModActivated(modData)
    print("onModActivated " .. tostring(modData.modname))
    
    if not modData or not modData.modname then
        return
    end
    
    -- Skip batch events for parent mod detection
    if modData.modname and (modData.modname:find("BatchActivation_") or modData.modname:find("BatchDeactivation_")) then
        return
    end
    
    -- Check if this mod has a mod ID (repo mod) or just use the mod name
    local modId = nil
    if modData.modData and modData.modData.tagid then
        modId = modData.modData.tagid
    end
    
    -- Check if this activated mod was one we were downloading
    if modId then
        for i, activeModId in ipairs(activeDownloads) do
            if activeModId == modId then
                -- Remove this mod from active downloads
                table.remove(activeDownloads, i)
                log("I", "ModConflictResolver", "Mod " .. modId .. " finished downloading and activated")
                
                -- Continue downloading more mods if there are any in the queue
                if #modsToSubscribe > 0 then
                    log("I", "ModConflictResolver", "Continuing downloads: " .. #modsToSubscribe .. " mods remaining")
                    downloadMods()
                end
                break
            end
        end
    end
    
    -- Parent mod identification logic
    if ourParentMod then
        return
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
        
        -- Collect all active dependency IDs for batch deactivation
        local activeDependencies = {}
        for modId, _ in pairs(ourDependencyIds) do
            if isModAlreadyActive(modId) then
                table.insert(activeDependencies, modId)
            end
        end
        
        -- Batch deactivate all dependencies at once
        if #activeDependencies > 0 then
            batchDeactivateMods(activeDependencies)
        end
        
        -- Reset our parent mod tracking
        ourParentMod = nil
    end
end

-- Export functions for external use
M.onModDeactivated = onModDeactivated
M.onModActivated = onModActivated
M.batchActivateMods = batchActivateMods
M.batchDeactivateMods = batchDeactivateMods
M.getAllRequiredModIds = collectAllRequiredMods
M.subscribeToAllMods = subscribeToAllRequiredMods
M.getParentMod = function() return ourParentMod end
M.onExtensionLoaded = onExtensionLoaded

return M