#pragma once
// The colour spaces Kite's maths moves between, in one place: sRGB's transfer function (Theme.swift's
// OKLab steps, the backdrop's CPU reference of Kite.metal) and AppKit's calibrated RGB, which
// NSColor.blended(withFraction:of:) mixes in (the favorites' highlight; later the split pane menu
// button's hover and the theme editor's colour slider).

namespace kite::color {

// sRGB's transfer function, each step in Double as the Mac's Theme.swift does it.
float SrgbToLinear(float c);
// The other way, from a linear value clamped to 0...1 first.
float LinearToSrgb(float c);
// The same in float throughout, as Kite.metal's (and Theme.hlsl's) shader computes it: what the
// backdrop's CPU reference matches, to the bit (Tests/Fixtures/theme-backdrop.json).
float LinearToSrgbShader(float c);

// An sRGB colour with its alpha, components 0...1, not premultiplied.
struct Color {
    float r = 0, g = 0, b = 0, a = 1;
    bool operator==(const Color&) const = default;
};

// NSColor.blended(withFraction:of:): both colours converted to calibrated RGB (Apple's Generic RGB
// profile: its primaries, D65, gamma 1.8; an sRGB colour outside its gamut clipped to it), each
// component and the alpha mixed `fraction` of the way from `a` to `b` there, and the result shown
// in sRGB again. `fraction` is clamped to 0...1, as NSColor clamps it.
// At a fraction of 0 or 1 the result is `a` or `b` clipped to Generic RGB's gamut (a saturated sRGB
// red comes back a little less red). Whether AppKit returns the colour unchanged there instead is
// unconfirmed: check it on the Mac before the theme editor's colour slider relies on it.
Color BlendCalibrated(const Color& a, const Color& b, double fraction);

}  // namespace kite::color
