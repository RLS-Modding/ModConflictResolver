local M = {}

local MERGE_OUTPUT_DIR = "/mods/ModConflictResolutions/"
local SUPPORTED_EXTENSIONS = {".json", ".lua", ".forest4", ".level", ".prefab", ".jbeam", ".jsonl"}
local RESOLVER_MOUNT_POINT = "/mods/ModConflictResolutions/"
local RESOLUTION_DEBOUNCE_TIME = 2.0
local MANIFEST_DIR = "/mods/mod_manifests/"
local JSON_DETECTION_SAMPLE_SIZE = 4096

local resolvedConflicts = {}
local conflictCounts = {}
local lastResolutionTime = 0

local modFileCache = {}
local zipFileListCache = {}
local fileContentCache = {}
local pathInternCache = {}

local function tableSize(t)
    if _G.tableSize then
        return _G.tableSize(t)
    end
    local count = 0
    for _ in pairs(t) do
        count = count + 1
    end
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

local function normalizePath(path)
    if not path then return "" end
    path = path:gsub("\\", "/")
    path = path:gsub("//+", "/")
    if not path:startswith("/") then
        path = "/" .. path
    end
    return path
end

local function internPath(path)
    if pathInternCache[path] then
        return pathInternCache[path]
    end
    pathInternCache[path] = path
    return path
end

local function sanitizeModName(modName)
    if not modName then return "unknown" end
    local sanitized = modName:gsub("[%s/<>:\"|?*\\]", "_")
    sanitized = sanitized:gsub("_+", "_")
    sanitized = sanitized:gsub("^_+", ""):gsub("_+$", "")
    return sanitized
end

local function isSupportedFileType(filePath)
    for _, ext in ipairs(SUPPORTED_EXTENSIONS) do
        if string.endswith(filePath:lower(), ext) then
            return true
        end
    end
    return false
end

local function isArray(t)
    if type(t) ~= "table" then return false end
    local count = 0
    for _ in pairs(t) do count = count + 1 end
    for i = 1, count do
        if t[i] == nil then return false end
    end
    return count > 0
end

local function getModTimestamp(modData)
    if not modData then return 0 end

    if modData.fullpath and FS:fileExists(modData.fullpath) then
        return FS:stat(modData.fullpath).modtime or 0
    elseif modData.unpackedPath and FS:directoryExists(modData.unpackedPath) then
        local latestTime = 0
        local modFiles = FS:findFiles(modData.unpackedPath, '*', -1, true, false)
        for _, fullPath in ipairs(modFiles) do
            local stat = FS:stat(fullPath)
            if stat and stat.modtime and stat.modtime > latestTime then
                latestTime = stat.modtime
            end
        end
        return latestTime
    end
    
    return 0
end

local function manifestIsStale(modData, manifestPath)
    if not FS:fileExists(manifestPath) then
        return true
    end
    local manifestStat = FS:stat(manifestPath)
    if not manifestStat or not manifestStat.modtime then
        return true
    end
    
    local modTimestamp = getModTimestamp(modData)
    return modTimestamp > manifestStat.modtime
end

local function getZipFileMap(zipPath)
    if zipFileListCache[zipPath] then
        return zipFileListCache[zipPath]
    end

    local zip = ZipArchive()
    if zip:openArchiveName(zipPath, "R") then
        local fileList = zip:getFileList()
        local fileMap = {}
        for i, f in ipairs(fileList) do
            fileMap[f] = i
        end
        zipFileListCache[zipPath] = fileMap
        zip:close()
    else
        log('E', 'ConflictResolver', 'Failed to open zip: ' .. tostring(zipPath))
        zipFileListCache[zipPath] = {}
    end
    return zipFileListCache[zipPath]
end

