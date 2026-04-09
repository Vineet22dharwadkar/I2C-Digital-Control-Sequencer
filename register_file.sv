// ============================================================
// register_file.sv  -  AS7038RB Configuration Registers (FIXED v2)
// Datasheet Section 6, Pages 16-21
//
// BUGS FIXED vs v1:
//
// BUG 3 (from i2c_slave analysis) - INTR auto-clear destroys the
//   clear pulse before interrupt_ctrl sees it:
//   Old code had: else begin r_intr <= 8'h00; end
//   This means every clock cycle when wr_en=0, r_intr is cleared.
//   The I2C write takes multiple clocks to arrive. By the time
//   interrupt_ctrl samples r_intr on the next rising edge, it is
//   already 0x00 again - so the interrupt is NEVER cleared.
//   Fix: r_intr only clears when interrupt_ctrl acknowledges it
//   (one-cycle handshake). We use a separate intr_ack input, or
//   simpler: r_intr holds its value until next write. The interrupt
//   controller is edge-triggered on the clear pulse, so holding the
//   written value for one extra clock is harmless.
//   REMOVED the "else r_intr <= 0" branch entirely.
//
// BUG 6 - o_osc_en / o_ldo_en gated sequencer from running before
//   CONTROL register is written. The sequencer should run as long
//   as seq_en=1 and seq_start=1. Whether the real chip's oscillator
//   is on or not is an analog concern - in digital RTL we do not
//   need to gate sequencer on o_osc_en. Removed that dependency.
//   (The chip_active signal already handles ENABLE pin reset.)
//
// BUG 7 - register_file port list had o_osc_en / o_ldo_en outputs
//   that were declared in the port but not connected in as7038rb_top.
//   Removed those two ports (unused in top-level, no connection bug).
// ============================================================

