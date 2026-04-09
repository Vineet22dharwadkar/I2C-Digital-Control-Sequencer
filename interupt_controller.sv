// ============================================================
// interrupt_ctrl.sv - Interrupt Controller
// AS7038RB Datasheet Section 7.2 (Interrupts, pg 107)
//
// FROM DATASHEET:
//   "An interrupt output pin INT can be used to interrupt the host.
//    Following interrupt sources are possible:
//    irq_adc, irq_sequencer, irq_ltf, irq_adc_threshold,
//    irq_fifothreshold, irq_fifooverflow, irq_clipdetect,
//    irq_led_supply_low
//    Depending on the setting in register INTENAB each of the above
//    interrupt sources can assert INT output pin (active low)."
//
// INT PIN BEHAVIOR (datasheet pin 9):
//   "Open drain interrupt output pin. Active low."
//   → driven LOW when interrupt fires, releases (goes HIGH) when cleared
//   → Must configure MCU GPIO with pull-up resistor
//
// STATUS REGISTER (0xA0):
//   Bit 7: irq_led_supply_low
//   Bit 6: irq_clipdetect
//   Bit 5: irq_fifooverflow
//   Bit 4: irq_fifothreshold
//   Bit 3: irq_adc_threshold
//   Bit 2: irq_ltf
//   Bit 1: irq_sequencer       ← Primary for optical sensing
//   Bit 0: irq_adc
//
// INTENAB (0xA8): same bit layout - 1 enables that source → INT pin
// INTR (0xAA): write bit to clear that interrupt flag
// ============================================================

`timescale 1ns / 1ps

module interrupt_ctrl (
    input  logic        clk,
    input  logic        rst_n,

    // Interrupt source inputs (from sequencer and other blocks)
    input  logic        irq_sequencer,    // End of sequence
    input  logic        irq_fifooverflow, // FIFO full - data lost
    input  logic        irq_fifothresh,   // FIFO threshold reached
    input  logic        irq_clipdetect,   // Signal clipping detected

    // INTENAB register [7:0] - controls which sources reach INT pin
    input  logic [7:0]  intenab,

    // INTR register [7:0] - write bit to clear that flag
    input  logic [7:0]  intr_clr,

    // STATUS register output → readable by I2C
    output logic [7:0]  status_out,

    // INT pin - active LOW open-drain output
    // Connect to MCU GPIO with external pull-up
    output logic        int_n
);

    // ── STATUS register (0xA0) bit assignments ─────────────
    localparam BIT_IRQ_LED_LOW   = 7;  // irq_led_supply_low
    localparam BIT_IRQ_CLIP      = 6;  // irq_clipdetect
    localparam BIT_IRQ_FIFO_OVF  = 5;  // irq_fifooverflow
    localparam BIT_IRQ_FIFO_THR  = 4;  // irq_fifothreshold
    localparam BIT_IRQ_ADC_THR   = 3;  // irq_adc_threshold (unused)
    localparam BIT_IRQ_LTF       = 2;  // irq_ltf (unused)
    localparam BIT_IRQ_SEQ       = 1;  // irq_sequencer
    localparam BIT_IRQ_ADC       = 0;  // irq_adc (unused)

    // ── Sticky interrupt flags ──────────────────────────────
    // Flags latch when interrupt fires. Stay latched until cleared via INTR.
    logic [7:0] irq_flags;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            irq_flags <= 8'h00;
        end else begin
            // SET: latch when source fires
            if (irq_sequencer)    irq_flags[BIT_IRQ_SEQ]      <= 1'b1;
            if (irq_fifooverflow) irq_flags[BIT_IRQ_FIFO_OVF] <= 1'b1;
            if (irq_fifothresh)   irq_flags[BIT_IRQ_FIFO_THR] <= 1'b1;
            if (irq_clipdetect)   irq_flags[BIT_IRQ_CLIP]      <= 1'b1;

            // CLEAR: write 1 to corresponding INTR bit clears the flag
            // Datasheet: "write same bit to INTR register to clear"
            if (intr_clr[BIT_IRQ_SEQ])      irq_flags[BIT_IRQ_SEQ]      <= 1'b0;
            if (intr_clr[BIT_IRQ_FIFO_OVF]) irq_flags[BIT_IRQ_FIFO_OVF] <= 1'b0;
            if (intr_clr[BIT_IRQ_FIFO_THR]) irq_flags[BIT_IRQ_FIFO_THR] <= 1'b0;
            if (intr_clr[BIT_IRQ_CLIP])     irq_flags[BIT_IRQ_CLIP]      <= 1'b0;
            if (intr_clr[BIT_IRQ_ADC_THR])  irq_flags[BIT_IRQ_ADC_THR]  <= 1'b0;
            if (intr_clr[BIT_IRQ_LTF])      irq_flags[BIT_IRQ_LTF]       <= 1'b0;
            if (intr_clr[BIT_IRQ_ADC])      irq_flags[BIT_IRQ_ADC]       <= 1'b0;
            if (intr_clr[BIT_IRQ_LED_LOW])  irq_flags[BIT_IRQ_LED_LOW]   <= 1'b0;
        end
    end

    // ── STATUS register output ─────────────────────────────
    assign status_out = irq_flags;

    // ── INT pin: active LOW ─────────────────────────────────
    // Datasheet: "each of the above interrupt sources can assert
    //             INT output pin (active low)"
    // INT goes LOW when: any enabled (INTENAB) flag is set
    // INT stays LOW until all active flags are cleared via INTR
    logic any_enabled_irq;
    assign any_enabled_irq = |(irq_flags & intenab);

    // Open-drain behavior: drive LOW to assert, release to de-assert
    // In FPGA: model as active-low output; use OBUF with pull-up in Vivado XDC
    assign int_n = ~any_enabled_irq;  // 0 = interrupt active, 1 = clear

endmodule