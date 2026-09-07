---
description: Rewrite prose in a file against the style rules
argument-hint: [file path]
---

Read $ARGUMENTS and rewrite only the prose. Do not change
code, data, markup structure, heading hierarchy, or any
number.

On a file that is mostly code, rewrite only the comments,
docstrings, and prose blocks. Never change an identifier, a
string literal, or a value. No number inside code, data, a
table of results, or a quoted source changes, whatever the
number rules say.

Apply ~/.claude/style.md and ~/.claude/mechanics.md, working
in this order.

1. Every heading that sets up a reveal gets renamed to state
   its content.
2. Every antithesis construction gets rewritten as two plain
   sentences, or one half gets deleted.
3. Every borrowed idiom or metaphor used as jargon gets
   replaced with the literal claim.
4. Every withheld-information opener, emphasis particle,
   scare quote, and dramatic sentence fragment gets removed.
   Every em dash, mid-sentence colon, and colon-then-reveal
   gets replaced with a comma, parentheses, "because", or a
   new sentence.
5. Every paragraph-final sentence that only restates or
   dramatizes gets deleted.
6. Every quote or epigraph gets verified against a real
   source in the repo. Unverifiable ones get deleted.
7. Any copy that argues for the quality of the work gets
   replaced with a description of what the thing does.
8. Every gendered generic pronoun, gendered noun, and
   disability framing gets rewritten per section 2a.
9. Every militaristic or violent term gets replaced from the
   section 2b table. Every use of color as a value gets
   replaced.
10. Every contraction gets expanded. Every sentence over 20
    words gets split. Every paragraph over 6 lines gets
    split or cut.
11. Every filler word, abstract hedge, and redundancy gets
    deleted. Every sentence opening with "it" or "this" gets
    its referent named.
12. Every number, unit, and decimal in prose gets the
    section 5 form. Numbers in code and data are untouched.
13. Every caption gets its number, unit, time period, and
    source. Every axis gets its label and unit.
14. Reread. If three paragraphs in a row end on the same
    rhythm, rewrite two.

Show a diff before writing. Do not add documentation, do not
add commentary, and do not summarize the changes beyond a
list of which rule numbers you applied.
