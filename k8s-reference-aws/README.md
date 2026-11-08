# Kubernetes on AWS — Production Reference

Ghost blog on EKS. Real AWS-native stack: Karpenter, ALB, RDS, EFS, External Secrets, ExternalDNS.

Compare with `../k8s-reference/` to see what changes when you go from generic k8s to AWS production.

## What's different from the generic reference

| Generic | AWS Production |
|---|---|
| Any k8s cluster | EKS (managed control plane) |
| nginx-ingress + cert-manager | AWS Load Balancer Controller (ALB) + ACM |
| MySQL StatefulSet | RDS Multi-AZ (outside the cluster) |
| `ReadWriteOnce` EBS PVC | `ReadWriteMany` EFS PVC (required for multi-pod mounts) |
| k8s Secret (`stringData`) | External Secrets Operator → AWS Secrets Manager |
| Cluster Autoscaler | Karpenter (faster, smarter, spot-aware) |
| Pod-level AWS access via node IAM role | IRSA — per-pod IAM roles via OIDC token projection |
| Manual DNS | ExternalDNS → Route53 |
| No log aggregation | Fluent Bit → CloudWatch Container Insights |
| Generic StorageClass | EBS gp3 StorageClass (EKS CSI driver required) |

---

## Prerequisites (install once)

```bash
# Tools
brew install awscli eksctl kubectl helm

# AWS credentials configured
aws configure  # or use SSO: aws sso login

# Verify account
aws sts get-caller-identity
```

---

## Step 1 — AWS resources (create before cluster)

```bash
# 1a. ACM certificate for your domain
aws acm request-certificate \
  --domain-name blog.example.com \
  --validation-method DNS \
  --region us-east-1
# Complete DNS validation in Route53 (it gives you a CNAME to add)

# 1b. RDS MySQL (Multi-AZ for production)
aws rds create-db-instance \
  --db-instance-identifier ghost-db \
  --db-instance-class db.t3.medium \
  --engine mysql \
  --engine-version 8.0 \
  --master-username admin \
  --master-user-password "CHANGE_ME" \
  --db-name ghost \
  --allocated-storage 20 \
  --storage-type gp3 \
  --storage-encrypted \
  --multi-az \
  --no-publicly-accessible \
  --vpc-security-group-ids sg-XXXXXXXX  # your cluster security group
# Note the endpoint: ghost-db.xxxxxxxxxx.us-east-1.rds.amazonaws.com
# Put that in app/04-configmap.yaml as database__connection__host

# 1c. Secrets Manager entries
aws secretsmanager create-secret \
  --name ghost/db \
  --secret-string '{"user":"ghost","password":"STRONG_RANDOM_PASS"}'

aws secretsmanager create-secret \
  --name ghost/smtp \
  --secret-string '{"user":"SES_ACCESS_KEY","pass":"SES_SECRET_KEY"}'

# 1d. Route53 hosted zone (if you don't have one)
aws route53 create-hosted-zone \
  --name example.com \
  --caller-reference $(date +%s)
```

---

## Step 2 — Create the EKS cluster

```bash
# Edit cluster/eksctl-cluster.yaml first:
#   - Replace ACCOUNT_ID
#   - Replace YOUR_OFFICE_CIDR
#   - Set region if not us-east-1

eksctl create cluster -f cluster/eksctl-cluster.yaml

# This takes ~15 minutes. eksctl:
#   - Creates VPC + subnets (3 AZs, public + private)
#   - Provisions EKS control plane
#   - Creates system managed node group (2× m5.large)
#   - Sets up OIDC provider for IRSA
#   - Creates IRSA service accounts with correct IAM roles
#   - Installs EKS managed add-ons (vpc-cni, coredns, kube-proxy, ebs-csi)

# Verify
kubectl get nodes
kubectl get pods -n kube-system
```

---

## Step 3 — Install add-ons

```bash
# Edit addons/install.sh:
#   - CLUSTER_NAME, AWS_REGION are set from env above
#   - The script creates the Karpenter CloudFormation stack, EFS filesystem,
#     and installs all Helm charts in the correct order

chmod +x addons/install.sh
./addons/install.sh

# After it completes, grab the EFS filesystem ID from the output:
# EFS_FS_ID=fs-xxxxxxxxx  ← update app/05-storage.yaml

# Verify add-ons
kubectl get pods -n kube-system
kubectl get pods -n external-secrets
```

---

## Step 4 — Update placeholders

```bash
# Across the app/ manifests, replace:
grep -r "ACCOUNT_ID\|CERTIFICATE_ARN\|RDS_ENDPOINT\|EFS_FILESYSTEM_ID\|example\.com" app/
```

