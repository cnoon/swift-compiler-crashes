#!/bin/bash
# Style guide: https://google-styleguide.googlecode.com/svn/trunk/shell.xml
# Shell lint: http://www.shellcheck.net/

swiftc_version=$(xcrun swiftc -version | cut -f2 -d"(" | cut -f1 -d")" | head -1)
xcode_path=$(xcode-select -p)
echo
echo "Running tests against: ${swiftc_version}"
echo "Using Xcode found at path: ${xcode_path}"
echo "Usage: $0 [-v] [-c<columns>] [file ...]"
echo

columns=$(tput cols)
verbose=0
while getopts ":c:v" o; do
  case "${o}" in
    c)
      columns=${OPTARG}
      ;;
    v)
      verbose=1
      ;;
  esac
done

shift $((OPTIND - 1))

color_red="\e[31m"
color_green="\e[32m"
color_bold="\e[1m"
color_normal_display="\e[0m"

argument_files=$*
name_size=$((columns - 27))
num_tests=0
num_crashed=0
seen_checksums=""

timeout() {
  timeout_in_seconds=$1
  command="/bin/sh -c \"$2\""
  expect -c "set echo \"-noecho\"; set timeout $timeout_in_seconds; spawn -noecho $command; expect timeout { exit 1 } eof { exit 0 } > /dev/null 2> /dev/null"
  return $?
}

test_file() {
  path="$1"
  if [[ ! -f "${path}" ]]; then
    return
  fi
  files_to_compile="${path}"
  if [[ ${path} =~ part1.swift ]]; then
    files_to_compile=${path//.part1.swift/.part[1-9].swift}
  elif [[ ${path} =~ (part|library)[2-9].swift ]]; then
    return
  fi
  num_tests=$((num_tests + 1))
  test_name=$(basename -s ".swift" "${path}")
  test_name=${test_name//-/ }
  test_name=${test_name//.part1/}
  test_name=${test_name//.library1/}
  test_name=${test_name//.script/}
  test_name=${test_name//.timeout/}
  # Tip: Want to see details of the type checker's reasoning? Compile with "xcrun swiftc -Xfrontend -debug-constraints"
  # NOTE: Compile under the three modes -Onone, -O and -Ounchecked until we hit a crash.
  swift_crash=0
  output=$(xcrun swiftc -Onone -o /dev/null ${files_to_compile} 2>&1)
  compilation_comment=""
  crash_detection_regexp="error: unable to execute command: Segmentation fault:|LLVM ERROR:|While emitting IR for source file"
  if ! egrep -q "${crash_detection_regexp}" <<< "${output}"; then
    output=$(xcrun swiftc -O -o /dev/null ${files_to_compile} 2>&1)
    compilation_comment="-O"
  fi
  if ! egrep -q "${crash_detection_regexp}" <<< "${output}"; then
    if [[ ${files_to_compile} =~ \.library1\. ]] && [[ -f "${files_to_compile//.library1./.library2.}" ]]; then
      source_file_using_library=${files_to_compile//.library1./.library2.}
      compilation_comment=""
      rm -f DummyModule.swiftdoc DummyModule.swiftmodule libDummyModule.dylib
      output=$(xcrun -sdk macosx swiftc -emit-library -o libDummyModule.dylib -Xlinker -install_name -Xlinker @rpath/libDummyModule.dylib -emit-module -emit-module-path DummyModule.swiftmodule -module-name DummyModule -module-link-name DummyModule "${files_to_compile}" 2>&1)
      if [[ $? == 0 ]]; then
        output=$(xcrun -sdk macosx swiftc "${source_file_using_library}" -o /dev/null -I . -L . -Xlinker -rpath -Xlinker @executable_path/ 2>&1)
        if ! egrep -q "${crash_detection_regexp}" <<< "${output}" && ! egrep -q "implicit entry/start for main executable" <<< "${output}"; then
            crash_detection_regexp="${crash_detection_regexp}|error: linker command failed with exit code 1"
        fi
        compilation_comment="lib"
      fi
      rm -f DummyModule.swiftdoc DummyModule.swiftmodule libDummyModule.dylib
    elif [[ ${files_to_compile} =~ \.timeout\. ]]; then
      timeout 5 "xcrun swift ${files_to_compile}"
      if [[ $? == 1 ]]; then
          swift_crash=1
          compilation_comment="timeout"
      fi
    elif [[ ${files_to_compile} =~ \.script\. ]]; then
      output_1=$(xcrun swift ${files_to_compile} 2>&1)
      err_1=$?
      output_2=$(xcrun swift -O ${files_to_compile} 2>&1)
      err_2=$?
      if [[ ${err_1} != ${err_2} ]]; then
        crash_detection_regexp="${crash_detection_regexp}|Stack dump:"
        compilation_comment="script"
        output="${output_1}${output_2}"
      fi
    fi
  fi
  normalized_stacktrace=$(egrep "0x[0-9a-f]" <<< "${output}" | sed 's/0x[0-9a-f]*//g' | sed 's/\+ [0-9]*$//g' | awk '{ print $3 }' | cut -f1 -d"(" | cut -f1 -d"<" | uniq)
  checksum=$(shasum <<< "${normalized_stacktrace}" | head -c10)
  is_dupe=0
  if [[ "${normalized_stacktrace}" == "" ]]; then
    checksum="        "
  else
    if egrep -q "${checksum}" <<< "${seen_checksums}"; then
      is_dupe=1
    fi
    seen_checksums="${seen_checksums}:${checksum}"
  fi
  if egrep -q "${crash_detection_regexp}" <<< "${output}" || [[ ${swift_crash} == 1 ]]; then
    if [[ "${compilation_comment}" != "" ]]; then
      test_name="${test_name} (${compilation_comment})"
    fi
    num_crashed=$((num_crashed + 1))
    dupe_text="      "
    if [[ ${is_dupe} == 1 ]]; then
      dupe_text="*DUPE*"
    fi
    printf "  %b  %-${name_size}.${name_size}b %-6.6b (%-10.10b)\n" "${color_red}✘${color_normal_display}" "${test_name}" "${dupe_text}" "${checksum}"
  else
    printf "  %b  %-${name_size}.${name_size}b\n" "${color_green}✓${color_normal_display}" "${test_name}"
  fi
  if [[ ${verbose} == 1 ]]; then
    echo
    printf "%b" "${color_bold}Compilation output:${color_normal_display}\n"
    echo "${output}"
    echo
    printf "%b" "${color_bold}Crash detection regexp used:${color_normal_display}\n"
    echo "${crash_detection_regexp}"
    echo
  fi
}

run_tests_in_directory() {
  header="$1"
  path="$2"
  printf "%b" "== ${color_bold}${header}${color_normal_display} ==\n"
  echo
  found_tests=0
  for test_path in "${path}"/*.swift; do
    if [[ -f "${test_path}" ]]; then
      found_tests=1
      test_file "${test_path}"
    fi
  done
  if [[ ${found_tests} == 0 ]]; then
      printf "  %b  %-${name_size}.${name_size}b\n" "${color_green}✓${color_normal_display}" "No tests found."
  fi
  echo
}

main() {
  if [[ "${argument_files}" == "" ]]; then
    run_tests_in_directory "Currently known crashes" "./crashes"
    run_tests_in_directory "Crashes marked as fixed in previous releases" "./fixed"
  else
    for test_path in ${argument_files}; do
      if [[ -f "${test_path}" ]]; then
        found_tests=1
        test_file "${test_path}"
      fi
    done
    echo
  fi
  echo "** Results: ${num_crashed} of ${num_tests} tests crashed the compiler **"
  echo
}

main
