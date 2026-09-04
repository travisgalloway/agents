# Writing style

Applies to everything you write. Chat replies, commit
messages, PR bodies, code comments, backlog issues, and any
prose that ships in a deliverable.

---

## 1. Register

Do not write punchy. This is technical writing, not
marketing copy. Do not build toward a turn of phrase. Lead
with the claim, then support it. If a sentence exists to
create emphasis rather than convey information, delete it.

- Write in the active voice. Use the passive only when the
  actor is unknown, or when the action matters more than
  the actor.
- Choose person by output type. Second person for chat
  replies and for instructions. First person for something
  written as a message, such as a commit body or a PR
  description. Third person for a formal document, such as
  a report, a design note, or a specification.
- Use no contractions, in any output.
- Hold sentences to 20 words or fewer.
- Hold paragraphs to 6 lines or fewer.
- Open every paragraph with its topic sentence.
- Do not narrate an opinion about the work. Drop "feel",
  "think", "believe", "like", and "love".
- Use no clichés and no slang.
- Make no generalizations. Drop "everyone knows", "nobody
  ever", and a bare "all".
- Expand an acronym on first use, with the acronym in
  parentheses. Well-known ones are exempt, such as API,
  CLI, JSON, and HTTP.

---

## 2. Banned constructions

- Borrowed metaphors used as jargon. Never "load-bearing",
  "the seam", "the unlock", "belt and suspenders", "smoking
  gun", "survive contact with", "carry the argument", "the
  through-line". State what depends on what instead. An
  analogy stated as an analogy is allowed. A metaphor used
  as a technical label is not.
- Idioms. Anything a literal translation would break.
  Never "fall through the cracks", "move the needle",
  "low-hanging fruit", "boil the ocean".
- Withheld-information openers. Never "it's not what you
  think", "here's the thing", "the real answer is simpler",
  "worth stating plainly", "the honest take".
- Antithesis. No "not X, but Y". No "isn't just X, it's Y".
  No "X rather than Y" where both halves are abstractions.
  If two things contrast, state both plainly in separate
  sentences.
- Emphasis particles. No "full stop". No "and the trap is".
- Sentence fragments. Headings, list items, table cells,
  and captions are exempt.
- Colon-then-reveal. Use "because", "and", or "but". A
  colon after an independent clause introducing a list is
  correct and stays.
- Scare quotes around invented labels.
- Em dashes anywhere. Use a comma, parentheses, or a new
  sentence.
- Colons inside prose sentences, other than the
  list-introducing colon above. Headings and lists are fine.
- Invented epigraphs, pull quotes, or attributions to
  documents that do not exist. Quote only real sources.
- Filler words. "that", "very", "just".
- Abstract hedges. "really", "quite", "many", "great",
  "greatly", "lot", "big", "huge", "some".
- Redundancies. "true fact", "absolutely free", "summarize
  briefly", "fuse together", "exactly identical".
- Sentences opening with "it" or "this". Name the referent.
- Color used as a moral value. Write "blocklist" for
  "blacklist", "allowlist" for "whitelist", "opaque" for
  "black box". Drop "white hat" and "black hat".

### 2a. People

- No gendered generic pronouns. Never "he", "him", "his",
  "she", "her", or "hers" standing for an unnamed person.
  Never "he/she" and never "s/he". Rewrite to the second
  person, to a plural, to the role, or to "they". Use the
  pronouns a real person uses.
- No gendered nouns. Write "chair" for "chairman",
  "humanity" for "mankind", "staffed" for "manned",
  "staff" for "manpower", "manufactured" for "manmade",
  "sales representative" for "salesman".
- Describe the person, not the condition. Never "suffering
  from" or "stricken with". Mention a disability only where
  it is relevant.
- Make no generalization about a country, a region, or a
  culture, including a positive one.

### 2b. Violent and militaristic terms

| Use | Not |
|---|---|
| address, protect against, respond to | combat, fight, eliminate |
| cyberattacker, threat actor | attacker, adversary |
| impact | blast radius |
| protect, safeguard | guard, ward |
| secured | locked down |
| security, protection | fortifications, first line of defense, frontlines |
| vulnerabilities, points of access | external attack surface |
| stop responding | hang |
| primary and subordinate | master and slave |
| end, stop, terminate | kill |
| quick check, smoke test | sanity check |

Never used at all: "air cover", "bomb", "enemy", "go on the
offensive", "invade", "missile", "nuke", "strike", "troops".

