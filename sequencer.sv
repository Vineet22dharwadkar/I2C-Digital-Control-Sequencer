// ============================================================
// sequencer.sv - AS7038RB Digital Control Sequencer (FIXED v2)
// Datasheet Section 7.1.9, Figure 41
//
// BUGS FIXED vs original:
//
// BUG 1 [CRITICAL]: cycle_count was NEVER incremented.
//   Declaration: logic [7:0] cycle_count; ← declared
//   Reset:       cycle_count <= '0;       ← reset
//   Increment:   MISSING!
//   Effect: cycle_count stays 0 forever. When seq_cnt != 0,
//   the condition (cycle_count >= seq_cnt - 1) is TRUE on the
//   VERY FIRST cycle_end because 0 >= (seq_cnt-1) is false
//   for seq_cnt>1, but since cycle_count never grows, the
//   sequencer NEVER stops in fixed-count mode.
//   FIX: Added cycle_count <= cycle_count + 1 inside cycle_end block.
//
// BUG 2 [HIGH]: running never auto-clears after seq_cnt cycles.
//   After irq_done_pulse fires in fixed-count mode, the sequencer
//   kept running indefinitely. Hardware should auto-stop.
//   FIX: Added 'running <= 0' when cycle_count reaches seq_cnt.
//        Also reset cycle_count to 0 on stop.
//
// BUG 3 [MEDIUM]: itg_en forced LOW when sequencer stops.
//   The original had: else if (!running) begin itg_en <= 1'b0; end
//   Datasheet says integrator is ON by default (start=1, stop=0 → always ON).
//   When sequencer is idle, itg_en should remain HIGH (default-ON).
//   FIX: Changed !running branch to itg_en <= 1'b1.
//
// BUG 4 [MINOR]: adc_sample pulse only 1 clk_sys wide (20ns at 50MHz).
//   The 'else adc_sample <= 0' cleared the signal every non-seq_tick clock.
//   With CLK_PER_US=50, seq_tick is 1 out of 50 clocks, so adc_sample
//   was only asserted for 20ns - potentially too narrow for downstream ADC.
//   FIX: adc_sample now holds HIGH from the trigger tick until next seq_tick.
//        This gives a full t_clk-wide pulse, reliably detectable.
// ============================================================

