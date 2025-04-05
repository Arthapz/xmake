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
import("support")
import(".builder", {inherit = true})

-- get flags for building a headerunit
function _make_headerunitflags(target, headerunit, headerunit_mapper, opt)
    local module_headerflag = support.get_moduleheaderflag(target)
    local module_mapperflag = support.get_modulemapperflag(target)
    assert(module_headerflag, "compiler(gcc): does not support c++ header units!")

    local headertype = opt.stl_headerunit and "c++-system-header" or "c++-header"
    local flags = table.join({}, {module_mapperflag .. headerunit_mapper,
                                  "-x", headertype})
    return flags
end

-- do compile
function _compile(target, flags, sourcefile, outputfile)

    local dryrun = option.get("dry-run")
    local compinst = target:compiler("cxx")
    local fileconfig = target:fileconfig(sourcefile)
    local external = fileconfig and fileconfig.external
    local compflags = (external and external.flags) and external.flags or compinst:compflags({sourcefile = sourcefile, target = target})
    flags = table.join(compflags or {}, flags)

    -- trace
    if option.get("verbose") then
        print(compinst:compcmd(sourcefile, outputfile, {target = target, compflags = flags, rawargs = true}))
    end

    -- do compile
    if not dryrun then
        assert(compinst:compile(sourcefile, outputfile, {target = target, compflags = flags}))
    end
end

-- do compile for batchcmds
-- @note we need to use batchcmds:compilev to translate paths in compflags for generator, e.g. -Ixx
function _batchcmds_compile(batchcmds, target, flags, sourcefile, outputfile)
    local compinst = target:compiler("cxx")
    local fileconfig = target:fileconfig(sourcefile)
    local external = fileconfig and fileconfig.external
    local compflags = (external and external.flags) and external.flags or compinst:compflags({sourcefile = sourcefile, target = target, sourcekind = "cxx"})
    flags = table.join("-c", compflags or {}, flags, {"-o", outputfile, sourcefile})
    batchcmds:compilev(flags, {compiler = compinst, sourcekind = "cxx"})
end

function _module_map_cachekey(target)
    local mode = config.mode()
    return target:name() .. "module_mapper" .. (mode or "")
end

-- generate a module mapper file for build a headerunit
function _generate_headerunit_modulemapper_file(headerunit)
    local mapper_path = path.join(path.directory(headerunit.bmifile), path.filename(headerunit.sourcefile) .. ".mapper.txt")
    local mapper_file = io.open(mapper_path, "wb")
    mapper_file:write("root " .. path.directory(headerunit.sourcefile) .. "\n")
    mapper_file:write(mapper_file, path.unix(headerunit.sourcefile) .. " " .. path.unix(path.absolute(headerunit.bmifile)) .. "\n")
    mapper_file:write("\n")
    mapper_file:close()
    return mapper_path
end

function _get_maplines(target, module)
    local maplines = {}
    if module.interface or module.implementation then
        table.insert(maplines, module.name .. " " .. path.absolute(module.bmifile))
    end
    for dep_name, dep_module in table.orderpairs(module.deps) do
        local dep_module_mapped = get_from_target_mapper(target, dep_name)
        assert(dep_module_mapped, "module dependency %s required for %s not found", dep_name, module.name or module.sourcefile)
        local mapline
        if dep_module_mapped.alias_of then
            -- headerunit
            local key = support.get_headerunit_key(target, dep_module.sourcefile)
            local headerunit = dep_module_mapped.alias_of[key]
            local name = headerunit.method == "include-angle" and headerunit.sourcefile or path.join("./", path.directory(module.sourcefile), dep_name)
            mapline = path.unix(name) .. " " .. path.unix(path.absolute(headerunit.bmifile))
        else
            -- named module
            mapline = dep_name .. " " .. path.unix(path.absolute(dep_module_mapped.bmifile))
        end
        table.insert(maplines, mapline)

        -- append deps
        if dep_module.deps then
            local deps = _get_maplines(target, {name = dep_module.name, deps = dep_module.deps, sourcefile = dep_module.sourcefile})
            table.join2(maplines, deps)
        end
    end

    -- remove duplicates
    return table.unique(maplines)
end

