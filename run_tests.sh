#!/bin/bash

# Color definitions
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m' # No Color

# Default values
mode="dev"
scylladb_dir="$(dirname "$(realpath "$0")")"
parallel_jobs=16
base_test_dir="./test_run_output"
specific_test_dir=""
scylla_args=""
build=False

# Function to display usage
usage() {
    cat << EOF
Usage: $0 [OPTIONS]

OPTIONS:
    --build                  Build the project before running tests
    -j, --jobs <number>      Number of parallel jobs for build and tests (default: 16)
    --build-mode <mode>      Build mode: dev, release, etc. (default: dev)
    --test-dir <path>        Specific test directory to run (e.g., test/cql). If not provided, runs all default test directories
    --scylla-args <args>     Scylla arguments to pass to test.py (e.g., "--reactor-backend asymmetric_io_uring")
    -h, --help               Display this help message

EXAMPLES:
    $0 --build -j 8 --build-mode release
    $0 --jobs 4 --test-dir test/cql
    $0 --build --test-dir test/cql --build-mode dev
EOF
    exit 0
}

# Parse command-line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --build)
            build=True
            shift
            ;;
        -j|--jobs)
            if [ -z "$2" ] || [[ "$2" =~ ^- ]]; then
                echo -e "${RED}Error: --jobs requires a numeric argument${NC}" >&2
                usage
            fi
            parallel_jobs="$2"
            shift 2
            ;;
        --build-mode)
            if [ -z "$2" ] || [[ "$2" =~ ^- ]]; then
                echo -e "${RED}Error: --build-mode requires an argument${NC}" >&2
                usage
            fi
            mode="$2"
            shift 2
            ;;
        --test-dir)
            if [ -z "$2" ] || [[ "$2" =~ ^- ]]; then
                echo -e "${RED}Error: --test-dir requires an argument${NC}" >&2
                usage
            fi
            specific_test_dir="$2"
            shift 2
            ;;
        --scylla-args)
            if [ -z "$2" ]; then
                echo -e "${RED}Error: --scylla-args requires an argument${NC}" >&2
                usage
            fi
            scylla_args="$2"
            shift 2
            ;;
        -h|--help)
            usage
            ;;
        *)
            echo -e "${RED}Error: Unknown option: $1${NC}" >&2
            usage
            ;;
    esac
done

# Cleanup function to kill test process and children
cleanup() {
    if [ -n "$test_pid" ] && kill -0 "$test_pid" 2>/dev/null; then
        echo -e "${YELLOW}Terminating test process (PID: $test_pid) and its children${NC}"
        kill -TERM -"$test_pid" 2>/dev/null
        sleep 2
        if kill -0 "$test_pid" 2>/dev/null; then
            kill -9 -"$test_pid" 2>/dev/null
        fi

        # As tests fight to be alive, let's kill all current user's processes that have test.py in their command line
        pkill -9 -u "$(whoami)" -f "test.py"
    fi
}

# Set trap to catch signals
trap cleanup SIGTERM SIGINT EXIT

echo -e "${BLUE}Changing directory to ${scylladb_dir}${NC}"
cd "${scylladb_dir}" || { echo -e "${RED}Error: failed to change directory to ${scylladb_dir}${NC}"; exit 1; }

echo -e "${CYAN}Configuration:${NC}"
echo -e "  Build mode: ${YELLOW}${mode}${NC}"
echo -e "  Parallel jobs: ${YELLOW}${parallel_jobs}${NC}"
echo -e "  Test output directory: ${YELLOW}${base_test_dir}${NC}"
if [ -n "${specific_test_dir}" ]; then
    echo -e "  Specific test directory: ${YELLOW}${specific_test_dir}${NC}"
fi
if [ -n "${scylla_args}" ]; then
    echo -e "  Scylla arguments: ${YELLOW}${scylla_args}${NC}"
fi
echo -e "  Build enabled: ${YELLOW}${build}${NC}"

dbuild_relative_path="tools/toolchain/dbuild"
dbuild_path="./${dbuild_relative_path}"
if ! [ -x "${dbuild_path}" ]; then
    echo -e "${RED}Error: dbuild not found at ${dbuild_path}${NC}"
    exit 1
fi

echo -e "${GREEN}Using dbuild at ${dbuild_path}${NC}"

