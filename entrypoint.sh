#!/bin/bash

taskset -c "${CORES}" /ro/PDFreactor/start.sh java -jar start.jar

