namespace AVDTune.Bench;

/// <summary>Own deterministic generator (xorshift64*), so data is the same on every machine and every .NET version.</summary>
public sealed class Rng
{
    private ulong _s;
    public Rng(ulong seed) { _s = seed == 0 ? 0x9E3779B97F4A7C15UL : seed; }
    public ulong NextU64()
    {
        _s ^= _s >> 12; _s ^= _s << 25; _s ^= _s >> 27;
        return _s * 0x2545F4914F6CDD1DUL;
    }
    public uint NextU32() => (uint)(NextU64() >> 32);
    /// <summary>0 .. n-1</summary>
    public int Next(int n) => (int)(((ulong)NextU32() * (ulong)n) >> 32);
    public double NextDouble() => (NextU64() >> 11) * (1.0 / (1UL << 53));
}
