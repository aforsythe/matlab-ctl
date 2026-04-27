// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Alex Forsythe, Academy of Motion Picture Arts and Sciences

// Fixture: CTL with a uniform `scale = 2.0` parameter declared with
// no storage qualifier (defaults to uniform per CTL grammar). Used
// to verify that apply_ctl honors CTL-source defaults on uniform
// main() inputs -- without an explicit setDefaultValue() call in
// the MEX, the live register stays zero-initialized and the
// transform silently returns zeros. Counterpart to
// defaulted_param.ctl which exercises the varying-default path.

void main
(
    input  varying float rIn,
    input  varying float gIn,
    input  varying float bIn,
    output varying float rOut,
    output varying float gOut,
    output varying float bOut,
    input          float scale = 2.0
)
{
    rOut = rIn * scale;
    gOut = gIn * scale;
    bOut = bIn * scale;
}
