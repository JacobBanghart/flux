# WordPress SaaS Platform - Business Process Design

## 🎯 Core Concept

**One-click WordPress deployment for clients, managed via Rancher UI on mobile.**

> **Architecture**: Per-client isolated pods with MariaDB + Valkey sidecars. No shared database.

---

## 📋 Business Flow

```
┌─────────────────────────────────────────────────────────────────────────┐
│                           CUSTOMER JOURNEY                              │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│  1. CLIENT SIGNS UP                                                     │
│     └── Payment processed (Stripe? PayPal? Invoice?)                   │
│     └── Client provides: business name, desired subdomain              │
│                                                                         │
│  2. YOU DEPLOY (Mobile - Rancher UI)                                   │
│     └── Open Rancher on phone                                          │
│     └── Click "Deploy WordPress" (Rancher Catalog App or Fleet)        │
│     └── Enter namespace (client-name)                                  │
│     └── Click deploy                                                    │
│                                                                         │
│  3. AUTOMATIC PROVISIONING                                              │
│     └── Namespace created with ResourceQuota + LimitRange              │
│     └── Pod deployed (WordPress + MariaDB + Valkey sidecars)           │
│     └── MariaDB database initialized (isolated per client)             │
│     └── NetworkPolicy applied (isolates namespace)                     │
│     └── TLS certificate issued                                         │
│     └── DNS record created                                              │
│     └── Client notified (email?)                                       │
│                                                                         │
│  4. CLIENT USES WORDPRESS                                               │
│     └── Accesses: https://clientname.yourplatform.com                  │
│     └── OR: https://theirdomain.com (custom domain later)             │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## 🏗️ Technical Architecture

```
┌─────────────────────────────────────────────────────────────────────────┐
│                           K3s Cluster                                   │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│  ┌───────────────────────────────┐   ┌───────────────────────────────┐ │
│  │     client-a namespace        │   │     client-b namespace        │ │
│  │  ┌─────────────────────────┐  │   │  ┌─────────────────────────┐  │ │
│  │  │      WordPress Pod      │  │   │  │      WordPress Pod      │  │ │
│  │  │ ┌─────────────────────┐ │  │   │  │ ┌─────────────────────┐ │  │ │
│  │  │ │ WordPress  :80      │ │  │   │  │ │ WordPress  :80      │ │  │ │
│  │  │ ├─────────────────────┤ │  │   │  │ ├─────────────────────┤ │  │ │
│  │  │ │ MariaDB    :3306    │ │  │   │  │ │ MariaDB    :3306    │ │  │ │
│  │  │ ├─────────────────────┤ │  │   │  │ ├─────────────────────┤ │  │ │
│  │  │ │ Valkey     :6379    │ │  │   │  │ │ Valkey     :6379    │ │  │ │
│  │  │ └─────────────────────┘ │  │   │  │ └─────────────────────┘ │  │ │
│  │  └─────────────────────────┘  │   │  └─────────────────────────┘  │ │
│  │  ResourceQuota + LimitRange   │   │  ResourceQuota + LimitRange   │ │
│  │  NetworkPolicy (isolated)     │   │  NetworkPolicy (isolated)     │ │
│  │  PVCs: wp-content + mysql     │   │  PVCs: wp-content + mysql     │ │
│  └───────────────────────────────┘   └───────────────────────────────┘ │
│                                                                         │
│  ┌─────────────────────────────────────────────────────────────────┐   │
│  │                    Shared Infrastructure                         │   │
│  │  Traefik (ingress + TLS)  │  External-DNS  │  NFS StorageClass  │   │
│  └─────────────────────────────────────────────────────────────────┘   │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

### Key Design Decisions

| Decision             | Choice                    | Rationale                              |
| -------------------- | ------------------------- | -------------------------------------- |
| Database             | MariaDB sidecar           | Per-client isolation, easy backup      |
| Cache                | Valkey sidecar            | Localhost, no network exposure         |
| Pod architecture     | 3 containers per pod      | Shared lifecycle, simple networking    |
| Storage              | NFS (nfs-rwx class)       | RWX for wp-content, RWO for MySQL      |
| Resource control     | ResourceQuota + LimitRange| Plan-based limits per namespace        |

---

## 🔐 Security Requirements

| Traffic Path         | Encryption                   | How                        |
| -------------------- | ---------------------------- | -------------------------- |
| User → Traefik       | TLS 1.3                      | Let's Encrypt / Cloudflare |
| Traefik → WordPress  | Plaintext (cluster internal) | OR mTLS via service mesh   |
| WordPress → MariaDB  | Localhost (same pod)         | 127.0.0.1:3306, no network |
| WordPress → Valkey   | Localhost (same pod)         | No network exposure        |

