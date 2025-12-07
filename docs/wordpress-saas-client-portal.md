# WordPress SaaS - Client Portal & Provisioning System

## 🎯 Overview

A client-facing portal for WordPress SaaS that handles:
- Client signup and authentication
- Plan selection and Stripe payment
- DNS configuration instructions
- Site provisioning via Kubernetes controller
- Site status and management

---

## 🏗️ Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              System Architecture                            │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  ┌─────────────────┐       ┌─────────────────┐       ┌─────────────────┐   │
│  │   Client        │       │   Client        │       │   Stripe        │   │
│  │   Browser       │       │   Portal        │       │   (Payments)    │   │
│  │                 │──────▶│   (Phoenix)     │◀─────▶│                 │   │
│  │                 │       │                 │       │   - Checkout    │   │
│  │                 │       │   - Auth        │       │   - Webhooks    │   │
│  │                 │       │   - Dashboard   │       │   - Billing     │   │
│  └─────────────────┘       │   - DNS Guide   │       └─────────────────┘   │
│                            └────────┬────────┘                              │
│                                     │                                       │
│                                     ▼                                       │
│                            ┌─────────────────┐                              │
│                            │   PostgreSQL    │                              │
│                            │                 │                              │
│                            │   - clients     │                              │
│                            │   - sites       │                              │
│                            │   - payments    │                              │
│                            │   - provisions  │                              │
│                            └────────┬────────┘                              │
│                                     │                                       │
│                                     │ LISTEN/NOTIFY                         │
│                                     ▼                                       │
│                            ┌─────────────────┐                              │
│                            │   Provisioner   │                              │
│                            │   Controller    │                              │
│                            │   (Go/Elixir)   │                              │
│                            │                 │                              │
│                            │   - Watches DB  │                              │
│                            │   - Helm deploy │                              │
│                            │   - Status sync │                              │
│                            └────────┬────────┘                              │
│                                     │                                       │
│                                     ▼                                       │
│  ┌──────────────────────────────────────────────────────────────────────┐  │
│  │                          K3s Cluster                                  │  │
│  │                                                                       │  │
│  │   ┌─────────────┐  ┌─────────────┐  ┌─────────────┐                  │  │
│  │   │ client-a    │  │ client-b    │  │ client-c    │  ...             │  │
│  │   │ namespace   │  │ namespace   │  │ namespace   │                  │  │
│  │   │             │  │             │  │             │                  │  │
│  │   │ WP+MariaDB  │  │ WP+MariaDB  │  │ WP+MariaDB  │                  │  │
│  │   │ +Valkey     │  │ +Valkey     │  │ +Valkey     │                  │  │
│  │   └─────────────┘  └─────────────┘  └─────────────┘                  │  │
│  │                                                                       │  │
│  └──────────────────────────────────────────────────────────────────────┘  │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 📊 Database Schema

