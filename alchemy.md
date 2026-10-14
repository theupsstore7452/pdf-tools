# PDF Tools Invariants

This document records the durable rules that PDF Tools changes must preserve.

## INV-shared-da-components: Use the shared web app components

- **Scope:** Common controls, theme styling, dialogs, and frontend packaging.
- **Rule:** Use `da-components` for common UI controls and their visual styling so web apps share a consistent appearance. Every selection dropdown must use `Da.Dropdown`, including sheet size, printing sides, duplex flip edge, orientation, tools, and preset selection; do not use native select menus. Use DA popovers for anchored forms. Keep domain state and workflow layouts in the app. Consume the same pinned, self-contained source bundle in Squire and PDF Tools; include its Elm sources, stylesheet, and browser adapter in every build and cache identity without depending on a sibling checkout. The shared adapter owns its component focus and dialog mechanics. Preserve drafts, accessible labels, validation, themes, and existing workflow behavior.
- **Evidence:** Shared component tests and browser contracts, application compilation and workflow regressions, and asset packaging checks.
- **Origin:** October 12, 2026 user request for both apps to use DA components to standardize the look of their web apps. Shared component styling supersedes earlier app-specific control styling requirements. The October 13, 2026 screenshot correction requires all selection dropdowns to use the styled DA dropdown.

## INV-JAVASCRIPT-BOOTSTRAP: Start Elm through plain JavaScript

- **Scope:** Browser initialization, browser resources, and frontend builds.
- **Rule:** Mount Elm and attach its browser resource bridge using plain JavaScript without the OCaml `elm-browser` library, its Elm companion, or an OCaml build toolchain. Rust serves generated assets and owns PDF processing; Elm owns application state. Preserve PDF resource lifecycle behavior, raw saved theme preferences, storage-failure feedback, and startup Retry. Include the JavaScript bootstrap in versioned assets and all development, CI, and container build paths; builds must not depend on a sibling checkout.
- **Owner:** `frontend/browser/bootstrap.js`, `frontend/bridge.js`, `frontend/elm/Main.elm`, and frontend build/packaging configuration.
- **Evidence:** Optimized frontend build; startup, theme persistence, and storage-failure browser checks; container checks of all five versioned assets and gzip sidecars.
- **Origin:** October 13, 2026 user request to replace PDF Tools' OCaml bootstrap library with plain JavaScript, superseding the October 12 shared-library requirement for this app.

## INV-NO-EXPORT-HISTORY: Keep exports out of persistent history

- **Scope:** PDF downloads, imposition catalogs, and server data storage.
- **Rule:** Do not retain export-history records or archive exported files, and do not expose export-history controls or endpoints. Remove legacy app-owned export archives on startup. Temporary output needed for an active download may exist for the bounded job lifecycle. Explicitly saved presets and job settings remain available.
- **Owner:** The Rust export, startup, and catalog boundaries and the Elm saved-settings view.
- **Evidence:** Backend checks of removed history endpoints, legacy cleanup, and successful exports without archive writes; browser checks of downloads and saved settings without history controls.
- **Origin:** The user explicitly rejected export history, its interface, and storage of previous exports.

## INV-TOAST-FEEDBACK: Keep notifications from moving the workspace

- **Scope:** Runtime workflow progress, confirmations, and operation errors.
- **Rule:** Show feedback as compact bottom-right toasts using the existing neutral theme, without inserting top banners or changing workspace geometry. Keep cancellation, retry, keyboard dismissal, and accessible announcements available. Routine confirmations expire; errors remain until dismissed or resolved. Respect reduced motion and narrow viewports. Retain local field validation and the established startup recovery indicator.
- **Owner:** The Elm notification state and root view and shared toast styles.
- **Evidence:** Model checks of expiry, stale timers, and retained error state; browser checks of geometry during progress, failures, and success, keyboard dismissal, retry, mobile containment, and both themes.
- **Origin:** The user requested clean, simple bottom-right toasts in place of jarring top banners that move the interface.

## INV-UI-STYLE: Keep the interface minimal and typography led

