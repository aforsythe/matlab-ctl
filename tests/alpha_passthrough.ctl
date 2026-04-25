// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Alex Forsythe, Academy of Motion Picture Arts and Sciences

// Fixture for alpha handling:
//   - Declares `aIn` as varying float with no default, matching the
//     shape of every ACES v2 IDT. apply_ctl's auto-alpha convention
//     should default this to 1.0 so out == in.
//   - Passing `aIn=v` via apply_ctl's Name=Value form should
//     broadcast v and produce out == v * in.
//   - Declares `aOut` so the MEX's "set every extra output varying"
//     path gets exercised.

void main
(
    input  varying float rIn,
    input  varying float gIn,
    input  varying float bIn,
    input  varying float aIn,
    output varying float rOut,
    output varying float gOut,
    output varying float bOut,
    output varying float aOut
)
{
    rOut = rIn * aIn;
    gOut = gIn * aIn;
    bOut = bIn * aIn;
    aOut = aIn;
}
