/*  RetroArch - A frontend for libretro.
 *  Copyright (C) 2021 - David Guillen Fandos
 *
 *  RetroArch is free software: you can redistribute it and/or modify it under the terms
 *  of the GNU General Public License as published by the Free Software Found-
 *  ation, either version 3 of the License, or (at your option) any later version.
 *
 *  RetroArch is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY;
 *  without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
 *  PURPOSE.  See the GNU General Public License for more details.
 *
 *  You should have received a copy of the GNU General Public License along with RetroArch.
 *  If not, see <http://www.gnu.org/licenses/>.
 */

#ifndef _MISC_CPUFREQ_H
#define _MISC_CPUFREQ_H

#include <stdint.h>

RETRO_BEGIN_DECLS

typedef struct cpu_scaling_driver
{
   /* Policy number in the sysfs tree */
   unsigned int policy_id;
   /* Which CPUs this scaling driver will affect */
   char *affected_cpus;
   /* Governor and available governors */
   char *scaling_governor;
   struct string_list *available_governors;
   /* Current frequency (value might be slightly old) */
   uint32_t current_frequency;
   /* Max and min frequencies, for the hardware and policy */
   uint32_t min_cpu_freq, max_cpu_freq;
   uint32_t min_policy_freq, max_policy_freq;
   /* Available frequencies table (can be NULL), ends with zero */
   uint32_t *available_freqs;
} cpu_scaling_driver_t;

/* Safely free all memory used by the driver */
void cpu_scaling_driver_free();

/* Get a list of the available cpu scaling drivers */
cpu_scaling_driver_t **get_cpu_scaling_drivers(bool can_update);

/* Set max and min policy cpu frequency */
bool set_cpu_scaling_min_frequency(
   cpu_scaling_driver_t *driver, uint32_t min_freq);
bool set_cpu_scaling_max_frequency(
   cpu_scaling_driver_t *driver, uint32_t max_freq);

/* Calculate next/previous frequencies */
uint32_t get_cpu_scaling_next_frequency(cpu_scaling_driver_t *driver,
   uint32_t freq, int step);

/* Set the scaling governor for this scaling driver */
bool set_cpu_scaling_governor(cpu_scaling_driver_t *driver, const char* governor);

RETRO_END_DECLS

#endif