- **Scope:** PDF Tools interface styling and style revisions.
- **Rule:** Use large, readable type and restrained neutral surfaces, with a blue accent for shared DA primary actions, selections, and keyboard focus in both themes. Primary action labels and selected-control labels must meet WCAG AA text contrast, and focus indicators must remain discernible. Rounded tool cards must retain visibly rounded corners where their navigation and content meet the frame. Avoid green accent branding, pervasive control and panel outlines, decorative brand and tool icons, and nonessential subheader copy. In the empty state, center the upload card itself in the viewport when space permits, with the PDF Tools heading and theme toggle directly above it; the toggle uses the shared DA appearance in both themes. Omit the introductory slogan and the Convert/Extract/Merge/Impose summary below the card. Retain useful labels, validation, status feedback, and visible keyboard focus. Treat Uniswap as a reference for visual restraint, not as a design to copy. Style revisions may make only minor layout adjustments; more substantial layout changes require explicit user approval.
- **Owner:** The Elm views and shared frontend styles.
- **Evidence:** Review rendered upload, document, and print workspaces in both themes; inspect tool-card corner containment and measure primary action, selected-control, and focus contrast; compare panel geometry before and after style revisions and exercise keyboard access and representative narrow viewports with the browser acceptance suite.
- **Origin:** The user rejected the green, outlined, icon-heavy UI pass and requested a minimal, utilitarian style with bold, readable typography, using Uniswap as a visual reference while restricting layout changes. The user later requested integrating the empty-state title and theme toggle near the upload card and removing both its slogan and the tool-summary copy, then clarified that the upload card itself must be centered even though its header sits above center. The user required the empty-state toggle background to match the upload card in both themes and fully rounded tool-card corners. The October 12, 2026 frontend correction supersedes the previous neutral-accent decision and the shared pink default with a blue accent.

## INV-STARTUP-RECOVERY: Show loading and recoverable startup failures

- **Scope:** Initial browser startup.
- **Rule:** Keep the upload interface client-rendered. Initially show only the saved or system theme's background. If initialization is still pending after 700 ms, show a subtle “Opening PDF Tools…” indicator rather than a full-screen loading page. Reveal an actionable failure message with Retry immediately on initialization failure. Remove startup feedback as soon as initialization succeeds, without an artificial minimum display time. Do not server-render or hydrate the upload interface.
- **Owner:** The frontend HTML startup boundary.
- **Evidence:** Browser checks of fast startup without an indicator, a delayed request crossing the 700 ms threshold, immediate failed-request feedback, retry after restoring the request, and saved/system themes before initialization.
- **Origin:** The user retained client rendering and startup recovery, then explicitly replaced the flashing loading page with a 700 ms delayed indicator and immediate failure feedback when updating PR 7.

## INV-WORKFLOW-RECOVERY: Preserve state across workflow loading

- **Scope:** Browser startup and first entry into a PDF workflow.
- **Rule:** Retain selected files and settings during loading and recovery. A failed workflow request must allow retry without reselecting files; a completion after leaving a workflow must not restore that workflow. Production asset URLs must identify the matching build so an existing tab cannot load incompatible replacement code.
- **Owner:** The Elm workflow state machine and release asset build.
- **Evidence:** Browser checks of failed-request retry and navigation during delayed requests; release smoke checks of versioned Elm, bridge, and CSS assets.
- **Origin:** Preserves the state retention and asset identity requirements of the former deferred Leptos workflows; the main Elm frontend loads its workflow code in one bundle.

## INV-DEV-SERVER-PORT: Keep the inspection server on port 3200

- **Scope:** Local development work on PDF Tools.
- **Rule:** Serve PDF Tools at `http://127.0.0.1:3200` while working so the user can inspect changes. Development startup must serve the current checkout's generated frontend even after the checkout moves with cached Rust artifacts. Resolve the server's frontend directory at runtime and reject a missing entrypoint before listening.
- **Owner:** The PDF Tools local development workflow and Rust server startup.
- **Evidence:** An HTTP request to `http://127.0.0.1:3200` succeeds while the development server is running; moved-checkout startup and explicit-directory asset-delivery regressions.
- **Origin:** The user explicitly required PDF Tools to always be served on port 3200 for inspection.

