module basic_npu #(
    parameter integer DATA_WIDTH = 4,
    parameter integer ACC_WIDTH  = 10,
    parameter integer VECTOR_LEN = 4
)(
    input  wire                  clk,
    input  wire                  rst,
    input  wire                  start,
    input  wire [DATA_WIDTH-1:0] data_in,
    input  wire [DATA_WIDTH-1:0] weight_in,
    input  wire [DATA_WIDTH-1:0] bias_in,
    input  wire                  valid_in,
    output reg  [DATA_WIDTH-1:0] result_out,
    output reg                   valid_out,
    output reg                   busy
);

    localparam [1:0] IDLE     = 2'b00,
                     COMPUTE  = 2'b01,
                     ACTIVATE = 2'b10,
                     DONE     = 2'b11;

    localparam integer COUNT_WIDTH = (VECTOR_LEN <= 1) ? 1 : $clog2(VECTOR_LEN);
    localparam [DATA_WIDTH-1:0] MAX_POS = {1'b0, {(DATA_WIDTH-1){1'b1}}};
    localparam signed [ACC_WIDTH-1:0] SAT_MAX = {{(ACC_WIDTH-DATA_WIDTH){1'b0}}, MAX_POS};

    reg [1:0] state;
    reg [COUNT_WIDTH-1:0] counter;
    reg signed [ACC_WIDTH-1:0] acc_reg;
    reg signed [DATA_WIDTH-1:0] bias_reg;

    // Keep the full signed product width, then sign-extend it to the accumulator.
    wire signed [(2*DATA_WIDTH)-1:0] product;
    wire signed [ACC_WIDTH-1:0] product_ext;
    wire signed [ACC_WIDTH-1:0] bias_ext;
    wire signed [ACC_WIDTH-1:0] biased_acc;

    assign product     = $signed(data_in) * $signed(weight_in);
    assign product_ext = product;
    assign bias_ext    = bias_reg;
    assign biased_acc  = acc_reg + bias_ext;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            state      <= IDLE;
            acc_reg    <= {ACC_WIDTH{1'b0}};
            bias_reg   <= {DATA_WIDTH{1'b0}};
            counter    <= {COUNT_WIDTH{1'b0}};
            result_out <= {DATA_WIDTH{1'b0}};
            valid_out  <= 1'b0;
            busy       <= 1'b0;
        end else begin
            // Default makes valid_out a one-cycle pulse in DONE.
            valid_out <= 1'b0;

            case (state)
                IDLE: begin
                    busy <= 1'b0;
                    if (start) begin
                        bias_reg <= $signed(bias_in);
                        acc_reg  <= {ACC_WIDTH{1'b0}};
                        counter  <= {COUNT_WIDTH{1'b0}};
                        busy     <= 1'b1;
                        state    <= COMPUTE;
                    end
                end

                COMPUTE: begin
                    if (valid_in) begin
                        acc_reg <= acc_reg + product_ext;
                        if (counter == VECTOR_LEN - 1) begin
                            // The final accumulation commits before ACTIVATE executes.
                            state <= ACTIVATE;
                        end else begin
                            counter <= counter + 1'b1;
                        end
                    end
                end

                ACTIVATE: begin
                    // Keep the original pipeline timing without a raw_result register.
                    state <= DONE;
                end

                DONE: begin
                    // ReLU followed by saturation to the largest positive signed value.
                    if (biased_acc < 0) begin
                        result_out <= {DATA_WIDTH{1'b0}};
                    end else if (biased_acc > SAT_MAX) begin
                        result_out <= MAX_POS;
                    end else begin
                        result_out <= biased_acc[DATA_WIDTH-1:0];
                    end
                    valid_out <= 1'b1;
                    busy      <= 1'b0;
                    state     <= IDLE;
                end

                default: begin
                    state     <= IDLE;
                    acc_reg   <= {ACC_WIDTH{1'b0}};
                    counter   <= {COUNT_WIDTH{1'b0}};
                    busy      <= 1'b0;
                    valid_out <= 1'b0;
                end
            endcase
        end
    end

endmodule
