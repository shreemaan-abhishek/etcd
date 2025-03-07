#!/usr/bin/env bash

source ./scripts/test_lib.sh

GIT_SHA=$(git rev-parse --short HEAD || echo "GitNotFound")
if [[ -n "$FAILPOINTS" ]]; then
  GIT_SHA="$GIT_SHA"-FAILPOINTS
fi

VERSION_SYMBOL="${ROOT_MODULE}/api/v3/version.GitSHA"

# Set GO_LDFLAGS="-s" for building without symbols for debugging.
# shellcheck disable=SC2206
GO_LDFLAGS=(${GO_LDFLAGS} "-X=${VERSION_SYMBOL}=${GIT_SHA}")
GO_BUILD_ENV=("CGO_ENABLED=0" "GO_BUILD_FLAGS=${GO_BUILD_FLAGS}" "GOOS=${GOOS}" "GOARCH=${GOARCH}")

# enable/disable failpoints
toggle_failpoints() {
  mode="$1"
  if command -v gofail >/dev/null 2>&1; then
    run gofail "$mode" server/etcdserver/ server/storage/backend/ server/storage/mvcc/
    if [[ "$mode" == "enable" ]]; then
      (
        cd ./server
        run go get go.etcd.io/gofail/runtime
      ) || exit 2
      (
        cd ./etcdutl
        run go get go.etcd.io/gofail/runtime
      ) || exit 2
      (
        cd ./etcdctl
        run go get go.etcd.io/gofail/runtime
      ) || exit 2
      (
        cd ./tests
        run go get go.etcd.io/gofail/runtime
      ) || exit 2
    fi
  elif [[ "$mode" != "disable" ]]; then
    log_error "FAILPOINTS set but gofail not found"
    exit 1
  fi
}

toggle_failpoints_default() {
  mode="disable"
  if [[ -n "$FAILPOINTS" ]]; then mode="enable"; fi
  toggle_failpoints "$mode"
}

etcd_build() {
  out="bin"
  if [[ -n "${BINDIR}" ]]; then out="${BINDIR}"; fi
  toggle_failpoints_default

  run rm -f "${out}/etcd"
  (
    cd ./server
    # Static compilation is useful when etcd is run in a container. $GO_BUILD_FLAGS is OK
    # shellcheck disable=SC2086
    run env "${GO_BUILD_ENV[@]}" go build $GO_BUILD_FLAGS \
      -trimpath \
      -installsuffix=cgo \
      "-ldflags=${GO_LDFLAGS[*]}" \
      -o="../${out}/etcd" . || return 2
  ) || return 2

  run rm -f "${out}/etcdutl"
  # shellcheck disable=SC2086
  (
    cd ./etcdutl
    run env GO_BUILD_FLAGS="${GO_BUILD_FLAGS}" "${GO_BUILD_ENV[@]}" go build $GO_BUILD_FLAGS \
      -trimpath \
      -installsuffix=cgo \
      "-ldflags=${GO_LDFLAGS[*]}" \
      -o="../${out}/etcdutl" . || return 2
  ) || return 2

  run rm -f "${out}/etcdctl"
  # shellcheck disable=SC2086
  (
    cd ./etcdctl
    run env GO_BUILD_FLAGS="${GO_BUILD_FLAGS}" "${GO_BUILD_ENV[@]}" go build $GO_BUILD_FLAGS \
      -trimpath \
      -installsuffix=cgo \
      "-ldflags=${GO_LDFLAGS[*]}" \
      -o="../${out}/etcdctl" . || return 2
  ) || return 2
  # Verify whether symbol we overwrote exists
  # For cross-compiling we cannot run: ${out}/etcd --version | grep -q "Git SHA: ${GIT_SHA}"

  # We need symbols to do this check:
  if [[ "${GO_LDFLAGS[*]}" != *"-s"* ]]; then
    go tool nm "${out}/etcd" | grep "${VERSION_SYMBOL}" > /dev/null
    if [[ "${PIPESTATUS[*]}" != "0 0" ]]; then
      log_error "FAIL: Symbol ${VERSION_SYMBOL} not found in binary: ${out}/etcd"
      return 2
    fi
  fi
}

tools_build() {
  out="bin"
  if [[ -n "${BINDIR}" ]]; then out="${BINDIR}"; fi
  tools_path="tools/benchmark
    tools/etcd-dump-db
    tools/etcd-dump-logs
    tools/local-tester/bridge"
  for tool in ${tools_path}
  do
    echo "Building" "'${tool}'"...
    run rm -f "${out}/${tool}"
    # shellcheck disable=SC2086
    run env GO_BUILD_FLAGS="${GO_BUILD_FLAGS}" CGO_ENABLED=0 go build ${GO_BUILD_FLAGS} \
      -trimpath \
      -installsuffix=cgo \
      "-ldflags=${GO_LDFLAGS[*]}" \
      -o="${out}/${tool}" "./${tool}" || return 2
  done
  tests_build "${@}"
}

tests_build() {
  out=${BINDIR:-./bin}
  out=$(readlink -f "$out")
  out="${out}/functional/cmd"
  mkdir -p "${out}"
  BINDIR="${out}" run ./tests/functional/build.sh || return 2
}

run_build() {
  echo Running "$1"
  if $1; then
    log_success "SUCCESS: $1 (GOARCH=${GOARCH})"
  else
    log_error "FAIL: $1 (GOARCH=${GOARCH})"
    exit 2
  fi
}

toggle_failpoints_default
