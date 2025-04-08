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
-- @file        scanner.lua
--

-- imports
import("core.base.json")
import("core.base.hashset")
import("core.base.graph")
import("core.base.option")
import("async.runjobs")
import("support")
import("stlheaders")

function _scanner(target)
    return support.import_implementation_of(target, "scanner")
end

function _parse_meta_info(metafile)
    local metadata = json.loadfile(metafile)
    if metadata.file and metadata.name then
        return metadata.file, metadata.name, metadata
    end

    local filename = path.basename(metafile)
    local metadir = path.directory(metafile)
    for _, ext in ipairs({".mpp", ".mxx", ".cppm", ".ixx"}) do
        if os.isfile(path.join(metadir, filename .. ext)) then
            filename = filename .. ext
            break
        end
    end

    local sourcecode = io.readfile(path.join(path.directory(metafile), filename))
    sourcecode = sourcecode:gsub("//.-\n", "\n")
    sourcecode = sourcecode:gsub("/%*.-%*/", "")

    local name
    for _, line in ipairs(sourcecode:split("\n", {plain = true})) do
        name = line:match("export%s+module%s+(.+)%s*;") or line:match("export%s+__preprocessed_module%s+(.+)%s*;")
        if name then
            break
        end
    end
    return filename, name, metadata
end

function _get_headerunit_bmifile(target, headerfile, key)
    local outputdir = support.get_outputdir(target, headerfile, {headerunit = true, key = key})
    return path.join(outputdir, path.filename(headerfile) .. support.get_bmi_extension(target))
end

-- parse module dependency data
--[[
{
  "build/.objs/stl_headerunit/linux/x86_64/release/src/hello.mpp.o" = {
    requires = {
      iostream = {
        method = "include-angle",
        unique = true,
        path = "/usr/include/c++/11/iostream"
      }
    },
    provides = {
      hello = {
        bmifile = "build/.gens/stl_headerunit/linux/x86_64/release/rules/modules/cache/hello.gcm",
        sourcefile = "src/hello.mpp"
      }
    }
  },
  "build/.objs/stl_headerunit/linux/x86_64/release/src/main.cpp.o" = {
    requires = {
      hello = {
        method = "by-name",
        unique = false,
        path = "build/.gens/stl_headerunit/linux/x86_64/release/rules/modules/cache/hello.gcm"
      }
    }
  }
}]]
function _parse_dependencies_data(target, moduleinfos)
    local modules
    local modules_names = hashset.new()
    for _, moduleinfo in ipairs(moduleinfos) do
        assert(moduleinfo.version <= 1)
        for _, rule in ipairs(moduleinfo.rules) do
            assert(rule["primary-output"])

            modules = modules or {}
            local module = {objectfile = path.translate(rule["primary-output"]), sourcefile = moduleinfo.sourcefile}
            local fileconfig = target:fileconfig(module.sourcefile)
            local external = fileconfig and fileconfig.external
            
            if rule.provides then
                -- assume rule.provides is always one element on C++
                -- @see https://www.open-std.org/jtc1/sc22/wg21/docs/papers/2022/p1689r5.html
                local provide = rule.provides and rule.provides[1]
                if provide then
                    assert(provide["logical-name"])

                    module.name = provide["logical-name"]
                    modules_names:insert(module.name)
                    module.sourcefile = module.sourcefile or path.normalize(provide["source-path"])
                    module.interface = provide["is-interface"] == nil and true or provide["is-interface"]
                    module.implementation = not module.interface

                    -- XMake handle bmifile so we don't need rely on compiler-module-path
                    local fileconfig = target:fileconfig(module.sourcefile)
                    local defines
                    local module_target = target
                    if fileconfig and fileconfig.external then
                        defines = external.defines
                        if not fileconfig.external.moduleonly and fileconfig.external.target then
                            module_target = fileconfig.external.target
                        end
                    end
                    local bmifile = support.get_bmi_path(provide["logical-name"] .. support.get_bmi_extension(target))
                    module.bmifile = path.join(support.get_outputdir(module_target, moduleinfo.sourcefile, {named = module.interface}), bmifile)
                    module.defines = defines
                end
            end

            if rule.requires then
                module.deps = {}
                for _, dep in ipairs(rule.requires) do
                    local method = dep["lookup-method"] or "by-name"
                    local name = dep["logical-name"]
                    module.deps[name] = {
                        name = name,
                        method = method,
                        unique = dep["unique-on-source-path"] or false,
                    }
                    if dep["source-path"] then
                        local sourcefile = path.normalize(dep["source-path"])
                        module.deps[name].sourcefile = sourcefile
                        module.deps[name].headerunit = true
                        -- insert headerunits into modules
                        if not modules[sourcefile] then
                            modules[sourcefile] = module.deps[name]
                            local key = support.get_headerunit_key(target, sourcefile)
                            modules[sourcefile].bmifile = _get_headerunit_bmifile(external and external.target or target, sourcefile, key)
                        elseif external and not external.moduleonly then
                            local key = support.get_headerunit_key(target, sourcefile)
                            modules[sourcefile].bmifile = _get_headerunit_bmifile(external and external.target or target, sourcefile, key)
                        end
                        if modules[sourcefile].name ~= name then
                            modules[sourcefile].aliases = modules[sourcefile].aliases or {}
                            table.insert(modules[sourcefile].aliases, name)
                        end
                    end
                end
            end

            assert(module.sourcefile)
            modules[module.sourcefile] = module
        end
    end
    -- check if a dependency is missing
    for _, module in pairs(modules) do
        for dep_name, dep in pairs(module.deps) do
            if dep.method == "by-name" then
                assert(modules_names:has(dep_name), format("missing %s dependency for module %s", dep_name, module.name or module.sourcefile))
            end
        end
    end
    return modules
