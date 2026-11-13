import 'package:breeze/logic/text_stats.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('TextStats counts words, characters and lines', () {
    final s = TextStats('hello world\nsecond line');
    expect(s.words, 4);
    expect(s.lines, 2);
    expect(s.charactersNoSpaces, 'helloworldsecondline'.length);
  });

  test('humanSize formats bytes', () {
    expect(humanSize(940), '940 B');
    expect(humanSize(53910).endsWith('kB'), true);
  });

  test('findRanges finds all case-insensitive matches', () {
    expect(findRanges('aXaxA', 'a').length, 3);
    expect(findRanges('hello', 'z'), isEmpty);
  });
}
