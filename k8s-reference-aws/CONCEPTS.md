# Deep Concepts — IRSA, Karpenter, and other non-obvious AWS/k8s mechanics

---

## IRSA — IAM Roles for Service Accounts

### The problem it solves

Without IRSA, every pod on a node shares the **node's IAM instance profile**. That means:
- A compromised app pod can call any AWS API the node is allowed to — S3, EC2, RDS, everything
- You can't scope permissions per application
- Least-privilege is impossible at the pod level

IRSA gives each pod its own IAM role, scoped to exactly what that pod needs.

### How it works (the full chain)

```
Pod                  k8s API server          AWS STS             AWS Services
 |                       |                      |                     |
 | 1. Requests token      |                      |                     |
 |───projected volume────▶|                      |                     |
 | ◀── JWT (OIDC token) ──|                      |                     |
 |                                               |                     |
 | 2. AssumeRoleWithWebIdentity                  |                     |
 |───────────────────────────────────────────────▶                     |
 |    (JWT + role ARN)    |                      |                     |
 |                                               |                     |
 | 3. Short-lived creds   |                      |                     |
 | ◀─────────────────────────────────────────────|                     |
 |                                               |                     |
 | 4. Call AWS API with creds                    |                     |
 |───────────────────────────────────────────────────────────────────▶|
```

**Step by step:**

1. **EKS has an OIDC provider** — a URL like `oidc.eks.us-east-1.amazonaws.com/id/XXXXXXXX`. When you set `withOIDC: true` in eksctl, this gets created and registered with AWS IAM.

2. **k8s projects a signed JWT into the pod** — as a mounted volume at `/var/run/secrets/eks.amazonaws.com/serviceaccount/token`. This token is signed by the OIDC provider and contains the pod's ServiceAccount identity.

3. **The AWS SDK in the pod calls `sts:AssumeRoleWithWebIdentity`** automatically (via the credential provider chain) — it reads the projected token and the `AWS_ROLE_ARN` env var (injected by the EKS pod identity webhook).

4. **AWS IAM validates the JWT** against the OIDC provider's public keys, checks the trust policy, and returns short-lived credentials (expire in 1–24h, configurable).

### The IAM trust policy

The IAM role must explicitly trust your cluster's OIDC provider and the specific ServiceAccount:

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {
      "Federated": "arn:aws:iam::ACCOUNT_ID:oidc-provider/oidc.eks.us-east-1.amazonaws.com/id/OIDC_ID"
    },
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {
      "StringEquals": {
        "oidc.eks.us-east-1.amazonaws.com/id/OIDC_ID:sub":
          "system:serviceaccount:ghost-prod:ghost",
        "oidc.eks.us-east-1.amazonaws.com/id/OIDC_ID:aud":
          "sts.amazonaws.com"
      }
    }
  }]
}
```

The `sub` condition locks it down so only the `ghost` ServiceAccount in the `ghost-prod` namespace can assume this role — no other pod can, even on the same node.

### What you configure in k8s

Just one annotation on the ServiceAccount:
```yaml
eks.amazonaws.com/role-arn: arn:aws:iam::ACCOUNT_ID:role/ghost-prod-sa-role
```

The EKS pod identity webhook intercepts pod creation and:
- Injects `AWS_ROLE_ARN` and `AWS_WEB_IDENTITY_TOKEN_FILE` env vars
- Mounts the projected token volume automatically

### eksctl shortcut

```yaml
# eksctl-cluster.yaml
iam:
  withOIDC: true
  serviceAccounts:
    - metadata:
        name: ghost
        namespace: ghost-prod
      attachPolicyARNs:
        - arn:aws:iam::aws:policy/SecretsManagerReadWrite
```

eksctl creates the IAM role, writes the trust policy, and annotates the ServiceAccount. You can also do it with Terraform or manually.

### Why not just give the node the permissions?

| Node instance profile | IRSA |
|---|---|
| All pods on node share the role | Per-pod granularity |
| Blast radius: full node | Blast radius: one ServiceAccount |
| Can't audit per-app | CloudTrail logs show which SA called which API |
| Works without OIDC | Requires OIDC provider |

---

## Karpenter — Node Autoscaler

### What Cluster Autoscaler does (the old way)

Cluster Autoscaler watches for unschedulable pods and scales existing **node groups** up/down. You pre-define node groups in eksctl (instance type, min/max). When CAS decides to scale up, it increases the node group's desired count → EC2 Auto Scaling Group creates a new instance → ~3–5 min before pod can schedule.

Problems:
- You define instance types upfront — if spot isn't available for your chosen type, you're stuck
- One node group per instance type family (complex configs)
- Scale-down is conservative and slow
- No awareness of pod topology constraints when picking which node to add

### What Karpenter does

Karpenter watches the k8s scheduler's unschedulable pod queue directly. When it sees a pod that can't schedule, it:

1. Reads the pod's resource requests, node affinity, topology constraints
2. Selects the **cheapest instance type** from your allowed list that satisfies all constraints
3. Calls EC2 `RunInstances` directly (not Auto Scaling Group) — ~30–60 seconds to a running node
4. Registers the node in k8s and lets the pod schedule

On scale-down, Karpenter consolidates: it looks for nodes that could be bin-packed onto fewer nodes, cordons + drains the excess nodes (respecting PDBs), and terminates the EC2 instances.

### EC2NodeClass — the "what kind of EC2"

```yaml
apiVersion: karpenter.k8s.aws/v1
kind: EC2NodeClass
metadata:
  name: default
