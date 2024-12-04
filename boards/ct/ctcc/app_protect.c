/*
 * Copyright (c) 2024 CTHINGS.CO
 *
 * SPDX-License-Identifier: Apache-2.0
 */

#include <zephyr/kernel.h>
#include <soc.h>

#if IS_ENABLED(CONFIG_SOC_SERIES_NRF91X)
#ifndef NRF_UICR
#define NRF_UICR NRF_UICR_S
#endif
#ifndef UICR_APPROTECT_PALL_Enabled
#define UICR_APPROTECT_PALL_Enabled UICR_APPROTECT_PALL_Protected
#endif
#endif /* CONFIG_SOC_SERIES_NRF91X* */

int security_init(void)
{
#if IS_ENABLED(CONFIG_NRF_APPROTECT_LOCK) && !IS_ENABLED(CONFIG_ARM_NONSECURE_FIRMWARE)
	if ((NRF_UICR->APPROTECT & UICR_APPROTECT_PALL_Msk) !=
			(UICR_APPROTECT_PALL_Enabled << UICR_APPROTECT_PALL_Pos)) {

		NRF_NVMC->CONFIG = NVMC_CONFIG_WEN_Wen << NVMC_CONFIG_WEN_Pos;
		while (NRF_NVMC->READY == NVMC_READY_READY_Busy) {
			;
		}

		NRF_UICR->APPROTECT = (NRF_UICR->APPROTECT & ~((uint32_t)UICR_APPROTECT_PALL_Msk)) |
			(UICR_APPROTECT_PALL_Enabled << UICR_APPROTECT_PALL_Pos);

		NRF_NVMC->CONFIG = NVMC_CONFIG_WEN_Ren << NVMC_CONFIG_WEN_Pos;
		while (NRF_NVMC->READY == NVMC_READY_READY_Busy) {
			;
		}

		NVIC_SystemReset();
	}
#endif /* CONFIG_NRF_APPROTECT_LOCK */

	return 0;
}

SYS_INIT(security_init, PRE_KERNEL_1, 10);
