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
-- @file        common.lua
--

-- imports
import("core.base.json")
import("core.base.bytes")
import("core.base.option")
import("core.base.hashset")
import("async.runjobs")
import("private.async.buildjobs")
import("private.action.clean.remove_files")
import("core.tool.compiler")
import("core.project.config")
import("core.project.depend")
import("utils.progress")
import("support")
import("scanner")

-- build target modules
function _build_modules(target, modules, built_modules, opt)
    if not opt.batchjobs then
        built_modules = table.reverse(built_modules)
    end
    for _, sourcefile in ipairs(built_modules) do
        local module = modules[sourcefile]

        opt.build_module(module, sourcefile, get_from_target_mapper(target, module.name).objectfile)
    end
end

-- build target headerunits
function _build_headerunits(headerunits, opt)
    for _, headerunit in ipairs(headerunits) do
        opt.build_headerunit(headerunit)
    end
end

-- check if flags are compatible for module reuse
function _are_flags_compatible(target, other, cppfile)
    local compinst1 = target:compiler("cxx")
    local flags1 = compinst1:compflags({sourcefile = cppfile, target = target})

    local compinst2 = other:compiler("cxx")
    local flags2 = compinst2:compflags({sourcefile = cppfile, target = other})

    local strip_defines = not target:policy("build.c++.modules.tryreuse.discriminate_on_defines")
    
    -- strip unrelevent flags
    flags1 = support.strip_flags(target, flags1, {strip_defines = strip_defines})
    flags2 = support.strip_flags(target, flags2, {strip_defines = strip_defines})

    if #flags1 ~= #flags2 then
        return false
    end

    table.sort(flags1)
    table.sort(flags2)

    for i = 1, #flags1 do
        if flags1[i] ~= flags2[i] then
            return false
        end
    end
    return true
end

-- try to reuse modules from other target
function _try_reuse_modules(target, modules)
    for _, module in pairs(modules) do
        local name, provide, cppfile = support.get_provided_module(module)
        if not provide then
            goto continue
        end

        cppfile = cppfile or module.cppfile

        local fileconfig = target:fileconfig(cppfile)
        local public = fileconfig and (fileconfig.public or fileconfig.external)
        if not public then
            goto continue
        end

        for _, dep in ipairs(target:orderdeps()) do
            if not _are_flags_compatible(target, dep, cppfile) then
                goto nextdep
            end
            local mapped = get_from_target_mapper(dep, name)
            if mapped then
                support.memcache():set2(target:name() .. name, "reuse", true)
                add_module_to_target_mapper(target, mapped.name, mapped.sourcefile, mapped.bmifile, table.join(mapped.opt or {}, {target = dep}))
                break
            end
            ::nextdep::
        end

        ::continue::
    end
    return modules
end

-- should we build this module or headerunit ?
function should_build(target, module)

    module = module.alias_of or module
    local _should_build = support.memcache():get2(target:name(), "should_build_" .. module.sourcefile)
    if _should_build == nil then
        local compinst = compiler.load("cxx", {target = target})
        local compflags = compinst:compflags({sourcefile = module.sourcefile, target = target})

        local dependfile = target:dependfile(module.bmifile or module.objectfile)
        local dependinfo = {}
        dependinfo.files = {module.sourcefile}
        dependinfo.values = {compinst:program(), compflags}
        dependinfo.lastmtime = os.isfile(module.bmifile or module.objectfile) and os.mtime(dependfile) or 0

        local old_dependinfo = target:is_rebuilt() and {} or (depend.load(dependfile) or {})
        if old_dependinfo.values then
            old_dependinfo.values[2] = support.strip_mapper_flags(target, old_dependinfo.values[2])
        end
        old_dependinfo.files = {module.sourcefile}

        -- force rebuild a module if any of its module dependency is rebuilt
        for dep_name, dep_module in table.orderpairs(module.deps) do
            local fileconfig = target:fileconfig(dep_module.sourcefile)
            local external = fileconfig and fileconfig.external
            local _target = target
            if external and external.target and not external.moduleonly then
                _target = external.target
            end

            local mapped_dep = get_from_target_mapper(_target, dep_name)
            if dep_module.headerunit and mapped_dep.alias_of then
                local key = support.get_headerunit_key(_target, dep_module.sourcefile)
                mapped_dep = mapped_dep.alias_of[key]
            end
            if should_build(_target, mapped_dep) then
                depend.save(dependinfo, dependfile)
                support.memcache():set2(target:name(), "should_build_" .. module.sourcefile, true)
                return true
            end
        end

        -- need build this object?
        local dryrun = option.get("dry-run")
        if dryrun or depend.is_changed(old_dependinfo, dependinfo) then
            depend.save(dependinfo, dependfile)
            support.memcache():set2(target:name(), "should_build_" .. module.sourcefile, true)
            return true
        end
        support.memcache():set2(target:name(), "should_build_" .. module.sourcefile, false)
        return false
    end
    return _should_build