spec:
  amiFamily: AL2                  # Amazon Linux 2 — sets bootstrap script + AMI selection
  role: KarpenterNodeRole         # IAM role the launched nodes assume
  subnetSelectorTerms:            # which subnets to launch in (discovered by tag)
    - tags:
        karpenter.sh/discovery: prod-cluster
  securityGroupSelectorTerms:     # which SGs to attach
    - tags:
        karpenter.sh/discovery: prod-cluster
  blockDeviceMappings:            # root volume config
    - deviceName: /dev/xvda
      ebs:
        volumeSize: 50Gi
        volumeType: gp3
        encrypted: true
```

EC2NodeClass is the AWS-specific config: **how** to launch the EC2 (networking, storage, IAM, AMI). It's separate from the scheduling policy.

### NodePool — the "when and how many"

```yaml
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: default
spec:
  template:
    spec:
      nodeClassRef:
        name: default             # points to the EC2NodeClass
      requirements:               # constraints on what instances to pick
        - key: karpenter.sh/capacity-type
          operator: In
          values: ["spot", "on-demand"]    # spot first; falls back to on-demand
        - key: node.kubernetes.io/instance-type
          operator: In
          values: [m5.large, m5.xlarge, m6i.large, c5.xlarge]  # diverse = better spot availability
  limits:
    cpu: 200                      # hard cap — prevents runaway scaling
  disruption:
    consolidationPolicy: WhenEmptyOrUnderutilized
    consolidateAfter: 2m          # wait 2min of underutilization before disrupting
    budgets:
      - nodes: "20%"              # disrupt at most 20% of nodes at a time
```

NodePool is the k8s scheduling policy: **which** pods land on Karpenter nodes, **what** constraints apply, and **when** to scale down.

### Spot interruption handling

Karpenter listens to EC2 instance interruption notices via an SQS queue (EC2 sends a 2-minute warning before terminating spot instances). When it receives the warning, it:

1. Cordons the node (no new pods)
2. Triggers consolidation — finds replacement capacity on another instance
3. Drains the node gracefully (respects PDBs and `terminationGracePeriodSeconds`)
4. The replacement pod lands before the spot instance is terminated

The SQS queue is created by the Karpenter CloudFormation stack in install.sh.

### Karpenter vs Cluster Autoscaler

| | Cluster Autoscaler | Karpenter |
|---|---|---|
| Speed to new node | 3–5 min | 30–60s |
| Instance selection | You pre-define node groups | Picks cheapest that fits |
| Spot handling | Via ASG spot config | Native, via SQS interruption queue |
| Consolidation | Conservative, slow | Aggressive, configurable |
| Config surface | Node group definitions | NodePool + EC2NodeClass CRDs |
| Multi-AZ awareness | ASG handles it | Built into NodePool requirements |
| Works without AWS | Yes (other providers) | No — AWS-only |

### When to use multiple NodePools

- **GPU workloads** — separate NodePool with `nvidia.com/gpu` requirements + tolerations
- **Spot vs on-demand segregation** — mission-critical pods get `on-demand` NodePool via pod labels
- **System vs application** — system NodePool on on-demand; app NodePool on spot

---

## ConfigMap as volume vs env vars

```yaml
# Env vars — injected at pod start, never update without restart
envFrom:
  - configMapRef:
      name: ghost-config

# Volume mount — file updates when ConfigMap changes (within ~1min via kubelet sync)
volumes:
  - name: config
    configMap:
      name: ghost-config
volumeMounts:
  - name: config
    mountPath: /etc/ghost/config
    readOnly: true
```

Volume-mounted ConfigMaps hot-reload. Env var ConfigMaps do not — you must restart the pod. For config that changes frequently (feature flags, rate limits), volume mount is the pattern. For values the app reads once at startup (DB host, port), env vars are fine.

---

## VPC Endpoints — keeping traffic off the internet

By default, when a pod calls AWS APIs (S3, Secrets Manager, ECR, STS), the traffic routes through the NAT Gateway to the public internet and back. That costs money and adds latency.

VPC Interface Endpoints keep that traffic inside the VPC over AWS PrivateLink:

```bash
# Create endpoints for the services your pods call
for SERVICE in ecr.dkr ecr.api s3 secretsmanager sts logs; do
  aws ec2 create-vpc-endpoint \
    --vpc-id $VPC_ID \
    --service-name com.amazonaws.us-east-1.$SERVICE \
    --vpc-endpoint-type Interface \
    --subnet-ids $PRIVATE_SUBNET_IDS \
    --security-group-ids $SG_ID \
    --private-dns-enabled
