# Design: Port Travis + AppVeyor CI to GitHub Actions (aiohttp 2.3.9)

Date: 2026-06-08

## Goal

Replace the dead Travis CI (`.travis.yml`) and AppVeyor (`.appveyor.yml`)
configuration with a single GitHub Actions workflow that reproduces the full
2.3.9 release artifact matrix and collects every built file as a downloadable
GitHub artifact. **No package publishing** — we do not upload to PyPI and store
no credentials.

## Target artifact matrix (from PyPI aiohttp 2.3.9)

16 files total:

- `aiohttp-2.3.9.tar.gz` (sdist)
- manylinux1, `cp34`/`cp35`/`cp36`, `x86_64` + `i686` → 6 wheels
- Windows, `cp34`/`cp35`/`cp36`, `win32` + `win_amd64` → 6 wheels
- macOS, `cp34` (`macosx_10_10` + `macosx_10_11`) + `cp36` (`macosx_10_10`) → 3 wheels

Note the original macOS set is intentionally asymmetric: `cp35` macOS was never
released, and `cp34` shipped two deployment targets. We reproduce exactly that
set, not a "tidied up" version.

## Hard constraints (2026 runner reality)

- Python 3.4/3.5/3.6 are EOL. `actions/setup-python` does not serve them on
  current hosted runners.
- The original macOS runner images (10.10/10.11) no longer exist.
- The Windows VC++ 2010 toolchain (required to compile CPython 3.4 C
  extensions) is gone from hosted Windows runners.

These constraints make a portion of the matrix infeasible on hosted runners.
The design reaches the reachable majority reliably and attempts the rest as
explicitly best-effort, never letting the fragile jobs block the solid ones.

## Per-platform approach

### Linux wheels + the test run — manylinux1 container (reliable)

The `quay.io/pypa/manylinux1_x86_64` and `quay.io/pypa/manylinux1_i686` images
still pull and still bundle CPython 3.4/3.5/3.6 under `/opt/python/`. This is
the only place those interpreters reliably exist. We:

- Run the **test** job inside the container, executing the existing Makefile
  targets (`cov-ci-no-ext`, `cov-ci-aio-debug`, `cov-ci-run`) per Python.
- Run the **linux-wheels** job by invoking the repo's existing
  `tools/build-wheels.sh` inside the container (it already iterates
  `cp34-cp34m cp35-cp35m cp36-cp36m`, runs `auditwheel repair`, and prunes
  non-manylinux1 wheels). The `i686` arch is built by running the `i686` image
  under `linux32`, matching the existing `tools/run_docker.sh` logic.

### macOS wheels — deployment-target tag rewrite (best-effort, expected to work)

We do **not** need 10.10/10.11 runner images. On a hosted intel runner
(`macos-13`) we build `x86_64` wheels and set `MACOSX_DEPLOYMENT_TARGET` to
raise the wheel platform tag:

- The wheel platform tag derives from `sysconfig.get_platform()`, seeded by the
  deployment target baked into the interpreter at compile time.
- python.org CPython 3.4/3.6 are built against a 10.6 baseline. Setting
  `MACOSX_DEPLOYMENT_TARGET=10.10` (or `10.11`) *raises* the tag to
  `macosx_10_10` / `macosx_10_11`. Raising is the supported direction; lowering
  is not.
- If the installed `wheel` version is too old to honor the env var, force the
  tag with `--plat-name macosx_10_10_x86_64` (etc.).

Build invocations:
- `cp34`: build twice — `MACOSX_DEPLOYMENT_TARGET=10.10` and `=10.11`.
- `cp36`: build once — `MACOSX_DEPLOYMENT_TARGET=10.10`.

Interpreter provisioning: `MatteoH2O1999/setup-python@v6` for 3.4/3.6; if it
cannot provide them, fall back to the python.org `.pkg` installers. macOS jobs
are `continue-on-error: true` because running a 3.4 interpreter on macOS 13 is
inherently fragile.

