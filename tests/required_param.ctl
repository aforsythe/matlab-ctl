// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Alex Forsythe, Academy of Motion Picture Arts and Sciences

// Fixture: CTL with a non-defaulted uniform parameter (`exposure`)
// that multiplies each channel. Used to verify two paths:
//   1. Calling without providing `exposure` raises with the
//      offending param named.
//   2. Calling with `exposure=N` via apply_ctl's Name=Value form
//      binds the uniform and produces N * in.

void main
(
    input  varying float rIn,
    input  varying float gIn,
    input  varying float bIn,
    input          float exposure,
    output varying float rOut,
    output varying float gOut,
    output varying float bOut
)
{
    rOut = rIn * exposure;
    gOut = gIn * exposure;
    bOut = bIn * exposure;
}
