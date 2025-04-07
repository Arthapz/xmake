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
function _make_headerunitflags(target, headerunit)

    -- get flags
    local exportheaderflag = support.get_exportheaderflag(target)
    local headernameflag = support.get_headernameflag(target)
    local ifcoutputflag = support.get_ifcoutputflag(target)
    local ifconlyflag = support.get_ifconlyflag(target)
    assert(headernameflag and exportheaderflag, "compiler(msvc): does not support c++ header units!")

    local headertype = (headerunit.method == "include-angle") and ":angle" or ":quote"
    -- local local_directory = (headertype == ":quote") and {"-I" .. path.directory(headerunit.sourcefile)} or {}
    local flags = table.join({}, {"-TP",
                                               exportheaderflag,
                                               ifcoutputflag,
                                               headerunit.bmifile},
                                               ifconlyflag or {},
                                               headernameflag .. headertype,
                                               headertype == ":angle" and headerunit.name or headerunit.sourcefile)
    return flags
end

-- do compile
function _compile(target, flags, sourcefile, outputfile, headerunit)

    local dryrun = option.get("dry-run")
    local compinst = target:compiler("cxx")
    local compflags = compinst:compflags({sourcefile = sourcefile, target = target})
    local flags = table.join(compflags or {}, flags)

    -- trace
    if option.get("verbose") then
        if headerunit then
            print(os.args(compinst:program(), flags))
        else
            print(compinst:compcmd(sourcefile, outputfile, {target = target, compflags = flags, rawargs = true}))
        end
    end

    -- do compile
    if not dryrun then
        if headerunit then
            local msvc = target:toolchain("msvc")
            os.vrunv(compinst:program(), flags, {envs = msvc:runenvs()})
        else
            assert(compinst:compile(sourcefile, outputfile, {target = target, compflags = flags}))
        end
    end
end

-- do compile for batchcmds
-- @note we need to use batchcmds:compilev to translate paths in compflags for generator, e.g. -Ixx
function _batchcmds_compile(batchcmds, target, flags, sourcefile, outputfile)
    opt = opt or {}
    local compinst = target:compiler("cxx")
    local compflags = compinst:compflags({sourcefile = sourcefile, target = target, sourcekind = "cxx"})
    flags = table.join("/c", compflags or {}, flags or {}, outputfile and "-Fo" .. outputfile or {}, sourcefile or {})
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
-- t            local mapflag
--             local bmifile = dep_module.bmi
--             -- aliased headerunit
--             if dep_module.aliasof then
--                 local aliased = get_from_target_mapper(target, dep_module.aliasof)
--                 bmifile = aliased.bmi
--                 mapflag = {headerunitflag .. aliased.headerunit.type, required .. "=" .. bmifile}
--             -- headerunit
--             elseif dep_module.headerunit then
--                 mapflag = {headerunitflag .. dep_module.headerunit.type, required .. "=" .. bmifile}
--             -- named module
--             else
--                 mapflag = {referenceflag, required .. "=" .. bmifile}
--             end
--             table.insert(deps_flags, mapflag)

--             -- append deps
--             if dep_module.opt and dep_module.opt.deps then
--                 local deps = _get_requiresflags(target, { name = dep_module.name or dep_module.sourcefile, bmi = bmifile, requires = dep_module.opt.deps })
--                 table.join2(deps_flags, deps)
--             end
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

-- populate module map
function populate_module_map(target, modules)
    for _, module in pairs(modules) do
        local name, provide, cppfile = support.get_provided_module(module)
        if provide then
            local bmifile = support.get_bmi_path(provide.bmi)
            add_module_to_target_mapper(target, name, cppfile, bmifile, {deps = module.requires})
        end
    end
end

-- get defines for a module
function get_module_required_defines(target, sourcefile)
    local compinst = compiler.load("cxx", {target = target})
    local compflags = compinst:compflags({sourcefile = sourcefile, target = target})
    local defines
    for _, flag in ipairs(compflags) do
        if flag:startswith("-D") or flag:startswith("/D") then
            defines = defines or {}
            table.insert(defines, flag:sub(3))
        end
    end
    return defines
end