```sql
-- Clients (users who pay for sites)
CREATE TABLE clients (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    email VARCHAR(255) UNIQUE NOT NULL,
    password_hash VARCHAR(255) NOT NULL,
    stripe_customer_id VARCHAR(255),
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- Sites (WordPress instances)
CREATE TABLE sites (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    client_id UUID REFERENCES clients(id) ON DELETE CASCADE,
    
    -- Identifiers
    name VARCHAR(63) NOT NULL,                    -- e.g., "acme-corp" (K8s namespace)
    subdomain VARCHAR(63) NOT NULL,               -- e.g., "acme-corp" 
    custom_domain VARCHAR(255),                   -- e.g., "www.acmecorp.com" (optional)
    
    -- Plan & billing
    plan VARCHAR(20) NOT NULL DEFAULT 'basic',    -- basic, pro, enterprise
    stripe_subscription_id VARCHAR(255),
    billing_status VARCHAR(20) DEFAULT 'trial',   -- trial, active, past_due, cancelled
    trial_ends_at TIMESTAMPTZ,
    
    -- Provisioning
    provision_status VARCHAR(20) DEFAULT 'pending', -- pending, provisioning, ready, failed, deleting
    provision_error TEXT,
    provisioned_at TIMESTAMPTZ,
    
    -- DNS
    dns_verified BOOLEAN DEFAULT FALSE,
    dns_verified_at TIMESTAMPTZ,
    
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW(),
    
    UNIQUE(name),
    UNIQUE(subdomain)
);

-- Provision queue (for LISTEN/NOTIFY pattern)
CREATE TABLE provision_queue (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    site_id UUID REFERENCES sites(id) ON DELETE CASCADE,
    action VARCHAR(20) NOT NULL,                  -- create, upgrade, delete
    payload JSONB,
    status VARCHAR(20) DEFAULT 'pending',         -- pending, processing, completed, failed
    attempts INT DEFAULT 0,
    last_error TEXT,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    processed_at TIMESTAMPTZ
);

-- Payments history
CREATE TABLE payments (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    client_id UUID REFERENCES clients(id),
    site_id UUID REFERENCES sites(id),
    stripe_payment_intent_id VARCHAR(255),
    amount_cents INT NOT NULL,
    currency VARCHAR(3) DEFAULT 'usd',
    status VARCHAR(20),                           -- succeeded, failed, refunded
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- Trigger to notify on provision queue changes
CREATE OR REPLACE FUNCTION notify_provision_queue()
RETURNS TRIGGER AS $$
BEGIN
    PERFORM pg_notify('provision_queue', json_build_object(
        'id', NEW.id,
        'site_id', NEW.site_id,
        'action', NEW.action
    )::text);
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER provision_queue_notify
    AFTER INSERT ON provision_queue
    FOR EACH ROW
    EXECUTE FUNCTION notify_provision_queue();

-- Index for controller queries
CREATE INDEX idx_provision_queue_pending 
    ON provision_queue(status, created_at) 
    WHERE status = 'pending';
```

---

## 🔄 Provisioning Flow

### 1. New Site Creation

