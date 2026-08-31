#!/bin/bash

# `exec` so the JVM replaces this shell as PID 1 and receives SIGTERM directly.
# Without it this bash stays PID 1, the kubelet's SIGTERM never reaches the JVM,
# and the container is SIGKILLed at the end of terminationGracePeriodSeconds --
# which is why terminations record exitCode 137 / reason Error. See CU-86bbqrrrt.
#
# CORES restricts the JVM's CPU affinity mask, which is a per-core LICENCE
# obligation -- do not remove it. `limits.cpu` in the chart is a CFS *time*
# quota and restricts no cores; `-XX:ActiveProcessorCount` only changes what the
# JVM believes it has. Neither is a substitute for this mask.
exec taskset -c "${CORES}" /ro/PDFreactor/start.sh

