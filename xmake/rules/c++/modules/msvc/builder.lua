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
-- @file        msvc/builder.lua
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
import("private.tools.vstool")
import("support")
import(".builder", {inherit = true})

-- get flags for building a module
function _make_modulebuildflags(target, provide, bmifile, opt)

    local ifcoutputflag = support.get_ifcoutputflag(target)
    local ifconlyflag = support.get_ifconlyflag(target)
    local interfaceflag = support.get_interfaceflag(target)
    local internalpartitionflag = support.get_internalpartitionflag(target)
    local ifconly = (not opt.build_objectfile and ifconlyflag)

    local flags
    if provide then -- named module
        flags = table.join({"-TP", ifcoutputflag, path(bmifile), provide.interface and interfaceflag or internalpartitionflag}, ifconly or {})
    else
        flags = {"-TP"}
    end
    return flags
end

function _compile_one_step(target, bmifile, sourcefile, objectfile, opt)

    local ifcoutputflag = support.get_ifcoutputflag(target)
    local interfaceflag = support.get_interfaceflag(target)
    local internalpartitionflag = support.get_internalpartitionflag(target)
    -- get flags
    local flags = {"-TP"}
    if opt.module.interface or opt.module.implementation then
        table.join2(flags, ifcoutputflag, path(bmifile), opt.module.interface and interfaceflag or internalpartitionflag)
    end
    if opt and opt.batchcmds then
        _batchcmds_compile(opt.batchcmds, target, flags, sourcefile, objectfile)
    else
        _compile(target, flags, sourcefile, objectfile)
    end
end

function _compile_bmi_step(target, bmifile, sourcefile, opt)

    local ifcoutputflag = support.get_ifcoutputflag(target)
    local interfaceflag = support.get_interfaceflag(target)
    local ifconlyflag = support.get_ifconlyflag(target)

    if not ifconlyflag then
        _compile_one_step(target, bmifile, sourcefile, opt.objectfile, opt)
    else
        local flags = {"-TP", ifcoutputflag, path(bmifile), interfaceflag, ifconlyflag}
        if opt and opt.batchcmds then
            _batchcmds_compile(opt.batchcmds, target, flags, sourcefile, bmifile)
        else
            _compile(target, flags, sourcefile, bmifile)
        end
    end
end

-- get flags for building a headerunit
function _make_headerunitflags(target, headerunit, headertype)

    -- get flags
    local exportheaderflag = support.get_exportheaderflag(target)
    local headernameflag = support.get_headernameflag(target)
    local ifcoutputflag = support.get_ifcoutputflag(target)
    local ifconlyflag = support.get_ifconlyflag(target)
    assert(headernameflag and exportheaderflag, "compiler(msvc): does not support c++ header units!")

    local flags = {"-TP",
                   exportheaderflag,
                   ifcoutputflag,
                   headerunit.bmifile,
                   ifconlyflag or {},
                   headernameflag .. headertype} -- keep it at last flag
    return flags
end

-- do compile
function _compile(target, flags, sourcefile, outputfile)

    local dryrun = option.get("dry-run")
    local compinst = target:compiler("cxx")
    local compflags = compinst:compflags({sourcefile = sourcefile, target = target, sourcekind = "cxx"})
    flags = table.join(compflags or {}, flags or {})

    -- trace
    if option.get("verbose") then
        if not outputfile then
            print(os.args(table.join(compinst:program(), flags, sourcefile)))
        else
            print(compinst:compcmd(sourcefile, outputfile, {target = target, compflags = flags, sourcekind = "cxx", rawargs = true}))
        end
    end

    -- do compile
    if not dryrun then
        if headerunit then
            local msvc = target:toolchain("msvc")
            os.vrunv(compinst:program(), flags, {envs = msvc:runenvs()})
        else
            assert(compinst:compile(sourcefile, outputfile or target:objectfile(sourcefile), {target = target, compflags = flags}))
        end
    end
end

-- do compile for batchcmds
-- @note we need to use batchcmds:compilev to translate paths in compflags for generator, e.g. -Ixx
function _batchcmds_compile(batchcmds, target, flags, sourcefile, outputfile)
    opt = opt or {}
    local compinst = target:compiler("cxx")
    local compflags = compinst:compflags({sourcefile = sourcefile, target = target, sourcekind = "cxx"})
    flags = table.join("/c", compflags or {}, outputfile and "-Fo" .. outputfile or {}, flags or {}, sourcefile or {})
    batchcmds:compilev(flags, {compiler = compinst, sourcekind = "cxx"})
