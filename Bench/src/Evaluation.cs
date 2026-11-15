namespace AVDTune.Bench;

/// <summary>Evaluation maths of the benchmark (design 2.2, 3): median, spread, index against a reference, geometric means.</summary>
public static class Evaluation
{
    public static double Median(IReadOnlyList<double> values)
    {
        if (values.Count == 0) throw new ArgumentException("No values.");
        var s = values.OrderBy(v => v).ToArray();
        int n = s.Length;
        return n % 2 == 1 ? s[n / 2] : (s[n / 2 - 1] + s[n / 2]) / 2.0;
    }

    public static double Mean(IReadOnlyList<double> values)
    {
        if (values.Count == 0) throw new ArgumentException("No values.");
        return values.Sum() / values.Count;
    }

    /// <summary>Sample standard deviation (n - 1); 0 for a single value.</summary>
    public static double StdDev(IReadOnlyList<double> values)
    {
        if (values.Count < 2) return 0;
        double m = Mean(values);
        double ss = values.Sum(v => (v - m) * (v - m));
        return Math.Sqrt(ss / (values.Count - 1));
    }

    /// <summary>Coefficient of variation in percent: standard deviation / mean x 100.</summary>
    public static double CvPercent(IReadOnlyList<double> values)
    {
        double m = Mean(values);
        return m == 0 ? 0 : StdDev(values) / Math.Abs(m) * 100.0;
    }

    public static bool IsUnstable(IReadOnlyList<double> values, double thresholdPercent = 10.0) => CvPercent(values) > thresholdPercent;

    /// <summary>I = 1000 x value / reference (higher is better) or 1000 x reference / value (lower is better).</summary>
    public static double Index(double value, double reference, bool higherIsBetter)
    {
        if (value <= 0 || reference <= 0) throw new ArgumentOutOfRangeException(nameof(value), "Value and reference must be positive.");
        return higherIsBetter ? 1000.0 * value / reference : 1000.0 * reference / value;
    }

    public static double GeometricMean(IReadOnlyList<double> values)
    {
        if (values.Count == 0) throw new ArgumentException("No values.");
        return Math.Exp(values.Sum(v => Math.Log(v)) / values.Count);
    }

    /// <summary>S = exp( sum(w x ln I) / sum(w) )</summary>
    public static double WeightedGeometricMean(IReadOnlyList<double> values, IReadOnlyList<double> weights)
    {
        if (values.Count == 0 || values.Count != weights.Count) throw new ArgumentException("Values and weights must have the same, non-zero length.");
        double sw = weights.Sum();
        if (sw <= 0) throw new ArgumentException("Weights must sum to a positive number.");
        double s = 0;
        for (int i = 0; i < values.Count; i++) s += weights[i] * Math.Log(values[i]);
        return Math.Exp(s / sw);
    }

    /// <summary>Rounds the way the design shows indexes (half away from zero).</summary>
    public static double RoundIndex(double v) => Math.Round(v, MidpointRounding.AwayFromZero);
}
