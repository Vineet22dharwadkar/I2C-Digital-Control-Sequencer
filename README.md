# I2C-Digital-Control-Sequencer
RTL design of I²C slave and programmable digital sequencer for biomedical SoC applications

Context
This project was built during an internship on a mixed-signal biosensor IC targeting early cardiac event detection. The chip optically measures blood-oxygen (SpO₂) and heart-rate signals (PPG) at 760 nm. The digital domain I designed enables the host MCU to configure the entire analog front end through a single I2C bus LED drive currents, integration windows, ADC timing, and interrupt masking without any dedicated firmware running on-chip.

The target application is a wearable patch that monitors continuously and alerts the patient (or caregiver) before a cardiac event escalates, giving time to seek treatment.

I2C Digital Control Sequencer RTL Design (AS7038RB)

Internship Project · Mixed-Signal Biosensor IC · Digital Domain RTL
Designed, debugged, and verified in SystemVerilog.
Part of a larger pre-cardiac-arrest detection system built around the AS7038RB optical biosensor.


What is this project?
This is the digital control block of a mixed-signal biosensor chip designed for pre-cardiac-arrest (early arrhythmia) detection. The chip shines infrared LEDs onto skin, measures the reflected light through photodiodes (photoplethysmography / PPG), and sends the data over I2C to a host MCU.
The digital domain which I designed is the brain that:

Accepts configuration commands from the host MCU over I2C
Stores those settings in a register file
Drives a precise timing sequencer that controls the LEDs, TIA integrator, and ADC
Reports interrupts back to the MCU when a measurement cycle completes

Think of it as the firmware-in-silicon: the MCU writes "fire LED1 at time-step 5, open the integrator at step 7, trigger the ADC at step 12" and this block executes those instructions in hardware, cycle after cycle, with microsecond-level timing accuracy.


System Architecture
The full chip is mixed-signal. My work covers everything inside the dashed box:

