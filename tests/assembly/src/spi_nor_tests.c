/*
 * Copyright (c) 2025 CTHINGS.CO
 *
 * SPDX-License-Identifier: Apache-2.0
 */

#include <zephyr/ztest.h>

#include <zephyr/drivers/flash.h>
#include <zephyr/drivers/gpio.h>
#include <zephyr/device.h>

#if DT_HAS_COMPAT_STATUS_OKAY(jedec_spi_nor)
#define SPI_FLASH_COMPAT jedec_spi_nor
#else
#error Unsupported flash driver
#endif
#define FLASH_TEST_REGION_OFFSET 0xff000
#define FLASH_SECTOR_SIZE        4096

ZTEST(spi_nor_tests, test_01_spi_nor_init)
{
	const struct device *flash_dev = DEVICE_DT_GET_ONE(SPI_FLASH_COMPAT);

	zassert_ok(!device_is_ready(flash_dev), "SPI flash driver was not found!\n");
}

ZTEST(spi_nor_tests, test_02_spi_nor_erase)
{
	const struct device *flash_dev = DEVICE_DT_GET_ONE(SPI_FLASH_COMPAT);
	int rc;

	zassert_ok(!device_is_ready(flash_dev), "SPI flash driver was not found!\n");

	rc = flash_erase(flash_dev, FLASH_TEST_REGION_OFFSET,
			 FLASH_SECTOR_SIZE);
	zassert_ok(rc, "Flash erase failed! %d\n", rc);
}

ZTEST(spi_nor_tests, test_03_spi_nor_write)
{
	const uint8_t expected[] = { 0x55, 0xaa, 0x66, 0x99 };
	const size_t len = sizeof(expected);
	const struct device *flash_dev = DEVICE_DT_GET_ONE(SPI_FLASH_COMPAT);
	int rc;

	zassert_ok(!device_is_ready(flash_dev), "SPI flash driver was not found!\n");

	rc = flash_write(flash_dev, FLASH_TEST_REGION_OFFSET, expected, len);
	zassert_ok(rc, "Flash write failed! %d\n", rc);
}

ZTEST(spi_nor_tests, test_04_spi_nor_verify)
{
	const uint8_t expected[] = { 0x55, 0xaa, 0x66, 0x99 };
	const size_t len = sizeof(expected);
	uint8_t buf[sizeof(expected)];
	const struct device *flash_dev = DEVICE_DT_GET_ONE(SPI_FLASH_COMPAT);
	int rc;

	zassert_ok(!device_is_ready(flash_dev), "SPI flash driver was not found!\n");

	memset(buf, 0, len);
	rc = flash_read(flash_dev, FLASH_TEST_REGION_OFFSET, buf, len);
	PRINT("I: expected: [0x%x][0x%x][0x%x][0x%x] | read: [0x%x][0x%x][0x%x][0x%x]",
			expected[0], expected[1], expected[2], expected[3],
			buf[0], buf[1], buf[2], buf[3]);
	zassert_ok(rc, "Flash read failed! %d\n", rc);

	zassert_ok(memcmp(expected, buf, len), "Data read does not match data written!!\n");
}

ZTEST(spi_nor_tests, test_05_spi_nor_clean_up)
{
	const uint8_t expected[] = { 0xff, 0xff, 0xff, 0xff };
	const size_t len = sizeof(expected);
	uint8_t buf[sizeof(expected)];
	const struct device *flash_dev = DEVICE_DT_GET_ONE(SPI_FLASH_COMPAT);
	int rc;

	zassert_ok(!device_is_ready(flash_dev), "SPI flash driver was not found!\n");

	rc = flash_erase(flash_dev, FLASH_TEST_REGION_OFFSET,
			 FLASH_SECTOR_SIZE);
	zassert_ok(rc, "Flash erase failed! %d\n", rc);

	memset(buf, 0, len);
	rc = flash_read(flash_dev, FLASH_TEST_REGION_OFFSET, buf, len);
	PRINT("I: expected: [0x%x][0x%x][0x%x][0x%x] | read: [0x%x][0x%x][0x%x][0x%x]",
			expected[0], expected[1], expected[2], expected[3],
			buf[0], buf[1], buf[2], buf[3]);
	zassert_ok(rc, "Flash read failed! %d\n", rc);

	zassert_ok(memcmp(expected, buf, len), "Data read does not match data written!!\n");
}

ZTEST_SUITE(spi_nor_tests, NULL, NULL, NULL, NULL, NULL);
