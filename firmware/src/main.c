/*
 * Copyright (c) 2024 CTHINGS.CO
 *
 * SPDX-License-Identifier: Apache-2.0
 */

#include <stdio.h>
#include <zephyr/kernel.h>

int main(void)
{
	while(1) {
		printf("Hello World! %s\n", CONFIG_BOARD_TARGET);
		k_sleep(K_SECONDS(1));
	}

	return 0;
}
