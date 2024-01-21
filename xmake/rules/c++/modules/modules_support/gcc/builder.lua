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
-- @file        gcc/builder.lua
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
import("compiler_support")
import(".builder", {inherit = true})

-- get flags for building a module
function _make_modulebuildflags(target, opt)

    local flags = {"-x", "c++", "-c"}
    if opt.batchcmds then
        table.join2(flags, "-o", target:objectfile(opt.sourcefile), opt.sourcefile)
    end

    return flags
end

-- get flags for building a headerunit
function _make_headerunitflags(target, headerunit, headerunit_mapper, opt)

    -- get flags
    local module_headerflag = compiler_support.get_moduleheaderflag(target)
    local module_onlyflag = compiler_support.get_moduleonlyflag(target)
    local module_mapperflag = compiler_support.get_modulemapperflag(target)
    assert(module_headerflag and module_onlyflag, "compiler(gcc): does not support c++ header units!")

    local local_directory = (headerunit.type == ":quote") and {"-I" .. path.directory(path.normalize(headerunit.path))} or {}

    local headertype = (headerunit.type == ":angle") and "system" or "user"

    local flags = table.join(local_directory, {module_mapperflag .. headerunit_mapper,
                                        module_headerflag .. headertype,
                                        module_onlyflag,
                                        "-xc++-header",
                                        "-c"})
    if opt.batchcmds then
       table.join2(flags, {"-o", opt.bmifile, path.filename(headerunit.path)})
    end

    return flags
end

-- do compile
function _compile(target, flags, sourcefile, outputfile)

    local dryrun = option.get("dry-run")
    local compinst = target:compiler("cxx")
    local compflags = compinst:compflags({sourcefile = sourcefile, target = target})
    local flags = table.join(compflags or {}, flags)

    -- trace
    vprint(compinst:compcmd(sourcefile, outputfile, {compflags = flags, rawargs = true}))

    if not dryrun then
        -- do compile
        assert(compinst:compile(sourcefile, outputfile, {compflags = flags}))
    end
end

-- do compile for batchcmds
-- @note we need to use batchcmds:compilev to translate paths in compflags for generator, e.g. -Ixx
function _batchcmds_compile(batchcmds, target, flags, sourcefile)

    local compinst = target:compiler("cxx")
    local compflags = compinst:compflags({sourcefile = sourcefile, target = target})
    local flags = table.join(compflags or {}, flags)

    batchcmds:compilev(flags, {compiler = compinst, sourcekind = "cxx"})
end

-- fill module mapper with modules
function _populate_target_mapper_with_modules(target, modules)

    local projectdir = os.projectdir()

    -- append all modules
    for _, module in pairs(modules) do
        local name, provide = compiler_support.get_provided_module(module)
        if provide then
            add_module_to_target_mapper(target, name, provide.sourcefile, path.absolute(compiler_support.get_bmi_path(provide.bmi), projectdir))
        end
    end

    -- then update their deps
    for _, module in pairs(modules) do
        local name, provide = get_provided_module(module)
        if provide then
            local bmifile = compiler_support.get_bmi_path(provide.bmi)
            add_module_to_target_mapper(target, name, provide.sourcefile, path.absolute(bmifile, projectdir), {deps = module.requires})
        end
    end
end

-- fill module mapper with header units
function _populate_target_mapper_with_headerunits(target, headerunits, opt)

    local outputdir = opt.outputdir
    for _, headerunit in ipairs(headerunits) do
        local bmifile = path.join(outputdir, path.filename(headerunit.name) .. compiler_support.get_bmi_extension())

        local headerunit_path = _get_headerunit_path(headerunit)
        add_headerunit_to_target_mapper(target, {name = headerunit.name, path = headerunit_path}, bmifile)
    end

    _flush_target_mapper(target)
end

-- get relative path of headerunit if headerunit is :quote
function _get_headerunit_path(headerunit)

    local projectdir = os.projectdir()

    local headerunit_path
    if headerunit.type == ":quote" then
        headerunit_path = path.join(".", path.relative(headerunit.path, projectdir))
    elseif headerunit.type == ":angle" then
        -- if path is relative then its a subtarget path
        headerunit_path = path.is_absolute(headerunit.path) and headerunit.path or path.join(".", headerunit.path)
    end

    return headerunit_path
end

function _module_map_cachekey(target)

    local mode = config.mode()
    return target:name() .. "module_mapper" .. (mode or "")
end

-- get or create a target module mapper
function _get_target_module_mapper(target)

    local memcache = compiler_support.memcache()
    local mapper = memcache:get2(target:name(), "module_mapper")
    if not mapper then
        mapper = compiler_support.localcache():get(_module_map_cachekey(target)) or {}

        memcache:set2(target:name(), "module_mapper", mapper)
    end

    return mapper
end

