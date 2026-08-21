String formatUsdMinorUnits(int minorUnits) {
  if (minorUnits < 0) {
    throw ArgumentError.value(minorUnits, 'minorUnits', 'must be nonnegative');
  }

  final dollars = minorUnits ~/ 100;
  final cents = (minorUnits % 100).toString().padLeft(2, '0');
  return '\$$dollars.$cents';
}
