#!/bin/bash
# Power-cut test of «Cambia formato» with little free space (docs/ROADMAP.md, 3.0 F → 3.2 A).
# A macOS VM (xipper-vm) converts a 1.5 GB ZIP to XIZ with --little-space and is switched off at a
# random moment, sometimes twice (the second time while it resumes); after each reboot the
# conversion must resume and end with a XIZ identical to the source, the ZIP gone.
#
# Unlike scripts/lowspace-crash.sh (kill -9), here the guest loses everything it had not flushed:
# its page cache and the APFS transactions in memory.
#
#   scripts/vm/powercut.sh [ROUNDS]        (default 20)
# Needs: the VM installed in ~/XipperVM/macos, set up once (powercut.sh prints what to do), and
# .build/release/xipper.
set -uo pipefail
ROUNDS=${1:-20}
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
VMDIR=${XIPPER_VM_DIR:-$HOME/XipperVM/macos}
VMUSER=${XIPPER_VM_USER:-xipper}
VM="$ROOT/.build/vm/xipper-vm"
KEY="$HOME/XipperVM/id_ed25519"
LOG="$ROOT/dist/powercut-$(date +%Y%m%d-%H%M).log"
mkdir -p "$ROOT/dist"

[ -x "$VM" ] || { echo "build it: scripts/vm/build.sh"; exit 2; }
[ -f "$KEY" ] || ssh-keygen -q -t ed25519 -N '' -C xipper-vm -f "$KEY"
mkdir -p "$VMDIR/share" && cp "$KEY.pub" "$VMDIR/share/xipper_vm.pub"

say() { echo "$*" | tee -a "$LOG"; }

ip_of_vm() {  # the VM's address from the DHCP leases of the host (vmnet NAT)
    local mac; mac=$("$VM" mac "$VMDIR" | tr -d '\n' | awk -F: '{for (i = 1; i <= NF; i++) { sub(/^0/, "", $i); printf "%s%s", $i, (i < NF ? ":" : "") }}')
    awk -v m="1,$mac" '/^{/ {ip = ""} /ip_address=/ {sub(/.*ip_address=/, ""); ip = $0} $0 ~ "hw_address=" m "$" {print ip; exit}' /var/db/dhcpd_leases 2>/dev/null
}
SSHOPT=(-i "$KEY" -o IdentitiesOnly=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile="$HOME/XipperVM/known_hosts" -o ConnectTimeout=5 -o BatchMode=yes)
g() { ssh "${SSHOPT[@]}" "$VMUSER@$IP" "$@"; }

VMPID=
boot() {
    "$VM" run "$VMDIR" >> "$LOG.vm" 2>&1 &
    VMPID=$!
    for _ in $(seq 1 120); do
        sleep 2
        IP=$(ip_of_vm)
        [ -n "$IP" ] && g true 2> /dev/null && return 0
        kill -0 $VMPID 2> /dev/null || { say "the VM exited during boot"; return 1; }
    done
    say "no SSH after 4 minutes"; return 1
}
power_cut() { kill -USR1 $VMPID; wait $VMPID 2> /dev/null; VMPID=; }
# At the end: what the guest has is flushed, then the VM is stopped (a test VM, nothing to save).
shutdown() { [ -n "$VMPID" ] && { g sync > /dev/null 2>&1; kill -USR1 $VMPID; wait $VMPID 2> /dev/null; }; }
trap shutdown EXIT

say "== power-cut test, $ROUNDS rounds, $(date)"
if ! boot; then
    cat <<EOF

The VM does not answer over SSH yet. Set it up once:
  1. $VM run "$VMDIR" --gui
  2. in the VM: Setup Assistant with a user named "$VMUSER" (no Apple Account, no FileVault);
     System Settings › General › Sharing › Remote Login on; then in Terminal:
       mkdir -p ~/.ssh && cat "/Volumes/My Shared Files/xipper_vm.pub" >> ~/.ssh/authorized_keys
  3. shut the VM down and run this script again.
EOF
    exit 2
fi
say "VM at $IP: $(g sw_vers -productVersion)"
g "mkdir -p pc" && scp -q "${SSHOPT[@]}" "$ROOT/.build/release/xipper" "$ROOT/scripts/vm/guest.sh" "$VMUSER@$IP:pc/" &&
    g "chmod +x pc/guest.sh pc/xipper && { [ -s pc/expected.sha ] || pc/guest.sh setup; }" | tee -a "$LOG"
DURATION=$(g "pc/guest.sh time")
say "one conversion takes ${DURATION}s in the VM"

pass=0
for r in $(seq 1 "$ROUNDS"); do
    g "pc/guest.sh reset" > /dev/null
    g "pc/guest.sh start" > /dev/null
    # Anywhere within the conversion, the start included.
    wait_s=$(awk -v s=$RANDOM -v d="$DURATION" 'BEGIN{srand(s); printf "%.2f", rand() * d}')
    sleep "$wait_s"
    state=$(g "pc/guest.sh state" | tr '\n' ' ')
    power_cut
    cuts=1
    boot || exit 1
    if [ $((r % 3)) -eq 0 ]; then
        # The second cut falls while it resumes.
        g "cd pc && nohup ./guest.sh finish > finish1.log 2>&1 < /dev/null &" > /dev/null
        sleep "$(awk -v s=$RANDOM -v d="$DURATION" 'BEGIN{srand(s); printf "%.2f", rand() * d}')"
        power_cut
        cuts=2
        boot || exit 1
    fi
    result=$(g "pc/guest.sh finish" 2>&1 | tail -1)
    say "round $r: cut after ${wait_s}s ($cuts cut$([ $cuts = 2 ] && echo s)), before the cut: ${state:-?} → $result"
    case $result in OK*) pass=$((pass + 1)) ;; esac
done
say "== $pass of $ROUNDS rounds ok"
[ "$pass" -eq "$ROUNDS" ]
