# PDF Tools

PDF Tools is a self-hosted web app with a Rust backend and Elm frontend, started
in the browser by a small plain JavaScript bootstrap. It turns PDF pages into
PNG or JPEG images, extracts selected pages as individual
PDFs in a ZIP, merges PDFs, converts ordered PNG or JPEG images into a PDF, and
imposes artwork onto print sheets.

This repository continues the original
[DaltonAlley/pdf-app](https://github.com/DaltonAlley/pdf-app) application, with
releases and container images published under `theupsstore7452/pdf-tools`.

The print-sheet workflow supports repeated or unique pages, simplex and duplex
layouts, automatic placement, previews, reusable presets, and print-ready
PDF exports.

Images to PDF keeps this workflow deliberately simple: each ordered PNG or JPEG
becomes one PDF page at its natural 300 DPI size. Page resizing, orientation,
fitting, and margins belong to other workflows.

## Make customer artwork into a print-ready flyer

Choose **Impose artwork**. **Width** and **Height** automatically
start at the finished cut dimensions of the first artwork page: a 5×7-inch PDF
with a 0.125-inch bleed starts at 5×7 inches, not 5.25×7.25 inches. An explicit
TrimBox or distinct CropBox takes precedence. Without cut metadata, common PDF
finished sizes with uniform 0.0625-, 0.125-, or 0.25-inch bleed are inferred; other
PDFs keep their page dimensions. Preview and export preserve the supplied bleed
outside that cut without shrinking the artwork. Images retain their full natural
300 DPI dimensions, including when their dimensions resemble a PDF with bleed.
These fields are always editable. Replacing artwork updates the default
size until you edit it, choose a finished orientation, or apply a saved setup;
those choices are retained when artwork changes. Mixed-size artwork shares the
first page's default finished size.

Use the **Fit**, **Fill**, and **Stretch** segmented field above the preview to choose
how artwork fits the finished size.

- **Fit** preserves proportions and content, with white borders
  where the source and finished shapes differ.
- **Fill** preserves proportions and crops to the chosen frame, centered by
  default. Saved crop positions are retained.
- **Stretch** fills the finished size by scaling width and height independently.
  It keeps the artwork but intentionally distorts its proportions.
- **Scale to add bleed** enlarges the fitted artwork uniformly. The normalized
  crop position is retained relative to the bleed frame, but additional content
  can fall outside the finished cut. Review the cut boundary before downloading.
  Fill and Stretch cover the bleed frame; Fit can retain white borders. No mode
  invents missing edge content.
- **Finished orientation** changes the product between Portrait and Landscape.
  Right-click an artwork item on the sheet to rotate that page independently.

Use **Presets** to save an impose setup you expect to use again. The
starter **5x7 on 12x18** preset is available without being applied automatically.
Applying a preset fills the finished size, sheet, fitting, bleed, arrangement,
and printing choices without replacing the uploaded artwork or its page
quantities. Presets can be created, renamed, updated, applied, or deleted.

**Fit**, **Fill**, and **Stretch** stay directly available in the toolbar above
the sheet preview as you move between the Size, Sheet, and Bleed tabs. Sheet
contains quantity, sheet size, printing, gutter, margin, and duplex settings.
Size contains finished dimensions, orientation, arrangement, and custom-grid
settings. All three tabs are available immediately, including while settings are incomplete or a preview
is loading. Use the arrow keys, Home, or End to navigate the tabs. Open the
advanced sheet settings to adjust gutters, custom margins, or duplex behavior.
On narrow screens, the toolbar stays
outside the Setup panel while **Preview** remains focused on inspecting the
sheet.

Red dashed cut paths are always visible on the sheet preview. Black dotted
rectangles show the outside bleed bounds where bleed is present, and the sheet
fits its canvas automatically. **Presets**, **Previous sheet**, and **Next sheet**
stay at the far right of the toolbar. Selection menus use the shared DA dropdown, and
the header tool selector has a visible surface before hover. These controls stay
in one row; on narrow screens,
scroll the toolbar horizontally to reach them. Selecting an impression shows a
blue outline with a narrow contrasting border around its finished cut,
including while its rotation menu is open. The outline stays the same thickness
as the canvas resizes.

Right-click a piece on the sheet to rotate its artwork clockwise, counterclockwise,
or 180°, or reset its rotation. The menu applies to all copies of that artwork
page. Rotation happens before Fit/Fill/Stretch, so portrait and landscape sources
can fill the same finished size without changing other pages. Keyboard users can
focus a piece and press Enter or Shift+F10. Previously saved bulk rotations,
fitting overrides, finished-size overrides, and crop positions remain supported
when restoring job settings.

Mixed-size PDF pages and images can share one manually defined finished size.
Mixed pieces use regular slots large enough for the largest piece, with
individual cut guides, not an optimized nesting algorithm. The toolbar fitting
choices apply to all artwork; saved per-piece settings remain supported. Duplex
pairs must have matching finished cuts, and odd source counts cannot be paired
automatically. In **Edit copy quantities**, **Apply to all** or Enter in
**Copies for all** commits the entered quantity to every page or pair and closes
the dialog.

Gutters measure the gap between finished cuts; supplied bleed occupies that gap
instead of being added to it. The layout increases an insufficient gap to keep
neighboring pieces from overlapping and reports that adjustment.

## Quick start with Docker Compose

Install Docker with the Compose plugin. Published images for Linux amd64 and
arm64 are available at [GHCR](https://github.com/theupsstore7452/pdf-tools/pkgs/container/pdf-tools).
Download `compose.release.yml` and `SHA256SUMS` from a
[GitHub release](https://github.com/theupsstore7452/pdf-tools/releases) into an empty
deployment directory, then run:

```sh
sha256sum --check SHA256SUMS
docker compose -f compose.release.yml up -d --wait
```

No source checkout is required. Private packages require a registry login;
an administrator can enable anonymous pulls by setting package visibility to
Public. The
release attachment pins that release's immutable image digest. If using the Compose file
from the repository instead, `PDF_APP_VERSION` defaults to `0.2.20` and can be set
in `.env` to select another published version.

To build locally instead, clone <https://github.com/theupsstore7452/pdf-tools>
and enter its repository root, then run:

```sh
docker compose up -d --build --wait
```

Open <http://localhost:3000>. Compose waits for the app's built-in health check
before returning. The supplied deployment is available only from the Docker
host because the app has no built-in authentication.

Compose stores persistent application data in `./data` beside the Compose file
and mounts it at `/app/data` in the container. This preserves impose presets,
and manually saved recent jobs when the container is replaced. Export history is
not retained. On startup, the app removes legacy export-history metadata and
archived export files from this directory.
Impose uploads are staged in that mounted data directory so large artwork uses
the host volume's capacity instead of the container's smaller temporary layer.
Temporary background-job downloads do not survive a restart. Back up `./data`
with the service stopped if that information matters to you.

## Optional configuration

The defaults require no configuration. To override them, create `.env` beside
`compose.release.yml` (or `docker-compose.yml` for source builds). The
repository's `.env.example` lists the available settings:

| Variable | Default | Purpose |
| --- | --- | --- |
| `HOST_PORT` | `3000` | Port published on the Docker host |
| `PDF_TOOLS_DATA_PATH` | `./data` | Persistent host directory mounted at `/app/data` |
| `PUID` / `PGID` | `1000` | Host IDs used to own persistent files |
| `MAX_UPLOAD_MB` | unset | Optional limit for generic multipart operations; canonical impose intake has separate safeguards |
| `PDF_TOOLS_MAX_IMPOSE_UPLOAD_MB` | `512` | Total compressed artwork bytes accepted by one canonical impose upload |
| `PDF_TOOLS_IMPOSE_UPLOAD_TIMEOUT_SECONDS` | `120` | Maximum elapsed time spent reading one canonical impose upload |
| `MAX_RENDER_PAGES` | unset | Optional page limit for render and split requests |
| `MAX_DOWNLOAD_MB` | unset | Optional generated-download size limit |
| `PDF_TOOLS_CPU_PERMITS` | up to 4 host CPUs | Shared workers for PDF and image processing |
| `PDF_TOOLS_MAX_ACTIVE_OPERATIONS` | CPU permit count | Concurrent upload and PDF operations |
| `RUST_LOG` | `info` | Server log filter |

Set `PUID` and `PGID` to the output of `id -u` and `id -g` if the deployment
account does not use ID `1000`.

When `MAX_UPLOAD_MB` is unset, generic uploads have no application-wide byte
limit. Canonical impose sources remain disk-streamed and are independently
bounded by `PDF_TOOLS_MAX_IMPOSE_UPLOAD_MB` and
`PDF_TOOLS_IMPOSE_UPLOAD_TIMEOUT_SECONDS`. Setting `MAX_UPLOAD_MB` limits
conversion, merge, split, and legacy job multipart endpoints; it does not
replace the canonical `/gang-up/sources` safeguards.

PDFium calls run on bounded blocking workers and are serialized because the
native library is process-global. Cancellation and deadlines are checked at
safe upload and page boundaries; a native call already in progress cannot be
forcibly interrupted. Preview requests are intentionally small (at most four
pages per batch), and request traces provide the source route and response
latency needed to identify repeated or slow renders without retaining another
in-memory copy of source PDFs.

## Upgrade or roll back

For released images, download the new release's Compose file and checksums,
verify them, then pull and replace the app:

```sh
sha256sum --check SHA256SUMS
docker compose -f compose.release.yml pull
docker compose -f compose.release.yml up -d --wait
```

To roll back, use the previous release's Compose file and repeat the commands.
For local source builds, update the checkout and run
`docker compose up -d --build --wait` instead.

The replacement briefly interrupts requests; the `./data:/app/data` mount
preserves persistent application data. Reload open browser tabs after the
health check succeeds. Back up data before upgrades if rollback is important.

## Publishing a release

The standalone repository runs `.github/workflows/release.yml` on `v*` tags or
manual dispatch. The tag must equal `v` plus the version in `Cargo.toml`; manual
dispatch takes the exact version without `v` and builds its existing version
tag, so a retry does not change the released source revision.
Both paths build the existing Dockerfile for Linux amd64 and arm64, publish
`ghcr.io/theupsstore7452/pdf-tools:<version>` using `GITHUB_TOKEN`, and smoke-test both
architectures by immutable image digest. Only after health and versioned frontend
asset checks pass does the workflow create a GitHub release with a digest-pinned
Compose file and `SHA256SUMS`. Images can exist even if a later smoke check fails.
An existing release is rejected before building or publishing an image.

Repository administrators must allow Actions to write contents and packages.
After the first publish, set the linked GHCR package's visibility to **Public**
in its package settings. New GHCR packages are private by default, even for a
public repository. The OCI source label links the package to this repository.

## Build from source

The browser bootstrap is ordinary JavaScript at `frontend/browser/bootstrap.js`.
CI and Docker build it with the Elm frontend using Node and the pinned npm
dependencies. The frontend build checks its syntax and includes its contents in
the versioned asset hash.

The source-build command above runs from the standalone repository root and
requires only Docker. For the pinned development shell and full checks, run from
that same repository root:

```sh
nix develop
just check
```

Both deployments use the same port, optional `.env`, and persistent `./data`.
Stop the source-built service with `docker compose down` before switching to the
released-image deployment on the same port.

## Local development

The PDF app uses Rust 1.97.1 and Elm 0.19.1. The npm lockfile pins the Elm
compiler, formatter, and test runner; no Rust WebAssembly target is required.
The default Nix shell (also available as `pdf-app`) includes Rust, Node/npm,
PDFium, Python Playwright, PyMuPDF, Pillow, and patched Chromium and Firefox
browsers:

```sh
nix develop
just dev
```

`nix develop .#commands` provides the lightweight container command tools.
Use the default shell for `just dev`, `just check`, and source builds.

Without Nix, install Rust with Clippy and rustfmt, Node, and PDFium. Set
`PDF_TOOLS_PDFIUM_PATH=/path/to/libpdfium.so` if PDFium is not on the library path.
`just dev` installs the pinned npm dependencies, generates the API codecs, builds
the frontend, starts Axum on <http://127.0.0.1:3200>, and watches frontend files.
Restart the command after backend changes. The supervisor stops only its own
processes. A directly run server defaults to loopback; set
`PDF_TOOLS_BIND_ADDRESS` for an intentional trusted-network bind. The container
uses `0.0.0.0` internally while Compose publishes to loopback.

```sh
just release       # optimized Rust backend and Elm frontend
just generate-api  # regenerate API types/codecs and Rust wire fixtures
just test          # Rust and Elm tests
just check         # formatting, lint, docs, contracts, builds, full acceptance
```

Axum serves `frontend/dist/app.html` and its versioned JavaScript/CSS assets.
The server resolves this directory from its working directory at startup;
set `PDF_TOOLS_FRONTEND_DIR` to an absolute path to serve a bundle elsewhere.
`just dev` sets this path to the current checkout. Missing entrypoints fail
startup with the attempted path instead of leaving a running server with 404s.
Deploy the complete distribution directory together. The build generates gzip
sidecars and retains previous asset directories on incremental builds. The
frontend uses relative API URLs and works on ordinary HTTP origins without
`crypto.randomUUID`, clipboard permissions, or a secure context.

Elm owns workflow state, files, HTTP uploads, validation, polling, and stale
response rejection. The [JavaScript bootstrap](frontend/browser/bootstrap.js)
mounts the app and checks its resource ports. The
[PDF browser adapter](frontend/bridge.js) handles theme storage and manages
binary preview blobs, object URLs, downloads, native dialog focus, and
crop pointer events. Rust remains authoritative for production geometry. See
[frontend implementation notes](frontend/README.md) for resource lifecycles and
the audited elm-rs generation boundary. The
[migration acceptance record](elm-migration-acceptance.md) lists verified
workflows, output checks, browser coverage, and environment limits.

The acceptance scripts use Python Playwright against a real Axum server and
inspect downloaded PDFs and raster images with PyMuPDF and Pillow. Normal
workflow requests reach the backend; only explicit recovery tests inject delays
or failures. With the application running:

```sh
python3 scripts/elm-browser-acceptance.py --url http://127.0.0.1:3200
python3 scripts/workflow-regressions.py --url http://127.0.0.1:3200
python3 scripts/elm-http-acceptance.py --port 3200
```

The workflow regression matrix runs 45 cases in each browser, covering PDF trim,
crop, bleed, rotation and UserUnit metadata; inferred cuts and unscaled export
landmarks; PNG/JPEG, alpha transparency, EXIF rotation and 300 DPI sizing; merge
ordering and removal; every raster format/resolution combination; extraction;
five sheet sizes with repeated PDF/image artwork; PDF and image duplex pair
ordering, mirroring and back rotation; and recovery after a corrupt image. It
checks actual downloaded content, dimensions,
pixels and quantities. Each case gets a fresh browser context, and failures do
not stop the remaining cases. JSON results, layout records, downloads and
Playwright traces are retained, with screenshots and DOM snapshots on failure.
Run a subset with `--checks cuts,duplex` or `--browsers chromium`. Reports default
to `/tmp/pdf-elm-acceptance/workflows`; use `--output` to change that location.

The checked-in `pdf_examples/before` and `pdf_examples/after` pairs also guard the
shop's two-up menu workflow: two 8.5×11-inch finished pieces with 0.125-inch bleed
on a 12×18-inch sheet, using the default 0.299-inch cut-to-cut gutter. The food
menu rotates a quarter-turn; the wine file already has an 11×8.5-inch cut and
contains two menu panels per piece. The tests upload each original, export two
copies, and compare cut positions, every text word and its bounding box, and the
rendered sheet against its supplied reference. Reference/actual/difference PNGs
and comparison metrics are retained. Run these alone with `--checks references`.

The full check launches an isolated release server with disposable data and runs
both browser suites plus insecure-HTTP acceptance in Chromium and Firefox.
The same check runs on every pull request and push to `main`, with browser
artifacts uploaded even on failure. Screenshots and result records are written to
`/tmp/pdf-elm-acceptance` by default. Override `PDF_TOOLS_ACCEPTANCE_OUTPUT` to
change that directory. No customer files are required.

Container packaging can be checked separately with a Docker or Podman engine:

```sh
python3 scripts/container-acceptance.py --engine docker
# Reuse an image:
python3 scripts/container-acceptance.py --engine podman --skip-build --image pdf-tools-elm:validation
```

This starts a disposable loopback-bound container, verifies compressed assets,
runs the same output-inspecting browser acceptance, and physically removes then
restores the Elm bundle to verify startup recovery. It does not replace Compose
services or mount persistent shop data.
