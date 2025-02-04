// Copyright (C) 2022 Intel Corporation
// SPDX-License-Identifier: MIT

//
// Export the host channel as Avalon interfaces through AXI interfaces,
// testing the helper modules that map AXI Lite to Avalon.
//

`include "ofs_plat_if.vh"

module ofs_plat_afu
   (
    // All platform wires, wrapped in one interface.
    ofs_plat_if plat_ifc
    );

    // ====================================================================
    //
    //  Get an AXI host channel collection from the platform.
    //
    // ====================================================================

    // Host memory AFU master
    ofs_plat_axi_mem_if
      #(
        `HOST_CHAN_AXI_MEM_PARAMS,
        .BURST_CNT_WIDTH(4),
        .LOG_CLASS(ofs_plat_log_pkg::HOST_CHAN)
        )
        host_mem_to_afu();

    // 64 bit read/write MMIO AFU slave
    ofs_plat_axi_mem_lite_if
      #(
        `HOST_CHAN_AXI_MMIO_PARAMS(64),
        .LOG_CLASS(ofs_plat_log_pkg::HOST_CHAN)
        )
        axi_mmio64_to_afu();

    // 512 bit write-only MMIO AFU slave
    ofs_plat_axi_mem_lite_if
      #(
        `HOST_CHAN_AXI_MMIO_PARAMS(512),
        .LOG_CLASS(ofs_plat_log_pkg::HOST_CHAN)
        )
        axi_mmio512_wr_to_afu();

    // Map FIU interface to AXI host memory and both MMIO ports
    ofs_plat_host_chan_as_axi_mem_with_dual_mmio
      #(
        .ADD_CLOCK_CROSSING(1),
        .ADD_TIMING_REG_STAGES(2)
        )
      primary_axi
       (
        .to_fiu(plat_ifc.host_chan.ports[0]),
        .host_mem_to_afu,
        .mmio_to_afu(axi_mmio64_to_afu),
        .mmio_wr_to_afu(axi_mmio512_wr_to_afu),

        // Use user clock
        .afu_clk(plat_ifc.clocks.uClk_usr.clk),
        .afu_reset_n(plat_ifc.clocks.uClk_usr.reset_n)
        );


    // ====================================================================
    //
    //  Map AXI Lite MMIO interfaces to Avalon using PIM shims
    //
    // ====================================================================

    localparam AVALON64_USER_WIDTH = axi_mmio64_to_afu.RID_WIDTH_ +
                                     axi_mmio64_to_afu.USER_WIDTH_;
    localparam AVALON512_USER_WIDTH = axi_mmio512_wr_to_afu.RID_WIDTH_ +
                                      axi_mmio512_wr_to_afu.USER_WIDTH_;

    ofs_plat_avalon_mem_if
      #(
        `HOST_CHAN_AVALON_MMIO_PARAMS(64),
        .USER_WIDTH(AVALON64_USER_WIDTH),
        .LOG_CLASS(ofs_plat_log_pkg::HOST_CHAN)
        )
        mmio64_to_afu();

    assign mmio64_to_afu.instance_number = axi_mmio64_to_afu.instance_number;
    assign mmio64_to_afu.clk = axi_mmio64_to_afu.clk;
    assign mmio64_to_afu.reset_n = axi_mmio64_to_afu.reset_n;


    ofs_plat_axi_mem_lite_if_to_avalon_if
      #(
        .PRESERVE_RESPONSE_USER(0),
        .LOCAL_WR_RESPONSE(1)
        )
      map_avmm_mmio64
       (
        .axi_source(axi_mmio64_to_afu),
        .avmm_sink(mmio64_to_afu)
        );

    ofs_plat_avalon_mem_if
      #(
        `HOST_CHAN_AVALON_MMIO_PARAMS(512),
        .USER_WIDTH(AVALON512_USER_WIDTH),
        .LOG_CLASS(ofs_plat_log_pkg::HOST_CHAN)
        )
        mmio512_wr_to_afu();

    assign mmio512_wr_to_afu.instance_number = axi_mmio512_wr_to_afu.instance_number;
    assign mmio512_wr_to_afu.clk = axi_mmio512_wr_to_afu.clk;
    assign mmio512_wr_to_afu.reset_n = axi_mmio512_wr_to_afu.reset_n;


    ofs_plat_axi_mem_lite_if_to_avalon_if
      #(
        .PRESERVE_RESPONSE_USER(0),
        .LOCAL_WR_RESPONSE(1)
        )
      map_avmm_mmio512
       (
        .axi_source(axi_mmio512_wr_to_afu),
        .avmm_sink(mmio512_wr_to_afu)
        );


    // ====================================================================
    //
    //  Tie off unused ports.
    //
    // ====================================================================

    ofs_plat_if_tie_off_unused
      #(
        // Masks are bit masks, with bit 0 corresponding to port/bank zero.
        // Set a bit in the mask when a port is IN USE by the design.
        // This way, the AFU does not need to know about every available
        // device. By default, devices are tied off.
        .HOST_CHAN_IN_USE_MASK(1)
        )
        tie_off(plat_ifc);


    // ====================================================================
    //
    //  Pass the constructed interfaces to the AFU.
    //
    // ====================================================================

    afu afu
      (
       .mmio64_if(mmio64_to_afu),
       .mmio512_if(mmio512_wr_to_afu)
       );

    // Tie off host memory -- not used by this test
    assign host_mem_to_afu.awvalid = 1'b0;
    assign host_mem_to_afu.wvalid = 1'b0;
    assign host_mem_to_afu.bready = 1'b1;
    assign host_mem_to_afu.arvalid = 1'b0;
    assign host_mem_to_afu.rready = 1'b1;

endmodule // ofs_plat_afu
