# Render checks for CPU, GPU, and empty resources
lint:
    helm lint charts/dev-env --set ssh.authorizedKey=test
    helm template test charts/dev-env --set ssh.authorizedKey=test >/dev/null
    helm template test charts/dev-env --set ssh.authorizedKey=test --set resources=null >/dev/null
    helm template test charts/dev-env --set ssh.authorizedKey=test --set gpu=null >/dev/null
    helm template test charts/dev-env --set ssh.authorizedKey=test --set gpu.enabled=true >/dev/null
    helm template test charts/dev-env --set ssh.authorizedKey=test --set gpu.enabled=true --set resources=null >/dev/null
    helm template test charts/dev-env --set ssh.authorizedKey=test --set gpu.enabled=true --set 'resources.limits.nvidia\.com/gpu=5' | grep -q 'nvidia.com/gpu: 5'
    ! helm template test charts/dev-env --set ssh.authorizedKey=test --set gpu.enabled=true --set gpu.count=0 >/dev/null 2>&1

# Smoke test: fresh kind cluster -> create env -> ssh -> destroy env
test: lint
    ./scripts/create-cluster.sh
    ./scripts/dev-env.sh create test --cpu 1 --memory 1Gi --ssh-key "$HOME/.ssh/id_ed25519.pub" --context kind-dev-envs-test-cluster
    ssh -o BatchMode=yes -o ConnectTimeout=15 k8s-dev-test 'echo smoke-ok'
    ./scripts/dev-env.sh destroy test -f

# GPU smoke test: fresh nvkind cluster -> GPU env -> nvidia-smi -> destroy env
test-gpu: lint
    ./scripts/test-gpu.sh