| Placeholder | Where | How to get it |
|---|---|---|
| `ACCOUNT_ID` | 01, 02, 07 | `aws sts get-caller-identity --query Account` |
| `CERTIFICATE_ARN` | 07-ingress.yaml | `aws acm list-certificates` |
| `RDS_ENDPOINT` | 04-configmap.yaml | `aws rds describe-db-instances --query 'DBInstances[0].Endpoint.Address'` |
| `EFS_FILESYSTEM_ID` | 05-storage.yaml | output from install.sh |
| `10.0.0.0/8` | 09-networkpolicy.yaml | your VPC CIDR (`aws ec2 describe-vpcs`) |

---

## Step 5 — Deploy the app

```bash
# Apply in order — numbered filenames enforce it
kubectl apply -f app/00-namespace.yaml
kubectl apply -f app/01-serviceaccount.yaml
kubectl apply -f app/02-secretstore.yaml
kubectl apply -f app/03-externalsecret.yaml
kubectl apply -f app/04-configmap.yaml
kubectl apply -f app/05-storage.yaml
kubectl apply -f app/06-ghost-deployment.yaml
kubectl apply -f app/07-ingress.yaml
kubectl apply -f app/08-hpa.yaml
kubectl apply -f app/09-networkpolicy.yaml
kubectl apply -f app/10-pdb.yaml

# Or all at once after ordering is confirmed:
# kubectl apply -f app/
```

---

## Step 6 — Verify

```bash
# Pods running and spread across AZs
kubectl -n ghost-prod get pods -o wide

# External Secrets synced
kubectl -n ghost-prod get externalsecret
kubectl -n ghost-prod get secret ghost-secrets

# ALB provisioned (takes 2-3 min)
kubectl -n ghost-prod get ingress
# ADDRESS column will show the ALB DNS name when ready

# HPA
kubectl -n ghost-prod get hpa

# Check topology spread
kubectl -n ghost-prod get pods -o json | jq '.items[].spec.nodeName'
kubectl get nodes -L topology.kubernetes.io/zone

# Karpenter nodes (if HPA scaled up and new nodes were needed)
kubectl get nodes -l role=application
```

---

## Operations

```bash
# Logs
kubectl -n ghost-prod logs -l app=ghost --tail=100 -f
# Or in CloudWatch: /aws/containerinsights/prod-cluster/application

# Shell into pod
kubectl -n ghost-prod exec -it deploy/ghost -- sh

# Rolling restart (e.g. after ConfigMap change)
kubectl -n ghost-prod rollout restart deploy/ghost
kubectl -n ghost-prod rollout status deploy/ghost

# Scale manually (HPA overrides this based on load)
kubectl -n ghost-prod scale deploy/ghost --replicas=4

# Check Karpenter consolidation activity
kubectl -n kube-system logs -l app.kubernetes.io/name=karpenter -f

# Force node drain (PDB prevents it from killing the last pod)
kubectl drain <node-name> --ignore-daemonsets --delete-emptydir-data

# Tear down app (keeps cluster + RDS + EFS)
kubectl delete namespace ghost-prod

# Tear down cluster
eksctl delete cluster -f cluster/eksctl-cluster.yaml
```

---

## Cost levers

| Resource | Cost driver | How to control |
|---|---|---|
| EKS control plane | $0.10/hr flat | Can't avoid — it's EKS |
| System node group | 2× m5.large on-demand | Size down if just running this app |
| Karpenter nodes | Spot by default | Mix spot/on-demand ratio in NodePool |
| NAT Gateway | $0.045/hr × 3 AZs + data | HighlyAvailable is expensive — use `Single` for non-prod |
| RDS | db.t3.medium Multi-AZ | Use Single-AZ for non-prod |
| ALB | ~$16/mo + LCU | One ALB per cluster (use IngressGroup to share) |
| EFS | $0.30/GB/mo | Elastic throughput — scales with usage |
| CloudWatch | Per GB ingested | Set log retention, filter noisy logs |

---

## Secret values in YAML — why there are none

Passwords and keys are **never in these YAML files**. The files contain only `secretKeyRef` pointers. The actual values live in AWS Secrets Manager and are pulled into the cluster at runtime by External Secrets Operator.

The old pattern (avoid in production):
```yaml
# 02-secret.yaml — DON'T do this; values end up in git
stringData:
  mysql-password: "my-actual-password"
```

The production pattern (this reference):
```yaml
# 03-externalsecret.yaml — pointer only, no value
remoteRef:
  key: ghost/db
  property: password
# ESO creates ghost-secrets k8s Secret from Secrets Manager at runtime
```

