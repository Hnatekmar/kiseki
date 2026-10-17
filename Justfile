# Render checks for CPU, GPU, ingress, sidecars, docker, and empty resources
lint:
    helm lint charts/dev-env --set ssh.authorizedKey=test
    helm template test charts/dev-env --set ssh.authorizedKey=test >/dev/null
    helm template test charts/dev-env --set ssh.authorizedKey=test --set resources=null >/dev/null
    helm template test charts/dev-env --set ssh.authorizedKey=test --set gpu=null >/dev/null
    helm template test charts/dev-env --set ssh.authorizedKey=test --set gpu.enabled=true >/dev/null
    helm template test charts/dev-env --set ssh.authorizedKey=test --set gpu.enabled=true --set resources=null >/dev/null
    helm template test charts/dev-env --set ssh.authorizedKey=test --set gpu.enabled=true --set 'resources.limits.nvidia\.com/gpu=5' | grep -q 'nvidia.com/gpu: 5'
    ! helm template test charts/dev-env --set ssh.authorizedKey=test --set gpu.enabled=true --set gpu.count=0 >/dev/null 2>&1
    # ingress: host required, ssh port rejected, TLS annotation rendered
    helm template test charts/dev-env --set ssh.authorizedKey=test --set ingress.enabled=true --set ingress.host=app.example.com --set ingress.port=3000 | grep -q 'cert-manager.io/cluster-issuer: letsencrypt-cloudflare'
    ! helm template test charts/dev-env --set ssh.authorizedKey=test --set ingress.enabled=true --set ingress.host=app.example.com --set ingress.tls=false | grep -q 'cert-manager.io/cluster-issuer'
    ! helm template test charts/dev-env --set ssh.authorizedKey=test --set ingress.enabled=true >/dev/null 2>&1
    ! helm template test charts/dev-env --set ssh.authorizedKey=test --set ingress.enabled=true --set ingress.host=app.example.com --set ingress.port=22 >/dev/null 2>&1
    # sidecars and dind
    helm template test charts/dev-env --set ssh.authorizedKey=test --set-json 'extraContainers=[{"name":"redis","image":"redis:7-alpine","ports":[{"name":"redis","containerPort":6379}]}]' | grep -q 'name: redis'
    helm template test charts/dev-env --set ssh.authorizedKey=test --set docker.enabled=true | grep -q 'privileged: true'
    ! helm template test charts/dev-env --set ssh.authorizedKey=test --set-json 'extraContainers=[{"name":"docker","image":"x"}]' >/dev/null 2>&1
    ! helm template test charts/dev-env --set ssh.authorizedKey=test --set-json 'extraContainers=[{"name":"redis"}]' >/dev/null 2>&1
    # CLI validation fails before it touches a cluster
    ! ./scripts/dev-env.sh create x --address app.example.com >/dev/null 2>&1
    ! ./scripts/dev-env.sh create x --port 3000 >/dev/null 2>&1
    ! ./scripts/dev-env.sh create x --address app.example.com --port 22 >/dev/null 2>&1
    ! ./scripts/dev-env.sh create x --address not-a-host --port 3000 >/dev/null 2>&1

# Smoke test: fresh kind cluster -> create env -> ssh -> destroy env
test: lint
    ./scripts/create-cluster.sh
    ./scripts/dev-env.sh create test --cpu 1 --memory 1Gi --ssh-key "$HOME/.ssh/id_ed25519.pub" --context kind-dev-envs-test-cluster
    ssh -o BatchMode=yes -o ConnectTimeout=15 k8s-dev-test 'echo smoke-ok'
    ./scripts/dev-env.sh destroy test -f

# GPU smoke test: fresh nvkind cluster -> GPU env -> nvidia-smi -> destroy env
test-gpu: lint
    ./scripts/test-gpu.sh
