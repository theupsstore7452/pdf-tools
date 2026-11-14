# Impose workflow audit and simplification

Date: 2026-11-12. Target: the existing local development server on port 3001.
The deployed app was not changed. Scope: the impose interface, not PDF layout or export algorithms.

## Verdict

Pass: the workflow retains the app's established visual language and print-specific behavior.
The basic path is now **Size → Sheet → Review**. Advanced capabilities were retained,
not removed; only their initial visibility changed.

Scoped health estimate after this pass: **16/20 — Good**. These are qualitative scores
for the inspected paths, not WCAG certification or a full performance benchmark.

| Dimension | Score | Evidence and limits |
| --- | --- | --- |
| Accessibility | 3/4 | Native disclosures; labeled fields; keyboard-operated tabs with panel relationships and focus restoration; validation recovery links. Full assistive-technology certification remains untested. |
| Performance | 3/4 | Disclosures, review navigation, zoom and guide visibility do not request a new layout. Existing preview assets have bounded caching. No large-file profiling was performed. |
| Theming | 3/4 | New surfaces use existing semantic tokens and were viewed in light and dark themes. The broader legacy stylesheet was not refactored. |
| Responsive design | 3/4 | Chromium/Firefox checks at 320, 390, 768 and 1440px, plus short landscape. Chromium synthesized-touch canvas scrolling passes; physical devices and Safari remain unverified. |
| Implementation integrity | 4/4 | Existing components and print settings preserved; output summary uses live state; advanced edits survive navigation; zoom and guides remain preview-only. |
| Total | 16/20 | Good; no blocking defect found in exercised paths. |

## Findings addressed

Eight P2 findings; no P0/P1 failure was established in the tested paths. No cosmetic P3 backlog was added.

| Finding | Category and location | User impact | Change |
| --- | --- | --- | --- |
| Final step presented as “Bleed” | Implementation integrity · `elm/View.elm`, `setupView` | Beginners had to understand a specialist term before reaching download. | Renamed the step Review. Output details and printer-scale guidance lead; trim/bleed settings remain expandable. |
| Layout choices competed with the first decision | Implementation integrity · `elm/View.elm`, Size step | Orientation, automatic arrangement and custom rows/columns distracted from finished dimensions. | Grouped these under Orientation and layout; active manual grids reopen when returning to the step. |
| Guide explanation occupied permanent preview space | Responsive design · `elm/Preview.elm` | Especially on phones, explanations crowded the artwork. | Kept zoom visible and moved guide controls, legend and explanation under Guide options. |
| Navigation shown for one sheet | Implementation integrity · `elm/View.elm`, `toolbarView` | Two disabled arrows suggested unavailable work and consumed space. | Show a one-sheet status instead; retain navigation for multiple sheets. |
| Mobile preview lacked a clear finishing action | Responsive design · `elm/Preview.elm` | Users had to infer how to leave Preview and reach export. | Added Review and download, which returns to Review without exporting or changing print settings. |
| Invalid settings could require hunting through steps | Accessibility · `elm/View.elm`, Review and advanced sections | A disabled download did not itself tell users where to correct an error. | Added links back to size/layout or sheet/copy settings; relevant invalid advanced fields reopen. Print warnings remain outside collapsed trim settings. |
| Workspace tabs lacked conventional arrow-key behavior | Accessibility · `elm/View.elm`, `elm/Main.elm` | Keyboard users could not navigate the tablist consistently. | Added roving tabindex, Arrow keys, Home/End, panel relationships and focus restoration. Reference: WAI-ARIA APG Tabs pattern; not asserted as a demonstrated WCAG AA failure. |
| Disabled duplex choice lacked context | Implementation integrity · `elm/View.elm`, Sheet step | Odd-page artwork made double-sided printing unavailable without explaining the requirement. | Explain that each front/back pair needs two artwork pages. |

The recurring problem was presenting specialist decisions as part of the default path.
The solution is progressive disclosure with retained state and visible recovery—not removing capabilities.

## Positive findings preserved

- Clear primary Next and Download actions; actual output and dimensions come from application state.
- Existing light/dark tokens, generous touch targets, native controls and reduced-motion support.
- PDF production geometry and warnings remain server-owned.
- Preview-only inspection does not change export settings or cause layout work.
- Preview asset eviction remains bounded (32 cached assets / 128 MiB, protecting displayed assets).

## Verification

From the repository root:

```sh
npm run build --prefix frontend
(cd frontend && PATH="$PWD/node_modules/.bin:$PATH" npm test && npm run format:check)
nix develop --no-write-lock-file -c python scripts/interface-browser-regressions.py --url http://127.0.0.1:3001 --browsers chromium,firefox --output /tmp/pdf-tools-impose-final
```

Passed, exit 0: optimized frontend build; 111 Elm tests; 6 bootstrap/watcher tests;
format validation; the expanded Chromium/Firefox interface suite, including all five
export workflows, collapsed defaults, advanced-setting retention, invalid drafts,
print warnings, mobile Review action, keyboard tabs, multiple-sheet navigation and
Chromium synthesized-touch scrolling.

The legacy acceptance checks also passed in Chromium and Firefox, exit 0:

```sh
nix develop --no-write-lock-file -c python scripts/elm-browser-acceptance.py --url http://127.0.0.1:3001 --browsers chromium,firefox --checks general,setup_tabs,setup_polish,preset_toolbar,preview_toolbar,copy_quantities --output /tmp/pdf-tools-impose-acceptance-final
```

Rendered screenshots cover both themes and the Size, Sheet, Review and mobile Preview paths.
The bundled detector was run against the populated local Review screen:

```sh
impeccable detect --cdp 9227 --target 127.0.0.1:3001 --json
```

Detector exit 2: only `overused-font` for the incumbent Inter font. This is not a
product usability defect; the existing typeface was deliberately retained in Operate mode.
No font replacement was warranted by that warning.

## Follow-up

No further feature removal is recommended. Test the common path with a first-time user,
particularly their understanding of finished-piece size versus print-sheet size.
Physical-device Safari, real-device touch, a dedicated 200% text-scaling assessment,
full screen-reader coverage and large-file performance remain manual/unverified work.

The applied sequence was simplification, clearer language, responsive/accessibility
corrections and a final `$impeccable polish` pass. Re-run `$impeccable audit` after
feedback-driven changes; the score should not be treated as a certification.
