# Travis+AppVeyor → GitHub Actions Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace dead Travis + AppVeyor CI with one GitHub Actions workflow that rebuilds the full aiohttp 2.3.9 artifact matrix (sdist + manylinux1/Windows/macOS wheels) and collects every built file as a single downloadable `dist` artifact. No publishing.

**Architecture:** One workflow `.github/workflows/ci.yml`. Jobs that need Python 3.4/3.5/3.6 (lint, test, sdist, linux wheels) run those interpreters via `docker run quay.io/pypa/manylinux1_*` — NOT the `container:` key, because manylinux1's glibc 2.5 cannot run the Node20 binary that `actions/checkout@v4` and other JS actions require. macOS wheels build on `macos-13` (intel) with the interpreter from `MatteoH2O1999/setup-python` and an explicit `--plat-name` to stamp `macosx_10_10`/`macosx_10_11`. Windows wheels are best-effort via the same setup-python fork with `continue-on-error`. A final `collect` job merges all per-job artifacts into one `dist`.

**Tech Stack:** GitHub Actions, Docker (manylinux1 images), `MatteoH2O1999/setup-python@v6`, `actions/upload-artifact@v4` / `download-artifact@v4`, period-pinned setuptools/wheel/cython (`<45` / `<0.34` / `0.27.1`).

**Validation note:** There is no unit-test harness for a YAML workflow. "Verify it fails / passes" maps to: YAML parses, then `actionlint` (if installed), then the real GitHub Actions run after push. Each task commits; the final task pushes and watches the run.

---

### Task 1: Remove dead CI configs

**Files:**
- Delete: `.travis.yml`
- Delete: `.appveyor.yml`

- [ ] **Step 1: Delete both files**

```bash
git rm .travis.yml .appveyor.yml
```

- [ ] **Step 2: Verify gone**

Run: `ls .travis.yml .appveyor.yml 2>&1`
Expected: `No such file or directory` for both.

- [ ] **Step 3: Commit**

```bash
git commit -m "Remove dead Travis and AppVeyor CI configs"
```

---

### Task 2: Workflow skeleton + lint job

**Files:**
- Create: `.github/workflows/ci.yml`

- [ ] **Step 1: Create the workflow with triggers and the lint job**

```yaml
name: CI

on:
  push:
  pull_request:
  workflow_dispatch:

jobs:
  lint:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Lint in manylinux1 (cp36, period-pinned tools)
        run: |
          docker run --rm -v "$PWD":/io quay.io/pypa/manylinux1_x86_64 bash -c '
            set -e
            cd /io
            PY=/opt/python/cp36-cp36m/bin
            $PY/pip install flake8==3.4.1 pyflakes==1.6.0 isort==4.2.15 docutils
            $PY/flake8 aiohttp --exclude=aiohttp/backport_cookies.py examples tests demos
            $PY/python -m isort -c -rc aiohttp tests examples
            $PY/python setup.py check -rms
          '
```

- [ ] **Step 2: Verify YAML parses**

Run: `python3 -c "import yaml; yaml.safe_load(open('.github/workflows/ci.yml')); print('ok')"`
Expected: `ok`

- [ ] **Step 3: Lint the workflow if actionlint is available**

Run: `command -v actionlint >/dev/null && actionlint .github/workflows/ci.yml || echo "actionlint not installed, skipping"`
Expected: no errors, or the skip message.

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/ci.yml
git commit -m "Add GitHub Actions workflow with lint job"
```

---

### Task 3: Test job (manylinux1, cp34/35/36)

**Files:**
- Modify: `.github/workflows/ci.yml` (append a `test` job under `jobs:`)

- [ ] **Step 1: Append the test job**

```yaml
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Run tests in manylinux1 for cp34/cp35/cp36
        run: |
          docker run --rm -v "$PWD":/io quay.io/pypa/manylinux1_x86_64 bash -c '
            set -e
            cd /io
            for PY in cp34-cp34m cp35-cp35m cp36-cp36m; do
              BIN=/opt/python/$PY/bin
              $BIN/pip install -r requirements/ci-wheel.txt
              $BIN/pip install -e .
              echo "=== $PY no-extensions ==="
              AIOHTTP_NO_EXTENSIONS=1 $BIN/py.test tests -q
              echo "=== $PY asyncio-debug ==="
              PYTHONASYNCIODEBUG=1 $BIN/py.test tests -q
            done
          '
