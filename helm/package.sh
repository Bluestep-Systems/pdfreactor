#!/bin/bash
set -e
cd $(dirname ${0})
helm package . -d ../../../../charts
helm repo index ../../../../charts