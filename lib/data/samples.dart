/// The files a fresh install starts with: one of each kind Breeze opens,
/// so the list shows at a glance what it can do. Written once, into an
/// empty folder, and never again (deleting them is the user's choice).
library;

/// (file name, text). Word and RTF files are written from their text as
/// Breeze's Markdown, so they open formatted.
const sampleFiles = <(String, String)>[
  ('Welcome to Breeze.md', _welcome),
  ('Team meeting notes.docx', _meeting),
  ('Masala chai recipe.rtf', _chai),
  ('Weekend trip packing list.txt', _packing),
  ('Monthly budget.csv', _budget),
  ('app_settings.json', _json),
  ('word_count.py', _python),
];

/// The one pinned at the top.
const sampleWelcome = 'Welcome to Breeze.md';

const _welcome = '''# Welcome to Breeze
A calm place for notes, documents and code. Each note is a real file (Word, RTF, Markdown or text), so it opens anywhere you share it.

## Write with style
Type **bold**, *italic*, ~~strikethrough~~ or <u>underline</u>, or use the bar above the keyboard. Headings, bulleted and numbered lists work as you type.

## Open almost anything
- **Word** (.docx) and **RTF** documents, with their look kept when you save
- **Markdown** and plain **text** notes
- **Code** in dozens of languages, coloured as you type
- **Data** like JSON, CSV and logs

## Keep it yours
1. Pin what matters to keep it on top
2. Tag notes to find them fast
3. Lock private notes with your fingerprint
4. Share or print any note as a PDF

Tap **+** to start a new note. These samples are yours to edit or delete.''';

const _meeting = '''# Team meeting
**Date:** Monday, 10:00 · **Where:** Room 3 and online

## Agenda
1. Last week's wins
2. Launch timeline
3. Open questions

## Notes
- The beta reached **1,200 users**, ahead of plan
- Onboarding feedback is *mostly positive*; the sign-up form needs fewer steps
- Launch stays on the **15th**, with a short freeze the week before

## Action items
- **Asha:** simplify the sign-up form by Thursday
- **Rahul:** draft the launch email
- **Everyone:** test the release build on your own phone''';

const _chai = '''# Masala chai
*Serves 2 · ready in 10 minutes*

## You need
- 1 cup water and 1 cup milk
- 2 tsp black tea leaves
- 2 green cardamom pods, crushed
- A small piece of ginger, grated
- Sugar to taste

## Method
1. Boil the water with the **ginger** and **cardamom** for 2 minutes.
2. Add the tea leaves and let it simmer for 1 minute.
3. Pour in the milk and sugar, and bring it to a boil **twice**.
4. Strain into cups and serve hot.

<u>Tip:</u> a pinch of black pepper or a clove makes it warmer on a cold day.''';

const _packing = '''Weekend trip - packing list

Clothes
  - 2 T-shirts, 1 shirt
  - Jeans and shorts
  - A light jacket
  - Comfortable shoes

Essentials
  - Phone charger and power bank
  - ID and tickets
  - Toothbrush and toothpaste
  - Sunscreen and sunglasses
  - Water bottle

Before leaving
  - Switch off the geyser
  - Water the plants
  - Lock the balcony door
''';

const _budget = '''Category,Planned,Spent,Left
Rent,15000,15000,0
Groceries,6000,4850,1150
Transport,2500,2140,360
Bills,3000,2760,240
Eating out,2000,2350,-350
Savings,8000,8000,0
Total,36500,35100,1400
''';

const _json = '''{
  "theme": "system",
  "accent": "sky",
  "fontSize": 16,
  "autosave": true,
  "backup": {
    "enabled": true,
    "frequency": "daily",
    "keep": 7
  },
  "recentFiles": [
    "Team meeting notes.docx",
    "Masala chai recipe.rtf"
  ]
}
''';

const _python =
    '''"""Counts the words in a text file and shows the most common ones."""

from collections import Counter
import re
import sys


def top_words(path, n=10):
    with open(path, encoding="utf-8") as f:
        words = re.findall(r"[a-z']+", f.read().lower())
    return Counter(words).most_common(n)


if __name__ == "__main__":
    for word, count in top_words(sys.argv[1]):
        print(f"{word:<15} {count}")
''';
