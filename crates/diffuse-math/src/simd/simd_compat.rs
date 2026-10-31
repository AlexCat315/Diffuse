//! Cross-platform SIMD compatibility layer.
//!
//! Swift's `SIMDCompat` re-exported Apple's `simd` module on Apple platforms and
//! supplied a scalar implementation elsewhere. Rust defines each type once, with
//! the size and alignment Swift actually had (`.migration/simd-layout.json`,
//! MIGRATION.md §5.3). The names registered in MIGRATION.md §8 are `Float2`,
//! `Float3`, `Float4`, the `Double*` and `Int*` variants, `Float3x3`,
//! `Float4x4` and `Quatf`.

use core::fmt;
use core::ops::{Add, AddAssign, Div, DivAssign, Mul, MulAssign, Neg, Sub, SubAssign};

/// `SIMD2<Float>`: 8 bytes, 8-aligned in Swift.
#[repr(C, align(8))]
#[derive(Clone, Copy, Default)]
pub struct Float2 {
    pub x: f32,
    pub y: f32,
}

/// `SIMD3<Float>`: 16 bytes, 16-aligned in Swift; the 4th lane is padding.
#[repr(C, align(16))]
#[derive(Clone, Copy, Default)]
pub struct Float3 {
    pub x: f32,
    pub y: f32,
    pub z: f32,
    /// Layout padding. Never read as a value.
    pub _pad: f32,
}

/// `SIMD4<Float>`: 16 bytes, 16-aligned.
#[repr(C, align(16))]
#[derive(Clone, Copy, Default)]
pub struct Float4 {
    pub x: f32,
    pub y: f32,
    pub z: f32,
    pub w: f32,
}

/// `SIMD2<Double>`: 16 bytes, 16-aligned.
#[repr(C, align(16))]
#[derive(Clone, Copy, Default)]
pub struct Double2 {
    pub x: f64,
    pub y: f64,
}

/// `SIMD3<Double>`: 32 bytes, 16-aligned.
#[repr(C, align(16))]
#[derive(Clone, Copy, Default)]
pub struct Double3 {
    pub x: f64,
    pub y: f64,
    pub z: f64,
    pub _pad: f64,
}

/// `SIMD4<Double>`: 32 bytes, 16-aligned.
#[repr(C, align(16))]
#[derive(Clone, Copy, Default)]
pub struct Double4 {
    pub x: f64,
    pub y: f64,
    pub z: f64,
    pub w: f64,
}

/// `SIMD2<Int32>`: 8 bytes, 8-aligned.
#[repr(C, align(8))]
#[derive(Clone, Copy, Default, PartialEq, Eq)]
pub struct Int2 {
    pub x: i32,
    pub y: i32,
}

/// `SIMD3<Int32>`: 16 bytes, 16-aligned.
#[repr(C, align(16))]
#[derive(Clone, Copy, Default, PartialEq, Eq)]
pub struct Int3 {
    pub x: i32,
    pub y: i32,
    pub z: i32,
    pub _pad: i32,
}

/// `SIMD4<Int32>`: 16 bytes, 16-aligned.
#[repr(C, align(16))]
#[derive(Clone, Copy, Default, PartialEq, Eq)]
pub struct Int4 {
    pub x: i32,
    pub y: i32,
    pub z: i32,
    pub w: i32,
}

/// `SIMD2<UInt32>`: 8 bytes, 8-aligned.
#[repr(C, align(8))]
#[derive(Clone, Copy, Default, PartialEq, Eq)]
pub struct UInt2 {
    pub x: u32,
    pub y: u32,
}

/// `SIMD4<UInt32>`: 16 bytes, 16-aligned.
#[repr(C, align(16))]
#[derive(Clone, Copy, Default, PartialEq, Eq)]
pub struct UInt4 {
    pub x: u32,
    pub y: u32,
    pub z: u32,
    pub w: u32,
}

/// `SIMD4<UInt8>`: 4 bytes, 4-aligned.
#[repr(C, align(4))]
#[derive(Clone, Copy, Default, PartialEq, Eq)]
pub struct UInt8x4(pub [u8; 4]);

/// `SIMD4<UInt16>`: 8 bytes, 8-aligned.
#[repr(C, align(8))]
#[derive(Clone, Copy, Default, PartialEq, Eq)]
pub struct UInt16x4(pub [u16; 4]);

// MIGRATION.md §5.3: these layouts are hard requirements.
const _: () = assert!(core::mem::size_of::<Float2>() == 8 && core::mem::align_of::<Float2>() == 8);
const _: () =
    assert!(core::mem::size_of::<Float3>() == 16 && core::mem::align_of::<Float3>() == 16);
const _: () =
    assert!(core::mem::size_of::<Float4>() == 16 && core::mem::align_of::<Float4>() == 16);
const _: () =
    assert!(core::mem::size_of::<Double2>() == 16 && core::mem::align_of::<Double2>() == 16);
const _: () =
    assert!(core::mem::size_of::<Double3>() == 32 && core::mem::align_of::<Double3>() == 16);
const _: () =
    assert!(core::mem::size_of::<Double4>() == 32 && core::mem::align_of::<Double4>() == 16);
const _: () = assert!(core::mem::size_of::<Int2>() == 8 && core::mem::align_of::<Int2>() == 8);
const _: () = assert!(core::mem::size_of::<Int3>() == 16 && core::mem::align_of::<Int3>() == 16);
const _: () = assert!(core::mem::size_of::<Int4>() == 16 && core::mem::align_of::<Int4>() == 16);
const _: () = assert!(core::mem::size_of::<UInt2>() == 8 && core::mem::align_of::<UInt2>() == 8);
const _: () = assert!(core::mem::size_of::<UInt4>() == 16 && core::mem::align_of::<UInt4>() == 16);
const _: () =
    assert!(core::mem::size_of::<UInt8x4>() == 4 && core::mem::align_of::<UInt8x4>() == 4);
const _: () =
    assert!(core::mem::size_of::<UInt16x4>() == 8 && core::mem::align_of::<UInt16x4>() == 8);

// Swift's `==` on a padded SIMD vector compares lanes only, so the padding must
// stay out of both equality and the debug description.
impl PartialEq for Float3 {
    #[inline]
    fn eq(&self, other: &Self) -> bool {
        self.x == other.x && self.y == other.y && self.z == other.z
    }
}

impl PartialEq for Float4 {
    #[inline]
    fn eq(&self, other: &Self) -> bool {
        self.x == other.x && self.y == other.y && self.z == other.z && self.w == other.w
    }
}

impl PartialEq for Double3 {
    #[inline]
    fn eq(&self, other: &Self) -> bool {
        self.x == other.x && self.y == other.y && self.z == other.z
    }
}

