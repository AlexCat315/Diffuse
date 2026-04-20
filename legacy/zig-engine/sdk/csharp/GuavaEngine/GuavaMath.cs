// ---------------------------------------------------------------------------
// GuavaMath.cs — 轻量数学类型（避免依赖 System.Numerics）
// ---------------------------------------------------------------------------

namespace Guava
{
    public struct Vector2
    {
        public float X, Y;

        public Vector2(float x, float y) { X = x; Y = y; }

        public static readonly Vector2 Zero = new(0, 0);
        public static readonly Vector2 One = new(1, 1);

        public static Vector2 operator +(Vector2 a, Vector2 b) => new(a.X + b.X, a.Y + b.Y);
        public static Vector2 operator -(Vector2 a, Vector2 b) => new(a.X - b.X, a.Y - b.Y);
        public static Vector2 operator *(Vector2 a, float s) => new(a.X * s, a.Y * s);

        public override string ToString() => $"({X:F2}, {Y:F2})";
    }

    public struct Vector3
    {
        public float X, Y, Z;

        public Vector3(float x, float y, float z) { X = x; Y = y; Z = z; }

        public static readonly Vector3 Zero = new(0, 0, 0);
        public static readonly Vector3 One = new(1, 1, 1);
        public static readonly Vector3 Up = new(0, 1, 0);
        public static readonly Vector3 Forward = new(0, 0, -1);
        public static readonly Vector3 Right = new(1, 0, 0);

        public float Length() => MathF.Sqrt(X * X + Y * Y + Z * Z);

        public Vector3 Normalized()
        {
            float len = Length();
            return len > 1e-8f ? new Vector3(X / len, Y / len, Z / len) : Zero;
        }

        public static float Dot(Vector3 a, Vector3 b) => a.X * b.X + a.Y * b.Y + a.Z * b.Z;

        public static Vector3 Cross(Vector3 a, Vector3 b) => new(
            a.Y * b.Z - a.Z * b.Y,
            a.Z * b.X - a.X * b.Z,
            a.X * b.Y - a.Y * b.X);

        public static Vector3 Lerp(Vector3 a, Vector3 b, float t) => a + (b - a) * t;

        public static Vector3 operator +(Vector3 a, Vector3 b) => new(a.X + b.X, a.Y + b.Y, a.Z + b.Z);
        public static Vector3 operator -(Vector3 a, Vector3 b) => new(a.X - b.X, a.Y - b.Y, a.Z - b.Z);
        public static Vector3 operator *(Vector3 a, float s) => new(a.X * s, a.Y * s, a.Z * s);
        public static Vector3 operator *(float s, Vector3 a) => new(a.X * s, a.Y * s, a.Z * s);
        public static Vector3 operator -(Vector3 a) => new(-a.X, -a.Y, -a.Z);

        public override string ToString() => $"({X:F2}, {Y:F2}, {Z:F2})";
    }

    public struct Quaternion
    {
        public float X, Y, Z, W;

        public Quaternion(float x, float y, float z, float w) { X = x; Y = y; Z = z; W = w; }

        public static readonly Quaternion Identity = new(0, 0, 0, 1);

        public static Quaternion FromEulerDegrees(float pitch, float yaw, float roll)
        {
            float p = pitch * MathF.PI / 360f;
            float y = yaw * MathF.PI / 360f;
            float r = roll * MathF.PI / 360f;
            float sp = MathF.Sin(p), cp = MathF.Cos(p);
            float sy = MathF.Sin(y), cy = MathF.Cos(y);
            float sr = MathF.Sin(r), cr = MathF.Cos(r);
            return new Quaternion(
                sr * cp * cy - cr * sp * sy,
                cr * sp * cy + sr * cp * sy,
                cr * cp * sy - sr * sp * cy,
                cr * cp * cy + sr * sp * sy);
        }

        public override string ToString() => $"({X:F3}, {Y:F3}, {Z:F3}, {W:F3})";
    }

    /// <summary>键盘按键码（与引擎 input.zig KeyCode 对齐）。</summary>
    public enum KeyCode : uint
    {
        A = 4, B = 5, C = 6, D = 7, E = 8, F = 9, G = 10,
        H = 11, I = 12, J = 13, K = 14, L = 15, M = 16, N = 17,
        O = 18, P = 19, Q = 20, R = 21, S = 22, T = 23, U = 24,
        V = 25, W = 26, X = 27, Y = 28, Z = 29,
        Num1 = 30, Num2 = 31, Num3 = 32, Num4 = 33, Num5 = 34,
        Num6 = 35, Num7 = 36, Num8 = 37, Num9 = 38, Num0 = 39,
        Enter = 40, Escape = 41, Backspace = 42, Tab = 43, Space = 44,
        Left = 80, Right = 79, Up = 82, Down = 81,
        LeftShift = 225, LeftCtrl = 224, LeftAlt = 226,
    }

    /// <summary>鼠标按键。</summary>
    public enum MouseButton : uint
    {
        Left = 0,
        Right = 1,
        Middle = 2,
    }
}
