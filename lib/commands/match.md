# /match

Make what we built match a design reference, detail by detail. I will give you a
Figma link (a frame or layer) or a screenshot, and say which page or component
it is. If I have not said which, ask.

This is where I have taste and the reference is the decision. Your job is to
reproduce it faithfully, not to improve it. If something in the design looks
inconsistent (15px here and 16px there, two greys that are nearly the same),
ask me which I meant rather than tidying it up.

Use `pnpm exec harness` if the project has a `pnpm-lock.yaml`, otherwise
`npx harness`.

## Stage 0. What you need

- **A running page.** The URL of the dev server route that shows this design.
  If no dev server is running, start it in the background and use its URL.
- **Playwright** in the project, for `harness shot`. If it is missing, ask me
  before adding it (it is a dependency): `npm i -D playwright` and
  `npx playwright install chromium`.
- **For a Figma link**, the Figma MCP server. If its tools are not available,
  say so, tell me the one-line setup from `docs/SETUP.md`, and meanwhile work
  from a screenshot of the frame as below.

## Stage 1. Read the design, as numbers

**From Figma**, for the node in the link:

- `get_design_context`: structure, layout (auto-layout direction, gaps,
  padding, alignment), sizes, text.
- `get_variable_defs`: the variables and styles in use. These are the values
  to build with.
- `get_screenshot`: the picture, to keep the numbers honest.
- The frame's width. That is the viewport width everything is measured at.

Save a reference image for the pixel comparison at
`.harness/shots/<name>-ref.png`: through `download_assets` if the server
offers it, otherwise ask me to export the frame as PNG at 2x and drop it
there.

**From a screenshot**, there are no exact values. Measure what you can from
the image, and write down each estimate you are building on (card padding
about 20px, heading about 32px semibold). Send me that list once, with the
ones you are least sure of first, so I can correct the few that matter; carry
on building while I look.

Either way, end this stage with a spec table, one row per element that
matters:

| Element | Property | Design value | Token |

## Stage 2. Map values to the design system

Find the project's tokens (Tailwind theme, CSS custom properties, a theme
file). Fill in the Token column. Where a design value has no token, do not
invent one and do not round to the nearest: flag it. Either the design drifted
from the system or the system is missing a token, and that is my call.

## Stage 3. Build

Build it, or adjust what exists, from the spec table. Stay inside the component
or page in question; a change to a shared component goes past me first.

## Stage 4. Measure

```
npx harness shot <url> --width <frame width> --reference .harness/shots/<name>-ref.png --styles "<selectors for the elements in the table>"
```

It renders at the frame's width and the reference's pixel density, waits for
web fonts, and prints JSON:

- `styles`: the computed type, spacing, colour, radius and size of each
  matching element. **Compare these with the spec table, row by row.** This is
  the real check; it catches the 2px differences no one sees in a picture.
- `compare`: an image with reference, render and a difference layer side by
  side. Open it and look at the red.
- `mismatch` and `hotBands`: how much differs, and at which heights. A pointer
  to where to look, never a score to drive to zero; text rendering alone keeps
  it above zero.
- `fontsNotLoaded`: if this lists anything, fix the font before anything else,
  because every text measurement is wrong until you do.

Then walk the checklist, stating for each item whether it matches, and if not,
both values:

1. Typography: family, size, weight, line height, letter spacing, case
2. Spacing: padding, gaps, margins between the blocks
3. Alignment and layout direction
4. Colour: text, backgrounds, borders
5. Borders and radii, shadows
6. Sizes: fixed widths and heights, icon sizes
7. Text behaviour: wrapping, truncation, what happens with a long string

## Stage 5. Fix and repeat, at most three passes

Fix what the checklist found and measure again. Stop when the checklist is
clean or after the third pass, whichever comes first. Do not loop past three:
what is still different by then needs me, not a fourth attempt.

## Stage 6. States and breakpoints

If the design shows more than one frame for this thing (hover, focus, empty,
error, loading, a mobile width, dark mode), take each in turn:

- other widths: `--width <that frame's width>`
- hover and focus: `--hover "<selector>"`, `--focus "<selector>"`
- dark mode: `--scheme dark`
- empty, error and loading states need the data to be in that state. If that
  means stubbing it, mark the stub `SPIKE(<today>)`.

Only the states the design shows. Do not invent ones it does not.

## Report

Short. Then stop; I will look at it myself.

1. What matches now, in one line.
2. A table of anything still different: element, property, design, build, and
   why it is left (a font not available, a value with no token, something CSS
   expresses differently from how Figma draws it).
3. Design values with no token, for me to decide.
4. The path to the last `compare` image.