end

-- get module requires flags
-- e.g
-- /reference Foo=build/.gens/Foo/rules/modules/cache/Foo.ifc
-- /headerUnit:angle glm/mat4x4.hpp=Users\arthu\AppData\Local\.xmake\packages\g\glm\0.9.9+8\91454f3ee0be416cb9c7452970a2300f\include\glm\mat4x4.hpp.ifc
--
function _get_requiresflags(target, module)

    local referenceflag = support.get_referenceflag(target)
    local headerunitflag = support.get_headerunitflag(target)

    local name = module.name or module.sourcefile
    local cachekey = target:name() .. name

    local requires, requires_changed = is_dependencies_changed(target, module)
    local requiresflags = support.memcache():get2(cachekey, "requiresflags")
    if not requiresflags or requires_changed then
        local deps_flags = {}
        for required in requires:orderitems() do
            local dep_module = get_from_target_mapper(target, required)
            assert(dep_module, "module dependency %s required for %s not found <%s>", required, name, target:name())

            -- aliased headerunit
            local headerunit = false
            if dep_module.alias_of then
                dep_module = dep_module.alias_of
                headerunit = true
            end
            local mapflag
            if headerunit then
                local type = dep_module.method == "include-angle" and ":angle" or ":quote"
                mapflag = {headerunitflag .. type}
            else
                mapflag = {referenceflag}
            end
            table.insert(mapflag, required .. "=" .. dep_module.bmifile)
            table.insert(deps_flags, mapflag)

            -- append deps
            if dep_module.deps then
                local deps = _get_requiresflags(target, dep_module)
                table.join2(deps_flags, deps)
            end
        end

        -- remove duplicates
        requiresflags = {}
        local contains = {}
        for _, map in ipairs(deps_flags) do
            local name = map[2]:split("=")[1]
            if name and not contains[name] then
                table.insert(requiresflags, map)
                contains[name] = true
            end
        end
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
                        _compile_bmi_step(target, module.bmifile, module.sourcefile, {objectfile = module.objectfile, module = module})
                    else
                        progress.show(opt.progress, "${color.build.target}<%s> ${clear}${color.build.object}compiling.module.$(mode) %s", target:name(), name or module.sourcefile)
                        _compile_one_step(target, module.bmifile, module.sourcefile, module.objectfile, {module = module})
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
                _compile_bmi_step(target, module.bmifile, module.sourcefile, {objectfile = module.objectfile, module = module, batchcmds = batchcmds})
            else
                batchcmds:show_progress(opt.progress, "${color.build.target}<%s> ${clear}${color.build.object}compiling.module.$(mode) %s", target:name(), name or module.sourcefile)
                _compile_one_step(target, module.bmifile, module.sourcefile, module.objectfile, {module = module, batchcmds = batchcmds})
            end
        else
            batchcmds:rm(module.objectfile) -- force rebuild for .cpp files
        end
    end
    batchcmds:add_depfiles(module.sourcefile)
    return os.mtime(module.objectfile)
end

-- build headerunit file for batchjobs
function make_headerunit_buildjobs(target, job_name, batchjobs, headerunit)

    return {
        name = job_name,
        sourcefile = headerunit.sourcefile,
        job = batchjobs:newjob(job_name, function(_, _, jobopt)
            local build = should_build(target, headerunit)
            if build then
                local name = headerunit.unique and path.filename(headerunit.name) or headerunit.name
                local headertype = (headerunit.method == "include-angle") and ":angle" or ":quote"
                progress.show(jobopt.progress, "${color.build.target}<%s> ${clear}${color.build.object}compiling.headerunit.$(mode) %s", target:name(), name)
                _compile(target, _make_headerunitflags(target, headerunit, headertype), (headertype == ":angle") and headerunit.name or headerunit.sourcefile)
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
        local headertype = (headerunit.method == "include-angle") and ":angle" or ":quote"
        batchcmds:show_progress(opt.progress, "${color.build.target}<%s> ${clear}${color.build.object}compiling.headerunit.$(mode) %s", target:name(), name)
        _batchcmds_compile(batchcmds, target, _make_headerunitflags(target, headerunit, headertype), (headertype == ":angle") and headerunit.name or headerunit.sourcefile)
        batchcmds:add_depfiles(headerunit.sourcefile)
    end
    batchcmds:add_depvalues(depvalues)
end
