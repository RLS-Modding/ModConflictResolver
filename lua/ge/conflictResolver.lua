local M = {}

-- Configuration
local MERGE_OUTPUT_DIR = "/mods/ModConflictResolutions/"
local SUPPORTED_EXTENSIONS = {".json", ".lua"}
local DEBUG_LOGGING = false
local RESOLVER_MOUNT_POINT = "/mods/ModConflictResolutions/"

local resolvedConflicts = {}
local conflictCounts = {}
local lastResolutionTime = 0
local RESOLUTION_DEBOUNCE_TIME = 2.0

local modFileCache = {}
local zipFileListCache = {}
local fileContentCache = {}
local modCacheValidTime = {}
local CACHE_VALIDITY_TIME = 30

local function debugLog(level, tag, message)
    if DEBUG_LOGGING then
        log(level, tag, message)
    end
end

-- Cache management
local function isCacheValid(modName)
    local cacheTime = modCacheValidTime[modName]
    if not cacheTime then return false end
    return (os.time() - cacheTime) < CACHE_VALIDITY_TIME
end

local function updateCacheTime(modName)
    modCacheValidTime[modName] = os.time()
end

local function clearModCache(modName)
    modFileCache[modName] = nil
    modCacheValidTime[modName] = nil
    -- Clear related file content cache entries
    for cacheKey in pairs(fileContentCache) do
        if cacheKey:startswith(modName .. ":") then
            fileContentCache[cacheKey] = nil
        end
    end
end

local function clearAllCaches()
    modFileCache = {}
    zipFileListCache = {}
    fileContentCache = {}
    modCacheValidTime = {}
end

local function tableSizeHelper(t)
    local count = 0
    for _ in pairs(t) do count = count + 1 end
    return count
end

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

local function isSupportedFileType(filePath)
    for _, ext in ipairs(SUPPORTED_EXTENSIONS) do
        if string.endswith(filePath:lower(), ext) then
            return true
        end
    end
    return false
end

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

local function normalizePath(path)
    if not path then return "" end
    -- Convert backslashes and remove double slashes
    path = path:gsub("\\", "/")
    path = path:gsub("//+", "/")
    if not path:startswith("/") then
        path = "/" .. path
    end
    return path
end

-- Batch read multiple files from ZIP to reduce I/O operations
local function batchReadFromZip(zipPath, filePaths)
    local results = {}
    local zip = ZipArchive()
    
    if not zip:openArchiveName(zipPath, "R") then
        log('E', 'ConflictResolver', 'Failed to open ZIP for batch read: ' .. zipPath)
        return results
    end
    
    -- Get or use cached file list
    local filesInZip = zipFileListCache[zipPath]
    if not filesInZip then
        filesInZip = zip:getFileList()
        zipFileListCache[zipPath] = filesInZip
    end
    
    -- Read all requested files
    for _, filePath in ipairs(filePaths) do
        local normalizedPath = normalizePath(filePath)
        local zipEntryPath = normalizedPath:startswith("/") and normalizedPath:sub(2) or normalizedPath
        
        for idx, zipFile in ipairs(filesInZip) do
            if zipFile == zipEntryPath or zipFile == normalizedPath then
                local content = zip:readFileEntryByIdx(idx)
                if content then
                    results[normalizedPath] = content
                end
                break
            end
        end
    end
    
    zip:close()
    return results
end

local function getModFiles(modData, modName)
    if not modData then
        return {}
    end
    
    -- Check cache first
    if modName and isCacheValid(modName) and modFileCache[modName] then
        debugLog('D', 'ConflictResolver', 'Cache hit for mod files: ' .. modName)
        return modFileCache[modName]
    end
    
    local files = {}
    
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
    -- Handle packed ZIP mods
    elseif modData.fullpath and FS:fileExists(modData.fullpath) then
        local zipPath = modData.fullpath
        if not zipFileListCache[zipPath] then
            debugLog('D', 'ConflictResolver', 'Loading ZIP file list for: ' .. zipPath)
            local zip = ZipArchive()
            if zip:openArchiveName(zipPath, "R") then
                zipFileListCache[zipPath] = zip:getFileList()
                zip:close()
            else
                log('E', 'ConflictResolver', 'Failed to open zip: ' .. tostring(zipPath))
                zipFileListCache[zipPath] = {}
            end
        else
            debugLog('D', 'ConflictResolver', 'Using cached ZIP file list for: ' .. zipPath)
        end
        
        for _, filePath in ipairs(zipFileListCache[zipPath]) do
            filePath = normalizePath(filePath)
            if isSupportedFileType(filePath) then
                table.insert(files, filePath)
            end
        end
    end
    
    -- Cache the result
    if modName then
        modFileCache[modName] = files
        updateCacheTime(modName)
    end
    
    return files