impl PartialEq for Double4 {
    #[inline]
    fn eq(&self, other: &Self) -> bool {
        self.x == other.x && self.y == other.y && self.z == other.z && self.w == other.w
    }
}

impl PartialEq for Float2 {
    #[inline]
    fn eq(&self, other: &Self) -> bool {
        self.x == other.x && self.y == other.y
    }
}

impl PartialEq for Double2 {
    #[inline]
    fn eq(&self, other: &Self) -> bool {
        self.x == other.x && self.y == other.y
    }
}

impl fmt::Debug for Float3 {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_tuple("Float3")
            .field(&self.x)
            .field(&self.y)
            .field(&self.z)
            .finish()
    }
}

impl fmt::Debug for Float4 {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_tuple("Float4")
            .field(&self.x)
            .field(&self.y)
            .field(&self.z)
            .field(&self.w)
            .finish()
    }
}

impl fmt::Debug for Float2 {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_tuple("Float2")
            .field(&self.x)
            .field(&self.y)
            .finish()
    }
}

impl fmt::Debug for Double3 {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_tuple("Double3")
            .field(&self.x)
            .field(&self.y)
            .field(&self.z)
            .finish()
    }
}

impl fmt::Debug for Double4 {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_tuple("Double4")
            .field(&self.x)
            .field(&self.y)
            .field(&self.z)
            .field(&self.w)
            .finish()
    }
}

impl fmt::Debug for Double2 {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_tuple("Double2")
            .field(&self.x)
            .field(&self.y)
            .finish()
    }
}

impl fmt::Debug for Int3 {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_tuple("Int3")
            .field(&self.x)
            .field(&self.y)
            .field(&self.z)
            .finish()
    }
}

impl Float2 {
    pub const ZERO: Float2 = Float2 { x: 0.0, y: 0.0 };
    pub const ONE: Float2 = Float2 { x: 1.0, y: 1.0 };

    #[inline]
    pub const fn new(x: f32, y: f32) -> Self {
        Float2 { x, y }
    }

    /// `SIMD2<Float>(repeating:)`.
    #[inline]
    pub const fn splat(value: f32) -> Self {
        Float2 { x: value, y: value }
    }

    #[inline]
    pub fn sum(self) -> f32 {
        self.x + self.y
    }
}

impl Float3 {
    pub const ZERO: Float3 = Float3 {
        x: 0.0,
        y: 0.0,
        z: 0.0,
        _pad: 0.0,
    };
    pub const ONE: Float3 = Float3 {
        x: 1.0,
        y: 1.0,
        z: 1.0,
        _pad: 0.0,
    };
    /// `SIMD3<Float>(repeating: .infinity)`, the lower bound of `Bounds3D.empty`.
    pub const INFINITY: Float3 = Float3 {
        x: f32::INFINITY,
        y: f32::INFINITY,
        z: f32::INFINITY,
        _pad: 0.0,
    };
    /// `SIMD3<Float>(repeating: -.infinity)`, the upper bound of `Bounds3D.empty`.
    pub const NEG_INFINITY: Float3 = Float3 {
        x: f32::NEG_INFINITY,
        y: f32::NEG_INFINITY,
        z: f32::NEG_INFINITY,
        _pad: 0.0,
    };

    #[inline]
    pub const fn new(x: f32, y: f32, z: f32) -> Self {
        Float3 { x, y, z, _pad: 0.0 }
    }

    /// `SIMD3<Float>(repeating:)`.
    #[inline]
    pub const fn splat(value: f32) -> Self {
        Float3 {
            x: value,
            y: value,
            z: value,
            _pad: 0.0,
        }
    }

    #[inline]
    pub fn sum(self) -> f32 {
        self.x + self.y + self.z
    }
}

impl Float4 {
    pub const ZERO: Float4 = Float4 {
        x: 0.0,
        y: 0.0,
        z: 0.0,
        w: 0.0,
    };
    pub const ONE: Float4 = Float4 {
        x: 1.0,
        y: 1.0,
        z: 1.0,
        w: 1.0,
    };

    #[inline]
    pub const fn new(x: f32, y: f32, z: f32, w: f32) -> Self {
        Float4 { x, y, z, w }
    }

    /// `SIMD4<Float>(repeating:)`.
    #[inline]
    pub const fn splat(value: f32) -> Self {
        Float4 {
            x: value,
            y: value,
            z: value,
            w: value,
        }
    }

    #[inline]
    pub fn sum(self) -> f32 {
        self.x + self.y + self.z + self.w
    }

    /// The `.xyz` swizzle used throughout the Swift code.
    #[inline]
    pub const fn xyz(self) -> Float3 {
        Float3::new(self.x, self.y, self.z)
    }
}

impl Double2 {
    pub const ZERO: Double2 = Double2 { x: 0.0, y: 0.0 };

    #[inline]
    pub const fn new(x: f64, y: f64) -> Self {
        Double2 { x, y }
    }

    #[inline]
    pub fn sum(self) -> f64 {
        self.x + self.y
    }
}

impl Double3 {
    pub const ZERO: Double3 = Double3 {
        x: 0.0,
        y: 0.0,
        z: 0.0,
        _pad: 0.0,
    };

    #[inline]
    pub const fn new(x: f64, y: f64, z: f64) -> Self {
        Double3 { x, y, z, _pad: 0.0 }
    }

    #[inline]
    pub fn sum(self) -> f64 {
        self.x + self.y + self.z
    }
}

impl Double4 {
    pub const ZERO: Double4 = Double4 {
        x: 0.0,
        y: 0.0,
        z: 0.0,
        w: 0.0,
    };

    #[inline]
    pub const fn new(x: f64, y: f64, z: f64, w: f64) -> Self {
        Double4 { x, y, z, w }
    }

    #[inline]
    pub fn sum(self) -> f64 {
        self.x + self.y + self.z + self.w
    }

    #[inline]
    pub const fn xyz(self) -> Double3 {
        Double3::new(self.x, self.y, self.z)
    }
}

