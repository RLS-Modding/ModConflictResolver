local M = {}

-- Configuration
local MERGE_OUTPUT_DIR = "/mods/unpacked/ModConflictResolutions/"
local SUPPORTED_EXTENSIONS = {".json"}
local DEBUG_LOGGING = true
local RESOLVER_MOUNT_POINT = "/mods/unpacked/ModConflictResolutions/"

-- Active conflicts tracking
local resolvedConflicts = {}
local conflictCounts = {}
local lastResolutionTime = 0
local RESOLUTION_DEBOUNCE_TIME = 2.0 -- seconds

-- Helper function for debug logging
local function debugLog(level, tag, message)
    if DEBUG_LOGGING then
        log(level, tag, message)
    end
end

-- Deep copy function for tables
local function deepcopy(orig)
    local orig_type = type(orig)
    local copy
    if orig_type == 'table' then
        copy = {}
        for orig_key, orig_value in next, orig, nil do
            copy[deepcopy(orig_key)] = deepcopy(orig_value)
        end
        setmetatable(copy, deepcopy(getmetatable(orig)))
    else
        copy = orig
    end
    return copy
end

-- Check if file extension is supported for merging
local function isSupportedFileType(filePath)
    for _, ext in ipairs(SUPPORTED_EXTENSIONS) do
        if string.endswith(filePath:lower(), ext) then
            return true
        end
    end
    return false
end

-- Get all active mods from the mod manager
local function getActiveMods()
    if not core_modmanager then
        debugLog('W', 'ConflictResolver', 'Mod manager not available')
        return {}
    end
    
    local activeMods = {}
    local allMods = core_modmanager.getMods()
    
    if not allMods then
        debugLog('W', 'ConflictResolver', 'No mods found in mod manager')
        return {}
    end
    
    for modName, modData in pairs(allMods) do
        if modData.active then
            activeMods[modName] = modData
        end
    end
    
    debugLog('I', 'ConflictResolver', 'Found ' .. tostring(tableSize(activeMods)) .. ' active mods')
    return activeMods
end

-- Normalize file path to remove double slashes and ensure consistency
local function normalizePath(path)
    if not path then return "" end
    -- Remove double slashes, ensure starts with single slash
    path = path:gsub("\\", "/")  -- Convert backslashes to forward slashes
    path = path:gsub("//+", "/") -- Replace multiple slashes with single slash
    if not path:startswith("/") then
        path = "/" .. path
    end
    return path
end

