local M = {}

local MERGE_OUTPUT_DIR = "/mods/ModConflictResolutions/"
local SUPPORTED_EXTENSIONS = {".json", ".lua", ".forest4", ".level", ".prefab", ".jbeam", ".jsonl"}
local RESOLVER_MOUNT_POINT = "/mods/ModConflictResolutions/"
local RESOLUTION_DEBOUNCE_TIME = 2.0
local MANIFEST_DIR = "/mods/mod_manifests/"
local JSON_DETECTION_SAMPLE_SIZE = 4096
local RESOLUTION_INDEX_FILE = MERGE_OUTPUT_DIR .. "resolutions.json"
local RESOLUTION_INDEX_VERSION = "0.2"

local resolvedConflicts = {}
local conflictCounts = {}
local lastResolutionTime = 0
local modSnapshot = {}
local globalFileToMods = {}

local modFileCache = {}
local zipFileListCache = {}
local fileContentCache = {}
local pathInternCache = {}
local pathNormalizeCache = {}
local fileAstCache = {}
local fileAstCacheSize = 0
local MAX_AST_CACHE_SIZE = 128
local openZipCache = {}
local zipCacheSize = 0
local MAX_ZIP_CACHE_SIZE = 16

local conflictStartTime = 0
local conflictStartClock = 0
local globalFileIndex = {}
local processedHashes = {}

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
    
    if pathNormalizeCache[path] then
        return pathNormalizeCache[path]
    end
    
    local normalized = path:gsub("\\", "/")
    normalized = normalized:gsub("//+", "/")
    if not normalized:startswith("/") then
        normalized = "/" .. normalized
    end
    
    pathNormalizeCache[path] = normalized
    return normalized
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
    
    local manifest = jsonReadFile(manifestPath)
    if not manifest or not manifest.latest then
        return true
    end
    
    local modTimestamp = getModTimestamp(modData)
    return modTimestamp > manifest.latest
end

local function getCachedZip(zipPath)
    if openZipCache[zipPath] then
        return openZipCache[zipPath]
    end
    
    if zipCacheSize >= MAX_ZIP_CACHE_SIZE then
        local toRemove = {}
        local count = 0
        for path, zip in pairs(openZipCache) do
            count = count + 1
            if count <= MAX_ZIP_CACHE_SIZE / 2 then
                table.insert(toRemove, path)
                zip:close()
            end
        end
        for _, path in ipairs(toRemove) do
            openZipCache[path] = nil
            zipCacheSize = zipCacheSize - 1
        end
    end
    
    local zip = ZipArchive()
    if zip:openArchiveName(zipPath, "R") then
        openZipCache[zipPath] = zip
        zipCacheSize = zipCacheSize + 1
        return zip
    else
        log('E', 'ConflictResolver', 'Failed to open zip: ' .. tostring(zipPath))
        return nil
    end
end

local function closeAllZipCaches()
    for _, zip in pairs(openZipCache) do
        zip:close()
    end
    openZipCache = {}
    zipCacheSize = 0
end

local function getZipFileMap(zipPath)
    if zipFileListCache[zipPath] then
        return zipFileListCache[zipPath]
    end

    local zip = getCachedZip(zipPath)
    if zip then
        local fileList = zip:getFileList()
        local fileMap = {}
        for i, f in ipairs(fileList) do
            fileMap[f] = i
        end
        zipFileListCache[zipPath] = fileMap
    else
        zipFileListCache[zipPath] = {}
    end
    return zipFileListCache[zipPath]
end

local function computeFileHash(content)
    if not content then return "0" end
    
    local len = #content
    if len == 0 then return "0" end
    
    if len <= 1024 then
        local hash = 5381
        for i = 1, len do
            hash = ((hash * 33) + string.byte(content, i)) % 2147483647
        end
        return tostring(hash)
    end
    
    local hash = 5381
    
    hash = ((hash * 33) + len) % 2147483647
    
    for i = 1, math.min(256, len) do
        hash = ((hash * 33) + string.byte(content, i)) % 2147483647
    end
    
    local midStart = math.floor(len / 2) - 128
    for i = midStart, math.min(midStart + 255, len) do
        if i > 0 then
            hash = ((hash * 33) + string.byte(content, i)) % 2147483647
        end
    end
    
    for i = math.max(1, len - 255), len do
        hash = ((hash * 33) + string.byte(content, i)) % 2147483647
    end
    
    return tostring(hash)
end

local filePathCache = {}
local hashCache = {}
local MAX_CACHE_SIZE = 10000
local cacheAccessCount = 0

