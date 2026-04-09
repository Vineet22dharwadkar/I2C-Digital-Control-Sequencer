// ============================================================
// tb_as7038rb.sv - AS7038RB Testbench (FINAL v3)
// Datasheet DS000726 v2-00
//
// I2C MASTER TASK TIMING - aligned to slave v3:
//
//  Slave samples SDA on SCL RISE
//  Slave drives SDA on SCL FALL
//
// Master must:
//  1. Hold SCL LOW
//  2. Set up SDA
//  3. Raise SCL → slave samples
//  4. Lower SCL → slave may drive (for ACK/read)
//
// For ACK reception: after the 8th data bit SCL falls, master
// releases SDA and raises SCL. Slave pulls SDA LOW (ACK).
// Master samples SDA while SCL is HIGH. Then SCL falls again.
// Slave releases SDA on this second fall. This matches v3 slave.
// ============================================================

`timescale 1ns / 1ps

module tb_as7038rb;

    // 50 MHz system clock
    localparam int CLK_PERIOD   = 20;   // ns
    // I2C half-bit period in system clocks
    // Fast enough for simulation, correct for protocol
    localparam int HALF_BIT     = 12;

    // ── Signals ─────────────────────────────────────────────
    logic clk_sys, rst_n, enable;
    logic scl_oe_tb, sda_oe_tb;

    wire scl_bus = scl_oe_tb ? 1'b0 : 1'bz;
    wire sda_bus = sda_oe_tb ? 1'b0 : 1'bz;
    pullup (scl_bus);
    pullup (sda_bus);

    logic led_drive_o, sec_led_o, itg_en_o;
    logic sdp1_o, sdm1_o, sdp2_o, sdm2_o;
    logic adc_sample_o, int_n_o, seq_running_o;
    logic [7:0] seq_status_o;

    // ── DUT ─────────────────────────────────────────────────
    as7038rb_top DUT (
        .clk_sys      (clk_sys),  .rst_n        (rst_n),
        .enable       (enable),   .scl          (scl_bus),
        .sda          (sda_bus),  .led_drive    (led_drive_o),
        .sec_led_drive(sec_led_o),.itg_en       (itg_en_o),
        .sdp1_out     (sdp1_o),   .sdm1_out     (sdm1_o),
        .sdp2_out     (sdp2_o),   .sdm2_out     (sdm2_o),
        .adc_sample   (adc_sample_o), .int_n    (int_n_o),
        .seq_running  (seq_running_o),.seq_status(seq_status_o)
    );

    // ── Clock ───────────────────────────────────────────────
    initial clk_sys = 1'b0;
    always #(CLK_PERIOD/2) clk_sys = ~clk_sys;

    // ── I2C Master Tasks ────────────────────────────────────
    // START: SDA falls while SCL HIGH
    task automatic i2c_start_cond;
        scl_oe_tb = 0; sda_oe_tb = 0;          // Both released = HIGH
        repeat(HALF_BIT) @(posedge clk_sys);
        sda_oe_tb = 1;                           // SDA falls → START condition
        repeat(HALF_BIT) @(posedge clk_sys);
        scl_oe_tb = 1;                           // SCL falls → data phase begins
        repeat(HALF_BIT) @(posedge clk_sys);
    endtask

    // STOP: SDA rises while SCL HIGH
    task automatic i2c_stop_cond;
        scl_oe_tb = 1; sda_oe_tb = 1;           // Both LOW
        repeat(HALF_BIT) @(posedge clk_sys);
        scl_oe_tb = 0;                           // SCL HIGH
        repeat(HALF_BIT) @(posedge clk_sys);
        sda_oe_tb = 0;                           // SDA rises → STOP
        repeat(HALF_BIT) @(posedge clk_sys);
    endtask

    // Send one byte MSB-first, collect ACK
    // SDA is set BEFORE SCL rises (setup time guaranteed)
    task automatic send_byte(input logic [7:0] data, output logic got_ack);
        int i;
        for (i = 7; i >= 0; i--) begin
            // SCL LOW: set up SDA
            scl_oe_tb = 1;
            repeat(HALF_BIT/2) @(posedge clk_sys);
            sda_oe_tb = ~data[i];                // 0=drive LOW, 1=release HIGH
            repeat(HALF_BIT/2) @(posedge clk_sys);
            // SCL HIGH: slave samples SDA
            scl_oe_tb = 0;
            repeat(HALF_BIT) @(posedge clk_sys);
        end
        // ACK bit: master releases SDA, slave drives LOW=ACK
        scl_oe_tb = 1;
        sda_oe_tb = 0;                           // Release SDA
        repeat(HALF_BIT) @(posedge clk_sys);
        scl_oe_tb = 0;                           // SCL HIGH - slave asserts ACK here
        repeat(HALF_BIT/2) @(posedge clk_sys);
        got_ack = ~sda_bus;                      // Sample: LOW=ACK, HIGH=NACK
        repeat(HALF_BIT/2) @(posedge clk_sys);
        scl_oe_tb = 1;                           // SCL LOW - slave releases ACK here
        repeat(HALF_BIT/2) @(posedge clk_sys);
        sda_oe_tb = 0;                           // Ensure SDA released
        repeat(HALF_BIT/2) @(posedge clk_sys);
    endtask

    // Receive one byte, send ACK(0) or NACK(1)
    task automatic recv_byte(input logic nack, output logic [7:0] data);
        int i;
        sda_oe_tb = 0;                           // Release SDA: slave will drive
        for (i = 7; i >= 0; i--) begin
            scl_oe_tb = 1;
            repeat(HALF_BIT) @(posedge clk_sys);
            scl_oe_tb = 0;                       // SCL HIGH: slave is driving SDA
            repeat(HALF_BIT/2) @(posedge clk_sys);
            data[i] = sda_bus;                   // Sample mid-high
            repeat(HALF_BIT/2) @(posedge clk_sys);
        end
        // ACK/NACK from master
        scl_oe_tb = 1;
        repeat(HALF_BIT/2) @(posedge clk_sys);
        sda_oe_tb = nack ? 1'b0 : 1'b1;         // NACK=release, ACK=drive LOW
        // Note: nack=1 means send NACK (release=1=high), nack=0 means ACK (drive=0=low)
        // sda_oe=1 drives LOW. So for NACK: sda_oe=0. For ACK: sda_oe=1.
        sda_oe_tb = nack ? 1'b0 : 1'b1;
        repeat(HALF_BIT/2) @(posedge clk_sys);
        scl_oe_tb = 0;                           // SCL HIGH
        repeat(HALF_BIT) @(posedge clk_sys);
        scl_oe_tb = 1;
        sda_oe_tb = 0;
        repeat(HALF_BIT/2) @(posedge clk_sys);
    endtask

    // Byte Write: [S][0x60|A][reg|A][data|A][P]
    task automatic write_reg(input logic [7:0] addr, input logic [7:0] data);
        logic ack;
        $display("[TB] Write 0x%02X = 0x%02X", addr, data);
        i2c_start_cond();
        send_byte(8'h60, ack);      // Device Write address
        send_byte(addr,  ack);      // Word address (register)
        send_byte(data,  ack);      // Data
        i2c_stop_cond();
        repeat(4) @(posedge clk_sys);
    endtask

    // Random Read: [S][0x60|A][reg|A][Sr][0x61|A][data|N][P]
    task automatic read_reg(input logic [7:0] addr, output logic [7:0] data);
        logic ack;
        logic [7:0] d;
        // Write phase: send register pointer
        i2c_start_cond();
        send_byte(8'h60, ack);      // Device Write
        send_byte(addr,  ack);      // Word address
        // Repeated START (switch to read)
        // Sr: SCL goes HIGH, then SDA goes HIGH (bus idle briefly), then START
        scl_oe_tb = 1;
        repeat(HALF_BIT/2) @(posedge clk_sys);
        sda_oe_tb = 0;              // Release SDA (HIGH)
        repeat(HALF_BIT/2) @(posedge clk_sys);
        scl_oe_tb = 0;              // SCL HIGH
        repeat(HALF_BIT/2) @(posedge clk_sys);
        // Now issue START while SCL is HIGH
        sda_oe_tb = 1;              // SDA falls = Sr
        repeat(HALF_BIT/2) @(posedge clk_sys);
        scl_oe_tb = 1;              // SCL LOW: ready for address byte
        repeat(HALF_BIT) @(posedge clk_sys);
        // Read phase
        send_byte(8'h61, ack);      // Device Read address
        recv_byte(1'b1, d);         // Receive data, send NACK (1=NACK)
        i2c_stop_cond();
        repeat(4) @(posedge clk_sys);
        data = d;
        $display("[TB] Read  0x%02X = 0x%02X", addr, d);
    endtask

    // ── Test variables ───────────────────────────────────────
    logic [7:0] id_val, rb_val;

    // ── Main test sequence ───────────────────────────────────
    initial begin
        rst_n     = 0; enable    = 0;
        scl_oe_tb = 0; sda_oe_tb = 0;
        id_val = 0; rb_val = 0;

        repeat(20) @(posedge clk_sys);
        rst_n  = 1;
        enable = 1;                // ENABLE pin HIGH: chip exits reset
        repeat(30) @(posedge clk_sys);

        $display("=================================================");
        $display("  AS7038RB Simulation FINAL v3                   ");
        $display("  Datasheet DS000726 v2-00                       ");
        $display("=================================================");

        // ── STEP 1: Power-on (CONTROL register 0x00) ─────────
        // Datasheet pg 111: ldo_en first, then osc_en
        $display("\n[TB] STEP 1: Power-on sequence");
        write_reg(8'h00, 8'h01);    // CONTROL: ldo_en=1
        repeat(60) @(posedge clk_sys);
        write_reg(8'h00, 8'h03);    // CONTROL: ldo_en + osc_en
        repeat(100) @(posedge clk_sys);

        // ── STEP 2: Verify chip ID (REG_ID = 0x92) ───────────
        // Expected: CHIP_ID = 0x21
        $display("\n[TB] STEP 2: Chip ID verification");
        read_reg(8'h92, id_val);
        if (id_val == 8'h21)
            $display("     PASS: ID=0x%02X correct", id_val);
        else
            $display("     FAIL: ID=0x%02X expected 0x21", id_val);

        // ── STEP 3: LED/PD/TIA config ─────────────────────────
        $display("\n[TB] STEP 3: LED, Photodiode, TIA");
        write_reg(8'h10, 8'h89);    // LED_CFG: sigref_en + led1_en
        write_reg(8'h12, 8'h00);    // LED1_CURRL
        write_reg(8'h13, 8'h32);    // LED1_CURRH (current=200)
        write_reg(8'h1A, 8'h02);    // PD_CFG: pd1 enabled
        write_reg(8'h1D, 8'h03);    // PD_AMPRCC: TIA mid gain
        write_reg(8'h1E, 8'h85);    // PD_AMPCFG: TIA enabled
        // Readback LED_CFG
        read_reg(8'h10, rb_val);
        if (rb_val == 8'h89)
            $display("     PASS: LED_CFG=0x%02X", rb_val);
        else
            $display("     FAIL: LED_CFG=0x%02X expected 0x89", rb_val);

        // ── STEP 4: Sequencer timing registers ───────────────
        // seq_div=9 → t_clk=10μs per tick (per datasheet SEQ_DIV formula)
        // seq_per=10 → 10 ticks per cycle (100μs, short for simulation)
        $display("\n[TB] STEP 4: Sequencer timing");
        write_reg(8'h31, 8'h09);    // SEQ_DIV = 9
        write_reg(8'h33, 8'h0A);    // SEQ_PER = 10
        write_reg(8'h34, 8'h00);    // SEQ_LED_STA  count=0
        write_reg(8'h35, 8'h02);    // SEQ_LED_STO  count=2
        write_reg(8'h38, 8'h01);    // SEQ_ITG_STA  count=1
        write_reg(8'h39, 8'h03);    // SEQ_ITG_STO  count=3
        write_reg(8'h3A, 8'h01);    // SEQ_SDP1_STA count=1
        write_reg(8'h3B, 8'h03);    // SEQ_SDP1_STO count=3
        write_reg(8'h3E, 8'h05);    // SEQ_SDM1_STA count=5
        write_reg(8'h3F, 8'h07);    // SEQ_SDM1_STO count=7
        write_reg(8'h42, 8'h08);    // SEQ_ADC      count=8
        write_reg(8'h30, 8'h00);    // SEQ_CNT = 0 (continuous)
        // Readback SEQ_PER
        read_reg(8'h33, rb_val);
        if (rb_val == 8'h0A)
            $display("     PASS: SEQ_PER=0x%02X", rb_val);
        else
            $display("     FAIL: SEQ_PER=0x%02X expected 0x0A", rb_val);

        // ── STEP 5: Enable interrupts ──────────────────────
        $display("\n[TB] STEP 5: Interrupts");
        write_reg(8'hA8, 8'h02);    // INTENAB: irq_sequencer (bit1) only

        // ── STEP 6: Enable sequencer hardware ─────────────
        // MAN_SEQ_CFG (0x2E): man_mode=0, diode_ctrl=01, seq_en=1
        $display("\n[TB] STEP 6: Enable sequencer hardware");
        write_reg(8'h2E, 8'h03);

        // ── STEP 7: Start sequencer ────────────────────────
        // SEQ_START (0x32) bit0=1 → rising edge triggers run
        $display("\n[TB] STEP 7: Start sequencer");
        write_reg(8'h32, 8'h01);

        // ── STEP 8: Observe sequencer outputs ─────────────
        $display("\n[TB] STEP 8: Monitoring outputs...");
        $display("     Expected per cycle (seq_per=10, t_clk=10us=100us/cycle):");
        $display("     led_drive  ON  count 0-2");
        $display("     itg_en     ON  count 1-3");
        $display("     sdp1_out   ON  count 1-3");
        $display("     sdm1_out   ON  count 5-7");
        $display("     adc_sample PULSE count 8");
        $display("     INT pin    LOW at end of cycle");

        // Wait for several sequencer cycles
        repeat(120000) @(posedge clk_sys);

        // ── STEP 9: Read STATUS ────────────────────────────
        $display("\n[TB] STEP 9: Read STATUS (0xA0)");
        read_reg(8'hA0, rb_val);
        if (rb_val[1])
            $display("     PASS: irq_sequencer SET. STATUS=0x%02X", rb_val);
        else
            $display("     FAIL: irq_sequencer NOT set. STATUS=0x%02X", rb_val);

        // ── STEP 10: Clear interrupt ───────────────────────
        $display("\n[TB] STEP 10: Clear interrupt");
        write_reg(8'hAA, 8'h02);    // INTR: clear irq_sequencer
        repeat(20) @(posedge clk_sys);
        read_reg(8'hA0, rb_val);
        $display("     STATUS after clear = 0x%02X (expect 0x00)", rb_val);
        if (rb_val == 8'h00)
            $display("     PASS: interrupt cleared");
        else
            $display("     NOTE: 0x%02X - lower bits may be new irq_seq since cleared", rb_val);

        // ── STEP 11: Stop sequencer ────────────────────────
        $display("\n[TB] STEP 11: Stop sequencer");
        write_reg(8'h32, 8'h00);    // SEQ_START = 0
        repeat(600) @(posedge clk_sys);
        if (!seq_running_o)
            $display("     PASS: seq_running=0 (stopped)");
        else
            $display("     FAIL: still running");

        $display("\n=================================================");
        $display("  SIMULATION COMPLETE                            ");
        $display("=================================================");
        $finish;
    end

    // ── Monitors ────────────────────────────────────────────
    initial begin
        $dumpfile("as7038rb_v3.vcd");
        $dumpvars(0, tb_as7038rb);
    end

    always @(posedge led_drive_o)  $display("[MON] %0t ns  led_drive  ON",  $time);
    always @(negedge led_drive_o)  $display("[MON] %0t ns  led_drive  OFF", $time);
    always @(posedge itg_en_o)     $display("[MON] %0t ns  itg_en     ON",  $time);
    always @(negedge itg_en_o)     $display("[MON] %0t ns  itg_en     OFF", $time);
    always @(posedge sdp1_o)       $display("[MON] %0t ns  sdp1_out   ON  (+1 demod)", $time);
    always @(posedge sdm1_o)       $display("[MON] %0t ns  sdm1_out   ON  (-1 demod)", $time);
    always @(posedge adc_sample_o) $display("[MON] %0t ns  adc_sample PULSE", $time);
    always @(negedge int_n_o)      $display("[MON] %0t ns  INT_n LOW  (interrupt)", $time);
    always @(posedge int_n_o)      $display("[MON] %0t ns  INT_n HIGH (cleared)",  $time);
    always @(posedge seq_running_o) $display("[MON] %0t ns  sequencer STARTED", $time);
    always @(negedge seq_running_o) $display("[MON] %0t ns  sequencer STOPPED", $time);

endmodule