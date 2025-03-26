#!/bin/bash
set -e
cd $(dirname ${0})
docker compose build b6p-pdfreactor
docker push ghcr.io/bluestep-systems/b6p-pdfreactor:latest
docker push ghcr.io/bluestep-systems/b6p-pdfreactor:1.0.0
