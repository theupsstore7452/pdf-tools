# Elm migration acceptance

Verified on October 6, 2026. The served frontend is Elm; the former Leptos
frontend, Rust/Wasm dependencies, and frontend build scripts have been removed.
Axum, Tokio, PDF processing, API routes, wire formats, and persistent storage
remain in place.

## Baseline and implementation

The original frontend and `frontend/styles.css` supplied the visual and workflow
baseline, together with `finished-artwork-acceptance.md`,
`inspection-edge-cases.md`, `transition-edge-cases.md`, `startup-edge-cases.md`,
`startup-performance.md`, and the existing smoke scripts. The tool selector,
file queue, four imposition setup steps, artwork toolbar, and setup/preview
arrangement remain familiar. Responsive changes bound dialogs and artwork
popovers, keep controls reachable on short screens, and prevent narrow-screen
overflow. The existing 1100px setup/preview breakpoint is retained.

Elm owns workflow state, file uploads, validation, and HTTP requests. A documented
JavaScript bridge owns browser blobs, object URLs, downloads, storage, focus,
and crop pointer events. All URLs are relative and the application needs no
secure-context browser API. Rust remains authoritative for layout geometry.

The pinned elm-rs generator derives types and codecs from a generation-only
copy of actual Rust declarations. CI checks generated code and fixtures for
drift, and Elm contract tests compare codecs with actual production Rust JSON.
Enum constructors are prefixed without changing wire strings. The two audited
Serde accommodations are described in [frontend/README.md](frontend/README.md):
function-valued defaults in the generation copy and output-only duplex
`backAlignment`. Production Serde is unchanged. Job responses remain text;
preview batches remain `PDFPV001` binary responses.

## Functional evidence

Python Playwright ran normal workflows against real Axum/PDFium processing.
PyMuPDF and Pillow inspected downloaded files; completion messages alone were
not used as output evidence. Network interception was limited to explicit
recovery tests.

| Coverage | Evidence checked in both browsers |
| --- | --- |
| File intake and inspection | Native browse/drop, append, replacement, removal, pointer/keyboard reordering, stable focus, corrupt inputs, canceled inspection and stale responses |
| PDF raster conversion | PNG/JPEG formats, selected page content/order, resolution settings, dimensions, single output and ZIP output |
| Extraction | Individual PDFs, combined PDF, and chunks; page counts, selected content and source ordering |
| Merge and images to PDF | Ordered content and page dimensions; PNG/JPEG pages at their natural 300 DPI size |
| Finished artwork | Explicit size choices, decimal drafts and validation, orientation, Fit/Fill/Stretch, crop endpoints/drag/reset, bleed, exported dimensions and colored content |
| Imposition | Rust/SVG/export cut geometry agreement, mixed artwork, per-artwork overrides, zero/bulk/individual quantities, simplex/duplex draft retention and output fronts/backs, manual grid and margins |
| Saved work | Preset create/apply/update/rename/delete, retention of artwork and quantities on apply, catalog failures/retry, recent restore/delete, history restore/delete and byte-identical stored downloads |
| Recovery and ownership | Export failure/retry, cancellation and late job/prepared/layout responses, retained committed files/settings, old preview retained during loading, source deletion/lease renewal, URL revocation |
| Preview scheduling | Serial batches no larger than four pages, six-page fixture split 4+2, bounded retries, explicit retry, manual-bleed cache identity |
| Workspace reset | Confirmation/cancel, stale layout rejected after clearing, resources released, new upload requires explicit finished dimensions |
| Startup and HTTP | Failed CSS/Elm/bridge loads recover through Retry; delayed startup; raster and imposed exports on an insecure HTTP origin with `crypto.randomUUID` unavailable |
| Layout and access | Themes persist, keyboard dialogs and focus, hit-tested controls, no document overflow, bounded previews and scrolling artwork editors |

Viewport coverage includes 1366×900, 1366×560, 1101×768, 1100×768, 1024×768,
881×700, 880×700, 800×900, 540×700, 539×700, 390×700, and 320×568. Screenshots
and result JSON are retained by the acceptance runner.

## Checks run

The complete `scripts/check.sh` passed in the Nix `pdf-app` shell after Leptos
removal: Rust formatting, Clippy, docs, generated-code drift, Elm formatting,
JavaScript syntax, optimized frontend/backend builds, 313 Rust tests, 64 Elm
tests, and Chromium/Firefox release-server acceptance. Later focused preview
and responsive refinements passed the 64 Elm tests and another full release
acceptance. The final container acceptance then passed the complete expanded
suite, including workspace lifecycle checks, in both browsers.
Additional focused saved-work acceptance explicitly checked export-history
restore and deletion as well as byte-identical stored-file downloads.

```sh
nix develop .#pdf-app --command scripts/check.sh
nix build .#checks.x86_64-linux.pdf-rustup .#checks.x86_64-linux.rust-1_97 --no-link
scripts/acceptance.sh
python3 scripts/container-acceptance.py --engine podman --skip-build --image pdf-tools-elm:validation
```

Browser versions were Chromium 149.0.7827.55 and Firefox 151.0, using the Nix
Playwright browser builds. The Linux amd64 container was built from the final
Dockerfile and validated with Podman. Its three versioned assets and gzip
responses passed; physically removing both `elm.js` and its gzip sidecar,
then restoring them, exercised deployed-file failure and Retry in both browsers.
No persistent shop data or existing Compose services were used.

Final validation image ID:
`db178ce59bab85f03acd70fc9fde0279c0aab1cf9b07367aa147c75cf7845369`.
Asset directory hash: `285d1e958c5bf137`. Combined JavaScript/bridge/CSS gzip
size: 89,954 bytes, excluding the entrypoint and HTTP headers. This is a bundle
measurement, not a new startup latency benchmark.

Local evidence:

- `/tmp/pdf-elm-final-check.log`: complete check after Leptos removal.
- `/tmp/pdf-elm-release-acceptance-final.log`: final full release acceptance.
- `/tmp/pdf-elm-lifecycle.log`: focused workspace lifecycle checks.
- `/tmp/pdf-elm-saved-final.log`: focused saved-work checks, including history restore/delete.
- `/tmp/pdf-elm-container-build-final.log`: final container build.
- `/tmp/pdf-elm-container-acceptance-final.log`: final container acceptance.
- `/tmp/pdf-elm-acceptance/{chromium,firefox}/`: final results and screenshots.

Existing backend tests also passed for legacy persistent records, saved presets,
recent jobs, and export history. There is no frontend persistence migration.
Elm's test watcher was checked after updating its transitive file watcher; npm
reports zero dependency vulnerabilities for the pinned frontend lockfile.

## Environment limits

Browser tests ran on Linux, including desktop and emulated small viewports.
Safari and physical mobile devices were not tested. The arm64 container was not
built or run locally; the release workflow retains both amd64 and arm64 builds
and architecture smoke checks. The local container build needed the environment's
CA bundle and a populated Elm cache because of its network proxy. Those
validation-only mounts and environment variables are absent from the runtime
image and are not production configuration.
