#!/usr/bin/env bash
# known.sh — advisories for packages with known Termux/Android issues.
# Sourced by build-in-termux.sh with PKG and VER set. Advisory only: it prints
# warnings; the build proceeds (fixes live in sdist_fixer.py or in patches/).
case "$PKG" in
  numpy)
    case "$VER" in
      2.5.*|2.6.*|2.7.*)
        echo "KNOWN ISSUE: numpy >= 2.5 calls cpow()/cexpl()/etc., which do not"
        echo "exist in Android's bionic libc. The build WILL fail at npy_math_complex."
        echo "Fix: pin numpy<=2.4.4 (builds cleanly on Termux)."
        ;;
    esac
    ;;
  scipy)
    echo "NOTE: scipy on Termux needs openblas: pkg install libopenblas before building."
    ;;
  cryptography|cffi)
    echo "NOTE: prefer the Termux packages (pkg install python-cryptography / python-cffi)"
    echo "or install libopenssl-static / libffi before building from source."
    ;;
  jiter|tiktoken|pydantic-core|*)
    # maturin-backed sdists built ON-DEVICE (uv/pip, outside this CI) fail with:
    #   "Failed to determine Android API level. Please set the ANDROID_API_LEVEL
    #    environment variable."
    # In this CI rootfs the var is exported by build-in-termux.sh; on-device users
    # need: export ANDROID_API_LEVEL=24  (matches the android_24_arm64_v8a tag).
    if command -v maturin >/dev/null 2>&1 || grep -q maturin pyproject.toml 2>/dev/null; then
      echo "NOTE: maturin build — if it fails with 'Failed to determine Android API"
      echo "level', run: export ANDROID_API_LEVEL=24 before the build."
    fi
    ;;
esac
