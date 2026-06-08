import subprocess
import sys
import textwrap

import pytest

from aiohttp.http_parser import (DEFAULT_MAX_DECOMPRESS_SIZE, HAS_BROTLI,
                                 _brotli, _brotli_decompressor)

try:
    import brotli as _system_brotli
except ImportError:  # pragma: no cover
    _system_brotli = None


def _run_py(code):
    return subprocess.run(
        [sys.executable, '-c', textwrap.dedent(code)],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        universal_newlines=True)


def _ver(mod):
    try:
        parts = mod.__version__.split('.')[:2]
        return (int(parts[0]), int(parts[1]))
    except Exception:
        return (0, 0)


def _decompress_capped(mod, data, max_length):
    obj = mod.Decompressor()
    if hasattr(obj, 'decompress'):
        return obj.decompress(data, max_length)
    return obj.process(data, max_length)


@pytest.mark.skipif(not HAS_BROTLI, reason="brotli is not installed")
def test_system_brotli_is_module_of_record():
    assert _brotli is not None
    assert not getattr(_brotli, '__name__', '').startswith('aiohttp._vendored')


@pytest.mark.skipif(not HAS_BROTLI, reason="brotli is not installed")
def test_brotli_decompressor_is_at_least_1_2():
    assert _brotli_decompressor is not None
    assert _ver(_brotli_decompressor) >= (1, 2), \
        _brotli_decompressor.__version__


@pytest.mark.skipif(not HAS_BROTLI, reason="brotli is not installed")
def test_brotli_bomb_is_capped():
    original = b'A' * (64 * 2 ** 20)
    compressed = _brotli.compress(original)
    assert len(compressed) < 2 ** 16

    out = _decompress_capped(
        _brotli_decompressor, compressed, DEFAULT_MAX_DECOMPRESS_SIZE + 1)
    assert len(out) > DEFAULT_MAX_DECOMPRESS_SIZE
    assert len(out) < len(original)


@pytest.mark.skipif(
    _system_brotli is None or _ver(_system_brotli) >= (1, 2),
    reason="requires an OLD (<1.2) system brotli for the vendored fallback")
def test_old_system_brotli_uses_vendored_decompressor():
    assert _brotli is _system_brotli
    assert _ver(_brotli) < (1, 2)

    assert _brotli_decompressor is not _system_brotli
    assert _brotli_decompressor.__name__.startswith('aiohttp._vendored')
    assert _ver(_brotli_decompressor) >= (1, 2)


def test_coexistence_subprocess_no_segfault():
    result = _run_py("""
        import importlib.util, sys
        if importlib.util.find_spec("brotli") is None:
            print("SKIP: no system brotli"); sys.exit(0)
        import brotli
        sysver = getattr(brotli, "__version__", "0.0")
        from aiohttp.http_parser import (
            _brotli, _brotli_decompressor, HAS_BROTLI,
        )
        assert HAS_BROTLI is True
        assert _brotli is brotli
        assert "brotli" in sys.modules

        assert _brotli_decompressor is not None
        decmm = tuple(
            int(p) for p in _brotli_decompressor.__version__.split(".")[:2])
        assert decmm >= (1, 2)

        try:
            sysmm = tuple(int(p) for p in sysver.split(".")[:2])
        except ValueError:
            sysmm = (0, 0)
        if sysmm >= (1, 2):
            assert _brotli_decompressor is brotli
        else:
            assert _brotli_decompressor is not brotli
            name = _brotli_decompressor.__name__
            assert name.startswith("aiohttp._vendored")
            assert "aiohttp._vendored.brotli" in sys.modules

        data = brotli.compress(b"x" * 1000)
        assert brotli.decompress(data) == b"x" * 1000
        print("OK system=%s decompressor=%s" % (
            sysver, _brotli_decompressor.__version__))
        """)
    assert result.returncode == 0, result.stderr
    assert "OK" in result.stdout or "SKIP" in result.stdout, result.stdout


def test_no_system_brotli_disables_br_subprocess():
    result = _run_py("""
        import sys, os
        class _Blocker:
            def find_module(self, name, path=None):
                if name.split(".")[0] in ("brotli", "brotlicffi"):
                    return self
                return None
            def load_module(self, name):
                raise ImportError("blocked for test")
        sys.meta_path.insert(0, _Blocker())
        for m in [k for k in sys.modules
                  if k.split(".")[0] in ("brotli", "brotlicffi")]:
            del sys.modules[m]

        from aiohttp.http_parser import (
            HAS_BROTLI, _brotli, _brotli_decompressor, DeflateBuffer,
        )
        assert HAS_BROTLI is False, "HAS_BROTLI should be False without brotli"
        assert _brotli is None
        assert _brotli_decompressor is None

        import aiohttp
        vp = os.path.join(
            os.path.dirname(aiohttp.__file__), "_vendored", "brotli.py")
        assert os.path.exists(vp), "vendored brotli.py should still ship"

        from aiohttp.http_exceptions import ContentEncodingError
        try:
            import unittest.mock as mock
            DeflateBuffer(mock.Mock(), "br")
        except ContentEncodingError:
            pass
        else:
            raise AssertionError("br should be rejected without system brotli")
        print("OK br disabled, vendored still ships")
        """)
    assert result.returncode == 0, result.stderr
    assert "OK" in result.stdout, result.stdout
