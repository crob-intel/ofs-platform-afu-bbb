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
// Map CCI-P MMIO requests to an Avalon memory channels. The AFU should supply
// the MMIO Avalon master.
//
// The MMIO data width must be a power of 2 between 64 and 512 bits. Addresses
// generated by the master here are to words (DATA_WIDTH). The data width of the
// word will affect the address size. Byteenable will indicate partial-word
// references.
//
// In CCI-P, the minimum addressable size is a DWORD.
//

//
// Standard interface: map CCI-P to a read/write MMIO master that will
// connect to an AFU MMIO slave.
//
module ofs_plat_map_ccip_as_avalon_mmio
  #(
    // When non-zero, add a clock crossing to move the Avalon
    // interface to the clock/reset_n pair passed in afu_clk/afu_reset_n.
    parameter ADD_CLOCK_CROSSING = 0,

    parameter MAX_OUTSTANDING_MMIO_RD_REQS = 64
    )
   (
    // CCI-P interface to FIU MMIO master
    ofs_plat_host_ccip_if.to_fiu to_fiu,

    // Generated Avalon master for connecting to AFU MMIO slave
    ofs_plat_avalon_mem_if.to_slave_clk mmio_to_afu,

    // Used for AFU clock/reset_n when ADD_CLOCK_CROSSING is nonzero
    input  logic afu_clk,
    input  logic afu_reset_n
    );

    ofs_plat_map_ccip_as_avalon_mmio_impl
      #(
        .ADD_CLOCK_CROSSING(ADD_CLOCK_CROSSING),
        .MAX_OUTSTANDING_MMIO_RD_REQS(MAX_OUTSTANDING_MMIO_RD_REQS)
        )
      ofs_av_mmio_impl
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

endmodule // ofs_plat_map_ccip_as_avalon_mmio


//
// Write-only variant of the Avalon MMIO bridge. This can be used for
// connecting to AFU MMIO master's that only receive write requests.
// CCI-P has a 512 bit wide MMIO write request but no corresponding
// wide MMIO read.
//
module ofs_plat_map_ccip_as_avalon_mmio_wo
  #(
    // When non-zero, add a clock crossing to move the AValon
    // interface to the clock/reset_n pair passed in afu_clk/afu_reset_n.
    parameter ADD_CLOCK_CROSSING = 0,

    parameter MAX_OUTSTANDING_MMIO_RD_REQS = 64
    )
   (
    // CCI-P read-only interface to FIU MMIO master
    ofs_plat_host_ccip_if.to_fiu_ro to_fiu,

    // Generated Avalon master for connecting to AFU MMIO slave
    ofs_plat_avalon_mem_if.to_slave_clk mmio_to_afu,

    // Used for AFU clock/reset_n when ADD_CLOCK_CROSSING is nonzero
    input  logic afu_clk,
    input  logic afu_reset_n
    );

    ofs_plat_map_ccip_as_avalon_mmio_impl
      #(
        .ADD_CLOCK_CROSSING(ADD_CLOCK_CROSSING),
        .MAX_OUTSTANDING_MMIO_RD_REQS(MAX_OUTSTANDING_MMIO_RD_REQS),
        .WRITE_ONLY_MODE(1)
        )
      ofs_av_mmio_impl
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

endmodule // ofs_plat_map_ccip_as_avalon_mmio_wo