| Concern              | Solution                                |
| -------------------- | --------------------------------------- |
| Client isolation     | Separate namespaces + ResourceQuota     |
| Network isolation    | NetworkPolicy (deny ingress by default) |
| Database access      | MariaDB sidecar (localhost only)        |
| Secrets              | Kubernetes Secrets with lookup pattern  |
| Resource limits      | LimitRange enforces per-container caps  |

### Why Per-Client MariaDB Sidecars?

Instead of a shared MySQL instance, each client gets their own MariaDB container as a sidecar:

| Benefit              | Explanation                                           |
| -------------------- | ----------------------------------------------------- |
| Complete isolation   | No accidental data leakage between clients            |
| Simple backups       | `kubectl exec` + `mariadb-dump` per namespace         |
| Easy restoration     | Restore a single client without affecting others      |
| No TLS complexity    | Database is localhost-only, no network exposure       |
| Resource accounting  | Database resources counted in client's ResourceQuota  |
| Simpler RBAC         | No cross-namespace access to shared DB credentials    |

```bash
# Backup a client's database
kubectl exec -n acme-corp deployment/wordpress -c mariadb -- \
  mariadb-dump -u root -p$PASSWORD wordpress > acme-corp-backup.sql

# Restore
kubectl exec -i -n acme-corp deployment/wordpress -c mariadb -- \
  mariadb -u root -p$PASSWORD wordpress < acme-corp-backup.sql
```

### Valkey as Sidecar (No Network Exposure)

```yaml
# Valkey runs in same pod as WordPress
# Communication is localhost:6379
# Never exposed outside the pod
# No encryption needed (same pod = same network namespace)
```

---

## 🎮 Rancher UI Deployment Options

### Option 1: Rancher Apps (Helm Catalog)

- Add custom Helm chart to Rancher catalog
- Shows up in Apps → Charts
- Fill in form (namespace, domain) → Deploy
- **Pros**: Native UI, form-based
- **Cons**: Need to build/maintain chart

### Option 2: Fleet (GitOps)

- Template in Git repo
- Rancher Fleet deploys from Git
- Create new folder/values for each client
- **Pros**: GitOps, auditable
- **Cons**: Not quite "one click" on mobile

### Option 3: Rancher Continuous Delivery + Script

- Simple script that Fleet picks up
- Trigger via webhook or manual
- **Pros**: Flexible
- **Cons**: More moving parts

### Recommendation for MVP: **Option 1 - Custom Helm Chart in Rancher Catalog**

---

## 📱 Mobile Workflow (Rancher UI)

```
┌─────────────────────────────────────────────────────────────────┐
│                     RANCHER MOBILE UI                           │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  1. Open Rancher (https://rancher.yourdomain.com)              │
│                                                                 │
│  2. Navigate: Apps → Charts → "WordPress Client"               │
│                                                                 │
│  3. Fill form:                                                  │
│     ┌─────────────────────────────────────────────────────┐    │
│     │  Namespace:    [acme-corp___________]               │    │
│     │  Subdomain:    [acme-corp___________].platform.com  │    │
│     │  Client Email: [client@example.com__]               │    │
│     │  Plan:         [● Basic  ○ Pro  ○ Enterprise]       │    │
│     │                                                      │    │
│     │            [ Deploy WordPress ]                      │    │
│     └─────────────────────────────────────────────────────┘    │
│                                                                 │
│  4. Watch deployment (optional)                                │
│                                                                 │
│  5. Done - client site live in ~60 seconds                     │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

---

## 💰 Billing Integration (Future)

### Options:

1. **Manual** - Invoice clients, deploy when paid
2. **Stripe Checkout** - Client pays, webhook triggers deploy
3. **WHMCS** - Full billing platform, integrates with hosting
4. **Blesta** - Similar to WHMCS
5. **Lago** - Open-source usage-based billing

### MVP: Start manual, add Stripe webhook later

---

## 📊 Resource Limits per Client

Each plan defines total namespace limits. The chart applies ResourceQuota + LimitRange.

| Plan       | CPU Limit | Memory Limit | WP Storage | DB Storage |
| ---------- | --------- | ------------ | ---------- | ---------- |
| basic      | 1.5 cores | 1.5 Gi       | 5 Gi       | 2 Gi       |
| pro        | 3 cores   | 3 Gi         | 20 Gi      | 5 Gi       |
| enterprise | 6 cores   | 6 Gi         | 50 Gi      | 10 Gi      |

```yaml
# ResourceQuota + LimitRange per namespace
apiVersion: v1
kind: ResourceQuota
metadata:
  name: client-quota