end

local function fileExistsInMod(filePath, modData)
    filePath = normalizePath(filePath)
    
    if modData.unpackedPath then
        local fullPath = modData.unpackedPath .. filePath
        return FS:fileExists(fullPath)
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

local function findFileConflicts()
    local activeMods = getActiveMods()
    local fileToMods = {} -- Maps file paths to mods that contain them
    local conflicts = {}
    
    -- Build file mapping with validation
    for modName, modData in pairs(activeMods) do
        local modFiles = getModFiles(modData, modName)
        for _, filePath in ipairs(modFiles) do
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

-- Read file directly from mod source (bypassing VFS)
local function readFileFromMod(filePath, modData, modName)
    filePath = normalizePath(filePath)
    
    -- Check cache first
    local cacheKey = (modName or "unknown") .. ":" .. filePath
    if fileContentCache[cacheKey] then
        debugLog('D', 'ConflictResolver', 'Cache hit for file content: ' .. cacheKey)
        return fileContentCache[cacheKey]
    end
    
    local content = nil
    
    if modData.unpackedPath then
        local fullPath = modData.unpackedPath .. filePath
        if FS:fileExists(fullPath) then
            content = readFile(fullPath)
        end
    elseif modData.fullpath and FS:fileExists(modData.fullpath) then
        local zip = ZipArchive()
        if zip:openArchiveName(modData.fullpath, "R") then
            local zipEntryPath = filePath:startswith("/") and filePath:sub(2) or filePath
            
            local filesInZip = zipFileListCache[modData.fullpath]
            if not filesInZip then
                filesInZip = zip:getFileList()
                zipFileListCache[modData.fullpath] = filesInZip
            end
            
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
    
    if content then
        fileContentCache[cacheKey] = content
    end
    
    return content
end

-- Check if table is an array (consecutive integer keys from 1)
local function isArray(t)
    if type(t) ~= "table" then return false end
    local count = 0
    for _ in pairs(t) do count = count + 1 end
    for i = 1, count do
        if t[i] == nil then return false end
    end
    return count > 0
end

local function bindingsEqual(a, b)
    if type(a) ~= "table" or type(b) ~= "table" then return false end
    return a.control == b.control and a.action == b.action
end

local function mergeArrays(baseArray, overlayArray, arrayKey)
    local result = deepcopy(baseArray)
    
    -- For input bindings, concatenate and deduplicate
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

-- Parse Lua file structure for merging
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
        
        -- Header (comments, empty lines, module declaration)
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
        -- Footer (return statement, etc.)
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

local function mergeLuaFunctionContent(baseFuncContent, overlayFuncContent, functionName)
    if not baseFuncContent then return overlayFuncContent end
    if not overlayFuncContent then return baseFuncContent end
    
    -- For onReset and updateGFX, merge the content
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
                -- Check if this variable assignment already exists
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
        -- For other functions, prefer base version
        return baseFuncContent
    end
end

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
    
    -- Merge exports
    for exportName, exportValue in pairs(baseStructure.exports) do
        merged.exports[exportName] = exportValue
    end
    for exportName, exportValue in pairs(overlayStructure.exports) do
        merged.exports[exportName] = exportValue
    end
    
    return merged
end

local function generateLuaContent(structure)
    local content = structure.header .. "\n\n"
    
    -- Add functions
    for funcName, funcContent in pairs(structure.functions) do
        content = content .. funcContent .. "\n\n"
    end
    
    -- Add exports
    content = content .. "-- public interface\n"
    for exportName, exportValue in pairs(structure.exports) do
        content = content .. "M." .. exportName .. " = " .. exportValue .. "\n"
    end
    
    content = content .. "\n" .. (structure.footer or "return M")
    
    return content
end

local function mergeJson(base, overlay)
    if type(base) ~= "table" or type(overlay) ~= "table" then
        return overlay
    end
    
    local result = deepcopy(base)
    
    for key, value in pairs(overlay) do
        if type(value) == "table" and type(result[key]) == "table" then
            if isArray(value) and isArray(result[key]) then
                result[key] = mergeArrays(result[key], value, key)
            else
                -- Recursively merge nested objects
                result[key] = mergeJson(result[key], value)
            end
        else
            result[key] = value
        end
    end
    
    return result
end

