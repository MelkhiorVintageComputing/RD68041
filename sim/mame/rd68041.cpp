// SPDX-License-Identifier: CERN-OHL-S-2.0
// Copyright 2026 Romain Dolbeau
// Source location: https://github.com/MelkhiorVintageComputing/RD68041

// RD68041 in MAME (M14) -- see rd68041.h.

#include "emu.h"
#include "rd68041.h"

#include "cpu/m68000/m68kdasm.h"

#include <cstdlib>
#include <dlfcn.h>

DEFINE_DEVICE_TYPE(RD68041, rd68041_device, "rd68041", "RD68041 (MC68040 / MC68LC040 RTL under Verilator)")

rd68041_device::rd68041_device(const machine_config &mconfig, const char *tag, device_t *owner, u32 clock)
	: cpu_device(mconfig, RD68041, tag, owner, clock)
	, m_program_config("program", ENDIANNESS_BIG, 32, 32)
	, m_cpu_space_config("cpu_space", ENDIANNESS_BIG, 32, 32, 0, address_map_constructor(FUNC(rd68041_device::cpu_space_map), this))
	, m_reset_cb(*this)
{
}

rd68041_device::~rd68041_device()
{
	delete m_vlt;
	if (m_dl)
		dlclose(m_dl);
}

// The default CPU space: every level autovectored, as MAME's 68000 family
// answers when the driver gives no map of its own.
void rd68041_device::cpu_space_map(address_map &map)
{
	for (int l = 1; l <= 7; l++)
		map(0xfffffff1 | (l << 1), 0xfffffff1 | (l << 1)).lr8(NAME([l] () -> u8 { return 0x18 + l; }));
}

device_memory_interface::space_config_vector rd68041_device::memory_space_config() const
{
	return space_config_vector {
		std::make_pair(AS_PROGRAM, &m_program_config),
		std::make_pair(AS_CPU_SPACE, &m_cpu_space_config)
	};
}

std::unique_ptr<util::disasm_interface> rd68041_device::create_disassembler()
{
	return std::make_unique<m68k_disassembler>(m68k_disassembler::TYPE_68040);
}

void rd68041_device::device_start()
{
	m_program = &space(AS_PROGRAM);
	m_cpu_space = &space(AS_CPU_SPACE);

	const char *path = getenv("RD68041_VLT");
	if (!path || !*path)
		throw emu_fatalerror("rd68041: set RD68041_VLT to the core's shared object (sim/mame/build.sh vlt)");
	m_dl = dlopen(path, RTLD_NOW | RTLD_LOCAL);
	if (!m_dl)
		throw emu_fatalerror("rd68041: %s", dlerror());
	auto abi = rd68041_vlt_abi_fn(dlsym(m_dl, "rd68041_vlt_abi"));
	auto create = rd68041_vlt_create_fn(dlsym(m_dl, "rd68041_vlt_create"));
	if (!abi || !create || abi() != RD68041_VLT_ABI)
		throw emu_fatalerror("rd68041: %s is not an RD68041 core of ABI %d", path, RD68041_VLT_ABI);
	m_vlt = create(this);
	m_vlt->set_waits(m_waits);
	osd_printf_info("rd68041: %s, the %s\n", path, m_vlt->fpu() ? "MC68040" : "MC68LC040");

	set_icountptr(m_icount);

	state_add(STATE_GENPC, "PC", m_pc).callexport();
	state_add(STATE_GENPCBASE, "CURPC", m_pc).callexport().noshow();
	state_add(STATE_GENFLAGS, "GENFLAGS", m_sr).callexport().noshow();
	state_add(1, "SR", m_sr).callexport();
	state_add(2, "SP", m_sp).callexport();
	for (int i = 0; i < 8; i++)
		state_add(3 + i, string_format("D%d", i).c_str(), m_r.d[i]).callexport();
	for (int i = 0; i < 8; i++)
		state_add(11 + i, string_format("A%d", i).c_str(), m_r.a[i]).callexport();
	state_add(19, "USP", m_r.usp).callexport();
	state_add(20, "ISP", m_r.isp).callexport();
	state_add(21, "MSP", m_r.msp).callexport();
	state_add(22, "VBR", m_r.vbr).callexport();
	state_add(23, "CACR", m_r.cacr).callexport();
	state_add(24, "TC", m_r.tc).callexport();
	state_add(25, "URP", m_r.urp).callexport();
	state_add(26, "SRP", m_r.srp).callexport();
	state_add(27, "ITT0", m_r.itt0).callexport();
	state_add(28, "ITT1", m_r.itt1).callexport();
	state_add(29, "DTT0", m_r.dtt0).callexport();
	state_add(30, "DTT1", m_r.dtt1).callexport();

	// MAME insists on some saved state. The core's own state lives in the
	// Verilator model and is not saved: save states are not supported.
	save_item(NAME(m_lines));
	save_item(NAME(m_ipl7_low));

	m_wall0 = std::chrono::steady_clock::now();
}

