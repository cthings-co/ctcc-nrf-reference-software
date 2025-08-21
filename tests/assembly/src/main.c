/*
 * Copyright (c) 2025 CTHINGS.CO
 *
 * SPDX-License-Identifier: Apache-2.0
 */

#include <zephyr/ztest.h>
#include <zephyr/kernel.h>
#include <zephyr/sys/printk.h>
#include <zephyr/console/console.h>
#include <zephyr/drivers/gpio.h>

/* LEDs */
#define LED0_NODE DT_ALIAS(led0)
static const struct gpio_dt_spec led0 = GPIO_DT_SPEC_GET(LED0_NODE, gpios);
#define LED1_NODE DT_ALIAS(led1)
static const struct gpio_dt_spec led1 = GPIO_DT_SPEC_GET(LED1_NODE, gpios);

ZTEST(assembly_base_tests, hello_console)
{
  for (int i = 0; i < 3; i++) {
		printk("Hello Console Test! %s\n\r", CONFIG_BOARD_TARGET);
  }
  printk("Waiting for any input to confirm it works both ways...\n\r");

  console_getchar();
}

ZTEST(assembly_base_tests, leds)
{
  /* Each CTCC has 2 LEDs signals, just turn them on and wait for confirmation */
  zassert_ok(!gpio_is_ready_dt(&led0));
  zassert_ok(!gpio_is_ready_dt(&led1));
	zassert_ok(gpio_pin_configure_dt(&led0, GPIO_OUTPUT_ACTIVE));
	zassert_ok(gpio_pin_configure_dt(&led1, GPIO_OUTPUT_ACTIVE));
	zassert_ok(gpio_pin_toggle_dt(&led0));
	zassert_ok(gpio_pin_toggle_dt(&led1));
  printk("Press 'y' to confirm LEDs are on...\n\r");

  uint8_t c = console_getchar();

  zassert_equal(c, 'y', "LEDs not confirmed to be working!");
	zassert_ok(gpio_pin_toggle_dt(&led0));
	zassert_ok(gpio_pin_toggle_dt(&led1));
}

static void *setup_assembly(void)
{
	console_init();

  return NULL;
}

ZTEST_SUITE(assembly_base_tests, NULL, setup_assembly, NULL, NULL, NULL);