-- build module file for batchjobs
function make_module_buildjobs(target, batchjobs, job_name, deps, opt)

    local name, provide, _ = support.get_provided_module(opt.module)
    local bmifile = provide and support.get_bmi_path(provide.bmi)
    local dryrun = option.get("dry-run")

    return {
        name = job_name,
        deps = table.join(target:name() .. "_populate_module_map", deps),
        sourcefile = opt.cppfile,
        job = batchjobs:newjob(name or opt.cppfile, function(index, total, jobopt)

            local mapped_bmi
            if provide and support.memcache():get2(target:name() .. name, "reuse") then
                mapped_bmi = get_from_target_mapper(target, name).bmi
            end

            local build, dependinfo
            local dependfile = target:dependfile(bmifile or opt.objectfile)
            if provide or support.has_module_extension(opt.cppfile) then
                build, dependinfo = should_build(target, opt.cppfile, bmifile, {name = name, objectfile = opt.objectfile, requires = opt.module.requires})

                -- needed to detect rebuild of dependencies
                if provide and build then
                    mark_build(target, name)
                end
            end

            -- append requires flags
            if opt.module.requires then
                _append_requires_flags(target, opt.module, name, opt.cppfile, bmifile, opt)
            end

            -- for cpp file we need to check after appendings the flags
            if build == nil then
                build, dependinfo = should_build(target, opt.cppfile, bmifile, {name = name, objectfile = opt.objectfile, requires = opt.module.requires})
            end

            if build then
                -- compile if it's a named module
                if provide or support.has_module_extension(opt.cppfile) then
                    if not dryrun then
                        local objectdir = path.directory(opt.objectfile)
                        if not os.isdir(objectdir) then
                            os.mkdir(objectdir)
                        end
                    end

                    local fileconfig = target:fileconfig(opt.cppfile)
                    local public = fileconfig and fileconfig.public
                    local external = fileconfig and fileconfig.external
                    local from_moduleonly = external and external.moduleonly
                    local bmifile = mapped_bmi or bmifile
                    if external and not from_moduleonly then
                        if not mapped_bmi then
                            progress.show(jobopt.progress, "${color.build.target}<%s> ${clear}${color.build.object}compiling.bmi.$(mode) %s", target:name(), name or opt.cppfile)
                            _compile_bmi_step(target, bmifile, opt.cppfile, opt.objectfile, provide)
                        end
                    else
                        progress.show(jobopt.progress, "${color.build.target}<%s> ${clear}${color.build.object}compiling.module.$(mode) %s", target:name(), name or opt.cppfile)
                        _compile_one_step(target, bmifile, opt.cppfile, opt.objectfile, provide)
                    end
                else
                    os.tryrm(opt.objectfile) -- force rebuild for .cpp files
                end
                depend.save(dependinfo, dependfile)
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
function make_headerunit_buildjobs(target, job_name, batchjobs, headerunit, bmifile, outputdir, opt)
    local already_exists = add_headerunit_to_target_mapper(target, headerunit, bmifile)
    if not already_exists then
        return {
            name = job_name,
            sourcefile = headerunit.path,
            job = batchjobs:newjob(job_name, function(index, total, jobopt)
                if not os.isdir(outputdir) then
                    os.mkdir(outputdir)
                end

                local compinst = compiler.load("cxx", {target = target})
                local compflags = compinst:compflags({sourcefile = headerunit.path, target = target})

                local dependfile = target:dependfile(bmifile)
                local dependinfo = depend.load(dependfile) or {}
                dependinfo.files = {}
                local depvalues = {compinst:program(), compflags}

                local name = headerunit.unique and headerunit.name or headerunit.path

                if opt.build then
                    progress.show(jobopt.progress, "${color.build.target}<%s> ${clear}${color.build.object}compiling.headerunit.$(mode) %s", target:name(), headerunit.name)
                    _compile(target, _make_headerunitflags(target, headerunit), name, target:objectfile(headerunit.path), true)
                end

                table.insert(dependinfo.files, headerunit.path)
                dependinfo.values = depvalues
                depend.save(dependinfo, dependfile)
            end)}
    end
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
        _batchcmds_compile(batchcmds, target, table.join(_make_headerunitflags(target, headerunit)))
        batchcmds:add_depfiles(headerunit.sourcefile)
    end
    batchcmds:add_depvalues(depvalues)
end
