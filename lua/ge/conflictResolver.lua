local M = {}

-- Configuration
local MERGE_OUTPUT_DIR = "/mods/ModConflictResolutions/"
local SUPPORTED_EXTENSIONS = {".json", ".lua"}
local DEBUG_LOGGING = false
local RESOLVER_MOUNT_POINT = "/mods/ModConflictResolutions/"

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
    local activeMods = {}
    local allMods = core_modmanager.getMods()
    
    if not allMods then
        return {}
    end
    
    for modName, modData in pairs(allMods) do
        if modData.active then
            activeMods[modName] = modData
        end
    end
    
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
    
    -- Handle repository mods with hashes
    if modData.modData and modData.modData.hashes then
        for _, hashData in ipairs(modData.modData.hashes) do
            local filePath = normalizePath(hashData[1])
            if isSupportedFileType(filePath) then
                table.insert(files, filePath)
            end
        end
    -- Handle unpacked mods
    elseif modData.unpackedPath and FS:directoryExists(modData.unpackedPath) then
        local modFiles = FS:findFiles(modData.unpackedPath, '*', -1, true, false)
        for _, fullPath in ipairs(modFiles) do
            local relativePath = fullPath:gsub(modData.unpackedPath, "")
            relativePath = normalizePath(relativePath)
            if isSupportedFileType(relativePath) then
                table.insert(files, relativePath)
            end
        end
    -- Handle packed zip mods
    elseif modData.fullpath and FS:fileExists(modData.fullpath) then
        local zip = ZipArchive()
        if zip:openArchiveName(modData.fullpath, "R") then
            local filesInZip = zip:getFileList()
            for _, filePath in ipairs(filesInZip) do
                filePath = normalizePath(filePath)
                if isSupportedFileType(filePath) then
                    table.insert(files, filePath)
                end
            end
            zip:close()
        else
            log('E', 'ConflictResolver', 'Failed to open zip: ' .. tostring(modData.fullpath))
        end
    end
    
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
            end
        end
    end
    
    -- Identify conflicts (files present in multiple mods)
    for filePath, modsList in pairs(fileToMods) do
        if #modsList > 1 then
            conflicts[filePath] = modsList
        end
    end
    
    return conflicts
end

-- Read file directly from a specific mod's source (bypassing virtual file system)
local function readFileFromMod(filePath, modData)
    filePath = normalizePath(filePath)
    local content = nil
    
    -- Handle unpacked mods - read directly from unpacked directory
    if modData.unpackedPath then
        local fullPath = modData.unpackedPath .. filePath
        if FS:fileExists(fullPath) then
            content = readFile(fullPath)
        end
    -- Handle packed ZIP mods - read directly from ZIP file
    elseif modData.fullpath and FS:fileExists(modData.fullpath) then
        local zip = ZipArchive()
        if zip:openArchiveName(modData.fullpath, "R") then
            -- Remove leading slash for ZIP file entry lookup
            local zipEntryPath = filePath:startswith("/") and filePath:sub(2) or filePath
            
            -- Try to find the file in the ZIP
            local filesInZip = zip:getFileList()
            for idx, zipFile in ipairs(filesInZip) do
                if zipFile == zipEntryPath or zipFile == filePath then
                    content = zip:readFileEntryByIdx(idx)
                    break
                end
            end
            zip:close()
        else
            log('E', 'ConflictResolver', 'Failed to open ZIP: ' .. modData.fullpath)
        end
    end
    
    return content
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
                log('I', 'ConflictResolver', 'Mounted conflict resolver')
                return true
            else
                log('E', 'ConflictResolver', 'Failed to mount conflict resolver')
                return false
            end
        else
            return true
        end
    else
        return false
    end
end

-- Unmount the conflict resolver directory
local function unmountConflictResolver()
    if FS:isMounted(RESOLVER_MOUNT_POINT) then
        if FS:unmount(RESOLVER_MOUNT_POINT) then
            log('I', 'ConflictResolver', 'Unmounted conflict resolver')
            return true
        else
            log('E', 'ConflictResolver', 'Failed to unmount conflict resolver')
            return false
        end
    end
    return true
end

