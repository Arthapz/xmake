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
-- @file        clang/builder.lua
--

-- imports
import("core.base.json")
import("core.base.option")
import("core.base.semver")
import("utils.progress")
import("private.action.build.object", {alias = "objectbuilder"})
import("core.tool.compiler")
import("core.project.config")
import("core.project.depend")
import("support")
import(".builder", {inherit = true})

function _compile_one_step(target, bmifile, sourcefile, objectfile, opt)

    local module_outputflag = support.get_moduleoutputflag(target)
    -- get flags
    if module_outputflag then
        local flags = table.join({"-x", "c++-module", module_outputflag .. bmifile}, opt.std and {"-Wno-include-angled-in-module-purview", "-Wno-reserved-module-identifier"} or {})
        if opt and opt.batchcmds then
            _batchcmds_compile(opt.batchcmds, target, flags, sourcefile, objectfile, opt)
        else
            _compile(target, flags, sourcefile, objectfile, opt)
        end
    else
        _compile_bmi_step(target, bmifile, sourcefile, opt)
        _compile_objectfile_step(target, bmifile, sourcefile, objectfile, opt)
    end
end

function _compile_bmi_step(target, bmifile, sourcefile, opt)

    local flags = table.join({"-x", "c++-module", "--precompile"}, opt.std and {"-Wno-include-angled-in-module-purview", "-Wno-reserved-module-identifier"} or {})
    if opt and opt.batchcmds then
        _batchcmds_compile(opt.batchcmds, target, flags, sourcefile, bmifile, opt)
    else
        _compile(target, flags, sourcefile, bmifile, opt)
    end
end

function _compile_objectfile_step(target, bmifile, sourcefile, objectfile, opt)
    if opt and opt.batchcmds then
        _batchcmds_compile(opt.batchcmds, target, {}, sourcefile, objectfile, {bmifile = bmifile})
    else
        _compile(target, {}, sourcefile, objectfile, {bmifile = bmifile})
    end
end

-- get flags for building a headerunit
function _make_headerunitflags(target, headerunit)

    local module_headerflag = support.get_moduleheaderflag(target)
    assert(module_headerflag, "compiler(clang): does not support c++ header units!")

    local local_directory = (headerunit.type == ":quote") and {"-I" .. path.directory(headerunit.path)} or {}
    local headertype = (headerunit.method == "include-quote") and "system" or "user"
    local flags = table.join(local_directory, {"-xc++-header", "-Wno-everything", module_headerflag .. headertype})
    return flags
end

-- do compile
function _compile(target, flags, sourcefile, outputfile, opt)

    opt = opt or {}
    local dryrun = option.get("dry-run")
    local compinst = target:compiler("cxx")
    local compflags = compinst:compflags({sourcefile = sourcefile, target = target, sourcekind = "cxx"})
    flags = table.join(flags or {}, compflags or {})

    -- trace
    if option.get("verbose") then
        print(compinst:compcmd(opt.bmifile or sourcefile, outputfile, {target = target, compflags = flags, rawargs = true}))
    end

    -- do compile
    if not dryrun then
        assert(compinst:compile(opt.bmifile or sourcefile, outputfile, {target = target, compflags = flags}))
    end
end

-- do compile for batchcmds
-- @note we need to use batchcmds:compilev to translate paths in compflags for generator, e.g. -Ixx
function _batchcmds_compile(batchcmds, target, flags, sourcefile, outputfile, opt)
    opt = opt or {}
    local compinst = target:compiler("cxx")
    local compflags = compinst:compflags({sourcefile = sourcefile, target = target, sourcekind = "cxx"})
    flags = table.join("-c", compflags or {}, flags, {"-o", outputfile, opt.bmifile or sourcefile})
    batchcmds:compilev(flags, {compiler = compinst, sourcekind = "cxx"})
end

-- get module requires flags
-- e.g
-- -fmodule-file=build/.gens/Foo/rules/modules/cache/foo.pcm
-- -fmodule-file=build/.gens/Foo/rules/modules/cache/iostream.pcm
-- -fmodule-file=build/.gens/Foo/rules/modules/cache/bar.hpp.pcm
-- on LLVM >= 16
-- -fmodule-file=foo=build/.gens/Foo/rules/modules/cache/foo.pcm
-- -fmodule-file=build/.gens/Foo/rules/modules/cache/iostream.pcm
-- -fmodule-file=build/.gens/Foo/rules/modules/cache/bar.hpp.pcm
--
function _get_requiresflags(target, module)

    local modulefileflag = support.get_modulefileflag(target)
    local name = module.name or module.sourcefile
    local cachekey = target:name() .. name

    local requires, requires_changed = is_dependencies_changed(target, module)
    local requiresflags = support.memcache():get2(cachekey, "requiresflags")
    if not requiresflags or requires_changed then
        requiresflags = {}
        for required in requires:orderitems() do
            local dep_module = get_from_target_mapper(target, required)
            assert(dep_module, "module dependency %s required for %s not found", required, name)

            -- aliased headerunit
            local headerunit = false
            if dep_module.alias_of then
                dep_module = dep_module.alias_of
                headerunit = true
            end
            local mapflag = headerunit and modulefileflag .. dep_module.bmifile or format("%s%s=%s", modulefileflag, required, dep_module.bmifile)
            table.insert(requiresflags, mapflag)

            -- append deps
            if dep_module.deps then
                local deps = _get_requiresflags(target, dep_module)
                table.join2(requiresflags, deps)
            end
        end
        requiresflags = table.unique(requiresflags)
        table.sort(requiresflags)
        support.memcache():set2(cachekey, "requiresflags", requiresflags)
        support.memcache():set2(cachekey, "oldrequires", requires)
    end
    return requiresflags
