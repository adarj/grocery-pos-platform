final RegExp _moneyInputPattern = RegExp(r'^(\d+)(?:\.(\d{1,2}))?$');

int? parseMoneyInputMinorUnits(String input) {
  final match = _moneyInputPattern.firstMatch(input.trim());
  if (match == null) return null;

  final wholeUnits = int.tryParse(match.group(1)!);
  if (wholeUnits == null) return null;

  final fraction = match.group(2);
  final minorFraction = switch (fraction?.length) {
    null => 0,
    1 => int.parse(fraction!) * 10,
    2 => int.parse(fraction!),
    _ => throw StateError('Money input regex admitted an invalid fraction.'),
  };
  return wholeUnits * 100 + minorFraction;
}