end

-- generate edges for DAG
function _get_edges(nodes, modules)
  local edges = {}
  local name_filemap = {}
  local deps_names = hashset.new()
  for _, node in ipairs(table.unique(nodes)) do
      local module = modules[node]
      if module.interface or module.implementation then
          if deps_names:has(module.name) then
              raise("duplicate module name detected \"" .. module.name .. "\"\n    -> " .. module.sourcefile .. "\n    -> " .. name_filemap[module.name])
          end
          deps_names:insert(module.name)
          name_filemap[module.name] = module.sourcefile
      elseif module.headerunit then
          deps_names:insert(module.name)
          name_filemap[module.name] = module.sourcefile
      end
      for dep_name, _ in table.orderpairs(module.deps) do
          for _, dep_node in ipairs(nodes) do
              local dep_module = modules[dep_node]
              if (dep_module.interface or dep_module.implementation or dep_module.headerunit) and dep_name == dep_module.name then
                  table.insert(edges, {dep_node, node})
                  break
              end
          end
      end
  end
  return edges
end

function _get_package_modules(package)
    local package_modules

    local modulesdir = path.join(package:installdir(), "modules")
    local metafiles = os.files(path.join(modulesdir, "*", "*.meta-info"))
    for _, metafile in ipairs(metafiles) do
        package_modules = package_modules or {}
        local modulefile, _, metadata = _parse_meta_info(metafile)

        -- -- patch flags with include directories
        -- local defines = compinst:compflags({target = target, sourcekind = "cxx"}) or {}
        -- local is_includeflag = false
        -- local includeflags = {}
        -- for _, flag in ipairs(flags) do
        --     if is_includeflag then
        --         table.insert(includeflags, flag)
        --         is_includeflag = false
        --     elseif flag == "-I" or flag == "-isystem" or flag == "/I" then
        --         table.insert(includeflags, flag)
        --         is_includeflag = true
        --     elseif flag:startswith("-I") or flag:startswith("-isystem") or flag:startswith("/I") then
        --         table.insert(includeflags, flag)
        --     end
        -- end
        -- metadata.defines = table.join(metadata.flags, includeflags)
        -- metadata.defines = defines
        
        local moduleonly = not package:libraryfiles()
        package_modules[path.join(modulesdir, modulefile)] = {defines = metadata.defines,
                                                              moduleonly = moduleonly}
    end

    return package_modules
end

