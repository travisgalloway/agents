# Mechanics reference

The detailed rules behind `~/.claude/style.md`. This file is
not imported by `CLAUDE.md`. Read it when editing prose,
when running `/deslop`, and before shipping a document or a
figure.

Sources: USU Engineering Writing Center, on technical
writing standards, number expressions, tables and figures,
and commonly missed grammar.

---

## 1. Grammar

1. **Comma before a coordinating conjunction** joining two
   independent clauses. "We discussed the problem, but we
   failed to decide."
2. **Comma after an introductory word, phrase, or clause.**
   "On the basis of the report, we expanded the test suite."
3. **No sentence fragments.** A dependent clause joins an
   independent one. Not "Based on 2010 data". Instead "The
   estimate was based on 2010 data".
4. **Serial comma** in a list of three or more, including
   before the conjunction. "Google, Bing, Yahoo, and Ask."
5. **Transitional words take commas.** "Therefore, the
   results were unpredicted." "You should, nevertheless,
   check the output."
6. **A transitional word joining two independent clauses
   takes a semicolon before it and a comma after it.**
   "Budgets rose; therefore, staff received the equipment."
   Dropping the transitional word and keeping the semicolon
   is equally correct.
7. **No run-ons and no comma splices.** Not "The build
   passed its coverage rose." Not "The build passed, its
   coverage rose." Instead "The build passed; its coverage
   rose." Or "The build passed, so its coverage rose."
8. **Appositives.** An essential appositive takes no commas.
   A non-essential one is set off by commas. "My friend John
   ran the marathon." "Pahoehoe lava, a textured formation,
   occurs on Kilauea."
9. **Essential and non-essential clauses.** "that" begins an
   essential clause and takes no comma. "which" begins a
   non-essential clause and takes one. "The book that you
   ordered is unavailable." "Use the card in my wallet,
   which is on the dresser."
10. **Comma between related adjectives** before a noun. "His
    direct, practical approach."
11. **Commas around geographic names, complete dates, and
    titles in names.** "Birmingham, Alabama, was first."
    "July 22, 1959, was the day." "Rachel B. Lake, PE."
    Do not abbreviate a state name inside a sentence.
12. **Parallel structure.** Not "read, hike, and watching
    birds". Instead "read, hike, and watch birds".
13. **Possessives.** Add `'s` to a singular noun. Add `s'`
    to a plural noun. Add `'s` to the end of a compound.
    "The boy's hat." "The girls' sweaters." "Todd and
    Anne's house." A noun ending in s takes `'s` or a bare
    apostrophe, consistently within one document.
14. **No apostrophe on plural numbers, symbols, or
    letters.** "The 1960s." "Too many &s on the page."
15. **No unclear pronoun reference.** Where "it", "this",
    "that", "them", or "they" could point at more than one
    noun, restate the noun.
16. **No misplaced or dangling modifiers.** Put the phrase
    next to what it modifies. Not "He bought a horse for his
    sister named Prince." Instead "He bought a horse named
    Prince for his sister."
17. **Homophones.** Check "affect" against "effect", "their"
    against "they're" and "there", "principle" against
    "principal", "to" against "two" and "too". "Affect" is
    usually the verb. "Effect" is usually the noun.
18. **Colon before a list**, after an independent clause.
    "We covered three topics: grammar, style, and voice."
19. **Periods and commas go inside quotation marks.** A
    question mark goes inside when the quote is the
    question.
20. **Subject-verb agreement.** "A new line has been
    released." "Two new lines have been released."

---

## 2. Numbers and units, in full

`style.md` section 5 carries the six rules that apply to
every output. These are the rest.

- **Zero** is written as a numeral. "The axes intersect at
  0."
- **A number above 10 in a range or list with higher
  numbers** is a numeral.
- **Approximate numbers** follow the same rules as exact
  ones. "About 50,000 events." "Approximately 8 samples in
  20."
- **Compound numbers from 21 to 99** are hyphenated when
  written as words. "Forty-nine measurements."
- **Adjacent numbers.** Keep the numeral with the unit and
  spell out the other. "twelve 26-in. pieces." Where the
  first number is long, spell out the one with the unit
  instead. "4,256 twenty-six-in. pieces."
- **Unit symbols are singular.** "1000 mm in 1 L", never
  "1000 mms".
- **A unit named for a person is capitalized as a symbol.**
  "0.3 T." "80 °C."
- **A unit written out is lowercase**, even when named for a
  person. "A tesla measures magnetic field strength."
- **A quantity of one, or a fraction of one, takes a
  singular unit.** "0.8 ton of steel."
- **Secondary units go in parentheses** after the primary
  ones. "a 2-in. (5.08-cm) rod."
- **"in." keeps its period**, to separate the unit from the
  preposition.
- **Simple fractions are spelled out and hyphenated.**
  "one-half of the amount." A complicated fraction uses
  numerals and a slash. "18/25 of the mixture."
- **A precise fraction takes decimal form.** "0.5 L."
- **Non-measured amounts take numerals.** Times, ages,
  points on a scale, figure and table references,
  percentages, and money. "at the age of 5." "Figure 4."
  "45.2%." "$0.26." A whole dollar amount drops the
  decimals, as "$45".

---

## 3. Tables and figures, content only

Page layout is out of scope. Fonts, margins, orientation,
and pagination are not governed here.

**Both.**

- Number tables and figures independently, in the order the
  text refers to them.
- Refer to each one in the text before it appears.
- Keep style consistent across every table and figure in a
  document.
- A caption carries a number, a title, the unit, the time
  period where one applies, and a citation where the data
  came from elsewhere. It tells the reader what to look for.
- Table captions go above. Figure captions go below. Both
  align left with the table or figure.

**Tables.**

- Column headings are short, descriptive, and horizontal.
- Units go in parentheses below the column heading.
- Use horizontal rules sparingly. Use no vertical rules.
- Align decimal points. Right justify other numbers.
- Text columns take left aligned headings and content.
- Numeric columns take centered headings and content.

**Figures.**

- Label both axes, with units.
- Include the zero origin on a linear scale, unless the data
  reads better without it.
- Put the legend inside the axes, or in the caption.
- Include error bars or uncertainty bands when plotting
  means.
- Put an initial zero on a number below one.
- Use scientific notation at 10⁴ and above, and at 10⁻⁴ and
  below.

**Not governed here.** Palette, series color, encoding
choice, mark specification, and dashboard layout belong to
the `dataviz` skill. Load that skill before writing chart
code, and do not re-derive its rules from this file.