## INV-WORKFLOW-TRANSITION-COHERENCE: Animate workflow contents with their container

- **Scope:** Transitions between all available PDF Tools operations.
- **Rule:** Animate every tool change. When an operation changes the workspace height, the outer card and its internal layout—including the primary action—must move together without content jumping, overlapping, losing settled padding, or blocking interaction. In the compact vertical stack, file rows, settings, and the download action must remain coordinated while entering or leaving Impose. Switching between generic workflows must expand or contract quickly. The transition must become immediate when the user prefers reduced motion.
- **Owner:** Elm tool switching, the browser workspace transition boundary, and workflow layout styles.
- **Evidence:** Exercise growing and shrinking operation changes with `agent-browser` at desktop, laptop, half-screen, and mobile viewports, sampling the outer card, controls, and primary-action positions throughout the transition. `scripts/workspace-motion.mjs` checks all five tools, rapid generic reversal, reduced motion, overlap, overshoot, and final geometry.
- **Origin:** The user explicitly required all workflow contents, including the download button, to move with the animation. The October 13, 2026 screenshot correction requests a quick expansion into the taller PDF-to-images workspace. The subsequent October 13 request requires smooth transitions between all tools and an updated Impose transition for the vertical stack.

## INV-LOADING-GEOMETRY: Keep transient loading feedback from moving the workspace

- **Scope:** First generic workflow entry, failed-module Retry, and imposition artwork inspection.
- **Rule:** Keep the upload view visible until the first generic workflow is ready, without showing an intermediate short workflow card. Retry must not shrink that loading view before revealing the workflow. Checking replacement artwork must preserve the existing imposition workspace bounds and expose cancellation without inserting a row above its controls.
- **Owner:** The app workflow-loading boundary and inspection feedback view.
- **Evidence:** Agent-browser frame measurements of first upload, failed-module Retry, and repeated artwork replacement, including a delayed inspection and cancellation.
- **Origin:** The user requested fixes for the first-upload stutter and the two matching transition defects found in the subsequent audit.

## INV-TOOL-SELECTION-CONTEXT: Select tools in place of the application brand

- **Scope:** Tool selection in populated PDF Tools workspaces.
- **Rule:** In populated workspaces, replace the header's generic PDF Tools brand text with the shared DA tool dropdown at the left of the header. In the imposition workspace, align the dropdown's left edge with the Size tab below it. Give it a visible DA control surface at rest so tool selection is discoverable without hover or extra visible text. Its hover and open backgrounds cover the full padded control, and menu-row highlights surround their labels with padding. Keep its visible chevron, accessible label, keyboard focus, and reachability at narrow widths and during workflow recovery. Do not repeat the selected tool title in the generic settings card; keep that form accessibly named. Impose navigation remains dedicated to its workflow. Switching tools retains selected files and settings.
- **Owner:** Elm header and workflow views and responsive header styles.
- **Evidence:** Browser checks of generic and impose switching, preparation recovery, keyboard access, selector and menu hover padding, absence of duplicate settings headings, and selector visibility and menu containment at desktop and narrow widths in both themes.
- **Origin:** October 12, 2026 user correction to replace the generic PDF Tools header text with the tool dropdown, superseding the earlier panel-heading and setup-rail placement; the subsequent correction requires full-element hover highlights and removes the redundant tool title from the right-hand card. The October 13, 2026 correction requires discoverability before hover without extra text. The subsequent screenshot correction aligns Impose artwork to the left above Size.

## INV-HEADER-CONTROL-SIZING: Keep the theme toggle aligned with header buttons