![Image](https://github.com/user-attachments/assets/6cb2f081-3762-451d-8585-07bba9977e1b)


<img width="848" height="350" alt="Image" src="https://github.com/user-attachments/assets/daa443f2-3118-4505-ae09-2f2dd07d4ef6" />

Block Breakdown
1. i2c_slave.sv — I2C Slave (11-state FSM)
The I2C slave is a fully standard-compliant 400kHz I2C peripheral. It supports:

7-bit addressing (device address 0x30)
Single-byte and sequential (burst) register writes
Single-byte and sequential register reads (with repeated START)
Open-drain SDA/SCL with a 3-stage synchroniser for metastability protection

The slave is implemented as a Moore FSM driven purely by scl_rise, scl_fall, i2c_start, and i2c_stop events there is no bit-bang counter or timer inside it. Every state transition is deterministic and edge-triggered.
States:

<img width="723" height="600" alt="Image" src="https://github.com/user-attachments/assets/2aac75b8-0e24-4e91-9463-909932dd334f" />

State What it does IDLEBus idle. SDA released. Waits for START condition.GET_ADDR Shifts in 7-bit address + R/W bit on each SCL rise.SEND_ACK Asserts ACK on SDA (SCL fall 1), releases (fall 2). Forks to WRITE or READ.NACK Address mismatch. Releases SDA, waits for STOP.GET_WA Shifts in 8-bit register word address.SEND_WA_ACKACKs the word address. Arms register read pointer.RX_DATA Shifts in data byte on each SCL rise. Fires reg_wr_en pulse.SEND_DA_ACKACKs the data byte, loops back to RX_DATA (page write).TX_DATA Drives bits 6–0 on SDA, one per SCL fall (bit 7 is pre-driven).WAIT_ACK_PRE Holds bit 0 on SDA for its full clock cycle before releasing.WAIT_ACK Samples master ACK/NACK on SCL rise. Continues sequential read or exits.DONE Master sent NACK read done. Waits for STOP.
Global overrides (highest priority):

Any i2c_stop → unconditionally returns to IDLE
Any i2c_start → unconditionally goes to GET_ADDR (handles repeated START)


2. register_file.sv — Configuration Register Bank
Holds all 40+ chip configuration registers. The write port is clocked (driven by reg_wr_en from the I2C slave), and the read port is purely combinational this is intentional, so that when the I2C slave arms the read address, the data appears on the bus with zero latency.
Key registers include:

SEQ_PER (0x33) — measurement period in µs ticks
SEQ_LED_STA/STO (0x34/0x35) — LED on/off time-steps within a cycle
SEQ_ITG_STA/STO (0x38/0x39) — integrator enable/disable time-steps
SEQ_ADC (0x42) — ADC trigger time-step
INTENAB (0xA8), INTR (0xAA) — interrupt enable / clear
ID (0x92) — read-only chip ID = 0x21


3. sequencer.sv — Hardware Measurement Sequencer
The sequencer generates precise, repeating control pulses for the analog front end. It works by counting through a programmable period (0 → SEQ_PER − 1) using a 1 µs base tick (derived from a 50 MHz system clock), then comparing the counter against start/stop registers for each signal.
Each output (LED, secondary LED, TIA integrator, SDP1/2, SDM1/2, ADC trigger) is controlled by an independent SR flip-flop comparator: the output sets when counter == _STA and clears when counter == _STO.
Run/stop logic:

Starts on rising edge of SEQ_START bit (written by MCU)
Stops when MCU writes 0 to SEQ_START
Auto-stops after SEQ_CNT cycles (if non-zero)
SEQ_CNT = 0 → continuous mode (runs until manually stopped)

IRQ generation: In continuous mode, fires irq_seq_done every cycle. In fixed-count mode, fires only on the last cycle.

4. interrupt_ctrl.sv — Interrupt Controller
Implements sticky interrupt flags for four interrupt sources: sequencer done, FIFO overflow, FIFO threshold, and clip detect. Each flag latches when its source fires and only clears when the MCU writes a 1 to the corresponding bit of the INTR register.
The INT_n output is active-low open-drain: it asserts (goes LOW) when any enabled flag is set (INTENAB & irq_flags != 0), and releases when all active flags are cleared.

Bugs Found and Fixed
Debugging this design was a significant part of the work. Here is a summary of the real bugs discovered during simulation and how they were resolved.

Bug 1 — I2C read data corrupted (bits shifted and duplicated)
Symptom: Every register read returned the wrong value. Tracing the bit pattern revealed a consistent corruption:
Expected: 0x21 (CHIP_ID)   →  Got: 0x88
Expected: 0x89 (LED_CFG)   →  Got: 0xE2
Expected: 0x0A (SEQ_PER)   →  Got: 0x82
Expected: 0x02 (STATUS)    →  Got: 0x80
Root cause: Three separate timing problems in TX_DATA:

Bit 7 driven twice. At bitcnt=7, txreg was loaded from reg_rd_data and sda_oe was set to ~reg_rd_data[7]. At bitcnt=6, txreg[7] was still equal to reg_rd_data[7] (the shift hadn't happened yet in simulation time), so bit 7 was driven again for a second SCL clock cycle — consuming the slot meant for bit 6.
Master samples pullup before slave drives SDA. The transition from SEND_ACK to TX_DATA happened on the same SCL fall that the testbench used as the recv_byte() trigger. The master raised SCL for its first sample before TX_DATA had seen any SCL fall to drive SDA. SDA was floating (pulled HIGH), so the master recorded 1 as the MSB.
Bit 0 was never driven. At bitcnt=0, the original code released SDA and jumped straight to WAIT_ACK without ever asserting bit 0 on the bus.

Fix: Three coordinated changes:

On the second SCL fall of SEND_ACK (the READ fork), pre-drive bit 7 immediately: sda_oe <= ~reg_rd_data[7], load txreg <= {reg_rd_data[6:0], 1'b0} (pre-shifted), and set bitcnt <= 6. This means when the master raises SCL for the first time, bit 7 is already on the wire.
TX_DATA now starts at bitcnt=6, so it drives bit 6 → bit 1 correctly.
Added WAIT_ACK_PRE state: at bitcnt=0, drive bit 0 and go to WAIT_ACK_PRE. On the next SCL fall, release SDA for the master ACK. This guarantees bit 0 holds for its full clock.
The same pre-drive pattern is applied in WAIT_ACK for sequential reads.


Bug 2 — Sequencer never stopped in fixed-count mode
Symptom: With SEQ_CNT = 5, the sequencer ran indefinitely instead of stopping after 5 cycles.
Root cause: cycle_count was declared and reset to 0, but the increment line was missing. The counter stayed at 0 forever. The termination condition cycle_count >= seq_cnt - 1 was never satisfied.
Fix: Added cycle_count <= cycle_count + 1 inside the cycle_end handler. Also added running <= 0 and cycle_count <= 0 when the count is reached (auto-stop).

Bug 3 — TIA integrator de-asserted when sequencer was idle
Symptom: itg_en went LOW whenever the sequencer wasn't running. Per the AS7038RB datasheet, the integrator is default-ON (start=1 means "begin integration", stop=0 means "always integrating").
Root cause: The !running branch had itg_en <= 1'b0 — exactly backwards from the datasheet.
Fix: Changed to itg_en <= 1'b1 in the idle branch.

Bug 4 — ADC sample pulse only 20 ns wide
Symptom: adc_sample was asserted for exactly one 50 MHz clock cycle (20 ns) potentially too narrow for downstream ADC logic.
Root cause: An else adc_sample <= 0 cleared the signal on every non-seq_tick cycle. Since seq_tick fires once every 1 µs (1 out of 50 clocks), the pulse was 1 clock wide out of every 50.
Fix: Removed the else clause. adc_sample now holds HIGH from the trigger tick until the next seq_tick overrides it, giving a full 1 µs-wide pulse.

Bug 5 — INTR register auto-cleared before interrupt controller could see it
Symptom: Writing to the INTR register (0xAA) to clear an interrupt had no effect. The interrupt flag never cleared.
Root cause: The register file had else r_intr <= 8'h00 every clock cycle where wr_en=0, r_intr was wiped back to zero. The I2C write takes several clock cycles to propagate, so by the time the interrupt controller sampled r_intr on the next rising edge, it had already been zeroed.
Fix: Removed the else r_intr <= 0 branch entirely. The register now holds its written value until the MCU writes 0x00 to explicitly release it.

Bug 6 — Sequencer gated on osc_en / ldo_en
Symptom: Sequencer would not start unless the oscillator and LDO enable registers were set, even though those signals are purely analog.
Root cause: The digital RTL was gating seq_en on o_osc_en && o_ldo_en a structural dependency that doesn't belong in digital RTL.
Fix: Removed that gate. Whether the analog oscillator is actually running is the analog team's concern; the digital sequencer runs when seq_en and seq_start say so.

Reading the Simulation Waveforms
Waveform 1 Full system run (2.5 ms view)
After the I2C configuration phase (the initial burst of SCL/SDA activity in the first ~400 µs), the system enters steady-state operation:

<img width="1882" height="692" alt="Image" src="https://github.com/user-attachments/assets/73635c80-f7b3-4009-81af-ed0fe33cca69" />

seq_running_o stays HIGH — the sequencer is active
itg_en_o pulses at the programmed SEQ_ITG_STA/STO times within each period
led_drive_o and sdp1_o, sdm1_o, sdp2_o, sdm2_o fire in sync — LED on, drive currents on
adc_sample_o fires once per period at the programmed step
int_n_o pulses LOW periodically — the sequencer interrupt fires every cycle (continuous mode, SEQ_CNT = 0x00)
seq_status_o shows 0x02 (irq_sequencer bit set)
id_val reads back 0x21 (CHIP_ID) and rb_val reads back 0x0A (SEQ_PER) — confirming correct I2C reads

Waveform 2 I2C timing zoom (25 µs view)
The close-up shows the raw SCL/SDA bus during the initial configuration writes:

<img width="1555" height="280" alt="Image" src="https://github.com/user-attachments/assets/65b70c64-414b-436d-9a99-d2e4a006436a" />

scl_oe_tb and sda_oe_tb show the master driving the bus
Each 9-clock burst is one byte (8 data bits + ACK)
After each write, SDA returns to HIGH (released) ACK from the slave
The repeating pattern confirms the page-write loop works correctly (sequential address auto-increment)


File Structure
├── rtl/
│   ├── i2c_slave.sv          # I2C slave FSM (11 states)
│   ├── register_file.sv      # Configuration register bank
│   ├── sequencer.sv          # Hardware measurement sequencer
│   ├── interrupt_ctrl.sv     # Sticky interrupt controller
│   └── top_module.sv         # Integration top-level
├── docs/
│   ├── architecture.png      # System block diagram
│   ├── i2c_fsm.png           # I2C slave FSM diagram
│   └── waveform_*.png        # Simulation screenshots
└── README.md

Skills Demonstrated

1. RTL design from scratch in SystemVerilog — no IP cores, no reference code
2. FSM design and coding — 11-state Moore machine with clean priority encoding for async events
3. Protocol implementation — I2C (400 kHz), including repeated START, sequential reads/writes, open-drain bus
4. Systematic debugging — traced corrupt bit patterns back to exact clock-edge race conditions using waveform analysis
5. Clock domain awareness — 3-stage synchroniser for SCL/SDA, edge detection, glitch filtering
6. Datasheet-driven design — all register addresses, bit fields, and timing requirements derived from AS7038RB DS000726 v2
7. Simulation and verification — self-checking testbench with register read-back verification