macro_rules! impl_vector_ops2 {
    ($t:ident, $s:ty) => {
        impl Add for $t {
            type Output = $t;
            #[inline]
            fn add(self, rhs: $t) -> $t {
                $t::new(self.x + rhs.x, self.y + rhs.y)
            }
        }

        impl Sub for $t {
            type Output = $t;
            #[inline]
            fn sub(self, rhs: $t) -> $t {
                $t::new(self.x - rhs.x, self.y - rhs.y)
            }
        }

        impl Mul for $t {
            type Output = $t;
            #[inline]
            fn mul(self, rhs: $t) -> $t {
                $t::new(self.x * rhs.x, self.y * rhs.y)
            }
        }

        impl Div for $t {
            type Output = $t;
            #[inline]
            fn div(self, rhs: $t) -> $t {
                $t::new(self.x / rhs.x, self.y / rhs.y)
            }
        }

        impl Neg for $t {
            type Output = $t;
            #[inline]
            fn neg(self) -> $t {
                $t::new(-self.x, -self.y)
            }
        }

        impl Mul<$s> for $t {
            type Output = $t;
            #[inline]
            fn mul(self, rhs: $s) -> $t {
                $t::new(self.x * rhs, self.y * rhs)
            }
        }

        impl Div<$s> for $t {
            type Output = $t;
            #[inline]
            fn div(self, rhs: $s) -> $t {
                $t::new(self.x / rhs, self.y / rhs)
            }
        }
    };
}

macro_rules! impl_vector_ops3 {
    ($t:ident, $s:ty) => {
        impl Add for $t {
            type Output = $t;
            #[inline]
            fn add(self, rhs: $t) -> $t {
                $t::new(self.x + rhs.x, self.y + rhs.y, self.z + rhs.z)
            }
        }

        impl Sub for $t {
            type Output = $t;
            #[inline]
            fn sub(self, rhs: $t) -> $t {
                $t::new(self.x - rhs.x, self.y - rhs.y, self.z - rhs.z)
            }
        }

        impl Mul for $t {
            type Output = $t;
            #[inline]
            fn mul(self, rhs: $t) -> $t {
                $t::new(self.x * rhs.x, self.y * rhs.y, self.z * rhs.z)
            }
        }

        impl Div for $t {
            type Output = $t;
            #[inline]
            fn div(self, rhs: $t) -> $t {
                $t::new(self.x / rhs.x, self.y / rhs.y, self.z / rhs.z)
            }
        }

        impl Neg for $t {
            type Output = $t;
            #[inline]
            fn neg(self) -> $t {
                $t::new(-self.x, -self.y, -self.z)
            }
        }

        impl AddAssign for $t {
            #[inline]
            fn add_assign(&mut self, rhs: $t) {
                *self = *self + rhs;
            }
        }

        impl SubAssign for $t {
            #[inline]
            fn sub_assign(&mut self, rhs: $t) {
                *self = *self - rhs;
            }
        }

        impl MulAssign for $t {
            #[inline]
            fn mul_assign(&mut self, rhs: $t) {
                *self = *self * rhs;
            }
        }

        impl DivAssign for $t {
            #[inline]
            fn div_assign(&mut self, rhs: $t) {
                *self = *self / rhs;
            }
        }

        impl Mul<$s> for $t {
            type Output = $t;
            #[inline]
            fn mul(self, rhs: $s) -> $t {
                $t::new(self.x * rhs, self.y * rhs, self.z * rhs)
            }
        }

        impl Div<$s> for $t {
            type Output = $t;
            #[inline]
            fn div(self, rhs: $s) -> $t {
                $t::new(self.x / rhs, self.y / rhs, self.z / rhs)
            }
        }
    };
}

macro_rules! impl_vector_ops4 {
    ($t:ident, $s:ty) => {
        impl Add for $t {
            type Output = $t;
            #[inline]
            fn add(self, rhs: $t) -> $t {
                $t::new(
                    self.x + rhs.x,
                    self.y + rhs.y,
                    self.z + rhs.z,
                    self.w + rhs.w,
                )
            }
        }

        impl Sub for $t {
            type Output = $t;
            #[inline]
            fn sub(self, rhs: $t) -> $t {
                $t::new(
                    self.x - rhs.x,
                    self.y - rhs.y,
                    self.z - rhs.z,
                    self.w - rhs.w,
                )
            }
        }

        impl Mul for $t {
            type Output = $t;
            #[inline]
            fn mul(self, rhs: $t) -> $t {
                $t::new(
                    self.x * rhs.x,
                    self.y * rhs.y,
                    self.z * rhs.z,
                    self.w * rhs.w,
                )
            }
        }

        impl Div for $t {
            type Output = $t;
            #[inline]
            fn div(self, rhs: $t) -> $t {
                $t::new(
                    self.x / rhs.x,
                    self.y / rhs.y,
                    self.z / rhs.z,
                    self.w / rhs.w,
                )
            }
        }

        impl Neg for $t {
            type Output = $t;
            #[inline]
            fn neg(self) -> $t {
                $t::new(-self.x, -self.y, -self.z, -self.w)
            }
        }

        impl AddAssign for $t {
            #[inline]
            fn add_assign(&mut self, rhs: $t) {
                *self = *self + rhs;
            }
        }

        impl SubAssign for $t {
            #[inline]
            fn sub_assign(&mut self, rhs: $t) {
                *self = *self - rhs;
            }
        }

        impl Mul<$s> for $t {
            type Output = $t;
            #[inline]
            fn mul(self, rhs: $s) -> $t {
                $t::new(self.x * rhs, self.y * rhs, self.z * rhs, self.w * rhs)
            }
        }

        impl Div<$s> for $t {
            type Output = $t;
            #[inline]
            fn div(self, rhs: $s) -> $t {
                $t::new(self.x / rhs, self.y / rhs, self.z / rhs, self.w / rhs)
            }
        }
    };
}

impl_vector_ops2!(Float2, f32);
impl_vector_ops3!(Float3, f32);
impl_vector_ops4!(Float4, f32);
impl_vector_ops2!(Double2, f64);
impl_vector_ops3!(Double3, f64);
impl_vector_ops4!(Double4, f64);

// Swift allows `Float * SIMD` in either order; Rust needs the scalar-left form.
macro_rules! impl_scalar_left {
    ($scalar:ty, $t:ident) => {
        impl Mul<$t> for $scalar {
            type Output = $t;
            #[inline]
            fn mul(self, rhs: $t) -> $t {
                rhs * self
            }
        }
    };
}

impl_scalar_left!(f32, Float2);
impl_scalar_left!(f32, Float3);
impl_scalar_left!(f32, Float4);
impl_scalar_left!(f64, Double2);
impl_scalar_left!(f64, Double3);
impl_scalar_left!(f64, Double4);

// MARK: - Free functions

#[inline]
pub fn simd_min2(a: Float2, b: Float2) -> Float2 {
    Float2::new(a.x.min(b.x), a.y.min(b.y))
}

#[inline]
pub fn simd_max2(a: Float2, b: Float2) -> Float2 {
    Float2::new(a.x.max(b.x), a.y.max(b.y))
}

#[inline]
pub fn simd_min4(a: Float4, b: Float4) -> Float4 {
    Float4::new(a.x.min(b.x), a.y.min(b.y), a.z.min(b.z), a.w.min(b.w))
}