local function mergeConflictingFiles(filePath, modsList)
    local isLuaFile = filePath:lower():endswith('.lua')
    local mergedData = nil
    local sourceMods = {}
    
    -- Group mods by ZIP file for batch processing
    local zipGroups = {}
    local unpackedMods = {}
    
    for _, modInfo in ipairs(modsList) do
        if modInfo.modData.fullpath and FS:fileExists(modInfo.modData.fullpath) then
            local zipPath = modInfo.modData.fullpath
            if not zipGroups[zipPath] then
                zipGroups[zipPath] = {}
            end
            table.insert(zipGroups[zipPath], modInfo)
        else
            table.insert(unpackedMods, modInfo)
        end
    end
    
    -- Process ZIP files in batches
    for zipPath, zipMods in pairs(zipGroups) do
        local filePaths = {}
        for i = 1, #zipMods do
            table.insert(filePaths, filePath)
        end
        
        local batchResults = batchReadFromZip(zipPath, filePaths)
        local fileContent = batchResults[filePath]
        
        if fileContent then
            for _, modInfo in ipairs(zipMods) do
                local cacheKey = modInfo.modName .. ":" .. filePath
                fileContentCache[cacheKey] = fileContent
                
                table.insert(sourceMods, modInfo.modName)
                
                if isLuaFile then
                    local luaStructure = parseLuaFile(fileContent)
                    if mergedData == nil then
                        mergedData = luaStructure
                    else
                        mergedData = mergeLua(mergedData, luaStructure)
                    end
                else
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
    end
    
    -- Process unpacked mods
    for _, modInfo in ipairs(unpackedMods) do
        local fileContent = readFileFromMod(filePath, modInfo.modData, modInfo.modName)
        if fileContent then
            table.insert(sourceMods, modInfo.modName)
            
            if isLuaFile then
                local luaStructure = parseLuaFile(fileContent)
                if mergedData == nil then
                    mergedData = luaStructure
                else
                    mergedData = mergeLua(mergedData, luaStructure)
                end
            else
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
    
    local outputPath = MERGE_OUTPUT_DIR .. filePath
    local outputDir = outputPath:match("(.+)/[^/]+$")
    
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

local function resolveConflicts(forceRun)
    -- Debounce rapid calls unless forced
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
    local totalConflicts = tableSize and tableSize(conflicts) or tableSizeHelper(conflicts)
    
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
    
    conflictCounts = {
        total = totalConflicts,
        resolved = resolvedCount,
        failed = totalConflicts - resolvedCount,
        lastRun = os.time()
    }
    
    local message = string.format("Resolved %d/%d conflicts", resolvedCount, totalConflicts)
    log('I', 'ConflictResolver', message)
    
    -- Mount resolver and notify of changes
    if resolvedCount > 0 then
        if mountConflictResolver() then
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

local function getConflictStatus()
    return {
        resolvedConflicts = resolvedConflicts,
        conflictCounts = conflictCounts,
        isEnabled = true
    }
end

local function clearResolvedConflicts()
    unmountConflictResolver()
    
    resolvedConflicts = {}
    conflictCounts = {}
    
    clearAllCaches()
    
    if FS:directoryExists(RESOLVER_MOUNT_POINT) then
        FS:remove(RESOLVER_MOUNT_POINT)
    end
end

-- Mod activation/deactivation hooks
local function onModActivated(modData)
    if modData and modData.modname then
        clearModCache(modData.modname)
    end
    
    resolveConflicts()
end

local function onModDeactivated(modData)
    if modData and modData.modname then
        clearModCache(modData.modname)
    end
    
    resolveConflicts()
end

-- Public API
M.resolveConflicts = resolveConflicts
M.getConflictStatus = getConflictStatus
M.clearResolvedConflicts = clearResolvedConflicts
M.findFileConflicts = findFileConflicts
M.getActiveMods = getActiveMods
M.mountConflictResolver = mountConflictResolver
M.unmountConflictResolver = unmountConflictResolver
M.onModActivated = onModActivated
M.onModDeactivated = onModDeactivated
M.clearAllCaches = clearAllCaches

M.getCacheStats = function()
    local sizeFn = tableSize or tableSizeHelper
    local stats = {
        modFileCache = sizeFn(modFileCache),
        zipFileListCache = sizeFn(zipFileListCache),
        fileContentCache = sizeFn(fileContentCache),
        totalCacheEntries = 0
    }
    stats.totalCacheEntries = stats.modFileCache + stats.zipFileListCache + stats.fileContentCache
    return stats
end

M.setCacheValidityTime = function(seconds)
    CACHE_VALIDITY_TIME = math.max(10, seconds) -- Minimum 10 seconds
end

M.setDebugLogging = function(enabled)
    DEBUG_LOGGING = enabled
    if enabled then
        log('I', 'ConflictResolver', 'Debug logging enabled')
    end
end

return M
