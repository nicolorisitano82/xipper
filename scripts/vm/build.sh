#!/bin/bash
# Builds and signs xipper-vm (needs the virtualization entitlement; ad-hoc signature is enough).
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p ../../.build/vm
swiftc -O -o ../../.build/vm/xipper-vm xipper-vm.swift
codesign -s - -f --entitlements xipper-vm.entitlements ../../.build/vm/xipper-vm
echo "../../.build/vm/xipper-vm"