end

function _append_requires_flags(target, module)

    local cxxflags = {}
    local requiresflags = _get_requiresflags(target, module)
    for _, flag in ipairs(requiresflags) do
        -- we need to wrap flag to support flag with space
        if type(flag) == "string" and flag:find(" ", 1, true) then
            table.insert(cxxflags, {flag})
        else
            table.insert(cxxflags, flag)
        end
    end
    target:fileconfig_add(module.sourcefile, {force = {cxxflags = cxxflags}})
end

-- build module file for batchjobs
function make_module_buildjobs(target, batchjobs, job_name, module, deps, opt)

    local dryrun = option.get("dry-run")
    return {
        name = job_name,
        deps = deps,
        sourcefile = module.sourcefile,
        job = batchjobs:newjob(job_name, function(_, _, jobopt)
            -- append requires flags
            if module.deps then
                _append_requires_flags(target, module)
            end

            -- generate and append module mapper file
            local build = should_build(target, module)

            local fileconfig = target:fileconfig(module.sourcefile)
            local external = fileconfig and fileconfig.external
            local reused = external and external.reused
            if build and not reused then
                if support.has_module_extension(module.sourcefile) then
                    if not dryrun then
                        local objectdir = path.directory(module.objectfile)
                        if not os.isdir(objectdir) then
                            os.mkdir(objectdir)
                        end
                    end
                    local name = module.name
                    if external and not external.moduleonly then
                        progress.show(jobopt.progress, "${color.build.target}<%s> ${clear}${color.build.object}compiling.module.bmi.$(mode) %s", target:name(), name or module.sourcefile)
                        _compile_bmi_step(target, module.bmifile, module.sourcefile, {std = (name == "std" or name == "std.compat")})
                    else
                        progress.show(opt.progress, "${color.build.target}<%s> ${clear}${color.build.object}compiling.module.$(mode) %s", target:name(), name or module.sourcefile)
                        _compile_one_step(target, module.bmifile, module.sourcefile, module.objectfile, {std = (name == "std" or name == "std.compat")})
                    end
                else
                    os.tryrm(module.objectfile) -- force rebuild for .cpp files
                end
            end
        end)}
end

-- build module file for batchcmds
function make_module_buildcmds(target, batchcmds, module, opt)

    -- append requires flags
    if module.deps then
        _append_requires_flags(target, module)
    end

    -- generate and append module mapper file
    local build = should_build(target, module)

    local fileconfig = target:fileconfig(module.sourcefile)
    local external = fileconfig and fileconfig.external
    local reused = external and external.reused
    if build and not reused then
        if support.has_module_extension(module.sourcefile) then
            batchcmds:mkdir(path.directory(module.objectfile))
            local name = module.name
            if external and not external.moduleonly then
                batchcmds:show_progress(opt.progress, "${color.build.target}<%s> ${clear}${color.build.object}compiling.module.bmi.$(mode) %s", target:name(), name or module.sourcefile)
                _compile_bmi_step(target, module.bmifile, module.sourcefile, {std = (name == "std" or name == "std.compat"), batchcmds = batchcmds})
            else
                batchcmds:show_progress(opt.progress, "${color.build.target}<%s> ${clear}${color.build.object}compiling.module.$(mode) %s", target:name(), name or module.sourcefile)
                _compile_one_step(target, module.bmifile, module.sourcefile, module.objectfile, {std = (name == "std" or name == "std.compat"), batchcmds = batchcmds})
            end
        else
            batchcmds:rm(module.objectfile) -- force rebuild for .cpp files
        end
        batchcmds:add_depfiles(module.sourcefile)
    end
    return os.mtime(module.objectfile)
end

-- build headerunit file for batchjobs
function make_headerunit_buildjobs(target, job_name, batchjobs, headerunit, opt)

    return {
        name = job_name,
        sourcefile = headerunit.sourcefile,
        job = batchjobs:newjob(job_name, function(_, _, jobopt)
            local build = should_build(target, headerunit)
            if build then
                local name = headerunit.unique and path.filename(headerunit.name) or headerunit.name
                progress.show(jobopt.progress, "${color.build.target}<%s> ${clear}${color.build.object}compiling.headerunit.$(mode) %s", target:name(), name)
                _compile(target, _make_headerunitflags(target, headerunit), headerunit.sourcefile, headerunit.bmifile)
            end
        end)}
end

-- build headerunit file for batchcmds
function make_headerunit_buildcmds(target, batchcmds, headerunit, opt)

    local compinst = compiler.load("cxx", {target = target})
    local compflags = compinst:compflags({sourcefile = headerunit.sourcefile, target = target, sourcekind = "cxx"})
    local depvalues = {compinst:program(), compflags}

    local build = should_build(target, headerunit)
    if build then
        local name = headerunit.unique and path.filename(headerunit.name) or headerunit.name
        batchcmds:show_progress(opt.progress, "${color.build.target}<%s> ${clear}${color.build.object}compiling.headerunit.$(mode) %s", target:name(), name)
        _batchcmds_compile(batchcmds, target, table.join(_make_headerunitflags(target, headerunit)), headerunit.sourcefile, headerunit.bmifile)
        batchcmds:add_depfiles(headerunit.sourcefile)
    end
    batchcmds:add_depvalues(depvalues)
end

function get_requires(target, module)

    local _requires
    local flags = _get_requiresflags(target, module)
    for _, flag in ipairs(flags) do
        _requires = _requires or {}
        table.insert(_requires, flag:split("=")[3])
    end
    return _requires
end