```
┌─────────────────────────────────────────────────────────────────────────┐
│                         New Site Flow                                   │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│  1. Client fills signup form                                            │
│     └── Email, password, site name, plan                               │
│                                                                         │
│  2. Portal creates client + site records (provision_status: pending)   │
│                                                                         │
│  3. Redirect to Stripe Checkout                                        │
│     └── Price based on plan                                            │
│                                                                         │
│  4. Stripe webhook: checkout.session.completed                         │
│     └── Portal updates billing_status: active                          │
│     └── Portal inserts into provision_queue (action: create)           │
│                                                                         │
│  5. PostgreSQL fires NOTIFY 'provision_queue'                          │
│                                                                         │
│  6. Controller receives notification                                    │
│     └── Updates provision_queue status: processing                     │
│     └── Runs: helm install <site-name> ./wordpress-client-chart ...    │
│     └── Waits for deployment ready                                     │
│     └── Updates sites.provision_status: ready                          │
│     └── Updates provision_queue status: completed                      │
│                                                                         │
│  7. Client sees site ready in dashboard                                │
│     └── DNS instructions displayed                                     │
│     └── Site URL clickable                                             │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

### 2. Plan Upgrade

```
Client requests upgrade → Stripe subscription update → 
Webhook fires → provision_queue (action: upgrade) → 
Controller runs helm upgrade with new plan → Done
```

### 3. Site Deletion

```
Client cancels → Stripe subscription cancelled → 
Grace period expires → provision_queue (action: delete) → 
Controller runs helm uninstall + kubectl delete ns → Done
```

---

## 🌐 Client Portal (Go + htmx)

### Tech Stack

| Component | Technology | Rationale |
|-----------|------------|-----------|
| Framework | Echo | Fast, minimal, great middleware |
| Templates | Templ | Type-safe Go templates |
| Frontend | htmx + Alpine.js | Real-time updates without JS complexity |
| Database | PostgreSQL + sqlc | Type-safe queries, LISTEN/NOTIFY |
| Auth | Goth | OAuth2 (Google, GitHub, etc.) |
| Sessions | gorilla/sessions | Secure cookie sessions |
| Payments | Stripe Go SDK | Checkout + webhooks |
| Styling | Tailwind CSS | Utility-first CSS |

### Project Structure

```
wordpress-saas-portal/
├── cmd/
│   ├── portal/main.go          # Web server
│   └── provisioner/main.go     # K8s controller
├── internal/
│   ├── auth/                   # Goth + sessions
│   ├── config/                 # Configuration
│   ├── database/               # sqlc generated + models
│   ├── handlers/               # HTTP handlers
│   ├── provisioner/            # Helm controller logic
│   └── templates/              # Templ components
├── sql/
│   ├── schema.sql              # Database schema
│   └── queries.sql             # sqlc queries
├── static/
│   └── css/
├── Dockerfile                  # Multi-stage (portal + provisioner)
├── sqlc.yaml
└── go.mod
```

### Key Pages

#### 1. New Site Form

```
┌─────────────────────────────────────────────────────┐
│  Create Your WordPress Site                         │
├─────────────────────────────────────────────────────┤
│                                                     │
│  Site Name:  [acme-corp____________]                │
│  (This will be your subdomain)                      │
│                                                     │
│  Your site URL will be:                             │
│  https://acme-corp.clients.yourdomain.com           │
│                                                     │
│  Select Plan:                                       │
│  ┌─────────────┐ ┌─────────────┐ ┌─────────────┐   │
│  │   Basic     │ │    Pro      │ │ Enterprise  │   │
│  │   $19/mo    │ │   $49/mo    │ │   $99/mo    │   │
│  │             │ │             │ │             │   │
│  │ • 1.5 CPU   │ │ • 3 CPU     │ │ • 6 CPU     │   │
│  │ • 1.5GB RAM │ │ • 3GB RAM   │ │ • 6GB RAM   │   │
│  │ • 5GB Files │ │ • 20GB Files│ │ • 50GB Files│   │
│  │ • 2GB DB    │ │ • 5GB DB    │ │ • 10GB DB   │   │
│  │             │ │             │ │             │   │
│  │  [Select]   │ │  [Select]   │ │  [Select]   │   │
│  └─────────────┘ └─────────────┘ └─────────────┘   │
│                                                     │
└─────────────────────────────────────────────────────┘
```

#### 2. DNS Configuration Page

```
┌─────────────────────────────────────────────────────┐
│  DNS Configuration for acme-corp                    │
├─────────────────────────────────────────────────────┤
│                                                     │
│  Your site is ready! 🎉                             │
│                                                     │
│  ─────────────────────────────────────────────────  │
│  Option 1: Use Our Subdomain (Already Working)     │
│  ─────────────────────────────────────────────────  │
│                                                     │
│  Your site is live at:                              │
│  https://acme-corp.clients.yourdomain.com           │
│                                                     │
│  ─────────────────────────────────────────────────  │
│  Option 2: Use Your Own Domain                      │
│  ─────────────────────────────────────────────────  │
│                                                     │
│  To use www.acmecorp.com, add this DNS record:     │
│                                                     │
│  ┌───────────────────────────────────────────────┐ │
│  │  Type:   CNAME                                │ │
│  │  Name:   www                                  │ │
│  │  Value:  ingress.yourdomain.com              │ │
│  │  TTL:    3600 (or Auto)                      │ │
│  └───────────────────────────────────────────────┘ │
│                                                     │
│  Custom Domain: [www.acmecorp.com_______] [Save]   │
│                                                     │
│  Status: ⏳ Waiting for DNS propagation...         │
│          (We check every 5 minutes)                │
│                                                     │
│  [Verify Now]                                       │
│                                                     │
└─────────────────────────────────────────────────────┘
```

#### 3. Dashboard

```
┌─────────────────────────────────────────────────────┐
│  Dashboard                              [New Site]  │
├─────────────────────────────────────────────────────┤
│                                                     │
│  Your Sites                                         │
│                                                     │
│  ┌─────────────────────────────────────────────┐   │
│  │ 🟢 acme-corp                                │   │
│  │    https://acme-corp.clients.yourdomain.com │   │
│  │    Plan: Basic  •  Status: Running          │   │
│  │                                             │   │
│  │    [Open Site] [DNS Settings] [Upgrade]     │   │
│  └─────────────────────────────────────────────┘   │
│                                                     │
│  ┌─────────────────────────────────────────────┐   │
│  │ 🟡 bobs-bakery                              │   │
│  │    Provisioning... (usually takes 2 min)    │   │
│  │    Plan: Pro                                │   │
│  └─────────────────────────────────────────────┘   │
│                                                     │
└─────────────────────────────────────────────────────┘
```

---

## 🤖 Provisioner Controller (Go)

### Architecture

The provisioner is a separate Go binary that:
1. Connects to PostgreSQL and LISTENs on `provision_queue` channel
2. Also polls every 30s for missed notifications
3. Processes jobs: create, upgrade, delete
4. Uses Helm SDK to deploy wordpress-client-chart
5. Updates site status back to database

### Controller Flow

```go
func (c *Controller) Run(ctx context.Context) error {
    // Connect and LISTEN
    conn.Exec(ctx, "LISTEN provision_queue")
    
    for {
        select {
        case <-ctx.Done():
            return nil
        case notification := <-conn.WaitForNotification(ctx):
            c.processPendingJobs(ctx)
        case <-ticker.C: // every 30s
            c.processPendingJobs(ctx)
        }
    }
}

