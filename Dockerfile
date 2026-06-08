ARG BASE_IMAGE=quay.io/pypa/manylinux1_x86_64
FROM ${BASE_IMAGE}

ARG PYTHON_VERSIONS="cp35-cp35m cp36-cp36m"
ENV PYTHONDONTWRITEBYTECODE=1

SHELL ["/bin/bash", "-euxo", "pipefail", "-c"]

COPY . /io
WORKDIR /io

RUN for PY in $PYTHON_VERSIONS; do \
        "/opt/python/$PY/bin/pip" install -r requirements/wheel.txt; \
        "/opt/python/$PY/bin/pip" wheel . --no-deps -w /io/dist/ --no-build-isolation; \
    done && \
    for whl in /io/dist/aiohttp-*-linux_*.whl; do \
        auditwheel repair "$whl" -w /io/dist/; \
    done && \
    rm -fv /io/dist/aiohttp-*-linux_*.whl && \
    for whl in /io/dist/aiohttp-*-manylinux*.whl; do \
        "/opt/python/cp36-cp36m/bin/python" -m zipfile -l "$whl" | grep -q '_vendored/_brotli.*\.so'; \
    done && \
    ls -la /io/dist
