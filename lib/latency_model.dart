class LatencySample {
  const LatencySample(this.seconds, this.ms);
  final double seconds;
  final double? ms;
  Map<String, dynamic> toJson() => {'seconds': seconds, 'ms': ms};
  factory LatencySample.fromJson(Map<String, dynamic> j) => LatencySample(
    (j['seconds'] as num).toDouble(),
    (j['ms'] as num?)?.toDouble(),
  );
}

class LatencyTotals {
  int count = 0, failures = 0;
  double _sum = 0;
  double? minimum, maximum;
  double? get average => count == failures ? null : _sum / (count - failures);
  void add(LatencySample sample) {
    count++;
    final value = sample.ms;
    if (value == null) {
      failures++;
      return;
    }
    _sum += value;
    if (minimum == null || value < minimum!) minimum = value;
    if (maximum == null || value > maximum!) maximum = value;
  }
}

class LatencyStats {
  LatencyStats(this.samples);
  final List<LatencySample> samples;
  List<double> get values =>
      samples.map((s) => s.ms).whereType<double>().toList();
  int get failures => samples.length - values.length;
  double? get average =>
      values.isEmpty ? null : values.reduce((a, b) => a + b) / values.length;
  double? get minimum =>
      values.isEmpty ? null : values.reduce((a, b) => a < b ? a : b);
  double? get maximum =>
      values.isEmpty ? null : values.reduce((a, b) => a > b ? a : b);
}
