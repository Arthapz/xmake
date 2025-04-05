includes("a", "b")

set_policy("build.c++.modules.std", false)

target("test")
    add_deps("a", "b")
    add_files("src/*.cpp")
    set_languages("cxxlatest")