**For variablizing non-secret values** (image tag, replica count, env-specific URLs) — raw YAML doesn't template. Production pipelines use:
- **Kustomize** — patch overlays per environment (`base/` + `overlays/prod/`, `overlays/staging/`)
- **Helm** — full templating (`{{ .Values.image.tag }}`), chart versioning, rollback
- This reference uses raw YAML for readability — in a real repo, wrap it in one of those.

---

## What's not in this reference

- Helm chart / Kustomize overlays (raw YAML for readability — see above for when to add them)
- ArgoCD / Flux (GitOps is a separate layer on top of this)
- Istio / Linkerd (service mesh — add if you need mTLS between pods)
- Amazon Managed Prometheus + Grafana (add for custom metrics + dashboards)
- Velero (cluster backup) + RDS automated backups (enable in RDS config)
- Multi-cluster / multi-region (blue/green via Route53 weighted routing)

---

## Human user access to the cluster

k8s has no native user accounts — there's no `kubectl get users`. Human access in EKS works through IAM.

```bash
# Grant a human read-only access (legacy aws-auth method)
eksctl create iamidentitymapping \
  --cluster prod-cluster \
  --arn arn:aws:iam::ACCOUNT_ID:user/alice \
  --group viewers \          # maps to a k8s group bound to a ClusterRole
  --username alice

# Grant via EKS Access Entries (newer API — recommended)
aws eks create-access-entry \
  --cluster-name prod-cluster \
  --principal-arn arn:aws:iam::ACCOUNT_ID:user/alice \
  --type STANDARD

aws eks associate-access-policy \
  --cluster-name prod-cluster \
  --principal-arn arn:aws:iam::ACCOUNT_ID:user/alice \
  --access-scope '{"type":"namespace","namespaces":["ghost-prod"]}' \
  --policy-arn arn:aws:eks::aws:cluster-access-policy/AmazonEKSViewPolicy
```

The IAM principal (user or role) authenticates with `aws eks get-token`, which kubectl uses transparently. The `aws-auth` ConfigMap or EKS Access Entries then maps that IAM identity to a k8s username/group, which RBAC governs from there.

```bash
# kubectl uses this automatically; you can also call it directly
aws eks get-token --cluster-name prod-cluster
```

CI/CD systems use an IAM Role (not user) assumed by the pipeline — bound to a `deployer` Role via RBAC (see `app/11-rbac.yaml`).

---

## If asked in an interview

- Why IRSA instead of node instance profile? → Least privilege at pod granularity. Node profile gives every pod on the node the same AWS access; IRSA scopes it per ServiceAccount. See `CONCEPTS.md` for the full token flow.
- Why Karpenter over Cluster Autoscaler? → Karpenter provisions EC2 directly (not via ASG), selects cheapest instance that fits pod requests, handles spot interruption via SQS. 30–60s to a new node vs 3–5 min with CAS. See `CONCEPTS.md`.
- Why EFS not EBS for Ghost content? → EBS is `ReadWriteOnce` — one node. Multiple Ghost replicas across AZs need `ReadWriteMany`. EFS handles this natively.
- Why ExternalSecrets not k8s Secrets with base64? → k8s Secrets are base64, not encrypted at rest unless you configure envelope encryption with KMS. Secrets Manager has rotation, full audit trail (CloudTrail), and fine-grained IAM scoping.
- How do humans authenticate to EKS? → IAM identity → `aws eks get-token` → aws-auth/Access Entry maps to k8s group → RBAC from there. No k8s-native user accounts.
- What does `concurrencyPolicy: Forbid` on a CronJob do? → Prevents a new Job run from starting if the previous one is still running. Important for backups and migrations that must not overlap.
- What's the difference between a Job and a CronJob? → Job runs once (or N times with backoffLimit). CronJob is a schedule that creates a Job on each trigger.
- When would you use an init container? → When the main container depends on something being ready (DB up, migration run, secret fetched) before it starts. Init containers run sequentially before any app container starts.
- What QoS class gets evicted first under memory pressure? → BestEffort (no requests/limits) → Burstable (requests < limits) → Guaranteed (requests == limits). Set both on all production containers.
- Why ALB target-type: ip? → Bypasses NodePort + kube-proxy hop. Direct pod IP routing = lower latency + required for sticky sessions.
- Why ExternalSecrets not k8s Secrets with base64? → k8s Secrets are base64, not encrypted at rest by default (unless you enable envelope encryption with KMS). Secrets Manager has rotation, audit trail, and cross-account access. ESO is the bridge.
- What does a PDB actually do? → It tells the eviction API "you cannot voluntarily evict this pod if doing so would violate this budget." Karpenter consolidation, node drain, and cluster upgrades all go through the eviction API.
