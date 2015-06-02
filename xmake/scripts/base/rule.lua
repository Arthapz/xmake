--!The Automatic Cross-platform Build Tool
-- 
-- XMake is free software; you can redistribute it and/or modify
-- it under the terms of the GNU Lesser General Public License as published by
-- the Free Software Foundation; either version 2.1 of the License, or
-- (at your option) any later version.
-- 
-- XMake is distributed in the hope that it will be useful,
-- but WITHOUT ANY WARRANTY; without even the implied warranty of
-- MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
-- GNU Lesser General Public License for more details.
-- 
-- You should have received a copy of the GNU Lesser General Public License
-- along with XMake; 
-- If not, see <a href="http://www.gnu.org/licenses/"> http://www.gnu.org/licenses/</a>
-- 
-- Copyright (C) 2009 - 2015, ruki All rights reserved.
--
-- @author      ruki
-- @file        rule.lua
--

-- define module: rule
local rule = rule or {}

-- load modules
local os        = require("base/os")
local path      = require("base/path")
local utils     = require("base/utils")
local config    = require("base/config")
local project   = require("base/project")
local platform  = require("platform/platform")

-- get the filename from the given name and kind
function rule.filename(name, kind)

    -- check
    assert(name and kind)

    -- get formats
    local formats = platform.get("format")
    assert(formats)

    -- get format
    local format = formats[kind] or {"", ""}

    -- make it
    return format[1] .. name .. format[2]
end

-- get target file for the given target
function rule.targetfile(target_name, target, buildir)

    -- check
    assert(target_name and target and target.kind)

    -- the target directory
    local targetdir = target.targetdir or buildir or config.get("buildir")
    assert(targetdir and type(targetdir) == "string")
   
    -- the target file name
    local filename = rule.filename(target_name, target.kind)
    assert(filename)

    -- make the target file path
    return targetdir .. "/" .. filename
end

-- get object files for the given source files
function rule.objectdir(target_name, target, buildir)

    -- check
    assert(target_name and target)

    -- the object directory
    local objectdir = target.objectdir
    if not objectdir then

        -- the build directory
        if not buildir then
            buildir = config.get("buildir")
        end
        assert(buildir)
   
        -- make the default object directory
        objectdir = buildir .. "/.objs"
    end
  
    -- ok?
    return objectdir
end

-- get object files for the given source files
function rule.objectfiles(target_name, target, sourcefiles, buildir)

    -- check
    assert(target_name and target and sourcefiles)

    -- the object directory
    local objectdir = rule.objectdir(target_name, target, buildir)
    assert(objectdir and type(objectdir) == "string")
   
    -- make object files
    local i = 1
    local objectfiles = {}
    for _, sourcefile in ipairs(sourcefiles) do

        -- make object file
        local objectfile = string.format("%s/%s/%s/%s", objectdir, target_name, path.directory(sourcefile), rule.filename(path.basename(sourcefile), "object"))

        -- save it
        objectfiles[i] = path.translate(objectfile)
        i = i + 1

    end

    -- ok?
    return objectfiles
end

-- get the source files from the given target
function rule.sourcefiles(target)

    -- check
    assert(target)

    -- no files?
    if not target.files then
        return {}
    end

    -- wrap files first
    local targetfiles = utils.wrap(target.files)

    -- match files
    local i = 1
    local sourcefiles = {}
    for _, targetfile in ipairs(targetfiles) do

        -- match source files
        local files = os.match(targetfile)

        -- process source files
        for _, file in ipairs(files) do

            -- convert to the relative path
            if path.is_absolute(file) then
                file = path.relative(file, xmake._PROJECT_DIR)
            end

            -- save it
            sourcefiles[i] = file
            i = i + 1

        end
    end

    -- remove repeat files
    sourcefiles = utils.unique(sourcefiles)

    -- ok?
    return sourcefiles
end

-- return module: rule
return rule
