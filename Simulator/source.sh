# SagePTE artifact
if command -v gcc-7 >/dev/null 2>&1; then
    export CC=$(command -v gcc-7)
    export CXX=$(command -v g++-7)
fi
export SIMULATOR_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null && pwd )"
alias build_simulator='$SIMULATOR_DIR/install.sh'
function run_simulator() { "$SIMULATOR_DIR/build/bin64/drrun" "$@"; }
