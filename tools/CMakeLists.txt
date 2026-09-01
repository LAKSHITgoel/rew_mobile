# Desktop CLI front end for rewcore.
add_executable(rewcli rewcli.cpp)
target_link_libraries(rewcli PRIVATE rewcore)
target_compile_options(rewcli PRIVATE -Wall -Wextra)