end

-- generate meta module informations for package / other buildsystems import
--
-- e.g
-- {
--      "flags": ["--std=c++23"]
--      "imports": ["std", "bar"]
--      "name": "foo"
--      "file": "foo.cppm"
-- }
function _generate_meta_module_info(target, name, sourcefile, requires)

    local compinst = target:compiler("cxx")
    local flags = support.strip_flags(target, compinst:compflags({sourcefile = sourcefile, target = target, sourcekind = "cxx"})) or {}
    print("AAAAAAAA", compinst:compflags({sourcefile = sourcefile, target = target, sourcekind = "cxx"}), flags)
    local modulehash = support.get_modulehash(target, sourcefile)
    local module_metadata = {name = name, file = path.join(modulehash, path.filename(sourcefile))}

    -- add flags
    module_metadata.flags = flags

    -- add imports
    if requires then
        for _name, _ in table.orderpairs(requires) do
            module_metadata.imports = module_metadata.imports or {}
            table.append(module_metadata.imports, _name)
        end
    end
    return module_metadata
end

function _target_module_map_cachekey(target)
    local mode = config.mode()
    return target:name() .. "module_mapper" .. (mode or "")
end

function _builder(target)
    local cachekey = tostring(target)
    local builder = support.memcache():get2("builder", cachekey)
    if builder == nil then
        if target:has_tool("cxx", "clang", "clangxx", "clang_cl") then
            builder = import("clang.builder", {anonymous = true})
        elseif target:has_tool("cxx", "gcc", "gxx") then
            builder = import("gcc.builder", {anonymous = true})
        elseif target:has_tool("cxx", "cl") then
            builder = import("msvc.builder", {anonymous = true})
        else
            local _, toolname = target:tool("cxx")
            raise("compiler(%s): does not support c++ module!", toolname)
        end
        support.memcache():set2("builder", cachekey, builder)
    end
    return builder
end

function mark_build(target, key)
    support.memcache():set2(key, "_is_built", target:name(), true)
end

function is_built(target, key)
    return support.memcache():get2(key .. "_is_built", target:name())
end

-- build batchjobs for modules
function build_batchjobs_for_modules(modules, batchjobs, rootjob)
    return buildjobs(modules, batchjobs, rootjob)
end

-- build modules for batchjobs
function build_modules_for_batchjobs(target, batchjobs, modules, built_modules, opt)
    opt.rootjob = batchjobs:group_leave() or opt.rootjob
    batchjobs:group_enter(target:name() .. "/build_cxxmodules", {rootjob = opt.rootjob})

    -- add populate module job
    local modulesjobs = {}
    local populate_jobname = target:name() .. "_populate_module_map"
    modulesjobs[populate_jobname] = {
        name = populate_jobname,
        job = batchjobs:newjob(populate_jobname, function(_, _)
            _try_reuse_modules(target, modules)
            _builder(target).populate_module_map(target, modules)
        end)
    }

    -- add module jobs
    -- for _, sourcefile in ipairs(built_modules) do
    --     local module = modules[sourcefile]

    --     opt.build_module(module, sourcefile, get_from_target_mapper(target, module.name).objectfile)
    -- end
    -- _build_modules(target, modules built_modules, table.join(opt, {
    --    build_module = function(module, sourcefile, objectfile)
    --     local job_name = name and target:name() .. name or sourcefile
    --     modulesjobs[job_name] = _builder(target).make_module_buildjobs(target, batchjobs, job_name, deps,
    --         {module = module, objectfile = objectfile, cppfile = cppfile})
    --   end
    -- }))

    -- build batchjobs for modules
    build_batchjobs_for_modules(modulesjobs, batchjobs, opt.rootjob)
end

-- build modules for batchcmds
function build_modules_for_batchcmds(target, batchcmds, modules, built_modules, opt)

    local depmtime = 0
    -- build modules
    built_modules = table.reverse(built_modules)
    local builder = _builder(target)

    for _, sourcefile in ipairs(built_modules) do
        local module = modules[sourcefile]

        depmtime = math.max(depmtime,
            builder.make_module_buildcmds(target, batchcmds, module, opt))
    end

    batchcmds:set_depmtime(depmtime)
end