done
```

With endpoints in place:
- ECR image pulls don't leave VPC (important for private ECR)
- Secrets Manager calls are sub-millisecond (same AZ)
- NAT Gateway data charges drop significantly on busy clusters
- Cluster works even if NAT Gateway is removed (for locked-down environments)

---

## ECR — private image registry

```bash
# Create a repository
aws ecr create-repository --repository-name ghost-custom --region us-east-1

# Build + push your image
aws ecr get-login-password | docker login --username AWS \
  --password-stdin ACCOUNT_ID.dkr.ecr.us-east-1.amazonaws.com

docker build -t ghost-custom .
docker tag ghost-custom:latest ACCOUNT_ID.dkr.ecr.us-east-1.amazonaws.com/ghost-custom:v1.0.0
docker push ACCOUNT_ID.dkr.ecr.us-east-1.amazonaws.com/ghost-custom:v1.0.0
```

In the Deployment, swap:
```yaml
image: ghost:5-alpine
# becomes:
image: ACCOUNT_ID.dkr.ecr.us-east-1.amazonaws.com/ghost-custom:v1.0.0
```

Node group IAM roles include `AmazonEC2ContainerRegistryReadOnly` — nodes can pull ECR images without additional secrets. The IRSA ServiceAccount can also pull if it has ECR permissions.

**ECR lifecycle policy** (prevent runstop storage costs):
```json
{
  "rules": [{
    "rulePriority": 1,
    "description": "Keep last 10 images",
    "selection": {"tagStatus": "any", "countType": "imageCountMoreThan", "countNumber": 10},
    "action": {"type": "expire"}
  }]
}
```

---

## PriorityClass — ensuring critical pods schedule first

When the cluster is under resource pressure, the scheduler evicts lower-priority pods to make room for higher-priority ones. Without PriorityClass, all your app pods compete equally with each other.

```yaml
apiVersion: scheduling.k8s.io/v1
kind: PriorityClass
metadata:
  name: high-priority
value: 1000000
globalDefault: false
description: "For business-critical workloads that should not be evicted"
---
apiVersion: scheduling.k8s.io/v1
kind: PriorityClass
metadata:
  name: low-priority
value: 100
globalDefault: true
description: "Default for non-critical batch workloads"
```

Assign in the Deployment:
```yaml
spec:
  template:
    spec:
      priorityClassName: high-priority
```

`system-cluster-critical` and `system-node-critical` are built-in — don't compete with these.

---

## QoS Classes — what the kubelet kills first under memory pressure

k8s automatically assigns one of three QoS classes based on your resource config:

| Class | Condition | Killed first? |
|---|---|---|
| Guaranteed | requests == limits on every container | Last |
| Burstable | requests set, limits differ OR not all containers have both | Middle |
| BestEffort | No requests or limits on any container | First |

For production: set requests AND limits on every container → Guaranteed class → never OOM-killed unless memory pressure is extreme.

For batch jobs: BestEffort is acceptable (they can be retried).

---

## Cluster upgrade — safe procedure

EKS upgrades one minor version at a time (1.28 → 1.29 → 1.30). Never skip versions.

```bash
# 1. Check current version
kubectl version --short
aws eks describe-cluster --name prod-cluster --query "cluster.version"

# 2. Review release notes + deprecations
# https://kubernetes.io/releases/ — check removed APIs

# 3. Upgrade control plane first
eksctl upgrade cluster --name prod-cluster --version 1.30 --approve

# 4. Upgrade managed add-ons (coredns, kube-proxy, vpc-cni, ebs-csi)
eksctl utils update-coredns --cluster prod-cluster --approve
eksctl utils update-kube-proxy --cluster prod-cluster --approve
eksctl utils update-aws-node --cluster prod-cluster --approve

# 5. Upgrade node groups (rolling — one node at a time, respects PDBs)
eksctl upgrade nodegroup --name system --cluster prod-cluster --kubernetes-version 1.30

# 6. Karpenter nodes self-upgrade — Karpenter replaces nodes with new AMI
# Force it if you don't want to wait for natural turnover:
kubectl annotate nodes -l karpenter.sh/nodepool=default \
  karpenter.sh/do-not-disrupt-

# 7. Verify
kubectl get nodes  # all nodes on new version
kubectl get pods -A  # all pods running
```

**Safe window**: upgrades are non-disruptive if PDBs are set and you have ≥2 replicas. Control plane upgrade causes ~10s API server unavailability (pods keep running; kubectl stops working briefly).