function _get_modulemapper_file(module)
    return path.join(os.tmpdir(), hash.md5(module.sourcefile), path.filename(module.sourcefile) .. ".mapper.txt")
end

-- generate a module mapper file for build a module
-- e.g
-- /usr/include/c++/11/iostream build/.gens/stl_headerunit/linux/x86_64/release/stlmodules/cache/iostream.gcm
-- hello build/.gens/stl_headerunit/linux/x86_64/release/rules/modules/cache/hello.gcm
--
function _generate_modulemapper_file(target, module)
    local maplines = _get_maplines(target, module)
    local mapper_path = _get_modulemapper_file(module)
    if os.isfile(mapper_path) then
        os.rm(mapper_path)
    end
    local mapper_content = {}
    table.insert(mapper_content, "root " .. path.unix(os.projectdir()))
    for _, mapline in ipairs(maplines) do
        table.insert(mapper_content, mapline)
    end
    mapper_content = table.concat(mapper_content, "\n") .. "\n"
    if not os.isfile(mapper_path) or io.readfile(mapper_path, {encoding = "binary"}) ~= mapper_content then
        io.writefile(mapper_path, mapper_content, {encoding = "binary"})
    end
    return mapper_path
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
function make_module_buildjobs(target, batchjobs, job_name, deps, opt)

    local name, provide, _ = support.get_provided_module(opt.module)
    local bmifile = provide and support.get_bmi_path(provide.bmi)
    local module_mapperflag = support.get_modulemapperflag(target)

    return {
        name = job_name,
        deps = table.join(target:name() .. "_populate_module_map", deps),
        sourcefile = opt.cppfile,
        job = batchjobs:newjob(name or opt.cppfile, function(_, _, jobopt)
            local mapped_bmi
            if provide or support.memcache():get2(target:name() .. name, "reuse") then
                mapped_bmi = get_from_target_mapper(target, name).bmi
            end

            -- generate and append module mapper file
            local module_mapper
            if provide or opt.module.requires then
                module_mapper = _generate_modulemapper_file(target, opt.module, path.directory(opt.cppfile))
            end

            local dependfile = target:dependfile(bmifile or opt.objectfile)
            local build, dependinfo = should_build(target, opt.cppfile, bmifile, {name = name, objectfile = opt.objectfile, requires = opt.module.requires})

            -- needed to detect rebuild of dependencies
            if provide and build then
                mark_build(target, key)
            end

            if build then
                -- compile if it's a named module
                if provide or support.has_module_extension(opt.cppfile) then
                    local module_onlyflag = support.get_moduleonlyflag(target)
                    local fileconfig = target:fileconfig(opt.cppfile)
                    local external = fileconfig and fileconfig.external
                    local from_moduleonly = external and external.moduleonly

                    local build_bmi = not mapped_bmi
                    local build_objectfile = from_moduleonly or not external

                    local flags = {"-x", "c++", module_mapperflag .. module_mapper}
                    local sourcefile
                    if build_bmi and build_objectfile then
                        progress.show(jobopt.progress, "${color.build.target}<%s> ${clear}${color.build.object}compiling.module.$(mode) %s", target:name(), name or opt.cppfile)
                        sourcefile = opt.cppfile
                    elseif build_bmi and module_onlyflag then
                        progress.show(jobopt.progress, "${color.build.target}<%s> ${clear}${color.build.object}compiling.bmi.$(mode) %s", target:name(), name or opt.cppfile)
                        table.insert(flags, module_onlyflag)
                        sourcefile = opt.cppfile
                    end

                    -- if option.get("diagnosis") then
                    --     print("mapper file --------\n%s--------", io.readfile(module_mapper))
                    -- end
                    if sourcefile then
                        _compile(target, flags, sourcefile, opt.objectfile)
                    end
                    os.tryrm(module_mapper)
                else
                    target:fileconfig_add(opt.cppfile, {force = {cxxflags = {module_mapperflag .. module_mapper}}})
                    -- os.tryrm(objectfile) -- force rebuild for .cpp files
                end
            end
        end)}
end