void rd68041_device::device_reset()
{
	// The power-on initialisation is done at the first execute_run(), once
	// the driver's machine_reset() has set memory up for the reset vector.
	m_need_reset = true;
	m_halt_reported = false;
}

void rd68041_device::device_stop()
{
	if (!m_vlt)
		return;
	double wall = std::chrono::duration<double>(std::chrono::steady_clock::now() - m_wall0).count();
	double emu = double(m_vlt->clocks()) / double(clock());
	osd_printf_info("rd68041: %llu clocks (%.3f emulated s), %llu instruction boundaries, %llu bus retries, "
			"%.1f s wall, %.4f emulated s per wall s, %.0f clocks/s\n",
			(unsigned long long)m_vlt->clocks(), emu, (unsigned long long)m_boundaries,
			(unsigned long long)m_retries, wall, wall > 0 ? emu / wall : 0.0,
			wall > 0 ? double(m_vlt->clocks()) / wall : 0.0);
}

void rd68041_device::state_export(const device_state_entry &entry)
{
	if (!m_vlt)
		return;
	m_vlt->regs(m_r);
	m_pc = m_r.pc;
	m_sr = m_r.sr;
	m_sp = m_r.a[7];
}

void rd68041_device::present_ipl()
{
	int level = 0;
	for (int l = 7; l >= 1; l--)
		if (BIT(m_lines, l) && !(l == 7 && m_ipl7_low > 0)) {
			level = l;
			break;
		}
	if (level != m_ipl) {
		m_ipl = level;
		m_vlt->set_ipl(level);
	}
}

void rd68041_device::execute_set_input(int inputnum, int state)
{
	if (inputnum < 1 || inputnum > 7)
		return;
	bool was = BIT(m_lines, inputnum);
	if (state == CLEAR_LINE)
		m_lines &= ~(1 << inputnum);
	else
		m_lines |= 1 << inputnum;
	// Level 7 is edge-sensitive (UM 8.2.9): a clear followed at once by an
	// assert is a new interrupt, which the core sees only if the lower level
	// stays on the pins long enough to be synchronised.
	if (inputnum == 7 && was && state == CLEAR_LINE)
		m_ipl7_low = 4;
	if (m_vlt)
		present_ipl();
	m_stop_clocks = 0;
}

void rd68041_device::execute_run()
{
	if (m_need_reset) {
		m_need_reset = false;
		m_ipl = -1;
		m_vlt->power_on(8);
		m_icount -= 20;
		present_ipl();
	}
	while (m_icount > 0) {
		if (m_vlt->halted()) {
			if (!m_halt_reported) {
				m_halt_reported = true;
				logerror("halted at PC %08x\n", m_vlt->pc());
				osd_printf_warning("rd68041: halted (a double bus fault; PC %08x)\n", m_vlt->pc());
				machine().schedule_exit();
			}
			m_icount = 0;
			break;
		}
		// STOP with nothing to take: nothing changes until an input line
		// does, which can only happen between time slices.
		if (m_vlt->stopped() && m_ipl7_low == 0) {
			if (++m_stop_clocks > 16) {
				m_icount = 0;
				break;
			}
		} else {
			m_stop_clocks = 0;
		}
		if (m_vlt->clock()) {
			m_boundaries++;
			if (debugger_enabled())
				debugger_instruction_hook(m_vlt->pc());
		}
		m_icount--;
		if (m_ipl7_low > 0 && --m_ipl7_low == 0)
			present_ipl();
	}
}

uint32_t rd68041_device::read(uint32_t addr, int tm, uint32_t mask, bool *retry)
{
	uint32_t d = m_program->read_dword(addr & ~3u, mask);
	*retry = access_to_be_redone();
	if (*retry)
		m_retries++;
	return d;
}

void rd68041_device::write(uint32_t addr, int tm, uint32_t data, uint32_t mask, bool *retry)
{
	m_program->write_dword(addr & ~3u, data, mask);
	*retry = access_to_be_redone();
	if (*retry)
		m_retries++;
}

int rd68041_device::iack(int level)
{
	standard_irq_callback(level, m_vlt->pc());
	u8 v = m_cpu_space->read_byte(0xfffffff1 | (level << 1));
	return v == 0x18 + level ? -1 : v;
}