//
// Internal implementation of the CCI-P to MMIO bridge.
//
module ofs_plat_map_ccip_as_avalon_mmio_impl
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

    ofs_plat_avalon_mem_if.to_slave_clk mmio_to_afu,

    // Used for AFU clock/reset_n when ADD_CLOCK_CROSSING is nonzero
    input  logic afu_clk,
    input  logic afu_reset_n
    );

    logic fclk;
    assign fclk = clk;

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

    // "reset_n" is already synchronous in "fclk", but Quartus sometimes has trouble
    // figuring this out.
    logic reset_n_fclk;
    ofs_plat_prim_clock_crossing_reset_async
      reset_cc
       (
        .clk(fclk),
        .reset_in(reset_n),
        .reset_out(reset_n_fclk)
        );

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
    // Send MMIO requests through a buffering FIFO in case the AFU's MMIO slave
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
    // replications.
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
    logic req_in_fifo_enq_en_fclk;
    assign req_in_fifo_enq_en_fclk = (sRx.c0.mmioRdValid || sRx.c0.mmioWrValid) &&
                                     mmio_req_fits_in_data &&
                                     ! error_fclk;

    ofs_plat_prim_fifo_dc_bram
      #(
        // Simply push the whole data structures through the FIFO.
        // Quartus will remove the parts that wind up not being used.
        .N_DATA_BITS(1 + $bits(t_ccip_clData) + $bits(t_ccip_c0_ReqMmioHdr)),
        .N_ENTRIES(MAX_OUTSTANDING_MMIO_RD_REQS)
        )
      req_in_fifo
       (
        .reset_n(reset_n_fclk),
        .wr_clk(fclk),
        .enq_data({ sRx.c0.mmioWrValid, mmio_in_wr_data_fclk, mmio_in_hdr_fclk }),
        .enq_en(req_in_fifo_enq_en_fclk),
        .notFull(req_in_fifo_notFull_fclk),
        .almostFull(),
        .rd_clk(mmio_to_afu.clk),
        .first({ mmio_is_wr, mmio_wr_data, mmio_hdr }),
        .deq_en(mmio_req_deq),
        .notEmpty(mmio_req_notEmpty)
        );

    //
    // Save tid for MMIO reads. It will be needed when generating the
    // response. Avalon slave responses will be returned in request order.
    //
    logic tid_in_fifo_notFull_fclk;
    logic tid_deq_fclk;
    t_ccip_tid mmio_tid_fclk;
    t_dword_idx dword_idx_fclk;

    generate
        if (WRITE_ONLY_MODE)
        begin : wo
            assign mmio_tid_fclk = t_ccip_tid'(0);
            assign dword_idx_fclk = t_dword_idx'(0);
            assign tid_in_fifo_notFull_fclk = 1'b1;
        end
        else
        begin : wr
            ofs_plat_prim_fifo_bram
              #(
                .N_DATA_BITS($bits(t_dword_idx) + $bits(t_ccip_tid)),
                .N_ENTRIES(MAX_OUTSTANDING_MMIO_RD_REQS)
                )
              tid_in_fifo
               (
                .clk(fclk),
                .reset_n,
                .enq_data({ t_dword_idx'(mmio_in_hdr_fclk.address), mmio_in_hdr_fclk.tid }),
                .enq_en(sRx.c0.mmioRdValid && ! error_fclk),
                .notFull(tid_in_fifo_notFull_fclk),
                .almostFull(),
                .first({ dword_idx_fclk, mmio_tid_fclk }),
                .deq_en(tid_deq_fclk),
                // Must not be empty
                .notEmpty()
                );
        end
    endgenerate

    //
    // Ingress FIFO overflow check. Stop the FIFO if an overflow is detected.
    // This tends to be a far easier failure to debug than when an MMIO request
    // is dropped silently.
    //
    always_ff @(posedge fclk)
    begin
        if (((sRx.c0.mmioRdValid || sRx.c0.mmioWrValid) && ! req_in_fifo_notFull_fclk) ||
            (sRx.c0.mmioRdValid && ! tid_in_fifo_notFull_fclk))
        begin
            error_fclk <= 1'b1;
        end

        if (!reset_n)
        begin
            error_fclk <= !DATA_WIDTH_LEGAL;
        end
    end

    //
    // Generate requests to the MMIO slave.
    //
    assign mmio_to_afu.write = mmio_req_notEmpty && mmio_is_wr;
    assign mmio_to_afu.read = mmio_req_notEmpty && ! mmio_is_wr && ! WRITE_ONLY_MODE;
    assign mmio_to_afu.burstcount = 1;
    // Data has already been formatted properly for the mmio_to_afu word size.
    assign mmio_to_afu.writedata = t_mmio_data'(mmio_wr_data);

    // Drop low address bits. CCI-P's MMIO address space is to DWORDS. The Avalon
    // address space is the index of whatever the MMIO DATA_WIDTH is set to. The
    // low address bits will be reflected in byteenable.
    assign mmio_to_afu.address = mmio_hdr.address[$bits(t_ccip_mmioAddr)-1 : DWORD_IDX_BITS];

    typedef logic [(DATA_WIDTH/32)-1 : 0] t_dword_enable_mask;
    t_dword_enable_mask dword_enable_mask;

    typedef logic [(DATA_WIDTH/8)-1 : 0] t_byteenable;

    // Construct the byteenable mask based on the size and address of the request.
    always_comb
    begin
        // 512 bit access? This step leaves the mask all 1's if 512 bits and all 0's if not.
        dword_enable_mask = mmio_hdr.length[1] ? ~t_dword_enable_mask'(0) : t_dword_enable_mask'(0);

        // Now account for a 32 or 64 bit access. The mask here is one bit per 32 data
        // bits, since the minimum CCI-P reference encoding is 32 bits. This DWORD mask
        // will be expanded to the byteenable mask below.
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
            mmio_to_afu.byteenable[4*i +: 4] = {4{dword_enable_mask[i]}};
        end
    end

    // Forward read responses back to CCI-P.
    logic mmio_rd_valid_fclk;
    t_mmio_data mmio_readdata_fclk;
    assign tid_deq_fclk = mmio_rd_valid_fclk;

    always_ff @(posedge fclk)
    begin
        c2Tx.mmioRdValid <= mmio_rd_valid_fclk;
        c2Tx.hdr.tid <= mmio_tid_fclk;

        c2Tx.data <= mmio_readdata_fclk;
        if (dword_idx_fclk[0])
        begin
            c2Tx.data[31:0] <= mmio_readdata_fclk[63:32];
        end

        if (!reset_n)
        begin
            c2Tx.mmioRdValid <= 1'b0;
        end
    end

    generate
        if (ADD_CLOCK_CROSSING == 0)
        begin : c2_nc
            // No clock crossing required
            assign mmio_rd_valid_fclk = mmio_to_afu.readdatavalid;
            assign mmio_readdata_fclk = mmio_to_afu.readdata;
        end
        else
        begin : c2_cc
            // Clock crossing from AFU Avalon master to CCI-P MMIO read response
            logic rsp_out_notEmpty_fclk;
            assign mmio_rd_valid_fclk = rsp_out_notEmpty_fclk;

            ofs_plat_prim_fifo_dc_bram
              #(
                .N_DATA_BITS(DATA_WIDTH),
                .N_ENTRIES(MAX_OUTSTANDING_MMIO_RD_REQS)
                )
            rsp_out_fifo
              (
               .reset_n(reset_n_fclk),
               .wr_clk(mmio_to_afu.clk),
               .enq_data(mmio_to_afu.readdata),
               .enq_en(mmio_to_afu.readdatavalid),
               .notFull(),
               .almostFull(),
               .rd_clk(fclk),
               .first(mmio_readdata_fclk),
               .deq_en(rsp_out_notEmpty_fclk),
               .notEmpty(rsp_out_notEmpty_fclk)
               );
        end
    endgenerate

    //
    // Consume requests once they are accepted by the Avalon slave.
    //
    assign mmio_req_deq = ! mmio_to_afu.waitrequest && mmio_req_notEmpty;

endmodule // ofs_plat_map_ccip_as_avalon_mmio
