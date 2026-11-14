#!/bin/zsh
# Builds Pip and opens it. Run from a clone of this repository.
set -euo pipefail
here=${0:A:h}
"$here/build.sh"
open "$HOME/Applications/Pip.app"
echo "Pip is on your desktop. Press Control-Option-P to talk to it."