spec:
  hard:
    requests.cpu: "{{ .planResources.requests.cpu }}"
    requests.memory: "{{ .planResources.requests.memory }}"
    limits.cpu: "{{ .planResources.limits.cpu }}"
    limits.memory: "{{ .planResources.limits.memory }}"
    persistentvolumeclaims: "2"
---
apiVersion: v1
kind: LimitRange
metadata:
  name: client-limits
spec:
  limits:
    - default:
        cpu: "{{ divide .planResources.limits.cpu by 3 }}"
        memory: "{{ divide .planResources.limits.memory by 3 }}"
      type: Container
```

---

## 🗄️ MariaDB Sidecar Architecture (Implemented)

```
┌─────────────────────────────────────────────────────────────────────────┐
│                          Per-Client Pod                                 │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│  Single Pod with 3 Containers:                                          │
│  ┌─────────────────────────────────────────────────────────────────┐   │
│  │                                                                   │   │
│  │  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐              │   │
│  │  │  WordPress  │  │   MariaDB   │  │   Valkey    │              │   │
│  │  │   :80       │  │   :3306     │  │   :6379     │              │   │
│  │  │             │  │             │  │             │              │   │
│  │  │ connects to │  │ localhost   │  │ localhost   │              │   │
│  │  │ 127.0.0.1   │  │ only        │  │ only        │              │   │
│  │  └─────────────┘  └─────────────┘  └─────────────┘              │   │
│  │                                                                   │   │
│  │  Shared volumes:                                                 │   │
│  │  ├── wp-content PVC (RWX) → /var/www/html/wp-content            │   │
│  │  └── mysql-data PVC (RWO) → /var/lib/mysql                      │   │
│  │                                                                   │   │
│  └─────────────────────────────────────────────────────────────────┘   │
│                                                                         │
│  Benefits:                                                              │
│  ├── No network exposure for MariaDB                                   │
│  ├── No TLS complexity (localhost communication)                       │
│  ├── Easy per-client backup with mariadb-dump                         │
│  └── Database lifecycle tied to WordPress (shared pod)                │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## 🚀 MVP Checklist

### Infrastructure

- [x] ~~MySQL (simple StatefulSet with TLS)~~ → MariaDB sidecar (per-client)
- [x] External-DNS handles DNS automatically ✅
- [x] Traefik handles TLS automatically ✅
- [x] Rancher installed ✅

### Helm Chart: `wordpress-client-chart` ✅

- [x] WordPress container
- [x] MariaDB sidecar container (per-client, localhost)
- [x] Valkey sidecar container
- [x] Ingress with dynamic hostname (external-dns picks it up)
- [x] Secret for DB credentials (with lookup pattern for upgrades)
- [x] PVCs for wp-content and mysql-data
- [x] ResourceQuota + LimitRange per plan
- [x] NetworkPolicy for namespace isolation
- [x] Init container for NFS permission fixes

### Rancher Setup

- [ ] Point Rancher to Helm chart Git repo
- [ ] Test deployment on mobile

### Nice to Have (Later)

- [ ] Stripe webhook for auto-deploy
- [ ] Client portal (view their site status)
- [ ] Auto-backup per client (script exists, needs cron)
- [ ] Custom domain support
- [ ] Email notifications on deploy

---

## ❓ Open Questions

1. **Pricing Model**: Per site/month? Usage-based? Tiered?

2. ~~**Target Market**~~: ✅ Clients will find you. Not worried about marketing.

3. **SLA/Uptime**: What uptime do you promise?

4. **Backup Strategy**: How often? Client-accessible?

5. **Support Model**: Tickets? Email? Chat?

6. **Scaling**: What if a client goes viral? Auto-scale?

7. **WordPress Updates**: Who handles them? Auto-update?

8. **Plugin Restrictions**: Allow any plugin? Whitelist?

---

## 🔄 Next Steps

1. ~~Define target market and pricing~~ Clients will come
2. ~~Deploy MySQL cluster~~ → Using MariaDB sidecars instead
3. ~~Build `wordpress-client` Helm chart~~ ✅ Done
4. Add chart to Rancher catalog ← **Next**
5. Test full flow on mobile
6. Onboard first client

---

## 📦 Helm Chart Structure

```
wordpress-client-chart/
├── Chart.yaml
├── README.md
├── values.yaml                 # Plan tiers, container configs
├── templates/
│   ├── _helpers.tpl            # Template helpers (labels, names)
│   ├── deployment.yaml         # WordPress + MariaDB + Valkey (3 containers)
│   ├── service.yaml            # ClusterIP for WordPress
│   ├── ingress.yaml            # Traefik ingress (triggers external-dns)
│   ├── pvc.yaml                # wp-content (RWX) + mysql-data (RWO)
│   ├── secret.yaml             # MariaDB creds (auto-generated, preserved on upgrade)
│   ├── resourcequota.yaml      # Namespace quota + LimitRange per plan
│   ├── networkpolicy.yaml      # Deny ingress, allow Traefik + external egress
│   └── NOTES.txt               # Post-install instructions
```

