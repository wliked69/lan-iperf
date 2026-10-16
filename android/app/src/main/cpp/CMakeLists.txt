cmake_minimum_required(VERSION 3.22)
project(laniperf LANGUAGES C)
get_filename_component(IPERF "${CMAKE_CURRENT_SOURCE_DIR}/../../../../../third_party/iperf/src" ABSOLUTE)
set(SOURCES cjson.c iperf_api.c iperf_error.c iperf_auth.c iperf_client_api.c
  iperf_locale.c iperf_server_api.c iperf_tcp.c iperf_udp.c iperf_sctp.c
  iperf_util.c iperf_time.c dscp.c net.c tcp_info.c timer.c units.c)
list(TRANSFORM SOURCES PREPEND "${IPERF}/")
add_library(laniperf SHARED bridge.c ${SOURCES})
target_include_directories(laniperf PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}" "${IPERF}")
target_compile_definitions(laniperf PRIVATE _GNU_SOURCE)
target_compile_features(laniperf PRIVATE c_std_11)
target_link_libraries(laniperf m)
# Compatible with Android devices using 16 KB memory pages.
target_link_options(laniperf PRIVATE "-Wl,-z,max-page-size=16384")
