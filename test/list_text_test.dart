import 'package:breeze/logic/list_text.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('friendlyDate', () {
    final now = DateTime(2026, 11, 12, 18, 0);
    test('today, yesterday, this week, this year, before', () {
      expect(
        friendlyDate(DateTime(2026, 11, 12, 16, 21), now: now),
        'Today, 16:21',
      );
      expect(
        friendlyDate(DateTime(2026, 11, 12, 0, 5), now: now, short: true),
        '00:05',
      );
      expect(
        friendlyDate(DateTime(2026, 11, 11, 23, 59), now: now),
        'Yesterday, 23:59',
      );
      expect(
        friendlyDate(DateTime(2026, 11, 11, 9), now: now, short: true),
        'Yesterday',
      );
      expect(
        friendlyDate(DateTime(2026, 11, 9, 14, 30), now: now),
        'Mon, 14:30',
      );
      expect(friendlyDate(DateTime(2026, 11, 5), now: now), '5 Nov');
      expect(friendlyDate(DateTime(2025, 11, 12), now: now), '12 Nov 2025');
    });
    test('a 12-hour phone reads 12-hour times', () {
      expect(
        friendlyDate(DateTime(2026, 11, 12, 16, 21), now: now, h24: false),
        'Today, 4:21 PM',
      );
      expect(
        friendlyDate(
          DateTime(2026, 11, 12, 0, 5),
          now: now,
          short: true,
          h24: false,
        ),
        '12:05 AM',
      );
      expect(
        fullDate(DateTime(2026, 11, 5, 9, 7), h24: false),
        '5 Nov 2026, 9:07 AM',
      );
    });
    test('a time ahead of the clock is a date, not "today"', () {
      expect(friendlyDate(DateTime(2026, 11, 20), now: now), '20 Nov');
    });
  });

  group('previewText', () {
    test('a note reads without its writing symbols', () {
      expect(
        previewText(
          '# Welcome to Breeze\nA **calm** place, *quiet* and ~~loud~~.\n'
              '- one\n2. two\n<u>under</u> [link](https://x.y)',
          '.md',
          'Welcome to Breeze',
        ),
        'A calm place, quiet and loud. one two under link',
      );
    });
    test('a title that is not the name stays, and maths keeps its star', () {
      expect(
        previewText('# Plan\n2 * 3 = 6', '.txt', 'Other'),
        'Plan 2 * 3 = 6',
      );
    });
    test('escaped symbols show as themselves', () {
      final bs = String.fromCharCode(92);
      expect(previewText('a $bs*b$bs* c', '.md', 'x'), 'a *b* c');
    });
    test('a table reads in dots; code stays as written', () {
      expect(
        previewText('Category,Planned\nRent,15000\n', '.csv', 'budget'),
        'Category · Planned Rent · 15000',
      );
      expect(previewText('# comment\n- x', '.py', 'y'), '# comment - x');
    });
    test('an empty file is empty', () {
      expect(previewText('\n  \n', '.txt', 'n'), '');
    });
  });
  test('a first line that starts the name is left out, by whole words', () {
    expect(
      previewText('Masala chai\nServes 2', '.rtf', 'Masala chai recipe'),
      'Serves 2',
    );
    expect(previewText('Team\nhi', '.txt', 'Teammate notes'), 'Team hi');
  });

  test('a Hindi title that repeats the name is left out too', () {
    expect(
      previewText('# मसाला चाय\nदो कप पानी', '.md', 'मसाला चाय'),
      'दो कप पानी',
    );
  });

  test('a quoted cell keeps its comma', () {
    expect(
      previewText('Name,Age\n"Doe, John",42\n"Say ""hi""",7', '.csv', 'x'),
      'Name · Age Doe, John · 42 Say "hi" · 7',
    );
  });

  test('a private-use character stays itself', () {
    final pua = String.fromCharCode(0xE141);
    final bs = String.fromCharCode(92);
    final out = previewText('a $pua b $bs# c', '.md', 'x');
    expect(out, contains(pua));
    expect(out, isNot(contains('A')));
  });

  test('yesterday across a clock change is still yesterday', () {
    // Local times on either side of a 23-hour day count by the calendar.
    final now = DateTime(2026, 3, 30, 10);
    expect(
      friendlyDate(DateTime(2026, 3, 29, 10), now: now),
      'Yesterday, 10:00',
    );
    expect(
      friendlyDate(DateTime(2026, 3, 29, 23, 30), now: now, short: true),
      'Yesterday',
    );
  });
}
