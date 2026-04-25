// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Alex Forsythe, Academy of Motion Picture Arts and Sciences

// Trivial identity CTL: apply_ctl(in, identity.ctl) should return a
// bit-exact copy of its input via the MEX -> CTL -> MEX round-trip.
// Any difference implies a marshal, channel-extraction, or shape-
// reconstruction bug in the MEX.

void main
(
    input  varying float rIn,
    input  varying float gIn,
    input  varying float bIn,
    output varying float rOut,
    output varying float gOut,
    output varying float bOut
)
{
    rOut = rIn;
    gOut = gIn;
    bOut = bIn;
}
