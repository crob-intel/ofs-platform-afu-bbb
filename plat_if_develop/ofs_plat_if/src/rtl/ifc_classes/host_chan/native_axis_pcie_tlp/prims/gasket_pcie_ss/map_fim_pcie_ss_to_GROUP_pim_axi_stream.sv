// Copyright (C) 2024 Intel Corporation
// SPDX-License-Identifier: MIT

`include "ofs_plat_if.vh"

//
// Mapping of individual FIM pcie_ss_axis_if to PIM AXI stream interfaces.
//
module map_fim_pcie_ss_to_@group@_pim_axi_stream
   (
    // FIM interfaces
    pcie_ss_axis_if.source pcie_ss_tx_a_st,
    pcie_ss_axis_if.source pcie_ss_tx_b_st,
    pcie_ss_axis_if.sink pcie_ss_rx_a_st,
    pcie_ss_axis_if.sink pcie_ss_rx_b_st,

    // PIM interfaces
    ofs_plat_axi_stream_if.to_source pim_tx_a_st,
    ofs_plat_axi_stream_if.to_source pim_tx_b_st,
    ofs_plat_axi_stream_if.to_sink pim_rx_a_st,
    ofs_plat_axi_stream_if.to_sink pim_rx_b_st
    );

    localparam FIM_PCIE_SEG_WIDTH = ofs_plat_host_chan_@group@_fim_gasket_pkg::TDATA_WIDTH /
                                    ofs_plat_host_chan_@group@_fim_gasket_pkg::NUM_OF_SEG;
    // Segment width in bytes (useful for indexing tkeep as valid bits)
    localparam FIM_PCIE_SEG_BYTES = FIM_PCIE_SEG_WIDTH / 8;

    wire clk = pim_tx_a_st.clk;
    wire reset_n = pim_tx_a_st.reset_n;

    logic pcie_ss_rx_a_is_sop;
    logic pcie_ss_rx_b_is_sop;

    //
    // TX (AFU -> host)
    //
    assign pim_tx_a_st.tready = pcie_ss_tx_a_st.tready;
    assign pcie_ss_tx_a_st.tvalid = pim_tx_a_st.tvalid;

    pcie_ss_hdr_pkg::PCIe_ReqHdr_t tx_a_hdr;
    assign tx_a_hdr = pcie_ss_hdr_pkg::PCIe_ReqHdr_t'(pim_tx_a_st.t.data);

    always_comb
    begin
        pcie_ss_tx_a_st.tlast = pim_tx_a_st.t.last;
        pcie_ss_tx_a_st.tdata = pim_tx_a_st.t.data;
        // Map byte->dword keep bits, dropping 3/4 of them, to save space.
        // Masks are always at the dword level.
        for (int w = 0; w < ofs_plat_host_chan_@group@_fim_gasket_pkg::TDATA_WIDTH/32; w = w + 1)
        begin
            pcie_ss_tx_a_st.tkeep[w*4 +: 4] = {4{pim_tx_a_st.t.keep[w*4]}};
        end

        // Bit 0 of tuser_vendor indicates PU (0) or DM (1) format. The PIM's
        // user data is broken down into PCIe SS segments. For now, we assume
        // that only segment 0 has a header.
        pcie_ss_tx_a_st.tuser_vendor = '0;
        pcie_ss_tx_a_st.tuser_vendor[0] = pim_tx_a_st.t.user[0].dm_mode;
`ifdef OFS_PCIE_SS_CFG_FLAG_TUSER_STORE_COMMIT_REQ
        // When this macro exists, a tuser_vendor must be set in order
        // to get FIM-generated local commits. The PIM expects commits
        // for all stores and interrupts.
        pcie_ss_tx_a_st.tuser_vendor[ofs_pcie_ss_cfg_pkg::TUSER_STORE_COMMIT_REQ_BIT] =
            pim_tx_a_st.t.user[0].sop &&
            (pcie_ss_hdr_pkg::func_is_mwr_req(tx_a_hdr.fmt_type) ||
             pcie_ss_hdr_pkg::func_is_interrupt_req(tx_a_hdr.fmt_type));
