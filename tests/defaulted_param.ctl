// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Alex Forsythe, Academy of Motion Picture Arts and Sciences

// Fixture: CTL with an `exposure` parameter that has a CTL-source default.
// Used to verify that get_ctl_signature's pretty-printer classifies
// index>3 inputs with HasDefault as "(defaulted in CTL; override
// optional)". `exposure` lives at the tail of the parameter list because
// CTL requires defaulted parameters to follow all non-defaulted ones.
// Declared `varying` because this CTL implementation only accepts
// default values on varying parameters.

void main
(
    input  varying float rIn,
    input  varying float gIn,
    input  varying float bIn,
    output varying float rOut,
    output varying float gOut,
    output varying float bOut,
    input  varying float exposure = 1.0
)
{
    rOut = rIn * exposure;
    gOut = gIn * exposure;
    bOut = bIn * exposure;
}