`timescale 1ns / 1ps

module sequencer (
    input  logic        clk_sys,
    input  logic        rst_n,

    input  logic        seq_en,
    input  logic        man_mode,

    input  logic        seq_start,
    input  logic [7:0]  seq_cnt,
    input  logic [7:0]  seq_div,
    input  logic [7:0]  seq_per,
    input  logic [7:0]  seq_led_sta,
    input  logic [7:0]  seq_led_sto,
    input  logic [7:0]  seq_secled_sta,
    input  logic [7:0]  seq_secled_sto,
    input  logic [7:0]  seq_itg_sta,
    input  logic [7:0]  seq_itg_sto,
    input  logic [7:0]  seq_sdp1_sta,
    input  logic [7:0]  seq_sdp1_sto,
    input  logic [7:0]  seq_sdp2_sta,
    input  logic [7:0]  seq_sdp2_sto,
    input  logic [7:0]  seq_sdm1_sta,
    input  logic [7:0]  seq_sdm1_sto,
    input  logic [7:0]  seq_sdm2_sta,
    input  logic [7:0]  seq_sdm2_sto,
    input  logic [7:0]  seq_adc,

    output logic        led_drive,
    output logic        sec_led_drive,
    output logic        itg_en,
    output logic        sdp1_out,
    output logic        sdm1_out,
    output logic        sdp2_out,
    output logic        sdm2_out,
    output logic        adc_sample,

    output logic        seq_running,
    output logic        irq_seq_done
);

    localparam int CLK_PER_US = 50;

    // ── Step 1: 1μs base tick ──────────────────────────────
    logic [5:0] us_prescale;
    logic       us_tick;
    logic [7:0] counter;
    logic       cycle_end;
    always_ff @(posedge clk_sys or negedge rst_n) begin
        if (!rst_n) begin
            us_prescale <= '0;
            us_tick     <= 1'b0;
        end else begin
            us_tick <= 1'b0;
            if (us_prescale == CLK_PER_US - 1) begin
                us_prescale <= '0;
                us_tick     <= 1'b1;
            end else begin
                us_prescale <= us_prescale + 1'b1;
            end
        end
    end

    // ── Step 2: seq_div clock divider ─────────────────────
    logic [7:0] div_cnt;
    logic       seq_tick;

    always_ff @(posedge clk_sys or negedge rst_n) begin
        if (!rst_n) begin
            div_cnt  <= '0;
            seq_tick <= 1'b0;
        end else begin
            seq_tick <= 1'b0;
            if (us_tick) begin
                if (div_cnt >= seq_div) begin
                    div_cnt  <= '0;
                    seq_tick <= 1'b1;
                end else begin
                    div_cnt <= div_cnt + 1'b1;
                end
            end
        end
    end

    // ── Step 3: seq_start rising edge detection ────────────
    logic seq_start_prev;
    logic seq_start_rise;

    always_ff @(posedge clk_sys or negedge rst_n) begin
        if (!rst_n) seq_start_prev <= 1'b0;
        else        seq_start_prev <= seq_start;
    end
    assign seq_start_rise = seq_start & ~seq_start_prev;

    // ── Step 4: Run/Stop Logic ─────────────────────────────
    // FIX BUG 1 + BUG 2: cycle_count now increments and running auto-clears.
    logic        running;
    logic [7:0]  cycle_count;  // ← WAS NEVER INCREMENTED IN ORIGINAL

    always_ff @(posedge clk_sys or negedge rst_n) begin
        if (!rst_n) begin
            running     <= 1'b0;
            cycle_count <= '0;
        end else begin
            if (!seq_en || man_mode) begin
                running     <= 1'b0;
                cycle_count <= '0;
            end else if (seq_start_rise && !running) begin
                // Rising edge of seq_start: begin a fresh run
                running     <= 1'b1;
                cycle_count <= '0;             // Reset counter for new run
            end else if (!seq_start && running) begin
                // MCU wrote 0 to SEQ_START: force stop
                running     <= 1'b0;
                cycle_count <= '0;
            end else if (running && cycle_end) begin
                // FIX BUG 1: Increment cycle_count on each completed cycle
                if (seq_cnt != 8'h00) begin
                    if (cycle_count >= seq_cnt - 1'b1) begin
                        // FIX BUG 2: Auto-stop after seq_cnt cycles complete
                        running     <= 1'b0;
                        cycle_count <= '0;
                    end else begin
                        cycle_count <= cycle_count + 1'b1;
                    end
                end
                // If seq_cnt==0 (continuous): cycle_count stays 0, running stays 1
            end
        end
    end
    assign seq_running = running;

    // ── Step 5: Main counter (0 → seq_period-1) ───────────


    always_ff @(posedge clk_sys or negedge rst_n) begin
        if (!rst_n) begin
            counter   <= '0;
            cycle_end <= 1'b0;
        end else begin
            cycle_end <= 1'b0;
            if (running && seq_tick) begin
                if (counter >= (seq_per - 1'b1)) begin
                    counter   <= '0;
                    cycle_end <= 1'b1;
                end else begin
                    counter <= counter + 1'b1;
                end
            end else if (!running) begin
                counter <= '0;
            end
        end
    end

    // ── Step 6: IRQ generation ─────────────────────────────
    // cycle_end fires at the end of each measurement cycle.
    // For continuous mode (seq_cnt=0): IRQ fires every cycle.
    // For fixed-count mode: IRQ fires only on the LAST cycle.
    logic irq_done_pulse;

    always_ff @(posedge clk_sys or negedge rst_n) begin
        if (!rst_n) begin
            irq_done_pulse <= 1'b0;
        end else begin
            irq_done_pulse <= 1'b0;
            if (cycle_end && running) begin
                if (seq_cnt == 8'h00) begin
                    // Continuous: IRQ every cycle
                    irq_done_pulse <= 1'b1;
                end else begin
                    // Fixed count: IRQ only on the LAST cycle
                    // cycle_count is the CURRENT completed cycle index (0-based)
                    // FIX BUG 1: cycle_count is now valid (it increments above)
                    if (cycle_count >= seq_cnt - 1'b1) begin
                        irq_done_pulse <= 1'b1;
                    end
                end
            end
        end
    end
    assign irq_seq_done = irq_done_pulse;

    // ── Step 7: SR Flip-Flop Comparators ──────────────────

    // LED driver
    always_ff @(posedge clk_sys or negedge rst_n) begin
        if (!rst_n) begin
            led_drive <= 1'b0;
        end else if (running && seq_tick) begin
            if (counter == seq_led_sta) led_drive <= 1'b1;
            if (counter == seq_led_sto) led_drive <= 1'b0;
        end else if (!running) begin
            led_drive <= 1'b0;
        end
    end

    // Secondary LED driver
    always_ff @(posedge clk_sys or negedge rst_n) begin
        if (!rst_n) begin
            sec_led_drive <= 1'b0;
        end else if (running && seq_tick) begin
            if (counter == seq_secled_sta) sec_led_drive <= 1'b1;
            if (counter == seq_secled_sto) sec_led_drive <= 1'b0;
        end else if (!running) begin
            sec_led_drive <= 1'b0;
        end
    end

    // TIA Integrator enable
    // FIX BUG 3: When !running, itg_en stays HIGH (default-ON per datasheet).
    // Original had itg_en <= 1'b0 in the !running branch - WRONG.
    always_ff @(posedge clk_sys or negedge rst_n) begin
        if (!rst_n) begin
            itg_en <= 1'b1;  // Default ON per datasheet
        end else if (running && seq_tick) begin
            if (counter == seq_itg_sta) itg_en <= 1'b1;
            if (counter == seq_itg_sto) itg_en <= 1'b0;
        end else if (!running) begin
            itg_en <= 1'b1;  // FIX BUG 3: was 1'b0, must be 1'b1 (default-ON)
        end
    end

    // SDP1
    always_ff @(posedge clk_sys or negedge rst_n) begin
        if (!rst_n) begin
            sdp1_out <= 1'b0;
        end else if (running && seq_tick) begin
            if (counter == seq_sdp1_sta) sdp1_out <= 1'b1;
            if (counter == seq_sdp1_sto) sdp1_out <= 1'b0;
        end else if (!running) begin
            sdp1_out <= 1'b0;
        end
    end

    // SDM1
    always_ff @(posedge clk_sys or negedge rst_n) begin
        if (!rst_n) begin
            sdm1_out <= 1'b0;
        end else if (running && seq_tick) begin
            if (counter == seq_sdm1_sta) sdm1_out <= 1'b1;
            if (counter == seq_sdm1_sto) sdm1_out <= 1'b0;
        end else if (!running) begin
            sdm1_out <= 1'b0;
        end
    end

    // SDP2
    always_ff @(posedge clk_sys or negedge rst_n) begin
        if (!rst_n) begin
            sdp2_out <= 1'b0;
        end else if (running && seq_tick) begin
            if (counter == seq_sdp2_sta) sdp2_out <= 1'b1;
            if (counter == seq_sdp2_sto) sdp2_out <= 1'b0;
        end else if (!running) begin
            sdp2_out <= 1'b0;
        end
    end

    // SDM2
    always_ff @(posedge clk_sys or negedge rst_n) begin
        if (!rst_n) begin
            sdm2_out <= 1'b0;
        end else if (running && seq_tick) begin
            if (counter == seq_sdm2_sta) sdm2_out <= 1'b1;
            if (counter == seq_sdm2_sto) sdm2_out <= 1'b0;
        end else if (!running) begin
            sdm2_out <= 1'b0;
        end
    end

    // ── ADC Sample Trigger ─────────────────────────────────
    // FIX BUG 4: Hold adc_sample HIGH for a full t_clk period (until next
    // seq_tick), not just 1 clk_sys cycle (20ns). This makes the pulse wide
    // enough for any downstream ADC trigger logic to reliably detect it.
    always_ff @(posedge clk_sys or negedge rst_n) begin
        if (!rst_n) begin
            adc_sample <= 1'b0;
        end else if (running && seq_tick) begin
            // Assert on trigger count, clear on all other counts
            adc_sample <= (counter == seq_adc) ? 1'b1 : 1'b0;
            // Pulse is now t_clk wide (held until next seq_tick overrides it)
        end else if (!running) begin
            adc_sample <= 1'b0;
        end
        // FIX BUG 4: NO 'else adc_sample <= 0' here.
        // Between seq_ticks, adc_sample holds its last value.
    end

endmodule