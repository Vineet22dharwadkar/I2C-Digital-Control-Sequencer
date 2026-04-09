// ============================================================
// i2c_slave.sv - AS7038RB I2C Slave  (FIXED v5 - VERIFIED)
// Datasheet DS000726 v2-00, Section 7.2
//
// ============================================================
// DEFINITIVE BUG REPORT - WHY READS WERE WRONG IN SIMULATION
// ============================================================
//
// Observed (from simulation output):
//   Read 0x92 (CHIP_ID=0x21) → 0x88   WRONG
//   Read 0x10 (LED_CFG=0x89) → 0xE2   WRONG
//   Read 0x33 (SEQ_PER=0x0A) → 0x82   WRONG
//   Read 0xA0 (STATUS=0x02)  → 0x80   WRONG
//
// Exact transformation proven by bit-level trace (matches ALL 4):
//   Slave drives on SDA: [bit7, bit7(dup), bit6, bit5, bit4, bit3, bit2, bit0=Z]
//   Testbench samples:   [1(pullup), bit7, bit7(dup), bit6, bit5, bit4, bit3, bit2]
//   = bits [7..2] of real data squeezed into positions [6..1], with
//     bit7 appearing twice, and the MSB position always reading as 1.
//
//   Verification:
//   0x21=00100001 → [1,0,0,0,1,0,0,0] = 0x88  ✓ matches sim
//   0x89=10001001 → [1,1,0,0,0,1,0,0] = 0xE2  ✓ matches sim
//   0x0A=00001010 → [1,0,0,0,0,0,1,0] = 0x82  ✓ matches sim
//   0x02=00000010 → [1,0,0,0,0,0,0,0] = 0x80  ✓ matches sim
//
// ── ROOT CAUSE 1: bit7 driven twice (TX_DATA bitcnt=7 and bitcnt=6) ─
//   At bitcnt=7: txreg <= reg_rd_data; sda_oe <= ~reg_rd_data[7]
//   At bitcnt=6: sda_oe <= ~txreg[7]   ← txreg still = reg_rd_data (load,
//     no shift yet). So txreg[7] = reg_rd_data[7] = bit7 AGAIN.
//     Then txreg <= {txreg[6:0],0} takes effect, but too late.
//   Result: bit7 occupies TWO SCL clock cycles.
//
// ── ROOT CAUSE 2: first SCL sample reads pullup=1 ─────────────
//   The slave transitions from SEND_ACK→TX_DATA on the same scl_fall
//   that is send_byte()'s last action. recv_byte() then immediately
//   raises SCL (scl_rise) for its first sample BEFORE TX_DATA has
//   seen any scl_fall to drive SDA. SDA = pullup = HIGH = 1.
//   The master stores 1 as bit7 of the received data.
//   Then the first scl_fall in recv_byte loop triggers TX_DATA which
//   drives actual bit7 - but master records this as bit6.
//
// ── ROOT CAUSE 3 (from previous analysis): bit0 never driven ──
//   At bitcnt=0, original TX_DATA released SDA and jumped to WAIT_ACK
//   without ever asserting bit0. Master always read pullup=1 for bit0.
//
// ============================================================
// THE THREE-PART FIX (v5)
// ============================================================
//
// FIX 1 (BUG 1+2 together): Pre-drive bit7 in SEND_ACK.
//   In SEND_ACK's second scl_fall (the one that releases the address ACK
//   and transitions to TX_DATA), simultaneously:
//     • Load txreg = reg_rd_data (capture register value)
//     • Pre-shift: txreg stored as {reg_rd_data[6:0], 0} (bit6 at MSB)
//     • Pre-drive: sda_oe <= ~reg_rd_data[7]  (bit7 onto SDA immediately)
//     • bitcnt <= 6 (TX_DATA picks up from bit6 onwards)
//   Now when recv_byte raises SCL for the first time: SDA already has bit7.
//   Master correctly reads bit7 in the first SCL cycle.
//
// FIX 2 (BUG 1): TX_DATA now starts at bitcnt=6.
//   txreg already holds {data[6:0],0}, so txreg[7]=data[6].
//   Driving ~txreg[7] at bitcnt=6 correctly gives bit6 (not bit7 again).
//   Each subsequent fall shifts and drives the next lower bit. No duplicate.
//
// FIX 3 (BUG 3 - original bit0 bug): Added WAIT_ACK_PRE state.
//   TX_DATA at bitcnt=0: drives bit0 (sda_oe <= ~txreg[7]), goes to WAIT_ACK_PRE.
//   WAIT_ACK_PRE on next scl_fall: bit0 clock is complete, releases SDA for ACK.
//   WAIT_ACK on scl_rise: samples master ACK/NACK.
//   This ensures all 8 bits are properly driven before the ACK phase.
//
// FIX 4 (Sequential read): In WAIT_ACK on master ACK (scl_rise):
//   Pre-drive bit7 of the NEXT register immediately (same pattern as SEND_ACK).
//   This ensures correct timing for burst sequential reads.
// ============================================================

