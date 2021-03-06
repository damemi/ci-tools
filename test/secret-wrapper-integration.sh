#!/bin/bash
set -euo pipefail

dir=$(mktemp -d)
trap 'rm -r "${dir}"' EXIT
export SHARED_DIR=${dir}/shared
export TMPDIR=${dir}/tmp
export NAMESPACE=test
export JOB_NAME_SAFE=test
ERR=${dir}/err.log
SECRET='[
  {
    "kind": "Secret",
    "apiVersion": "v1",
    "metadata": {
      "name": "test",
      "creationTimestamp": null
    },
    "data": {
      "test0.txt": "dGVzdDAK"
    },
    "type": "Opaque"
  }
]'

fail() {
    echo "$1"
    cat "${ERR}"
    return 1
}

check_output() {
    local out
    if ! out=$(diff /dev/fd/3 /dev/fd/4 3<<<"$1" 4<<<"${SECRET}"); then
        echo '[ERROR] incorrect dry-run output:'
        echo "${out}"
        return 1
    fi
}

test_mkdir() {
    echo '[INFO] Verifying the directory is created'
    [[ ! -e "${TMPDIR}" ]]
    if ! secret-wrapper --dry-run true > /dev/null 2> "${ERR}"; then
        fail '[ERROR] secret-wrapper failed'
    fi
    if ! [[ -e "${TMPDIR}" ]]; then
        fail '[ERROR] secret-wrapper did not create the directory'
    fi
}

test_shared_dir() {
    echo '[INFO] Verifying SHARED_DIR is set correctly'
    if ! v=$(secret-wrapper --dry-run bash -c 'echo >&3 "${SHARED_DIR}"' \
        3>&1 > /dev/null 2> "${ERR}")
    then
        fail '[ERROR] secret-wrapper failed'
    fi
    diff <(echo "$v") <(echo "${TMPDIR}"/secret)
}

test_copy_dir() {
    local data_dir=..2020_03_09_17_18_45.291041453
    echo '[INFO] Verifying SHARED_DIR is copied correctly'
    mkdir "${SHARED_DIR}/${data_dir}"
    echo test0 > "${SHARED_DIR}/${data_dir}/test0.txt"
    ln -s "${data_dir}" "${SHARED_DIR}/..data"
    ln -s ..2020_03_09_17_18_45.291041453 "${SHARED_DIR}/..data"
    ln -s ..data/test0.txt "${SHARED_DIR}/test0.txt"
    [[ ! -e "${TMPDIR}/secret/test.txt" ]]
    if ! secret-wrapper --dry-run true > /dev/null 2> "${ERR}"; then
        fail '[ERROR] secret-wrapper failed'
    fi
    echo test0 | diff "${TMPDIR}/secret/test0.txt" -
    if [[ -L "${TMPDIR}/secret/..data" ]]; then
        fail '[ERROR] symlinks should not be copied'
    fi
    if [[ -e "${TMPDIR}/secret/..2020_03_09_17_18_45.291041453" ]]; then
        fail '[ERROR] directories should not be copied'
    fi
}

test_signal() {
    local pid
    secret-wrapper --dry-run sleep 1d 2> "${ERR}" &
    pid=$!
    if ! timeout 1s sh -c \
        'until pgrep -P "$1" sleep > /dev/null ; do :; done' \
        sh "${pid}"
    then
        kill "${pid}"
        fail '[ERROR] timeout while waiting for `sleep` to start:'
    fi
    kill -s "$1" "${pid}"
    if wait "$pid"; then
        fail "[ERROR] secret-wrapper did not fail as expected:"
    fi
}

mkdir "${SHARED_DIR}"
test_mkdir
test_shared_dir
test_copy_dir
echo '[INFO] Running `secret-wrapper true`...'
if ! out=$(secret-wrapper --dry-run true 2> "${ERR}"); then
    fail "[ERROR] secret-wrapper failed:"
fi
check_output "${out}"
echo '[INFO] Running `secret-wrapper false`...'
if out=$(secret-wrapper --dry-run false 2> "${ERR}"); then
    fail "[ERROR] secret-wrapper did not fail:"
fi
check_output "${out}"
echo '[INFO] Running `secret-wrapper sleep 1d` and sending SIGINT...'
out=$(test_signal INT)
check_output "${out}"
echo '[INFO] Running `secret-wrapper sleep 1d` and sending SIGTERM...'
out=$(test_signal TERM)
check_output "${out}"
echo "[INFO] Success"
