#!/usr/bin/env bash
# Build the remediation function's package: the handler plus anthropic[bedrock]
# for the Lambda runtime (Python 3.12, x86_64), resolved as binary wheels so a
# macOS or ARM workstation produces the right artifacts.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${ROOT}/build/remediate"

rm -rf "${OUT}"
mkdir -p "${OUT}"
python3 -m pip install --quiet --target "${OUT}" \
  --platform manylinux2014_x86_64 --python-version 3.12 --implementation cp \
  --only-binary=:all: --requirement "${ROOT}/app/requirements.txt"
cp "${ROOT}/app/remediate.py" "${OUT}/"
# Bytecode caches make the zip, and so source_code_hash, differ between builds.
find "${OUT}" -name '__pycache__' -type d -prune -exec rm -rf {} +
echo "Built ${OUT} ($(du -sh "${OUT}" | cut -f1))"