- **Scope:** The PDF Tools headers and populated-workspace header actions.
- **Rule:** Use the shared DA theme toggle with a 44-pixel height in both headers. In populated workspaces, group Add, Replace, and Clear in one shared DA command menu using its shared dropdown trigger with a 44-pixel height, and place the separate theme toggle immediately to its right. Workspace must use the DA dropdown surface and chevron, with actions requiring explicit activation rather than running on dismissal. Match the tool dropdown's popup border, corners, shadow, typography, padded rows, and neutral pointer highlights; reserve row focus outlines for keyboard navigation. Size the Workspace popup to its action labels, preserving single-line labels and viewport containment at supported widths. Keep theme switching out of the Workspace menu. Omit the redundant current-file count and byte-size header element.
- **Owner:** The application header control styles.
- **Evidence:** Inspect toggle geometry and placement, populated header menu actions, keyboard dismissal, dialog focus return, and containment at desktop and mobile widths.
- **Origin:** The user requested a uniform header toggle height, then on October 12, 2026 requested combining populated header actions and removing the file-count/size element. The subsequent correction explicitly places the DA light/dark toggle to the right of Workspace and excludes theme switching from its menu. The October 13, 2026 correction requires Workspace to be a dropdown from DA components; the subsequent screenshot comparison selects the Impose artwork tool dropdown's visual style for Workspace, followed by a correction to its oversized popup.

## INV-COMPACT-WORKFLOW-CONTROLS: Keep workflow rows and choices coherent

- **Scope:** Selected files, imposition setup navigation, and page-selection actions.
- **Rule:** Use the shared DA file-list component for single-row files in both generic and imposition workflows, retaining filenames, page details, ordering when relevant, and removal. PDF to images, Extract pages, Combine PDFs, and Images to PDF use a narrow, compact stacked workspace: content-sized file rows above settings and a readily reached export action below, without large enclosing file or export panels. Short lists must not stretch to fill unused space; long lists scroll within a bounded region. Generic workflows show ordering controls and their hint only with multiple files. Keep imposition file rows compact. Give Size, Sheet, and Bleed equal-size navigation buttons. Page-selection actions must not have a differently styled background frame. List Use each page once before Repeat pages. Selecting Repeat pages opens the quantity dialog immediately. When repeat printing has one copy quantity, retain the labeled Copies input; multiple quantities use a neutral summary card showing total impressions and page or pair quantities with an Edit action.
- **Owner:** Da.FileList and the PDF Tools workflow views and layout styles.
- **Evidence:** Shared component contracts and browser checks of single-file and multi-file stacked geometry, bounded long lists, ordering, removal, equal setup-button dimensions, page selection, and narrow viewports in both themes.
- **Origin:** October 12, 2026 user frontend correction with compact file-row and workflow-control references; the subsequent screenshot correction requests only a labeled Copies input for a single quantity. The October 13, 2026 screenshot corrections first requested aligned download actions and more room for short lists, then replaced the large export panels with full-width lists and compact actions and required opening quantities directly from Repeat pages. The subsequent October 13 request selects a compact stacked layout for PDF to images and similar workflows, superseding stretched short lists and side-by-side settings panels.

## INV-BROWSER-VIDEO-CAPTURE: Keep agent-browser video capture available

- **Scope:** The PDF Tools Nix development shell.
- **Rule:** `nix develop .#pdf-app` must provide both `agent-browser` and `ffmpeg` so browser audit recordings can be finalized without undeclared host tooling.
- **Owner:** The `devShells.<system>.pdf-app` package declaration in the repository flake.
- **Evidence:** Inside `nix develop .#pdf-app`, `agent-browser --version` and `ffmpeg -version` succeed, and a short agent-browser recording can be stopped into a non-empty WebM file.
- **Origin:** The user explicitly required ffmpeg in the project shell for video capture.

## INV-DEFAULT-DEVELOPMENT-SHELL: Supply the native development command dependencies

- **Scope:** The repository's default Nix development shell and documented Just commands.
- **Rule:** Plain `nix develop` selects the full `pdf-app` shell, including Node/npm, Rust and frontend/browser tooling needed by `just dev` and `just check`. Keep the named `pdf-app` shell compatible with CI and expose the lightweight container command shell separately as `commands`.
- **Owner:** `devShells.<system>` in `flake.nix` and the development instructions in `README.md`.
- **Evidence:** The default and named `pdf-app` shells evaluate to the same derivation; Node/npm and Cargo resolve inside the default shell, and `just check` can start its frontend dependency installation.
- **Origin:** October 12, 2026 user report that `nix develop` followed by `just check` fails because npm is missing.

## INV-IMPOSITION-RECOVERABLE-PROGRESSION: Keep imposition progression explicit and recoverable