-- generate dependency files
function _generate_dependencies(target, sourcebatch, opt)
    local changed = false
    if opt.progress then
        if type(opt.progress) == "table" then
            opt.progress = tostring(opt.progress)
            opt.progress = tonumber(opt.progress:sub(1, -2))
        end
    else
       opt.progress = 0
    end
    if opt.batchjobs then
        local jobs = option.get("jobs") or os.default_njob()
        runjobs(target:name() .. "_module_scanner", function(index)
            local sourcefile = sourcebatch.sourcefiles[index]
            changed = _scanner(target).generate_dependency_for(target, sourcefile, opt) or changed
        end, {comax = jobs, total = #sourcebatch.sourcefiles})
    else
        for _, sourcefile in ipairs(sourcebatch.sourcefiles) do
            changed = _scanner(target).generate_dependency_for(target, sourcefile, opt) or changed
        end
    end
    return changed
end
-- get module dependencies
function get_module_dependencies(target, sourcebatch, opt)
    local cachekey = target:name() .. "/" .. sourcebatch.rulename
    local modules = support.memcache():get2("modules", cachekey)
    if modules == nil then
        modules = support.localcache():get2("modules", cachekey)
        opt.progress = opt.progress or 0
        local changed = _generate_dependencies(target, sourcebatch, opt)
        if changed or modules == nil then
            local moduleinfos = support.load_moduleinfos(target, sourcebatch)
            modules = _parse_dependencies_data(target, moduleinfos)
            support.localcache():set2("modules", cachekey, modules)
            support.localcache():save()
        end
        support.memcache():set2("modules", cachekey, modules)
    end
    return modules
end

-- get headerunits info
function sort_headerunits(modules, headerunits)
    local _headerunits
    local stl_headerunits
    for _, headerunit in ipairs(headerunits) do
        local module = modules[headerunit]
        assert(module)
        if stlheaders.is_stl_header(module.name) then
            stl_headerunits = stl_headerunits or {}
            table.insert(stl_headerunits, headerunit)
        else
            _headerunits = _headerunits or {}
            table.insert(_headerunits, headerunit)
        end
    end
    return _headerunits, stl_headerunits
end

-- https://www.open-std.org/jtc1/sc22/wg21/docs/papers/2022/p1689r5.html
--[[
{
  "version": 1,
  "revision": 0,
  "rules": [
    {
      "primary-output": "use-header.mpp.o",
      "requires": [
        {
          "logical-name": "<header.hpp>",
          "source-path": "/path/to/found/header.hpp",
          "unique-on-source-path": true,
          "lookup-method": "include-angle"
        }
      ]
    },
    {
      "primary-output": "header.hpp.bmi",
      "provides": [
        {
          "logical-name": "header.hpp",
          "source-path": "/path/to/found/header.hpp",
          "unique-on-source-path": true,
        }
      ]
    }
  ]
}]]
function fallback_generate_dependencies(target, jsonfile, sourcefile, preprocess_file)
    local output = {version = 1, revision = 0, rules = {}}
    local rule = {outputs = {jsonfile}}
    rule["primary-output"] = target:objectfile(sourcefile)

    local module_name_export
    local module_name_private
    local module_deps = {}
    local module_deps_set = hashset.new()
    local sourcecode = preprocess_file(sourcefile) or io.readfile(sourcefile)
    local internal = false
    sourcecode = sourcecode:gsub("//.-\n", "\n")
    sourcecode = sourcecode:gsub("/%*.-%*/", "")
    for _, line in ipairs(sourcecode:split("\n", {plain = true})) do
        if line:match("#") then
            goto continue
        end
        if not module_name_export then
            module_name_export = line:match("export%s+module%s+(.+)%s*;") or line:match("export%s+__preprocessed_module%s+(.+)%s*;")
        end
        if not module_name_private then
            module_name_private = line:match("module%s+(.+)%s*;") or line:match("__preprocessed_module%s+(.+)%s*;")
            if module_name_private then
                internal = module_name_private:find(":")
            end
        end
        local module_depname = line:match("import%s+(.+)%s*;")
        -- we need to parse module interface dep in cxx/impl_unit.cpp, e.g. hello.mpp and hello_impl.cpp
        -- @see https://github.com/xmake-io/xmake/pull/2664#issuecomment-1213167314
        if not module_depname and not support.has_module_extension(sourcefile) then
            module_depname = module_name_private
        end
        if module_depname and not module_deps_set:has(module_depname) then
            local module_dep = {}
            -- partition? import :xxx;
            if module_depname:startswith(":") then
                local module_name = (module_name_export or module_name_private or "")
                module_name = module_name:split(":")[1]
                module_dep["unique-on-source-path"] = true
                module_depname = module_name .. module_depname
            elseif module_depname:startswith("\"") then
                module_depname = module_depname:sub(2, -2)
                module_dep["lookup-method"] = "include-quote"
                module_dep["unique-on-source-path"] = true
                module_dep["source-path"] = support.find_quote_header_file(target, sourcefile, module_depname)
            elseif module_depname:startswith("<") then
                module_depname = module_depname:sub(2, -2)
                module_dep["lookup-method"] = "include-angle"
                module_dep["unique-on-source-path"] = true
                module_dep["source-path"] = support.find_angle_header_file(target, module_depname)
            end
            module_dep["logical-name"] = module_depname
            table.insert(module_deps, module_dep)
            module_deps_set:insert(module_depname)
        end
        ::continue::
    end

    if module_name_export or internal then
        local outputdir = support.get_outputdir(target, sourcefile, {named = true})

        local provide = {}
        provide["logical-name"] = module_name_export or module_name_private
        provide["source-path"] = sourcefile
        provide["is-interface"] = not internal
        provide["compiled-module-path"] = path.join(outputdir, (module_name_export or module_name_private) .. support.get_bmi_extension(target))

        rule.provides = {}
        table.insert(rule.provides, provide)
    end

    rule.requires = module_deps
    table.insert(output.rules, rule)
    local jsondata = json.encode(output)
    io.writefile(jsonfile, jsondata)
end

-- extract packages modules dependencies
function get_all_packages_modules(target)

    -- parse all meta-info and append their informations to the package store
    local packages = target:pkgs() or {}
    for _, deps in ipairs(target:orderdeps()) do
        table.join2(packages, deps:pkgs())
    end

    local packages_modules
    for _, package in table.orderpairs(packages) do
        local package_modules = _get_package_modules(package)
        if package_modules then
           packages_modules = packages_modules or {}
           table.join2(packages_modules, package_modules)
        end
    end
    return packages_modules
end

-- topological sort
function sort_modules_by_dependencies(target, modules)
    local built_modules = {}
    local built_headerunits = {}
    local objectfiles = {}

    -- feed the dag
    local edges = _get_edges(table.keys(modules), modules)
    local dag = graph.new(true)
    for _, e in ipairs(edges) do
        dag:add_edge(e[1], e[2])
    end
    -- check if dag have dependency cycles
    local has_cycle = dag:find_cycle()
    if has_cycle then
        local cycle = dag:find_cycle()
        if cycle then
            local names = {}
            for _, sourcefile in ipairs(cycle) do
                local module = modules[sourcefile]
                table.insert(names, module.name or module.sourcefile)
            end
            local module = modules[cycle[1]]
            table.insert(names, module.name or module.sourcefile)
            raise("circular modules dependency detected!\n%s", table.concat(names, "\n   -> import "))
        end
    end
    -- sort sourcefiles by dependencies
    local sourcefiles_sorted = dag:topological_sort()
    sourcefiles_sorted = table.reverse(sourcefiles_sorted)
    local sourcefiles_sorted_set = hashset.from(sourcefiles_sorted)
    for sourcefile, _ in pairs(modules) do
        if not sourcefiles_sorted_set:has(sourcefile) then
            table.insert(sourcefiles_sorted, sourcefile)
            sourcefiles_sorted_set:insert(sourcefile)
        end
    end
    -- prepare objectfiles list built by the target
    local culleds
    for _, sourcefile in ipairs(sourcefiles_sorted) do
        local module = modules[sourcefile]
        local insert = false
        local insert_objectfile = false
        local name
        local fileconfig = target:fileconfig(sourcefile)
        local external = fileconfig and fileconfig.external
        local public = fileconfig and fileconfig.public or false
        local can_cull = target:policy("build.c++.modules.culling")
        if fileconfig and fileconfig.cull ~= nil then
            can_cull = can_cull and fileconfig.cull
        end
        local dont_cull = false
        if module.interface or module.implementation then
            can_cull = can_cull and not public
            name = module.name

            insert = true
            insert_objectfile = not external

            if external then
                dont_cull = true
            end

            if external and external.reused then
                insert = false
            end

            if external and external.moduleonly then
                insert_objectfile = true
            end

            -- if culling is enabled and not a public module, try to cull
            if can_cull and insert and not public then
                insert = false
                local old_insert_objectfile = insert_objectfile
                insert_objectfile = false
                local edges = dag:adjacent_edges(sourcefile)
                if edges then
                    for _, edge in ipairs(edges) do
                        if edge:to() ~= sourcefile and sourcefiles_sorted_set:has(edge:to()) then
                            insert = true
                            insert_objectfile = old_insert_objectfile
                            break
                        end
                    end
                end
            end
            if not insert then
                insert_objectfile = false
            end
        elseif module.headerunit then
            local key = support.get_headerunit_key(target, sourcefile)
            local insert = (module.bmifile == _get_headerunit_bmifile(target, sourcefile, key)) -- external headerunit ?
            if insert and can_cull then
                insert = false
                local edges = dag:adjacent_edges(sourcefile)
                if edges then
                    for _, edge in ipairs(edges) do
                        if edge:to() ~= sourcefile and sourcefiles_sorted_set:has(edge:to()) then
                            insert = true
                            break
                        end
                    end
                end
            end
            if insert then
                table.insert(built_headerunits, sourcefile)
            end
        else
            -- if the module is not a named module, we always insert it
            insert = true
            insert_objectfile = support.has_module_extension(sourcefile)
        end

        -- if module not culled build it, if not notify that the module has been culled
        if insert_objectfile then
            table.insert(objectfiles, tostring(target:objectfile(sourcefile)))
        end
        if insert then
            table.insert(built_modules, sourcefile)
        elseif dont_cull then
        elseif not module.headerunit then
            sourcefiles_sorted_set:remove(sourcefile)
            if can_cull and name ~= "std" and name ~= "std.compat" then
                culleds = culleds or {}
                culleds[target:name()] = culleds[target:name()] or {}
                table.insert(culleds[target:name()], format("%s -> %s", name, sourcefile))
            end
        end
    end

    -- if some named modules has been culled, notify the user
    if culleds then
        if option.get("verbose") then
            local culled_strs = {}
            for target_name, m in pairs(culleds) do
                table.insert(culled_strs, format("%s:\n        %s", target_name, table.concat(m, "\n        ")))
            end
            wprint("some modules have got culled, because it is not consumed by its target nor flagged as a public module with add_files(\"xxx.mpp\", {public = true})\n    %s",
                   table.concat(culled_strs, "\n    "))
        else
            wprint("some modules have got culled, use verbose (-v) mode to more informations")
        end
    end
    table.sort(objectfiles)
    return built_modules, table.unique(built_headerunits), objectfiles
end

-- check if flags are compatible for module reuse
function _are_flags_compatible(target, other, sourcefile)
    local compinst1 = target:compiler("cxx")
    local flags1 = compinst1:compflags({sourcefile = sourcefile, target = target, sourcekind = "cxx"})

    local compinst2 = other:compiler("cxx")
    local flags2 = compinst2:compflags({sourcefile = sourcefile, target = other, sourcekind = "cxx"})
    
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

-- get source modulefile for external target deps
function get_targetdeps_modules(target)
    local modules
    local pkg_modules = get_all_packages_modules(target)
    if pkg_modules then
        modules = modules or {}
        table.join2(modules, pkg_modules)
    end
    for _, dep in ipairs(target:orderdeps()) do
        local sourcebatch = dep:sourcebatches()["c++.build.modules.builder"]
        if sourcebatch and sourcebatch.sourcefiles then
            local dep_deps_modules = get_targetdeps_modules(dep)
            for sourcefile, external in pairs(dep_deps_modules) do
                modules = modules or {}
                local reuse = target:policy("build.c++.modules.tryreuse") and not dep:is_moduleonly() and _are_flags_compatible(target, dep, sourcefile)
                modules[sourcefile] = external
                modules[sourcefile].reused = reuse
                modules[sourcefile].target = modules[sourcefile].target or dep
            end
            local compinst = dep:compiler("cxx")
            for _, sourcefile in ipairs(sourcebatch.sourcefiles) do
                if not modules or not modules[sourcefile] then
                    local fileconfig = dep:fileconfig(sourcefile)
                    local public = (fileconfig and fileconfig.public and not fileconfig.external) or false
                    if public then
                        modules = modules or {}
                        local flags = compinst:compflags({target = dep, sourcefile = sourcefile, sourcekind = "cxx"})
                        local defines = support.get_defines(flags)
                        local reuse = target:policy("build.c++.modules.tryreuse") and not dep:is_moduleonly() and _are_flags_compatible(target, dep, sourcefile)
                        modules[sourcefile] = { moduleonly = dep:is_moduleonly(),
                                                reused = reuse,
                                                defines = defines,
                                                target = dep }
                    end
                end
            end
        end
    end
    return modules
end

