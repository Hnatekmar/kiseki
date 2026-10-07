# Smoke test: fresh kind cluster -> create env -> ssh -> destroy env
test:
    ./scripts/create-cluster.sh
    ./scripts/dev-env.sh create test --cpu 1 --memory 1Gi --ssh-key "$HOME/.ssh/id_ed25519.pub" --context kind-dev-envs-test-cluster
    ssh -o BatchMode=yes -o ConnectTimeout=15 k8s-dev-test 'echo smoke-ok'
    ./scripts/dev-env.sh destroy test -f
