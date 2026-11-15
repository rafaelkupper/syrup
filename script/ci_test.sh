#!/bin/sh
set -eu

"$(dirname "$0")/check-boundaries.sh"
# The provider corpus is generated from the fetched examples; the checked-in Swift must match them.
python3 -I "$(dirname "$0")/provider-corpus/generate.py" --check
python3 -I "$(dirname "$0")/test_mutation.py"
xcodegen
# Compile the production entry point without requiring a distribution certificate.
# The isolated test host below uses its own ad-hoc signature.
xcodebuild -scheme Syrup -configuration Debug build CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO
"$(dirname "$0")/test-isolated.sh"
# Breaks the Swift lines this branch changed, one at a time, and fails if the suite still passes.
python3 -I "$(dirname "$0")/mutation.py"