- **Scope:** The browser imposition workflow from artwork selection through output.
- **Rule:** Choosing an imposition mode must preserve that choice without unintended advancement; invalid layout input must not advance; disclosures must not submit; modal focus must remain contained and return to its trigger; and preparation failures must retain per-file removal so the user can recover without restarting. In Edit copy quantities, Apply to all or Enter in Copies for all must commit the valid bulk quantity to every page or duplex pair, replace stale individual drafts, close the dialog, and return focus to its opener. Invalid bulk input must not apply or close.
- **Owner:** The imposition workspace state machine and browser view.
- **Evidence:** Frontend model and keyboard-event tests plus browser exercises of Repeat, custom-grid disclosure and validation, bulk Enter for simplex and duplex quantities, quantity-dialog keyboard focus, and mixed-file failure recovery.
- **Origin:** The user requested fixes for the audited imposition usability and recovery failures, with imposition as the most important workflow.

## INV-PDF-SELECTION-KNOWN-VALID: Validate selected PDFs before enabling dependent work

- **Scope:** Browser selection and page-range controls for PDF workflows.
- **Rule:** A selected PDF must be proven readable and have an authoritative page count before it becomes active. General document intake must accept readable PDFs with mixed page sizes or orientations. Imposition must retain each page's geometry and resolve finished sizing rather than rejecting artwork solely because pages differ. Page-range controls must reject pages outside that known boundary before submission and explain when a changed source invalidates a retained range; a rejected replacement must preserve the previously valid workspace.
- **Owner:** The generic workspace PDF-preflight boundary and page-selection model, with the server remaining authoritative for untrusted requests.
- **Evidence:** Frontend model tests and agent-browser exercises using corrupt PDFs, valid replacement state, and out-of-range selections.
- **Origin:** The user requested fixes for late corrupt-file and out-of-range failures found in the workflow audit.

## INV-PRINT-OUTPUT-CHOICES: Expose required print geometry and extraction packaging

- **Scope:** Images-to-PDF and Extract Pages workflows and their multipart job contracts.
- **Rule:** Images-to-PDF creates one PDF page per ordered image at its natural 300 DPI size. Its browser workflow does not expose page resizing, orientation, fitting, or margin choices; the server may retain fixed-page request compatibility for existing API clients. Extract Pages must offer individual PDFs, one combined PDF, and bounded page chunks. The browser must expose these choices and the server must independently validate them.
- **Owner:** The generic workflow controls and the `/jobs` conversion and extraction request handlers.
- **Evidence:** Frontend contract tests, backend document and web-handler tests, and successful agent-browser exports for original-size image output plus combined and chunked extraction.
- **Origin:** The user requested fixes for missing image page geometry and extraction packaging discovered in the workflow audit.

## INV-FINISHED-SIZE-FIRST: Express the intended print product before source geometry

- **Scope:** Imposition artwork sizing and placement.
- **Rule:** Accept mixed-size PDF pages and images, but always have the user explicitly define the intended finished dimensions. Keep width and height visible and editable; reusable presets are explicit user-invoked workflow shortcuts, never inferred intent. Do not automatically use original source sizes or apply a preset. Preserve explicitly chosen dimensions across fitting, bleed changes, retries, and replacement; retain explicitly saved per-piece overrides when restoring job settings. Fit preserves proportions and retains all artwork, Fill preserves proportions using the retained crop position, defaulting to center, and opt-in Stretch independently scales both axes with a clear distortion explanation. Do not infer customer intent from source geometry or silently shrink oversized artwork.
- **Owner:** Source analysis, imposition requests, and finished-size controls.
- **Evidence:** Mixed-source and odd-aspect-ratio print workflows, exact exported cut sizes, and visible image-sizing assumptions.
- **Origin:** The user regularly receives AI-generated images with unsuitable aspect ratios and approved a finished-size-first mixed-artwork workflow. The subsequent fitting-only toolbar correction removes manual per-piece and crop controls while retaining saved settings and processing.

## INV-FIT-BLEED-PARITY: Fitting and bleed must preserve deliberate framing