local function buildManifest(modData, manifestPath, modName)
    local files = {}
    local startTime = os.time()
    
    if modData.modData and modData.modData.hashes then
        for _, hashData in ipairs(modData.modData.hashes) do
            local filePath = normalizePath(hashData[1])
            if isSupportedFileType(filePath) then
                table.insert(files, internPath(filePath))
            end
        end
    elseif modData.unpackedPath and FS:directoryExists(modData.unpackedPath) then
        local modFiles = FS:findFiles(modData.unpackedPath, '*', -1, true, false)
        for _, fullPath in ipairs(modFiles) do
            local relativePath = fullPath:gsub(modData.unpackedPath, "")
            relativePath = normalizePath(relativePath)
            if isSupportedFileType(relativePath) then
                table.insert(files, internPath(relativePath))
            end
        end
    elseif modData.fullpath and FS:fileExists(modData.fullpath) then
        local zipFileMap = getZipFileMap(modData.fullpath)
        for filePath, _ in pairs(zipFileMap) do
            local normalized = normalizePath(filePath)
            if isSupportedFileType(normalized) then
                table.insert(files, internPath(normalized))
            end
        end
    end
    
    local manifest = {
        scanned = startTime,
        count = #files,
        files = files
    }
    
    if not FS:directoryExists(MANIFEST_DIR) then
        FS:directoryCreate(MANIFEST_DIR, true)
    end
    
    local success = jsonWriteFile(manifestPath, manifest, true)
    
    if success then
        log('I', 'ConflictResolver', 'Built manifest for ' .. (modName or 'unknown') .. ' with ' .. #files .. ' files')
    else
        log('E', 'ConflictResolver', 'Failed to write manifest: ' .. manifestPath)
    end
    
    return manifest
end

local function loadManifestList(modData, modName)
    if not modData or not modName then
        return {}
    end
    
    local sanitizedName = sanitizeModName(modName)
    local manifestPath = MANIFEST_DIR .. sanitizedName .. ".json"
    
    if manifestIsStale(modData, manifestPath) then
        local manifest = buildManifest(modData, manifestPath, modName)
        return manifest.files or {}
    else
        local manifest = jsonReadFile(manifestPath)
        if manifest and manifest.files then
            return manifest.files
        else
            log('W', 'ConflictResolver', 'Invalid manifest file, rebuilding: ' .. manifestPath)
            local newManifest = buildManifest(modData, manifestPath, modName)
            return newManifest.files or {}
        end
    end
end

local function clearModCache(modName)
    modFileCache[modName] = nil
    for cacheKey in pairs(fileContentCache) do
        if cacheKey:startswith(modName .. ":") then
            fileContentCache[cacheKey] = nil
        end
    end
    
    if modName then
        local sanitizedName = sanitizeModName(modName)
        local manifestPath = MANIFEST_DIR .. sanitizedName .. ".json"
        if FS:fileExists(manifestPath) then
            FS:remove(manifestPath)
        end
    end
end

local function clearAllCaches()
    modFileCache = {}
    zipFileListCache = {}
    fileContentCache = {}
    pathInternCache = {}
    
    if FS:directoryExists(MANIFEST_DIR) then
        local manifestFiles = FS:findFiles(MANIFEST_DIR, '*.json', 0, true, false)
        for _, manifestPath in ipairs(manifestFiles) do
            FS:remove(manifestPath)
        end
    end
end

local function getCacheStats()
    local stats = {
        modFileCache = tableSize(modFileCache),
        zipFileListCache = tableSize(zipFileListCache),
        fileContentCache = tableSize(fileContentCache),
        pathInternCache = tableSize(pathInternCache),
        totalCacheEntries = 0
    }
    stats.totalCacheEntries = stats.modFileCache + stats.zipFileListCache + stats.fileContentCache + stats.pathInternCache
    
    if FS:directoryExists(MANIFEST_DIR) then
        local manifestFiles = FS:findFiles(MANIFEST_DIR, '*.json', 0, true, false)
        stats.manifestFiles = #manifestFiles
        stats.totalCacheEntries = stats.totalCacheEntries + stats.manifestFiles
    else
        stats.manifestFiles = 0
    end
    
    return stats
end

local function batchReadFromZip(zipPath, filePaths)
    local results = {}
    local zipFileMap = getZipFileMap(zipPath)
    if tableSize(zipFileMap) == 0 then
        return results
    end

    local zip = ZipArchive()
    if not zip:openArchiveName(zipPath, "R") then
        log('E', 'ConflictResolver', 'Failed to open ZIP for batch read: ' .. zipPath)
        return results
    end

    for _, filePath in ipairs(filePaths) do
        local normalizedPath = normalizePath(filePath)
        local zipEntryPath = normalizedPath:startswith("/") and normalizedPath:sub(2) or normalizedPath
        
        local fileIndex = zipFileMap[zipEntryPath] or zipFileMap[normalizedPath]
        if fileIndex then
            local content = zip:readFileEntryByIdx(fileIndex)
            if content then
                results[normalizedPath] = content
            end
        end
    end

    zip:close()
    return results
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

local function getModFiles(modData, modName)
    if not modData then
        return {}
    end
    
    if modName and modFileCache[modName] then
        return modFileCache[modName]
    end
    
    local files = loadManifestList(modData, modName)
    
    if modName then
        modFileCache[modName] = files
    end
    
    return files
end

local function fileExistsInMod(filePath, modData)
    filePath = normalizePath(filePath)
    
    if modData.unpackedPath then
        local fullPath = modData.unpackedPath .. filePath
        return FS:fileExists(fullPath)
    elseif modData.fullpath and FS:fileExists(modData.fullpath) then
        local zipFileMap = getZipFileMap(modData.fullpath)
        local zipEntryPath = filePath:startswith("/") and filePath:sub(2) or filePath
        return zipFileMap[zipEntryPath] ~= nil or zipFileMap[filePath] ~= nil
    end
    return false
end

local function readFileFromMod(filePath, modData, modName)
    filePath = normalizePath(filePath)
    
    local cacheKey = (modName or "unknown") .. ":" .. filePath
    if fileContentCache[cacheKey] then
        return fileContentCache[cacheKey]
    end
    
    local content = nil
    
    if modData.unpackedPath then
        local fullPath = modData.unpackedPath .. filePath
        if FS:fileExists(fullPath) then
            content = readFile(fullPath)
        end
    elseif modData.fullpath and FS:fileExists(modData.fullpath) then
        local zipFileMap = getZipFileMap(modData.fullpath)
        local zipEntryPath = filePath:startswith("/") and filePath:sub(2) or filePath
        local fileIndex = zipFileMap[zipEntryPath] or zipFileMap[filePath]

        if fileIndex then
            local zip = ZipArchive()
            if zip:openArchiveName(modData.fullpath, "R") then
                content = zip:readFileEntryByIdx(fileIndex)
                zip:close()
            else
                log('E', 'ConflictResolver', 'Failed to open ZIP: ' .. modData.fullpath)
            end
        end
    end
    
    if content then
        fileContentCache[cacheKey] = content
    end
    
    return content
end

local function mountConflictResolver()
    if FS:directoryExists(RESOLVER_MOUNT_POINT) then
        if not FS:isMounted(RESOLVER_MOUNT_POINT) then
            if FS:mount(RESOLVER_MOUNT_POINT) then
                return true
            else
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
            return true
        else
            return false
        end
    end
    return true
end

local function clearMergeOutputDirectory()
    if FS:directoryExists(MERGE_OUTPUT_DIR) then
        FS:remove(MERGE_OUTPUT_DIR)
    end
end

local function detectJsonFormat(content, filePath)
    if not content or content == "" then
        return false
    end
    
    local sampleSize = math.min(#content, JSON_DETECTION_SAMPLE_SIZE)
    local sample = content:sub(1, sampleSize)
    
    local braceDepth = 0
    local objectCount = 0
    local inString = false
    local escapeNext = false
    
    for i = 1, #sample do
        local char = sample:sub(i, i)
        
        if escapeNext then
            escapeNext = false
        elseif char == "\\" and inString then
            escapeNext = true
        elseif char == '"' then
            inString = not inString
        elseif not inString then
            if char == "{" then
                braceDepth = braceDepth + 1
            elseif char == "}" then
                braceDepth = braceDepth - 1
                if braceDepth == 0 then
                    objectCount = objectCount + 1
                    if objectCount > 1 then
                        return true
                    end
                end
            end
        end
    end
    
    return objectCount > 1
end

local function parseJsonContent(content, filePath, modName)
    local objects = {}
    
    if not content or content == "" then
        return objects
    end
    
    if detectJsonFormat(content, filePath) then
        for line in content:gmatch("[^\r\n]+") do
            local trimmedLine = line:match("^%s*(.-)%s*$")
            
            if trimmedLine ~= "" then
                local success, jsonObj = pcall(jsonDecode, trimmedLine)
                if success and type(jsonObj) == "table" then
                    table.insert(objects, jsonObj)
                end
            end
        end
    else
        local success, jsonObj = pcall(jsonDecode, content)
        if success and type(jsonObj) == "table" then
            table.insert(objects, jsonObj)
        end
    end
    
    return objects
end

local function generateUniqueKey(obj)
        local idKeys = {"persistentId", "id", "uuid", "guid"}
    local nameKeys = {"name", "title", "label"}
    local positionKeys = {"position", "pos", "location", "transform"}
    local rotationKeys = {"rotationMatrix", "rotation", "rot", "orientation"}
    local typeKeys = {"type", "class", "category", "kind"}
    local parentKeys = {"__parent", "parent", "parentId"}
    
    local keyParts = {}
    
    local foundId = nil
    for _, key in ipairs(idKeys) do
        if obj[key] then
            foundId = tostring(obj[key])
            break
        end
    end
    
    local foundName = nil
    for _, key in ipairs(nameKeys) do
        if obj[key] then
            foundName = tostring(obj[key])
            break
        end
    end
    
    if foundId and foundName then
        table.insert(keyParts, foundId .. ":" .. foundName)
    elseif foundId then
        table.insert(keyParts, foundId)
    elseif foundName then
        table.insert(keyParts, foundName)
    end
    
    if #keyParts == 0 then
        for _, key in ipairs(typeKeys) do
            if obj[key] then
                table.insert(keyParts, tostring(obj[key]))
                break
            end
        end
        
        for _, key in ipairs(parentKeys) do
            if obj[key] then
                table.insert(keyParts, tostring(obj[key]))
                break
            end
        end
        
        for _, key in ipairs(positionKeys) do
            if obj[key] and type(obj[key]) == "table" then
                local pos = obj[key]
                local posStr = string.format("%.6f,%.6f,%.6f", 
                    pos[1] or pos.x or 0, 
                    pos[2] or pos.y or 0, 
                    pos[3] or pos.z or 0)
                table.insert(keyParts, posStr)
                break
            end
        end
        
        for _, key in ipairs(rotationKeys) do
            if obj[key] then
                if type(obj[key]) == "table" then
                    local rot = obj[key]
                    if #rot >= 3 then
                        local rotStr = string.format("%.3f,%.3f,%.3f", rot[1] or 0, rot[2] or 0, rot[3] or 0)
                        table.insert(keyParts, rotStr)
                    end
                else
                    table.insert(keyParts, tostring(obj[key]))
                end
                break
            end
        end
        
        if obj.shapeName then
            table.insert(keyParts, tostring(obj.shapeName))
        end
    end
    
    if #keyParts == 0 then
        return jsonEncode(obj)
    end
    
    return table.concat(keyParts, ":")
end

local function mergeJsonLines(allObjects, filePath)
    local mergedObjects = {}
    local seenObjects = {}
    
    for _, obj in ipairs(allObjects) do
        local uniqueKey = generateUniqueKey(obj)
        
        if not seenObjects[uniqueKey] then
            seenObjects[uniqueKey] = true
            table.insert(mergedObjects, obj)
        end
    end
    
    return mergedObjects
end

local function mergeSingleJsonObjects(base, overlay, filePath)
    if type(base) ~= "table" or type(overlay) ~= "table" then
        return overlay
    end
    
    local result = {}
    
    for key, value in pairs(base) do
        if type(value) == "table" then
            result[key] = mergeSingleJsonObjects(value, {}, filePath) -- Deep copy
        else
            result[key] = value
        end
    end
    
    for key, value in pairs(overlay) do
        if type(value) == "table" and type(result[key]) == "table" then
            result[key] = mergeSingleJsonObjects(result[key], value, filePath)
        else
            result[key] = value
        end
    end
    
    return result
end

local function analyzeKeyOrder(allObjects)
    local keyFirstSeen = {}
    
    local sampleSize = math.min(10, #allObjects)
    for i = 1, sampleSize do
        local obj = allObjects[i]
        if type(obj) == "table" then
            local order = 0
            for key, _ in pairs(obj) do
                if not keyFirstSeen[key] then
                    keyFirstSeen[key] = order
                    order = order + 1
                end
            end
        end
    end
    
    local sortedKeys = {}
    for key, order in pairs(keyFirstSeen) do
        table.insert(sortedKeys, {key = key, order = order})
    end
    table.sort(sortedKeys, function(a, b) return a.order < b.order end)
    
    local keyOrder = {}
    for _, item in ipairs(sortedKeys) do
        table.insert(keyOrder, item.key)
    end
    
    return keyOrder
end

local function encodeJsonWithOrder(obj, keyOrder)
    if type(obj) ~= "table" then
        return jsonEncode(obj)
    end
    
    keyOrder = keyOrder or {}
    local parts = {}
    local seenKeys = {}
    
    for _, key in ipairs(keyOrder) do
        if obj[key] ~= nil then
            local valueStr = jsonEncode(obj[key])
            table.insert(parts, string.format('"%s":%s', key, valueStr))
            seenKeys[key] = true
        end
    end
    
    local remainingKeys = {}
    for key in pairs(obj) do
        if not seenKeys[key] then
            table.insert(remainingKeys, key)
        end
    end
    table.sort(remainingKeys)
    
    for _, key in ipairs(remainingKeys) do
        local valueStr = jsonEncode(obj[key])
        table.insert(parts, string.format('"%s":%s', key, valueStr))
    end
    
    return "{" .. table.concat(parts, ",") .. "}"
end

local function objectsToJsonFormat(objects, filePath, isJsonLines)
    if #objects == 0 then
        return ""
    end
    
    local keyOrder = analyzeKeyOrder(objects)
    
    if isJsonLines then
        local lines = {}
        
        for _, obj in ipairs(objects) do
            local success, jsonLine = pcall(encodeJsonWithOrder, obj, keyOrder)
            if success then
                table.insert(lines, jsonLine)
            else
                local fallbackSuccess, fallbackJson = pcall(jsonEncode, obj)
                if fallbackSuccess then
                    table.insert(lines, fallbackJson)
                end
            end
        end
        
        return table.concat(lines, "\n") .. "\n"
    else
        if #objects == 1 then
            local success, jsonStr = pcall(jsonEncode, objects[1])
            if success then
                return jsonStr
            else
                return ""
            end
        else
            local mergedObject = objects[1]
            for i = 2, #objects do
                mergedObject = mergeSingleJsonObjects(mergedObject, objects[i], filePath)
            end
            local success, jsonStr = pcall(jsonEncode, mergedObject)
            if success then
                return jsonStr
            else
                return ""
            end
        end
    end
end

local function bindingsEqual(a, b)
    if type(a) ~= "table" or type(b) ~= "table" then return false end
    return a.control == b.control and a.action == b.action
end

local function mergeArrays(baseArray, overlayArray, arrayKey)
    local result = deepcopy(baseArray)
    
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
        for _, item in ipairs(overlayArray) do
            table.insert(result, item)
        end
    end
    
    return result
end

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
        
        if not inFunction and (trimmedLine == "" or trimmedLine:startswith("--") or trimmedLine:startswith("local M = {}")) then
            if structure.header == "" then
                structure.header = line
            else
                structure.header = structure.header .. "\n" .. line
            end
        elseif trimmedLine:match("^local function (%w+)%(") then
            local funcName = trimmedLine:match("^local function (%w+)%(")
            inFunction = funcName
            functionContent = {line}
        elseif inFunction and trimmedLine:match("^end%s*$") then
            table.insert(functionContent, line)
            structure.functions[inFunction] = table.concat(functionContent, "\n")
            inFunction = nil
            functionContent = {}
        elseif inFunction then
            table.insert(functionContent, line)
        elseif trimmedLine:match("^M%.(%w+)%s*=") then
            local exportName = trimmedLine:match("^M%.(%w+)%s*=")
            local exportValue = trimmedLine:match("^M%.%w+%s*=%s*(.+)$")
            structure.exports[exportName] = exportValue
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
        
        local funcHeader = baseFuncContent:match("(local function .-%(.-%))")
        local result = funcHeader .. "\n"
        for _, line in ipairs(baseLines) do
            result = result .. line .. "\n"
        end
        result = result .. "end"
        
        return result
    else
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
    
    for funcName, funcContent in pairs(structure.functions) do
        content = content .. funcContent .. "\n\n"
    end
    
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
                result[key] = mergeJson(result[key], value)
            end
        else
            result[key] = value
        end
    end
    
    return result
end

local function findFileConflicts()
    local activeMods = getActiveMods()
    local fileToMods = {}
    local conflicts = {}
    
    for modName, modData in pairs(activeMods) do
        local modFiles = getModFiles(modData, modName)
        for _, filePath in ipairs(modFiles) do
            local internedPath = internPath(filePath)
            if not fileToMods[internedPath] then
                fileToMods[internedPath] = {}
            end
            table.insert(fileToMods[internedPath], {
                modName = modName,
                modData = modData
            })
        end
    end
    
    for filePath, modsList in pairs(fileToMods) do
        if #modsList > 1 then
            conflicts[filePath] = modsList
        end
    end
    
    return conflicts
end

local function mergeConflictingFiles(filePath, modsList)
    local isLuaFile = filePath:lower():endswith('.lua')

    local lowerPath = filePath:lower()
    local isJsonFile = lowerPath:endswith('.json') or lowerPath:endswith('.forest4') or 
                      lowerPath:endswith('.level') or lowerPath:endswith('.prefab') or 
                      lowerPath:endswith('.jbeam') or lowerPath:endswith('.jsonl')
    local mergedData = nil
    local sourceMods = {}
    local allObjects = {}
    local isJsonLines = false

    local function processContent(content, modName)
        table.insert(sourceMods, modName)

        if isLuaFile then
            local luaStructure = parseLuaFile(content)
            if mergedData == nil then
                mergedData = luaStructure
            else
                mergedData = mergeLua(mergedData, luaStructure)
            end
        elseif isJsonFile then
            local objects = parseJsonContent(content, filePath, modName)
            if #objects > 0 then
                if not isJsonLines and #allObjects == 0 then
                    isJsonLines = detectJsonFormat(content, filePath)
                end
                
                for _, obj in ipairs(objects) do
                    table.insert(allObjects, obj)
                end
            end
        else
            local success, jsonData = pcall(jsonDecode, content)
            if success then
                if mergedData == nil then
                    mergedData = jsonData
                else
                    mergedData = mergeJson(mergedData, jsonData)
                end
            else
                log('E', 'ConflictResolver', 'Failed to parse content in ' .. filePath .. ' from mod ' .. modName)
            end
        end
    end
    
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
    
    for zipPath, zipMods in pairs(zipGroups) do
        local modInfo = zipMods[1]
        local fileContent = readFileFromMod(filePath, modInfo.modData, modInfo.modName)

        if fileContent then
            for _, mod in ipairs(zipMods) do
                processContent(fileContent, mod.modName)
            end
        end
    end
    
    for _, modInfo in ipairs(unpackedMods) do
        local fileContent = readFileFromMod(filePath, modInfo.modData, modInfo.modName)
        if fileContent then
            processContent(fileContent, modInfo.modName)
        end
    end
    
    if isJsonFile and #allObjects > 0 then
        if isJsonLines then
            local mergedObjects = mergeJsonLines(allObjects, filePath)
            local jsonContent = objectsToJsonFormat(mergedObjects, filePath, true)
            mergedData = jsonContent
        else
            if #allObjects == 1 then
                local jsonContent = objectsToJsonFormat(allObjects, filePath, false)
                mergedData = jsonContent
            else
                local mergedObject = allObjects[1]
                for i = 2, #allObjects do
                    mergedObject = mergeSingleJsonObjects(mergedObject, allObjects[i], filePath)
                end
                local jsonContent = objectsToJsonFormat({mergedObject}, filePath, false)
                mergedData = jsonContent
            end
        end
    end
    
    if mergedData == nil then
        log('E', 'ConflictResolver', 'No valid data found for ' .. filePath)
        return false
    end
    
    local outputPath = MERGE_OUTPUT_DIR .. filePath
    local outputDir = outputPath:match("(.+)/[^/]+$")
    
    if outputDir and not FS:directoryExists(outputDir) then
        FS:directoryCreate(outputDir, true)
    end
    
    local success = false
    if isLuaFile then
        local luaContent = generateLuaContent(mergedData)
        success = writeFile(outputPath, luaContent)
    elseif isJsonFile then
        success = writeFile(outputPath, mergedData)
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
    
    clearMergeOutputDirectory()
    
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
    
    if resolvedCount > 0 then
        if mountConflictResolver() then
            local changedFiles = {}
            for filePath, conflictInfo in pairs(resolvedConflicts) do
                table.insert(changedFiles, {filename = filePath, type = "modified"})
            end
            if #changedFiles > 0 and _G.onFileChanged then
                _G.onFileChanged(changedFiles)
            end
            
            extensions.hook('onModConflictsResolved', {
                resolved = resolvedConflicts,
                counts = conflictCounts
            })
        end
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

-- Core conflict resolution
M.resolveConflicts = resolveConflicts
M.getConflictStatus = getConflictStatus
M.clearResolvedConflicts = clearResolvedConflicts
M.findFileConflicts = findFileConflicts

-- File system operations
M.clearMergeOutputDirectory = clearMergeOutputDirectory
M.mountConflictResolver = mountConflictResolver
M.unmountConflictResolver = unmountConflictResolver

-- Mod management
M.getActiveMods = getActiveMods
M.onModActivated = onModActivated
M.onModDeactivated = onModDeactivated

-- Cache management
M.clearAllCaches = clearAllCaches
M.getCacheStats = getCacheStats

-- Manifest system
M.manifestIsStale = manifestIsStale
M.buildManifest = buildManifest
M.loadManifestList = loadManifestList

-- Enhanced JSON processing
M.detectJsonFormat = detectJsonFormat
M.parseJsonContent = parseJsonContent
M.generateUniqueKey = generateUniqueKey
M.mergeJsonLines = mergeJsonLines
M.mergeSingleJsonObjects = mergeSingleJsonObjects
M.objectsToJsonFormat = objectsToJsonFormat

return M