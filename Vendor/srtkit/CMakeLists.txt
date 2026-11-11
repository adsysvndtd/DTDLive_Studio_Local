cmake_minimum_required(VERSION 3.20)
project(SRTKit LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# SRT_PREFIX: thư mục cài libsrt + mbedtls (include/, lib/)
set(SRT_PREFIX "" CACHE PATH "Prefix chứa libsrt.a và mbedtls")
option(SRTKIT_BUILD_TESTS "Build test (Linux/macOS)" ON)
option(SRTKIT_BUILD_OBJC "Build bridge Objective-C++ (iOS/macOS)" OFF)

set(SRTKIT_SOURCES
    src/CameraPair.cpp
    src/AbrController.cpp
    src/SrtBroadcaster.cpp
    src/SrtConnection.cpp
    src/SrtIngestServer.cpp
    src/SrtUrl.cpp
    src/TalkbackReceiver.cpp
    src/Timecode.cpp
    src/TsDemuxer.cpp
    src/TsMuxer.cpp
    src/WhipClient.cpp)

if(SRTKIT_BUILD_OBJC)
    enable_language(OBJCXX)
    list(APPEND SRTKIT_SOURCES ios/SRTKit.mm ios/CameraReceiver.mm ios/CameraPair.mm ios/IngestServer.mm)
endif()

add_library(srtkit STATIC ${SRTKIT_SOURCES})
target_include_directories(srtkit PUBLIC include ${SRT_PREFIX}/include)
target_compile_options(srtkit PRIVATE -Wall -Wextra -Wno-unused-parameter)
if(SRTKIT_BUILD_OBJC)
    target_include_directories(srtkit PUBLIC ios)
    set_source_files_properties(ios/SRTKit.mm ios/CameraReceiver.mm ios/CameraPair.mm ios/IngestServer.mm PROPERTIES COMPILE_FLAGS "-fobjc-arc")
endif()

find_package(Threads REQUIRED)
set(SRTKIT_LINK
    ${SRT_PREFIX}/lib/libsrt.a
    ${SRT_PREFIX}/lib/libmbedtls.a
    ${SRT_PREFIX}/lib/libmbedx509.a
    ${SRT_PREFIX}/lib/libmbedcrypto.a)
foreach(extra everest p256m)
    if(EXISTS ${SRT_PREFIX}/lib/lib${extra}.a)
        list(APPEND SRTKIT_LINK ${SRT_PREFIX}/lib/lib${extra}.a)
    endif()
endforeach()
target_link_libraries(srtkit PUBLIC ${SRTKIT_LINK} Threads::Threads)

if(SRTKIT_BUILD_TESTS)
    foreach(t test_publish test_unit test_talkback test_whip)
        add_executable(${t} tests/${t}.cpp)
        target_link_libraries(${t} PRIVATE srtkit)
    endforeach()
endif()
