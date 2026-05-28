#!/bin/bash
# Point this project at the canonical GitHub repo and remove the duplicate.
set -e
cd "$(dirname "$0")/.."

CANONICAL="https://github.com/Ujdasingh/REDGE---CLIPBOARD-CALCULATOR-.git"
DUPLICATE="Ujdasingh/Redge"

git remote set-url origin "$CANONICAL"
git push -u origin main

echo ""
echo "Remote set to: $CANONICAL"
echo ""
echo "Delete the duplicate repo (requires: gh auth login):"
echo "  gh repo delete $DUPLICATE --yes"
echo ""
echo "Or delete manually: https://github.com/$DUPLICATE/settings"
