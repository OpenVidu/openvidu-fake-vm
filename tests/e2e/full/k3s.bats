#!/usr/bin/env bats
# bats file_tags=e2e:full
#
# k3s genuinely comes up inside the VM. We lean on `--verify-keep` (which installs k3s over
# SSH and waits until the node is Ready) as the bring-up, then assert Ready and run a pod.

load '../test_helper'

export FAKE_VM_NO_REGISTRY=1     # k3s pulls its images from Docker Hub directly here
E2E_IP="172.31.99.14"

setup_file() {
    require_e2e
    require_internet
    export BATS_TEST_TIMEOUT=900
    # --verify-keep installs k3s, waits for Ready, and leaves it running.
    "$FAKE_VM" start "$E2E_IP" --verify-keep >&2
    # The node reports Ready before the control plane finishes creating the default
    # namespace's ServiceAccount, so an immediate `kubectl run/create` can race with
    # "serviceaccount \"default\" not found". Wait for it before any workload test.
    "$FAKE_VM" ssh "$E2E_IP" \
        'for _ in $(seq 1 30); do sudo k3s kubectl -n default get serviceaccount default >/dev/null 2>&1 && exit 0; sleep 2; done; exit 1' >&2
}

teardown_file() {
    e2e_teardown
}

@test "the k3s node reports Ready" {
    run "$FAKE_VM" ssh "$E2E_IP" 'sudo k3s kubectl get nodes --no-headers'
    assert_success
    assert_output --partial "Ready"
}

@test "k3s schedules and runs a pod to completion" {
    "$FAKE_VM" ssh "$E2E_IP" \
        'sudo k3s kubectl run probe --image=busybox --restart=Never --command -- echo hi'

    local phase=""
    for _ in $(seq 1 60); do
        phase="$("$FAKE_VM" ssh "$E2E_IP" \
            'sudo k3s kubectl get pod probe -o jsonpath={.status.phase}' 2>/dev/null || true)"
        [[ "$phase" == "Succeeded" || "$phase" == "Failed" ]] && break
        sleep 3
    done
    assert_equal "$phase" "Succeeded"

    run "$FAKE_VM" ssh "$E2E_IP" 'sudo k3s kubectl logs probe'
    assert_success
    assert_output "hi"
}

# Integration: a real Deployment exposed via a NodePort, gated by the firewall — proving the
# pod + service + port-open + firewall work together, not just in isolation.
@test "a NodePort service is reachable only while the firewall opens it" {
    "$FAKE_VM" ssh "$E2E_IP" 'sudo k3s kubectl create deployment web --image=nginx:alpine'
    "$FAKE_VM" ssh "$E2E_IP" 'sudo k3s kubectl apply -f -' <<'YAML'
apiVersion: v1
kind: Service
metadata: { name: web }
spec:
  type: NodePort
  selector: { app: web }
  ports: [{ port: 80, targetPort: 80, nodePort: 30080 }]
YAML
    "$FAKE_VM" ssh "$E2E_IP" 'sudo k3s kubectl rollout status deploy/web --timeout=150s'

    # default-deny: the NodePort (DNAT'd, so ufw's INPUT never sees it) is blocked
    "$FAKE_VM" firewall "$E2E_IP" reset
    run port_reachable "$E2E_IP" 30080
    assert_failure

    # open it: reachable from the host
    "$FAKE_VM" firewall "$E2E_IP" open 30080/tcp
    run wait_reachable "$E2E_IP" 30080
    assert_success

    # close it: blocked again
    "$FAKE_VM" firewall "$E2E_IP" close 30080/tcp
    run port_reachable "$E2E_IP" 30080
    assert_failure
}

# The perimeter firewall must NOT touch the cluster's INTERNAL network: it gates external
# ingress (-i eth0), while pod-to-pod / ClusterIP traffic rides the CNI (flannel/cni0). Prove
# internal service communication still works even with the perimeter fully locked (default-deny).
@test "the firewall does not affect internal ClusterIP service communication" {
    "$FAKE_VM" ssh "$E2E_IP" 'sudo k3s kubectl create deployment backend --image=nginx:alpine'
    "$FAKE_VM" ssh "$E2E_IP" 'sudo k3s kubectl expose deployment backend --port=80'   # ClusterIP
    "$FAKE_VM" ssh "$E2E_IP" 'sudo k3s kubectl rollout status deploy/backend --timeout=150s'

    # Lock the perimeter down: default-deny, external ingress blocked (only 22 open).
    "$FAKE_VM" firewall "$E2E_IP" reset

    # A client pod reaches the backend by its ClusterIP DNS name — purely internal traffic,
    # plus internal CoreDNS resolution — neither of which should be affected by the firewall.
    "$FAKE_VM" ssh "$E2E_IP" \
        'sudo k3s kubectl run client --image=busybox --restart=Never --command -- \
             sh -c "wget -q -T 15 -O- http://backend >/dev/null 2>&1 && echo INTERNAL_OK || echo INTERNAL_FAIL"'

    local phase=""
    for _ in $(seq 1 60); do
        phase="$("$FAKE_VM" ssh "$E2E_IP" \
            'sudo k3s kubectl get pod client -o jsonpath={.status.phase}' 2>/dev/null || true)"
        [[ "$phase" == "Succeeded" || "$phase" == "Failed" ]] && break
        sleep 3
    done

    run "$FAKE_VM" ssh "$E2E_IP" 'sudo k3s kubectl logs client'
    assert_success
    assert_output "INTERNAL_OK"       # internal comms unaffected by the perimeter firewall
}
