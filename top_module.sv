// ============================================================
// as7038rb_top.sv  -  Top-Level (FIXED v2)
// AS7038RB I2C Slave + Digital Control Sequencer
// Datasheet: DS000726 v2-00
//
// FIXED vs v1:
//   - Removed o_osc_en / o_ldo_en connections (removed from register_file)
//   - All other connections identical
// ============================================================

`timescale 1ns / 1ps

module as7038rb_top (
    input  logic        clk_sys,
    input  logic        rst_n,
    input  logic        enable,

    inout  wire         scl,
    inout  wire         sda,

    output logic        led_drive,
    output logic        sec_led_drive,
    output logic        itg_en,
    output logic        sdp1_out,
    output logic        sdm1_out,
    output logic        sdp2_out,
    output logic        sdm2_out,
    output logic        adc_sample,

    output logic        int_n,
    output logic        seq_running,
    output logic [7:0]  seq_status
);

    // ── Internal wires ─────────────────────────────────────
    logic        reg_wr_en;
    logic [7:0]  reg_wr_addr, reg_wr_data;
    logic        reg_rd_en;
    logic [7:0]  reg_rd_addr, reg_rd_data;

    logic        r_man_mode, r_seq_en, r_seq_start;
    logic [7:0]  r_seq_cnt, r_seq_div, r_seq_per;
    logic [7:0]  r_seq_led_sta, r_seq_led_sto;
    logic [7:0]  r_seq_secled_sta, r_seq_secled_sto;
    logic [7:0]  r_seq_itg_sta, r_seq_itg_sto;
    logic [7:0]  r_seq_sdp1_sta, r_seq_sdp1_sto;
    logic [7:0]  r_seq_sdp2_sta, r_seq_sdp2_sto;
    logic [7:0]  r_seq_sdm1_sta, r_seq_sdm1_sto;
    logic [7:0]  r_seq_sdm2_sta, r_seq_sdm2_sto;
    logic [7:0]  r_seq_adc;
    logic [7:0]  r_intenab, r_intr_clr;

    logic        irq_sequencer;
    logic [7:0]  status_reg;

    // ENABLE pin: active HIGH. LOW resets all registers.
    logic chip_active;
    assign chip_active = enable & rst_n;

    // ── I2C Slave ──────────────────────────────────────────
    i2c_slave u_i2c (
        .clk         (clk_sys),
        .rst_n       (chip_active),
        .scl         (scl),
        .sda         (sda),
        .reg_wr_en   (reg_wr_en),
        .reg_wr_addr (reg_wr_addr),
        .reg_wr_data (reg_wr_data),
        .reg_rd_en   (reg_rd_en),
        .reg_rd_addr (reg_rd_addr),
        .reg_rd_data (reg_rd_data)
    );

    // ── Register File ──────────────────────────────────────
    register_file u_regfile (
        .clk             (clk_sys),
        .rst_n           (chip_active),
        .wr_en           (reg_wr_en),
        .wr_addr         (reg_wr_addr),
        .wr_data         (reg_wr_data),
        .rd_addr         (reg_rd_addr),
        .rd_data         (reg_rd_data),
        .status_in       (status_reg),
        .o_man_mode      (r_man_mode),
        .o_seq_en        (r_seq_en),
        .o_seq_cnt       (r_seq_cnt),
        .o_seq_div       (r_seq_div),
        .o_seq_start     (r_seq_start),
        .o_seq_per       (r_seq_per),
        .o_seq_led_sta   (r_seq_led_sta),
        .o_seq_led_sto   (r_seq_led_sto),
        .o_seq_secled_sta(r_seq_secled_sta),
        .o_seq_secled_sto(r_seq_secled_sto),
        .o_seq_itg_sta   (r_seq_itg_sta),
        .o_seq_itg_sto   (r_seq_itg_sto),
        .o_seq_sdp1_sta  (r_seq_sdp1_sta),
        .o_seq_sdp1_sto  (r_seq_sdp1_sto),
        .o_seq_sdp2_sta  (r_seq_sdp2_sta),
        .o_seq_sdp2_sto  (r_seq_sdp2_sto),
        .o_seq_sdm1_sta  (r_seq_sdm1_sta),
        .o_seq_sdm1_sto  (r_seq_sdm1_sto),
        .o_seq_sdm2_sta  (r_seq_sdm2_sta),
        .o_seq_sdm2_sto  (r_seq_sdm2_sto),
        .o_seq_adc       (r_seq_adc),
        .o_intenab       (r_intenab),
        .o_intr_clr      (r_intr_clr)
    );

    // ── Sequencer ──────────────────────────────────────────
    sequencer u_seq (
        .clk_sys        (clk_sys),
        .rst_n          (chip_active),
        .seq_en         (r_seq_en),
        .man_mode       (r_man_mode),
        .seq_start      (r_seq_start),
        .seq_cnt        (r_seq_cnt),
        .seq_div        (r_seq_div),
        .seq_per        (r_seq_per),
        .seq_led_sta    (r_seq_led_sta),
        .seq_led_sto    (r_seq_led_sto),
        .seq_secled_sta (r_seq_secled_sta),
        .seq_secled_sto (r_seq_secled_sto),
        .seq_itg_sta    (r_seq_itg_sta),
        .seq_itg_sto    (r_seq_itg_sto),
        .seq_sdp1_sta   (r_seq_sdp1_sta),
        .seq_sdp1_sto   (r_seq_sdp1_sto),
        .seq_sdp2_sta   (r_seq_sdp2_sta),
        .seq_sdp2_sto   (r_seq_sdp2_sto),
        .seq_sdm1_sta   (r_seq_sdm1_sta),
        .seq_sdm1_sto   (r_seq_sdm1_sto),
        .seq_sdm2_sta   (r_seq_sdm2_sta),
        .seq_sdm2_sto   (r_seq_sdm2_sto),
        .seq_adc        (r_seq_adc),
        .led_drive      (led_drive),
        .sec_led_drive  (sec_led_drive),
        .itg_en         (itg_en),
        .sdp1_out       (sdp1_out),
        .sdm1_out       (sdm1_out),
        .sdp2_out       (sdp2_out),
        .sdm2_out       (sdm2_out),
        .adc_sample     (adc_sample),
        .seq_running    (seq_running),
        .irq_seq_done   (irq_sequencer)
    );

    // ── Interrupt Controller ───────────────────────────────
    interrupt_ctrl u_irq (
        .clk             (clk_sys),
        .rst_n           (chip_active),
        .irq_sequencer   (irq_sequencer),
        .irq_fifooverflow(1'b0),
        .irq_fifothresh  (1'b0),
        .irq_clipdetect  (1'b0),
        .intenab         (r_intenab),
        .intr_clr        (r_intr_clr),
        .status_out      (status_reg),
        .int_n           (int_n)
    );

    assign seq_status = status_reg;

endmodule