#[inline]
pub fn simd_max4(a: Float4, b: Float4) -> Float4 {
    Float4::new(a.x.max(b.x), a.y.max(b.y), a.z.max(b.z), a.w.max(b.w))
}

/// `simd_min` for `SIMD3<Float>`.
#[inline]
pub fn simd_min(a: Float3, b: Float3) -> Float3 {
    Float3::new(a.x.min(b.x), a.y.min(b.y), a.z.min(b.z))
}

/// `simd_max` for `SIMD3<Float>`.
#[inline]
pub fn simd_max(a: Float3, b: Float3) -> Float3 {
    Float3::new(a.x.max(b.x), a.y.max(b.y), a.z.max(b.z))
}

/// `simd_clamp(_ x: Float, _ lo: Float, _ hi: Float)`.
#[inline]
pub fn simd_clamp_scalar(x: f32, lo: f32, hi: f32) -> f32 {
    x.max(lo).min(hi)
}

/// `simd_clamp(_ x: Double, _ lo: Double, _ hi: Double)`.
#[inline]
pub fn simd_clamp_double(x: f64, lo: f64, hi: f64) -> f64 {
    x.max(lo).min(hi)
}

#[inline]
pub fn simd_clamp2(x: Float2, lo: Float2, hi: Float2) -> Float2 {
    simd_min2(simd_max2(x, lo), hi)
}

#[inline]
pub fn simd_clamp(x: Float3, lo: Float3, hi: Float3) -> Float3 {
    simd_min(simd_max(x, lo), hi)
}

#[inline]
pub fn simd_clamp4(x: Float4, lo: Float4, hi: Float4) -> Float4 {
    simd_min4(simd_max4(x, lo), hi)
}

#[inline]
pub fn simd_mix3(x: Float3, y: Float3, t: Float3) -> Float3 {
    x + (y - x) * t
}

#[inline]
pub fn simd_mix_scalar(x: f32, y: f32, t: f32) -> f32 {
    x + (y - x) * t
}

#[inline]
pub fn simd_mix2(x: Float2, y: Float2, t: f32) -> Float2 {
    x + (y - x) * t
}

#[inline]
pub fn simd_mix4(x: Float4, y: Float4, t: Float4) -> Float4 {
    x + (y - x) * t
}

#[inline]
pub fn simd_abs(v: Float3) -> Float3 {
    Float3::new(v.x.abs(), v.y.abs(), v.z.abs())
}

#[inline]
pub fn simd_dot2(a: Float2, b: Float2) -> f32 {
    (a * b).sum()
}

#[inline]
pub fn simd_dot(a: Float3, b: Float3) -> f32 {
    (a * b).sum()
}

#[inline]
pub fn simd_dot4(a: Float4, b: Float4) -> f32 {
    (a * b).sum()
}

#[inline]
pub fn simd_dot_f64_2(a: Double2, b: Double2) -> f64 {
    (a * b).sum()
}

#[inline]
pub fn simd_dot_f64_3(a: Double3, b: Double3) -> f64 {
    (a * b).sum()
}

#[inline]
pub fn simd_dot_f64_4(a: Double4, b: Double4) -> f64 {
    (a * b).sum()
}

#[inline]
pub fn simd_length2(v: Float2) -> f32 {
    (v * v).sum().sqrt()
}

#[inline]
pub fn simd_length(v: Float3) -> f32 {
    (v * v).sum().sqrt()
}

#[inline]
pub fn simd_length4(v: Float4) -> f32 {
    (v * v).sum().sqrt()
}

/// Non-prefixed alias matching Apple simd's `length()` shorthand.
#[inline]
pub fn length(v: Float3) -> f32 {
    simd_length(v)
}

#[inline]
pub fn simd_length_squared2(v: Float2) -> f32 {
    (v * v).sum()
}

#[inline]
pub fn simd_length_squared(v: Float3) -> f32 {
    (v * v).sum()
}

#[inline]
pub fn simd_length_squared4(v: Float4) -> f32 {
    (v * v).sum()
}

#[inline]
pub fn simd_distance2(a: Float2, b: Float2) -> f32 {
    simd_length2(a - b)
}

#[inline]
pub fn simd_distance(a: Float3, b: Float3) -> f32 {
    simd_length(a - b)
}

#[inline]
pub fn simd_distance4(a: Float4, b: Float4) -> f32 {
    simd_length4(a - b)
}

#[inline]
pub fn distance(a: Float3, b: Float3) -> f32 {
    simd_length(a - b)
}

#[inline]
pub fn simd_distance_squared2(a: Float2, b: Float2) -> f32 {
    simd_length_squared2(a - b)
}

#[inline]
pub fn simd_distance_squared(a: Float3, b: Float3) -> f32 {
    simd_length_squared(a - b)
}

#[inline]
pub fn simd_distance_squared4(a: Float4, b: Float4) -> f32 {
    simd_length_squared4(a - b)
}

#[inline]
pub fn simd_normalize2(v: Float2) -> Float2 {
    let len = simd_length2(v);
    if len > 0.0 { v / len } else { v }
}

#[inline]
pub fn simd_normalize(v: Float3) -> Float3 {
    let len = simd_length(v);
    if len > 0.0 { v / len } else { v }
}

#[inline]
pub fn simd_normalize4(v: Float4) -> Float4 {
    let len = simd_length4(v);
    if len > 0.0 { v / len } else { v }
}

#[inline]
pub fn simd_cross(a: Float3, b: Float3) -> Float3 {
    Float3::new(
        a.y * b.z - a.z * b.y,
        a.z * b.x - a.x * b.z,
        a.x * b.y - a.y * b.x,
    )
}

// MARK: - simd_float4x4

/// `simd_float4x4`: 64 bytes, 16-aligned. Storage is column-major.
#[repr(C, align(16))]
#[derive(Clone, Copy)]
pub struct Float4x4 {
    pub columns: [Float4; 4],
}

/// `simd_float3x3`: 48 bytes, 16-aligned. Storage is column-major.
#[repr(C, align(16))]
#[derive(Clone, Copy)]
pub struct Float3x3 {
    pub columns: [Float3; 3],
}

const _: () =
    assert!(core::mem::size_of::<Float4x4>() == 64 && core::mem::align_of::<Float4x4>() == 16);
const _: () =
    assert!(core::mem::size_of::<Float3x3>() == 48 && core::mem::align_of::<Float3x3>() == 16);

impl PartialEq for Float4x4 {
    #[inline]
    fn eq(&self, other: &Self) -> bool {
        self.columns == other.columns
    }
}

impl fmt::Debug for Float4x4 {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_tuple("Float4x4").field(&self.columns).finish()
    }
}

impl Default for Float4x4 {
    fn default() -> Self {
        Self::new()
    }
}

