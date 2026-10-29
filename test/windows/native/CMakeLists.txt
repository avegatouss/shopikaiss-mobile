cmake_minimum_required(VERSION 3.14)
project(shopikaiss_native_checks LANGUAGES CXX)
enable_testing()
add_executable(native_checks native_checks.cpp
  ../../../windows/runner/secret_protection.cpp
  ../../../windows/runner/instance_lock.cpp)
target_include_directories(native_checks PRIVATE ../../../windows/runner)
target_compile_features(native_checks PRIVATE cxx_std_17)
target_compile_definitions(native_checks PRIVATE NOMINMAX UNICODE _UNICODE)
target_link_libraries(native_checks PRIVATE crypt32 advapi32)
add_test(NAME windows_native_security COMMAND native_checks)
set_tests_properties(windows_native_security PROPERTIES TIMEOUT 30)