- **Scope:** Imposition preview and exported PDFs.
- **Rule:** Separate fitting artwork into its finished cut frame from extending artwork to add bleed. Preserve the chosen normalized crop position within the expanded bleed frame and show any additional edge loss, rather than promising fixed cut-relative landmarks. Preview and export must use the same placement plan, including each piece's source identity, cut rectangle, rotation, fitting, and clipping. A larger grid slot must never become a smaller piece's cut size. Duplex fronts and backs must remain registered.
- **Owner:** Layout planning, preview rendering, and PDF export.
- **Evidence:** Asymmetric labeled artwork with near-edge marks, contain/cover positioning, bleed toggles, mixed-size cuts, and duplex output checks.
- **Origin:** The user reported that Scale to add bleed crops strangely when converting odd-sized artwork into Letter flyers, making imposition unusable.

## INV-ORIENTATION-DISCOVERABILITY: Keep orientation out of advanced settings

- **Scope:** Imposition setup and preview.
- **Rule:** Use the styled DA dropdown for finished-size Portrait/Landscape in Size. Keep it easy to select without expanding Advanced. Impression placement retains its request and saved-settings semantics without a toolbar orientation control. Keep impression rotation controls out of Setup, including the duplicate manual-grid Item rotation. Distinguish finished dimensions, sheet placement, and source artwork rotation; update the preview and sheet counts immediately and retain duplex registration.
- **Owner:** Imposition controls and placement planning.
- **Evidence:** Desktop and half-screen browser workflows, keyboard access, and output orientation checks.
- **Origin:** The user explicitly requested easier impression-orientation selection and approved prominent orientation controls, then requested keeping rotation functionality in Artwork and removing its Setup duplicates. The subsequent fitting-only toolbar correction removes the impression-orientation UI.

## INV-ARTWORK-CONTEXTS: Keep artwork fitting directly in the toolbar

- **Scope:** Imposition setup, the workspace toolbar, and responsive sheet preview layout.
- **Rule:** Show Fit, Fill, and Stretch as one shared DA segmented field in the toolbar row, with an accessible group name and visible selection, without an Artwork fitting header or dropdown. Do not expose an Artwork tab or disclosure, per-artwork scope, source details, bulk rotation, impression orientation, per-piece dimensions, or crop position/reset controls there. Setup owns Size, Sheet, and Bleed, with responsive Setup/Preview navigation. Size includes arrangement and custom-grid controls below finished orientation; Sheet includes gutter, margin, and duplex settings; do not expose a separate Arrangement tab. Cut paths remain visible, and the sheet fits its canvas automatically. Preserve the separate canvas item action menu and the processing and saved-settings behavior of retained artwork options.
- **Owner:** The imposition toolbar view, shared DA segmented field, and application layout styles.
- **Evidence:** Browser checks of the segmented field, fitting changes and exports, absence of the removed controls and visible header, keyboard access, busy state, and toolbar containment at desktop and narrow widths.
- **Origin:** The user replaced the earlier Artwork inspector design with a fitting-only control directly in the toolbar row, then explicitly requested visible Fit, Fill, and Stretch buttons without a fitting header or dropdown. The subsequent October 13 correction groups these choices in a DA segmented field.

## INV-IMPOSE-TRANSITION-POLISH: Coordinate workflow frame and contents

- **Scope:** Entering and leaving Impose, including first deferred load and Retry.
- **Rule:** Keep the frame and workflow contents visually coordinated, without an intermediate collapsed card, clipped primary actions, or late layout jumps. Avoid restarting animations on resize-observer feedback. Rapid switching must not resurrect a departed workflow. Reduced motion must remain immediate, and loading/recovery must not discard files or settings.
- **Evidence:** Before/after real-browser frame traces for cold/warm entry, exit, rapid reversal, delayed/failed loading, Retry, and reduced motion. The `workspace_animation` browser acceptance check samples header, card, and action bounds during returns to PDF to images and Extract pages at desktop, laptop, and half-screen sizes to detect overshoot and late corrections.
- **Origin:** The user requested polishing the animations when switching into Impose.

## INV-IMPOSE-SETUP-STABILITY: Keep setup navigation in place

