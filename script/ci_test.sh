#!/bin/sh
set -eu

"$(dirname "$0")/check-boundaries.sh"
xcodegen
# Compile the production entry point without requiring a distribution certificate.
# The isolated test host below uses its own ad-hoc signature.
xcodebuild -scheme Syrup -configuration Debug build CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO
"$(dirname "$0")/test-isolated.sh"