local function cleanupCaches()
    cacheAccessCount = cacheAccessCount + 1
    if cacheAccessCount % 1000 == 0 then
        local pathCacheSize = tableSize(filePathCache)
        local hashCacheSize = tableSize(hashCache)
        
        if pathCacheSize > MAX_CACHE_SIZE then
            local toRemove = pathCacheSize - MAX_CACHE_SIZE
            local removed = 0
            for key, entry in pairs(filePathCache) do
                if removed >= toRemove then break end
                if entry.timestamp and (os.time() - entry.timestamp) > 300 then
                    filePathCache[key] = nil
                    removed = removed + 1
                end
            end
        end
        
        if hashCacheSize > MAX_CACHE_SIZE then
            local keys = {}
            for k in pairs(hashCache) do
                table.insert(keys, k)
            end
            local toRemove = math.floor(#keys * 0.3)
            for i = 1, toRemove do
                hashCache[keys[i]] = nil
            end
        end
    end
end

local function readFileFromMod(filePath, modData, modName, expectedHash)
    filePath = normalizePath(filePath)
    
    cleanupCaches()
    
    if expectedHash and fileContentCache[expectedHash] then
        return fileContentCache[expectedHash]
    end
    
    local cacheKey = modName .. ":" .. filePath
    local cached = filePathCache[cacheKey]
    if cached then
        cached.timestamp = os.time()
        if cached.content and cached.hash and not fileContentCache[cached.hash] then
            fileContentCache[cached.hash] = cached.content
        end
        return cached.content
    end
    
    local content = nil
    local startTime = hptimer()
    
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
            local zip = getCachedZip(modData.fullpath)
            if zip then
                content = zip:readFileEntryByIdx(fileIndex)
            else
                log('E', 'ConflictResolver', 'Failed to open ZIP: ' .. modData.fullpath)
            end
        end
    end
    
    local ioTime = startTime:stop()
    
    if content then
        local hashStartTime = hptimer()
        local hash = expectedHash or computeFileHash(content)
        local hashTime = hashStartTime:stop()
        
        fileContentCache[hash] = content
        filePathCache[cacheKey] = {
            content = content,
            hash = hash,
            timestamp = os.time(),
            ioTime = ioTime,
            hashTime = hashTime
        }
        
        if not expectedHash then
            hashCache[cacheKey] = hash
        end
    else
        filePathCache[cacheKey] = {
            content = nil,
            hash = nil,
            timestamp = os.time(),
            ioTime = ioTime
        }
    end
    
    return content
end

local function batchReadFromZip(zipPath, filePaths)
    local results = {}
    local zipFileMap = getZipFileMap(zipPath)
    if tableSize(zipFileMap) == 0 then
        return results
    end

    local zip = getCachedZip(zipPath)
    if not zip then
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

    return results
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

local function buildManifest(modData, manifestPath, modName)
    local entries = {}
    local startTime = os.time()
    local latestMtime = 0
    local totalFiles = 0
    local processedFiles = 0
    
    if modData.modData and modData.modData.hashes then
        for _, hashData in ipairs(modData.modData.hashes) do
            local filePath = normalizePath(hashData[1])
            if isSupportedFileType(filePath) then
                local fileKey = filePath .. ":" .. (hashData[2] or "")
                if processedHashes[fileKey] then
                    local entry = {
                        path = internPath(filePath),
                        hash = processedHashes[fileKey]
                    }
                    table.insert(entries, entry)
                else
                    local content = readFileFromMod(filePath, modData, modName)
                    local hash = computeFileHash(content)
                    processedHashes[fileKey] = hash
                    
                    local entry = {
                        path = internPath(filePath),
                        hash = hash
                    }
                    
                    table.insert(entries, entry)
                    if content then
                        fileContentCache[hash] = content
                    end
                    processedFiles = processedFiles + 1
                end
                totalFiles = totalFiles + 1
            end
        end
        latestMtime = getModTimestamp(modData)
    elseif modData.unpackedPath and FS:directoryExists(modData.unpackedPath) then
        local modFiles = FS:findFiles(modData.unpackedPath, '*', -1, true, false)
        for _, fullPath in ipairs(modFiles) do
            local relativePath = fullPath:gsub(modData.unpackedPath, "")
            relativePath = normalizePath(relativePath)
            if isSupportedFileType(relativePath) then
                local stat = FS:stat(fullPath)
                local fileKey = relativePath .. ":" .. (stat and stat.modtime or "0")
                
                if processedHashes[fileKey] then
                    local entry = {
                        path = internPath(relativePath),
                        hash = processedHashes[fileKey]
                    }
                    table.insert(entries, entry)
                else
                    local content = readFile(fullPath)
                    local hash = computeFileHash(content)
                    processedHashes[fileKey] = hash
                    
                    local entry = {
                        path = internPath(relativePath),
                        hash = hash
                    }
                    
                    table.insert(entries, entry)
                    if content then
                        fileContentCache[hash] = content
                    end
                    processedFiles = processedFiles + 1
                end
                totalFiles = totalFiles + 1
                
                if not processedHashes[fileKey] then
                    local stat = FS:stat(fullPath)
                    if stat and stat.modtime and stat.modtime > latestMtime then
                        latestMtime = stat.modtime
                    end
                end
            end
        end
    elseif modData.fullpath and FS:fileExists(modData.fullpath) then
        local zipFileMap = getZipFileMap(modData.fullpath)
        local zipPaths = {}
        for filePath, _ in pairs(zipFileMap) do
            local normalized = normalizePath(filePath)
            if isSupportedFileType(normalized) then
                table.insert(zipPaths, normalized)
            end
        end
        
        local batchContent = batchReadFromZip(modData.fullpath, zipPaths)
        for filePath, content in pairs(batchContent) do
            local contentHash = computeFileHash(content)
            local fileKey = filePath .. ":" .. contentHash
            
            if not processedHashes[fileKey] then
                processedHashes[fileKey] = contentHash
                
                local entry = {
                    path = internPath(filePath),
                    hash = contentHash
                }
                
                table.insert(entries, entry)
                if content then
                    fileContentCache[contentHash] = content
                end
                processedFiles = processedFiles + 1
            else
                local entry = {
                    path = internPath(filePath),
                    hash = processedHashes[fileKey]
                }
                table.insert(entries, entry)
            end
            totalFiles = totalFiles + 1
        end
        latestMtime = getModTimestamp(modData)
    end
    
    local manifest = {
        scanned = startTime,
        latest = latestMtime,
        entries = entries
    }
    
    if not FS:directoryExists(MANIFEST_DIR) then
        FS:directoryCreate(MANIFEST_DIR, true)
    end
    
    local success = jsonWriteFile(manifestPath, manifest, true)
    
    if success then
        local cacheHitRate = totalFiles > 0 and ((totalFiles - processedFiles) / totalFiles * 100) or 0
        log('I', 'ConflictResolver', string.format('Built manifest for %s with %d files (%.1f%% cache hits)', 
            modName or 'unknown', #entries, cacheHitRate))
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
        modSnapshot[modName] = {
            ts = manifest.scanned,
            entries = manifest.entries
        }
        return manifest.entries or {}
    else
        local manifest = jsonReadFile(manifestPath)
        if manifest and manifest.entries then
            if not modSnapshot[modName] or modSnapshot[modName].ts ~= manifest.scanned then
                modSnapshot[modName] = {
                    ts = manifest.scanned,
                    entries = manifest.entries
                }
            end
            return manifest.entries
        else
            log('W', 'ConflictResolver', 'Invalid manifest file, rebuilding: ' .. manifestPath)
            local newManifest = buildManifest(modData, manifestPath, modName)
            modSnapshot[modName] = {
                ts = newManifest.scanned,
                entries = newManifest.entries
            }
            return newManifest.entries or {}
        end
    end
end

local function clearModCache(modName)
    modFileCache[modName] = nil
    modSnapshot[modName] = nil
    
    for filePath, modsList in pairs(globalFileToMods) do
        for i = #modsList, 1, -1 do
            if modsList[i].modName == modName then
                table.remove(modsList, i)
            end
        end
        if #modsList == 0 then
            globalFileToMods[filePath] = nil
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

local function addToAstCache(hash, ast)
    if fileAstCacheSize >= MAX_AST_CACHE_SIZE then
        local newCache = {}
        local newSize = 0
        local count = 0
        for h, a in pairs(fileAstCache) do
            count = count + 1
            if count > MAX_AST_CACHE_SIZE / 2 then
                newCache[h] = a
                newSize = newSize + 1
            end
        end
        fileAstCache = newCache
        fileAstCacheSize = newSize
    end
    
    if not fileAstCache[hash] then
        fileAstCacheSize = fileAstCacheSize + 1
    end
    fileAstCache[hash] = ast
end

local function clearAllCaches()
    modFileCache = {}
    zipFileListCache = {}
    fileContentCache = {}
    pathInternCache = {}
    pathNormalizeCache = {}
    modSnapshot = {}
    globalFileToMods = {}
    globalFileIndex = {}
    processedHashes = {}
    fileAstCache = {}
    fileAstCacheSize = 0
    closeAllZipCaches()
    
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
        pathNormalizeCache = tableSize(pathNormalizeCache),
        modSnapshot = tableSize(modSnapshot),
        globalFileToMods = tableSize(globalFileToMods),
        globalFileIndex = tableSize(globalFileIndex),
        processedHashes = tableSize(processedHashes),
        fileAstCache = fileAstCacheSize,
        openZipCache = zipCacheSize,
        filePathCache = tableSize(filePathCache),
        hashCache = tableSize(hashCache),
        totalCacheEntries = 0
    }
    stats.totalCacheEntries = stats.modFileCache + stats.zipFileListCache + stats.fileContentCache + 
                              stats.pathInternCache + stats.pathNormalizeCache + stats.modSnapshot + 
                              stats.globalFileToMods + stats.globalFileIndex + stats.processedHashes + 
                              stats.fileAstCache + stats.openZipCache + stats.filePathCache + stats.hashCache
    
    if FS:directoryExists(MANIFEST_DIR) then
        local manifestFiles = FS:findFiles(MANIFEST_DIR, '*.json', 0, true, false)
        stats.manifestFiles = #manifestFiles
        stats.totalCacheEntries = stats.totalCacheEntries + stats.manifestFiles
    else
        stats.manifestFiles = 0
    end
    
    return stats
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
    
    local entries = loadManifestList(modData, modName)
    
    if modName then
        modFileCache[modName] = entries
    end
    
    return entries
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

local function loadResolutionIndex()
    if not FS:fileExists(RESOLUTION_INDEX_FILE) then
        return { version = RESOLUTION_INDEX_VERSION, resolutions = {}, versionChanged = false }
    end
    
    local data = jsonReadFile(RESOLUTION_INDEX_FILE)
    if not data or type(data) ~= "table" then
        return { version = RESOLUTION_INDEX_VERSION, resolutions = {}, versionChanged = false }
    end
    
    -- Check for legacy format (direct resolution data without version)
    if not data.version and not data.resolutions then
        log('I', 'ConflictResolver', 'Converting legacy resolution index format - forcing complete rebuild')
        
        -- Clear everything for legacy conversion
        if FS:directoryExists(MERGE_OUTPUT_DIR) then
            FS:remove(MERGE_OUTPUT_DIR)
            log('I', 'ConflictResolver', 'Cleared merge output directory for legacy conversion')
        end
        
        return { version = RESOLUTION_INDEX_VERSION, resolutions = {}, versionChanged = true }
    end
    
    -- Check version compatibility
    if data.version ~= RESOLUTION_INDEX_VERSION then
        log('I', 'ConflictResolver', string.format('Resolution index version mismatch (%s vs %s), forcing complete rebuild', 
            tostring(data.version), RESOLUTION_INDEX_VERSION))
        
        -- Clear the entire merge output directory for clean start
        if FS:directoryExists(MERGE_OUTPUT_DIR) then
            FS:remove(MERGE_OUTPUT_DIR)
            log('I', 'ConflictResolver', 'Cleared merge output directory due to version change')
        end
        
        -- Clear all caches to ensure fresh start
        clearAllCaches()
        
        return { version = RESOLUTION_INDEX_VERSION, resolutions = {}, versionChanged = true }
    end
    
    -- Same version, no rebuild needed
    data.versionChanged = false
    return data
end

local function saveResolutionIndex(resolutionData)
    if not FS:directoryExists(MERGE_OUTPUT_DIR) then
        FS:directoryCreate(MERGE_OUTPUT_DIR, true)
    end
    
    local indexData = {
        version = RESOLUTION_INDEX_VERSION,
        createdAt = os.time(),
        description = "Mod conflict resolution index - tracks merged files and their source mods",
        resolutions = resolutionData
    }
    
    jsonWriteFile(RESOLUTION_INDEX_FILE, indexData, true)
end

local function pruneObsoleteResolutions(conflicts, indexData)
    local activeFiles = {}
    for filePath, _ in pairs(conflicts) do
        activeFiles[filePath] = true
    end
    
    local resolutions = indexData.resolutions or {}
    for filePath, resolution in pairs(resolutions) do
        if not activeFiles[filePath] then
            if resolution.outputPath and FS:fileExists(resolution.outputPath) then
                FS:remove(resolution.outputPath)
            end
            resolutions[filePath] = nil
        end
    end
    indexData.resolutions = resolutions
end

local function shouldSkipMerge(filePath, modsList, indexData)
    -- Never skip if version changed - force complete rebuild
    if indexData.versionChanged then
        return false
    end
    
    local resolutions = indexData.resolutions or {}
    local resolution = resolutions[filePath]
    if not resolution then
        return false
    end
    
    if not resolution.outputPath or not FS:fileExists(resolution.outputPath) then
        return false
    end
    
    if not resolution.sourceMods or not resolution.sourceHashes then
        return false
    end
    
    if #resolution.sourceMods ~= #modsList or #resolution.sourceHashes ~= #modsList then
        return false
    end
    
    local currentMods = {}
    local currentHashes = {}
    
    for _, modInfo in ipairs(modsList) do
        table.insert(currentMods, modInfo.modName)
        table.insert(currentHashes, modInfo.hash)
    end
    
    table.sort(currentMods)
    table.sort(currentHashes)
    
    local cachedMods = {}
    local cachedHashes = {}
    for _, mod in ipairs(resolution.sourceMods) do
        table.insert(cachedMods, mod)
    end
    for _, hash in ipairs(resolution.sourceHashes) do
        table.insert(cachedHashes, hash)
    end
    table.sort(cachedMods)
    table.sort(cachedHashes)
    
    for i = 1, #currentMods do
        if currentMods[i] ~= cachedMods[i] or currentHashes[i] ~= cachedHashes[i] then
            return false
        end
    end
    
    return true
end

local function recordResolution(filePath, modsList, outputHash, indexData)
    local sourceMods = {}
    local sourceHashes = {}
    
    for _, modInfo in ipairs(modsList) do
        table.insert(sourceMods, modInfo.modName)
        table.insert(sourceHashes, modInfo.hash)
    end
    
    if not indexData.resolutions then
        indexData.resolutions = {}
    end
    
    indexData.resolutions[filePath] = {
        outputPath = MERGE_OUTPUT_DIR .. filePath,
        sourceMods = sourceMods,
        sourceHashes = sourceHashes,
        outputHash = outputHash,
        mergedAt = os.time()
    }
end

local function stripBOM(text)
    if not text then return text end
    
    -- Remove BOM (U+FEFF) and other invisible Unicode characters
    text = text:gsub("\239\187\191", "")  -- UTF-8 BOM
    text = text:gsub("\255\254", "")      -- UTF-16 LE BOM
    text = text:gsub("\254\255", "")      -- UTF-16 BE BOM
    text = text:gsub("\239\191\191", "")  -- Alternative UTF-8 BOM representation
    text = text:gsub("[\194\195][\128-\191]", function(match)
        -- Remove U+FEFF (Zero Width No-Break Space) in UTF-8
        if match == "\239\187\191" then return "" end
        return match
    end)
    
    return text
end

local function parseJsonContent(content, filePath, modName)
    if not content or content == "" then
        return {}
    end
    
    content = stripBOM(content)
    
    local contentHash = computeFileHash(content)
    if fileAstCache[contentHash] then
        return fileAstCache[contentHash]
    end
    
    local objects = {}
    
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
    
    addToAstCache(contentHash, objects)
    
    return objects
end

local function generateUniqueKey(obj)
    if obj.__key then
        return obj.__key
    end
    
    local nameKeys = {"name", "title", "label", "id", "guid", "uuid"}
    local positionKeys = {"position", "pos", "location", "transform"}
    local rotationKeys = {"rotationMatrix", "rotation", "rot", "orientation"}
    local typeKeys = {"type", "class", "category", "kind"}
    local parentKeys = {"__parent", "parent", "parentId"}
    local shapeKeys = {"shapeName", "shape", "mesh", "model"}
    local annotationKeys = {"annotation", "description", "comment"}
    local additionalKeys = {"material", "texture", "scale", "size", "isRenderEnabled", "useInstanceRenderData", "decalType"}
    
    local keyParts = {}
        
    for _, key in ipairs(nameKeys) do
        if obj[key] and obj[key] ~= "" then
            table.insert(keyParts, "name:" .. tostring(obj[key]))
        end
    end
    
    for _, key in ipairs(typeKeys) do
        if obj[key] and obj[key] ~= "" then
            table.insert(keyParts, "type:" .. tostring(obj[key]))
        end
    end
    
    for _, key in ipairs(parentKeys) do
        if obj[key] and obj[key] ~= "" then
            table.insert(keyParts, "parent:" .. tostring(obj[key]))
        end
    end
    
    for _, key in ipairs(shapeKeys) do
        if obj[key] and obj[key] ~= "" then
            table.insert(keyParts, "shape:" .. tostring(obj[key]))
        end
    end
    
    for _, key in ipairs(annotationKeys) do
        if obj[key] and obj[key] ~= "" then
            table.insert(keyParts, "annotation:" .. tostring(obj[key]))
        end
    end
    
    for _, key in ipairs(positionKeys) do
        if obj[key] then
            if type(obj[key]) == "table" then
                local pos = obj[key]
                local posStr = string.format("pos:%.6f,%.6f,%.6f", 
                    pos[1] or pos.x or 0, 
                    pos[2] or pos.y or 0, 
                    pos[3] or pos.z or 0)
                table.insert(keyParts, posStr)
            else
                table.insert(keyParts, "pos:" .. tostring(obj[key]))
            end
        end
    end
    
    for _, key in ipairs(rotationKeys) do
        if obj[key] then
            if type(obj[key]) == "table" then
                local rot = obj[key]
                if #rot >= 9 then
                    local rotStr = string.format("rot:%.6f,%.6f,%.6f,%.6f,%.6f,%.6f", 
                        rot[1] or 0, rot[2] or 0, rot[3] or 0, 
                        rot[4] or 0, rot[5] or 0, rot[6] or 0)
                    table.insert(keyParts, rotStr)
                elseif #rot >= 3 then
                    local rotStr = string.format("rot:%.6f,%.6f,%.6f", rot[1] or 0, rot[2] or 0, rot[3] or 0)
                    table.insert(keyParts, rotStr)
                end
            else
                table.insert(keyParts, "rot:" .. tostring(obj[key]))
            end
        end
    end
    
    for _, key in ipairs(additionalKeys) do
        if obj[key] and obj[key] ~= "" then
            table.insert(keyParts, key .. ":" .. tostring(obj[key]))
        end
    end
    
    if #keyParts < 3 then
        local otherKeys = {"value", "data", "content", "color", "variant", "model"}
        for _, key in ipairs(otherKeys) do
            if obj[key] and obj[key] ~= "" then
                table.insert(keyParts, key .. ":" .. tostring(obj[key]))
            end
        end
    end
    
    local key
    if #keyParts == 0 then
        local sortedPairs = {}
        for k, v in pairs(obj) do
            if k ~= "__key" then
                table.insert(sortedPairs, k .. "=" .. tostring(v))
            end
        end
        table.sort(sortedPairs)
        key = "hash:" .. table.concat(sortedPairs, ";")
    else
        table.sort(keyParts)
        key = table.concat(keyParts, "|")
    end
    
    obj.__key = key
    return key
end

local function computePartHashesForEntry(entry, filePath)
    if entry.partHashes then
        return entry.partHashes
    end
    
    local content = readFileFromMod(filePath, entry.modData, entry.modName, entry.hash)
    if not content or not detectJsonFormat(content, filePath) then
        entry.partHashes = {}
        return entry.partHashes
    end
    
    local partHashes = {}
    for line in content:gmatch("[^\r\n]+") do
        local trimmedLine = line:match("^%s*(.-)%s*$")
        if trimmedLine ~= "" then
            table.insert(partHashes, computeFileHash(trimmedLine))
        end
    end
    
    entry.partHashes = partHashes
    return partHashes
end

local function allPartHashesEqual(modsList, filePath)
    if #modsList <= 1 then return true end
    
    local firstPartHashes = computePartHashesForEntry(modsList[1], filePath)
    if #firstPartHashes == 0 then
        return false
    end
    
    for i = 2, #modsList do
        local entryPartHashes = computePartHashesForEntry(modsList[i], filePath)
        if #entryPartHashes ~= #firstPartHashes then
            return false
        end
        
        for j = 1, #firstPartHashes do
            if firstPartHashes[j] ~= entryPartHashes[j] then
                return false
            end
        end
    end
    
    return true
end

local function mergeJsonLines(allObjects, filePath, modsList)
    local mergedObjects = {}
    local seenObjects = {}
    
    for _, obj in ipairs(allObjects) do
        local uniqueKey = generateUniqueKey(obj)
        
        if not seenObjects[uniqueKey] then
            seenObjects[uniqueKey] = true
            table.insert(mergedObjects, obj)
        end
    end
    
    -- Remove __key properties before returning for serialization
    for _, obj in ipairs(mergedObjects) do
        obj.__key = nil
    end
    
    return mergedObjects
end

local function mergeSingleJsonObjects(base, overlay, filePath)
    if type(base) ~= "table" or type(overlay) ~= "table" then
        return overlay
    end
    
    for key, value in pairs(overlay) do
        if type(value) == "table" and type(base[key]) == "table" then
            base[key] = mergeSingleJsonObjects(base[key], value, filePath)
        else
            base[key] = value
        end
    end
    
    return base
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
            return objects[1]
        else
            local mergedObject = objects[1]
            for i = 2, #objects do
                mergedObject = mergeSingleJsonObjects(mergedObject, objects[i], filePath)
            end
            return mergedObject
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
        local seen = {}
        for _, baseItem in ipairs(result) do
            local key = (baseItem.control or "") .. ":" .. (baseItem.action or "")
            seen[key] = true
        end
        
        for _, overlayItem in ipairs(overlayArray) do
            local key = (overlayItem.control or "") .. ":" .. (overlayItem.action or "")
            if not seen[key] then
                seen[key] = true
                result[#result + 1] = overlayItem
            end
        end
    else
        for _, item in ipairs(overlayArray) do
            result[#result + 1] = item
        end
    end
    
    return result
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

local function allHashesEqual(modsList)
    if #modsList <= 1 then return true end
    
    local firstHash = modsList[1].hash
    for i = 2, #modsList do
        if modsList[i].hash ~= firstHash then
            return false
        end
    end
    return true
end

local function copyFirstFileAndRecord(filePath, modsList)
    local firstMod = modsList[1]
    local content = readFileFromMod(filePath, firstMod.modData, firstMod.modName, firstMod.hash)
    
    if not content then
        return false
    end
    
    local outputPath = MERGE_OUTPUT_DIR .. filePath
    local outputDir = outputPath:match("(.+)/[^/]+$")
    
    if outputDir and not FS:directoryExists(outputDir) then
        FS:directoryCreate(outputDir, true)
    end
    
    local success = writeFile(outputPath, content)
    
    if success then
        local sourceMods = {}
        for _, modInfo in ipairs(modsList) do
            table.insert(sourceMods, modInfo.modName)
        end
        
        resolvedConflicts[filePath] = {
            outputPath = outputPath,
            sourceMods = sourceMods,
            mergedAt = os.time(),
            identicalHash = firstMod.hash
        }
        return true
    end
    
    return false
end

local function updateGlobalFileToMods(modName, entries)
    for _, entry in ipairs(entries) do
        local filePath = entry.path
        if not globalFileToMods[filePath] then
            globalFileToMods[filePath] = {}
        end
        
        local found = false
        for i, existing in ipairs(globalFileToMods[filePath]) do
            if existing.modName == modName then
                globalFileToMods[filePath][i] = {
                    modName = modName,
                    modData = existing.modData,
                    hash = entry.hash
                }
                found = true
                break
            end
        end
        
        if not found then
            table.insert(globalFileToMods[filePath], {
                modName = modName,
                modData = nil,
                hash = entry.hash
            })
        end
    end
end

local function quickScanForPotentialConflicts(activeMods)
    local fileToModNames = {}
    local potentiallyConflictingMods = {}
    
    log('I', 'ConflictResolver', 'Quick scanning ' .. tableSize(activeMods) .. ' mods for potential conflicts...')
    
    for modName, modData in pairs(activeMods) do
        local fileList = {}
        
        if modData.modData and modData.modData.hashes then
            for _, hashData in ipairs(modData.modData.hashes) do
                local filePath = normalizePath(hashData[1])
                if isSupportedFileType(filePath) then
                    table.insert(fileList, filePath)
                end
            end
        elseif modData.unpackedPath and FS:directoryExists(modData.unpackedPath) then
            local modFiles = FS:findFiles(modData.unpackedPath, '*', -1, true, false)
            for _, fullPath in ipairs(modFiles) do
                local relativePath = fullPath:gsub(modData.unpackedPath, "")
                relativePath = normalizePath(relativePath)
                if isSupportedFileType(relativePath) then
                    table.insert(fileList, relativePath)
                end
            end
        elseif modData.fullpath and FS:fileExists(modData.fullpath) then
            local zipFileMap = getZipFileMap(modData.fullpath)
            for filePath, _ in pairs(zipFileMap) do
                local normalized = normalizePath(filePath)
                if isSupportedFileType(normalized) then
                    table.insert(fileList, normalized)
                end
            end
        end
        
        for _, filePath in ipairs(fileList) do
            if not fileToModNames[filePath] then
                fileToModNames[filePath] = {}
            end
            table.insert(fileToModNames[filePath], modName)
        end
    end
    
    local uniqueFiles = {}
    for filePath, modNames in pairs(fileToModNames) do
        if #modNames > 1 then
            for _, modName in ipairs(modNames) do
                potentiallyConflictingMods[modName] = true
            end
        else
            uniqueFiles[filePath] = true
        end
    end
    
    local conflictingCount = tableSize(potentiallyConflictingMods)
    local totalCount = tableSize(activeMods)
    local uniqueFileCount = tableSize(uniqueFiles)
    local totalFileCount = tableSize(fileToModNames)
    
    log('I', 'ConflictResolver', string.format('Found %d/%d mods with potential conflicts (%.1f%% reduction)', 
        conflictingCount, totalCount, (1 - conflictingCount/totalCount) * 100))
    log('I', 'ConflictResolver', string.format('Identified %d/%d unique files to skip (%.1f%% file reduction)', 
        uniqueFileCount, totalFileCount, (uniqueFileCount/totalFileCount) * 100))
    
    globalFileIndex.uniqueFiles = uniqueFiles
    
    return potentiallyConflictingMods
end

local function processConflictsAfterJobs(activeMods, quickConflictMap)
    local conflicts = {}
    
    for filePath, hashList in pairs(quickConflictMap) do
        if #hashList > 1 then
            local fullModsList = {}
            for _, hashEntry in ipairs(hashList) do
                local modData = activeMods[hashEntry.modName]
                if modData then
                    table.insert(fullModsList, {
                        modName = hashEntry.modName,
                        modData = modData,
                        hash = hashEntry.hash
                    })
                end
            end
            
            if #fullModsList > 1 then
                conflicts[filePath] = fullModsList
                
                globalFileToMods[filePath] = fullModsList
            end
        end
    end
    
    return conflicts
end

local function findFileConflicts()
    local activeMods = getActiveMods()
    local conflicts = {}
    
    local potentiallyConflictingMods = quickScanForPotentialConflicts(activeMods)
    
    local quickConflictMap = {}
    
    for modName, modData in pairs(activeMods) do
        if not potentiallyConflictingMods[modName] then
            goto continue
        end
        
        local currentSnapshot = modSnapshot[modName]
        local entries
        
        if not currentSnapshot then
            entries = getModFiles(modData, modName)
        else
            local manifestPath = MANIFEST_DIR .. sanitizeModName(modName) .. ".json"
            if manifestIsStale(modData, manifestPath) then
                entries = getModFiles(modData, modName)
            else
                entries = currentSnapshot.entries
            end
        end
        
        for _, entry in ipairs(entries) do
            local filePath = entry.path
            
            if globalFileIndex.uniqueFiles and globalFileIndex.uniqueFiles[filePath] then
                goto continue_entry
            end
            
            if not quickConflictMap[filePath] then
                quickConflictMap[filePath] = {}
            end
            
            table.insert(quickConflictMap[filePath], {
                modName = modName,
                hash = entry.hash
            })
            
            ::continue_entry::
        end
        
        ::continue::
    end
    
    for filePath, hashList in pairs(quickConflictMap) do
        if #hashList > 1 then
            local firstHash = hashList[1].hash
            local hasRealConflict = false
            
            for i = 2, #hashList do
                if hashList[i].hash ~= firstHash then
                    hasRealConflict = true
                    break
                end
            end
            
            if hasRealConflict then
                local fullModsList = {}
                for _, hashEntry in ipairs(hashList) do
                    local modData = activeMods[hashEntry.modName]
                    if modData then
                        table.insert(fullModsList, {
                            modName = hashEntry.modName,
                            modData = modData,
                            hash = hashEntry.hash
                        })
                    end
                end
                
                if #fullModsList > 1 then
                    conflicts[filePath] = fullModsList
                    
                    globalFileToMods[filePath] = fullModsList
                end
            end
        end
    end
    
    return conflicts
end

local function batchReadUnpackedMods(unpackedMods, filePath)
    local fileGroups = {}
    local results = {}
    
    for _, modInfo in ipairs(unpackedMods) do
        if modInfo.modData.unpackedPath then
            local fullPath = modInfo.modData.unpackedPath .. filePath
            if not fileGroups[fullPath] then
                fileGroups[fullPath] = {}
            end
            table.insert(fileGroups[fullPath], modInfo)
        end
    end
    
    for fullPath, mods in pairs(fileGroups) do
        if FS:fileExists(fullPath) then
            local content = readFile(fullPath)
            if content then
                for _, modInfo in ipairs(mods) do
                    results[modInfo.modName] = content
                end
            end
        end
    end
    
    return results
end

local function mergeConflictingFiles(filePath, modsList)
    if allHashesEqual(modsList) then
        return copyFirstFileAndRecord(filePath, modsList)
    end
    
    if allPartHashesEqual(modsList, filePath) then
        return copyFirstFileAndRecord(filePath, modsList)
    end
    
    local lowerPath = filePath:lower()
    
    local isLuaFile = filePath:lower():endswith('.lua')
    local isJsonFile = lowerPath:endswith('.json') or lowerPath:endswith('.forest4') or 
                      lowerPath:endswith('.level') or lowerPath:endswith('.prefab') or 
                      lowerPath:endswith('.jbeam') or lowerPath:endswith('.jsonl')
    local mergedData = nil
    local sourceMods = {}
    local allObjects = {}
    local isJsonLines = false

    local luaContents = {}
    local function processContent(content, modName)
        table.insert(sourceMods, modName)

        if isLuaFile then
            content = stripBOM(content)
            table.insert(luaContents, content)
        elseif isJsonFile then
            content = stripBOM(content)
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
            content = stripBOM(content)
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
        local fileContent = readFileFromMod(filePath, modInfo.modData, modInfo.modName, modInfo.hash)

        if fileContent then
            -- Only process the content once per zip file, use combined mod name
            local combinedModName = {}
            for _, mod in ipairs(zipMods) do
                table.insert(combinedModName, mod.modName)
            end
            processContent(fileContent, table.concat(combinedModName, "+"))
        end
    end
    
    local unpackedContent = batchReadUnpackedMods(unpackedMods, filePath)
    for modName, content in pairs(unpackedContent) do
        processContent(content, modName)
    end
    
    if isLuaFile and #luaContents > 0 then
        if #luaContents == 1 then
            mergedData = luaContents[1]
        else
            local seen = {}
            local uniqueContents = {}
            for _, c in ipairs(luaContents) do
                local h = computeFileHash(c)
                if not seen[h] then
                    seen[h] = true
                    table.insert(uniqueContents, c)
                end
            end
            if #uniqueContents == 1 then
                mergedData = uniqueContents[1]
            end
        end
    elseif isJsonFile and #allObjects > 0 then
        if isJsonLines then
            local mergedObjects = mergeJsonLines(allObjects, filePath, modsList)
            local jsonContent = objectsToJsonFormat(mergedObjects, filePath, true)
            mergedData = jsonContent
        else
            if #allObjects == 1 then
                mergedData = objectsToJsonFormat(allObjects, filePath, false)
            else
                local mergedObject = allObjects[1]
                for i = 2, #allObjects do
                    mergedObject = mergeSingleJsonObjects(mergedObject, allObjects[i], filePath)
                end
                mergedData = objectsToJsonFormat({mergedObject}, filePath, false)
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
        success = writeFile(outputPath, mergedData)
    elseif isJsonFile then
        if isJsonLines then
            success = writeFile(outputPath, mergedData)
        else
            success = jsonWriteFile(outputPath, mergedData, true)
        end
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

local function finalizeConflictResolution(resolvedCount, skippedCount, totalConflicts, resolutionData, versionChanged)
    saveResolutionIndex(resolutionData)
    
    conflictCounts = {
        total = totalConflicts,
        resolved = resolvedCount,
        skipped = skippedCount,
        failed = totalConflicts - resolvedCount - skippedCount,
        lastRun = os.time(),
        versionChanged = versionChanged or false
    }
    
    local message = string.format("Resolved %d/%d conflicts (%d skipped)", 
                                  resolvedCount, totalConflicts, skippedCount)
    if versionChanged then
        message = message .. " [Version changed - complete rebuild]"
    end
    log('I', 'ConflictResolver', message)

    local duration = os.clock() - conflictStartClock
    local cacheStats = getCacheStats()
    log('I', 'ConflictResolver', string.format('Conflict resolution took %0.3f seconds (cache entries: %d)', 
        duration, cacheStats.totalCacheEntries))
    
    if resolvedCount > 0 or skippedCount > 0 then
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
    
    if resolvedCount > 0 or skippedCount > 0 then
        closeAllZipCaches()
    end
    
    return {
        success = resolvedCount > 0 or skippedCount > 0,
        message = message,
        resolvedCount = resolvedCount,
        skippedCount = skippedCount,
        totalConflicts = totalConflicts,
        conflicts = resolvedConflicts
    }
end

local function processConflicts(conflicts, resolutionIndex)
    local resolvedCount = 0
    local skippedCount = 0
    local totalConflicts = tableSize(conflicts)
    
    -- Log version change status
    if resolutionIndex.versionChanged then
        log('I', 'ConflictResolver', 'Version changed - forcing complete rebuild of all resolutions')
        resolvedConflicts = {}  -- Clear the resolved conflicts cache
    end
    
    -- Always save the resolution index, even if no conflicts
    if totalConflicts == 0 then
        saveResolutionIndex(resolutionIndex.resolutions or {})
        local message = resolutionIndex.versionChanged and "No conflicts found (version changed)" or "No conflicts found"
        return {
            success = true,
            message = message,
            resolvedCount = 0,
            totalConflicts = 0
        }
    end
    
    for filePath, modsList in pairs(conflicts) do
        if shouldSkipMerge(filePath, modsList, resolutionIndex) then
            local resolutions = resolutionIndex.resolutions or {}
            resolvedConflicts[filePath] = resolutions[filePath]
            skippedCount = skippedCount + 1
        else
            -- Log rebuild reason for debugging
            if resolutionIndex.versionChanged then
                log('D', 'ConflictResolver', 'Rebuilding ' .. filePath .. ' (version changed)')
            end
            
            if mergeConflictingFiles(filePath, modsList) then
                local outputPath = MERGE_OUTPUT_DIR .. filePath
                if FS:fileExists(outputPath) then
                    local outputContent = readFile(outputPath)
                    local outputHash = computeFileHash(outputContent)
                    recordResolution(filePath, modsList, outputHash, resolutionIndex)
                    local resolutions = resolutionIndex.resolutions or {}
                    resolvedConflicts[filePath] = resolutions[filePath]
                end
                resolvedCount = resolvedCount + 1
            end
        end
    end
    
    return finalizeConflictResolution(resolvedCount, skippedCount, totalConflicts, resolutionIndex.resolutions or {}, resolutionIndex.versionChanged)
end

local function resolveConflicts(forceRun)
    conflictStartTime = os.time()
    conflictStartClock = os.clock()
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
    
    local resolutionIndex = loadResolutionIndex()
    local conflicts = findFileConflicts()
    pruneObsoleteResolutions(conflicts, resolutionIndex)
    
    return processConflicts(conflicts, resolutionIndex)
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
    closeAllZipCaches()
    
    if FS:fileExists(RESOLUTION_INDEX_FILE) then
        FS:remove(RESOLUTION_INDEX_FILE)
    end
    
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

local function onVehicleSwitched()
    core_jobSystem.create(function(job)
        job.sleep(1)
        core_input_bindings.getUsedBindingsFiles()
    end)
end

M.onVehicleSwitched = onVehicleSwitched
M.resolveConflicts = resolveConflicts
M.getConflictStatus = getConflictStatus
M.clearResolvedConflicts = clearResolvedConflicts
M.findFileConflicts = findFileConflicts

M.clearMergeOutputDirectory = clearMergeOutputDirectory
M.mountConflictResolver = mountConflictResolver
M.unmountConflictResolver = unmountConflictResolver

M.getActiveMods = getActiveMods
M.onModActivated = onModActivated
M.onModDeactivated = onModDeactivated

M.clearAllCaches = clearAllCaches
M.getCacheStats = getCacheStats

M.manifestIsStale = manifestIsStale
M.buildManifest = buildManifest
M.loadManifestList = loadManifestList

M.detectJsonFormat = detectJsonFormat
M.parseJsonContent = parseJsonContent
M.generateUniqueKey = generateUniqueKey
M.mergeJsonLines = mergeJsonLines
M.mergeSingleJsonObjects = mergeSingleJsonObjects
M.objectsToJsonFormat = objectsToJsonFormat

M.loadResolutionIndex = loadResolutionIndex
M.saveResolutionIndex = saveResolutionIndex
M.pruneObsoleteResolutions = pruneObsoleteResolutions
M.shouldSkipMerge = shouldSkipMerge
M.recordResolution = recordResolution

M.quickScanForPotentialConflicts = quickScanForPotentialConflicts
M.computePartHashesForEntry = computePartHashesForEntry
M.allPartHashesEqual = allPartHashesEqual
M.stripBOM = stripBOM

return M