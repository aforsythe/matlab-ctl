// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Alex Forsythe, Academy of Motion Picture Arts and Sciences

// 2x scaling CTL. Applied after identity.ctl in a two-step chain,
// the combined effect is simply doubling the input -- which proves
// that the MEX pipes output of stage N into input of stage N+1
// correctly.

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
    rOut = rIn * 2.0;
    gOut = gIn * 2.0;
    bOut = bIn * 2.0;
}
