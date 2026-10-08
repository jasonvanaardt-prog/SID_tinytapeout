// Replay a SID register trace into the RTL and record the audio.
//
// The trace comes from tools/sid2regs.py, which runs the tune's own 6502
// player code. Every register write is driven over the phi2 bus exactly
// as a C64 would drive it, so what comes out is the design playing the
// tune, not a model of it.
//
// SPDX-FileCopyrightText: 2026 Jason van Aardt
// SPDX-License-Identifier: CERN-OHL-S-2.0

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdint>
#include <vector>
#include <string>
#include <unordered_map>

#include "Vtt_um_sid6581.h"
#include "Vtt_um_sid6581___024root.h"
#include "verilated.h"

static const double PHI2_PAL = 985248.0;
static const int FRAME = 8;          // phi2 cycles per filter sample

// ui_in bit assignments
static const uint8_t CS_N = 0x20, RW = 0x40;

struct Write { uint64_t cycle; uint8_t reg, val; };

static void put32(std::vector<uint8_t> &v, uint32_t x) {
    for (int i = 0; i < 4; i++) v.push_back((x >> (8 * i)) & 0xFF);
}
static void put16(std::vector<uint8_t> &v, uint16_t x) {
    for (int i = 0; i < 2; i++) v.push_back((x >> (8 * i)) & 0xFF);
}

int main(int argc, char **argv) {
    const char *trace_path = nullptr, *wav_path = "sid_tune.wav";
    double seconds = 30.0;
    int decim = 3;
    bool normalize = false;

    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "-o") && i + 1 < argc) wav_path = argv[++i];
        else if (!strcmp(argv[i], "--seconds") && i + 1 < argc) seconds = atof(argv[++i]);
        else if (!strcmp(argv[i], "--decimate") && i + 1 < argc) decim = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--normalize")) normalize = true;
        else trace_path = argv[i];
    }
    if (!trace_path) { fprintf(stderr, "usage: %s trace.txt [-o out.wav] "
                                       "[--seconds S] [--decimate N]\n", argv[0]); return 2; }

    // ---------------------------------------------------------- the trace
    std::vector<Write> writes;
    {
        FILE *f = fopen(trace_path, "r");
        if (!f) { perror(trace_path); return 1; }
        unsigned long long c; unsigned r, v;
        while (fscanf(f, "%llu %x %x", &c, &r, &v) == 3)
            writes.push_back({c, (uint8_t)r, (uint8_t)v});
        fclose(f);
    }
    printf("trace: %zu register writes\n", writes.size());

    // One bus cycle can carry one write; if the 6502 managed two in the
    // same phi2 cycle, push the later one on.
    std::unordered_map<uint64_t, Write> sched;
    sched.reserve(writes.size() * 2);
    for (auto &w : writes) {
        uint64_t c = w.cycle;
        while (sched.count(c)) c++;
        sched[c] = w;
    }

    // ------------------------------------------------------------ the DUT
    Verilated::commandArgs(argc, argv);
    auto *top = new Vtt_um_sid6581;
    auto *root = top->rootp;

    top->ui_in = CS_N | RW;
    top->uio_in = 0;
    top->ena = 1;
    top->rst_n = 0;
    for (int i = 0; i < 16; i++) { top->clk = 1; top->eval(); top->clk = 0; top->eval(); }
    top->rst_n = 1;

    const uint64_t total = (uint64_t)(seconds * PHI2_PAL);
    std::vector<int16_t> samples;
    samples.reserve((size_t)(total / FRAME / decim) + 16);

    int32_t acc = 0; int accn = 0;
    uint64_t next_report = 0;

    for (uint64_t cyc = 0; cyc < total; cyc++) {
        auto it = sched.find(cyc);
        if (it != sched.end()) {
            top->ui_in = (uint8_t)(it->second.reg & 0x1F);   // cs_n=0, rw=0
            top->uio_in = it->second.val;
        } else {
            top->ui_in = CS_N | RW;
            top->uio_in = 0;
        }

        top->clk = 1; top->eval();     // rising edge of phi2
        top->clk = 0; top->eval();     // falling edge: a write latches here

        // uo_out bit 4 is the filter-sample strobe.
        if (top->uo_out & 0x10) {
            int16_t s = (int16_t)root->tt_um_sid6581__DOT__u_core__DOT__u_audio__DOT__audio_o;
            acc += s;
            if (++accn == decim) { samples.push_back((int16_t)(acc / decim)); acc = 0; accn = 0; }
        }

        if (cyc >= next_report) {
            printf("\r  simulating... %5.1f%%", 100.0 * cyc / total);
            fflush(stdout);
            next_report += total / 50;
        }
    }
    printf("\r                                   \r");

    // A SID's output sits well below digital full scale -- the C64 does the
    // amplifying. Optionally scale up so it is comfortable to listen to.
    int32_t rawpeak = 0;
    for (auto s : samples) if (abs(s) > rawpeak) rawpeak = abs(s);
    if (normalize && rawpeak > 0) {
        double g = 26000.0 / rawpeak;
        printf("normalising: peak %d, gain x%.2f\n", rawpeak, g);
        for (auto &s : samples) {
            double v = s * g;
            s = (int16_t)(v > 32767 ? 32767 : (v < -32768 ? -32768 : v));
        }
    }

    // ------------------------------------------------------------ the WAV
    const uint32_t rate = (uint32_t)(PHI2_PAL / FRAME / decim + 0.5);
    std::vector<uint8_t> hdr;
    uint32_t dlen = (uint32_t)(samples.size() * 2);
    const char *r1 = "RIFF"; hdr.insert(hdr.end(), r1, r1 + 4);
    put32(hdr, 36 + dlen);
    const char *r2 = "WAVEfmt "; hdr.insert(hdr.end(), r2, r2 + 8);
    put32(hdr, 16); put16(hdr, 1); put16(hdr, 1);
    put32(hdr, rate); put32(hdr, rate * 2); put16(hdr, 2); put16(hdr, 16);
    const char *r3 = "data"; hdr.insert(hdr.end(), r3, r3 + 4);
    put32(hdr, dlen);

    FILE *f = fopen(wav_path, "wb");
    if (!f) { perror(wav_path); return 1; }
    fwrite(hdr.data(), 1, hdr.size(), f);
    fwrite(samples.data(), 2, samples.size(), f);
    fclose(f);

    int32_t peak = 0; double rms = 0;
    for (auto s : samples) { if (abs(s) > peak) peak = abs(s); rms += (double)s * s; }
    rms = samples.empty() ? 0 : sqrt(rms / samples.size());

    printf("wrote %s: %zu samples at %u Hz = %.2f s, peak %d, rms %.0f\n",
           wav_path, samples.size(), rate, samples.size() / (double)rate, peak, rms);
    delete top;
    return 0;
}
