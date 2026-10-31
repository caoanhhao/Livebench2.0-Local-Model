#!/bin/bash
set -e
echo "=== Create virtual environment ==="
python -m venv .venv
echo "=== Activate and install ==="
source .venv/bin/activate
pip install -e .
echo "=== Virtual environment ready ==="
deactivate