- **Scope:** Switching steps and scrolling controls in the imposition setup view.
- **Rule:** Keep an arrow-only Back control on the left and forward control on the right, always visible with accessible names. Disable Back at Size, forward at Bleed, and both while busy. Keep the final download action separate from the navigation arrows. Switching between Size, Sheet, and Bleed must preserve the setup navigation, scrolling-region, and footer bounds at a fixed viewport. Additional setup controls must scroll within the setup panel rather than displacing navigation; reusable saved settings belong in the workspace toolbar. Newly selected steps start at the top of their controls while retaining form values. Keyboard focus must not move the surrounding page.
- **Owner:** The Elm imposition setup view and its layout styles.
- **Evidence:** The `setup_geometry` browser acceptance check samples rendered frames during step changes, rapid reversal, and rail scrolling at desktop, short-screen, tablet, and mobile widths. The `setup_tabs` check exercises keyboard navigation and preserves validation and drafts. The `setup_polish` Python Playwright check covers persistent arrows and disabled endpoints in both themes.
- **Origin:** The user required stable right-side Continue and left-side Back buttons, a shorter Sheet tab label, and fixes plus regression tests for jitter when switching tabs and moving around the page. The October 12, 2026 screenshot correction replaces the text navigation buttons with always-visible arrows disabled when their direction is unavailable. The subsequent user request leaves three setup steps; the October 13, 2026 correction moves Arrangement to Size below finished orientation.

## INV-IMPOSE-PREVIEW-CONTROLS: Keep cut paths visible and the toolbar simple

- **Scope:** The imposition sheet preview and workspace toolbar.
- **Rule:** Always show cut paths without a guide toggle. Render cut paths in red and selection outlines in blue. For populated impressions with positive effective bleed, show a black dotted rectangle at the actual outside bleed boundary without a dotted-line key or bleed amount readout in the preview toolbar. Omit bleed rectangles when the effective amount is zero. Do not display gutter overlays. Keep cut paths and bleed bounds discernible over light and dark artwork, with a small fixed screen stroke as the canvas resizes. Keep artwork fitting, sheet status, duplex side controls, and saved presets consolidated into a single row above the canvas, with Presets at the far right and adjacent Previous sheet and Next sheet buttons. Automatically fit the sheet to the canvas without zoom controls. Do not offer a setup-collapse control; retain responsive Setup/Preview navigation and a usable setup scrolling region. Keep horizontal scrolling where needed to preserve toolbar reachability on narrow screens.
- **Owner:** The Elm SVG preview, workspace toolbar, and responsive styles.
- **Evidence:** The `preview_toolbar` browser acceptance check exercises always-visible cut paths, absence of guide toggles and gutter overlays, red cuts, blue selection, effective bleed bounds and absence of a toolbar bleed legend, multi-sheet navigation, absence of zoom and setup-collapse controls, duplex side switching, and stable toolbar bounds; `responsive` covers control containment and narrow-screen reachability.
- **Origin:** The user required a single-row toolbar and always-visible Cut paths, then moved presets to its upper-right end and removed setup-collapse and zoom controls. The October 13, 2026 screenshot correction requires red cuts, blue selection, black dotted outside bleed bounds, and visible current bleed information. The subsequent October 13 correction removes the dotted-line key and bleed amount readout from the toolbar while retaining the canvas bleed bounds.

## INV-ARTWORK-ROTATION: Rotate individual artwork before fitting

- **Scope:** Imposition canvas item actions, artwork settings, layout planning, and PDF output.
- **Rule:** Right-clicking a populated canvas item opens an extensible action menu for that artwork page. Support independent quarter-turn rotations and reset, with keyboard access. Retain existing bulk rotation in saved settings and processing without exposing bulk-rotation controls in the fitting-only toolbar. A restored bulk angle preserves per-page fitting and finished-size overrides. Apply rotation before fitting to the chosen finished size; an individual action affects every copy of the selected page only. Keep finished cuts, quantities, bleed geometry, and duplex registration intact; preview and export must agree. Retain rotation in saved job settings and default older settings to zero.
- **Owner:** Elm artwork overrides and the Rust page plan/export boundary.
- **Evidence:** Model checks of page scope, 200-page bulk rotation and preserved settings, Rust geometry/rotation checks, and the `artwork_rotation` browser acceptance check covering mixed orientations, canvas menu interaction, preview, and downloaded output.
- **Origin:** The user requested independent rotation through a canvas right-click menu so portrait and landscape example artwork can share an impose workflow, then requested removing redundant Setup rotation controls and keeping bulk rotation in Artwork for documents such as 200-page portrait artwork. The subsequent fitting-only toolbar correction removes the bulk-rotation UI while retaining individual canvas actions and saved settings.

