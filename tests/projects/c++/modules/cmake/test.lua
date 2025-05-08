import("lib.detect.find_tool")
import("core.base.semver")
import("core.tool.toolchain")
import("utils.ci.is_running", {alias = "ci_is_running"})

function _cleanup()
    os.rm(".xmake", "build")
end

function _gen_cmakelist()
    if not os.isfile("CMakeLists.txt") then
        os.vrunv("xmake project -k cmake")
    end
end

function _build(t)
    os.mv("xmake.lua", "xmake.lua_")
    local verbose_flags = ""
    if ci_is_running() then
        verbose_flags = " -vD"
    end
    os.vrunv("xmake f --trybuild=cmake --toolchain=" .. t .. verbose_flags, {shell = true})
    os.vrunv("xmake b" .. verbose_flags, {shell = true})
    os.mv("xmake.lua_", "xmake.lua")
end

function _set_env(toolchain)
        local cc = toolchain:tool("cc")
        local cxx = toolchain:tool("cxx")
        local ld = toolchain:tool("ld")
        local ar = toolchain:tool("ar")
        local rc = toolchain:tool("mrc")

        os.setenv("CC", cc)
        os.setenv("CXX", cxx)
        os.setenv("LD", ld)
        os.setenv("AR", ar)
        os.setenv("RC", mrc)
    end
end

function main(t)
    _cleanup()

    os.setenv("CMAKE_GENERATOR", "Ninja")

    local cmake = find_tool("cmake", {version = true})
    local ninja = find_tool("ninja")
    if ninja and cmake and cmake.version and semver.compare(cmake.version, "3.28") >= 0 then
        os.setenv("CMAKE_MAKE_PROGRAM", ninja.program .. (is_subhost("msys") and ".exe" or ""))
        _gen_cmakelist()
        if is_subhost("windows") then
            local clang = find_tool("clang", {version = true})
            if clang and clang.version and semver.compare(clang.version, "19.0") >= 0 then
                local _toolchain = toolchain.load("llvm")
                _set_env(_toolchain)
                _build("clang")
                _cleanup()
            end
            local msvc = toolchain.load("msvc")
            if msvc and msvc:check() then
                _set_env(msvc)
                _build("msvc")
            end
        elseif is_subhost("msys") or is_subhost("linux") then
            local gcc = find_tool("gcc", {version = true})
            if gcc and gcc.version and semver.compare(gcc.version, "14.0") >= 0 then
                local _toolchain = toolchain.load("gcc")
                _set_env(_toolchain)
                _build("gcc")
                _cleanup()
            end
            local clang = find_tool("clang", {version = true})
            if clang and clang.version and semver.compare(clang.version, "19.0") >= 0 then
                local _toolchain = toolchain.load("clang")
                _set_env(_toolchain)
                _build("clang")
            end
        end
        os.setenv("CC", nil)
        os.setenv("CXX", nil)
        os.setenv("LD", nil)
        os.setenv("AR", nil)
        os.setenv("RC", nil)
        os.setenv("CMAKE_MAKE_PROGRAM", nil)
    end
end
