local M = {}

-- Simple analysis cache to avoid reprocessing identical content
local ANALYSIS_CACHE_MAX = 128
local analysisCache = {}
local analysisCacheOrder = {}

local function cachePut(key, value)
    if not analysisCache[key] then
        analysisCacheOrder[#analysisCacheOrder + 1] = key
    end
    analysisCache[key] = value
    if #analysisCacheOrder > ANALYSIS_CACHE_MAX then
        local trim = math.floor(ANALYSIS_CACHE_MAX / 2)
        for i = 1, trim do
            local k = analysisCacheOrder[i]
            analysisCache[k] = nil
        end
        local newOrder = {}
        for i = trim + 1, #analysisCacheOrder do
            newOrder[#newOrder + 1] = analysisCacheOrder[i]
        end
        analysisCacheOrder = newOrder
    end
end

local function cacheGet(key)
    return analysisCache[key]
end

local function fastHash(s)
    local h = 5381
    for i = 1, #s do
        h = ((h * 33) + string.byte(s, i)) % 0x100000000
    end
    return tostring(h)
end

-- Pattern matching utilities
local function trimWhitespace(str)
    if not str then return "" end
    return str:match("^%s*(.-)%s*$")
end

local function escapePattern(str)
    return (str:gsub("(%W)", "%%%1"))
end

-- Find the end of a multiline construct (table, function call, etc.)
local function findMultilineEnd(lines, startLine, openChar, closeChar)
    local depth = 0
    
    for i = startLine, #lines do
        local line = lines[i]
        local j = 1
        
        while j <= #line do
            local char = line:sub(j, j)
            
            -- Simple bracket counting (ignore strings for now to avoid complexity)
            if char == openChar then
                depth = depth + 1
            elseif char == closeChar then
                depth = depth - 1
                if depth == 0 then
                    return i, j
                end
            end
            
            j = j + 1
        end
    end
    
    return nil, nil
end

-- Check if a line starts a multiline construct
local function isMultilineStart(line)
    local trimmed = trimWhitespace(line)
    
    -- Check for table assignment that might be multiline
    if trimmed:match("=%s*{%s*$") or trimmed:match("=%s*{[^}]*$") then
        return "table", "{"
    end
    
    -- Check for function call that might be multiline
    if trimmed:match("%(.*[^%)]*$") then
        return "function_call", "("
    end
    
    -- Check for function calls that start with a function name followed by open parenthesis
    if trimmed:match("^[%w_%.]+%s*%(") then
        return "function_call", "("
    end
    
    -- Check for standalone table
    if trimmed:match("^{%s*$") or trimmed:match("^{[^}]*$") then
        return "table", "{"
    end
    
    return nil, nil
end

local function findModulePattern(lines)
    local candidates = {}
    local returnLine = nil
    local returnVar = nil
    
    -- First pass: find all local var = {} declarations
    for i, line in ipairs(lines) do
        local trimmed = trimWhitespace(line)
        
        -- Look for module declaration pattern: local VAR = {}
        local localVar = trimmed:match("^local%s+([%w_]+)%s*=%s*{%s*}%s*$")
        if localVar then
            candidates[localVar] = i
        end
    end
    
    -- Second pass: find return statement
    for i, line in ipairs(lines) do
        local trimmed = trimWhitespace(line)
        local foundReturnVar = trimmed:match("^return%s+([%w_]+)%s*$")
        if foundReturnVar and candidates[foundReturnVar] then
            returnVar = foundReturnVar
            returnLine = i
            break
        end
    end
    
    if returnVar then
        return returnVar, candidates[returnVar], returnLine
    else
        -- If no matching return found, return the first candidate (might be a module without return)
        for var, line in pairs(candidates) do
            return var, line, nil
        end
    end
    
    return nil, nil, nil
end

local function findFunctionEnd(lines, startLine)
    local depth = 0
    local inFunction = false
    
    for i = startLine, #lines do
        local trimmed = trimWhitespace(lines[i])
        
        -- Skip empty lines and comments for processing but continue counting
        if trimmed == "" or trimmed:match("^%-%-") then
            -- Continue to next line
        -- Check for function start
        elseif trimmed:match("^local%s+function") or trimmed:match("^function") then
            if i == startLine then
                inFunction = true
                depth = 1
            else
                depth = depth + 1
            end
        -- Check for other block starts
        elseif trimmed:match("^if%s") or trimmed:match("^for%s") or trimmed:match("^while%s") or trimmed:match("^repeat%s") or trimmed:match("^do%s*$") then
            if inFunction then
                depth = depth + 1
            end
        -- Check for block ends
        elseif trimmed:match("^end%s*$") then
            if inFunction then
                depth = depth - 1
                if depth == 0 then
                    return i
                end
            end
        elseif trimmed:match("^until%s") then
            if inFunction then
                depth = depth - 1
                if depth == 0 then
                    return i
                end
            end
        end
    end
    
    return nil
end

local function findStructureEnd(lines, startLine, structType)
    local depth = 1
    local endKeyword = "end"
    if structType == "repeat" then
        endKeyword = "until"
    end
    
    for i = startLine + 1, #lines do
        local trimmed = trimWhitespace(lines[i])
        
        -- Check for nested structures
        if trimmed:match("^if%s") or trimmed:match("^for%s") or trimmed:match("^while%s") or 
           trimmed:match("^repeat%s") or trimmed:match("^function") or trimmed:match("^do%s*$") then
            depth = depth + 1
        elseif (endKeyword == "end" and trimmed:match("^end%s*$")) or 
               (endKeyword == "until" and trimmed:match("^until%s")) then
            depth = depth - 1
            if depth == 0 then
                return i
            end
        end
    end
    
    return nil
end

-- Placeholder for analyzeIfBranches - will be defined after analyzeStructureRecursive
local analyzeIfBranches

local function analyzeStructureRecursive(lines, startLine, endLine, baseLineOffset)
    local result = {}
    
    if not endLine then
        endLine = #lines
    end
    
    local i = startLine
    while i <= endLine do
        local line = lines[i]
        local trimmed = trimWhitespace(line)
        local relativeLine = i - baseLineOffset
        local jumped = false  -- Track if we jumped to a new position
        
        -- Check for functions
        local funcName = trimmed:match("^local%s+function%s+([%w_]+)%s*%(")
        local moduleVar, moduleFuncName = trimmed:match("^function%s+([%w_]+)%.([%w_]+)%s*%(")
        local anonymousFunc = trimmed:match("^function%s*%(")
        
        if funcName or moduleFuncName or anonymousFunc then
            local name = funcName or moduleFuncName
            local funcType = funcName and "local_function" or "module_function"
            
            -- For anonymous functions, they should be part of a multiline function call
            if anonymousFunc then
                -- Check if this is part of a multiline function call
                local constructType, openChar = isMultilineStart(trimmed)
                if constructType == "function_call" then
                    -- This is part of a multiline function call, handle it as such
                    local closeChar = ")"
                    local endLine, endPos = findMultilineEnd(lines, i, openChar, closeChar)
                    
                    if endLine then
                        -- Collect the full multiline function call
                        local fullValue = {}
                        for j = i, endLine do
                            table.insert(fullValue, lines[j])
                        end
                        
                        if not result.otherStatements then result.otherStatements = {} end
                        table.insert(result.otherStatements, {
                            line = relativeLine,
                            statement = table.concat(fullValue, "\n"),
                            fullStatement = table.concat(fullValue, "\n")
                        })
                        
                        i = endLine + 1
                        jumped = true
                    else
                        -- Will be incremented at end of loop
                    end
                else
                    -- Check if this is part of a function call that started earlier
                    -- Look backwards to see if we're inside a function call
                    local inFunctionCall = false
                    local callStartLine = i
                    
                    -- Look backwards to find the start of the function call
                    for j = i - 1, math.max(1, i - 10), -1 do
                        local checkLine = trimWhitespace(lines[j])
                        if checkLine:match("^[%w_%.]+%s*%(") then
                            -- Found the start of a function call
                            inFunctionCall = true
                            callStartLine = j
                            break
                        elseif checkLine:match("^%s*$") or checkLine:match("^%-%-") then
                            -- Skip empty lines and comments
                        else
                            -- Not part of a function call
                            break
                        end
                    end
                    
                    if inFunctionCall then
                        -- This anonymous function is part of a function call
                        local closeChar = ")"
                        local endLine, endPos = findMultilineEnd(lines, callStartLine, "(", closeChar)
                        
                        if endLine then
                            -- Collect the full multiline function call
                            local fullValue = {}
                            for j = callStartLine, endLine do
                                table.insert(fullValue, lines[j])
                            end
                            
                            if not result.otherStatements then result.otherStatements = {} end
                            table.insert(result.otherStatements, {
                                line = callStartLine - baseLineOffset,
                                statement = table.concat(fullValue, "\n"),
                                fullStatement = table.concat(fullValue, "\n")
                            })
                            
                            i = endLine + 1
                            jumped = true
                        else
                            -- Will be incremented at end of loop
                        end
                    else
                        -- Treat as standalone anonymous function
                        local funcEndLine = findFunctionEnd(lines, i)
                        if funcEndLine then
                            local content = {}
                            for j = i, funcEndLine do
                                table.insert(content, lines[j])
                            end
                            
                            -- Extract parameters for anonymous function
                            local params = {}
                            local paramStr = trimmed:match("function%s*%((.-)%)")
                            if paramStr and paramStr ~= "" then
                                for param in paramStr:gmatch("([%w_]+)") do
                                    table.insert(params, param)
                                end
                            end
                            
                            -- Recursively analyze function internals
                            local internals = analyzeStructureRecursive(lines, i + 1, funcEndLine - 1, i)
                            
                            if not result.functions then result.functions = {} end
                            result.functions["anonymous"] = {
                                type = "anonymous_function",
                                startLine = relativeLine,
                                endLine = funcEndLine - baseLineOffset,
                                parameters = params,
                                content = content,
                                internals = internals
                            }
                            
                            i = funcEndLine + 1
                            jumped = true
                        else
                            -- Will be incremented at end of loop
                        end
                    end
                end
            else
                -- Handle named functions as before
                local funcEndLine = findFunctionEnd(lines, i)
                
                if funcEndLine then
                    local content = {}
                    for j = i, funcEndLine do
                        table.insert(content, lines[j])
                    end
                    
                    -- Extract parameters
                    local params = {}
                    local paramPattern = funcName and "^local%s+function%s+[%w_]+%s*%((.-)%)" or "^function%s+[%w_]+%.[%w_]+%s*%((.-)%)"
                    local paramStr = trimmed:match(paramPattern)
                    if paramStr and paramStr ~= "" then
                        for param in paramStr:gmatch("([%w_]+)") do
                            table.insert(params, param)
                        end
                    end
                    
                    -- Recursively analyze function internals (excluding the function declaration and end lines)
                    local internals = analyzeStructureRecursive(lines, i + 1, funcEndLine - 1, i)
                    
                    if not result.functions then result.functions = {} end
                    result.functions[name] = {
                        type = funcType,
                        startLine = relativeLine,
                        endLine = funcEndLine - baseLineOffset,
                        parameters = params,
                        content = content,
                        internals = internals,
                        moduleVar = moduleVar
                    }
                    
                    -- Skip to after the function end to avoid analyzing its content again at this scope level
                    i = funcEndLine + 1
                    jumped = true
                else
                    -- Will be incremented at end of loop
                end
            end
            
        -- Check for do blocks
        elseif trimmed:match("^do%s*$") then
            local doEndLine = findStructureEnd(lines, i, "do")
            if doEndLine then
                local doContent = {}
                for j = i, doEndLine do
                    table.insert(doContent, lines[j])
                end
                
                -- Recursively analyze do block internals
                local internals = analyzeStructureRecursive(lines, i + 1, doEndLine - 1, i)
                
                if not result.doBlocks then result.doBlocks = {} end
                table.insert(result.doBlocks, {
                    startLine = relativeLine,
                    endLine = doEndLine - baseLineOffset,
                    content = doContent,
                    internals = internals
                })
                
                -- Skip to after the do block end to avoid analyzing its content again at this scope level
                i = doEndLine + 1
                jumped = true
            else
                -- Will be incremented at end of loop
            end
            
        -- Check for control structures
        elseif trimmed:match("^if%s") or trimmed:match("^for%s") or trimmed:match("^while%s") or trimmed:match("^repeat%s") then
            local structType = nil
            if trimmed:match("^if%s") then structType = "if"
            elseif trimmed:match("^for%s") then structType = "for"
            elseif trimmed:match("^while%s") then structType = "while"
            elseif trimmed:match("^repeat%s") then structType = "repeat"
            end
            
            local structEndLine = findStructureEnd(lines, i, structType)
            if structEndLine then
                local structContent = {}
                for j = i, structEndLine do
                    table.insert(structContent, lines[j])
                end
                
                -- For if statements, analyze the hierarchical structure
                if structType == "if" then
                    local absoluteIfLine = i
                    local absoluteEndLine = structEndLine
                    local branches = analyzeIfBranches(lines, absoluteIfLine, absoluteEndLine, baseLineOffset)
                    local internals = analyzeStructureRecursive(lines, i + 1, structEndLine - 1, i)
                    
                    if not result.controlStructures then result.controlStructures = {} end
                    table.insert(result.controlStructures, {
                        type = structType,
                        startLine = relativeLine,
                        endLine = structEndLine - baseLineOffset,
                        condition = trimmed,
                        content = structContent,
                        internals = internals,
                        branches = branches
                    })
                else
                    -- Recursively analyze structure internals for non-if structures
                    local internals = analyzeStructureRecursive(lines, i + 1, structEndLine - 1, i)
                    
                    if not result.controlStructures then result.controlStructures = {} end
                    table.insert(result.controlStructures, {
                        type = structType,
                        startLine = relativeLine,
                        endLine = structEndLine - baseLineOffset,
                        condition = trimmed,
                        content = structContent,
                        internals = internals
                    })
                end
                
                -- Skip to after the structure end to avoid analyzing its content again at this scope level
                i = structEndLine + 1
                jumped = true
            else
                -- Will be incremented at end of loop
            end
            
        else
            -- Check for table function assignments (M.func = function...) - MUST come first
            if trimmed:match("^([%w_]+)%.([%w_]+)%s*=%s*function") then
                local tableName, funcName = trimmed:match("^([%w_]+)%.([%w_]+)%s*=%s*function")
                -- Need to find the end of this function assignment
                local funcEndLine = nil
                local depth = 0
                local foundFunction = false
                
                for j = i, #lines do
                    local checkLine = trimWhitespace(lines[j])
                    if checkLine:match("function") and j == i then
                        foundFunction = true
                        depth = 1
                    elseif foundFunction then
                        if checkLine:match("^function") or checkLine:match("^if%s") or checkLine:match("^for%s") or 
                           checkLine:match("^while%s") or checkLine:match("^repeat%s") or checkLine:match("^do%s*$") then
                            depth = depth + 1
                        elseif checkLine:match("^end%s*$") then
                            depth = depth - 1
                            if depth == 0 then
                                funcEndLine = j
                                break
                            end
                        elseif checkLine:match("^until%s") then
                            depth = depth - 1
                            if depth == 0 then
                                funcEndLine = j
                                break
                            end
                        end
                    end
                end
                
                if funcEndLine then
                    local content = {}
                    for j = i, funcEndLine do
                        table.insert(content, lines[j])
                    end
                    
                    -- Extract parameters
                    local params = {}
                    local paramStr = trimmed:match("function%s*%((.-)%)")
                    if paramStr and paramStr ~= "" then
                        for param in paramStr:gmatch("([%w_]+)") do
                            table.insert(params, param)
                        end
                    end
                    
                    -- Recursively analyze function internals
                    local internals = analyzeStructureRecursive(lines, i + 1, funcEndLine - 1, i)
                    
                    if not result.functions then result.functions = {} end
                    result.functions[funcName] = {
                        type = "table_function",
                        startLine = relativeLine,
                        endLine = funcEndLine - baseLineOffset,
                        parameters = params,
                        content = content,
                        internals = internals,
                        tableName = tableName
                    }
                    
                    -- Skip to after the function end to avoid analyzing its content again at this scope level
                    i = funcEndLine + 1
                    jumped = true
                else
                    i = i + 1
                end
                
            -- Check for assignments (including multiline) - MUST come after table function assignments
            elseif trimmed:match("^([%w_.]+)%s*=%s*(.+)$") then
                local assignVar, assignValue = trimmed:match("^([%w_.]+)%s*=%s*(.+)$")
                if not trimmed:match("^local%s") then
                    -- Check if this is a multiline construct
                    local constructType, openChar = isMultilineStart(trimmed)
                    if constructType and openChar then
                        local closeChar = openChar == "{" and "}" or openChar == "(" and ")" or openChar == "[" and "]" or openChar
                        local endLine, endPos = findMultilineEnd(lines, i, openChar, closeChar)
                        
                        if endLine then
                            -- Collect the full multiline value
                            local fullValue = {}
                            for j = i, endLine do
                                if j == i then
                                    -- For the first line, extract only the value part (after the =)
                                    local valuePart = lines[j]:match("^%s*[%w_.]+%s*=%s*(.*)$")
                                    if valuePart then
                                        table.insert(fullValue, valuePart)
                                    end
                                else
                                    table.insert(fullValue, lines[j])
                                end
                            end
                            
                            if not result.assignments then result.assignments = {} end
                            table.insert(result.assignments, {
                                variable = assignVar,
                                value = table.concat(fullValue, "\n"),
                                line = relativeLine,
                                multiline = true,
                                startLine = relativeLine,
                                endLine = endLine - baseLineOffset
                            })
                            
                            i = endLine + 1
                            jumped = true
                        else
                            if not result.assignments then result.assignments = {} end
                            table.insert(result.assignments, {
                                variable = assignVar,
                                value = assignValue,
                                line = relativeLine
                            })
                            -- Will be incremented at end of loop
                        end
                    else
                        if not result.assignments then result.assignments = {} end
                        table.insert(result.assignments, {
                            variable = assignVar,
                            value = assignValue,
                            line = relativeLine
                        })
                    end
                end
                -- Continue to end of loop for increment
            
            -- Check for bracket-indexed assignments like arr[i] = value (including multiline values)
            elseif trimmed:match("^([%w_%.]+%b%[%].-)%s*=%s*(.+)$") then
                local assignVar, assignValue = trimmed:match("^([%w_%.]+%b%[%].-)%s*=%s*(.+)$")
                -- Treat as non-local assignment
                local constructType, openChar = isMultilineStart(trimmed)
                if constructType and openChar then
                    local closeChar = openChar == "{" and "}" or openChar == "(" and ")" or openChar == "[" and "]" or openChar
                    local endLine, endPos = findMultilineEnd(lines, i, openChar, closeChar)
                    if endLine then
                        local fullValue = {}
                        for j = i, endLine do
                            if j == i then
                                local valuePart = lines[j]:match("^%s*.-=%s*(.*)$")
                                if valuePart then table.insert(fullValue, valuePart) end
                            else
                                table.insert(fullValue, lines[j])
                            end
                        end
                        if not result.assignments then result.assignments = {} end
                        table.insert(result.assignments, {
                            variable = assignVar,
                            value = table.concat(fullValue, "\n"),
                            line = relativeLine,
                            multiline = true,
                            startLine = relativeLine,
                            endLine = endLine - baseLineOffset
                        })
                        i = endLine + 1
                        jumped = true
                    else
                        if not result.assignments then result.assignments = {} end
                        table.insert(result.assignments, { variable = assignVar, value = assignValue, line = relativeLine })
                    end
                else
                    if not result.assignments then result.assignments = {} end
                    table.insert(result.assignments, { variable = assignVar, value = assignValue, line = relativeLine })
                end
                -- Continue to end of loop for increment
            
            -- Check for elseif statements
            elseif trimmed:match("^elseif%s") then
                if not result.otherStatements then result.otherStatements = {} end
                table.insert(result.otherStatements, {
                    line = relativeLine,
                    statement = trimmed,
                    fullStatement = trimmed
                })
            -- Check for else statements
            elseif trimmed:match("^else%s*$") then
                if not result.otherStatements then result.otherStatements = {} end
                table.insert(result.otherStatements, {
                    line = relativeLine,
                    statement = trimmed,
                    fullStatement = trimmed
                })
            -- Check for return statements
            elseif trimmed:match("^return") then
                local returnValue = trimmed:match("^return%s*(.*)$")
                if not result.returnStatements then result.returnStatements = {} end
                table.insert(result.returnStatements, {
                    line = relativeLine,
                    value = returnValue or "",
                    fullStatement = trimmed
                })
            -- Check for break statements
            elseif trimmed:match("^break%s*$") then
                if not result.breakStatements then result.breakStatements = {} end
                table.insert(result.breakStatements, {
                    line = relativeLine,
                    fullStatement = trimmed
                })
            -- Check for goto statements
            elseif trimmed:match("^goto%s+([%w_]+)%s*$") then
                local labelName = trimmed:match("^goto%s+([%w_]+)%s*$")
                if not result.gotoStatements then result.gotoStatements = {} end
                table.insert(result.gotoStatements, {
                    line = relativeLine,
                    label = labelName,
                    fullStatement = trimmed
                })
            -- Check for labels
            elseif trimmed:match("^::([%w_]+)::%s*$") then
                local labelName = trimmed:match("^::([%w_]+)::%s*$")
                if not result.labels then result.labels = {} end
                table.insert(result.labels, {
                    line = relativeLine,
                    name = labelName,
                    fullStatement = trimmed
                })
            -- Check for variable declarations (including multiline)
            elseif trimmed:match("^local%s+([%w_]+)%s*=%s*(.+)$") then
                local varName, value = trimmed:match("^local%s+([%w_]+)%s*=%s*(.+)$")
                if not trimmed:match("^local%s+function") then
                    -- Check if this is a multiline construct
                    local constructType, openChar = isMultilineStart(trimmed)
                    if constructType and openChar then
                        local closeChar = openChar == "{" and "}" or openChar == "(" and ")" or openChar == "[" and "]" or openChar
                        local endLine, endPos = findMultilineEnd(lines, i, openChar, closeChar)
                        
                        if endLine then
                            -- Collect the full multiline value
                            local fullValue = {}
                            for j = i, endLine do
                                if j == i then
                                    -- For the first line, extract only the value part (after the =)
                                    local valuePart = lines[j]:match("^%s*local%s+[%w_]+%s*=%s*(.*)$")
                                    if valuePart then
                                        table.insert(fullValue, valuePart)
                                    end
                                else
                                    table.insert(fullValue, lines[j])
                                end
                            end
                            
                            if not result.variables then result.variables = {} end
                            result.variables[varName] = {
                                line = relativeLine,
                                value = table.concat(fullValue, "\n"),
                                multiline = true,
                                startLine = relativeLine,
                                endLine = endLine - baseLineOffset
                            }
                            
                            i = endLine + 1
                            jumped = true
                        else
                            if not result.variables then result.variables = {} end
                            result.variables[varName] = {
                                line = relativeLine,
                                value = value
                            }
                            -- Will be incremented at end of loop
                        end
                    else
                        if not result.variables then result.variables = {} end
                        result.variables[varName] = {
                            line = relativeLine,
                            value = value
                        }
                    end
                end
                -- Continue to end of loop for increment

                
            -- Check for other standalone statements (function calls, etc.)
            elseif trimmed ~= "" and not trimmed:match("^%-%-") and not trimmed:match("^end%s*$") and not trimmed:match("^else") and not trimmed:match("^elseif") then
            -- Check if this might be a multiline function call
            local constructType, openChar = isMultilineStart(trimmed)
            if constructType == "function_call" then
                local closeChar = ")"
                local endLine, endPos = findMultilineEnd(lines, i, openChar, closeChar)
                
                if endLine then
                    -- Collect the full multiline function call
                    local fullValue = {}
                    for j = i, endLine do
                        table.insert(fullValue, lines[j])
                    end
                    
                    if not result.otherStatements then result.otherStatements = {} end
                    table.insert(result.otherStatements, {
                        line = relativeLine,
                        statement = table.concat(fullValue, "\n"),
                        fullStatement = table.concat(fullValue, "\n")
                    })
                    
                    i = endLine + 1
                    jumped = true
                else
                    if not result.otherStatements then result.otherStatements = {} end
                    table.insert(result.otherStatements, {
                        line = relativeLine,
                        statement = trimmed,
                        fullStatement = trimmed
                    })
                end
            else
                if not result.otherStatements then result.otherStatements = {} end
                table.insert(result.otherStatements, {
                    line = relativeLine,
                    statement = trimmed,
                    fullStatement = trimmed
                })
            end
            end
            
            -- Only increment if we haven't jumped to a new position
            if not jumped then
                i = i + 1
            end
        end
    end
    
    return result
end

-- Define analyzeIfBranches after analyzeStructureRecursive to avoid circular dependency
analyzeIfBranches = function(lines, startLine, endLine, baseLineOffset)
    local branches = {}
    local currentBranch = nil
    local branchStartLine = startLine + 1
    
    -- Extract the initial if condition (handle multiline conditions)
    local ifCondition = nil
    if startLine <= #lines then
        local conditionLines = {}
        local foundThen = false
        
        -- Start from the if line and collect until we find "then"
        for i = startLine, endLine - 1 do
            local line = lines[i]
            if not line then break end
            
            if i == startLine then
                -- Extract condition from first line (remove "if ")
                local firstCondition = line:match("^%s*if%s*(.+)$")
                if firstCondition then
                    -- Check if "then" is on the same line
                    if firstCondition:match("then%s*$") then
                        firstCondition = firstCondition:gsub("%s*then%s*$", "")
                        table.insert(conditionLines, firstCondition)
                        foundThen = true
                        break
                    else
                        table.insert(conditionLines, firstCondition)
                    end
                end
            else
                -- Check subsequent lines for continuation and "then"
                local trimmed = trimWhitespace(line)
                if trimmed:match("then%s*$") then
                    -- Remove "then" and add the rest
                    local conditionPart = trimmed:gsub("%s*then%s*$", "")
                    if conditionPart ~= "" then
                        table.insert(conditionLines, conditionPart)
                    end
                    foundThen = true
                    break
                else
                    -- Add the whole line as part of condition
                    table.insert(conditionLines, trimmed)
                end
            end
        end
        
        if foundThen and #conditionLines > 0 then
            ifCondition = table.concat(conditionLines, " ")
            -- Update branchStartLine to start after the line containing "then"
            for i = startLine, endLine - 1 do
                local line = lines[i]
                if line and trimWhitespace(line):match("then%s*$") then
                    branchStartLine = i + 1
                    break
                end
            end
        end
    end
    
    -- Track nesting depth to only consider elseif/else at the same level
    local nestingDepth = 0
    
    -- Create the initial if branch before starting the loop
    if ifCondition then
        currentBranch = {
            type = "if",
            startLine = startLine - baseLineOffset,
            condition = ifCondition,
            content = {}
        }
    end
    
    -- Start nesting tracking from the line after "then"
    local startTrackingLine = branchStartLine
    
    for i = startTrackingLine, endLine - 1 do
        local trimmed = trimWhitespace(lines[i])
        local relativeLine = i - baseLineOffset
        
        -- Track nesting depth for if/then/end blocks
        if trimmed:match("^if%s") or trimmed:match("^for%s") or trimmed:match("^while%s") or trimmed:match("^repeat%s") or trimmed:match("^do%s*$") then
            nestingDepth = nestingDepth + 1
        elseif trimmed:match("^end%s*$") or trimmed:match("^until%s") then
            nestingDepth = nestingDepth - 1
        end
        
        -- Only process elseif/else at the same nesting level (depth 0)
        if nestingDepth == 0 and trimmed:match("^elseif%s") then
            -- Save the previous branch if it exists
            if currentBranch then
                currentBranch.endLine = i - 1
                currentBranch.content = {}
                for j = branchStartLine, i - 1 do
                    table.insert(currentBranch.content, lines[j])
                end
                
                -- Recursively analyze the branch internals
                currentBranch.internals = analyzeStructureRecursive(lines, branchStartLine, i - 1, baseLineOffset)
                
                table.insert(branches, currentBranch)
            end
            
            -- Start a new elseif branch
            local elseifCondition = trimmed:match("^elseif%s*(.+)$")
            if elseifCondition then
                elseifCondition = elseifCondition:gsub("%s*then%s*$", "")  -- Remove "then" from condition
            end
            currentBranch = {
                type = "elseif",
                startLine = relativeLine,
                condition = elseifCondition,
                content = {}
            }
            branchStartLine = i + 1  -- Start content after the elseif line
            
        elseif nestingDepth == 0 and trimmed:match("^else%s*$") then
            -- Save the previous branch if it exists
            if currentBranch then
                currentBranch.endLine = i - 1
                currentBranch.content = {}
                for j = branchStartLine, i - 1 do
                    table.insert(currentBranch.content, lines[j])
                end
                
                -- Recursively analyze the branch internals
                currentBranch.internals = analyzeStructureRecursive(lines, branchStartLine, i - 1, baseLineOffset)
                
                table.insert(branches, currentBranch)
            end
            
            -- Start the else branch
            currentBranch = {
                type = "else",
                startLine = relativeLine,
                condition = trimmed,
                content = {}
            }
            branchStartLine = i + 1  -- Start content after the else line
            
        end
    end
    
    -- Save the last branch
    if currentBranch then
        currentBranch.endLine = endLine - 1 - baseLineOffset
        currentBranch.content = {}
        for j = branchStartLine, endLine - 1 do
            table.insert(currentBranch.content, lines[j])
        end
        
        -- Recursively analyze the branch internals
        currentBranch.internals = analyzeStructureRecursive(lines, branchStartLine, endLine - 1, baseLineOffset)
        
        table.insert(branches, currentBranch)
    end
    
    return branches
end

local function analyzeVariables(lines)
    local variables = {}
    local functions = {}
    local scopeDepth = 0
    local inFunction = false
    
    for i, line in ipairs(lines) do
        local trimmed = trimWhitespace(line)
        
        -- Function definitions (capture before updating scope)
        local funcName = trimmed:match("^local%s+function%s+([%w_]+)%s*%(")
        if funcName and scopeDepth == 0 then
            local endLine = findFunctionEnd(lines, i)
            local content = {}
            if endLine then
                for j = i, endLine do
                    table.insert(content, lines[j])
                end
            end
            
            -- Extract parameters
            local params = {}
            local paramStr = trimmed:match("^local%s+function%s+[%w_]+%s*%((.-)%)")
            if paramStr and paramStr ~= "" then
                for param in paramStr:gmatch("([%w_]+)") do
                    table.insert(params, param)
                end
            end
            
            -- Analyze function internals
            local internals = analyzeStructureRecursive(lines, i + 1, endLine - 1, i)
            
            functions[funcName] = {
                startLine = i,
                endLine = endLine,
                type = "local_function",
                content = content,
                parameters = params,
                internals = internals
            }
        end
        
        -- Track scope depth
        if trimmed:match("^local%s+function") or trimmed:match("^function") or 
           trimmed:match("^if%s") or trimmed:match("^for%s") or trimmed:match("^while%s") or trimmed:match("^repeat%s") then
            if trimmed:match("function") then
                inFunction = true
            end
            scopeDepth = scopeDepth + 1
        elseif trimmed:match("^end%s*$") or trimmed:match("^until%s") then
            scopeDepth = scopeDepth - 1
            if scopeDepth == 0 then
                inFunction = false
            end
        end
        
        -- Only analyze variables at module scope (scopeDepth == 0)
        if scopeDepth == 0 and not inFunction then
            -- Local variable assignments
            local varName, value = trimmed:match("^local%s+([%w_]+)%s*=%s*(.+)$")
            if varName then
                variables[varName] = {
                    line = i,
                    value = value,
                    type = "local"
                }
            end
        end
        
        -- Module function assignments (M.funcName = ...)
        local moduleVar, moduleFuncName = trimmed:match("^function%s+([%w_]+)%.([%w_]+)%s*%(")
        if moduleVar and moduleFuncName then
            local endLine = findFunctionEnd(lines, i)
            local content = {}
            if endLine then
                for j = i, endLine do
                    table.insert(content, lines[j])
                end
            end
            
            -- Extract parameters
            local params = {}
            local paramStr = trimmed:match("^function%s+[%w_]+%.[%w_]+%s*%((.-)%)")
            if paramStr and paramStr ~= "" then
                for param in paramStr:gmatch("([%w_]+)") do
                    table.insert(params, param)
                end
            end
            
            -- Analyze function internals
            local internals = analyzeStructureRecursive(lines, i + 1, endLine - 1, i)
            
            functions[moduleFuncName] = {
                startLine = i,
                endLine = endLine,
                type = "module_function",
                moduleVar = moduleVar,
                content = content,
                parameters = params,
                internals = internals
            }
        end
    end
    
    return variables, functions
end

-- Analyze file structure
function M.analyzeFile(content)
    local lines = {}
    -- Handle both \n and \r\n line endings, and preserve empty lines
    content = content:gsub("\r\n", "\n"):gsub("\r", "\n")

    local contentHash = fastHash(content)
    local cached = cacheGet(contentHash)
    if cached then return cached end
    for line in (content .. "\n"):gmatch("([^\n]*)\n") do
        table.insert(lines, line)
    end
    
    local moduleVar, moduleDeclarationLine, returnLine = findModulePattern(lines)
    
    -- Use the recursive structure analyzer for complete analysis
    local structure = analyzeStructureRecursive(lines, 1, #lines, 0)
    
    local analysis = {
        totalLines = #lines,
        hasModulePattern = moduleVar ~= nil,
        moduleVariable = moduleVar,
        moduleDeclarationLine = moduleDeclarationLine,
        returnLine = returnLine,
        structure = structure
    }
    
    cachePut(contentHash, analysis)
    return analysis
end

local function writeStructureToLua(structure, indent, exports, moduleVar)
    local lines = {}
    local indentStr = string.rep("    ", indent)
    
    -- We need to write everything in the order it appears in the source
    -- Collect all items with their line numbers and sort them
    local items = {}
    
    -- Collect variables
    if structure.variables then
        for name, info in pairs(structure.variables) do
            -- Skip module variable at root level since it's handled separately
            if indent > 0 or not (name == "M" or name:match("^[A-Z]$")) then
                table.insert(items, {
                    type = "variable",
                    line = info.line,
                    name = name,
                    value = info.value,
                    info = info  -- Pass the full info object for multiline handling
                })
            end
        end
    end
    
    -- Collect functions
    if structure.functions then
        for name, func in pairs(structure.functions) do
            table.insert(items, {
                type = "function",
                line = func.startLine,
                name = name,
                func = func
            })
        end
    end
    
    -- Collect assignments
    if structure.assignments then
        for _, assign in ipairs(structure.assignments) do
            table.insert(items, {
                type = "assignment",
                line = assign.line,
                variable = assign.variable,
                value = assign.value,
                assign = assign  -- Pass the full assignment object for multiline handling
            })
        end
    end
    
    -- Collect return statements
    if structure.returnStatements then
        for _, ret in ipairs(structure.returnStatements) do
            table.insert(items, {
                type = "return",
                line = ret.line,
                statement = ret.fullStatement
            })
        end
    end
    
    -- Collect break statements
    if structure.breakStatements then
        for _, brk in ipairs(structure.breakStatements) do
            table.insert(items, {
                type = "break",
                line = brk.line,
                statement = brk.fullStatement
            })
        end
    end
    
    -- Collect goto statements
    if structure.gotoStatements then
        for _, gt in ipairs(structure.gotoStatements) do
            table.insert(items, {
                type = "goto",
                line = gt.line,
                statement = gt.fullStatement
            })
        end
    end
    
    -- Collect labels
    if structure.labels then
        for _, lbl in ipairs(structure.labels) do
            table.insert(items, {
                type = "label",
                line = lbl.line,
                statement = lbl.fullStatement
            })
        end
    end
    
    -- Collect do blocks
    if structure.doBlocks then
        for _, doBlock in ipairs(structure.doBlocks) do
            table.insert(items, {
                type = "doblock",
                line = doBlock.startLine,
                doBlock = doBlock
            })
        end
    end
    
    -- Collect other statements
    if structure.otherStatements then
        for _, stmt in ipairs(structure.otherStatements) do
            table.insert(items, {
                type = "other",
                line = stmt.line,
                statement = stmt.fullStatement
            })
        end
    end
    
    -- Collect control structures
    if structure.controlStructures then
        for _, struct in ipairs(structure.controlStructures) do
            table.insert(items, {
                type = "control",
                line = struct.startLine,
                struct = struct
            })
        end
    end
    
    -- Sort items by line number
    table.sort(items, function(a, b) return a.line < b.line end)
    
    -- Write items in order
    for _, item in ipairs(items) do
        if item.type == "variable" then
            if item.info and item.info.multiline then
                -- Handle multiline variables
                local valueLines = {}
                if item.info.value:find("\n") then
                    -- Truly multiline value
                    for line in item.info.value:gmatch("[^\n]+") do
                        table.insert(valueLines, line)
                    end
                else
                    -- Single line marked as multiline
                    table.insert(valueLines, item.info.value)
                end
                
                -- Reconstruct the variable declaration with the value
                if #valueLines > 0 then
                    -- First line gets the variable declaration
                    table.insert(lines, indentStr .. "local " .. item.name .. " = " .. valueLines[1])
                    -- Subsequent lines are added as-is (with proper indentation)
                    for i = 2, #valueLines do
                        table.insert(lines, indentStr .. valueLines[i])
                    end
                end
            else
                table.insert(lines, indentStr .. "local " .. item.name .. " = " .. item.value)
            end
            
        elseif item.type == "function" then
            local func = item.func
            local funcLine = indentStr
            if func.type == "local_function" then
                funcLine = funcLine .. "local function " .. item.name .. "("
            elseif func.type == "module_function" then
                funcLine = funcLine .. "function " .. (func.moduleVar or "M") .. "." .. item.name .. "("
            elseif func.type == "table_function" then
                funcLine = funcLine .. (func.tableName or "M") .. "." .. item.name .. " = function("
            end
            
            -- Add parameters
            if func.parameters and #func.parameters > 0 then
                funcLine = funcLine .. table.concat(func.parameters, ", ")
            end
            funcLine = funcLine .. ")"
            table.insert(lines, funcLine)
            
            -- Write function internals
            if func.internals then
                local internalLines = writeStructureToLua(func.internals, indent + 1, exports, moduleVar)
                for _, line in ipairs(internalLines) do
                    table.insert(lines, line)
                end
            end
            
            table.insert(lines, indentStr .. "end")
            table.insert(lines, "")  -- Empty line after function
            
        elseif item.type == "assignment" then
            local isTopLevel = indent == 0
            local mv = moduleVar or "M"
            local isExport = isTopLevel and item.variable:match("^" .. escapePattern(mv) .. "%.[%w_]+$") ~= nil
            local target = isExport and exports or lines
            if item.assign and item.assign.multiline then
                -- Handle multiline assignments
                local valueLines = {}
                if item.assign.value:find("\n") then
                    -- Truly multiline value
                    for line in item.assign.value:gmatch("[^\n]+") do
                        table.insert(valueLines, line)
                    end
                else
                    -- Single line marked as multiline
                    table.insert(valueLines, item.assign.value)
                end
                
                -- Reconstruct the assignment with the value
                if #valueLines > 0 then
                    -- First line gets the assignment declaration
                    table.insert(target, indentStr .. item.variable .. " = " .. valueLines[1])
                    -- Subsequent lines are added as-is (with proper indentation)
                    for i = 2, #valueLines do
                        table.insert(target, indentStr .. valueLines[i])
                    end
                end
            else
                table.insert(target, indentStr .. item.variable .. " = " .. item.value)
            end
            
        elseif item.type == "return" then
            table.insert(lines, indentStr .. item.statement)
            
        elseif item.type == "break" then
            table.insert(lines, indentStr .. item.statement)
            
        elseif item.type == "goto" then
            table.insert(lines, indentStr .. item.statement)
            
        elseif item.type == "label" then
            table.insert(lines, indentStr .. item.statement)
            
        elseif item.type == "doblock" then
            local doBlock = item.doBlock
            table.insert(lines, indentStr .. "do")
            
            -- Write do block internals
            if doBlock.internals then
                local internalLines = writeStructureToLua(doBlock.internals, indent + 1, exports, moduleVar)
                for _, line in ipairs(internalLines) do
                    table.insert(lines, line)
                end
            end
            
            table.insert(lines, indentStr .. "end")
            table.insert(lines, "")  -- Empty line after do block
            
        elseif item.type == "other" then
            table.insert(lines, indentStr .. item.statement)
            
                elseif item.type == "control" then
            local struct = item.struct
            
            -- For if statements with branches, write the hierarchical structure
            if struct.type == "if" and struct.branches and #struct.branches > 0 then
                -- Write the initial if condition
                local firstCondition = struct.branches[1] and struct.branches[1].condition or "true"
                table.insert(lines, indentStr .. "if " .. firstCondition .. " then")
                
                -- Write each branch
                for i, branch in ipairs(struct.branches) do
                    if i > 1 then
                        -- Write elseif or else
                        if branch.type == "elseif" then
                            table.insert(lines, indentStr .. "elseif " .. branch.condition .. " then")
                        elseif branch.type == "else" then
                            table.insert(lines, indentStr .. "else")
                        end
                    end
                    
                    -- Write branch internals (this includes the content)
                    if branch.internals then
                        local internalLines = writeStructureToLua(branch.internals, indent + 1, exports, moduleVar)
                        for _, line in ipairs(internalLines) do
                            table.insert(lines, line)
                        end
                    end
                end
                
                table.insert(lines, indentStr .. "end")
            else
                -- Handle other control structures as before
                table.insert(lines, indentStr .. struct.condition)
                
                -- Write structure internals
                if struct.internals then
                    local internalLines = writeStructureToLua(struct.internals, indent + 1, exports, moduleVar)
                    for _, line in ipairs(internalLines) do
                        table.insert(lines, line)
                    end
                end
                
                -- Write closing statement
                if struct.type == "repeat" then
                    -- For repeat loops, we need the until condition - for now use placeholder
                    table.insert(lines, indentStr .. "until condition")
                else
                    table.insert(lines, indentStr .. "end")
                end
            end
            table.insert(lines, "")  -- Empty line after structure
        end
    end
    
    return lines
end

-- Write analysis structure to Lua file
function M.writeLuaFile(analysis)
    local lines = {}
    local exports = {}
    
    -- Write module declaration if detected
    if analysis.hasModulePattern then
        table.insert(lines, "local " .. analysis.moduleVariable .. " = {}")
        table.insert(lines, "")
    end
    
    -- Write the main structure
    if analysis.structure then
        local structureLines = writeStructureToLua(analysis.structure, 0, exports, analysis.moduleVariable or "M")
        for _, line in ipairs(structureLines) do
            -- Skip duplicate module return statements - they'll be handled at the end
            if not (line:match("^return " .. (analysis.moduleVariable or "M") .. "%s*$") and analysis.hasModulePattern) then
                table.insert(lines, line)
            end
        end
    end

    -- Append exports at the end (before return M if present)
    if #exports > 0 then
        if #lines > 0 and lines[#lines]:match("%S") then
            table.insert(lines, "")
        end
        for _, exLine in ipairs(exports) do
            table.insert(lines, exLine)
        end
    end
    
    -- Write module return if detected and not already written
    if analysis.hasModulePattern then
        -- Check if the last non-empty line is already a return statement
        local lastLine = ""
        for i = #lines, 1, -1 do
            if lines[i]:match("%S") then  -- Non-empty line
                lastLine = lines[i]
                break
            end
        end
        
        if not lastLine:match("^return " .. analysis.moduleVariable) then
            table.insert(lines, "return " .. analysis.moduleVariable)
        end
    end

    local output = ""
    
    for _, line in ipairs(lines) do
        output = output .. line .. "\n"
    end

    return output
end

return M