-- build module file for batchcmds
function make_module_buildcmds(target, batchcmds, module, opt)

    local module_mapperflag = support.get_modulemapperflag(target)
    local module_onlyflag = support.get_moduleonlyflag(target)
    local module_flag = support.get_modulesflag(target)

    local module_mapper
    if module.implementation or module.interface or module.deps then
        module_mapper = _get_modulemapper_file(module)
        target:fileconfig_add(module.sourcefile, {force = {cxxflags = {module_mapperflag .. module_mapper}}})
    end

    -- generate and append module mapper file
    local build = should_build(target, module)

    -- needed to detect rebuild of dependencies
    if build then
        if module.implementation or module.interface or module.deps then
            _generate_modulemapper_file(target, module)
        end

        -- compile if it's a named module
        if option.get("diagnosis") then
            if module.name  then
                batchcmds:show("mapper file for %s (%s) --------\n%s--------", module.name, module.sourcefile, io.readfile(module_mapper))
            else
                batchcmds:show("mapper file for %s --------\n%s--------", module.sourcefile, io.readfile(module_mapper))
            end
        end
        if support.has_module_extension(module.sourcefile) then
            batchcmds:mkdir(path.directory(module.objectfile))
            local flags = {"-x", "c++", module_mapperflag .. module_mapper}
            local fileconfig = target:fileconfig(module.sourcefile)
            local external = fileconfig and fileconfig.external
            if external and not external.reuse and not external.moduleonly then
                batchcmds:show_progress(opt.progress, "${color.build.target}<%s> ${clear}${color.build.object}compiling.module.bmi.$(mode) %s", target:name(), module.name or module.sourcefile)
                table.insert(flags, module_onlyflag)
                table.insert(flags, module_flag)
            else
                batchcmds:show_progress(opt.progress, "${color.build.target}<%s> ${clear}${color.build.object}compiling.module.$(mode) %s", target:name(), module.name or module.sourcefile)
            end
            _batchcmds_compile(batchcmds, target, flags, module.sourcefile, module.objectfile)
            batchcmds:rm(module_mapper)
        else
            batchcmds:rm(module.objectfile) -- force rebuild for .cpp files
        end
        batchcmds:add_depfiles(module.sourcefile)
    end
end

-- build headerunit file for batchjobs
function make_headerunit_buildjobs(target, job_name, batchjobs, headerunit, bmifile, outputdir, opt)

    local _headerunit = headerunit
    _headerunit.path = headerunit.method == ":quote" and path.relative(headerunit.path) or headerunit.path
    local already_exists = add_headerunit_to_target_mapper(target, _headerunit, bmifile)
    if not already_exists then
        return {
            name = job_name,
            sourcefile = headerunit.path,
            job = batchjobs:newjob(job_name, function(_, _, jobopt)
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
                    local name = headerunit.unique and headerunit.name or headerunit.path
                    progress.show(jobopt.progress, "${color.build.target}<%s> ${clear}${color.build.object}compiling.headerunit.$(mode) %s", target:name(), name)
                    if option.get("diagnosis") then
                        print("mapper file %s --------\n%s--------", headerunit_mapper, io.readfile(headerunit_mapper))
                    end
                    _compile(target,
                        _make_headerunitflags(target, headerunit, headerunit_mapper, opt),
                        opt.stl_headerunit and headerunit.name or path.translate(headerunit.sourcefile), bmifile)
                    os.tryrm(headerunit_mapper)
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
        local headerunit_mapper = _generate_headerunit_modulemapper_file(headerunit)
        local name = headerunit.unique and path.filename(headerunit.name) or headerunit.name
        if option.get("diagnosis") then
            batchcmds:show("mapper file for %s (%s) --------\n%s--------", name, headerunit_mapper, io.readfile(headerunit_mapper))
        end
        batchcmds:show_progress(opt.progress, "${color.build.target}<%s> ${clear}${color.build.object}compiling.headerunit.$(mode) %s", target:name(), name)
        _batchcmds_compile(batchcmds, target,
                    _make_headerunitflags(target, headerunit, headerunit_mapper, opt),
               opt.stl_headerunit and headerunit.name or path.translate(headerunit.sourcefile), headerunit.bmifile)
        batchcmds:add_depfiles(headerunit.sourcefile)
        batchcmds:rm(headerunit_mapper)
    end
    batchcmds:add_depvalues(depvalues)
end