impl Float4x4 {
    /// `simd_float4x4()` — every column zero.
    #[inline]
    pub const fn new() -> Self {
        Float4x4 {
            columns: [Float4::ZERO; 4],
        }
    }

    /// `simd_float4x4(columns:)`.
    #[inline]
    pub const fn from_columns(c: [Float4; 4]) -> Self {
        Float4x4 { columns: c }
    }

    /// `simd_float4x4(_ col0:, _ col1:, _ col2:, _ col3:)`.
    #[inline]
    pub const fn new_with_columns(col0: Float4, col1: Float4, col2: Float4, col3: Float4) -> Self {
        Float4x4 {
            columns: [col0, col1, col2, col3],
        }
    }

    /// `simd_float4x4(diagonal:)`.
    #[inline]
    pub const fn diagonal(d: Float4) -> Self {
        Float4x4 {
            columns: [
                Float4::new(d.x, 0.0, 0.0, 0.0),
                Float4::new(0.0, d.y, 0.0, 0.0),
                Float4::new(0.0, 0.0, d.z, 0.0),
                Float4::new(0.0, 0.0, 0.0, d.w),
            ],
        }
    }

    /// `simd_float4x4(_ scalar:)` — the scalar on the diagonal.
    #[inline]
    pub const fn from_scalar(scalar: f32) -> Self {
        Self::diagonal(Float4::splat(scalar))
    }

    /// `simd_float4x4(rows:)`: each element is a row; storage stays column-major.
    ///
    /// # Panics
    ///
    /// Panics when `rows` does not contain exactly four rows, matching the Swift
    /// `precondition(rows.count == 4)`.
    #[inline]
    pub fn from_rows(rows: &[Float4]) -> Self {
        assert!(rows.len() == 4, "simd_float4x4(rows:) needs exactly 4 rows");
        Float4x4 {
            columns: [
                Float4::new(rows[0].x, rows[1].x, rows[2].x, rows[3].x),
                Float4::new(rows[0].y, rows[1].y, rows[2].y, rows[3].y),
                Float4::new(rows[0].z, rows[1].z, rows[2].z, rows[3].z),
                Float4::new(rows[0].w, rows[1].w, rows[2].w, rows[3].w),
            ],
        }
    }

    /// Column access with the Swift subscript's bounds check.
    ///
    /// # Panics
    ///
    /// Panics when `col` is outside `0..4`.
    #[inline]
    pub fn column(&self, col: usize) -> Float4 {
        match col {
            0 => self.columns[0],
            1 => self.columns[1],
            2 => self.columns[2],
            3 => self.columns[3],
            _ => panic!("Column index {col} out of range for simd_float4x4"),
        }
    }

    /// Column access without the bounds check, for internal arithmetic.
    #[inline]
    pub fn set_column(&mut self, col: usize, value: Float4) {
        match col {
            0..=3 => self.columns[col] = value,
            _ => panic!("Column index {col} out of range for simd_float4x4"),
        }
    }

    /// Rotation-only matrix from a quaternion.
    pub fn from_quatf(q: Quatf) -> Self {
        let ix = q.vector.x;
        let iy = q.vector.y;
        let iz = q.vector.z;
        let r = q.vector.w;
        let x2 = ix + ix;
        let y2 = iy + iy;
        let z2 = iz + iz;
        let xx = ix * x2;
        let xy = ix * y2;
        let xz = ix * z2;
        let yy = iy * y2;
        let yz = iy * z2;
        let zz = iz * z2;
        let wx = r * x2;
        let wy = r * y2;
        let wz = r * z2;
        Float4x4 {
            columns: [
                Float4::new(1.0 - (yy + zz), xy + wz, xz - wy, 0.0),
                Float4::new(xy - wz, 1.0 - (xx + zz), yz + wx, 0.0),
                Float4::new(xz + wy, yz - wx, 1.0 - (xx + yy), 0.0),
                Float4::new(0.0, 0.0, 0.0, 1.0),
            ],
        }
    }

    /// Named variant used by some call sites (`simd_float4x4(rotation:)`).
    #[inline]
    pub fn from_rotation(q: Quatf) -> Self {
        Self::from_quatf(q)
    }

    #[inline]
    pub fn transpose(self) -> Self {
        simd_transpose(self)
    }

    #[inline]
    pub fn inverse(self) -> Self {
        simd_inverse(self)
    }
}

pub fn mul_4x4_4x4(lhs: Float4x4, rhs: Float4x4) -> Float4x4 {
    let mut r = Float4x4::new();
    for i in 0..4 {
        let c = rhs.column(i);
        r.set_column(
            i,
            lhs.columns[0] * c.x
                + lhs.columns[1] * c.y
                + lhs.columns[2] * c.z
                + lhs.columns[3] * c.w,
        );
    }
    r
}

pub fn mul_4x4_float4(lhs: Float4x4, rhs: Float4) -> Float4 {
    lhs.columns[0] * rhs.x
        + lhs.columns[1] * rhs.y
        + lhs.columns[2] * rhs.z
        + lhs.columns[3] * rhs.w
}

impl Mul for Float4x4 {
    type Output = Float4x4;
    #[inline]
    fn mul(self, rhs: Float4x4) -> Float4x4 {
        mul_4x4_4x4(self, rhs)
    }
}

impl Mul<Float4> for Float4x4 {
    type Output = Float4;
    #[inline]
    fn mul(self, rhs: Float4) -> Float4 {
        mul_4x4_float4(self, rhs)
    }
}

impl MulAssign for Float4x4 {
    #[inline]
    fn mul_assign(&mut self, rhs: Float4x4) {
        *self = mul_4x4_4x4(*self, rhs);
    }
}

/// `matrix_identity_float4x4`.
pub const MATRIX_IDENTITY_FLOAT4X4: Float4x4 = Float4x4::from_columns([
    Float4::new(1.0, 0.0, 0.0, 0.0),
    Float4::new(0.0, 1.0, 0.0, 0.0),
    Float4::new(0.0, 0.0, 1.0, 0.0),
    Float4::new(0.0, 0.0, 0.0, 1.0),
]);

pub fn simd_transpose(m: Float4x4) -> Float4x4 {
    Float4x4::from_rows(&m.columns)
}

