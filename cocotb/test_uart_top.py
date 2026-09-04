"""
cocotb testbench for uart_top, driven through the uart_top_loopback wrapper.

Mirrors the coverage of tb/tb_uart_top.sv -- reset state, single-byte round
trips, back-to-back streaming with a scoreboard, TX FIFO fill, and RX FIFO
fill + overrun -- written in Python as a second, independent check of the
same integration rather than a replacement for the SystemVerilog testbench.
"""

import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, ReadOnly, RisingEdge

# Mirrors uart_top_loopback's fixed configuration (uart_top's own defaults,
# except FIFO depth -- see uart_top_loopback.sv's header comment for why
# those default small here): CLK_FREQ_HZ=50_000_000, BAUD_RATE=115_200,
# DATA_BITS=8, no parity, STOP_BITS=1, OVERSAMPLE=16.
CLK_FREQ_HZ = 50_000_000
BAUD_RATE = 115_200
OVERSAMPLE = 16
DATA_BITS = 8
STOP_BITS = 1
TX_FIFO_DEPTH = 4
RX_FIFO_DEPTH = 4

CLK_PERIOD_NS = 20  # 1 / 50 MHz

# Mirrors baud_rate_gen's own round-to-nearest divisor calculation, so this
# test can size its wait/timeout windows without peeking into the DUT.
_BAUD_X_OS = BAUD_RATE * OVERSAMPLE
DIVISOR_X16 = (CLK_FREQ_HZ + _BAUD_X_OS // 2) // _BAUD_X_OS
BIT_PERIOD_CLKS = DIVISOR_X16 * OVERSAMPLE
FRAME_CLKS = BIT_PERIOD_CLKS * (1 + DATA_BITS + STOP_BITS)  # start + data + stop


async def start_clock(dut):
    cocotb.start_soon(Clock(dut.clk_i, CLK_PERIOD_NS, unit="ns").start())


async def reset_dut(dut):
    dut.rst_ni.value = 0
    dut.tx_wdata_i.value = 0
    dut.tx_wr_en_i.value = 0
    dut.rx_rd_en_i.value = 0
    await ClockCycles(dut.clk_i, 5)
    dut.rst_ni.value = 1
    await ClockCycles(dut.clk_i, 5)


async def tx_send(dut, data):
    """Waits for tx_ready_o, then issues a one-cycle write handshake."""
    await RisingEdge(dut.clk_i)
    while not dut.tx_ready_o.value:
        await RisingEdge(dut.clk_i)
    dut.tx_wdata_i.value = data
    dut.tx_wr_en_i.value = 1
    await RisingEdge(dut.clk_i)
    dut.tx_wr_en_i.value = 0
    # Let the TX FIFO's own logic (tx_ready_o/tx_full_o/tx_busy_o) settle
    # into this timestep's final value before a caller reads it right after
    # this returns -- reading immediately after RisingEdge can otherwise
    # observe a value from before this edge's updates have all applied.
    await ReadOnly()


async def rx_recv(dut, max_cycles):
    """Waits for rx_valid_o, captures the byte + error flags, then acks it.

    Returns None on timeout, else a dict with data/overrun/framing_err/parity_err.
    """
    for _ in range(max_cycles):
        await RisingEdge(dut.clk_i)
        if dut.rx_valid_o.value:
            result = {
                "data": int(dut.rx_rdata_o.value),
                "overrun": bool(dut.rx_overrun_o.value),
                "framing_err": bool(dut.rx_framing_err_o.value),
                "parity_err": bool(dut.rx_parity_err_o.value),
            }
            dut.rx_rd_en_i.value = 1
            await RisingEdge(dut.clk_i)
            dut.rx_rd_en_i.value = 0
            # See the matching note in tx_send above.
            await ReadOnly()
            return result
    return None


async def round_trip(dut, data):
    tx_task = cocotb.start_soon(tx_send(dut, data))
    result = await rx_recv(dut, FRAME_CLKS * 3)
    await tx_task

    assert result is not None, f"rx_valid_o never pulsed for 0x{data:02x}"
    assert result["data"] == data, f"got 0x{result['data']:02x}, expected 0x{data:02x}"
    assert not result["overrun"], f"unexpected overrun for 0x{data:02x}"
    assert not result["framing_err"], f"unexpected framing error for 0x{data:02x}"
    assert not result["parity_err"], f"unexpected parity error for 0x{data:02x}"


@cocotb.test()
async def test_reset(dut):
    """Every status signal should be in its idle state right out of reset."""
    await start_clock(dut)
    await reset_dut(dut)

    assert dut.tx_ready_o.value == 1, "tx_ready_o not high out of reset"
    assert dut.tx_full_o.value == 0, "tx_full_o high out of reset"
    assert dut.tx_busy_o.value == 0, "tx_busy_o high out of reset"
    assert dut.rx_valid_o.value == 0, "rx_valid_o high out of reset"
    assert dut.rx_empty_o.value == 1, "rx_empty_o not high out of reset"
    assert dut.rx_full_o.value == 0, "rx_full_o high out of reset"
    assert dut.rx_busy_o.value == 0, "rx_busy_o high out of reset"
    assert dut.rx_overrun_o.value == 0, "rx_overrun_o high out of reset"


@cocotb.test()
async def test_round_trip(dut):
    """Single bytes sent through the loopback should come back unchanged."""
    await start_clock(dut)
    await reset_dut(dut)

    for data in (0x00, 0xFF, 0xA5, 0x3C, 0x81):
        await round_trip(dut, data)

    random.seed(0)
    for _ in range(5):
        await round_trip(dut, random.randint(0, 255))


@cocotb.test()
async def test_streaming(dut):
    """20 back-to-back bytes must arrive in order, with no error flags."""
    await start_clock(dut)
    await reset_dut(dut)

    random.seed(1)
    n = 20
    expected = [random.randint(0, 255) for _ in range(n)]
    received = []

    async def writer():
        for b in expected:
            await tx_send(dut, b)

    async def reader():
        for _ in range(n):
            result = await rx_recv(dut, FRAME_CLKS * 4)
            assert result is not None, "byte never arrived during streaming"
            assert not (result["overrun"] or result["framing_err"] or result["parity_err"]), \
                f"unexpected error flags during streaming: {result}"
            received.append(result["data"])

    writer_task = cocotb.start_soon(writer())
    await reader()
    await writer_task

    assert received == expected, f"streaming mismatch: got {received}, expected {expected}"


@cocotb.test()
async def test_tx_fifo_full(dut):
    """Bursting writes faster than transmission drains them should fill the
    TX FIFO, and every byte should still arrive correctly once it drains.

    Writes TX_FIFO_DEPTH+1 bytes, not TX_FIFO_DEPTH: uart_tx has its own
    1-deep internal holding register that eagerly pulls the first byte out
    of the FIFO the moment it's written (well before any baud tick), so the
    FIFO itself only actually reaches "full" once one extra byte is queued
    behind that.
    """
    await start_clock(dut)
    await reset_dut(dut)

    assert dut.tx_full_o.value == 0, "tx_full_o set before the burst started"

    n = TX_FIFO_DEPTH + 1
    expected = [0xC0 + i for i in range(n)]
    for b in expected:
        await tx_send(dut, b)

    assert dut.tx_full_o.value == 1, "tx_full_o not set after filling the TX FIFO"
    assert dut.tx_ready_o.value == 0, "tx_ready_o still high while the TX FIFO is full"
    assert dut.tx_busy_o.value == 1, "tx_busy_o not set while the TX FIFO has queued work"

    received = []
    for _ in range(n):
        result = await rx_recv(dut, FRAME_CLKS * 3)
        assert result is not None, "a burst byte never arrived"
        assert not (result["overrun"] or result["framing_err"] or result["parity_err"]), \
            f"unexpected error flags during TX burst: {result}"
        received.append(result["data"])

    assert received == expected, f"TX burst mismatch: got {received}, expected {expected}"
    assert dut.tx_full_o.value == 0, "tx_full_o still set after everything drained"


@cocotb.test()
async def test_rx_overrun(dut):
    """Filling the RX FIFO exactly to depth with no reads must lose nothing;
    one more byte on top of that overflows it. The dropped byte is the new
    arrival, not anything already queued -- the real behavioral difference
    from a single-register design.
    """
    await start_clock(dut)
    await reset_dut(dut)

    assert dut.rx_empty_o.value == 1, "RX FIFO not empty before the test started"

    queued = [0x80 + i for i in range(RX_FIFO_DEPTH)]
    for b in queued:
        await tx_send(dut, b)

    # Give all RX_FIFO_DEPTH frames time to fully land.
    await ClockCycles(dut.clk_i, FRAME_CLKS * (RX_FIFO_DEPTH + 2))

    assert dut.rx_full_o.value == 1, f"RX FIFO not full after {RX_FIFO_DEPTH} unread bytes"
    assert dut.rx_overrun_o.value == 0, "rx_overrun_o set before the FIFO actually overflowed"

    # One more, with the FIFO already full -- this one has nowhere to go.
    await tx_send(dut, 0xFE)
    await ClockCycles(dut.clk_i, FRAME_CLKS * 2)

    assert dut.rx_overrun_o.value == 1, "rx_overrun_o not set after the RX FIFO overflowed"
    assert dut.rx_full_o.value == 1, "RX FIFO unexpectedly not full right after overflow"

    # Drain; the FIFO should hold exactly the original queued bytes, in
    # order -- proof the overflow byte was dropped, not that it overwrote
    # something already queued.
    received = []
    for _ in range(RX_FIFO_DEPTH):
        result = await rx_recv(dut, FRAME_CLKS * 3)
        assert result is not None, "a queued byte never came back"
        received.append(result["data"])

    assert received == queued, f"RX overrun drain mismatch: got {received}, expected {queued}"
    assert dut.rx_empty_o.value == 1, f"RX FIFO not empty after draining exactly {RX_FIFO_DEPTH} bytes"
    assert dut.rx_overrun_o.value == 0, "rx_overrun_o didn't clear after draining"

    # Confirm the link is still healthy afterward.
    await round_trip(dut, 0x42)