-- Get all files from a mod
local function getModFiles(modData)
    local files = {}
    
    if not modData then
        return files
    end
    
    debugLog('D', 'ConflictResolver', 'Scanning mod: ' .. modData.modname .. ' (type: ' .. (modData.modType or 'unknown') .. ')')
    
    -- Handle repository mods with hashes
    if modData.modData and modData.modData.hashes then
        debugLog('D', 'ConflictResolver', 'Repository mod with ' .. #modData.modData.hashes .. ' files in manifest')
        for _, hashData in ipairs(modData.modData.hashes) do
            local filePath = normalizePath(hashData[1])
            if isSupportedFileType(filePath) then
                table.insert(files, filePath)
                debugLog('D', 'ConflictResolver', 'Found in manifest: ' .. filePath)
            end
        end
    -- Handle unpacked mods
    elseif modData.unpackedPath and FS:directoryExists(modData.unpackedPath) then
        debugLog('D', 'ConflictResolver', 'Unpacked mod at: ' .. modData.unpackedPath)
        local modFiles = FS:findFiles(modData.unpackedPath, '*', -1, true, false)
        for _, fullPath in ipairs(modFiles) do
            local relativePath = fullPath:gsub(modData.unpackedPath, "")
            relativePath = normalizePath(relativePath)
            if isSupportedFileType(relativePath) then
                table.insert(files, relativePath)
                debugLog('D', 'ConflictResolver', 'Found unpacked: ' .. relativePath)
            end
        end
    -- Handle packed zip mods
    elseif modData.fullpath and FS:fileExists(modData.fullpath) then
        debugLog('D', 'ConflictResolver', 'Packed mod ZIP: ' .. modData.fullpath)
        local zip = ZipArchive()
        if zip:openArchiveName(modData.fullpath, "R") then
            local filesInZip = zip:getFileList()
            debugLog('D', 'ConflictResolver', 'ZIP contains ' .. #filesInZip .. ' files')
            for _, filePath in ipairs(filesInZip) do
                filePath = normalizePath(filePath)
                if isSupportedFileType(filePath) then
                    table.insert(files, filePath)
                    debugLog('D', 'ConflictResolver', 'Found in ZIP: ' .. filePath)
                end
            end
            zip:close()
        else
            debugLog('E', 'ConflictResolver', 'Failed to open zip: ' .. tostring(modData.fullpath))
        end
    end
    
    debugLog('D', 'ConflictResolver', 'Mod ' .. modData.modname .. ' contains ' .. #files .. ' supported files')
    return files
end

-- Check if a file actually exists in a mod (used for validation)
local function fileExistsInMod(filePath, modData)
    filePath = normalizePath(filePath)
    
    -- Handle unpacked mods
    if modData.unpackedPath then
        local fullPath = modData.unpackedPath .. filePath
        return FS:fileExists(fullPath)
    -- Handle packed ZIP mods
    elseif modData.fullpath and FS:fileExists(modData.fullpath) then
        local zip = ZipArchive()
        if zip:openArchiveName(modData.fullpath, "R") then
            local zipEntryPath = filePath:startswith("/") and filePath:sub(2) or filePath
            local filesInZip = zip:getFileList()
            for _, zipFile in ipairs(filesInZip) do
                if zipFile == zipEntryPath or zipFile == filePath then
                    zip:close()
                    return true
                end
            end
            zip:close()
        end
    end
    return false
end

-- Find file conflicts between active mods
local function findFileConflicts()
    local activeMods = getActiveMods()
    local fileToMods = {} -- Maps file paths to list of mods that actually contain them
    local conflicts = {}
    
    -- Build file mapping with validation
    for modName, modData in pairs(activeMods) do
        local modFiles = getModFiles(modData)
        for _, filePath in ipairs(modFiles) do
            -- Validate that the file actually exists in this mod before considering it for conflicts
            if fileExistsInMod(filePath, modData) then
                if not fileToMods[filePath] then
                    fileToMods[filePath] = {}
                end
                table.insert(fileToMods[filePath], {
                    modName = modName,
                    modData = modData
                })
                debugLog('D', 'ConflictResolver', 'Validated file exists: ' .. filePath .. ' in ' .. modName)
            else
                debugLog('D', 'ConflictResolver', 'File listed but not found: ' .. filePath .. ' in ' .. modName .. ' (skipping)')
            end
        end
    end
    
    -- Identify conflicts (files present in multiple mods)
    for filePath, modsList in pairs(fileToMods) do
        if #modsList > 1 then
            conflicts[filePath] = modsList
            local modNames = {}
            for _, modInfo in ipairs(modsList) do
                table.insert(modNames, modInfo.modName)
            end
            debugLog('I', 'ConflictResolver', 'Conflict found: ' .. filePath .. ' in ' .. #modsList .. ' mods (' .. table.concat(modNames, ', ') .. ')')
        end
    end
    
    return conflicts
end

-- Read JSON file directly from a specific mod's source (bypassing virtual file system)
local function readJsonFromMod(filePath, modData)
    filePath = normalizePath(filePath)
    local content = nil
    
    -- Handle unpacked mods - read directly from unpacked directory
    if modData.unpackedPath then
        local fullPath = modData.unpackedPath .. filePath
        if FS:fileExists(fullPath) then
            content = readFile(fullPath)
            debugLog('D', 'ConflictResolver', 'Read from unpacked: ' .. fullPath)
        else
            debugLog('D', 'ConflictResolver', 'File not found in unpacked mod: ' .. fullPath)
        end
    -- Handle packed ZIP mods - read directly from ZIP file
    elseif modData.fullpath and FS:fileExists(modData.fullpath) then
        local zip = ZipArchive()
        if zip:openArchiveName(modData.fullpath, "R") then
            -- Remove leading slash for ZIP file entry lookup
            local zipEntryPath = filePath:startswith("/") and filePath:sub(2) or filePath
            
            -- Try to find the file in the ZIP
            local filesInZip = zip:getFileList()
            local found = false
            for idx, zipFile in ipairs(filesInZip) do
                if zipFile == zipEntryPath or zipFile == filePath then
                    content = zip:readFileEntryByIdx(idx)
                    debugLog('D', 'ConflictResolver', 'Read from ZIP: ' .. modData.fullpath .. ' -> ' .. zipFile .. ' (index: ' .. idx .. ')')
                    found = true
                    break
                end
            end
            if not found then
                debugLog('D', 'ConflictResolver', 'File not found in ZIP: ' .. zipEntryPath .. ' (looked for: ' .. filePath .. ')')
            end
            zip:close()
        else
            debugLog('E', 'ConflictResolver', 'Failed to open ZIP: ' .. modData.fullpath)
        end
    end
    
    if not content then
        debugLog('W', 'ConflictResolver', 'Could not read ' .. filePath .. ' from mod ' .. modData.modname)
        return nil
    end
    
    local success, jsonData = pcall(jsonDecode, content)
    if not success then
        debugLog('E', 'ConflictResolver', 'Failed to parse JSON in ' .. filePath .. ' from mod ' .. modData.modname .. ': ' .. tostring(jsonData))
        return nil
    end
    
    debugLog('D', 'ConflictResolver', 'Successfully parsed JSON from ' .. modData.modname .. ': ' .. filePath)
    return jsonData
end

-- Check if a table is an array (has consecutive integer keys starting from 1)
local function isArray(t)
    if type(t) ~= "table" then return false end
    local count = 0
    for _ in pairs(t) do count = count + 1 end
    for i = 1, count do
        if t[i] == nil then return false end
    end
    return count > 0
end

-- Check if two binding entries are the same (for deduplication)
local function bindingsEqual(a, b)
    if type(a) ~= "table" or type(b) ~= "table" then return false end
    return a.control == b.control and a.action == b.action
end

-- Merge arrays with smart deduplication
local function mergeArrays(baseArray, overlayArray, arrayKey)
    local result = deepcopy(baseArray)
    
    -- For input bindings, we want to concatenate and deduplicate
    if arrayKey == "bindings" then
        for _, overlayItem in ipairs(overlayArray) do
            local isDuplicate = false
            for _, baseItem in ipairs(result) do
                if bindingsEqual(baseItem, overlayItem) then
                    isDuplicate = true
                    break
                end
            end
            if not isDuplicate then
                table.insert(result, overlayItem)
            end
        end
    else
        -- For other arrays, concatenate without deduplication
        for _, item in ipairs(overlayArray) do
            table.insert(result, item)
        end
    end
    
    return result
end

-- Mount the conflict resolver directory to override original mod files
local function mountConflictResolver()
    if FS:directoryExists(RESOLVER_MOUNT_POINT) then
        if not FS:isMounted(RESOLVER_MOUNT_POINT) then
            if FS:mount(RESOLVER_MOUNT_POINT) then
                debugLog('I', 'ConflictResolver', 'Successfully mounted conflict resolver: ' .. RESOLVER_MOUNT_POINT)
                return true
            else
                debugLog('E', 'ConflictResolver', 'Failed to mount conflict resolver: ' .. RESOLVER_MOUNT_POINT)
                return false
            end
        else
            debugLog('D', 'ConflictResolver', 'Conflict resolver already mounted: ' .. RESOLVER_MOUNT_POINT)
            return true
        end
    else
        debugLog('D', 'ConflictResolver', 'Conflict resolver directory does not exist yet: ' .. RESOLVER_MOUNT_POINT)
        return false
    end
end

-- Unmount the conflict resolver directory
local function unmountConflictResolver()
    if FS:isMounted(RESOLVER_MOUNT_POINT) then
        if FS:unmount(RESOLVER_MOUNT_POINT) then
            debugLog('I', 'ConflictResolver', 'Successfully unmounted conflict resolver: ' .. RESOLVER_MOUNT_POINT)
            return true
        else
            debugLog('E', 'ConflictResolver', 'Failed to unmount conflict resolver: ' .. RESOLVER_MOUNT_POINT)
            return false
        end
    end
    return true
end

-- Deep merge two JSON objects
local function mergeJson(base, overlay)
    if type(base) ~= "table" or type(overlay) ~= "table" then
        -- If either is not a table, overlay takes precedence
        return overlay
    end
    
    local result = deepcopy(base)
    
    for key, value in pairs(overlay) do
        if type(value) == "table" and type(result[key]) == "table" then
            -- Check if both are arrays
            if isArray(value) and isArray(result[key]) then
                -- Merge arrays using smart concatenation
                result[key] = mergeArrays(result[key], value, key)
            else
                -- Recursively merge nested objects
                result[key] = mergeJson(result[key], value)
            end
        else
            -- Direct assignment for non-table values or when base doesn't have the key
            result[key] = value
        end
    end
    
    return result
end

-- Merge conflicting JSON files
local function mergeConflictingFiles(filePath, modsList)
    debugLog('I', 'ConflictResolver', 'Merging ' .. #modsList .. ' versions of ' .. filePath)
    
    local mergedJson = nil
    local sourceMods = {}
    
    -- Read and merge all versions
    for _, modInfo in ipairs(modsList) do
        debugLog('D', 'ConflictResolver', 'Reading ' .. filePath .. ' from mod: ' .. modInfo.modName)
        local jsonData = readJsonFromMod(filePath, modInfo.modData)
        if jsonData then
            table.insert(sourceMods, modInfo.modName)
            debugLog('I', 'ConflictResolver', 'Successfully read ' .. filePath .. ' from ' .. modInfo.modName .. ' (' .. #(jsonData.bindings or {}) .. ' bindings)')
            if mergedJson == nil then
                mergedJson = jsonData
            else
                mergedJson = mergeJson(mergedJson, jsonData)
            end
        else
            debugLog('W', 'ConflictResolver', 'Failed to read ' .. filePath .. ' from ' .. modInfo.modName)
        end
    end
    
    if mergedJson == nil then
        debugLog('E', 'ConflictResolver', 'No valid JSON data found for ' .. filePath)
        return false
    end
    
    -- Ensure output directory exists
    local outputPath = MERGE_OUTPUT_DIR .. filePath
    local outputDir = outputPath:match("(.+)/[^/]+$")
    if outputDir and not FS:directoryExists(outputDir) then
        -- Create directory structure (BeamNG should handle this automatically when writing files)
        debugLog('D', 'ConflictResolver', 'Output directory will be created: ' .. outputDir)
    end
    
    -- Write merged file
    local success = jsonWriteFile(outputPath, mergedJson, true)
    if success then
        debugLog('I', 'ConflictResolver', 'Successfully merged ' .. filePath .. ' to ' .. outputPath)
        resolvedConflicts[filePath] = {
            outputPath = outputPath,
            sourceMods = sourceMods,
            mergedAt = os.time()
        }
        return true
    else
        debugLog('E', 'ConflictResolver', 'Failed to write merged file: ' .. outputPath)
        return false
    end
end

-- Main conflict resolution function
local function resolveConflicts(forceRun)
    -- Debounce multiple rapid calls unless forced
    local currentTime = os.time()
    if not forceRun and (currentTime - lastResolutionTime) < RESOLUTION_DEBOUNCE_TIME then
        debugLog('D', 'ConflictResolver', 'Skipping conflict resolution due to debounce (last run ' .. (currentTime - lastResolutionTime) .. 's ago)')
        return {
            success = false,
            message = "Skipped due to debounce",
            resolvedCount = 0,
            totalConflicts = 0
        }
    end
    
    lastResolutionTime = currentTime
    debugLog('I', 'ConflictResolver', 'Starting conflict resolution...')
    
    local conflicts = findFileConflicts()
    local resolvedCount = 0
    local totalConflicts = tableSize(conflicts)
    
    if totalConflicts == 0 then
        debugLog('I', 'ConflictResolver', 'No conflicts found')
        return {
            success = true,
            message = "No conflicts found",
            resolvedCount = 0,
            totalConflicts = 0
        }
    end
    
    debugLog('I', 'ConflictResolver', 'Found ' .. totalConflicts .. ' file conflicts')
    
    -- Resolve each conflict
    for filePath, modsList in pairs(conflicts) do
        if mergeConflictingFiles(filePath, modsList) then
            resolvedCount = resolvedCount + 1
        end
    end
    
    -- Update conflict counts
    conflictCounts = {
        total = totalConflicts,
        resolved = resolvedCount,
        failed = totalConflicts - resolvedCount,
        lastRun = os.time()
    }
    
    local message = string.format("Resolved %d/%d conflicts", resolvedCount, totalConflicts)
    debugLog('I', 'ConflictResolver', message)
    
    -- Mount the conflict resolver to make merged files active
    if resolvedCount > 0 then
        if mountConflictResolver() then
            debugLog('I', 'ConflictResolver', 'Conflict resolver mounted - merged files are now active')
            -- Notify file system of changes
            local changedFiles = {}
            for filePath, conflictInfo in pairs(resolvedConflicts) do
                table.insert(changedFiles, {filename = filePath, type = "modified"})
            end
            if #changedFiles > 0 then
                _G.onFileChanged(changedFiles)
            end
        else
            debugLog('W', 'ConflictResolver', 'Failed to mount conflict resolver - merged files may not be active')
        end
        
        extensions.hook('onModConflictsResolved', {
            resolved = resolvedConflicts,
            counts = conflictCounts
        })
    end
    
    return {
        success = resolvedCount > 0,
        message = message,
        resolvedCount = resolvedCount,
        totalConflicts = totalConflicts,
        conflicts = resolvedConflicts
    }
end

-- Get conflict resolution status
local function getConflictStatus()
    return {
        resolvedConflicts = resolvedConflicts,
        conflictCounts = conflictCounts,
        isEnabled = true
    }
end

-- Clear resolved conflicts (for debugging/reset)
local function clearResolvedConflicts()
    -- Unmount the conflict resolver first
    unmountConflictResolver()
    
    -- Clear the cache
    resolvedConflicts = {}
    conflictCounts = {}
    
    -- Remove the resolver directory if it exists
    if FS:directoryExists(RESOLVER_MOUNT_POINT) then
        FS:remove(RESOLVER_MOUNT_POINT)
        debugLog('I', 'ConflictResolver', 'Removed conflict resolver directory: ' .. RESOLVER_MOUNT_POINT)
    end
    
    debugLog('I', 'ConflictResolver', 'Cleared resolved conflicts cache and unmounted resolver')
end

-- Hook into mod activation/deactivation to auto-resolve conflicts
local function onModActivated(modData)
    debugLog('D', 'ConflictResolver', 'Mod activated: ' .. (modData.modname or 'unknown'))
    -- Delay resolution to allow mod to fully mount
    if core_jobsystem then
        core_jobsystem.create(function(job)
            job.sleep(1.0) -- Wait 1 second for mod to be fully mounted
            resolveConflicts()
        end)
    else
        -- Fallback without job system
        resolveConflicts()
    end
end

local function onModDeactivated(modData)
    debugLog('D', 'ConflictResolver', 'Mod deactivated: ' .. (modData.modname or 'unknown'))
    -- Re-resolve conflicts when mods are deactivated
    if core_jobsystem then
        core_jobsystem.create(function(job)
            job.sleep(0.5)
            resolveConflicts()
        end)
    else
        resolveConflicts()
    end
end

-- Initialize the conflict resolver
local function onExtensionLoaded()
    debugLog('I', 'ConflictResolver', 'ModConflictResolver loaded')
    
    -- Initial conflict resolution
    if core_jobsystem then
        core_jobsystem.create(function(job)
            job.sleep(2.0) -- Wait for other systems to initialize
            resolveConflicts()
        end)
    else
        resolveConflicts()
    end
end

-- Console commands for manual control
local function onConsoleCmd(cmdName, ...)
    if cmdName == "modconflict_resolve" then
        local result = resolveConflicts(true) -- Force resolution
        print("Conflict Resolution Result:")
        print("- Resolved: " .. result.resolvedCount .. "/" .. result.totalConflicts)
        print("- Message: " .. result.message)
        return true
    elseif cmdName == "modconflict_status" then
        local status = getConflictStatus()
        print("ModConflictResolver Status:")
        print("- Resolved conflicts: " .. tableSize(status.resolvedConflicts))
        print("- Last run conflicts: " .. (status.conflictCounts.total or 0))
        print("- Last run resolved: " .. (status.conflictCounts.resolved or 0))
        if status.conflictCounts.lastRun then
            print("- Last run: " .. os.date("%c", status.conflictCounts.lastRun))
        end
        return true
    elseif cmdName == "modconflict_clear" then
        clearResolvedConflicts()
        print("Cleared resolved conflicts cache")
        return true
    elseif cmdName == "modconflict_debug" then
        DEBUG_LOGGING = not DEBUG_LOGGING
        print("Debug logging " .. (DEBUG_LOGGING and "enabled" or "disabled"))
        return true
    elseif cmdName == "modconflict_mount" then
        if mountConflictResolver() then
            print("Conflict resolver mounted successfully")
        else
            print("Failed to mount conflict resolver")
        end
        return true
    elseif cmdName == "modconflict_unmount" then
        if unmountConflictResolver() then
            print("Conflict resolver unmounted successfully")
        else
            print("Failed to unmount conflict resolver")
        end
        return true
    end
    return false
end

-- Public API
M.resolveConflicts = resolveConflicts
M.getConflictStatus = getConflictStatus
M.clearResolvedConflicts = clearResolvedConflicts
M.findFileConflicts = findFileConflicts
M.getActiveMods = getActiveMods
M.mountConflictResolver = mountConflictResolver
M.unmountConflictResolver = unmountConflictResolver
M.onExtensionLoaded = onExtensionLoaded
M.onModActivated = onModActivated
M.onModDeactivated = onModDeactivated
M.onConsoleCmd = onConsoleCmd

return M