pub fn simd_inverse(m: Float4x4) -> Float4x4 {
    // MESA-style cofactor inverse (column-major layout).
    let m0 = m.columns[0].x;
    let m1 = m.columns[0].y;
    let m2 = m.columns[0].z;
    let m3 = m.columns[0].w;
    let m4 = m.columns[1].x;
    let m5 = m.columns[1].y;
    let m6 = m.columns[1].z;
    let m7 = m.columns[1].w;
    let m8 = m.columns[2].x;
    let m9 = m.columns[2].y;
    let m10 = m.columns[2].z;
    let m11 = m.columns[2].w;
    let m12 = m.columns[3].x;
    let m13 = m.columns[3].y;
    let m14 = m.columns[3].z;
    let m15 = m.columns[3].w;

    let i0 = m5 * m10 * m15 - m5 * m11 * m14 - m9 * m6 * m15 + m9 * m7 * m14 + m13 * m6 * m11
        - m13 * m7 * m10;
    let i4 = -m4 * m10 * m15 + m4 * m11 * m14 + m8 * m6 * m15 - m8 * m7 * m14 - m12 * m6 * m11
        + m12 * m7 * m10;
    let i8 = m4 * m9 * m15 - m4 * m11 * m13 - m8 * m5 * m15 + m8 * m7 * m13 + m12 * m5 * m11
        - m12 * m7 * m9;
    let i12 = -m4 * m9 * m14 + m4 * m10 * m13 + m8 * m5 * m14 - m8 * m6 * m13 - m12 * m5 * m10
        + m12 * m6 * m9;
    let i1 = -m1 * m10 * m15 + m1 * m11 * m14 + m9 * m2 * m15 - m9 * m3 * m14 - m13 * m2 * m11
        + m13 * m3 * m10;
    let i5 = m0 * m10 * m15 - m0 * m11 * m14 - m8 * m2 * m15 + m8 * m3 * m14 + m12 * m2 * m11
        - m12 * m3 * m10;
    let i9 = -m0 * m9 * m15 + m0 * m11 * m13 + m8 * m1 * m15 - m8 * m3 * m13 - m12 * m1 * m11
        + m12 * m3 * m9;
    let i13 = m0 * m9 * m14 - m0 * m10 * m13 - m8 * m1 * m14 + m8 * m2 * m13 + m12 * m1 * m10
        - m12 * m2 * m9;
    let i2 = m1 * m6 * m15 - m1 * m7 * m14 - m5 * m2 * m15 + m5 * m3 * m14 + m13 * m2 * m7
        - m13 * m3 * m6;
    let i6 = -m0 * m6 * m15 + m0 * m7 * m14 + m4 * m2 * m15 - m4 * m3 * m14 - m12 * m2 * m7
        + m12 * m3 * m6;
    let i10 = m0 * m5 * m15 - m0 * m7 * m13 - m4 * m1 * m15 + m4 * m3 * m13 + m12 * m1 * m7
        - m12 * m3 * m5;
    let i14 = -m0 * m5 * m14 + m0 * m6 * m13 + m4 * m1 * m14 - m4 * m2 * m13 - m12 * m1 * m6
        + m12 * m2 * m5;
    let i3 = -m1 * m6 * m11 + m1 * m7 * m10 + m5 * m2 * m11 - m5 * m3 * m10 - m9 * m2 * m7
        + m9 * m3 * m6;
    let i7 =
        m0 * m6 * m11 - m0 * m7 * m10 - m4 * m2 * m11 + m4 * m3 * m10 + m8 * m2 * m7 - m8 * m3 * m6;
    let i11 =
        -m0 * m5 * m11 + m0 * m7 * m9 + m4 * m1 * m11 - m4 * m3 * m9 - m8 * m1 * m7 + m8 * m3 * m5;
    let i15 =
        m0 * m5 * m10 - m0 * m6 * m9 - m4 * m1 * m10 + m4 * m2 * m9 + m8 * m1 * m6 - m8 * m2 * m5;

    let det = m0 * i0 + m1 * i4 + m2 * i8 + m3 * i12;
    if det.abs() <= f32::MIN_POSITIVE {
        return MATRIX_IDENTITY_FLOAT4X4;
    }
    let d = 1.0 / det;
    Float4x4::from_columns([
        Float4::new(i0 * d, i1 * d, i2 * d, i3 * d),
        Float4::new(i4 * d, i5 * d, i6 * d, i7 * d),
        Float4::new(i8 * d, i9 * d, i10 * d, i11 * d),
        Float4::new(i12 * d, i13 * d, i14 * d, i15 * d),
    ])
}

pub fn simd_determinant(m: Float4x4) -> f32 {
    // Cofactors for the first row — matches simd_inverse's computation.
    let m0 = m.columns[0].x;
    let m1 = m.columns[0].y;
    let m2 = m.columns[0].z;
    let m3 = m.columns[0].w;
    let m4 = m.columns[1].x;
    let m5 = m.columns[1].y;
    let m6 = m.columns[1].z;
    let m7 = m.columns[1].w;
    let m8 = m.columns[2].x;
    let m9 = m.columns[2].y;
    let m10 = m.columns[2].z;
    let m11 = m.columns[2].w;
    let m12 = m.columns[3].x;
    let m13 = m.columns[3].y;
    let m14 = m.columns[3].z;
    let m15 = m.columns[3].w;
    let i0 = m5 * m10 * m15 - m5 * m11 * m14 - m9 * m6 * m15 + m9 * m7 * m14 + m13 * m6 * m11
        - m13 * m7 * m10;
    let i4 = -m4 * m10 * m15 + m4 * m11 * m14 + m8 * m6 * m15 - m8 * m7 * m14 - m12 * m6 * m11
        + m12 * m7 * m10;
    let i8 = m4 * m9 * m15 - m4 * m11 * m13 - m8 * m5 * m15 + m8 * m7 * m13 + m12 * m5 * m11
        - m12 * m7 * m9;
    let i12 = -m4 * m9 * m14 + m4 * m10 * m13 + m8 * m5 * m14 - m8 * m6 * m13 - m12 * m5 * m10
        + m12 * m6 * m9;
    m0 * i0 + m1 * i4 + m2 * i8 + m3 * i12
}

// MARK: - simd_float3x3

impl PartialEq for Float3x3 {
    #[inline]
    fn eq(&self, other: &Self) -> bool {
        self.columns == other.columns
    }
}

impl fmt::Debug for Float3x3 {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_tuple("Float3x3").field(&self.columns).finish()
    }
}

impl Default for Float3x3 {
    fn default() -> Self {
        Self::new()
    }
}

impl Float3x3 {
    #[inline]
    pub const fn new() -> Self {
        Float3x3 {
            columns: [Float3::ZERO; 3],
        }
    }

    #[inline]
    pub const fn from_columns(c: [Float3; 3]) -> Self {
        Float3x3 { columns: c }
    }

    #[inline]
    pub const fn diagonal(d: Float3) -> Self {
        Float3x3 {
            columns: [
                Float3::new(d.x, 0.0, 0.0),
                Float3::new(0.0, d.y, 0.0),
                Float3::new(0.0, 0.0, d.z),
            ],
        }
    }