if [ "${build}" = True ]; then
    echo -e "${BLUE}Build flag is set to True, proceeding with build${NC}"
    # If build/mode exists, remove it
    relative_build_dir="build/${mode}"
    echo -e "${BLUE}Checking for existing build directory at ${relative_build_dir}${NC}"
    if [ -f "${relative_build_dir}" ]; then
        echo -e "${YELLOW}Removing existing ${relative_build_dir} file${NC}"
        rm -rf "${relative_build_dir}"
    fi

    # Run configure
    configure_script_path="./configure.py"
    echo -e "${CYAN}Running configure with mode ${mode}${NC}"
    if ! "${dbuild_path}" "${configure_script_path}" --mode "${mode}"; then
        echo -e "${RED}Error: configure failed${NC}"
        exit 1
    fi

    # Run build
    echo -e "${CYAN}Running build with mode ${mode} and ${parallel_jobs} parallel jobs${NC}"
    if ! "${dbuild_path}" ninja "${mode}-build" -j"${parallel_jobs}"; then
        echo -e "${RED}Error: build failed${NC}"
        exit 1
    fi

    echo -e "${GREEN}Build completed successfully${NC}"
else
    echo -e "${CYAN}Build flag is set to False, skipping build step${NC}"
fi

echo -e "${MAGENTA}Preparing to run tests with mode ${mode}${NC}"

if ! [ -d "${base_test_dir}" ]; then
    echo -e "${BLUE}Creating test output directory at ${base_test_dir}${NC}"
    mkdir -p "${base_test_dir}"
fi
echo -e "${BLUE}Test output directory is set to ${base_test_dir}${NC}"

timestamp=$(date +%Y%m%d_%H%M%S)
test_dir="${base_test_dir}/${timestamp}"
mkdir -p "${test_dir}"
echo -e "${BLUE}Test output will be organized in subdirectory: ${test_dir}${NC}"

# ./test.py --help
# Pytest directories are:
#                          - test/boost
#                          - test/ldap
#                          - test/raft
#                          - test/unit
#                          - test/vector_search
#                          - test/vector_search_validator
#                          - test/alternator
#                          - test/broadcast_tables
#                          - test/cql
#                          - test/cqlpy
#                          - test/rest_api
#                          - test/nodetool
#                          - test/scylla_gdb
directory_list=(
    "test/boost"
    "test/ldap"
    "test/raft"
    "test/unit"
    "test/vector_search"
    "test/broadcast_tables"
    "test/cql"
    "test/cqlpy"
    "test/rest_api"
    "test/nodetool"
    "test/scylla_gdb"
    "test/alternator"
    "test/vector_search_validator" # Moved to the end of the list as it is the longest running test and we want to run it last to get faster feedback on other tests
)

if [ -n "${specific_test_dir}" ]; then
    # Use specific test directory if provided
    directory_list=("${specific_test_dir}")
    echo -e "${MAGENTA}Running tests in specified directory: ${specific_test_dir}${NC}"
else
    # Use default directory list
    echo -e "${MAGENTA}Running tests in the following directories: ${directory_list[@]}${NC}"
fi

FAILED_TESTS=0

for dir in "${directory_list[@]}"; do
    echo
    echo -e "${YELLOW}========================================${NC}"
    echo -e "${CYAN}Running tests in directory: ${dir}${NC}"

    test_output_file="${test_dir}/test_output_${timestamp}_${mode}_${dir##*/}.log"
    echo -e "${BLUE}Test output will be logged to ${test_output_file}${NC}"

    echo

    # Log time
    start_time=$(date +%s)
    echo -e "${GREEN}Test started at: $(date -d "@$start_time" +"%Y-%m-%d %H:%M:%S")${NC}"

    test_script_path="./test.py"
    if [ -n "${scylla_args}" ]; then
        "${dbuild_path}" "${test_script_path}" "${dir}" -s -j"${parallel_jobs}" --mode="$mode" --extra-scylla-cmdline-options="${scylla_args}" &> "${test_output_file}" &
    else
        "${dbuild_path}" "${test_script_path}" "${dir}" -s -j"${parallel_jobs}" --mode="$mode" &> "${test_output_file}" &
    fi
    test_pid=$!

    echo -e "${MAGENTA}Test process started with PID: $test_pid${NC}"
    echo -e "${YELLOW}If you need to stop the tests, you kill this script and it will clean up the test process and its children${NC}"
    wait "$test_pid"
    exit_code=$?


    end_time=$(date +%s)
    duration=$((end_time - start_time))

    echo

    echo -e "${GREEN}Test completed at: $(date -d "@$end_time" +"%Y-%m-%d %H:%M:%S")${NC}"
    echo -e "${GREEN}Test duration: $duration seconds${NC}"

    if [ $exit_code -ne 0 ]; then
        echo -e "${RED}Error: tests failed with exit code $exit_code${NC}"
        echo -e "${RED}Check the test output log for details: ${test_output_file}${NC}"
        FAILED_TESTS=$((FAILED_TESTS + 1))
    else
        echo -e "${GREEN}Tests in directory ${dir} completed successfully${NC}"
    fi
done

if [ $FAILED_TESTS -ne 0 ]; then
    echo -e "${RED}Some tests failed. Check the test output logs for details.${NC}"
else
    echo -e "${GREEN}All tests completed successfully. Test output is available at ${test_output_file}${NC}"
fi