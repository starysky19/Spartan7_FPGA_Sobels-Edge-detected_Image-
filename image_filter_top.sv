`timescale 1ns / 1ps

// Real Digital Boolean board / Spartan-7 XC7S50
// Protocol at 115200 baud, 8-N-1:
//   PC -> FPGA: 0xA5, followed by IMAGE_W*IMAGE_W raw grayscale bytes
//   FPGA -> PC: 0x5A, followed by the same number of Sobel edge bytes
//
// The FPGA performs a 3x3 Sobel edge detector with zero padding.
// For the normal hardware build IMAGE_W=128 and CLKS_PER_BIT=868.

module image_filter_top #(
    parameter integer IMAGE_W = 128,
    parameter integer CLKS_PER_BIT = 868
) (
    input  logic        clk,
    input  logic        btn_reset,   // Boolean board BTN3, active high
    input  logic        uart_rxd,    // UART data from PC
    output logic        uart_txd,    // UART data to PC
    output logic [15:0] led
);

    localparam integer NUM_PIXELS = IMAGE_W * IMAGE_W;
    localparam integer IDX_W = (NUM_PIXELS <= 2) ? 1 : $clog2(NUM_PIXELS);
    localparam integer COUNT_W = (NUM_PIXELS <= 2) ? 1 : $clog2(NUM_PIXELS + 1);

    logic [7:0] image_mem [0:NUM_PIXELS-1];

    logic [7:0] rx_data;
    logic       rx_valid;
    logic [7:0] tx_data;
    logic       tx_start;
    logic       tx_busy;

    uart_rx #(.CLKS_PER_BIT(CLKS_PER_BIT)) u_uart_rx (
        .clk(clk),
        .reset(btn_reset),
        .rx_serial(uart_rxd),
        .rx_data(rx_data),
        .rx_valid(rx_valid)
    );

    uart_tx #(.CLKS_PER_BIT(CLKS_PER_BIT)) u_uart_tx (
        .clk(clk),
        .reset(btn_reset),
        .tx_data(tx_data),
        .tx_start(tx_start),
        .tx_serial(uart_txd),
        .tx_busy(tx_busy)
    );

    typedef enum logic [3:0] {
        WAIT_COMMAND,
        RECEIVE_IMAGE,
        SEND_HEADER_START,
        SEND_HEADER_WAIT_BUSY,
        SEND_HEADER_WAIT_DONE,
        CALC_SETUP,
        CALC_ACCUMULATE,
        SEND_PIXEL_START,
        SEND_PIXEL_WAIT_BUSY,
        SEND_PIXEL_WAIT_DONE
    } state_t;

    state_t state = WAIT_COMMAND;

    logic [COUNT_W-1:0] receive_count = '0;
    logic [IDX_W-1:0] pixel_index = '0;
    logic [3:0] tap_index = 4'd0;
    logic signed [11:0] gx_accumulator = 12'sd0;
    logic signed [11:0] gy_accumulator = 12'sd0;
    logic signed [11:0] gx_sample;
    logic signed [11:0] gy_sample;
    logic signed [11:0] gx_final;
    logic signed [11:0] gy_final;
    logic [11:0] abs_gx;
    logic [11:0] abs_gy;
    logic [12:0] sobel_magnitude;
    logic [7:0] ram_q = 8'd0;

    integer current_row;
    integer current_col;
    integer sample_row;
    integer sample_col;
    integer sample_addr;
    logic sample_in_bounds;

    // Sobel taps in row-major order. Gx detects vertical edges; Gy detects
    // horizontal edges. Signed accumulators preserve gradient direction.
    always_comb begin
        current_row = pixel_index / IMAGE_W;
        current_col = pixel_index % IMAGE_W;
        sample_row = current_row + (tap_index / 3) - 1;
        sample_col = current_col + (tap_index % 3) - 1;
        sample_addr = sample_row * IMAGE_W + sample_col;
        sample_in_bounds = (sample_row >= 0) && (sample_row < IMAGE_W) &&
                           (sample_col >= 0) && (sample_col < IMAGE_W);

        gx_sample = 12'sd0;
        gy_sample = 12'sd0;
        case (tap_index)
            4'd0: begin gx_sample = -$signed({4'd0, ram_q}); gy_sample = -$signed({4'd0, ram_q}); end
            4'd1: begin gx_sample = 12'sd0; gy_sample = -($signed({4'd0, ram_q}) <<< 1); end
            4'd2: begin gx_sample = $signed({4'd0, ram_q}); gy_sample = -$signed({4'd0, ram_q}); end
            4'd3: begin gx_sample = -($signed({4'd0, ram_q}) <<< 1); gy_sample = 12'sd0; end
            4'd4: begin gx_sample = 12'sd0; gy_sample = 12'sd0; end
            4'd5: begin gx_sample = ($signed({4'd0, ram_q}) <<< 1); gy_sample = 12'sd0; end
            4'd6: begin gx_sample = -$signed({4'd0, ram_q}); gy_sample = $signed({4'd0, ram_q}); end
            4'd7: begin gx_sample = 12'sd0; gy_sample = ($signed({4'd0, ram_q}) <<< 1); end
            4'd8: begin gx_sample = $signed({4'd0, ram_q}); gy_sample = $signed({4'd0, ram_q}); end
            default: begin gx_sample = 12'sd0; gy_sample = 12'sd0; end
        endcase
        gx_final = gx_accumulator + gx_sample;
        gy_final = gy_accumulator + gy_sample;
        abs_gx = gx_final[11] ? $unsigned(-gx_final) : $unsigned(gx_final);
        abs_gy = gy_final[11] ? $unsigned(-gy_final) : $unsigned(gy_final);
        // L1 gradient magnitude is hardware-friendly; saturate to 255.
        sobel_magnitude = {1'b0, abs_gx} + {1'b0, abs_gy};
    end

    // UART transfers one byte every ~8680 clocks at 100 MHz.
    // Image storage and filtering happen in separate phases, allowing
    // image_mem to infer a single synchronous-read memory.
    always_ff @(posedge clk) begin
        if (btn_reset) begin
            state <= WAIT_COMMAND;
            receive_count <= '0;
            pixel_index <= '0;
            tap_index <= 4'd0;
            gx_accumulator <= 12'sd0;
            gy_accumulator <= 12'sd0;
            ram_q <= 8'd0;
            tx_data <= 8'd0;
            tx_start <= 1'b0;
        end else begin
            tx_start <= 1'b0;

            case (state)
                WAIT_COMMAND: begin
                    if (rx_valid && rx_data == 8'hA5) begin
                        receive_count <= '0;
                        state <= RECEIVE_IMAGE;
                    end
                end

                RECEIVE_IMAGE: begin
                    if (rx_valid) begin
                        image_mem[receive_count] <= rx_data;
                        if (receive_count == NUM_PIXELS-1) begin
                            pixel_index <= '0;
                            tap_index <= 4'd0;
                            gx_accumulator <= 12'sd0;
                            gy_accumulator <= 12'sd0;
                            state <= SEND_HEADER_START;
                        end else begin
                            receive_count <= receive_count + 1'b1;
                        end
                    end
                end

                SEND_HEADER_START: begin
                    if (!tx_busy) begin
                        tx_data <= 8'h5A;
                        tx_start <= 1'b1;
                        state <= SEND_HEADER_WAIT_BUSY;
                    end
                end

                SEND_HEADER_WAIT_BUSY: begin
                    if (tx_busy)
                        state <= SEND_HEADER_WAIT_DONE;
                end

                SEND_HEADER_WAIT_DONE: begin
                    if (!tx_busy) begin
                        pixel_index <= '0;
                        tap_index <= 4'd0;
                        gx_accumulator <= 12'sd0;
                            gy_accumulator <= 12'sd0;
                        state <= CALC_SETUP;
                    end
                end

                CALC_SETUP: begin
                    // Synchronous memory read. Out-of-image samples are zero.
                    if (sample_in_bounds)
                        ram_q <= image_mem[sample_addr];
                    else
                        ram_q <= 8'd0;

                    state <= CALC_ACCUMULATE;
                end

                CALC_ACCUMULATE: begin
                    if (tap_index == 4'd8) begin
                        // Include the ninth tap in the final gradients.
                        if (sobel_magnitude > 13'd255)
                            tx_data <= 8'd255;
                        else
                            tx_data <= sobel_magnitude[7:0];
                        state <= SEND_PIXEL_START;
                    end else begin
                        gx_accumulator <= gx_accumulator + gx_sample;
                        gy_accumulator <= gy_accumulator + gy_sample;
                        tap_index <= tap_index + 1'b1;
                        state <= CALC_SETUP;
                    end
                end

                SEND_PIXEL_START: begin
                    if (!tx_busy) begin
                        tx_start <= 1'b1;
                        state <= SEND_PIXEL_WAIT_BUSY;
                    end
                end

                SEND_PIXEL_WAIT_BUSY: begin
                    if (tx_busy)
                        state <= SEND_PIXEL_WAIT_DONE;
                end

                SEND_PIXEL_WAIT_DONE: begin
                    if (!tx_busy) begin
                        if (pixel_index == NUM_PIXELS-1) begin
                            state <= WAIT_COMMAND;
                        end else begin
                            pixel_index <= pixel_index + 1'b1;
                            tap_index <= 4'd0;
                            gx_accumulator <= 12'sd0;
                            gy_accumulator <= 12'sd0;
                            state <= CALC_SETUP;
                        end
                    end
                end

                default: state <= WAIT_COMMAND;
            endcase
        end
    end

    // Simple progress/status LEDs:
    // [7:0]   last transmitted filtered value
    // [11:8]  state code
    // [15:12] high bits of receive_count during receive, otherwise zero
    always_comb begin
        led = 16'd0;
        led[11:8] = state;
        led[7:0] = tx_data;
        if (state == RECEIVE_IMAGE)
            led[15:12] = receive_count[COUNT_W-1 -: ((COUNT_W >= 4) ? 4 : COUNT_W)];
    end

endmodule


module uart_rx #(
    parameter integer CLKS_PER_BIT = 868
) (
    input  logic       clk,
    input  logic       reset,
    input  logic       rx_serial,
    output logic [7:0] rx_data,
    output logic       rx_valid
);
    localparam integer CNT_W = (CLKS_PER_BIT <= 2) ? 1 : $clog2(CLKS_PER_BIT + 1);

    typedef enum logic [1:0] {RX_IDLE, RX_START, RX_DATA, RX_STOP} rx_state_t;
    rx_state_t state = RX_IDLE;

    logic rx_meta = 1'b1;
    logic rx_sync = 1'b1;
    logic [CNT_W-1:0] clk_count = '0;
    logic [2:0] bit_index = 3'd0;
    logic [7:0] shift_reg = 8'd0;

    always_ff @(posedge clk) begin
        if (reset) begin
            rx_meta <= 1'b1;
            rx_sync <= 1'b1;
            state <= RX_IDLE;
            clk_count <= '0;
            bit_index <= 3'd0;
            shift_reg <= 8'd0;
            rx_data <= 8'd0;
            rx_valid <= 1'b0;
        end else begin
            rx_meta <= rx_serial;
            rx_sync <= rx_meta;
            rx_valid <= 1'b0;

            case (state)
                RX_IDLE: begin
                    if (!rx_sync) begin
                        clk_count <= (CLKS_PER_BIT / 2);
                        state <= RX_START;
                    end
                end

                RX_START: begin
                    if (clk_count == 0) begin
                        if (!rx_sync) begin
                            clk_count <= CLKS_PER_BIT - 1;
                            bit_index <= 3'd0;
                            state <= RX_DATA;
                        end else begin
                            state <= RX_IDLE;
                        end
                    end else begin
                        clk_count <= clk_count - 1'b1;
                    end
                end

                RX_DATA: begin
                    if (clk_count == 0) begin
                        shift_reg[bit_index] <= rx_sync;
                        clk_count <= CLKS_PER_BIT - 1;
                        if (bit_index == 3'd7)
                            state <= RX_STOP;
                        else
                            bit_index <= bit_index + 1'b1;
                    end else begin
                        clk_count <= clk_count - 1'b1;
                    end
                end

                RX_STOP: begin
                    if (clk_count == 0) begin
                        if (rx_sync) begin
                            rx_data <= shift_reg;
                            rx_valid <= 1'b1;
                        end
                        state <= RX_IDLE;
                    end else begin
                        clk_count <= clk_count - 1'b1;
                    end
                end

                default: state <= RX_IDLE;
            endcase
        end
    end
endmodule


module uart_tx #(
    parameter integer CLKS_PER_BIT = 868
) (
    input  logic       clk,
    input  logic       reset,
    input  logic [7:0] tx_data,
    input  logic       tx_start,
    output logic       tx_serial,
    output logic       tx_busy
);
    localparam integer CNT_W = (CLKS_PER_BIT <= 2) ? 1 : $clog2(CLKS_PER_BIT + 1);

    logic [CNT_W-1:0] clk_count = '0;
    logic [3:0] bit_index = 4'd0;
    logic [9:0] shift_reg = 10'h3FF;

    always_ff @(posedge clk) begin
        if (reset) begin
            clk_count <= '0;
            bit_index <= 4'd0;
            shift_reg <= 10'h3FF;
            tx_serial <= 1'b1;
            tx_busy <= 1'b0;
        end else begin
            if (!tx_busy) begin
                tx_serial <= 1'b1;
                if (tx_start) begin
                    // 10-bit frame: stop, 8 data bits, start.
                    shift_reg <= {1'b1, tx_data, 1'b0};
                    tx_serial <= 1'b0;
                    tx_busy <= 1'b1;
                    clk_count <= CLKS_PER_BIT - 1;
                    bit_index <= 4'd0;
                end
            end else if (clk_count == 0) begin
                if (bit_index == 4'd9) begin
                    tx_serial <= 1'b1;
                    tx_busy <= 1'b0;
                end else begin
                    tx_serial <= shift_reg[1];
                    shift_reg <= {1'b1, shift_reg[9:1]};
                    bit_index <= bit_index + 1'b1;
                    clk_count <= CLKS_PER_BIT - 1;
                end
            end else begin
                clk_count <= clk_count - 1'b1;
            end
        end
    end
endmodule