    #[inline]
    pub const fn from_scalar(scalar: f32) -> Self {
        Self::diagonal(Float3::splat(scalar))
    }

    /// Extracts the upper-left 3x3 from a 4x4.
    #[inline]
    pub const fn from_float4x4(m: Float4x4) -> Self {
        Float3x3 {
            columns: [
                Float3::new(m.columns[0].x, m.columns[0].y, m.columns[0].z),
                Float3::new(m.columns[1].x, m.columns[1].y, m.columns[1].z),
                Float3::new(m.columns[2].x, m.columns[2].y, m.columns[2].z),
            ],
        }
    }

    pub fn from_quatf(q: Quatf) -> Self {
        let ix = q.vector.x;
        let iy = q.vector.y;
        let iz = q.vector.z;
        let r = q.vector.w;
        let x2 = ix + ix;
        let y2 = iy + iy;
        let z2 = iz + iz;
        let xx = ix * x2;
        let xy = ix * y2;
        let xz = ix * z2;
        let yy = iy * y2;
        let yz = iy * z2;
        let zz = iz * z2;
        let wx = r * x2;
        let wy = r * y2;
        let wz = r * z2;
        Float3x3 {
            columns: [
                Float3::new(1.0 - (yy + zz), xy + wz, xz - wy),
                Float3::new(xy - wz, 1.0 - (xx + zz), yz + wx),
                Float3::new(xz + wy, yz - wx, 1.0 - (xx + yy)),
            ],
        }
    }

    /// # Panics
    ///
    /// Panics when `col` is outside `0..3`, matching the Swift `fatalError`.
    #[inline]
    pub fn column(&self, col: usize) -> Float3 {
        match col {
            0 => self.columns[0],
            1 => self.columns[1],
            2 => self.columns[2],
            _ => panic!("Column index out of range"),
        }
    }

    #[inline]
    pub fn set_column(&mut self, col: usize, value: Float3) {
        match col {
            0..=2 => self.columns[col] = value,
            _ => panic!("Column index out of range"),
        }
    }
}

/// `matrix_identity_float3x3`.
pub const MATRIX_IDENTITY_FLOAT3X3: Float3x3 = Float3x3::from_columns([
    Float3::new(1.0, 0.0, 0.0),
    Float3::new(0.0, 1.0, 0.0),
    Float3::new(0.0, 0.0, 1.0),
]);

impl Mul<Float3> for Float3x3 {
    type Output = Float3;
    #[inline]
    fn mul(self, rhs: Float3) -> Float3 {
        self.columns[0] * rhs.x + self.columns[1] * rhs.y + self.columns[2] * rhs.z
    }
}

impl Mul for Float3x3 {
    type Output = Float3x3;
    #[inline]
    fn mul(self, rhs: Float3x3) -> Float3x3 {
        let mut r = Float3x3::new();
        for i in 0..3 {
            let c = rhs.column(i);
            r.set_column(
                i,
                self.columns[0] * c.x + self.columns[1] * c.y + self.columns[2] * c.z,
            );
        }
        r
    }
}

pub fn simd_transpose3(m: Float3x3) -> Float3x3 {
    Float3x3::from_columns([
        Float3::new(m.columns[0].x, m.columns[1].x, m.columns[2].x),
        Float3::new(m.columns[0].y, m.columns[1].y, m.columns[2].y),
        Float3::new(m.columns[0].z, m.columns[1].z, m.columns[2].z),
    ])
}

pub fn simd_inverse3(m: Float3x3) -> Float3x3 {
    let c0 = m.columns[0];
    let c1 = m.columns[1];
    let c2 = m.columns[2];
    let cof0 = Float3::new(
        c1.y * c2.z - c1.z * c2.y,
        c0.z * c2.y - c0.y * c2.z,
        c0.y * c1.z - c0.z * c1.y,
    );
    let det = c0.x * cof0.x + c1.x * cof0.y + c2.x * cof0.z;
    if det.abs() <= f32::MIN_POSITIVE {
        return MATRIX_IDENTITY_FLOAT3X3;
    }
    let d = 1.0 / det;
    let cof1 = Float3::new(
        c1.z * c2.x - c1.x * c2.z,
        c0.x * c2.z - c0.z * c2.x,
        c0.z * c1.x - c0.x * c1.z,
    );
    let cof2 = Float3::new(
        c1.x * c2.y - c1.y * c2.x,
        c0.y * c2.x - c0.x * c2.y,
        c0.x * c1.y - c0.y * c1.x,
    );
    // Adjugate (transposed cofactor matrix) / det.
    Float3x3::from_columns([
        Float3::new(cof0.x * d, cof1.x * d, cof2.x * d),
        Float3::new(cof0.y * d, cof1.y * d, cof2.y * d),
        Float3::new(cof0.z * d, cof1.z * d, cof2.z * d),
    ])
}

pub fn simd_determinant3(m: Float3x3) -> f32 {
    let c0 = m.columns[0];
    let c1 = m.columns[1];
    let c2 = m.columns[2];
    c0.x * (c1.y * c2.z - c1.z * c2.y) - c0.y * (c1.x * c2.z - c1.z * c2.x)
        + c0.z * (c1.x * c2.y - c1.y * c2.x)
}

// MARK: - simd_quatf

/// `simd_quatf`: 16 bytes, 16-aligned. `vector` is `(ix, iy, iz, r)`.
#[repr(C, align(16))]
#[derive(Clone, Copy)]
pub struct Quatf {
    pub vector: Float4,
}

const _: () = assert!(core::mem::size_of::<Quatf>() == 16 && core::mem::align_of::<Quatf>() == 16);

impl PartialEq for Quatf {
    #[inline]
    fn eq(&self, other: &Self) -> bool {
        self.vector == other.vector
    }
}

impl fmt::Debug for Quatf {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_tuple("Quatf").field(&self.vector).finish()
    }
}

impl Default for Quatf {
    fn default() -> Self {
        Self::IDENTITY
    }
}

impl Quatf {
    pub const IDENTITY: Quatf = Quatf {
        vector: Float4::new(0.0, 0.0, 0.0, 1.0),
    };

    #[inline]
    pub const fn from_vector(vector: Float4) -> Self {
        Quatf { vector }
    }

    /// `simd_quatf(real:imag:)`.
    #[inline]
    pub const fn from_real_imag(real: f32, imag: Float3) -> Self {
        Quatf {
            vector: Float4::new(imag.x, imag.y, imag.z, real),
        }
    }

    /// `simd_quatf(ix:iy:iz:r:)`.
    #[inline]
    pub const fn from_parts(ix: f32, iy: f32, iz: f32, r: f32) -> Self {
        Quatf {
            vector: Float4::new(ix, iy, iz, r),
        }
    }

