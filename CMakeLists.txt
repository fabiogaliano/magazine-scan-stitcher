cmake_minimum_required(VERSION 3.20)
project(magazine_scan_stitcher VERSION 0.1.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

find_package(OpenCV 4.5 REQUIRED COMPONENTS core imgproc imgcodecs features2d calib3d)

add_library(magstitch_engine
    src/stitcher.cpp
)
target_include_directories(magstitch_engine PUBLIC include)
target_link_libraries(magstitch_engine PUBLIC ${OpenCV_LIBS})
target_compile_options(magstitch_engine PRIVATE -Wall -Wextra -Wpedantic)

add_executable(magstitch src/main.cpp)
target_link_libraries(magstitch PRIVATE magstitch_engine)

include(CTest)
if(BUILD_TESTING)
    add_executable(magstitch_tests tests/test_geometry.cpp)
    target_link_libraries(magstitch_tests PRIVATE magstitch_engine)
    add_test(NAME geometry COMMAND magstitch_tests)
endif()

install(TARGETS magstitch RUNTIME DESTINATION bin)