-- add a module or header unit into a mapper
--
function _add_to_target_mapper(target, name, bmi, deps)

    local mapper = _get_target_module_mapper(target)

    mapper[name] = {map = name .. " " .. os.args(bmi, {escape = true}), deps = deps}
end

-- get a module or headerunit from mapper
function _get_from_target_mapper(target, name)

    local mapper = _get_target_module_mapper(target)

    if mapper[name] then
        return mapper[name]
    end
end

function _get_headerunit_maplines()

end

-- generate a module mapper file for build a headerunit
function _generate_headerunit_modulemapper_file(module)

    local dryrun = option.get("dry-run")

    local path = os.tmpfile()
    local mapper_file = io.open(path, "wb")

    mapper_file:write("root " .. os.projectdir())
    -- mapper_file:write("root " .. os.projectdir():replace("\\", "/"))
    mapper_file:write("\n")

    mapper_file:write(mapper_file, module.name:replace("\\", "/") .. " " .. module.bmifile:replace("\\", "/"))
    -- mapper_file:write(mapper_file, module.name .. " " .. module.bmifile)
    mapper_file:write("\n")

    mapper_file:close()

    return path

end

function _get_maplines(target, module)
    local maplines = {}

    local m_name, m = compiler_support.get_provided_module(module)
    if m then
        table.insert(maplines, m_name .. " " .. compiler_support.get_bmi_path(m.bmi))
    end

    for required, _ in pairs(module.requires) do
        local dep_module
        local dep_target
        for _, dep in ipairs(target:orderdeps()) do
            dep_module = get_from_target_mapper(dep, required)
            if dep_module then
                dep_target = dep
                break
            end
        end

        -- if not in target dep
        if not dep_module then
            dep_module = get_from_target_mapper(target, required)
            if dep_module then
                dep_target = target
            end
        end

        assert(dep_module, "module dependency %s required for %s not found", required, name)

        local mapline = (dep_module.headerunit and dep_module.headerunit.path:replace("\\", "/") or required) .. " " .. dep_module.bmi:replace("\\", "/")
        table.insert(maplines, mapline)

        -- append deps
        if dep_module.opt and dep_module.opt.deps then
            local deps = _get_maplines(dep_target, { name = dep_module.name, bmi = bmifile, requires = dep_module.opt.deps })
            table.join2(maplines, deps)
        end
    end
    
    -- remove duplicates
    return table.unique(maplines)
end

-- generate a module mapper file for build a module
-- e.g
-- /usr/include/c++/11/iostream build/.gens/stl_headerunit/linux/x86_64/release/stlmodules/cache/iostream.gcm
-- hello build/.gens/stl_headerunit/linux/x86_64/release/rules/modules/cache/hello.gcm
--
function _generate_modulemapper_file(target, module)

    local maplines = _get_maplines(target, module)

    local path = os.tmpfile()
    local mapper_file = io.open(path, "wb")

    mapper_file:write("root " .. os.projectdir():replace("\\", "/"))
    mapper_file:write("\n")

    for _, mapline in ipairs(maplines) do
        mapper_file:write(mapline)
        mapper_file:write("\n")
    end

    mapper_file:close()

    return path
end

-- flush modulemap to mapper file cache
function _flush_target_mapper(target)

    local mapper = _get_target_module_mapper(target)
    local localcache = compiler_support.localcache()

    -- not using set2/get2 to flush only current target mapper
    localcache:set(_module_map_cachekey(target), mapper)
    localcache:save(_module_map_cachekey(target))
end

-- add populate job
function init_build_for(target, batch, modules, opt)

    if opt.batchjobs then
        local job_name = get_modulemap_populate_jobname(target)
        return { modulemap_populatejob_name = {
            name = job_name,
            job = batch:addjob(job_name, function(index, total)
                progress.show((index * 100) / total, "${color.build.object}populating.%s.map for target <%s>", opt.type, target:name())
                if opt.type == "module" then
                    _populate_target_mapper_with_modules(target, modules)
                else
                    _populate_target_mapper_with_headerunits(target, modules, opt)
                end
            end)}}
    else
        batch:show_progress(opt.progress, "${color.build.object}populating.%s.map for target <%s>", opt.type, target:name())
        if opt.type == "module" then
            _populate_target_mapper_with_modules(target, modules)
        else
            _populate_target_mapper_with_headerunits(target, modules, opt)
        end
    end
end

-- get defines for a module
function get_module_required_defines(target, sourcefile)
    local compinst = compiler.load("cxx", {target = target})
    local compflags = compinst:compflags({sourcefile = sourcefile, target = target})
    local defines

    for _, flag in ipairs(compflags) do
        if flag:startswith("-D") then
            defines = defines or {}
            table.insert(defines, flag:sub(3))
        end
    end

    return defines
end

