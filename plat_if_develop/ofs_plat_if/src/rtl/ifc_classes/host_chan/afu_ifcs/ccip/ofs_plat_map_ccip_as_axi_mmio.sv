//
// Copyright (c) 2019, Intel Corporation
// All rights reserved.
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions are met:
//
// Redistributions of source code must retain the above copyright notice, this
// list of conditions and the following disclaimer.
//
// Redistributions in binary form must reproduce the above copyright notice,
// this list of conditions and the following disclaimer in the documentation
// and/or other materials provided with the distribution.
//
// Neither the name of the Intel Corporation nor the names of its contributors
// may be used to endorse or promote products derived from this software
// without specific prior written permission.
//
// THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
// AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
// IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
// ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE
// LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
// CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
// SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
// INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
// CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
// ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
// POSSIBILITY OF SUCH DAMAGE.

`include "ofs_plat_if.vh"

//
// Map CCI-P MMIO requests to an AXI memory channels. The AFU should supply
// the MMIO AXI source.
//
// The MMIO data width must be a power of 2 between 64 and 512 bits. Addresses
// generated by the source here are to bytes, independent of DATA_WIDTH.
// This is different from the Avalon implementation, which adjusts the
// address size to match the data size. AXI Lite has no byte mask on reads,
// making the Avalon-style encoding impossible.
//
// In CCI-P, the minimum addressable size is a DWORD. Consequently, the
// low 2 address bits in the AXI MMIO channel will always be 0 in this
// implementation.
//

//
// Standard interface: map CCI-P to a read/write MMIO source that will
// connect to an AFU MMIO sink.
//
module ofs_plat_map_ccip_as_axi_mmio
  #(
    // When non-zero, add a clock crossing to move the AXI
    // interface to the clock/reset_n pair passed in afu_clk/afu_reset_n.
    parameter ADD_CLOCK_CROSSING = 0,

    parameter MAX_OUTSTANDING_MMIO_RD_REQS = 64
    )
   (
    // CCI-P interface to FIU MMIO source
    ofs_plat_host_ccip_if.to_fiu to_fiu,

    // Generated AXI source for connecting to AFU MMIO sink
    ofs_plat_axi_mem_lite_if.to_sink_clk mmio_to_afu,

    // Used for AFU clock/reset_n when ADD_CLOCK_CROSSING is nonzero
    input  logic afu_clk,
    input  logic afu_reset_n
    );

    ofs_plat_map_ccip_as_axi_mmio_impl
      #(
        .ADD_CLOCK_CROSSING(ADD_CLOCK_CROSSING),
        .MAX_OUTSTANDING_MMIO_RD_REQS(MAX_OUTSTANDING_MMIO_RD_REQS)
        )
      ofs_axi_mmio_impl
       (
        .clk(to_fiu.clk),
        .reset_n(to_fiu.reset_n),
        .instance_number(to_fiu.instance_number),
        .sRx(to_fiu.sRx),
        .c2Tx(to_fiu.sTx.c2),
        .mmio_to_afu,
        .afu_clk,
        .afu_reset_n
        );

    assign to_fiu.sTx.c0 = t_if_ccip_c0_Tx'(0);
    assign to_fiu.sTx.c1 = t_if_ccip_c1_Tx'(0);

endmodule // ofs_plat_map_ccip_as_axi_mmio


//
// Write-only variant of the AXI MMIO bridge. This can be used for
// connecting to AFU MMIO source's that only receive write requests.
// CCI-P has a 512 bit wide MMIO write request but no corresponding
// wide MMIO read.
//
module ofs_plat_map_ccip_as_axi_mmio_wo
  #(
    // When non-zero, add a clock crossing to move the AXI
    // interface to the clock/reset_n pair passed in afu_clk/afu_reset_n.
    parameter ADD_CLOCK_CROSSING = 0,

    parameter MAX_OUTSTANDING_MMIO_RD_REQS = 64
    )
   (
    // CCI-P read-only interface to FIU MMIO source
    ofs_plat_host_ccip_if.to_fiu_ro to_fiu,

    // Generated AXI source for connecting to AFU MMIO sink
    ofs_plat_axi_mem_lite_if.to_sink_clk mmio_to_afu,

    // Used for AFU clock/reset_n when ADD_CLOCK_CROSSING is nonzero
    input  logic afu_clk,
    input  logic afu_reset_n
    );

    ofs_plat_map_ccip_as_axi_mmio_impl
      #(
        .ADD_CLOCK_CROSSING(ADD_CLOCK_CROSSING),
        .MAX_OUTSTANDING_MMIO_RD_REQS(MAX_OUTSTANDING_MMIO_RD_REQS),
        .WRITE_ONLY_MODE(1)
        )
      ofs_axi_mmio_impl
       (
        .clk(to_fiu.clk),
        .reset_n(to_fiu.reset_n),
        .instance_number(to_fiu.instance_number),
        .sRx(to_fiu.sRx),
        .c2Tx(),
        .mmio_to_afu,
        .afu_clk,
        .afu_reset_n
        );

endmodule // ofs_plat_map_ccip_as_axi_mmio_wo


//
// Internal implementation of the CCI-P to MMIO bridge.
//
module ofs_plat_map_ccip_as_axi_mmio_impl
  #(
    parameter ADD_CLOCK_CROSSING = 0,
    parameter MAX_OUTSTANDING_MMIO_RD_REQS = 64,
    parameter WRITE_ONLY_MODE = 0
    )
   (
    input  logic clk,
    input  logic reset_n,
    input  int unsigned instance_number,
    input  t_if_ccip_Rx sRx,
    output t_if_ccip_c2_Tx c2Tx,

    ofs_plat_axi_mem_lite_if.to_sink_clk mmio_to_afu,

    // Used for AFU clock/reset_n when ADD_CLOCK_CROSSING is nonzero
    input  logic afu_clk,
    input  logic afu_reset_n
    );

    logic fclk;
    assign fclk = clk;
    logic freset_n;
    assign freset_n = reset_n;

    localparam ADDR_WIDTH = mmio_to_afu.ADDR_WIDTH_;
    typedef logic [ADDR_WIDTH-1 : 0] t_mmio_addr;
    localparam DATA_WIDTH = mmio_to_afu.DATA_WIDTH_;
    typedef logic [DATA_WIDTH-1 : 0] t_mmio_data;

    localparam DATA_WIDTH_LEGAL = (DATA_WIDTH >= 64) && (DATA_WIDTH <= 512) &&
                                  (DATA_WIDTH == (2 ** $clog2(DATA_WIDTH)));
    // synthesis translate_off
    initial
    begin : error_proc
        if (! DATA_WIDTH_LEGAL)
            $fatal(2, "** ERROR ** %m: Data width (%0d) must be a power of 2 between 64 and 512.", DATA_WIDTH);
    end
    // synthesis translate_on

    assign mmio_to_afu.clk = (ADD_CLOCK_CROSSING == 0) ? fclk : afu_clk;
    assign mmio_to_afu.reset_n = (ADD_CLOCK_CROSSING == 0) ? reset_n : afu_reset_n;
    assign mmio_to_afu.instance_number = instance_number;

    // synthesis translate_off
    always_ff @(negedge mmio_to_afu.clk)
    begin
        if (mmio_to_afu.reset_n === 1'bx)
        begin
            $fatal(2, "** ERROR ** %m: mmio_to_afu.reset_n port is uninitialized!");
        end
    end
    // synthesis translate_on

    // Index of the minimum addressable size (32 bit DWORD)
    localparam DWORD_IDX_BITS = $clog2(DATA_WIDTH / 32);
    typedef logic [DWORD_IDX_BITS-1 : 0] t_dword_idx;

    // Cast CCI-P c0 header into ReqMmioHdr
    t_ccip_c0_ReqMmioHdr mmio_in_hdr_fclk;
    assign mmio_in_hdr_fclk = t_ccip_c0_ReqMmioHdr'(sRx.c0.hdr);

    logic error_fclk;

    //
    // Send MMIO requests through a buffering FIFO in case the AFU's MMIO sink
    // asserts waitrequest.
    //
    logic req_in_fifo_notFull_fclk;
    logic mmio_is_wr;
    t_ccip_clData mmio_wr_data;
    t_ccip_c0_ReqMmioHdr mmio_hdr;
    logic mmio_req_deq;
    logic mmio_req_notEmpty;

    // Restructure incoming write data so that 32 and 64 bit writes are replicated
    // throughout, even in a 512 bit MMIO interface. Quartus will drop unused
    // replications. Data replication is required because AXI expects the data
    // positioned in the bus independent of the low address bits.
    t_ccip_clData mmio_in_wr_data_fclk;
    always_comb
    begin
        if (mmio_in_hdr_fclk.length == 2'b00)
            // 32 bit write -- replicate 16 times
            mmio_in_wr_data_fclk = {16{sRx.c0.data[31:0]}};
        else if (mmio_in_hdr_fclk.length == 2'b01)
            // 64 bit write -- replicate 8 times
            mmio_in_wr_data_fclk = {8{sRx.c0.data[63:0]}};
        else
            // Full 512 bit write
            mmio_in_wr_data_fclk = sRx.c0.data;
    end

    // Drop requests that are larger than the data bus size. E.g., 512 bit writes
    // will not be sent to 64 bit interfaces.
    logic mmio_req_fits_in_data;
    generate
        if (DATA_WIDTH <= 32)
            // Accept only 32 bit requests
            assign mmio_req_fits_in_data = (mmio_in_hdr_fclk.length == 2'b00);
        else if (DATA_WIDTH <= 64)
            // Accept 32 and 64 bit requests
            assign mmio_req_fits_in_data = (mmio_in_hdr_fclk.length[1] == 1'b0);
        else
            assign mmio_req_fits_in_data = 1'b1;
    endgenerate

    // New request?
    logic req_in_fifo_enq_en_fclk, req_in_fifo_enq_en_fclk_q;
    assign req_in_fifo_enq_en_fclk =
        ((sRx.c0.mmioRdValid && !WRITE_ONLY_MODE) || sRx.c0.mmioWrValid) &&
        mmio_req_fits_in_data &&
        !error_fclk;

    // Simply push the whole data structures through the FIFO.
    // Quartus will remove the parts that wind up not being used.
    localparam FIFO_IN_WIDTH = 1 + $bits(t_ccip_clData) + $bits(t_ccip_c0_ReqMmioHdr);
    logic [FIFO_IN_WIDTH-1 : 0] req_in_fifo_q;

    always_ff @(posedge fclk)
    begin
        req_in_fifo_q <= { sRx.c0.mmioWrValid, mmio_in_wr_data_fclk, mmio_in_hdr_fclk };
        req_in_fifo_enq_en_fclk_q <= req_in_fifo_enq_en_fclk;
    end

    ofs_plat_prim_fifo_dc
      #(
        .N_DATA_BITS(FIFO_IN_WIDTH),
        .N_ENTRIES(MAX_OUTSTANDING_MMIO_RD_REQS)
        )
      req_in_fifo
       (
        .enq_clk(fclk),
        .enq_reset_n(freset_n),
        .enq_data(req_in_fifo_q),
        .enq_en(req_in_fifo_enq_en_fclk_q),
        .notFull(req_in_fifo_notFull_fclk),
        .almostFull(),
        .deq_clk(mmio_to_afu.clk),
        .deq_reset_n(mmio_to_afu.reset_n),
        .first({ mmio_is_wr, mmio_wr_data, mmio_hdr }),
        .deq_en(mmio_req_deq),
        .notEmpty(mmio_req_notEmpty)
        );

    //
    // Ingress FIFO overflow check. Stop the FIFO if an overflow is detected.
    // This tends to be a far easier failure to debug than when an MMIO request
    // is dropped silently.
    //
    always_ff @(posedge fclk)
    begin
        if ((sRx.c0.mmioRdValid || sRx.c0.mmioWrValid) && !req_in_fifo_notFull_fclk)
        begin
            error_fclk <= 1'b1;
        end

        if (!reset_n)
        begin
            error_fclk <= !DATA_WIDTH_LEGAL;
        end
    end

    // Add low address bits. CCI-P's MMIO address space is to DWORDS. The AXI
    // address space is to bytes.
    t_mmio_addr mmio_req_addr;
    assign mmio_req_addr = { mmio_hdr.address, 2'b0 };

    // Encode the request size
    ofs_plat_axi_mem_pkg::t_axi_log2_beat_size mmio_req_size;
    always_comb
    begin
        case (mmio_hdr.length)
            2'b00: mmio_req_size = 3'b010;	// 4 bytes
            2'b01: mmio_req_size = 3'b011;	// 8 bytes
            2'b10: mmio_req_size = 3'b110;	// 64 bytes
            default: mmio_req_size = '0;
        endcase // case (mmio_hdr.length)
    end


    //
    // Generate requests to the MMIO sink.
    //

    // Consume requests once they are accepted by the AXI sink. Since
    // the write address and data buses check each other below, the
    // ready/valid state of the write data bus can be ignored here.
    assign mmio_req_deq = (mmio_to_afu.arvalid && mmio_to_afu.arready) ||
                          (mmio_to_afu.awvalid && mmio_to_afu.awready);

    // Read
    assign mmio_to_afu.arvalid = mmio_req_notEmpty && !mmio_is_wr && !WRITE_ONLY_MODE;
    always_comb
    begin
        mmio_to_afu.ar = '0;
        mmio_to_afu.ar.id = { mmio_hdr.tid, t_dword_idx'(mmio_hdr.address) };
        mmio_to_afu.ar.addr = mmio_req_addr;
        mmio_to_afu.ar.size = mmio_req_size;
    end

    // Write address -- only mark it valid if write data bus is also ready
    assign mmio_to_afu.awvalid = mmio_req_notEmpty && mmio_is_wr && mmio_to_afu.wready;
    always_comb
    begin
        mmio_to_afu.aw = '0;
        mmio_to_afu.aw.addr = mmio_req_addr;
        mmio_to_afu.aw.size = mmio_req_size;
    end

    // Write data -- only mark it valid if write address bus is also ready
    logic [(DATA_WIDTH/8)-1 : 0] mmio_byte_mask;
    assign mmio_to_afu.wvalid = mmio_req_notEmpty && mmio_is_wr && mmio_to_afu.awready;
    always_comb
    begin
        mmio_to_afu.w = '0;
        mmio_to_afu.w.data = t_mmio_data'(mmio_wr_data);
        mmio_to_afu.w.strb = mmio_byte_mask;
    end

    // Construct the byte mask based on the size and address of the request.
    typedef logic [(DATA_WIDTH/32)-1 : 0] t_dword_enable_mask;
    t_dword_enable_mask dword_enable_mask;

    always_comb
    begin
        // 512 bit access? This step leaves the mask all 1's if 512 bits and all 0's if not.
        dword_enable_mask = mmio_hdr.length[1] ? ~t_dword_enable_mask'(0) : t_dword_enable_mask'(0);

        // Now account for a 32 or 64 bit access. The mask here is one bit per 32 data
        // bits, since the minimum CCI-P reference encoding is 32 bits. This DWORD mask
        // will be expanded to the byte mask below.
        //
        // The index to dword_enable_mask is to 2 bit chunks of the mask, accounting for
        // aligned 64 bit requests. The low bit of t_dword_idx is forced to 0 to
        // guarantee alignment. Even for 32 bit requests, it selects the proper region
        // of dword_enable_mask. The value for the assignment is 2'b11 when masking a
        // 64 bit request and either 2'b10 or 2'b01 for 32 bit requests, depending on
        // which DWORD is being selected.
        //
        // This component is ORed into the mask to merge it with the 512 bit case above.
        dword_enable_mask[t_dword_idx'(mmio_hdr.address) & ~t_dword_idx'(1) +: 2] |=
            (mmio_hdr.length[0] ? 2'b11 : (mmio_hdr.address[0] ? 2'b10 : 2'b01));

        // Expand the dword_enable_mask to a byte enable mask
        for (int i = 0; i < $bits(t_dword_enable_mask); i = i + 1)
        begin : be
            mmio_byte_mask[4*i +: 4] = {4{dword_enable_mask[i]}};
        end
    end

    // Forward read responses back to CCI-P. The response pipeline never blocks.
    assign mmio_to_afu.rready = 1'b1;

    logic mmio_rd_valid_fclk;
    t_dword_idx mmio_rd_dword_idx_fclk, mmio_rd_dword_idx_fclk_q;
    t_ccip_tid mmio_rd_tid_fclk;
    // Read resonse, organized as a vector of 64 bit words
    logic [(DATA_WIDTH/64)-1:0][63:0] mmio_rd_data_fclk;

    t_if_ccip_c2_Tx c2Tx_setup;

    always_ff @(posedge fclk)
    begin
        // First response stage: generate the header and pick the required
        // 64 bit range from the read response. For a 64 bit bus this is
        // just a pipeline stage.
        c2Tx_setup.mmioRdValid <= mmio_rd_valid_fclk;
        c2Tx_setup.hdr.tid <= mmio_rd_tid_fclk;
        c2Tx_setup.data <= mmio_rd_data_fclk[mmio_rd_dword_idx_fclk >> 1];

        // Second stage: pass the read response to c2Tx and select the proper
        // 32 bit data range, if necessary.
        c2Tx <= c2Tx_setup;
        if (mmio_rd_dword_idx_fclk_q[0])
        begin
            c2Tx.data[31:0] <= c2Tx_setup.data[63:32];
        end

        mmio_rd_dword_idx_fclk_q <= mmio_rd_dword_idx_fclk;

        if (!reset_n)
        begin
            c2Tx.mmioRdValid <= 1'b0;
        end
    end

    generate
        if (ADD_CLOCK_CROSSING == 0)
        begin : c2_nc
            // No clock crossing required
            assign mmio_rd_valid_fclk = mmio_to_afu.rvalid;
            assign { mmio_rd_tid_fclk, mmio_rd_dword_idx_fclk } = { '0, mmio_to_afu.r.id };
            assign mmio_rd_data_fclk = mmio_to_afu.r.data;
        end
        else
        begin : c2_cc
            // Clock crossing from AFU AXI source to CCI-P MMIO read response
            logic rsp_out_notEmpty_fclk;
            assign mmio_rd_valid_fclk = rsp_out_notEmpty_fclk;

            ofs_plat_prim_fifo_dc
              #(
                .N_DATA_BITS($bits(t_dword_idx) + $bits(t_ccip_tid) + DATA_WIDTH),
                .N_ENTRIES(MAX_OUTSTANDING_MMIO_RD_REQS)
                )
            rsp_out_fifo
              (
               .enq_clk(mmio_to_afu.clk),
               .enq_reset_n(mmio_to_afu.reset_n),
               .enq_data({ '0, mmio_to_afu.r.id, mmio_to_afu.r.data }),
               .enq_en(mmio_to_afu.rvalid),
               .notFull(),
               .almostFull(),
               .deq_clk(fclk),
               .deq_reset_n(freset_n),
               .first({ {mmio_rd_tid_fclk, mmio_rd_dword_idx_fclk}, mmio_rd_data_fclk }),
               .deq_en(rsp_out_notEmpty_fclk),
               .notEmpty(rsp_out_notEmpty_fclk)
               );
        end
    endgenerate

    // Drop write responses
    assign mmio_to_afu.bready = 1'b1;

endmodule // ofs_plat_map_ccip_as_axi_mmio