-- Parse Lua file to extract structure
local function parseLuaFile(content)
    local structure = {
        header = "",
        functions = {},
        variables = {},
        exports = {},
        footer = ""
    }
    
    local lines = {}
    for line in content:gmatch("[^\r\n]+") do
        table.insert(lines, line)
    end
    
    local inFunction = nil
    local functionContent = {}
    local i = 1
    
    while i <= #lines do
        local line = lines[i]
        local trimmedLine = line:match("^%s*(.-)%s*$")
        
        -- Skip empty lines and comments at the top (header)
        if not inFunction and (trimmedLine == "" or trimmedLine:startswith("--") or trimmedLine:startswith("local M = {}")) then
            if structure.header == "" then
                structure.header = line
            else
                structure.header = structure.header .. "\n" .. line
            end
        -- Function definition
        elseif trimmedLine:match("^local function (%w+)%(") then
            local funcName = trimmedLine:match("^local function (%w+)%(")
            inFunction = funcName
            functionContent = {line}
        -- End of function
        elseif inFunction and trimmedLine:match("^end%s*$") then
            table.insert(functionContent, line)
            structure.functions[inFunction] = table.concat(functionContent, "\n")
            inFunction = nil
            functionContent = {}
        -- Inside function
        elseif inFunction then
            table.insert(functionContent, line)
        -- Module exports
        elseif trimmedLine:match("^M%.(%w+)%s*=") then
            local exportName = trimmedLine:match("^M%.(%w+)%s*=")
            local exportValue = trimmedLine:match("^M%.%w+%s*=%s*(.+)$")
            structure.exports[exportName] = exportValue
        -- Return statement or other footer content
        elseif trimmedLine:match("^return") or (trimmedLine ~= "" and not trimmedLine:startswith("--")) then
            if structure.footer == "" then
                structure.footer = line
            else
                structure.footer = structure.footer .. "\n" .. line
            end
        end
        
        i = i + 1
    end
    
    return structure
end

-- Merge function content by combining variable assignments
local function mergeLuaFunctionContent(baseFuncContent, overlayFuncContent, functionName)
    if not baseFuncContent then return overlayFuncContent end
    if not overlayFuncContent then return baseFuncContent end
    
    -- For onReset and updateGFX, we want to merge the content
    if functionName == "onReset" or functionName == "updateGFX" then
        local baseLines = {}
        local overlayLines = {}
        
        for line in baseFuncContent:gmatch("[^\r\n]+") do
            local trimmed = line:match("^%s*(.-)%s*$")
            if not (trimmed:startswith("local function") or trimmed == "end" or trimmed == "" or trimmed:startswith("--")) then
                table.insert(baseLines, line)
            end
        end
        
        for line in overlayFuncContent:gmatch("[^\r\n]+") do
            local trimmed = line:match("^%s*(.-)%s*$") 
            if not (trimmed:startswith("local function") or trimmed == "end" or trimmed == "" or trimmed:startswith("--")) then
                -- Check if this variable assignment already exists in base
                local varName = trimmed:match("electrics%.values%[['\"](.-)['\"]%]")
                if varName then
                    local found = false
                    for _, baseLine in ipairs(baseLines) do
                        if baseLine:match("electrics%.values%[['\"]*" .. varName .. "['\"]%]") then
                            found = true
                            break
                        end
                    end
                    if not found then
                        table.insert(baseLines, line)
                    end
                else
                    table.insert(baseLines, line)
                end
            end
        end
        
        -- Reconstruct function
        local funcHeader = baseFuncContent:match("(local function .-%(.-%))")
        local result = funcHeader .. "\n"
        for _, line in ipairs(baseLines) do
            result = result .. line .. "\n"
        end
        result = result .. "end"
        
        return result
    else
        -- For other functions, prefer the base version
        return baseFuncContent
    end
end

-- Merge two Lua file structures
local function mergeLua(baseStructure, overlayStructure)
    local merged = {
        header = baseStructure.header,
        functions = {},
        variables = {},
        exports = {},
        footer = baseStructure.footer
    }
    
    -- Merge functions
    for funcName, funcContent in pairs(baseStructure.functions) do
        merged.functions[funcName] = funcContent
    end
    for funcName, funcContent in pairs(overlayStructure.functions) do
        if merged.functions[funcName] then
            merged.functions[funcName] = mergeLuaFunctionContent(merged.functions[funcName], funcContent, funcName)
        else
            merged.functions[funcName] = funcContent
        end
    end
    
    -- Merge exports (combine all exports)
    for exportName, exportValue in pairs(baseStructure.exports) do
        merged.exports[exportName] = exportValue
    end
    for exportName, exportValue in pairs(overlayStructure.exports) do
        merged.exports[exportName] = exportValue
    end
    
    return merged
