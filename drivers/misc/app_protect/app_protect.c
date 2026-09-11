/*
 * Copyright (c) 2024 CTHINGS.CO
 *
 * SPDX-License-Identifier: Apache-2.0
 */

#include <zephyr/kernel.h>
#include <soc.h>

/*
 * nRF91 names the locked field value ..._Protected rather than ..._Enabled, so the
 * UICR_APPROTECT_PALL_Enabled alias below is the one thing here that is strictly
 * required. NRF_UICR and NRF_NVMC do resolve on nRF91 in a Zephyr build - nrfx maps
 * them to the secure aliases (nrfx_config_nrf91.h: #define NRF_UICR NRF_UICR_S) - so
 * those two guards are belt-and-braces for a build that does not pull that header in,
 * not a fix for a macro that is missing.
 *
 * BOTH SoC-series symbols have to be tested, so that this file stays portable across
 * NCS generations. Zephyr renamed the series: SOC_SERIES_NRF91 is the live symbol on
 * the generation this tree pins and SOC_SERIES_NRF91X is its deprecated alias, while
 * on older ones it is the other way round - NRF91X is live and SOC_SERIES_NRF91 does
 * not exist. Testing one name alone would skip this block on the other generation and
 * then fail to compile on the undefined macros.
 */
#if IS_ENABLED(CONFIG_SOC_SERIES_NRF91) || IS_ENABLED(CONFIG_SOC_SERIES_NRF91X)
#ifndef NRF_UICR
#define NRF_UICR NRF_UICR_S
#endif
#ifndef NRF_NVMC
#define NRF_NVMC NRF_NVMC_S
#endif
#ifndef UICR_APPROTECT_PALL_Enabled
#define UICR_APPROTECT_PALL_Enabled UICR_APPROTECT_PALL_Protected
#endif
#endif /* CONFIG_SOC_SERIES_NRF91 || CONFIG_SOC_SERIES_NRF91X */

#if (IS_ENABLED(CONFIG_NRF_APPROTECT_LOCK) || IS_ENABLED(CONFIG_NRF_SECURE_APPROTECT_LOCK)) && \
    !IS_ENABLED(CONFIG_ARM_NONSECURE_FIRMWARE)

/*
 * UICR is flash, so a write can only clear bits - which is exactly why "locked" is
 * the all-zero field value on both families (nRF52840 PALL Enabled = 0x00 in an 8-bit
 * field; nRF91 PALL Protected = 0x00000000 across the whole word, shipped as
 * 0x50FA50FA HwUnprotected). Going from unprotected to protected only clears bits, so
 * no erase is needed and the change is one-way.
 */
static bool uicr_lock_word(volatile uint32_t *reg, uint32_t msk, uint32_t locked)
{
	NRF_NVMC->CONFIG = NVMC_CONFIG_WEN_Wen << NVMC_CONFIG_WEN_Pos;
	while (NRF_NVMC->READY == NVMC_READY_READY_Busy) {
		;
	}

	*reg = (*reg & ~msk) | locked;

	/*
	 * UICR is Normal memory (0x10001000 on nRF52840, 0x00FF8000 on nRF91 - both
	 * inside the Cortex-M Code region) while NVMC is Device memory. The core does
	 * not order a Normal-memory store against a later Device-memory store, so
	 * without this barrier the CONFIG=Ren below can retire first and the UICR write
	 * is simply dropped. nrfx's own word write does precisely this - ready-check,
	 * store, __DMB(), and only then revoke write-enable (see nvmc_word_write() and
	 * nrfx_nvmc_word_write() in nrfx/drivers/src/nrfx_nvmc.c) - and polling READY
	 * afterwards neither orders the store nor retries it.
	 */
	__DMB();

	NRF_NVMC->CONFIG = NVMC_CONFIG_WEN_Ren << NVMC_CONFIG_WEN_Pos;
	while (NRF_NVMC->READY == NVMC_READY_READY_Busy) {
		;
	}

	/*
	 * Report what UICR actually reads back, so the caller resets only for a write
	 * that took. A write that keeps failing would otherwise reset, find the word
	 * still unlocked, write, and reset again - bricking the card in a loop, on the
	 * one code path meant to run once in the life of the device.
	 */
	return (*reg & msk) == locked;
}
#endif /* CONFIG_NRF_APPROTECT_LOCK && !CONFIG_ARM_NONSECURE_FIRMWARE */

int security_init(void)
{
#if (IS_ENABLED(CONFIG_NRF_APPROTECT_LOCK) || IS_ENABLED(CONFIG_NRF_SECURE_APPROTECT_LOCK)) && \
    !IS_ENABLED(CONFIG_ARM_NONSECURE_FIRMWARE)
	bool reset_needed = false;

#if IS_ENABLED(CONFIG_NRF_APPROTECT_LOCK)
	const uint32_t ap_locked = UICR_APPROTECT_PALL_Enabled << UICR_APPROTECT_PALL_Pos;

	if ((NRF_UICR->APPROTECT & UICR_APPROTECT_PALL_Msk) != ap_locked) {
		if (uicr_lock_word(&NRF_UICR->APPROTECT,
				   (uint32_t)UICR_APPROTECT_PALL_Msk, ap_locked)) {
			reset_needed = true;
		}
	}
#endif /* CONFIG_NRF_APPROTECT_LOCK */

	/*
	 * nRF91 has a SECOND access port with its own UICR word. In this image - always
	 * a SECURE one, the driver depends on !ARM_NONSECURE_FIRMWARE - NCS's
	 * NRF_SECURE_APPROTECT_LOCK makes SystemInit force-protect that port on every
	 * boot; writing UICR here is what makes it permanent, so the part stays locked
	 * across an erase and reflash rather than only while our firmware runs. (On an
	 * _ns target the actor is TF-M instead, which writes both UICR words itself via
	 * nrfx_nvmc_word_write - permanently, not per-boot - and this helper is absent.)
	 *
	 * The symbol exists only on parts that have the port, so this compiles out on
	 * nRF52840 - whose UICR has no SECUREAPPROTECT member at all.
	 */
#if IS_ENABLED(CONFIG_NRF_SECURE_APPROTECT_LOCK)
	const uint32_t sap_locked =
		UICR_SECUREAPPROTECT_PALL_Protected << UICR_SECUREAPPROTECT_PALL_Pos;

	if ((NRF_UICR->SECUREAPPROTECT & UICR_SECUREAPPROTECT_PALL_Msk) != sap_locked) {
		if (uicr_lock_word(&NRF_UICR->SECUREAPPROTECT,
				   (uint32_t)UICR_SECUREAPPROTECT_PALL_Msk, sap_locked)) {
			reset_needed = true;
		}
	}
#endif /* CONFIG_NRF_SECURE_APPROTECT_LOCK */

	/* One reset once both words are settled: the MDK loads the soft branch from
	 * UICR at SystemInit, so the new state only takes effect after a reset.
	 */
	if (reset_needed) {
		NVIC_SystemReset();
	}
#endif /* CONFIG_NRF_APPROTECT_LOCK && !CONFIG_ARM_NONSECURE_FIRMWARE */

	return 0;
}

SYS_INIT(security_init, PRE_KERNEL_1, 10);
