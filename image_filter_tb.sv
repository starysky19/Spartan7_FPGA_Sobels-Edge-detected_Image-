`timescale 1ns / 1ps

module image_filter_tb;
    localparam integer IMAGE_W = 4;
    localparam integer NUM_PIXELS = IMAGE_W * IMAGE_W;
    localparam integer CLKS_PER_BIT = 16;
    logic clk = 1'b0;
    logic btn_reset = 1'b1;
    logic uart_rxd = 1'b1;
    logic uart_txd;
    logic [15:0] led;
    logic [7:0] received_byte;
    integer i, r, c, dr, dc, sr, sc, gx, gy, pix, total;

    image_filter_top #(.IMAGE_W(IMAGE_W), .CLKS_PER_BIT(CLKS_PER_BIT)) dut
      (.clk(clk), .btn_reset(btn_reset), .uart_rxd(uart_rxd), .uart_txd(uart_txd), .led(led));
    always #5 clk = ~clk;

    task automatic send_uart_byte(input logic [7:0] value);
      integer k;
      begin
        uart_rxd = 1'b0; repeat (CLKS_PER_BIT) @(posedge clk);
        for (k=0;k<8;k=k+1) begin uart_rxd=value[k]; repeat(CLKS_PER_BIT) @(posedge clk); end
        uart_rxd=1'b1; repeat(CLKS_PER_BIT) @(posedge clk);
      end
    endtask
    task automatic receive_uart_byte(output logic [7:0] value);
      integer k;
      begin
        @(negedge uart_txd); repeat(CLKS_PER_BIT + CLKS_PER_BIT/2) @(posedge clk);
        for(k=0;k<8;k=k+1) begin value[k]=uart_txd; repeat(CLKS_PER_BIT) @(posedge clk); end
        repeat(CLKS_PER_BIT) @(posedge clk);
      end
    endtask
    function automatic [7:0] expected_pixel(input integer rr, input integer cc);
      integer a,b,yy,xx,v,gxx,gyy,mag;
      begin
        gxx=0; gyy=0;
        for(a=-1;a<=1;a=a+1) for(b=-1;b<=1;b=b+1) begin
          yy=rr+a; xx=cc+b; v=0;
          if(yy>=0 && yy<IMAGE_W && xx>=0 && xx<IMAGE_W) v=yy*IMAGE_W+xx+1;
          case ((a+1)*3+(b+1))
            0: begin gxx=gxx-v; gyy=gyy-v; end
            1: gyy=gyy-2*v;
            2: begin gxx=gxx+v; gyy=gyy-v; end
            3: gxx=gxx-2*v;
            5: gxx=gxx+2*v;
            6: begin gxx=gxx-v; gyy=gyy+v; end
            7: gyy=gyy+2*v;
            8: begin gxx=gxx+v; gyy=gyy+v; end
          endcase
        end
        mag=(gxx<0?-gxx:gxx)+(gyy<0?-gyy:gyy);
        expected_pixel=(mag>255)?8'd255:mag[7:0];
      end
    endfunction
    initial begin
      $display("Starting 4x4 UART Sobel edge-detector test.");
      repeat(5) @(posedge clk); btn_reset=1'b0;
      send_uart_byte(8'hA5);
      for(i=0;i<NUM_PIXELS-1;i=i+1) send_uart_byte(i+1);
      fork
        begin receive_uart_byte(received_byte); end
        begin send_uart_byte(NUM_PIXELS); end
      join
      if(received_byte!==8'h5A) $fatal(1,"FAIL: expected header 0x5A, got 0x%02h",received_byte);
      for(i=0;i<NUM_PIXELS;i=i+1) begin
        receive_uart_byte(received_byte); r=i/IMAGE_W; c=i%IMAGE_W;
        if(received_byte!==expected_pixel(r,c)) $fatal(1,"FAIL at (%0d,%0d): got %0d expected %0d",r,c,received_byte,expected_pixel(r,c));
      end
      $display("PASS: All 16 pixels match expected 3x3 Sobel edge magnitudes."); $finish;
    end
    initial begin #100000000; $fatal(1,"TIMEOUT: testbench did not complete."); end
endmodule
