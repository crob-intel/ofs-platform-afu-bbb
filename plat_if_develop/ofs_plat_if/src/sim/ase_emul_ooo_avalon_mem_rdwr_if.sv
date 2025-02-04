// Copyright (C) 2022 Intel Corporation
// SPDX-License-Identifier: MIT

//
// Emulate an out of order Avalon port by swapping the order of responses randomly.
//

`include "ofs_plat_if.vh"

module ase_emul_ooo_avalon_mem_rdwr_if
  #(
    // Are responses out of order?
    parameter OUT_OF_ORDER = 0
    )
   (
    ofs_plat_avalon_mem_rdwr_if.to_sink mem_sink,
    ofs_plat_avalon_mem_rdwr_if.to_source_clk mem_source
    );
            
    localparam DATA_WIDTH = mem_sink.DATA_WIDTH_;
    localparam RESPONSE_WIDTH = mem_sink.RESPONSE_WIDTH_;
    localparam USER_WIDTH = mem_sink.USER_WIDTH_;

    generate
        if (OUT_OF_ORDER == 0)
        begin : n
            // Not out of order
            ofs_plat_avalon_mem_rdwr_if_connect_sink_clk conn
               (
                .mem_sink,
                .mem_source
                );
        end
        else
        begin : o
            assign mem_source.clk = mem_sink.clk;
            assign mem_source.reset_n = mem_sink.reset_n;
            assign mem_source.instance_number = mem_sink.instance_number;

            always_comb
            begin
                `OFS_PLAT_AVALON_MEM_RDWR_IF_FROM_SOURCE_TO_SINK_COMB(mem_sink, mem_source);

                mem_source.rd_waitrequest = mem_sink.rd_waitrequest;
                mem_source.wr_waitrequest = mem_sink.wr_waitrequest;
            end

            ase_emul_ooo_pipe
              #(
                .DATA_WIDTH(DATA_WIDTH + RESPONSE_WIDTH + USER_WIDTH + 1)
                )
              rd_ooo
               (
                .clk(mem_sink.clk),
                .reset_n(mem_sink.reset_n),
                .data_in({ mem_sink.rd_readdata,
                           mem_sink.rd_response,
                           mem_sink.rd_readresponseuser,
                           mem_sink.rd_readdatavalid }),
                .data_out({ mem_source.rd_readdata,
                            mem_source.rd_response,
                            mem_source.rd_readresponseuser,
                            mem_source.rd_readdatavalid })
                );

            ase_emul_ooo_pipe
              #(
                .DATA_WIDTH(RESPONSE_WIDTH + USER_WIDTH + 1)
                )
              wr_ooo
               (
                .clk(mem_sink.clk),
                .reset_n(mem_sink.reset_n),
                .data_in({ mem_sink.wr_response,
                           mem_sink.wr_writeresponseuser,
                           mem_sink.wr_writeresponsevalid }),
                .data_out({ mem_source.wr_response,
                            mem_source.wr_writeresponseuser,
                            mem_source.wr_writeresponsevalid })
                );
        end
    endgenerate

endmodule // ase_emul_ooo_avalon_mem_rdwr_if


module ase_emul_ooo_pipe
  #(
    parameter DATA_WIDTH = 0
    )
   (
    input  logic clk,
    input  logic reset_n,
    input  logic [DATA_WIDTH-1 : 0] data_in,
    output logic [DATA_WIDTH-1 : 0] data_out
    );

    // Rotate "random" number generator
    logic [19:0] rnd;
    always_ff @(posedge clk)
    begin
        rnd <= { rnd[18:0], rnd[19] };

        if (!reset_n)
        begin
            rnd <= 20'h8676d;
        end
    end

    // There is no flow control. Keep data_in flowing into the queue, replacing
    // either q0 or q1 randomly.

    typedef logic [DATA_WIDTH-1 : 0] t_data;
    t_data q0, q1;

    always_ff @(posedge clk)
    begin
        if (rnd[0])
        begin
            q0 <= data_in;
            data_out <= q0;
        end
        else
        begin
            q1 <= data_in;
            data_out <= q1;
        end

        if (!reset_n)
        begin
            q0[0] <= 1'b0;
            q1[0] <= 1'b0;
            data_out[0] <= 1'b0;
        end
    end

endmodule // ase_emul_ooo_pipe