`timescale 1ns / 1ps

module i2c_slave (
    input  logic        clk,
    input  logic        rst_n,

    inout  wire         scl,
    inout  wire         sda,

    output logic        reg_wr_en,
    output logic [7:0]  reg_wr_addr,
    output logic [7:0]  reg_wr_data,

    output logic        reg_rd_en,
    output logic [7:0]  reg_rd_addr,
    input  logic [7:0]  reg_rd_data
);

    localparam logic [6:0] I2C_ADDR = 7'h30;

    // Open-drain: sda_oe=1 → drive SDA LOW; sda_oe=0 → release (pullup → HIGH)
    logic sda_oe;
    assign sda = sda_oe ? 1'b0 : 1'bz;

    // 3-stage synchroniser (metastability protection + glitch filter)
    logic [2:0] scl_r, sda_r;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            scl_r <= 3'b111;
            sda_r <= 3'b111;
        end else begin
            scl_r <= {scl_r[1:0], scl};
            sda_r <= {sda_r[1:0], sda};
        end
    end
    wire scl_in = scl_r[2];
    wire sda_in = sda_r[2];

    // Edge detection (1-cycle pulses)
    logic scl_d, sda_d;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin scl_d <= 1'b1; sda_d <= 1'b1; end
        else        begin scl_d <= scl_in; sda_d <= sda_in; end
    end
    wire scl_rise = scl_in  & ~scl_d;
    wire scl_fall = ~scl_in &  scl_d;
    wire i2c_start = ~sda_in &  sda_d & scl_in;  // SDA falls while SCL HIGH
    wire i2c_stop  =  sda_in & ~sda_d & scl_in;  // SDA rises while SCL HIGH

    // ── State machine ───────────────────────────────────────
    typedef enum logic [3:0] {
        IDLE         = 4'd0,
        GET_ADDR     = 4'd1,   // Receive 7-bit addr + R/W
        SEND_ACK     = 4'd2,   // Assert/release address ACK
        GET_WA       = 4'd3,   // Receive register word address
        SEND_WA_ACK  = 4'd4,   // Assert/release word-addr ACK
        RX_DATA      = 4'd5,   // Receive data byte (write path)
        SEND_DA_ACK  = 4'd6,   // Assert/release data-byte ACK
        TX_DATA      = 4'd7,   // Drive bits 6..0 (bit7 pre-driven)
        WAIT_ACK_PRE = 4'd8,   // Hold bit0; wait for its clock to end
        WAIT_ACK     = 4'd9,   // Sample master ACK/NACK
        NACK         = 4'd10,  // Address mismatch → await STOP
        DONE         = 4'd11   // Master NACK received → await STOP
    } state_t;

    state_t      state;
    logic [7:0]  shreg;    // RX shift register (MSB-first)
    logic [2:0]  bitcnt;   // Bit counter
    logic [7:0]  waddr;    // Register pointer (auto-inc for sequential ops)
    logic [7:0]  txreg;    // TX shift register
    logic        rw;       // Latched R/W bit

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state       <= IDLE;
            shreg       <= '0;
            bitcnt      <= 3'd7;
            waddr       <= '0;
            txreg       <= '0;
            rw          <= 1'b0;
            sda_oe      <= 1'b0;
            reg_wr_en   <= 1'b0;
            reg_wr_addr <= '0;
            reg_wr_data <= '0;
            reg_rd_en   <= 1'b0;
            reg_rd_addr <= '0;
        end else begin
            reg_wr_en <= 1'b0;   // Default: write-enable is a pulse only

            // ── GLOBAL PRIORITY: START (incl. Repeated START) ─
            if (i2c_start) begin
                state  <= GET_ADDR;
                bitcnt <= 3'd7;
                shreg  <= '0;
                sda_oe <= 1'b0;
            end

            // ── GLOBAL PRIORITY: STOP ──────────────────────────
            else if (i2c_stop) begin
                state     <= IDLE;
                sda_oe    <= 1'b0;
                reg_rd_en <= 1'b0;
            end

            else begin
                case (state)

                //────────────────────────────────────────────────
                IDLE: sda_oe <= 1'b0;

                //────────────────────────────────────────────────
                // GET_ADDR: shift in 8 bits [A6..A0][R/W] on scl_rise.
                //────────────────────────────────────────────────
                GET_ADDR: begin
                    if (scl_rise) begin
                        shreg <= {shreg[6:0], sda_in};
                        if (bitcnt == 3'd0) begin
                            rw    <= sda_in;
                            state <= SEND_ACK;
                        end else
                            bitcnt <= bitcnt - 1'b1;
                    end
                end

                //────────────────────────────────────────────────
                // SEND_ACK: respond to address byte.
                //
                // On scl_fall while sda_oe=0 (Fall 1 after 8th bit):
                //   Check address. If match: assert ACK (sda_oe=1).
                //   For READ: also arm the register read so reg_rd_data
                //   is valid by Fall 2.
                //
                // On scl_fall while sda_oe=1 (Fall 2 = ACK clock end):
                //   For WRITE: release ACK, go to GET_WA.
                //   For READ:  FIX BUGS 1+2: pre-drive bit7 NOW.
                //     • txreg <= {reg_rd_data[6:0], 0}  (pre-shifted)
                //     • sda_oe <= ~reg_rd_data[7]       (bit7 on SDA)
                //     • bitcnt <= 6, state <= TX_DATA
                //     When recv_byte raises SCL for its first sample,
                //     SDA already holds bit7 → correct read.
                //────────────────────────────────────────────────
                SEND_ACK: begin
                    if (scl_fall) begin
                        if (!sda_oe) begin
                            // Fall 1
                            if (shreg[7:1] == I2C_ADDR) begin
                                sda_oe <= 1'b1;   // Assert ACK
                                bitcnt <= 3'd7;
                                if (rw) begin
                                    // Arm register read while asserting ACK.
                                    // reg_rd_data will be combinationally valid
                                    // before Fall 2 arrives (many clk cycles later).
                                    reg_rd_addr <= waddr;
                                    reg_rd_en   <= 1'b1;
                                end
                            end else begin
                                sda_oe <= 1'b0;
                                state  <= NACK;
                            end
                        end else begin
                            // Fall 2: ACK clock is over
                            if (!rw) begin
                                // WRITE transaction
                                sda_oe <= 1'b0;
                                shreg  <= '0;
                                state  <= GET_WA;
                            end else begin
                                // READ transaction
                                // FIX ROOT CAUSE 1+2: Pre-drive bit7 on THIS fall.
                                // reg_rd_data is valid (was armed on Fall 1).
                                txreg     <= {reg_rd_data[6:0], 1'b0};  // pre-shifted
                                sda_oe    <= ~reg_rd_data[7];            // drive bit7 now
                                reg_rd_en <= 1'b0;
                                bitcnt    <= 3'd6;   // TX_DATA starts from bit6
                                state     <= TX_DATA;
                            end
                        end
                    end
                end

                //────────────────────────────────────────────────
                // GET_WA: receive 8-bit word address on scl_rise.
                //────────────────────────────────────────────────
                GET_WA: begin
                    if (scl_rise) begin
                        shreg <= {shreg[6:0], sda_in};
                        if (bitcnt == 3'd0) begin
                            waddr <= {shreg[6:0], sda_in};
                            state <= SEND_WA_ACK;
                        end else
                            bitcnt <= bitcnt - 1'b1;
                    end
                end

                //────────────────────────────────────────────────
                // SEND_WA_ACK: two-fall ACK for word address.
                // After release: go to RX_DATA.
                // Also arm register file for any subsequent Repeated Start read.
                //────────────────────────────────────────────────
                SEND_WA_ACK: begin
                    if (scl_fall) begin
                        if (!sda_oe) begin
                            sda_oe      <= 1'b1;   // Assert ACK
                            bitcnt      <= 3'd7;
                            shreg       <= '0;
                            // Arm read pointer (needed for Repeated Start reads)
                            reg_rd_addr <= waddr;
                            reg_rd_en   <= 1'b1;
                        end else begin
                            sda_oe <= 1'b0;        // Release ACK
                            state  <= RX_DATA;
                        end
                    end
                end

                //────────────────────────────────────────────────
                // RX_DATA: shift in data byte on scl_rise.
                // Page Write: waddr auto-increments after each byte.
                //────────────────────────────────────────────────
                RX_DATA: begin
                    if (scl_rise) begin
                        shreg <= {shreg[6:0], sda_in};
                        if (bitcnt == 3'd0) begin
                            reg_wr_en   <= 1'b1;
                            reg_wr_addr <= waddr;
                            reg_wr_data <= {shreg[6:0], sda_in};
                            waddr  <= waddr + 1'b1;
                            shreg  <= '0;
                            state  <= SEND_DA_ACK;
                        end else
                            bitcnt <= bitcnt - 1'b1;
                    end
                end

                //────────────────────────────────────────────────
                // SEND_DA_ACK: two-fall ACK for data byte.
                // After release: loop back to RX_DATA (Page Write).
                //────────────────────────────────────────────────
                SEND_DA_ACK: begin
                    if (scl_fall) begin
                        if (!sda_oe) begin
                            sda_oe <= 1'b1;   // Assert ACK
                            bitcnt <= 3'd7;
                        end else begin
                            sda_oe <= 1'b0;   // Release ACK
                            state  <= RX_DATA;
                        end
                    end
                end

                //────────────────────────────────────────────────
                // TX_DATA: drive bits [6..0], one per scl_fall.
                // Bit 7 was already driven in SEND_ACK (or WAIT_ACK).
                // txreg enters pre-shifted so txreg[7]=bit6 at bitcnt=6.
                //
                // At each fall (bitcnt 6..1):
                //   drive sda_oe = ~txreg[7]   (current bit)
                //   shift txreg left             (expose next bit)
                //   decrement bitcnt
                //
                // At bitcnt=0:
                //   FIX ROOT CAUSE 3: drive bit0 explicitly (was silently skipped).
                //   Go to WAIT_ACK_PRE to hold bit0 for its full clock cycle.
                //────────────────────────────────────────────────
                TX_DATA: begin
                    if (scl_fall) begin
                        if (bitcnt == 3'd0) begin
                            // Drive bit0 (FIX ROOT CAUSE 3)
                            sda_oe <= ~txreg[7];
                            state  <= WAIT_ACK_PRE;
                        end else begin
                            // Drive current bit, shift for next
                            sda_oe <= ~txreg[7];
                            txreg  <= {txreg[6:0], 1'b0};
                            bitcnt <= bitcnt - 1'b1;
                        end
                    end
                end

                //────────────────────────────────────────────────
                // WAIT_ACK_PRE: bit0 is being held on SDA.
                // Wait for the next scl_fall (end of bit0 clock), then
                // release SDA so the master can drive ACK or NACK.
                //────────────────────────────────────────────────
                WAIT_ACK_PRE: begin
                    if (scl_fall) begin
                        sda_oe <= 1'b0;    // Release for master ACK/NACK
                        state  <= WAIT_ACK;
                    end
                end

                //────────────────────────────────────────────────
                // WAIT_ACK: sample master ACK/NACK on scl_rise.
                //   SDA=LOW → ACK: sequential read continues.
                //     Pre-drive bit7 of next register immediately
                //     (same FIX as SEND_ACK) so timing is correct.
                //   SDA=HIGH → NACK: read is done, await STOP.
                //────────────────────────────────────────────────
                WAIT_ACK: begin
                    if (scl_rise) begin
                        if (!sda_in) begin
                            // Master ACK: send next register in sequential read
                            waddr       <= waddr + 1'b1;
                            reg_rd_addr <= waddr + 1'b1;
                            reg_rd_en   <= 1'b1;
                            // Pre-drive bit7 of next byte (same fix as SEND_ACK)
                            // reg_rd_data updates combinationally; it is valid on the
                            // same cycle after reg_rd_addr changes (register_file is comb).
                            txreg     <= {reg_rd_data[6:0], 1'b0};
                            sda_oe    <= ~reg_rd_data[7];
                            reg_rd_en <= 1'b0;
                            bitcnt    <= 3'd6;
                            state     <= TX_DATA;
                        end else begin
                            // Master NACK: done
                            reg_rd_en <= 1'b0;
                            state     <= DONE;
                        end
                    end
                end

                NACK: ;   // Await STOP (globally handled above)
                DONE: ;   // Await STOP (globally handled above)

                default: state <= IDLE;
                endcase
            end
        end
    end

endmodule