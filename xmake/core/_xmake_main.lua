--!A cross-platform build utility based on Lua
--
-- Licensed under the Apache License, Version 2.0 (the "License");
-- you may not use this file except in compliance with the License.
-- You may obtain a copy of the License at
--
--     http://www.apache.org/licenses/LICENSE-2.0
--
-- Unless required by applicable law or agreed to in writing, software
-- distributed under the License is distributed on an "AS IS" BASIS,
-- WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
-- See the License for the specific language governing permissions and
-- limitations under the License.
-- 
-- Copyright (C) 2015 - 2019, TBOOX Open Source Group.
--
-- @author      ruki
-- @file        _xmake_main.lua
--

-- init namespace: xmake
xmake                   = xmake or {}
xmake._ARGV             = _ARGV
xmake._HOST             = _HOST
xmake._ARCH             = _ARCH
xmake._VERSION          = _VERSION
xmake._VERSION_SHORT    = _VERSION_SHORT
xmake._PROGRAM_DIR      = _PROGRAM_DIR
xmake._PROGRAM_FILE     = _PROGRAM_FILE
xmake._PROJECT_DIR      = _PROJECT_DIR
xmake._PROJECT_FILE     = "xmake.lua"

-- init loadfile
local _loadfile = _loadfile or loadfile
local _loadcache = {}
function loadfile(filepath)
    local errors = nil
    local script = _loadcache[filepath]
    if script == nil then
        script, errors = _loadfile(filepath)
        if script and filepath:startswith(_PROGRAM_DIR) then
            _loadcache[filepath] = script
        end
    end
    return script, errors
end

-- init package path
package.path = xmake._PROGRAM_DIR .. "/core/?.lua;" .. package.path

-- load modules
local main = require("main")

-- the main function
function _xmake_main()
    return main.entry()
end