`endif
    end

    //
    // TX B (AFU -> host). TX B is a second transmit port. The PIM uses the B
    // port for reads and the primary port for writes and other traffic. This
    // may improve aggregate throughput in multi-VF designs.
    //
    assign pim_tx_b_st.tready = pcie_ss_tx_b_st.tready;
    assign pcie_ss_tx_b_st.tvalid = pim_tx_b_st.tvalid;

    always_comb
    begin
        pcie_ss_tx_b_st.tlast = pim_tx_b_st.t.last;
        pcie_ss_tx_b_st.tdata = pim_tx_b_st.t.data;
        // Map byte->dword keep bits, dropping 3/4 of them, to save space.
        // Masks are always at the dword level.
        for (int w = 0; w < ofs_plat_host_chan_@group@_fim_gasket_pkg::TDATA_WIDTH/32; w = w + 1)
        begin
            pcie_ss_tx_b_st.tkeep[w*4 +: 4] = {4{pim_tx_b_st.t.keep[w*4]}};
        end

        // Bit 0 of tuser_vendor indicates PU (0) or DM (1) format. The PIM's
        // user data is broken down into PCIe SS segments. For now, we assume
        // that only segment 0 has a header.
        pcie_ss_tx_b_st.tuser_vendor = '0;
        pcie_ss_tx_b_st.tuser_vendor[0] = pim_tx_b_st.t.user[0].dm_mode;
    end

    //
    // RX A (host -> AFU)
    //
    assign pcie_ss_rx_a_st.tready = pim_rx_a_st.tready;
    assign pim_rx_a_st.tvalid = pcie_ss_rx_a_st.tvalid;

    always_comb
    begin
        pim_rx_a_st.t = '0;
        pim_rx_a_st.t.last = pcie_ss_rx_a_st.tlast;
        pim_rx_a_st.t.data = pcie_ss_rx_a_st.tdata;
        pim_rx_a_st.t.keep = pcie_ss_rx_a_st.tkeep;

        // The PIM's user field has sop/eop tracking built in. For now, we
        // assume that only PCIe SS segment 0 has a header.
        pim_rx_a_st.t.user = '0;
        pim_rx_a_st.t.user[0].dm_mode = pcie_ss_rx_a_st.tuser_vendor[0];
        pim_rx_a_st.t.user[0].sop = pcie_ss_rx_a_is_sop;

        // Mark at most one EOP. Find the highest segment with a payload and
        // set its EOP bit, using tlast. tlast is currently the only header
        // indicator in the FIM's PCIe SS configuration.
        for (int s = ofs_plat_host_chan_@group@_fim_gasket_pkg::NUM_OF_SEG - 1; s >= 0; s = s - 1)
        begin
            if (pcie_ss_rx_a_st.tkeep[s * FIM_PCIE_SEG_BYTES])
            begin
                pim_rx_a_st.t.user[0].eop = pcie_ss_rx_a_st.tlast;
                break;
            end
        end
    end

    always_ff @(posedge clk)
    begin
        // Is the next RX packet a new SOP?
        if (pcie_ss_rx_a_st.tready && pcie_ss_rx_a_st.tvalid)
        begin
            pcie_ss_rx_a_is_sop <= pcie_ss_rx_a_st.tlast;
        end

        if (!reset_n)
        begin
            pcie_ss_rx_a_is_sop <= 1'b1;
        end
    end

    //
    // RX B (post TX A/B arbitration locally generated write completions -> AFU)
    //
    assign pcie_ss_rx_b_st.tready = pim_rx_b_st.tready;
    assign pim_rx_b_st.tvalid = pcie_ss_rx_b_st.tvalid;

    always_comb
    begin
        pim_rx_b_st.t = '0;
        pim_rx_b_st.t.last = pcie_ss_rx_b_st.tlast;
        pim_rx_b_st.t.data = pcie_ss_rx_b_st.tdata;
        pim_rx_b_st.t.keep = pcie_ss_rx_b_st.tkeep;

        // The PIM's user field has sop/eop tracking built in. For now, we
        // assume that only PCIe SS segment 0 has a header.
        pim_rx_b_st.t.user = '0;
        pim_rx_b_st.t.user[0].dm_mode = pcie_ss_rx_b_st.tuser_vendor[0];
        pim_rx_b_st.t.user[0].sop = pcie_ss_rx_b_is_sop;

        // Mark at most one EOP. Find the highest segment with a payload and
        // set its EOP bit, using tlast. tlast is currently the only header
        // indicator in the FIM's PCIe SS configuration.
        for (int s = ofs_plat_host_chan_@group@_fim_gasket_pkg::NUM_OF_SEG - 1; s >= 0; s = s - 1)
        begin
            if (pcie_ss_rx_b_st.tkeep[s * FIM_PCIE_SEG_BYTES])
            begin
                pim_rx_b_st.t.user[0].eop = pcie_ss_rx_b_st.tlast;
                break;
            end
        end
    end

    always_ff @(posedge clk)
    begin
        // Is the next RX packet a new SOP?
        if (pcie_ss_rx_b_st.tready && pcie_ss_rx_b_st.tvalid)
        begin
            pcie_ss_rx_b_is_sop <= pcie_ss_rx_b_st.tlast;
        end

        if (!reset_n)
        begin
            pcie_ss_rx_b_is_sop <= 1'b1;
        end
    end

endmodule // map_fim_pcie_ss_to_@group@_pim_axi_stream