### Key Templates

**values.yaml** (what you fill in on Rancher):

```yaml
# Client-specific (REQUIRED)
clientName: ""    # e.g., "acme-corp"
clientDomain: ""  # e.g., "acme-corp.clients.yourdomain.com"
clientEmail: ""   # For notifications (future)

# Plan selection (basic, pro, enterprise)
plan: "basic"

# Plan-based resource tiers (TOTAL namespace limits)
plans:
  basic:
    limits:
      cpu: "1500m"
      memory: "1536Mi"
    wpStorage: "5Gi"
    dbStorage: "2Gi"
  pro:
    limits:
      cpu: "3000m"
      memory: "3Gi"
    wpStorage: "20Gi"
    dbStorage: "5Gi"
  enterprise:
    limits:
      cpu: "6000m"
      memory: "6Gi"
    wpStorage: "50Gi"
    dbStorage: "10Gi"

# Container images
wordpress:
  image:
    repository: wordpress
    tag: "6.7-php8.3-apache"
mariadb:
  image:
    repository: mariadb
    tag: "11.4"
valkey:
  image:
    repository: valkey/valkey
    tag: "8.0"
```

**deployment.yaml** (WordPress + MariaDB + Valkey in single pod):

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: wordpress
spec:
  replicas: 1
  strategy:
    type: Recreate  # Required for RWO MySQL PVC
  template:
    spec:
      # Fix NFS permissions
      initContainers:
        - name: fix-permissions
          image: busybox:1.36
          command: ["sh", "-c", "chmod -R 777 /var/www/html/wp-content && chown -R 999:999 /var/lib/mysql"]
          volumeMounts:
            - name: wp-content
              mountPath: /var/www/html/wp-content
            - name: mysql-data
              mountPath: /var/lib/mysql

      containers:
        # WordPress
        - name: wordpress
          image: wordpress:6.7-php8.3-apache
          ports:
            - containerPort: 80
          env:
            - name: WORDPRESS_DB_HOST
              value: "127.0.0.1:3306"  # MariaDB sidecar
            - name: WORDPRESS_DB_NAME
              value: wordpress
            - name: WORDPRESS_DB_USER
              value: wordpress
            - name: WORDPRESS_DB_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: wordpress-db-credentials
                  key: password
            - name: WORDPRESS_CONFIG_EXTRA
              value: |
                define('WP_REDIS_HOST', '127.0.0.1');
                define('WP_REDIS_PORT', 6379);

        # MariaDB sidecar (per-client, localhost only)
        - name: mariadb
          image: mariadb:11.4
          ports:
            - containerPort: 3306
          env:
            - name: MARIADB_DATABASE
              value: wordpress
            - name: MARIADB_USER
              value: wordpress
            - name: MARIADB_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: wordpress-db-credentials
                  key: password
            - name: MARIADB_ROOT_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: wordpress-db-credentials
                  key: root-password
          volumeMounts:
            - name: mysql-data
              mountPath: /var/lib/mysql

        # Valkey sidecar (Redis cache)
        - name: valkey
          image: valkey/valkey:8.0
          ports:
            - containerPort: 6379

      volumes:
        - name: wp-content
          persistentVolumeClaim:
            claimName: wordpress-content
        - name: mysql-data
          persistentVolumeClaim:
            claimName: wordpress-mysql
```

### Deploy Command

```bash
# Deploy a new client
helm install acme-corp ./wordpress-client-chart \
  --namespace acme-corp \
  --create-namespace \
  --set clientName=acme-corp \
  --set clientDomain=acme-corp.clients.yourdomain.com \
  --set plan=basic

# Upgrade (passwords are preserved)
helm upgrade acme-corp ./wordpress-client-chart \
  --namespace acme-corp \
  --set clientName=acme-corp \
  --set clientDomain=acme-corp.clients.yourdomain.com \
  --set plan=pro  # Upgrade to pro plan

# Backup client database
kubectl exec -n acme-corp deployment/wordpress -c mariadb -- \
  mariadb-dump -u root -p$(kubectl get secret -n acme-corp wordpress-db-credentials -o jsonpath='{.data.root-password}' | base64 -d) \
  wordpress > acme-corp-backup.sql
```

---

_Document created: November 30, 2025_
_Last updated: Architecture refactored to per-client MariaDB sidecars_
_Status: MVP Complete - Ready for Rancher catalog integration_