-- generate headerunits for batchjobs
function build_headerunits_for_batchjobs(target, batchjobs, sourcebatch, modules, opt)

    local user_headerunits, stl_headerunits = scanner.get_headerunits(target, sourcebatch, modules)
    if not user_headerunits and not stl_headerunits then
       return
    end

    -- we need new group(headerunits)
    -- e.g. group(build_modules) -> group(headerunits)
    opt.rootjob = batchjobs:group_leave() or opt.rootjob
    batchjobs:group_enter(target:name() .. "/build_headerunits", {rootjob = opt.rootjob})

    local build_headerunits = function(headerunits)
        local modulesjobs = {}
        _build_headerunits(target, headerunits, table.join(opt, {
            build_headerunit = function(headerunit, key, bmifile, outputdir, build)
                local job_name = target:name() .. key
                local job = _builder(target).make_headerunit_buildjobs(target, job_name, batchjobs, headerunit, bmifile, outputdir, table.join(opt, {build = build}))
                if job then
                  modulesjobs[job_name] = job
                end
            end
        }))
        build_batchjobs_for_modules(modulesjobs, batchjobs, opt.rootjob)
    end

    -- build stl header units first as other headerunits may need them
    if stl_headerunits then
        opt.stl_headerunit = true
        build_headerunits(stl_headerunits)
    end
    if user_headerunits then
        opt.stl_headerunit = false
        build_headerunits(user_headerunits)
    end
end

-- generate headerunits for batchcmds
function build_headerunits_for_batchcmds(target, batchcmds, modules, built_headerunits, opt)

    local headerunits, stl_headerunits = scanner.sort_headerunits(modules, built_headerunits)
    if not headerunits and not stl_headerunits then
       return
    end

    local builder = _builder(target)
    -- build stl header units first as other headerunits may need them
    opt.stl_headerunit = true
    for _, headerunit in ipairs(stl_headerunits) do
        builder.make_headerunit_buildcmds(target, batchcmds, modules[headerunit], opt)
    end
    opt.stl_headerunit = false
    for _, headerunit in ipairs(headerunits) do
        builder.make_headerunit_buildcmds(target, batchcmds, modules[headerunit], opt)
    end
end