    #[inline]
    pub const fn real(&self) -> f32 {
        self.vector.w
    }

    #[inline]
    pub const fn imag(&self) -> Float3 {
        Float3::new(self.vector.x, self.vector.y, self.vector.z)
    }

    /// `simd_quatf(angle:axis:)`.
    pub fn from_angle_axis(angle: f32, axis: Float3) -> Self {
        let half_angle = angle * 0.5;
        let s = (half_angle as f64).sin() as f32;
        let len = simd_length(axis);
        let normalized_axis = if len > 0.0 {
            axis / len
        } else {
            Float3::new(0.0, 1.0, 0.0)
        };
        Quatf {
            vector: Float4::new(
                normalized_axis.x * s,
                normalized_axis.y * s,
                normalized_axis.z * s,
                (half_angle as f64).cos() as f32,
            ),
        }
    }

    /// Shortest-arc rotation that takes `from` onto `to` (both need not be unit).
    pub fn from_to(from: Float3, to: Float3) -> Self {
        let f = simd_normalize(from);
        let t = simd_normalize(to);
        let d = simd_dot(f, t);
        if d >= 1.0 - 1e-6 {
            // Already aligned → identity.
            Quatf {
                vector: Float4::new(0.0, 0.0, 0.0, 1.0),
            }
        } else if d <= -1.0 + 1e-6 {
            // Opposed: rotate 180° about any axis orthogonal to `f`. A 180°
            // rotation about a unit axis is the pure quaternion (axis, 0).
            let mut axis = simd_cross(Float3::new(1.0, 0.0, 0.0), f);
            if simd_length(axis) < 1e-6 {
                axis = simd_cross(Float3::new(0.0, 1.0, 0.0), f);
            }
            axis = simd_normalize(axis);
            Quatf {
                vector: Float4::new(axis.x, axis.y, axis.z, 0.0),
            }
        } else {
            let axis = simd_cross(f, t);
            let s = ((1.0 + d) * 2.0).sqrt();
            let invs = 1.0 / s;
            Quatf {
                vector: Float4::new(axis.x * invs, axis.y * invs, axis.z * invs, s * 0.5),
            }
        }
    }

    /// Init from a 3x3 rotation matrix (Shepperd's method).
    pub fn from_float3x3(m: Float3x3) -> Self {
        let trace = m.columns[0].x + m.columns[1].y + m.columns[2].z;
        if trace > 0.0 {
            let s: f32 = 0.5 / (trace + 1.0).sqrt();
            Quatf {
                vector: Float4::new(
                    (m.columns[1].z - m.columns[2].y) * s,
                    (m.columns[2].x - m.columns[0].z) * s,
                    (m.columns[0].y - m.columns[1].x) * s,
                    0.25 / s,
                ),
            }
        } else if m.columns[0].x > m.columns[1].y && m.columns[0].x > m.columns[2].z {
            let s: f32 = 2.0 * (1.0 + m.columns[0].x - m.columns[1].y - m.columns[2].z).sqrt();
            Quatf {
                vector: Float4::new(
                    0.25 * s,
                    (m.columns[1].x + m.columns[0].y) / s,
                    (m.columns[2].x + m.columns[0].z) / s,
                    (m.columns[1].z - m.columns[2].y) / s,
                ),
            }
        } else if m.columns[1].y > m.columns[2].z {
            let s: f32 = 2.0 * (1.0 + m.columns[1].y - m.columns[0].x - m.columns[2].z).sqrt();
            Quatf {
                vector: Float4::new(
                    (m.columns[1].x + m.columns[0].y) / s,
                    0.25 * s,
                    (m.columns[2].y + m.columns[1].z) / s,
                    (m.columns[2].x - m.columns[0].z) / s,
                ),
            }
        } else {
            let s: f32 = 2.0 * (1.0 + m.columns[2].z - m.columns[0].x - m.columns[1].y).sqrt();
            Quatf {
                vector: Float4::new(
                    (m.columns[2].x + m.columns[0].z) / s,
                    (m.columns[2].y + m.columns[1].z) / s,
                    0.25 * s,
                    (m.columns[0].y - m.columns[1].x) / s,
                ),
            }
        }
    }

    /// Init from a 4x4 rotation matrix (extracts the upper-left 3x3).
    #[inline]
    pub fn from_float4x4(m: Float4x4) -> Self {
        Self::from_float3x3(Float3x3::from_float4x4(m))
    }

    /// Rotate a vector by this quaternion.
    #[inline]
    pub fn act(&self, v: Float3) -> Float3 {
        let q = self.imag();
        let t = simd_cross(q, v) * 2.0;
        v + t * self.real() + simd_cross(q, t)
    }
}

impl Mul for Quatf {
    type Output = Quatf;
    #[inline]
    fn mul(self, rhs: Quatf) -> Quatf {
        let lv = self.vector;
        let rv = rhs.vector;
        Quatf {
            vector: Float4::new(
                lv.w * rv.x + lv.x * rv.w + lv.y * rv.z - lv.z * rv.y,
                lv.w * rv.y - lv.x * rv.z + lv.y * rv.w + lv.z * rv.x,
                lv.w * rv.z + lv.x * rv.y - lv.y * rv.x + lv.z * rv.w,
                lv.w * rv.w - lv.x * rv.x - lv.y * rv.y - lv.z * rv.z,
            ),
        }
    }
}

/// Spherical interpolation matching the Apple simd shortest-arc behavior.
pub fn cove_slerp(start: Quatf, end: Quatf, t: f32) -> Quatf {
    fn normalized(vector: Float4) -> Float4 {
        let magnitude = simd_length4(vector);
        if magnitude > 1e-8 {
            vector / magnitude
        } else {
            Float4::new(0.0, 0.0, 0.0, 1.0)
        }
    }

    let start_vector = normalized(start.vector);
    let mut end_vector = normalized(end.vector);
    let mut cosine = simd_dot4(start_vector, end_vector);
    if cosine < 0.0 {
        end_vector = -end_vector;
        cosine = -cosine;
    }
    cosine = simd_clamp_scalar(cosine, -1.0, 1.0);

    if cosine > 0.9995 {
        return Quatf {
            vector: normalized(start_vector + (end_vector - start_vector) * t),
        };
    }

    let angle = (cosine as f64).acos() as f32;
    let denominator = (angle as f64).sin() as f32;
    if denominator.abs() <= 1e-8 {
        return Quatf {
            vector: start_vector,
        };
    }
    let start_weight = (((1.0 - t) * angle) as f64).sin() as f32 / denominator;
    let end_weight = ((t * angle) as f64).sin() as f32 / denominator;
    Quatf {
        vector: normalized(start_vector * start_weight + end_vector * end_weight),
    }
}
