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
-- Copyright (C) 2015-present, TBOOX Open Source Group.
--
-- @author      ruki, Arthapz
-- @file        xmake.lua
--

-- define rule: c++.build.modules
rule("c++.build.modules")

    -- @note common.contains_modules() need it
    set_extensions(".cppm", ".ccm", ".cxxm", ".c++m", ".mpp", ".mxx", ".ixx")

    add_deps("c++.build.modules.builder")
    add_deps("c++.build.modules.install")

    on_config(function (target)
        import("config")(target)
    end)

-- build modules
rule("c++.build.modules.builder")
    set_sourcekinds("cxx")
    set_extensions(".mpp", ".mxx", ".cppm", ".ixx")

    -- parallel build support to accelerate `xmake build` to build modules
    -- before_build_files(function(target, batchjobs, sourcebatch, opt)
    --     import("builder")(target, batchjobs, sourcebatch, table.join(opt or {}, {batchjobs = true}))
    -- end, {batch = true})

    -- serial compilation only, usually used to support project generator
    before_buildcmd_files(function(target, batchcmds, sourcebatch, opt)
        import("builder")(target, batchcmds, sourcebatch, table.join(opt or {}, {batchjobs = false}))
    end)

    after_clean(function (target)
        import("builder").clean(target)
    end)

-- install modules
rule("c++.build.modules.install")
    set_extensions(".mpp", ".mxx", ".cppm", ".ixx")

    before_install(function (target)
        import("install").install(target)
    end)

    before_uninstall(function (target)
        import("install").uninstall(target)
    end)
