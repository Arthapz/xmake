﻿target("a")
    set_languages("cxxlatest")
    set_kind("headeronly")
    add_rules("c++.moduleonly")
    add_headerfiles("*.hpp")
    add_files("a.mpp")