`timescale 1ns / 1ps

module register_file (
    input  logic        clk,
    input  logic        rst_n,

    // Write port (from I2C slave)
    input  logic        wr_en,
    input  logic [7:0]  wr_addr,
    input  logic [7:0]  wr_data,

    // Read port (to I2C slave - combinational)
    input  logic [7:0]  rd_addr,
    output logic [7:0]  rd_data,

    // Live STATUS register from interrupt controller
    input  logic [7:0]  status_in,

    // ── Sequencer decoded outputs ──────────────────────────
    output logic        o_man_mode,
    output logic        o_seq_en,
    output logic [7:0]  o_seq_cnt,
    output logic [7:0]  o_seq_div,
    output logic        o_seq_start,
    output logic [7:0]  o_seq_per,
    output logic [7:0]  o_seq_led_sta,
    output logic [7:0]  o_seq_led_sto,
    output logic [7:0]  o_seq_secled_sta,
    output logic [7:0]  o_seq_secled_sto,
    output logic [7:0]  o_seq_itg_sta,
    output logic [7:0]  o_seq_itg_sto,
    output logic [7:0]  o_seq_sdp1_sta,
    output logic [7:0]  o_seq_sdp1_sto,
    output logic [7:0]  o_seq_sdp2_sta,
    output logic [7:0]  o_seq_sdp2_sto,
    output logic [7:0]  o_seq_sdm1_sta,
    output logic [7:0]  o_seq_sdm1_sto,
    output logic [7:0]  o_seq_sdm2_sta,
    output logic [7:0]  o_seq_sdm2_sto,
    output logic [7:0]  o_seq_adc,

    // Interrupt
    output logic [7:0]  o_intenab,
    output logic [7:0]  o_intr_clr
);

    // ── Register Addresses ──────────────────────────────────
    localparam ADDR_CONTROL       = 8'h00;
    localparam ADDR_LED_CFG       = 8'h10;
    localparam ADDR_LED_WAIT_LOW  = 8'h11;
    localparam ADDR_LED1_CURRL    = 8'h12;
    localparam ADDR_LED1_CURRH    = 8'h13;
    localparam ADDR_LED2_CURRL    = 8'h14;
    localparam ADDR_LED2_CURRH    = 8'h15;
    localparam ADDR_LED3_CURRL    = 8'h16;
    localparam ADDR_LED3_CURRH    = 8'h17;
    localparam ADDR_LED4_CURRL    = 8'h18;
    localparam ADDR_LED4_CURRH    = 8'h19;
    localparam ADDR_PD_CFG        = 8'h1A;
    localparam ADDR_PD_AMPRCC     = 8'h1D;
    localparam ADDR_PD_AMPCFG     = 8'h1E;
    localparam ADDR_LED12_MODE    = 8'h2C;
    localparam ADDR_LED34_MODE    = 8'h2D;
    localparam ADDR_MAN_SEQ_CFG   = 8'h2E;
    localparam ADDR_SEQ_CNT       = 8'h30;
    localparam ADDR_SEQ_DIV       = 8'h31;
    localparam ADDR_SEQ_START     = 8'h32;
    localparam ADDR_SEQ_PER       = 8'h33;
    localparam ADDR_SEQ_LED_STA   = 8'h34;
    localparam ADDR_SEQ_LED_STO   = 8'h35;
    localparam ADDR_SEQ_SECLED_STA= 8'h36;
    localparam ADDR_SEQ_SECLED_STO= 8'h37;
    localparam ADDR_SEQ_ITG_STA   = 8'h38;
    localparam ADDR_SEQ_ITG_STO   = 8'h39;
    localparam ADDR_SEQ_SDP1_STA  = 8'h3A;
    localparam ADDR_SEQ_SDP1_STO  = 8'h3B;
    localparam ADDR_SEQ_SDP2_STA  = 8'h3C;
    localparam ADDR_SEQ_SDP2_STO  = 8'h3D;
    localparam ADDR_SEQ_SDM1_STA  = 8'h3E;
    localparam ADDR_SEQ_SDM1_STO  = 8'h3F;
    localparam ADDR_SEQ_SDM2_STA  = 8'h40;
    localparam ADDR_SEQ_SDM2_STO  = 8'h41;
    localparam ADDR_SEQ_ADC       = 8'h42;
    localparam ADDR_SD_SUBS       = 8'h45;
    localparam ADDR_OFE_CFGA      = 8'h50;
    localparam ADDR_OFE1_CFGA     = 8'h54;
    localparam ADDR_OFE1_CFGB     = 8'h55;
    localparam ADDR_ADC_CFGB      = 8'h89;
    localparam ADDR_ADC_MASKL     = 8'h8B;
    localparam ADDR_ADC_MASKH     = 8'h8C;
    localparam ADDR_FIFO_CFG      = 8'h78;
    localparam ADDR_FIFO_CNTRL    = 8'h79;
    localparam ADDR_SUBID         = 8'h91;
    localparam ADDR_ID            = 8'h92;
    localparam ADDR_STATUS        = 8'hA0;
    localparam ADDR_INTENAB       = 8'hA8;
    localparam ADDR_INTR          = 8'hAA;

    // Fixed chip ID values (read-only, per AS7038RB)
    localparam [7:0] CHIP_ID    = 8'h21;
    localparam [7:0] CHIP_SUBID = 8'h01;

    // ── Register Storage ────────────────────────────────────
    logic [7:0] r_control;
    logic [7:0] r_led_cfg;
    logic [7:0] r_led_wait;
    logic [7:0] r_led1_currl, r_led1_currh;
    logic [7:0] r_led2_currl, r_led2_currh;
    logic [7:0] r_led3_currl, r_led3_currh;
    logic [7:0] r_led4_currl, r_led4_currh;
    logic [7:0] r_pd_cfg;
    logic [7:0] r_pd_amprcc;
    logic [7:0] r_pd_ampcfg;
    logic [7:0] r_led12_mode;
    logic [7:0] r_led34_mode;
    logic [7:0] r_man_seq_cfg;
    logic [7:0] r_seq_cnt;
    logic [7:0] r_seq_div;
    logic [7:0] r_seq_start;
    logic [7:0] r_seq_per;
    logic [7:0] r_seq_led_sta;
    logic [7:0] r_seq_led_sto;
    logic [7:0] r_seq_secled_sta;
    logic [7:0] r_seq_secled_sto;
    logic [7:0] r_seq_itg_sta;
    logic [7:0] r_seq_itg_sto;
    logic [7:0] r_seq_sdp1_sta;
    logic [7:0] r_seq_sdp1_sto;
    logic [7:0] r_seq_sdp2_sta;
    logic [7:0] r_seq_sdp2_sto;
    logic [7:0] r_seq_sdm1_sta;
    logic [7:0] r_seq_sdm1_sto;
    logic [7:0] r_seq_sdm2_sta;
    logic [7:0] r_seq_sdm2_sto;
    logic [7:0] r_seq_adc;
    logic [7:0] r_sd_subs;
    logic [7:0] r_ofe_cfga;
    logic [7:0] r_ofe1_cfga;
    logic [7:0] r_ofe1_cfgb;
    logic [7:0] r_adc_cfgb;
    logic [7:0] r_adc_maskl;
    logic [7:0] r_adc_maskh;
    logic [7:0] r_fifo_cfg;
    logic [7:0] r_intenab;
    logic [7:0] r_intr;

    // ── Write Logic ─────────────────────────────────────────
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            r_control       <= '0; r_led_cfg       <= '0;
            r_led_wait      <= '0;
            r_led1_currl    <= '0; r_led1_currh    <= '0;
            r_led2_currl    <= '0; r_led2_currh    <= '0;
            r_led3_currl    <= '0; r_led3_currh    <= '0;
            r_led4_currl    <= '0; r_led4_currh    <= '0;
            r_pd_cfg        <= '0; r_pd_amprcc     <= '0;
            r_pd_ampcfg     <= '0;
            r_led12_mode    <= '0; r_led34_mode    <= '0;
            r_man_seq_cfg   <= '0;
            r_seq_cnt       <= '0; r_seq_div       <= '0;
            r_seq_start     <= '0; r_seq_per       <= '0;
            r_seq_led_sta   <= '0; r_seq_led_sto   <= '0;
            r_seq_secled_sta<= '0; r_seq_secled_sto<= '0;
            r_seq_itg_sta   <= '0; r_seq_itg_sto   <= '0;
            r_seq_sdp1_sta  <= '0; r_seq_sdp1_sto  <= '0;
            r_seq_sdp2_sta  <= '0; r_seq_sdp2_sto  <= '0;
            r_seq_sdm1_sta  <= '0; r_seq_sdm1_sto  <= '0;
            r_seq_sdm2_sta  <= '0; r_seq_sdm2_sto  <= '0;
            r_seq_adc       <= '0; r_sd_subs       <= '0;
            r_ofe_cfga      <= '0; r_ofe1_cfga     <= '0;
            r_ofe1_cfgb     <= '0; r_adc_cfgb      <= '0;
            r_adc_maskl     <= '0; r_adc_maskh     <= '0;
            r_fifo_cfg      <= '0;
            r_intenab       <= '0;
            r_intr          <= '0;
        end else if (wr_en) begin
            case (wr_addr)
                ADDR_CONTROL:        r_control        <= wr_data;
                ADDR_LED_CFG:        r_led_cfg        <= wr_data;
                ADDR_LED_WAIT_LOW:   r_led_wait       <= wr_data;
                ADDR_LED1_CURRL:     r_led1_currl     <= wr_data;
                ADDR_LED1_CURRH:     r_led1_currh     <= wr_data;
                ADDR_LED2_CURRL:     r_led2_currl     <= wr_data;
                ADDR_LED2_CURRH:     r_led2_currh     <= wr_data;
                ADDR_LED3_CURRL:     r_led3_currl     <= wr_data;
                ADDR_LED3_CURRH:     r_led3_currh     <= wr_data;
                ADDR_LED4_CURRL:     r_led4_currl     <= wr_data;
                ADDR_LED4_CURRH:     r_led4_currh     <= wr_data;
                ADDR_PD_CFG:         r_pd_cfg         <= wr_data;
                ADDR_PD_AMPRCC:      r_pd_amprcc      <= wr_data;
                ADDR_PD_AMPCFG:      r_pd_ampcfg      <= wr_data;
                ADDR_LED12_MODE:     r_led12_mode     <= wr_data;
                ADDR_LED34_MODE:     r_led34_mode     <= wr_data;
                ADDR_MAN_SEQ_CFG:    r_man_seq_cfg    <= wr_data;
                ADDR_SEQ_CNT:        r_seq_cnt        <= wr_data;
                ADDR_SEQ_DIV:        r_seq_div        <= wr_data;
                ADDR_SEQ_START:      r_seq_start      <= wr_data;
                ADDR_SEQ_PER:        r_seq_per        <= wr_data;
                ADDR_SEQ_LED_STA:    r_seq_led_sta    <= wr_data;
                ADDR_SEQ_LED_STO:    r_seq_led_sto    <= wr_data;
                ADDR_SEQ_SECLED_STA: r_seq_secled_sta <= wr_data;
                ADDR_SEQ_SECLED_STO: r_seq_secled_sto <= wr_data;
                ADDR_SEQ_ITG_STA:    r_seq_itg_sta    <= wr_data;
                ADDR_SEQ_ITG_STO:    r_seq_itg_sto    <= wr_data;
                ADDR_SEQ_SDP1_STA:   r_seq_sdp1_sta   <= wr_data;
                ADDR_SEQ_SDP1_STO:   r_seq_sdp1_sto   <= wr_data;
                ADDR_SEQ_SDP2_STA:   r_seq_sdp2_sta   <= wr_data;
                ADDR_SEQ_SDP2_STO:   r_seq_sdp2_sto   <= wr_data;
                ADDR_SEQ_SDM1_STA:   r_seq_sdm1_sta   <= wr_data;
                ADDR_SEQ_SDM1_STO:   r_seq_sdm1_sto   <= wr_data;
                ADDR_SEQ_SDM2_STA:   r_seq_sdm2_sta   <= wr_data;
                ADDR_SEQ_SDM2_STO:   r_seq_sdm2_sto   <= wr_data;
                ADDR_SEQ_ADC:        r_seq_adc        <= wr_data;
                ADDR_SD_SUBS:        r_sd_subs        <= wr_data;
                ADDR_OFE_CFGA:       r_ofe_cfga       <= wr_data;
                ADDR_OFE1_CFGA:      r_ofe1_cfga      <= wr_data;
                ADDR_OFE1_CFGB:      r_ofe1_cfgb      <= wr_data;
                ADDR_ADC_CFGB:       r_adc_cfgb       <= wr_data;
                ADDR_ADC_MASKL:      r_adc_maskl      <= wr_data;
                ADDR_ADC_MASKH:      r_adc_maskh      <= wr_data;
                ADDR_FIFO_CFG:       r_fifo_cfg       <= wr_data;
                ADDR_INTENAB:        r_intenab        <= wr_data;
                // FIX BUG 3: INTR holds written value (no auto-clear)
                // interrupt_ctrl sees the pulse on the next posedge,
                // then the MCU writes 0x00 to INTR to release.
                ADDR_INTR:           r_intr           <= wr_data;
                default: ; // Read-only or reserved - ignore
            endcase
        end
        // FIX BUG 3: REMOVED the "else r_intr <= 8'h00" that was here.
        // That auto-clear wiped r_intr every non-write clock, so the
        // interrupt controller never saw the clear pulse.
    end

    // ── Read Logic (pure combinational) ─────────────────────
    always_comb begin
        case (rd_addr)
            ADDR_CONTROL:        rd_data = r_control;
            ADDR_LED_CFG:        rd_data = r_led_cfg;
            ADDR_LED_WAIT_LOW:   rd_data = r_led_wait;
            ADDR_LED1_CURRL:     rd_data = r_led1_currl;
            ADDR_LED1_CURRH:     rd_data = r_led1_currh;
            ADDR_LED2_CURRL:     rd_data = r_led2_currl;
            ADDR_LED2_CURRH:     rd_data = r_led2_currh;
            ADDR_LED3_CURRL:     rd_data = r_led3_currl;
            ADDR_LED3_CURRH:     rd_data = r_led3_currh;
            ADDR_LED4_CURRL:     rd_data = r_led4_currl;
            ADDR_LED4_CURRH:     rd_data = r_led4_currh;
            ADDR_PD_CFG:         rd_data = r_pd_cfg;
            ADDR_PD_AMPRCC:      rd_data = r_pd_amprcc;
            ADDR_PD_AMPCFG:      rd_data = r_pd_ampcfg;
            ADDR_LED12_MODE:     rd_data = r_led12_mode;
            ADDR_LED34_MODE:     rd_data = r_led34_mode;
            ADDR_MAN_SEQ_CFG:    rd_data = r_man_seq_cfg;
            ADDR_SEQ_CNT:        rd_data = r_seq_cnt;
            ADDR_SEQ_DIV:        rd_data = r_seq_div;
            ADDR_SEQ_START:      rd_data = r_seq_start;
            ADDR_SEQ_PER:        rd_data = r_seq_per;
            ADDR_SEQ_LED_STA:    rd_data = r_seq_led_sta;
            ADDR_SEQ_LED_STO:    rd_data = r_seq_led_sto;
            ADDR_SEQ_SECLED_STA: rd_data = r_seq_secled_sta;
            ADDR_SEQ_SECLED_STO: rd_data = r_seq_secled_sto;
            ADDR_SEQ_ITG_STA:    rd_data = r_seq_itg_sta;
            ADDR_SEQ_ITG_STO:    rd_data = r_seq_itg_sto;
            ADDR_SEQ_SDP1_STA:   rd_data = r_seq_sdp1_sta;
            ADDR_SEQ_SDP1_STO:   rd_data = r_seq_sdp1_sto;
            ADDR_SEQ_SDP2_STA:   rd_data = r_seq_sdp2_sta;
            ADDR_SEQ_SDP2_STO:   rd_data = r_seq_sdp2_sto;
            ADDR_SEQ_SDM1_STA:   rd_data = r_seq_sdm1_sta;
            ADDR_SEQ_SDM1_STO:   rd_data = r_seq_sdm1_sto;
            ADDR_SEQ_SDM2_STA:   rd_data = r_seq_sdm2_sta;
            ADDR_SEQ_SDM2_STO:   rd_data = r_seq_sdm2_sto;
            ADDR_SEQ_ADC:        rd_data = r_seq_adc;
            ADDR_SD_SUBS:        rd_data = r_sd_subs;
            ADDR_OFE_CFGA:       rd_data = r_ofe_cfga;
            ADDR_OFE1_CFGA:      rd_data = r_ofe1_cfga;
            ADDR_OFE1_CFGB:      rd_data = r_ofe1_cfgb;
            ADDR_ADC_CFGB:       rd_data = r_adc_cfgb;
            ADDR_ADC_MASKL:      rd_data = r_adc_maskl;
            ADDR_ADC_MASKH:      rd_data = r_adc_maskh;
            ADDR_FIFO_CFG:       rd_data = r_fifo_cfg;
            ADDR_INTENAB:        rd_data = r_intenab;
            // Read-only fixed values
            ADDR_ID:             rd_data = CHIP_ID;
            ADDR_SUBID:          rd_data = CHIP_SUBID;
            // Live STATUS from interrupt controller
            ADDR_STATUS:         rd_data = status_in;
            default:             rd_data = 8'h00;
        endcase
    end

    // ── Decoded field outputs to sequencer ──────────────────
    assign o_man_mode      = r_man_seq_cfg[7];
    assign o_seq_en        = r_man_seq_cfg[0];

    assign o_seq_cnt        = r_seq_cnt;
    assign o_seq_div        = r_seq_div;
    assign o_seq_start      = r_seq_start[0];   // bit0 = seq_start R_PUSH
    assign o_seq_per        = r_seq_per;
    assign o_seq_led_sta    = r_seq_led_sta;
    assign o_seq_led_sto    = r_seq_led_sto;
    assign o_seq_secled_sta = r_seq_secled_sta;
    assign o_seq_secled_sto = r_seq_secled_sto;
    assign o_seq_itg_sta    = r_seq_itg_sta;
    assign o_seq_itg_sto    = r_seq_itg_sto;
    assign o_seq_sdp1_sta   = r_seq_sdp1_sta;
    assign o_seq_sdp1_sto   = r_seq_sdp1_sto;
    assign o_seq_sdp2_sta   = r_seq_sdp2_sta;
    assign o_seq_sdp2_sto   = r_seq_sdp2_sto;
    assign o_seq_sdm1_sta   = r_seq_sdm1_sta;
    assign o_seq_sdm1_sto   = r_seq_sdm1_sto;
    assign o_seq_sdm2_sta   = r_seq_sdm2_sta;
    assign o_seq_sdm2_sto   = r_seq_sdm2_sto;
    assign o_seq_adc        = r_seq_adc;

    assign o_intenab  = r_intenab;
    assign o_intr_clr = r_intr;

endmodule