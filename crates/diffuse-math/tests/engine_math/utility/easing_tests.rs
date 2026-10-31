//! `EasingTests` — Swift suite `Easing`.

use diffuse_math::simd::simd_compat::Float3;
use diffuse_math::utility::easing::Easing;

const ALL_EASINGS: [Easing; 31] = [
    Easing::Linear,
    Easing::EaseInQuad,
    Easing::EaseOutQuad,
    Easing::EaseInOutQuad,
    Easing::EaseInCubic,
    Easing::EaseOutCubic,
    Easing::EaseInOutCubic,
    Easing::EaseInQuart,
    Easing::EaseOutQuart,
    Easing::EaseInOutQuart,
    Easing::EaseInQuint,
    Easing::EaseOutQuint,
    Easing::EaseInOutQuint,
    Easing::EaseInSine,
    Easing::EaseOutSine,
    Easing::EaseInOutSine,
    Easing::EaseInExpo,
    Easing::EaseOutExpo,
    Easing::EaseInOutExpo,
    Easing::EaseInCirc,
    Easing::EaseOutCirc,
    Easing::EaseInOutCirc,
    Easing::EaseInElastic,
    Easing::EaseOutElastic,
    Easing::EaseInOutElastic,
    Easing::EaseInBack,
    Easing::EaseOutBack,
    Easing::EaseInOutBack,
    Easing::EaseInBounce,
    Easing::EaseOutBounce,
    Easing::EaseInOutBounce,
];

// "linear maps t to itself" (parameterized: (t, expected))
#[test]
fn linear_easing() {
    let cases: [(f32, f32); 5] = [
        (0.0, 0.0),
        (0.25, 0.25),
        (0.5, 0.5),
        (0.75, 0.75),
        (1.0, 1.0),
    ];
    for (t, expected) in cases {
        assert_eq!(Easing::Linear.evaluate(t), expected, "t = {t}");
    }
}

// "evaluate clamps input to [0,1]"
#[test]
fn evaluate_clamps_input() {
    assert_eq!(Easing::Linear.evaluate(-0.5), 0.0);
    assert_eq!(Easing::Linear.evaluate(1.5), 1.0);
}

// "ease at 0 is always 0"
#[test]
fn ease_at_zero() {
    for easing in ALL_EASINGS {
        assert_eq!(easing.evaluate(0.0), 0.0, "{easing:?} at t=0 should be 0");
    }
}

// "ease at 1 is always 1"
#[test]
fn ease_at_one() {
    for easing in ALL_EASINGS {
        assert_eq!(easing.evaluate(1.0), 1.0, "{easing:?} at t=1 should be 1");
    }
}

// "easeOut inverts easeIn at t=0.5"
#[test]
fn ease_out_inverts_ease_in() {
    let pairs: [(Easing, Easing); 6] = [
        (Easing::EaseInQuad, Easing::EaseOutQuad),
        (Easing::EaseInCubic, Easing::EaseOutCubic),
        (Easing::EaseInQuart, Easing::EaseOutQuart),
        (Easing::EaseInSine, Easing::EaseOutSine),
        (Easing::EaseInExpo, Easing::EaseOutExpo),
        (Easing::EaseInCirc, Easing::EaseOutCirc),
    ];
    for (ease_in, ease_out) in pairs {
        let v = ease_in.evaluate(0.3);
        let inv = 1.0 - ease_out.evaluate(1.0 - 0.3);
        assert!((v - inv).abs() < 0.001, "{ease_in:?} vs {ease_out:?}");
    }
}

// "interpolate scalar spans range"
#[test]
fn interpolate_scalar() {
    assert_eq!(Easing::Linear.interpolate(0.0, 10.0, 0.5), 5.0);
    assert_eq!(Easing::Linear.interpolate(10.0, 0.0, 0.25), 7.5);
}

// "interpolate SIMD3 spans range"
#[test]
fn interpolate_simd3() {
    let from = Float3::new(0.0, 0.0, 0.0);
    let to = Float3::new(4.0, 8.0, 12.0);
    let result = Easing::Linear.interpolate_vector(from, to, 0.5);
    assert_eq!(result, Float3::new(2.0, 4.0, 6.0));
}
