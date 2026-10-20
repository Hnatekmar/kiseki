package cli

import (
	"flag"
	"strings"
)

// The option sets below describe the commands the Bash script still owns. Nothing
// parses them here yet: they exist so the help text is generated from
// definitions rather than maintained by hand, and so the port inherits the shape
// it has to reproduce. TestLegacyFlagsMatchBash fails when one of these flags is
// not one the script actually accepts, which keeps the documentation honest
// until the command moves.

type createOptions struct {
	cpu, memory, sshKey, kubeContext, address, port string
	persistenceSize, storageClass                   string
	gpu                                             int
	docker, json, noCheck, persistence              bool
	containers, sets, values                        stringList
}

func (o *createOptions) register(fs *flag.FlagSet) {
	fs.StringVar(&o.cpu, "cpu", "", "CPU cores (default: prompt then 4)")
	fs.StringVar(&o.memory, "memory", "", "Memory, e.g. 8Gi (default: prompt then 8Gi)")
	fs.IntVar(&o.gpu, "gpu", 0, "request N NVIDIA GPUs")
	fs.StringVar(&o.sshKey, "ssh-key", "", "SSH public key path")
	fs.StringVar(&o.kubeContext, "context", "", "Kubernetes context")
	fs.StringVar(&o.address, "address", "", "publish an Ingress for HOST; requires --port")
	fs.StringVar(&o.port, "port", "", "container port the app listens on; requires --address")
	fs.Var(&o.containers, "container", "sidecar in the pod, repeatable: name=IMAGE[:TAG][,port=N][,env=KEY=VALUE]")
	fs.BoolVar(&o.docker, "docker", false, "add a docker:dind sidecar and set DOCKER_HOST")
	fs.BoolVar(&o.persistence, "persistence", false, "persist /root on a PVC (default 10Gi)")
	fs.StringVar(&o.persistenceSize, "persistence-size", "", "PVC size, implies --persistence (e.g. 20Gi)")
	fs.StringVar(&o.storageClass, "storage-class", "", "StorageClass for the PVC, implies --persistence")
	fs.Var(&o.sets, "set", "Helm value override, repeatable (e.g. image.tag=43)")
	fs.Var(&o.values, "values", "Helm values file, repeatable")
	fs.Var(&o.values, "f", "Helm values file, repeatable (same flag as --values)")
	fs.BoolVar(&o.json, "json", false, "print one JSON object on stdout, progress on stderr")
	fs.BoolVar(&o.noCheck, "no-check", false, "skip the SSH connectivity check")
}

type destroyOptions struct {
	force bool
}

func (o *destroyOptions) register(fs *flag.FlagSet) {
	fs.BoolVar(&o.force, "f", false, "force destroy without confirmation")
}

// stringList is a repeatable string flag.
type stringList []string

func (s *stringList) String() string { return strings.Join(*s, ",") }

func (s *stringList) Set(value string) error {
	*s = append(*s, value)
	return nil
}
