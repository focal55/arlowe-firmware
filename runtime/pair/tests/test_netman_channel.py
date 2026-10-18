"""
Tests for choosing the setup AP channel from the pre-AP scan (issue 298).

A phone cannot join the setup AP when channel 6 is busy, so the channel is no
longer a constant. Contract the implementation must meet:

  netman.pick_ap_channel(rows) -> int
    rows   scan rows, each at least {"chan": int, "signal": int 0-100}; other
           keys are ignored.
    Only channels 1, 6 and 11 are candidates. A row counts toward a candidate
    only if its chan equals it exactly: other 2.4 GHz channels (2-5, 7-10,
    12-14) and every 5 GHz row (chan > 14) are ignored, no nearest-channel
    mapping. Each candidate is scored by (number of rows on it, summed signal
    of those rows), lower is better; a full tie goes to the first of 1, 6, 11.
    An empty scan, or one with no row on 1, 6 or 11, returns 1. The result is
    always one of 1, 6, 11.

  NetMan.scan() rows carry "chan" (int) beside ssid/signal/secure; the nmcli
    field list is SSID,SIGNAL,SECURITY,CHAN. Existing ssid/signal/secure
    parsing and the strongest-row-per-SSID dedupe are unchanged.

  NetMan.ap_up(ssid, psk, channel) puts `802-11-wireless.channel <channel>`
    in the profile; there is no default and no constant 6.

  App: _new_session picks the channel from the pre-AP scan (pick_ap_channel of
    the scan rows; of [] if the scan failed), passes it to ap_up, and records
    it as session.channel; PairingFlow._recover re-raises the AP with
    ap_up(session.ssid, session.psk, session.channel) (see test_flow.py).

Run from repo root:
    PYTHONPATH=runtime:runtime/lib python3 -m pytest runtime/pair/tests/test_netman_channel.py -q
"""

import pytest

from pair import netman


def rows(**by_chan):
    """rows(c1=[92], c6=[67, 70], ...) -> scan rows with those signals."""
    return [{"ssid": "n%s-%d" % (k, i), "chan": int(k[1:]), "signal": s}
            for k, sigs in by_chan.items() for i, s in enumerate(sigs)]


def pick(r):
    return netman.pick_ap_channel(r)


def test_site_data_from_the_issue_picks_channel_1():
    assert pick(rows(c1=[92], c6=[67, 70, 72, 77], c11=[94, 95])) == 1


def test_quiet_channel_11_wins_when_1_and_6_are_busy():
    assert pick(rows(c1=[50, 60], c6=[40, 45, 50], c11=[30])) == 11


def test_quiet_channel_6_wins_when_1_and_11_are_busy():
    assert pick(rows(c1=[50, 60], c6=[80], c11=[30, 40])) == 6


def test_fewest_networks_beats_lower_summed_signal():
    assert pick(rows(c1=[10, 10, 10], c6=[95], c11=[20, 20])) == 6


def test_equal_counts_go_to_the_lowest_summed_signal():
    assert pick(rows(c1=[80, 70], c6=[30, 20], c11=[60, 60])) == 6


def test_equal_counts_lowest_sum_can_be_channel_11():
    assert pick(rows(c1=[90], c6=[70], c11=[40])) == 11


def test_full_tie_goes_to_channel_1():
    assert pick(rows(c1=[50], c6=[50], c11=[50])) == 1


def test_tie_between_6_and_11_goes_to_6():
    assert pick(rows(c1=[90, 90], c6=[50], c11=[50])) == 6


def test_empty_scan_picks_channel_1():
    assert pick([]) == 1


def test_only_5ghz_rows_pick_channel_1():
    assert pick(rows(c36=[90, 80], c149=[70])) == 1


def test_5ghz_rows_do_not_count_against_a_candidate():
    assert pick(rows(c36=[99, 99, 99], c6=[60], c11=[60], c1=[60, 60])) == 6


def test_other_24ghz_channels_are_ignored():
    # 3 and 9 are not candidates and do not count toward 1 or 6
    assert pick(rows(c3=[90, 90], c9=[90, 90], c1=[50], c6=[40], c11=[30])) == 11


def test_only_non_candidate_24ghz_rows_pick_channel_1():
    assert pick(rows(c4=[90], c8=[90], c13=[90])) == 1


@pytest.mark.parametrize("r", [
    [], rows(c1=[1]), rows(c6=[99]), rows(c11=[5, 5]), rows(c1=[9], c6=[9], c11=[9]),
    rows(c2=[50]), rows(c44=[50]),
])
def test_result_is_always_a_candidate_channel(r):
    assert pick(r) in {1, 6, 11}