### Windows wheels — best-effort via Matteo's setup-python

`MatteoH2O1999/setup-python@v6` provides EOL interpreters (3.4/3.5/3.6) on
Windows, building from source when needed (slow, ~25m). It supplies the
interpreter only, not a compiler. Compiler reality:

- `cp34` → MSVC 2010, absent from hosted runners → riskiest; likely fails to
  compile the C extensions and may fall back to a pure-python wheel (which will
  not carry the expected `cp34-win` platform tag). Accepted under best-effort.
- `cp35` (MSVC v14.0) and `cp36` (MSVC v14.1) sit on the VS2022 (v14.3x) ABI
  line and are expected to compile.

The whole `windows-wheels` job uses a matrix of `{3.4, 3.5, 3.6} × {win32,
win_amd64}` with `continue-on-error: true`, so failures never block the rest of
the workflow.

## Workflow structure

Single file: `.github/workflows/ci.yml`. Triggers: `push`, `pull_request`, and
`workflow_dispatch`.

Jobs:

| Job | Runner | Output | Blocking? |
|---|---|---|---|
| `lint` | `ubuntu-latest` | flake8 + isort + `setup.py check` | yes |
| `test` | `ubuntu-latest`, container `quay.io/pypa/manylinux1_x86_64` | test run for cp34/35/36 | yes |
| `sdist` | `ubuntu-latest` | `aiohttp-2.3.9.tar.gz` | yes |
| `linux-wheels` | `ubuntu-latest` + manylinux1 docker (x86_64, i686) | 6 wheels | yes |
| `macos-wheels` | `macos-13` | 3 wheels | no (`continue-on-error`) |
| `windows-wheels` | `windows-2022`, matrix 3.4/3.5/3.6 × win32/amd64 | up to 6 wheels | no (`continue-on-error`) |
| `collect` | `ubuntu-latest` | merges all `dist-*` into one `dist` artifact (`needs:` all builds, `if: always()`) | no |

Lint tooling (flake8, isort) runs under a modern Python on the host; it only
needs to parse source, not import aiohttp. The `setup.py check` step mirrors the
old Travis "dist setup check" stage.

### Artifact collection

`actions/upload-artifact@v4` makes artifact names immutable — two jobs cannot
upload to the same name. So each build job uploads to a **distinct** name
(`dist-sdist`, `dist-linux-<arch>`, `dist-macos`, `dist-windows-<pyver>-<arch>`),
and a final `collect` job (`needs:` all build jobs, `if: always()` so it runs
even when the best-effort jobs fail) downloads them all with
`actions/download-artifact` (pattern `dist-*`, `merge-multiple: true`) and
re-uploads a single consolidated `dist` artifact. The result is one downloadable
`dist` containing every file that successfully built — up to all 16.

Coverage from the `test` job is uploaded as a separate `coverage` artifact (no
external coverage service, no token).

## Files changed

- **Delete** `.travis.yml`.
- **Delete** `.appveyor.yml`.
- **Add** `.github/workflows/ci.yml`.
- **Reuse unchanged**: `tools/build-wheels.sh`, `tools/run_docker.sh`,
  `Makefile`, `requirements/*`. The workflow calls the existing scripts rather
  than reimplementing wheel logic.

## Explicit non-goals

- No PyPI upload / `twine` / deploy stage. No `secure:` secrets, no
  `PYPI_API_TOKEN`, no Trusted Publishing.
- No modernization of the supported-Python matrix — we target the original
  3.4/3.5/3.6 set only.
- No change to package source, `setup.py`, or test code.

## Success criteria

- `lint`, `test`, `sdist`, `linux-wheels` are green on a normal push.
- The `dist` artifact contains the sdist + 6 manylinux1 wheels at minimum.
- `macos-wheels` and `windows-wheels` run, add whatever they manage to build to
  `dist`, and never turn the overall workflow red when they fail.
