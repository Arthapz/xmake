--!A cross-toolchain build utility based on Lua
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
-- Copyright (C) 2015-present, Xmake Open Source Community.
--
-- @author      ruki
-- @file        check.lua
--

-- imports
import("core.project.config")
import("lib.detect.find_path")
import("lib.detect.find_tool")
import("detect.sdks.find_xcode")
import("detect.sdks.find_cross_toolchain")

-- check the cross toolchain
function main(toolchain)

    -- get sdk directory
    local sdkdir = toolchain:sdkdir()
    local bindir = toolchain:bindir()
    local cross  = toolchain:cross()
    if not sdkdir and not bindir then
        bindir = try {function () return os.iorunv("llvm-config", {"--bindir"}) end}
        if bindir then
            sdkdir = path.directory(bindir)
        elseif is_host("linux") and os.isfile("/usr/bin/llvm-ar") then
            sdkdir = "/usr"
        elseif is_host("macosx") then
            if os.arch() == "arm64" then
                bindir = find_path("llvm-ar", "/opt/homebrew/opt/llvm/bin")
            else
                bindir = find_path("llvm-ar", "/usr/local/Cellar/llvm/*/bin")
            end
            if bindir then
                sdkdir = path.directory(bindir)
            end
        elseif is_host("windows") then
            local llvm_ar = find_tool("llvm-ar", {force = true, envs = {PATH = os.getenv("PATH")}})
            if llvm_ar and llvm_ar.program and path.is_absolute(llvm_ar.program) then
                bindir = path.directory(llvm_ar.program)
                sdkdir = path.directory(bindir)
            end
        end
    end

    -- find cross toolchain from external envirnoment
    local cross_toolchain = find_cross_toolchain(sdkdir, {bindir = bindir})
    if not cross_toolchain then
        -- find it from packages
        for _, package in ipairs(toolchain:packages()) do
            local installdir = package:installdir()
            if installdir and os.isdir(installdir) then
                cross_toolchain = find_cross_toolchain(installdir)
                if cross_toolchain then
                    break
                end
            end
        end
    end
    if cross_toolchain then
        toolchain:config_set("cross", cross)
        toolchain:config_set("bindir", cross_toolchain.bindir)
        toolchain:config_set("sdkdir", cross_toolchain.sdkdir)
    else
        raise("llvm toolchain not found!")
    end

    if toolchain:is_plat("cross") and (not toolchain:cross() or toolchain:cross():match("^%s*$")) then
        raise("Missing cross target. Use `--cross=name` to specify.")
    end

    -- attempt to find xcode to pass `-isysroot` on macos
    if toolchain:is_plat("macosx") then
        import("private.utils.toolchain").check_xcode(toolchain, {no_bindir = true})
    end
    return cross_toolchain
end