end

-- Generate Lua file content from structure
local function generateLuaContent(structure)
    local content = structure.header .. "\n\n"
    
    -- Add functions
    for funcName, funcContent in pairs(structure.functions) do
        content = content .. funcContent .. "\n\n"
    end
    
    -- Add exports section
    content = content .. "-- public interface\n"
    for exportName, exportValue in pairs(structure.exports) do
        content = content .. "M." .. exportName .. " = " .. exportValue .. "\n"
    end
    
    content = content .. "\n" .. (structure.footer or "return M")
    
    return content
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

-- Merge conflicting files (JSON or Lua)
local function mergeConflictingFiles(filePath, modsList)
    local isLuaFile = filePath:lower():endswith('.lua')
    local mergedData = nil
    local sourceMods = {}
    
    -- Read and merge all versions
    for _, modInfo in ipairs(modsList) do
        local fileContent = readFileFromMod(filePath, modInfo.modData)
        if fileContent then
            table.insert(sourceMods, modInfo.modName)
            
            if isLuaFile then
                -- Parse Lua file
                local luaStructure = parseLuaFile(fileContent)
                if mergedData == nil then
                    mergedData = luaStructure
                else
                    mergedData = mergeLua(mergedData, luaStructure)
                end
            else
                -- Parse JSON file
                local success, jsonData = pcall(jsonDecode, fileContent)
                if success then
                    if mergedData == nil then
                        mergedData = jsonData
                    else
                        mergedData = mergeJson(mergedData, jsonData)
                    end
                else
                    log('E', 'ConflictResolver', 'Failed to parse JSON in ' .. filePath .. ' from mod ' .. modInfo.modName)
                end
            end
        end
    end
    
    if mergedData == nil then
        log('E', 'ConflictResolver', 'No valid data found for ' .. filePath)
        return false
    end
    
    -- Ensure output directory exists
    local outputPath = MERGE_OUTPUT_DIR .. filePath
    local outputDir = outputPath:match("(.+)/[^/]+$")
    
    -- Write merged file
    local success = false
    if isLuaFile then
        local luaContent = generateLuaContent(mergedData)
        success = writeFile(outputPath, luaContent)
    else
        success = jsonWriteFile(outputPath, mergedData, true)
    end
    
    if success then
        resolvedConflicts[filePath] = {
            outputPath = outputPath,
            sourceMods = sourceMods,
            mergedAt = os.time()
        }
        return true
    else
        log('E', 'ConflictResolver', 'Failed to write merged file: ' .. outputPath)
        return false
    end
end

-- Main conflict resolution function
local function resolveConflicts(forceRun)
    -- Debounce multiple rapid calls unless forced
    local currentTime = os.time()
    if not forceRun and (currentTime - lastResolutionTime) < RESOLUTION_DEBOUNCE_TIME then
        return {
            success = false,
            message = "Skipped due to debounce",
            resolvedCount = 0,
            totalConflicts = 0
        }
    end
    
    lastResolutionTime = currentTime
    
    local conflicts = findFileConflicts()
    local resolvedCount = 0
    local totalConflicts = tableSize(conflicts)
    
    if totalConflicts == 0 then
        return {
            success = true,
            message = "No conflicts found",
            resolvedCount = 0,
            totalConflicts = 0
        }
    end
    
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
    log('I', 'ConflictResolver', message)
    
    -- Mount the conflict resolver to make merged files active
    if resolvedCount > 0 then
        if mountConflictResolver() then
            -- Notify file system of changes
            local changedFiles = {}
            for filePath, conflictInfo in pairs(resolvedConflicts) do
                table.insert(changedFiles, {filename = filePath, type = "modified"})
            end
            if #changedFiles > 0 then
                _G.onFileChanged(changedFiles)
            end
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
    end
end

-- Hook into mod activation/deactivation to auto-resolve conflicts
local function onModActivated(modData)
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

return M