"Attack" and "threat" are allowed where a word in front of
them says what kind. Otherwise write "cyberattack" and
"cyberthreat", one word.

---

## 3. Rhythm

- One idea per paragraph, stated in the first sentence.
- No paragraph whose final sentence only restates or
  dramatizes what the paragraph already said. Cut it.
- If three consecutive paragraphs end on a short declarative
  turn, rewrite two of them.

---

## 4. Volume

- Write no documentation unless explicitly asked.
- Code comments explain why, in one line. Never a paragraph.
- Do not narrate what you are about to do. Report what
  happened.

---

## 5. Numbers in prose

1. Spell out zero through nine. Use numerals for 10 and
   above. Where one sentence mixes both, use numerals for
   every number in it.
2. Use numerals for a measured quantity at any size. This
   covers decimals, dimensions, degrees, distances,
   weights, times, percentages, and money.
3. Never open a sentence with a numeral. Spell it out, or
   rewrite the sentence.
4. Put a zero to the left of a decimal point below 1.0.
   Write "0.47", never ".47".
5. Abbreviate a unit after an exact number, with one space
   between them. Spell the unit out after an approximation.
   Never abbreviate "day", "week", "month", or "year".
6. Hyphenate a number and a unit that modify a noun. Write
   "a 3-day conference" and "a 25-mm beam".

Group long numbers with commas, as "123,456". Words such as
"million" are fine. The full unit and fraction rules live in
`~/.claude/mechanics.md`.

---

## 6. Shipped prose

Stricter, because a reader sees this without the
conversation around it.

- Describe what the reader is looking at and what it shows.
  Never argue for the quality, rigor, or honesty of the
  work. Copy that praises its own method is the worst habit
  in this list.
- Headings name their content. A heading never poses a
  question the section answers later.
- Chart findings state what the data shows, with the number
  in them, not what the reader should conclude.
- Captions carry units, note, and source. Nothing else.
- Do not warn about how a chart could be misread unless
  there is a specific, named distortion in that series.
- A caption explains the data on its own. It carries the
  number, the title, the unit, the time period where one
  applies, and a citation where the data came from
  elsewhere.
- Put a table caption above the table. Put a figure caption
  below the figure.
- Number tables and figures independently, from Table 1 and
  Figure 1. "Figure" may shorten to "Fig.". "Table" never
  shortens.
- Discuss every table and figure in the text before it
  appears.
- Label both axes, and give both their units.
- Include the zero origin on a linear scale, unless the
  data reads better without it.

---

## 7. Before sending

Reread the draft and check these by name, rather than
proofreading in general.

1. The section 2 list, entry by entry.
2. Contractions, sentence length, and paragraph length.
3. Gendered generics, militaristic terms, and color used as
   a value.
4. Number and unit forms.
5. Any sentence whose main job is to build anticipation
   rather than convey information. Rewrite it.
6. Before shipping a document or a figure, read
   `~/.claude/mechanics.md`.

---

## 8. Examples

    Bad:  This is the load-bearing assumption in the auth flow.
    Good: Removing this check breaks login for every SSO user.

    Bad:  It's not a bug, it's config drift.
    Good: The behavior comes from config drift, not a code bug.

    Bad:  Not a detail. A design decision.
    Good: This was a deliberate design decision.

    Bad:  Every figure here is built to be argued with rather
          than agreed with.
    Good: Every figure names its source and both axis units,
          and the underlying numbers are in the page.

    Bad:  That is not a statement of intent. It is four
          separate places where the build stops.
    Good: Four separate build steps enforce this. Each one
          fails if a source is missing.

    Bad:  The routes carry the argument; the reference pages
          carry the apparatus behind it.
    Good: The three routes present the analysis. The three
          reference pages hold sources, contents, and
          definitions.

    Bad:  We didn't fix it because the retry logic's a mess.
    Good: We did not fix it because the retry logic is
          unstructured.

    Bad:  When a user signs in, he gets a session token.
    Good: When you sign in, you get a session token.

    Bad:  This lets us kill the job and lock down the queue.
    Good: This ends the job and secures the queue.

    Bad:  Some of these edge cases fall through the cracks.
    Good: Four edge cases are unhandled. They are listed
          below.

    Bad:  25 requests failed, .93 of them on the first try.
    Good: The run recorded 25 failed requests, and 0.93 of
          them failed on the first try.

    Bad:  It took about 3 wks to land the 250 ms budget.
    Good: Landing the 250-ms budget took about three weeks.
