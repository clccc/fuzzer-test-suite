#!/bin/bash
# Copyright 2017 Google Inc. All Rights Reserved.
# Licensed under the Apache License, Version 2.0 (the "License");

# set -x
. benchmark.cfg
. parameters.cfg
. fengine.cfg

FENGINE_NAME=$(curl http://metadata.google.internal/computeMetadata/v1/instance/attributes/fengine -H "Metadata-Flavor: Google")

BINARY=${BENCHMARK}-${FUZZING_ENGINE}

# seeds comes from dispatcher.sh, if it exists
chmod 750 $BINARY

# All options which are always called here, rather than being left
# to $BINARY_RUNTIME_OPTIONS, are effectively mandatory

if [[ $FUZZING_ENGINE == "afl" ]]; then
  chmod 750 afl-fuzz

  # AFL requires some starter input
  if [[ ! -d seeds ]]; then
    mkdir seeds
  fi
  if [[ !$(find seeds -type f) ]]; then
    echo "Input" > ./seeds/nil_seed
  fi
  # TODO: edit core_pattern in Docker VM
  # https://groups.google.com/forum/m/#!msg/afl-users/7arn66RyNfg/BsnOPViuCAAJ
  export AFL_I_DONT_CARE_ABOUT_MISSING_CRASHES=1

  EXEC_CMD="./afl-fuzz $BINARY_RUNTIME_OPTIONS -i ./seeds/ -o corpus -- $BINARY &"
  PROCESS_NAME="afl-fuzz"
elif [[ $FUZZING_ENGINE == "libfuzzer" ]]; then

  EXEC_CMD="./$BINARY $BINARY_RUNTIME_OPTIONS -workers=$JOBS -jobs=$JOBS corpus"
  PROCESS_NAME=$BINARY

  if [[ -d seeds ]]; then
    EXEC_CMD="$EXEC_CMD seeds"
  fi
  EXEC_CMD="$EXEC_CMD &"

fi

# Folder name to sync to (convenient)
SYNC_TO=${BENCHMARK}-${FENGINE_NAME}
# WAIT_PERIOD should be longer than the whole loop, otherwise a sync cycle will be missed
WAIT_PERIOD=20

conduct_experiment() {
  TRIAL_NUM=$1

  rm -fr corpus corpus-archives results
  mkdir -p corpus corpus-archives results

  # "cycle 0" will be "time 0", and for purposes is skipped
  CYCLE=1
  # Now, begin
  $EXEC_CMD
  # Setting SECONDS is fine, it still gets ++ on schedule
  SECONDS=0
  NEXT_SYNC=$WAIT_PERIOD

  while [[ $(ps -x | grep $PROCESS_NAME) ]]; do

    # Ensure that measurements happen every $WAIT_PERIOD
    SLEEP_TIME=$(($NEXT_SYNC - $SECONDS))
    sleep $SLEEP_TIME

    # Snapshot
    cp -r corpus corpus-copy

    echo "VM_SECONDS=$SECONDS" > results/seconds-${CYCLE}
    # ls -l corpus-copy > results/corpus-data-${CYCLE}
    tar -cvzf corpus-archives/corpus-archive-${CYCLE}.tar.gz corpus-copy
    gsutil -m rsync -rPd results gs://fuzzer-test-suite/experiment-folders/${SYNC_TO}/trial-${TRIAL_NUM}/results
    gsutil -m rsync -rPd corpus-archives gs://fuzzer-test-suite/experiment-folders/${SYNC_TO}/trial-${TRIAL_NUM}/corpus

    # Done with snapshot
    rm -r corpus-copy

    CYCLE=$(($CYCLE + 1))
    NEXT_SYNC=$(($CYCLE * $WAIT_PERIOD))
    # Skip cycle if need be
    while [[ $(($NEXT_SYNC < $SECONDS)) == 1 ]]; do
      echo "$CYCLE" >> results/skipped-cycles
      CYCLE=$(($CYCLE + 1))
      NEXT_SYNC=$(($CYCLE * $WAIT_PERIOD))
    done

  done
}

TRIAL_NUM=0
while [[ $TRIAL_NUM != $N_ITERATIONS ]]; do
  conduct_experiment $TRIAL_NUM
  TRIAL_NUM=$(($TRIAL_NUM + 1))
done