-- build module file for batchjobs
function make_module_build_job(target, batchjobs, job_name, deps, name, provide, module, cppfile, objectfile, opt)

    local bmifile = provide and compiler_support.get_bmi_path(provide.bmi)
    local module_mapperflag = compiler_support.get_modulemapperflag(target)
    local populate_job_name = get_modulemap_populate_jobname(target)

    return {
        name = job_name,
        deps = table.join({populate_job_name}, deps),
        sourcefile = cppfile,
        job = batchjobs:newjob(name or cppfile, function(index, total)

            local compinst = compiler.load("cxx", {target = target})
            local compflags = compinst:compflags({sourcefile = cppfile, target = target})

            -- generate and append module mapper file
            local module_mapper
            if provide or module.requires then
                module_mapper = _generate_modulemapper_file(target, module)
                target:fileconfig_add(cppfile, {force = {cxxflags = {module_mapperflag .. module_mapper}}})
            end

            local dependfile = target:dependfile(bmifile or objectfile)
            local dependinfo = depend.load(dependfile) or {}
            dependinfo.files = {}
            local depvalues = {compinst:program(), compflags}

            if opt.build then
                -- compile if it's a named module
                if provide or compiler_support.has_module_extension(cppfile) then
                    progress.show((index * 100) / total, "${color.build.object}compiling.module.$(mode) %s for target <%s>", name or cppfile, target:name())

                    local flags = _make_modulebuildflags(target, opt)
                    _compile(target, flags, cppfile, objectfile)
                    os.tryrm(module_mapper)
                end
            end
            table.insert(dependinfo.files, cppfile)
            dependinfo.values = depvalues
            depend.save(dependinfo, dependfile)
        end)}
end

-- build module file for batchcmds
function make_module_build_cmds(target, batchcmds, name, provide, module, cppfile, objectfile, opt)

    local bmifile = provide and compiler_support.get_bmi_path(provide.bmi)
    local module_mapperflag = compiler_support.get_modulemapperflag(target)

    -- generate and append module mapper file
    local module_mapper
    if provide or module.requires then
        module_mapper = _generate_modulemapper_file(target, module)
        target:fileconfig_add(cppfile, {force = {cxxflags = {module_mapperflag .. module_mapper}}})
    end

    if opt.build then
        -- compile if it's a named module
        if provide or compiler_support.has_module_extension(cppfile) then
            batchcmds:show_progress(opt.progress, "${color.build.object}compiling.module.$(mode) %s for target <%s>", name or cppfile, target:name())
            batchcmds:mkdir(path.directory(objectfile))

            _batchcmds_compile(batchcmds, target, _make_modulebuildflags(target, {batchcmds = true, sourcefile = cppfile}), cppfile)
        end
    end

    batchcmds:add_depfiles(cppfile)

    return os.mtime(objectfile)
end

-- build headerunit file for batchjobs
function make_headerunit_build_job(target, job_name, batchjobs, headerunit, bmifile, outputdir, opt)

    return {
        name = job_name,
        sourcefile = headerunit.path,
        job = batchjobs:newjob(job_name, function(index, total)
            if not os.isdir(outputdir) then
                os.mkdir(outputdir)
            end

            local compinst = compiler.load("cxx", {target = target})
            local compflags = compinst:compflags({sourcefile = headerunit.path, target = target})

            local dependfile = target:dependfile(bmifile)
            local dependinfo = depend.load(dependfile) or {}
            dependinfo.files = {}
            local depvalues = {compinst:program(), compflags}

            if opt.build then
                local headerunit_mapper = _generate_headerunit_modulemapper_file({name = path.normalize(headerunit.path), bmifile = bmifile})

                progress.show((index * 100) / total, "${color.build.object}compiling.headerunit.$(mode) %s for target <%s>", headerunit.name, target:name())
                _compile(target, _make_headerunitflags(target, headerunit, headerunit_mapper, opt), path.translate(path.filename(headerunit.name)), bmifile)
                os.tryrm(headerunit_mapper)
            end

            table.insert(dependinfo.files, headerunit.path)
            dependinfo.values = depvalues
            depend.save(dependinfo, dependfile)
        end)}
end

-- build headerunit file for batchcmds
function make_headerunit_build_cmds(target, batchcmds, headerunit, bmifile, outputdir, opt)

    local headerunit_mapper = _generate_headerunit_modulemapper_file({name = path.normalize(headerunit.path), bmifile = bmifile})
    batchcmds:mkdir(outputdir)

    if opt.build then
        local name = headerunit.unique and headerunit.name or headerunit.path
        batchcmds:show_progress(opt.progress, "${color.build.object}compiling.headerunit.$(mode) %s for target <%s>", name, target:name())
        _batchcmds_compile(batchcmds, target, _make_headerunitflags(target, headerunit, headerunit_mapper, {batchcmds = true, bmifile = bmifile}))
    end

    batchcmds:rm(headerunit_mapper)
    batchcmds:add_depfiles(headerunit.path)
    return os.mtime(bmifile)
end