func (c *Controller) processPendingJobs(ctx context.Context) {
    jobs := queries.GetPendingProvisionJobs(ctx, 10)
    for _, job := range jobs {
        switch job.Action {
        case "create":
            c.helmInstall(job.SiteName, vals)
            c.waitForDeployment(ctx, job.SiteName)
        case "upgrade":
            c.helmUpgrade(job.SiteName, vals)
        case "delete":
            c.helmUninstall(job.SiteName)
            c.deleteNamespace(ctx, job.SiteName)
        }
    }
}
```

---

## 💳 Stripe Integration

### Products & Prices

```javascript
// Create these in Stripe Dashboard or via API
const products = {
  basic: {
    name: "WordPress Basic",
    price: 1900, // $19.00
    interval: "month"
  },
  pro: {
    name: "WordPress Pro", 
    price: 4900, // $49.00
    interval: "month"
  },
  enterprise: {
    name: "WordPress Enterprise",
    price: 9900, // $99.00
    interval: "month"
  }
};
```

### Webhook Events to Handle

| Event | Action |
|-------|--------|
| `checkout.session.completed` | Create site, start provisioning |
| `invoice.paid` | Ensure billing_status = active |
| `invoice.payment_failed` | Set billing_status = past_due, email client |
| `customer.subscription.updated` | Handle plan changes |
| `customer.subscription.deleted` | Queue site for deletion (with grace period) |

### Stripe Webhook Handler (Go)

```go
func (h *Handler) StripeWebhook(c echo.Context) error {
    body, _ := io.ReadAll(c.Request().Body)
    signature := c.Request().Header.Get("Stripe-Signature")
    
    event, err := webhook.ConstructEvent(body, signature, h.config.StripeWebhookSecret)
    if err != nil {
        return c.String(http.StatusBadRequest, "Invalid signature")
    }
    
    switch event.Type {
    case "checkout.session.completed":
        var session stripe.CheckoutSession
        json.Unmarshal(event.Data.Raw, &session)
        
        siteID := session.Metadata["site_id"]
        
        // Update billing status
        queries.UpdateSiteBillingStatus(ctx, siteID, "active", session.Subscription.ID)
        
        // Queue for provisioning - this triggers NOTIFY
        queries.CreateProvisionJob(ctx, siteID, "create", payload)
        
    case "customer.subscription.deleted":
        // Queue site for deletion
        queries.CreateProvisionJob(ctx, siteID, "delete", payload)
    }
    
    return c.String(http.StatusOK, "ok")
}
```

---

## 🔒 Security Considerations

| Concern | Solution |
|---------|----------|
| Stripe webhook verification | Verify signature header |
| Controller DB access | Separate DB user with limited permissions |
| Helm execution | Controller runs in-cluster with RBAC |
| Client data isolation | Each site in own namespace, NetworkPolicy |
| Portal auth | bcrypt passwords, secure sessions |
| Admin access | Separate admin routes with MFA |

---

## 📁 Project Structure

```
wordpress-saas-portal/
├── cmd/
│   ├── portal/main.go          # Web server entry point
│   └── provisioner/main.go     # Controller entry point
├── internal/
│   ├── auth/
│   │   ├── providers.go        # Goth OAuth setup
│   │   └── session.go          # Session helpers
│   ├── config/
│   │   └── config.go           # Environment config
│   ├── database/
│   │   ├── database.go         # Connection pool
│   │   ├── models.go           # Data models
│   │   └── queries.sql.go      # sqlc generated
│   ├── handlers/
│   │   ├── handlers.go         # Base handler + middleware
│   │   ├── auth.go             # OAuth handlers
│   │   ├── pages.go            # Home, pricing, dashboard
│   │   ├── sites.go            # Site CRUD + htmx partials
│   │   └── stripe.go           # Webhook + billing portal
│   ├── provisioner/
│   │   └── controller.go       # Helm deploy logic
│   └── templates/
│       ├── layout.templ        # Base layout + nav
│       ├── auth.templ          # Login page
│       ├── pages.templ         # Home, pricing
│       ├── dashboard.templ     # Dashboard + site list
│       └── sites.templ         # Site forms + DNS config
├── sql/
│   ├── schema.sql              # Full database schema
│   └── queries.sql             # sqlc query definitions
├── static/
│   └── css/tailwind.css
├── Dockerfile                  # Multi-stage build
├── sqlc.yaml                   # sqlc config
├── .env.example                # Environment template
└── go.mod
```

---

## 🚀 MVP Checklist

### Phase 1: Database & Core Portal
- [ ] PostgreSQL schema migration
- [ ] Phoenix project setup
- [ ] Client authentication (signup/login)
- [ ] Site creation form (no payment yet)
- [ ] Dashboard with site list

### Phase 2: Stripe Integration
- [ ] Stripe products/prices created
- [ ] Checkout flow
- [ ] Webhook handler
- [ ] Billing status tracking

### Phase 3: Provisioner Controller
- [ ] Go project setup
- [ ] PostgreSQL LISTEN/NOTIFY
- [ ] Helm SDK integration
- [ ] Create/upgrade/delete actions
- [ ] Status sync back to DB

### Phase 4: DNS & Polish
- [ ] DNS verification checker
- [ ] Custom domain support in ingress
- [ ] Email notifications
- [ ] Error handling & retries

### Phase 5: Production
- [ ] Controller Dockerfile & deployment
- [ ] Portal Dockerfile & deployment
- [ ] Monitoring & alerting
- [ ] Backup strategy

---

## ❓ Open Questions

1. **Trial period?** - Free trial before requiring payment?
2. **Refunds?** - Automatic or manual?
3. **Site suspension?** - What happens on payment failure? Grace period?
4. **Admin panel?** - Separate admin UI or just Rancher?
5. **Email provider?** - Postmark? SendGrid? Self-hosted?

---

_Document created: December 5, 2025_
_Status: Implementation Started - Go + htmx stack_
_Code: `/home/jqwop/gitlab/wordpress-saas-portal/`_