## INV-CANVAS-SPACE: Keep production-count copy out of the canvas

- **Scope:** Imposition sheet preview.
- **Rule:** Do not reserve a bottom canvas section for pieces-per-sheet, sheet count, pieces-produced, or extra-piece summary text. Keep the released space available for inspecting artwork; retain actionable production warnings in setup.
- **Owner:** The imposition preview and setup views.
- **Evidence:** Browser inspection of the preview region without a summary strip and with a sheet filling its available height.
- **Origin:** The user explicitly requested removing the bottom production-count section to make more space in the canvas.

## INV-IMPRESSION-SELECTION: Make the selected impression clear

- **Scope:** Selecting, focusing, and opening actions for an impression on the impose canvas.
- **Rule:** Indicate the selected impression with a clearly visible outline at its finished cut, distinct from cut paths and readable over light and dark artwork. Keep its stroke at a modest fixed screen width as the canvas resizes. Selection must not obscure artwork or show the browser's large SVG focus ring. Keep keyboard focus discernible and indicate only the selected impression, including when multiple copies share a page and while its right-click rotation menu is open.
- **Owner:** The Elm impression selection state and SVG preview styles.
- **Evidence:** Browser checks of click, keyboard focus, open context menu and dismissal, repeated copies, and responsive sheet sizing; screenshots confirm a clear cut-bound indicator without artwork obstruction.
- **Origin:** The user initially requested a very small selection indicator, then requested a more obvious indication of the impression selected for right-click rotation after simplifying the guides to always-visible cut paths.

## INV-IMPOSE-PRESET-ACCESS: Reuse layouts throughout setup

- **Scope:** Saved presets in the imposition workflow.
- **Rule:** Make preset loading and saving available in the upper-right toolbar at every setup step and while inspecting the preview. Save the current valid shared printing and layout settings without requiring step completion or a finished preview. Loading is explicit, restores the preset settings, and retains the current artwork and its copy quantities without opening the quantity editor. Keep separate saved-job restoration for artwork-specific settings.
- **Owner:** The Elm workspace toolbar, preset save/apply state transitions, and preset API.
- **Evidence:** Model and browser checks of saving while layout is pending, applying and saving from all three setup steps and Preview, custom-grid settings round trips, and retained artwork and quantities.
- **Origin:** The user requested presets that can be loaded or saved at any time for recurring layouts such as business cards, 5 × 7, Letter, and 4 × 6 pieces on 12 × 18 sheets.

## INV-IMPOSE-SIZE-CONTENT: Keep size setup focused and artwork files visible

- **Scope:** Imposition Size and Sheet setup steps and the setup rail styling.
- **Rule:** Label the finished-dimension inputs Width and Height, retaining their units. Size keeps finished orientation, then Arrangement, and shows artwork files directly, including removal and ordering controls, without a collapsible file section or detected-artwork-details disclosure. Sheet owns Repeat pages / Use each page once alongside quantities and sheet settings. The setup tabs, scrolling fields, and navigation footer share one neutral background. At desktop widths, the setup tabs and preview toolbar share one row with a continuous divider across the workspace.
- **Owner:** Elm setup views and the PDF Tools DA theme/layout styles.
- **Evidence:** Frontend state tests and browser acceptance of visible files, orientation keyboard selection, page modes in Sheet, uniform setup surfaces, and stable setup geometry in both themes and narrow viewports. The `setup_polish` Python Playwright check measures the continuous divider and artwork row containment and spacing.
- **Origin:** October 12, 2026 user corrections to the imposition frontend screenshots, including the aligned header divider and polished artwork file rows.
