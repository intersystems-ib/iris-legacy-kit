#!/usr/bin/env bash
# Test stand-in for a project's publish step: succeeds unless ui/FAIL exists.
[[ -e ui/FAIL ]] && { echo "publish failed (ui/FAIL present)"; exit 1; }
echo "ui published"