```

- [ ] **Step 2: Verify YAML parses**

Run: `python3 -c "import yaml; d=yaml.safe_load(open('.github/workflows/ci.yml')); print(sorted(d['jobs']))"`
Expected: `['lint', 'test']`

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/ci.yml
git commit -m "Add test job (manylinux1 cp34/35/36)"
```

---

### Task 4: sdist job

**Files:**
- Modify: `.github/workflows/ci.yml` (append `sdist` job)

- [ ] **Step 1: Append the sdist job**

```yaml
  sdist:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Build sdist in manylinux1 (cp36 + cython)
        run: |
          docker run --rm -v "$PWD":/io quay.io/pypa/manylinux1_x86_64 bash -c '
            set -e
            cd /io
            PY=/opt/python/cp36-cp36m/bin
            $PY/pip install cython==0.27.1
            $PY/python setup.py sdist
          '
      - name: List sdist
        run: ls -la dist
      - uses: actions/upload-artifact@v4
        with:
          name: dist-sdist
          path: dist/*.tar.gz
          if-no-files-found: error
```

- [ ] **Step 2: Verify YAML parses and job present**

Run: `python3 -c "import yaml; d=yaml.safe_load(open('.github/workflows/ci.yml')); print('sdist' in d['jobs'])"`
Expected: `True`

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/ci.yml
git commit -m "Add sdist job"
```

---

### Task 5: Linux wheels job (manylinux1 x86_64 + i686)

**Files:**
- Modify: `.github/workflows/ci.yml` (append `linux-wheels` job)

Uses the repo's existing `tools/build-wheels.sh` unchanged (it iterates `cp34-cp34m cp35-cp35m cp36-cp36m`, runs `auditwheel repair`, prunes non-manylinux1 wheels). The i686 image runs natively on the x86_64 host under a `linux32` personality, matching `tools/run_docker.sh`.

- [ ] **Step 1: Append the linux-wheels job**

```yaml
  linux-wheels:
    runs-on: ubuntu-latest
    strategy:
      fail-fast: false
      matrix:
        include:
          - image: quay.io/pypa/manylinux1_x86_64
            arch: x86_64
            pre: ""
          - image: quay.io/pypa/manylinux1_i686
            arch: i686
            pre: "linux32"
    steps:
      - uses: actions/checkout@v4
      - name: Build manylinux1 wheels (${{ matrix.arch }})
        run: |
          docker run --rm -v "$PWD":/io "${{ matrix.image }}" ${{ matrix.pre }} /io/tools/build-wheels.sh aiohttp
      - name: List wheels
        run: ls -la dist
      - uses: actions/upload-artifact@v4
        with:
          name: dist-linux-${{ matrix.arch }}
          path: dist/*.whl
          if-no-files-found: error
```

- [ ] **Step 2: Verify YAML parses and matrix has two arches**

Run: `python3 -c "import yaml; d=yaml.safe_load(open('.github/workflows/ci.yml')); print([m['arch'] for m in d['jobs']['linux-wheels']['strategy']['matrix']['include']])"`
Expected: `['x86_64', 'i686']`

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/ci.yml
git commit -m "Add linux-wheels job (manylinux1 x86_64 + i686)"
```

---

### Task 6: macOS wheels job (deployment-target tag stamping)

**Files:**
- Modify: `.github/workflows/ci.yml` (append `macos-wheels` job)

Three original macOS files: `cp34` at `macosx_10_10` and `macosx_10_11`, `cp36` at `macosx_10_10`. `--plat-name macosx-<target>-x86_64` forces the wheel tag regardless of the old `wheel` version; `MACOSX_DEPLOYMENT_TARGET` makes the compiler target that OS. `continue-on-error` because running a 3.4 interpreter on macOS 13 is inherently fragile.

- [ ] **Step 1: Append the macos-wheels job**

```yaml
  macos-wheels:
    runs-on: macos-13
    continue-on-error: true
    strategy:
      fail-fast: false
      matrix:
        include:
          - pyver: "3.4"
            target: "10.10"
          - pyver: "3.4"
            target: "10.11"
          - pyver: "3.6"
            target: "10.10"
    steps:
      - uses: actions/checkout@v4
      - name: Set up Python ${{ matrix.pyver }}
        uses: MatteoH2O1999/setup-python@v6
        with:
          python-version: ${{ matrix.pyver }}
      - name: Build wheel (target ${{ matrix.target }})
        env:
          MACOSX_DEPLOYMENT_TARGET: ${{ matrix.target }}
        run: |
          python -m pip install --upgrade "pip<21" "setuptools<45" "wheel<0.34" "cython==0.27.1"
          python setup.py bdist_wheel --plat-name "macosx-${{ matrix.target }}-x86_64" --dist-dir dist
          ls -la dist
      - uses: actions/upload-artifact@v4
        with:
          name: dist-macos-py${{ matrix.pyver }}-${{ matrix.target }}
          path: dist/*.whl
          if-no-files-found: ignore
```

- [ ] **Step 2: Verify YAML parses and three macOS builds defined**

Run: `python3 -c "import yaml; d=yaml.safe_load(open('.github/workflows/ci.yml')); print(len(d['jobs']['macos-wheels']['strategy']['matrix']['include']))"`
Expected: `3`

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/ci.yml
git commit -m "Add macos-wheels job (deployment-target tag stamping)"
```

---

### Task 7: Windows wheels job (best-effort)

**Files:**
- Modify: `.github/workflows/ci.yml` (append `windows-wheels` job)

Best-effort: `cp35`/`cp36` should compile on the VS2022 (v14.x) ABI line; `cp34` (needs MSVC 2010) likely fails and may fall back to a non-platform pure-python wheel. `continue-on-error` keeps the matrix from blocking the workflow. `arch: x86` → `win32` and `arch: x64` → `win_amd64` in the wheel name automatically.

- [ ] **Step 1: Append the windows-wheels job**

```yaml
  windows-wheels:
    runs-on: windows-2022
    continue-on-error: true
    strategy:
      fail-fast: false
      matrix:
        pyver: ["3.4", "3.5", "3.6"]
        arch: ["x86", "x64"]
    steps:
      - uses: actions/checkout@v4
      - name: Set up Python ${{ matrix.pyver }} (${{ matrix.arch }})
        uses: MatteoH2O1999/setup-python@v6
        with:
          python-version: ${{ matrix.pyver }}
          architecture: ${{ matrix.arch }}
      - name: Build wheel
        run: |
          python -m pip install --upgrade "pip<21" "setuptools<45" "wheel<0.34" "cython==0.27.1"
          python -m pip wheel . --no-deps -w dist
          dir dist
      - uses: actions/upload-artifact@v4
        with:
          name: dist-windows-py${{ matrix.pyver }}-${{ matrix.arch }}
          path: dist/*.whl
          if-no-files-found: ignore
```

- [ ] **Step 2: Verify YAML parses and 3×2 matrix**

Run: `python3 -c "import yaml; d=yaml.safe_load(open('.github/workflows/ci.yml')); m=d['jobs']['windows-wheels']['strategy']['matrix']; print(len(m['pyver'])*len(m['arch']))"`
Expected: `6`

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/ci.yml
git commit -m "Add windows-wheels job (best-effort via setup-python fork)"
```

---

### Task 8: Collect job (merge all artifacts into one `dist`)

**Files:**
- Modify: `.github/workflows/ci.yml` (append `collect` job)

`if: always()` so it runs even when the best-effort macOS/Windows jobs fail; `download-artifact@v4` with `merge-multiple: true` flattens every `dist-*` into one folder, re-uploaded as `dist`.

- [ ] **Step 1: Append the collect job**

```yaml
  collect:
    needs: [sdist, linux-wheels, macos-wheels, windows-wheels]
    if: always()
    runs-on: ubuntu-latest
    steps:
      - name: Download all per-job artifacts
        uses: actions/download-artifact@v4
        with:
          pattern: dist-*
          path: all
          merge-multiple: true
      - name: List everything collected
        run: ls -la all || echo "nothing built"
      - name: Upload consolidated dist
        uses: actions/upload-artifact@v4
        with:
          name: dist
          path: all/*
          if-no-files-found: warn
```

- [ ] **Step 2: Verify final job graph**

Run: `python3 -c "import yaml; d=yaml.safe_load(open('.github/workflows/ci.yml')); print(sorted(d['jobs'])); print(d['jobs']['collect']['needs'])"`
Expected:
`['collect', 'lint', 'linux-wheels', 'macos-wheels', 'sdist', 'test', 'windows-wheels']`
`['sdist', 'linux-wheels', 'macos-wheels', 'windows-wheels']`

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/ci.yml
git commit -m "Add collect job merging artifacts into single dist"
```

---

### Task 9: Push and verify the real run

**Files:** none (verification only)

- [ ] **Step 1: Push**

```bash
git push origin master
```

- [ ] **Step 2: Watch the run**

Run: `gh run list --limit 1` then `gh run watch` (if `gh` is authenticated for `ali-security/aiohttp-8239`).
Fallback (no `gh`): open `https://github.com/ali-security/aiohttp-8239/actions`.

- [ ] **Step 3: Confirm success criteria**

- `lint`, `test`, `sdist`, `linux-wheels` are green.
- The `dist` artifact contains, at minimum: `aiohttp-2.3.9.tar.gz` + 6 `manylinux1` wheels.
- `macos-wheels` and `windows-wheels` ran; whatever they built is added to `dist`; their failures did not turn the workflow red.

- [ ] **Step 4: Record outcome**

Note in the PR/commit which of the best-effort macOS/Windows wheels actually built, so the gap (vs. the original 16) is documented honestly.

---

## Self-Review

**Spec coverage:**
- 16-file matrix → Tasks 4 (sdist), 5 (6 linux), 6 (3 macOS), 7 (6 windows). ✓
- manylinux1 container for linux+test → Tasks 3, 5 (via `docker run`, with the Node20/glibc rationale). ✓
- `MACOSX_DEPLOYMENT_TARGET` tag raise → Task 6 (plus `--plat-name` for reliability on old `wheel`). ✓
- Matteo setup-python best-effort Windows → Task 7, `continue-on-error`. ✓
- No publish / no secrets → no publish job exists; nothing stores credentials. ✓
- Delete `.travis.yml` + `.appveyor.yml`, add `ci.yml`, reuse existing scripts → Tasks 1, 2–8. ✓
- Unique artifact names + `collect` merge (upload-artifact@v4 immutability) → Tasks 4–8 unique names, Task 8 merge. ✓
- Coverage artifact: spec mentioned a separate `coverage` artifact. **Deviation:** dropped to keep the test job simple and green (coverage files weren't part of the 16-file deliverable). Flagged for user.

**Placeholder scan:** No TBD/TODO; every code step shows full content. ✓

**Consistency:** Artifact names all follow `dist-*`; `collect` `pattern: dist-*` matches. Job names referenced in `collect.needs` all exist. Pins consistent across mac/windows (`setuptools<45`, `wheel<0.34`, `cython==0.27.1`). ✓

**One open deviation for user:** dropped the `coverage` artifact from the spec. If you want it back, the test job needs `--cov` + an `upload-artifact` step.