function generate_metadata(target, modules)

    local public_modules
    for sourcefile, module in table.orderpairs(modules) do
        local fileconfig = target:fileconfig(sourcefile)
        local public = fileconfig and fileconfig.public
        if public then
            public_modules = public_modules or {}
            table.insert(public_modules, module)
        end
    end

    if not public_modules then
        return
    end

    local jobs = option.get("jobs") or os.default_njob()
    runjobs(target:name() .. "_install_modules", function(index, _, jobopt)
        local module = public_modules[index]
        local metafilepath = support.get_metafile(target, module.sourcefile)
        progress.show(jobopt.progress, "${color.build.target}<%s> generating.module.metadata %s", target:name(), module.name)
        local metadata = _generate_meta_module_info(target, module.name, module.sourcefile, module.deps)
        json.savefile(metafilepath, metadata)
    end, {comax = jobs, total = #public_modules})
end

-- invalidate module mapper keys
function _invalidate_mapper_keys(target)
    local memcache = support.memcache()
    memcache:set2(target:name(), "module_mapper_keys", nil)
end

-- get or create a target module mapper
function get_target_module_mapper(target)
    local memcache = support.memcache()
    local mapper = memcache:get2(target:name(), "module_mapper")
    if not mapper then
        mapper = {}
        memcache:set2(target:name(), "module_mapper", mapper)
    else
    end
    local memcache = support.memcache()
    -- we generate the keys map to optimise the efficiency
    local keys = memcache:get2(target:name(), "module_mapper_keys")
    if not keys then
        keys = {}
        for _, item in pairs(mapper) do
            if item.key then
                table.insert(keys, item.key)
            end
        end
        keys = hashset.from(keys)
        memcache:set2(target:name(), "module_mapper_keys", keys)
    end
    return mapper, keys
end

-- feed the module mapper
function feed_module_mapper(target, modules, built_modules, built_headerunits)
    local built_set = hashset.from(table.join(built_modules or {}, built_headerunits or {}))
    -- insert dependencies mappers
    local mapper, keys = get_target_module_mapper(target)
    for _, dep in ipairs(target:orderdeps()) do
        local dep_mapper = get_target_module_mapper(dep)
        if dep_mapper then
            table.join2(mapper, dep_mapper)
        end
    end

    -- feed modules map
    local compinst = target:compiler("cxx")
    for sourcefile, module in pairs(modules) do
        if built_set:has(sourcefile) then
            local fileconfig = target:fileconfig(sourcefile)
            local flags
            if fileconfig and fileconfig.external then
                flags = fileconfig.external.flags
            end
            if module.headerunit then
                flags = flags or support.strip_flags(target, compinst:compflags({sourcefile = sourcefile, target = target, sourcekind = "cxx"}))
                local key = support.get_headerunit_key(target, sourcefile, {flags = flags})
                if not keys:has(key) then
                    mapper[key] = {name = module.name, bmifile = module.bmifile, sourcefile = module.sourcefile, method = module.method, key = key}
                    _invalidate_mapper_keys(target)
                end
                mapper[module.name] = mapper[module.name] or {}
                mapper[module.name].alias_of = mapper[module.name].alias_of or {}
                mapper[module.name].alias_of[key] = mapper[key]
                for _, alias in ipairs(module.aliases) do
                    mapper[alias] = {alias_of = mapper[key]}
                    mapper[alias].alias_of[key] = mapper[key]
                end
            elseif module.interface or module.implementation then
                if not keys[module.name] then
                    mapper[module.name] = {name = module.name, bmifile = module.bmifile, sourcefile = module.sourcefile, deps = module.deps, flags = flags}
                end
            end
        end
    end
end

-- add a module to target mapper
function add_module_to_target_mapper(target, module, flags)
    local mapper, keys = get_target_module_mapper(target)
end

-- add a headerunit to target mapper
function add_headerunit_to_target_mapper(target, module, key)
    local mapper, keys = get_target_module_mapper(target)

end

-- get a module from target mapper by name
function get_from_target_mapper(target, key)
    local mapper = get_target_module_mapper(target)
    return mapper[key]
end

-- check if dependencies changed
function is_dependencies_changed(target, module)
    local cachekey = target:name() .. module.name
    local requires = hashset.from(table.keys(module.requires or {}))
    local oldrequires = support.memcache():get2(cachekey, "oldrequires")
    local changed = false
    if oldrequires then
        if oldrequires ~= requires then
           requires_changed = true
        else
           for required in requires:items() do
              if not oldrequires:has(required) then
                  requires_changed = true
                  break
              end
           end
        end
    end
    return requires, changed
end

function clean(target)
    -- we cannot use target:data("cxx.has_modules"),
    -- because on_config will be not called when cleaning targets
    if support.contains_modules(target) then
        remove_files(support.modules_cachedir(target))
        if option.get("all") then
            remove_files(support.stlmodules_cachedir(target))
            support.localcache():clear()
            support.localcache():save()
        end
    end
end

function main(target, batch, sourcebatch, opt)

    if target:data("cxx.has_modules") then
        -- append std module
        local std_modules = support.get_stdmodules(target)
        if std_modules then
            table.join2(sourcebatch.sourcefiles, std_modules)
        end

        -- add target deps modules
        local deps_sourcefiles
        if target:orderdeps() then
            deps_sourcefiles = scanner.get_targetdeps_modules(target)
        end

        -- extract packages modules dependencies
        deps_sourcefiles = table.join(deps_sourcefiles or {}, scanner.get_all_packages_modules(target) or {})
        -- print(deps_sourcefiles)
        -- append to sourcebatch
        for _, sourcefile_data in ipairs(deps_sourcefiles) do
            table.insert(sourcebatch.sourcefiles, sourcefile_data.file)
            target:fileconfig_add(sourcefile_data.file, {external = sourcefile_data.external})
        end

        support.patch_sourcebatch(target, sourcebatch, opt)
        local modules = scanner.get_module_dependencies(target, sourcebatch, opt)

        if not target:is_moduleonly() then
            -- avoid building non referenced modules
            local built_modules, built_headerunits, objectfiles = scanner.sort_modules_by_dependencies(target, modules)
            sourcebatch.objectfiles = objectfiles

            -- feed module mapper
            feed_module_mapper(target, modules, built_modules, built_headerunits)

            if opt.batchjobs then
            -- build headerunits
                build_headerunits_for_batchjobs(target, batch, modules, built_headerunits, opt)

                -- build modules
                build_modules_for_batchjobs(target, batch, modules, built_modules, opt)
            else
                -- build headerunits
                build_headerunits_for_batchcmds(target, batch, modules, built_headerunits, opt)

                -- build modules
                build_modules_for_batchcmds(target, batch, modules, built_modules, opt)
            end
        else
            -- avoid duplicate linking of object files of non-module programs
            sourcebatch.objectfiles = {}
        end

        support.localcache():set2(target:name(), "c++.modules", modules)
        support.localcache():save()
    else
        sourcebatch.sourcefiles = {}
        sourcebatch.objectfiles = {}
        sourcebatch.dependfiles = {}
    end
end
