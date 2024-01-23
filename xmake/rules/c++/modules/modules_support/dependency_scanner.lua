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
-- @file        dependency_scanner.lua
--

-- imports
import("core.base.json")
import("core.base.hashset")
import("compiler_support")
import("stl_headers")

function _dependency_scanner(target)
    local cachekey = tostring(target)
    local dependency_scanner = compiler_support.memcache():get2("dependency_scanner", cachekey)
    if dependency_scanner == nil then
        if target:has_tool("cxx", "clang", "clangxx") then
            dependency_scanner = import("clang.dependency_scanner", {anonymous = true})
        elseif target:has_tool("cxx", "gcc", "gxx") then
            dependency_scanner = import("gcc.dependency_scanner", {anonymous = true})
        elseif target:has_tool("cxx", "cl") then
            dependency_scanner = import("msvc.dependency_scanner", {anonymous = true})
        else
            local _, toolname = target:tool("cxx")
            raise("compiler(%s): does not support c++ module!", toolname)
        end
        compiler_support.memcache():set2("dependency_scanner", cachekey, dependency_scanner)
    end
    return dependency_scanner
end

function _parse_meta_info(target, metafile)
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
        bmi = "build/.gens/stl_headerunit/linux/x86_64/release/rules/modules/cache/hello.gcm",
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
    for _, moduleinfo in ipairs(moduleinfos) do
        assert(moduleinfo.version <= 1)
        for _, rule in ipairs(moduleinfo.rules) do
            modules = modules or {}
            local m = {}
            if rule.provides then
                for _, provide in ipairs(rule.provides) do
                    m.provides = m.provides or {}
                    assert(provide["logical-name"])
                    local bmifile = provide["compiled-module-path"]
                    -- try to find the compiled module path in outputs filed (MSVC doesn't generate compiled-module-path)
                    if not bmifile then
                        for _, output in ipairs(rule.outputs) do
                            if output:endswith(compiler_support.get_bmi_extension(target)) then
                                bmifile = output
                                break
                            end
                        end

                        -- we didn't found the compiled module path, so we assume it
                        if not bmifile then
                            local name = provide["logical-name"] .. compiler_support.get_bmi_extension(target)
                            -- partition ":" character is invalid path character on windows
                            -- @see https://github.com/xmake-io/xmake/issues/2954
                            name = name:replace(":", "-")
                            bmifile = path.join(compiler_support.get_outputdir(target,  name), name)
                        end
                    end
                    m.provides[provide["logical-name"]] = {
                        bmi = bmifile,
                        sourcefile = moduleinfo.sourcefile,
                        interface = provide["is-interface"]
                    }
                end
            else
                m.cppfile = moduleinfo.sourcefile
            end
            assert(rule["primary-output"])
            modules[path.translate(rule["primary-output"])] = m
        end
    end

    for _, moduleinfo in ipairs(moduleinfos) do
        for _, rule in ipairs(moduleinfo.rules) do
            local m = modules[path.translate(rule["primary-output"])]
            for _, r in ipairs(rule.requires) do
                m.requires = m.requires or {}
                local p = r["source-path"]
                if not p then
                    for _, dependency in pairs(modules) do
                        if dependency.provides and dependency.provides[r["logical-name"]] then
                            p = dependency.provides[r["logical-name"]].bmi
                            break
                        end
                    end
                end
                m.requires[r["logical-name"]] = {
                    method = r["lookup-method"] or "by-name",
                    path = p and path.translate(p) or nil,
                    unique = r["unique-on-source-path"] or false
                }
            end
        end
    end
    return modules
end


-- check circular dependencies for the given module
function _check_circular_dependencies_of_module(name, moduledeps, modulesources, depspath)
    for _, dep in ipairs(moduledeps[name]) do
        local depinfo = moduledeps[dep]
        if depinfo then
            local depspath_sub
            if depspath then
                for idx, name in ipairs(depspath) do
                    if name == dep then
                        local circular_deps = table.slice(depspath, idx)
                        table.insert(circular_deps, dep)
                        local sourceinfo = ""
                        for _, circular_depname in ipairs(circular_deps) do
                            local sourcefile = modulesources[circular_depname]
                            if sourcefile then
                                sourceinfo = sourceinfo .. ("\n  -> module(%s) in %s"):format(circular_depname, sourcefile)
                            end
                        end
                        os.raise("circular modules dependency(%s) detected!%s", table.concat(circular_deps, ", "), sourceinfo)
                    end
                end
                depspath_sub = table.join(depspath, dep)
            end
            _check_circular_dependencies_of_module(dep, moduledeps, modulesources, depspath_sub)
        end
    end
end

-- check circular dependencies
-- @see https://github.com/xmake-io/xmake/issues/3031
function _check_circular_dependencies(modules)
    local moduledeps = {}
    local modulesources = {}
    for _, mod in pairs(modules) do
        if mod then
            if mod.provides and mod.requires then
                for name, provide in pairs(mod.provides) do
                    modulesources[name] = provide.sourcefile
                    local deps = moduledeps[name]
                    if deps then
                        table.join2(deps, mod.requires)
                    else
                        moduledeps[name] = table.keys(mod.requires)
                    end
                end
            end
        end
    end
    for name, _ in pairs(moduledeps) do
        _check_circular_dependencies_of_module(name, moduledeps, modulesources, {name})
    end
end

function _topological_sort_visit(node, nodes, modules, output)
    if node.marked then
        return
    end
    assert(not node.tempmarked)
    node.tempmarked = true
    local m1 = modules[node.objectfile]
    for _, n in ipairs(nodes) do
        if not n.tempmarked then
            local m2 = modules[n.objectfile]
            if m2 then
                for name, _ in pairs(m1.provides) do
                    if m2.requires and m2.requires[name] then
                        _topological_sort_visit(n, nodes, modules, output)
                    end
                end
            end
        end
    end
    node.tempmarked = false
    node.marked = true
    table.insert(output, 1, node.objectfile)
end

function _topological_sort_has_node_without_mark(nodes)
    for _, node in ipairs(nodes) do
        if not node.marked then
            return true
        end
    end
    return false
end

function _topological_sort_get_first_unmarked_node(nodes)
    for _, node in ipairs(nodes) do
        if not node.marked and not node.tempmarked then
            return node
        end
    end
end

function _fill_needed_module(target, modules, module)
    local needed_modules = {}

    for required_name, required_module in pairs(module.requires) do
        table.insert(needed_modules, required_name)
        table.join2(needed_modules, _fill_needed_module(target, modules, required_module))
    end

    return needed_modules
end

function _get_package_modules(target, package, opt)
    local package_modules

    local modulesdir = path.join(package:installdir(), "modules")
    local metafiles = os.files(path.join(modulesdir, "*", "*.meta-info"))
    for _, metafile in ipairs(metafiles) do
        package_modules = package_modules or {}
        local modulefile, name, metadata = _parse_meta_info(target, metafile)
        package_modules[name] = {file = path.join(modulesdir, modulefile), metadata = metadata}
    end

    return package_modules
end

-- get module dependencies
function get_module_dependencies(target, sourcebatch, opt)
    local cachekey = target:name() .. "/" .. sourcebatch.rulename
    local modules = compiler_support.memcache():get2("modules", cachekey)
    if modules == nil or opt.regenerate then
        modules = compiler_support.localcache():get2("modules", cachekey)
        opt.progress = opt.progress or 0
        local changed = _dependency_scanner(target).generate_dependencies(target, sourcebatch, opt)
        if changed or modules == nil then
            local moduleinfos = compiler_support.load_moduleinfos(target, sourcebatch)
            modules = _parse_dependencies_data(target, moduleinfos)
            if modules then
                _check_circular_dependencies(modules)
            end
            modules = cull_unused_modules(target, modules)
            compiler_support.localcache():set2("modules", cachekey, modules)
            compiler_support.localcache():save()
        end
        compiler_support.memcache():set2("modules", cachekey, modules)
    end
    return modules
end

-- get headerunits info
function get_headerunits(target, sourcebatch, modules)
    local headerunits
    local stl_headerunits
    for _, objectfile in ipairs(sourcebatch.objectfiles) do
        local m = modules[objectfile]
        if m then
            for name, r in pairs(m.requires) do
                if r.method ~= "by-name" then
                    local unittype = r.method == "include-angle" and ":angle" or ":quote"
                    if stl_headers.is_stl_header(name) then
                        stl_headerunits = stl_headerunits or {}
                        if not table.find_if(stl_headerunits, function(i, v) return v.name == name end) then
                            table.insert(stl_headerunits, {name = name, path = r.path, type = unittype, unique = r.unique})
                        end
                    else
                        headerunits = headerunits or {}
                        if not table.find_if(headerunits, function(i, v) return v.name == name end) then
                            table.insert(headerunits, {name = name, path = r.path, type = unittype, unique = r.unique})
                        end
                    end
                end
            end
        end
    end
    return headerunits, stl_headerunits
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
        if not module_depname and not compiler_support.has_module_extension(sourcefile) then
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
                module_dep["source-path"] = compiler_support.find_quote_header_file(target, sourcefile, module_depname)
            elseif module_depname:startswith("<") then
                module_depname = module_depname:sub(2, -2)
                module_dep["lookup-method"] = "include-angle"
                module_dep["unique-on-source-path"] = true
                module_dep["source-path"] = compiler_support.find_angle_header_file(target, module_depname)
            end
            module_dep["logical-name"] = module_depname
            table.insert(module_deps, module_dep)
            module_deps_set:insert(module_depname)
        end
        ::continue::
    end

    if module_name_export or internal then
        local outputdir = compiler_support.get_outputdir(target, sourcefile)

        local provide = {}
        provide["logical-name"] = module_name_export or module_name_private
        provide["source-path"] = sourcefile
        provide["is-interface"] = not internal
        provide["compiled-module-path"] = path.join(outputdir, (module_name_export or module_name_private) .. compiler_support.get_bmi_extension(target))

        rule.provides = {}
        table.insert(rule.provides, provide)
    end

    rule.requires = module_deps
    table.insert(output.rules, rule)
    local jsondata = json.encode(output)
    io.writefile(jsonfile, jsondata)
end

-- extract packages modules dependencies
function get_all_packages_modules(target, opt)
    local packages_modules

    -- parse all meta-info and append their informations to the package store
    local packages = target:pkgs() or {}

    for _, deps in pairs(target:orderdeps()) do
        table.join2(packages, deps:pkgs())
    end

    for _, package in pairs(packages) do
        local package_modules = _get_package_modules(target, package, opt)
        if package_modules then
           packages_modules = packages_modules or {}
           table.join2(packages_modules, package_modules)
        end
    end

    return packages_modules
end

-- topological sort
function sort_modules_by_dependencies(objectfiles, modules)
    local output = {}
    local nodes  = {}
    for _, objectfile in ipairs(objectfiles) do
        local m = modules[objectfile]
        if m then
            table.insert(nodes, {marked = false, tempmarked = false, objectfile = objectfile})
        end
    end
    while _topological_sort_has_node_without_mark(nodes) do
        local node = _topological_sort_get_first_unmarked_node(nodes)
        _topological_sort_visit(node, nodes, modules, output)
    end
    return output
end

-- get source modulefile for external target deps
function get_targetdeps_modules(target)
    local sourcefiles
    for _, dep in ipairs(target:orderdeps()) do
        local sourcebatch = dep:sourcebatches()["c++.build.modules.builder"]
        if sourcebatch and sourcebatch.sourcefiles then
            for _, sourcefile in ipairs(sourcebatch.sourcefiles) do
                local fileconfig = dep:fileconfig(sourcefile)
                local public = (fileconfig and fileconfig.public and not fileconfig.external) or false
                if public then
                    sourcefiles = sourcefiles or {}
                    table.insert(sourcefiles, sourcefile)
                    target:fileconfig_add(sourcefile, {external = true})
                end
            end
        end
    end
    return sourcefiles
end

-- cull unused packages modules
-- removed named module not used in the translation units
-- when building a library we only cull external modules because we need module objectfiles to be linked inside the library
-- on an executable we cull explicitly referenced module
function cull_unused_modules(target, modules)

    local cull_all_modules = target:kind() == "executable"

    local needed_modules = {}
    for _, module in pairs(modules) do
        local fileconfig = target:fileconfig(module.sourcefile)
        local external = fileconfig and fileconfig.external
        if not (cull_all_modules and external) then
            goto CONTINUE
        end

        if module.provides and module.requires then
            table.join2(needed_modules, _fill_needed_module(target, modules, module))
        end

        ::CONTINUE::
    end

    local culled = {}
    for objectfile, module in pairs(modules) do
        -- if cull_all_modules and modules.provides then
        --     local name,_,_ = compiler_support.get_provided_module(module)
        --     if module.requires then
        --         for required, _ in pairs(module.requires) do
        --             table.insert(needed_modules, required)
        --         end
        --     end
        --     if table.find(needed_modules, name) then
        --        culled[objectfile] = module
        --     end
        -- else
             culled[objectfile] = module
        -- end
    end

    return culled
end
