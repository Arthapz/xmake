add_rules("mode.debug", "mode.release")

add_defines("_UNICODE", "UNICODE")

target("UMDFSkeleton")
    add_rules("wdk.env.umdf", "wdk.driver")
    add_values("wdk.tracewpp.flags", "-scan:internal.h")
    add_files("*.cpp", {rules = "wdk.tracewpp"})
    add_files("*.rc", "*.inx")
    set_values("wdk.umdf.sdkver", "1.9")
    add_files("exports.def")
    on_config(function(target)
        if target:has_tool("sh", "clang", "clangxx") then
            target:add("shflags", "-Wl,/ENTRY:_DllMainCRTStartup" .. (is_arch("x86") and "@12" or ""), {force = true})
        else
            target:add("shflags", "/ENTRY:_DllMainCRTStartup" .. (is_arch("x86") and "@12" or ""), {force = true})
        end
    end)

