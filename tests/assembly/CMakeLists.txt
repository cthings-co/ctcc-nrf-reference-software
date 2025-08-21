# Copyright (c) 2025 CTHINGS.CO
# SPDX-License-Identifier: Apache-2.0

cmake_minimum_required(VERSION 3.13.1)

find_package(Zephyr REQUIRED HINTS $ENV{ZEPHYR_BASE})

project(assembly)

set(src_dir ${CMAKE_CURRENT_SOURCE_DIR}/src)
set(inc_dir ${CMAKE_CURRENT_SOURCE_DIR}/inc)

target_sources(app PRIVATE ${src_dir}/main.c)
target_sources_ifdef(CONFIG_SPI_NOR app PRIVATE ${src_dir}/spi_nor_tests.c)

include_directories(
	${inc_dir})
