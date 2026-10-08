cmake_minimum_required(VERSION 3.16)

# Your unit's address and PIN live in the git-ignored sdkconfig.secrets
# (see sdkconfig.secrets.example).
if(EXISTS "${CMAKE_CURRENT_LIST_DIR}/sdkconfig.secrets")
    set(SDKCONFIG_DEFAULTS "sdkconfig.defaults;sdkconfig.secrets")
endif()

include($ENV{IDF_PATH}/tools/cmake/project.cmake)
project(eclips_bridge)
