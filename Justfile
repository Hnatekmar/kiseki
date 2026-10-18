set shell := ["bash", "-cu"]

# Render checks for CPU, GPU, ingress, sidecars, docker, persistence, and empty resources
lint:
    helm lint charts/kiseki --set ssh.authorizedKey=test
    helm template test charts/kiseki --set ssh.authorizedKey=test >/dev/null
    helm template test charts/kiseki --set ssh.authorizedKey=test --set resources=null >/dev/null
    helm template test charts/kiseki --set ssh.authorizedKey=test --set gpu=null >/dev/null
    helm template test charts/kiseki --set ssh.authorizedKey=test --set gpu.enabled=true >/dev/null
    helm template test charts/kiseki --set ssh.authorizedKey=test --set gpu.enabled=true --set resources=null >/dev/null
    helm template test charts/kiseki --set ssh.authorizedKey=test --set gpu.enabled=true --set 'resources.limits.nvidia\.com/gpu=5' | grep -q 'nvidia.com/gpu: 5'
    ! helm template test charts/kiseki --set ssh.authorizedKey=test --set gpu.enabled=true --set gpu.count=0 >/dev/null 2>&1
    # ingress: host required, ssh port rejected, TLS annotation rendered
    helm template test charts/kiseki --set ssh.authorizedKey=test --set ingress.enabled=true --set ingress.host=app.example.com --set ingress.port=3000 | grep -q 'cert-manager.io/cluster-issuer: letsencrypt-cloudflare'
    ! helm template test charts/kiseki --set ssh.authorizedKey=test --set ingress.enabled=true --set ingress.host=app.example.com --set ingress.tls=false | grep -q 'cert-manager.io/cluster-issuer'
    ! helm template test charts/kiseki --set ssh.authorizedKey=test --set ingress.enabled=true >/dev/null 2>&1
    ! helm template test charts/kiseki --set ssh.authorizedKey=test --set ingress.enabled=true --set ingress.host=app.example.com --set ingress.port=22 >/dev/null 2>&1
    # sidecars and dind
    helm template test charts/kiseki --set ssh.authorizedKey=test --set-json 'extraContainers=[{"name":"redis","image":"redis:7-alpine","ports":[{"name":"redis","containerPort":6379}]}]' | grep -q 'name: redis'
    helm template test charts/kiseki --set ssh.authorizedKey=test --set docker.enabled=true | grep -q 'privileged: true'
    ! helm template test charts/kiseki --set ssh.authorizedKey=test --set-json 'extraContainers=[{"name":"docker","image":"x"}]' >/dev/null 2>&1
    ! helm template test charts/kiseki --set ssh.authorizedKey=test --set-json 'extraContainers=[{"name":"redis"}]' >/dev/null 2>&1
    # volumes, init containers, and the sidecar wait list
    helm template test charts/kiseki --set ssh.authorizedKey=test -f examples/extraSVC.yaml | grep -q 'KISEKI_WAIT_PORTS'
    helm template test charts/kiseki --set ssh.authorizedKey=test -f examples/extraSVC.yaml | grep -q 'initContainers:'
    ! helm template test charts/kiseki --set ssh.authorizedKey=test --set-json 'extraVolumes=[{"name":"data","emptyDir":{}}]' >/dev/null 2>&1
    ! helm template test charts/kiseki --set ssh.authorizedKey=test --set-json 'extraVolumes=[{"name":"a","emptyDir":{}},{"name":"a","emptyDir":{}}]' >/dev/null 2>&1
    # persistence: the claim is the home directory, not /data
    helm template test charts/kiseki --set ssh.authorizedKey=test --set storage.enabled=true | grep -q 'mountPath: /root'
    helm template test charts/kiseki --set ssh.authorizedKey=test --set storage.enabled=true --set storage.size=20Gi | grep -q 'storage: 20Gi'
    ! helm template test charts/kiseki --set ssh.authorizedKey=test --set storage.enabled=true | grep -q 'mountPath: /data'
    ! ./scripts/kiseki.sh create x --persistence-size nope >/dev/null 2>&1
    ! ./scripts/kiseki.sh create x --storage-class 'Bad_Class' >/dev/null 2>&1
    # the committed example must match the generator
    diff <(./scripts/kiseki.sh example) examples/extraSVC.yaml
    # CLI validation fails before it touches a cluster
    ! ./scripts/kiseki.sh create x --address app.example.com >/dev/null 2>&1
    ! ./scripts/kiseki.sh create x --port 3000 >/dev/null 2>&1
    ! ./scripts/kiseki.sh create x --address app.example.com --port 22 >/dev/null 2>&1
    ! ./scripts/kiseki.sh create x --address not-a-host --port 3000 >/dev/null 2>&1
    # installer round trip in a throwaway bin directory
    tmp=$(mktemp -d) && ./scripts/install.sh --bindir "$tmp" >/dev/null && "$tmp/kiseki" --help >/dev/null && ./scripts/install.sh --uninstall --bindir "$tmp" >/dev/null && [ ! -e "$tmp/kiseki" ] && rm -rf "$tmp"

# Install the CLI into ~/.local/bin (override with PREFIX or --bindir)
install:
    ./scripts/install.sh

# Regenerate the committed sidecar example
example:
    ./scripts/kiseki.sh example --output examples/extraSVC.yaml

# Smoke test: fresh kind cluster -> create env -> ssh -> destroy env
test: lint
    ./scripts/create-cluster.sh
    ./scripts/kiseki.sh create test --cpu 1 --memory 1Gi --ssh-key "$HOME/.ssh/id_ed25519.pub" --context kind-kiseki-test-cluster
    ssh -o BatchMode=yes -o ConnectTimeout=15 kiseki-test 'echo smoke-ok'
    ./scripts/kiseki.sh destroy test -f

# GPU smoke test: fresh nvkind cluster -> GPU env -> nvidia-smi -> destroy env
test-gpu: lint
    ./scripts/test-gpu.sh
