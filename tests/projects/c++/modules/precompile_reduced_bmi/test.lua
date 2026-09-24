inherit(".test_base")
import("core.base.json")

local _CLANG_MIN_VER = "23"

function clang_min_ver()
    return _CLANG_MIN_VER
end

function _check_commands(config, outdata)
    local has_precompile_reduced_bmi = outdata:find("--precompile-reduced-bmi", 1, true) ~= nil
    local expect_precompile_reduced_bmi = config.precompile_reduced_bmi and config.two_phases
    assert(has_precompile_reduced_bmi == expect_precompile_reduced_bmi,
        "unexpected --precompile-reduced-bmi usage\n%s", outdata)

    if config.two_phases then
        local object_command
        for _, line in ipairs(outdata:split("\n", {plain = true})) do
            if line:find("hello.mpp", 1, true) and
               (line:find("hello.mpp.o", 1, true) or line:find("hello.mpp.obj", 1, true)) and
               line:find(" -c ", 1, true) and
               not line:find("clang-scan-deps", 1, true) and
               not line:find("--precompile", 1, true) then
                object_command = line
                break
            end
        end
        assert(object_command, "module object command missing\n%s", outdata)
        local consumes_bmi = object_command:find("hello.pcm", 1, true) ~= nil
        assert(consumes_bmi ~= expect_precompile_reduced_bmi, "unexpected module object input\n%s", outdata)
    end
end

function _check_incremental()
    local outdata = os.iorun("xmake -v")
    if outdata:find("compiling", 1, true) or
       outdata:find("linking", 1, true) or
       outdata:find("generating", 1, true) then
        raise("Modules incremental compilation does not work\n%s", outdata)
    end
end

function _check_compile_commands(config)
    os.run("xmake project -k compile_commands")
    local bmi_command
    local object_command
    for _, command in ipairs(assert(json.loadfile("compile_commands.json"))) do
        if command.file:endswith("hello.mpp") then
            local commandline = command.command or table.concat(command.arguments or {}, " ")
            if commandline:find("--precompile", 1, true) then
                bmi_command = commandline
            elseif commandline:find("hello.mpp.o", 1, true) or commandline:find("hello.mpp.obj", 1, true) then
                object_command = commandline
            end
        end
    end
    assert(bmi_command, "module BMI command missing from compile_commands.json")
    assert(object_command, "module object command missing from compile_commands.json")
    local expect_precompile_reduced_bmi = config.precompile_reduced_bmi and config.two_phases
    assert((bmi_command:find("--precompile-reduced-bmi", 1, true) ~= nil) == expect_precompile_reduced_bmi,
        "unexpected module BMI command\n%s", bmi_command)
    assert(object_command:find("hello.mpp", 1, true) and not object_command:find("hello.pcm", 1, true),
        "unexpected module object command\n%s", object_command)
end

function _configure(config)
    local argv = {"f", "--yes", "--toolchain=" .. config.toolchain}
    if config.platform then
        table.join2(argv, {"-p", config.platform})
    end
    if config.runtimes then
        table.insert(argv, "--runtimes=" .. config.runtimes)
    end
    local policies = "--policies=build.c++.modules.std:" .. (config.stdmodule and "y" or "n")
    policies = policies .. ",build.c++.modules.fallbackscanner:" .. (config.fallbackscanner and "y" or "n")
    policies = policies .. ",build.c++.modules.two_phases:" .. (config.two_phases and "y" or "n")
    policies = policies .. ",build.c++.modules.clang.precompile_reduced_bmi:" .. (config.precompile_reduced_bmi and "y" or "n")
    table.insert(argv, policies)
    table.join2(argv, config.flags or {})
    os.execv("xmake", argv)
end

function _check_build(config)
    local outdata = os.iorun("xmake -rv")
    _check_commands(config, outdata)

    os.run("xmake run")
    _check_incremental()
    if config.two_phases then
        _check_compile_commands(config)
    end

    if config.two_phases then
        local toggled_config = table.clone(config)
        toggled_config.precompile_reduced_bmi = not config.precompile_reduced_bmi
        _configure(toggled_config)
        local toggled_outdata = os.iorun("xmake -v")
        _check_commands(toggled_config, toggled_outdata)
        os.run("xmake run")
        _check_incremental()
        _check_compile_commands(toggled_config)
    end
end

function main(_)
    run_tests({compiler = "clang", version = clang_min_ver(), precompile_reduced_bmi = true, build = _check_build})
end
