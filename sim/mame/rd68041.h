// SPDX-License-Identifier: CERN-OHL-S-2.0
// Copyright 2026 Romain Dolbeau
// Source location: https://github.com/MelkhiorVintageComputing/RD68041

// RD68041 in MAME (M14): a cpu_device whose processor is the RTL,
// rd68041_top under Verilator, behind a pin-level bus agent
// (sim/mame/rd68041_vlt.cpp, loaded from the shared object $RD68041_VLT at
// start: the MC68040's build, or the MC68LC040's). RD68031's device, for the
// MC68040 bus.
//
// - AS_PROGRAM is the physical bus, 32 bits wide, as on the pins: the core
//   translates and caches inside, as the part does.
// - AS_CPU_SPACE (4, as for MAME's 68000 family) answers the interrupt
//   acknowledge: a byte at $FFFFFFF1 | level << 1, autovectors by default.
// - Input lines 1-7 are the interrupt levels, wire-ORed into IPL2-0; a fall
//   of level 7 is held off the pins for a few clocks so that the core sees
//   the new edge (UM 8.2.9).
// - An access a handler wants made again (cpu_device::retry_access) is
//   answered with a bus retry, and the core runs the transfer again.
// - reset_cb() follows RSTO, which the RESET instruction asserts (UM 7.10).
// - Time: one MAME cycle is one BCLK of the core.
//
// Copied into MAME's tree by sim/mame/build.sh, beside the Quadra's driver.
#ifndef MAME_APPLE_RD68041_H
#define MAME_APPLE_RD68041_H

#pragma once

#include "rd68041_vlt.h"

#include <chrono>

class rd68041_device : public cpu_device, private rd68041_vlt_bus
{
public:
	enum { AS_CPU_SPACE = 4 };

	rd68041_device(const machine_config &mconfig, const char *tag, device_t *owner, u32 clock);
	virtual ~rd68041_device();

	void set_waits(int w) { m_waits = w; }
	auto reset_cb() { return m_reset_cb.bind(); }

protected:
	virtual void device_start() override ATTR_COLD;
	virtual void device_reset() override ATTR_COLD;
	virtual void device_stop() override ATTR_COLD;

	virtual u32 execute_min_cycles() const noexcept override { return 1; }
	virtual u32 execute_max_cycles() const noexcept override { return 64; }
	virtual void execute_run() override;
	virtual void execute_set_input(int inputnum, int state) override;
	virtual bool execute_input_edge_triggered(int inputnum) const noexcept override { return inputnum == 7; }

	virtual space_config_vector memory_space_config() const override;
	virtual void state_export(const device_state_entry &entry) override;
	virtual std::unique_ptr<util::disasm_interface> create_disassembler() override;

private:
	// rd68041_vlt_bus
	virtual uint32_t read(uint32_t addr, int tm, uint32_t mask, bool *retry) override;
	virtual void write(uint32_t addr, int tm, uint32_t data, uint32_t mask, bool *retry) override;
	virtual int iack(int level) override;
	virtual void reset_out(bool asserted) override { m_reset_cb(asserted ? 1 : 0); }

	void cpu_space_map(address_map &map) ATTR_COLD;
	void present_ipl();

	address_space_config m_program_config, m_cpu_space_config;
	address_space *m_program = nullptr, *m_cpu_space = nullptr;
	int m_icount = 0;

	void *m_dl = nullptr;
	rd68041_vlt *m_vlt = nullptr;
	rd68041_vlt_regs m_r{};
	u32 m_pc = 0, m_sr = 0, m_sp = 0;

	int m_waits = 0;
	devcb_write_line m_reset_cb;
	u8 m_lines = 0;          // input lines 1-7 asserted, bit n for line n
	int m_ipl7_low = 0;      // clocks left that level 7 is held off the pins
	int m_ipl = -1;          // the level on the pins
	bool m_need_reset = true;
	bool m_halt_reported = false;
	int m_stop_clocks = 0;
	u64 m_boundaries = 0, m_retries = 0;
	std::chrono::steady_clock::time_point m_wall0;
};

DECLARE_DEVICE_TYPE(RD68041, rd68041_device)

#endif // MAME_APPLE_RD68041_H
