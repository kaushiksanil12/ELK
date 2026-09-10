# Elastic Stack (ELK) — Self-Hosted Production Setup & Runbook

> **Stack:** Elasticsearch · Kibana · Fleet Server · Nginx (SSL) · Certbot  
> **Version:** 9.x (configured via `.env`, default `9.5.0`)  
> **Deployment:** Docker Compose (single-node)  
> **Agents:** Elastic Agent on remote servers, managed via Fleet  
> **Backups:** Automated daily snapshots to AWS S3 with Snapshot Lifecycle Management (SLM)

---

## Table of Contents

1. [Architecture Overview](#1-architecture-overview)
2. [Prerequisites & Firewall Ports](#2-prerequisites--firewall-ports)
3. [Project Structure](#3-project-structure)
4. [Configuration — `.env` Reference](#4-configuration----env-reference)
5. [Step-by-Step Deployment on a Fresh Server](#5-step-by-step-deployment-on-a-fresh-server)
6. [Setting Up Fleet Server](#6-setting-up-fleet-server)
7. [Installing Elastic Agent on Remote Servers](#7-installing-elastic-agent-on-remote-servers)
8. [Decoupled Updates: Changing Retention & Settings Live](#8-decoupled-updates-changing-retention--settings-live)
9. [AWS S3 Backups & Restoring Snapshots](#9-aws-s3-backups--restoring-snapshots)
10. [Managing the Stack](#10-managing-the-stack)
11. [Security Notes & TLS](#11-security-notes--tls)
12. [Resource Limits Explained](#12-resource-limits-explained)
13. [Production Quirks, Gotchas & Debugging Runbook](#13-production-quirks-gotchas--debugging-runbook)
14. [Troubleshooting & Handy API Commands](#14-troubleshooting--handy-api-commands)
15. [Under the Hood: Script Reference](#15-under-the-hood-script-reference)

---

## 1. Architecture Overview

```
┌──────────────────────────────────────────────────────────┐
│                  ELK SERVER (Docker Compose)              │
│                                                          │
│  ┌───────────────────────────────────────────────────┐   │
│  │                    NGINX (SSL Proxy)               │   │
│  │   :80  :443  :9200  :8220  :8200                  │   │
│  └───┬───────────┬──────────┬──────────┬─────────────┘   │
│      │           │          │          │                 │
│  ┌───▼───┐  ┌────▼───┐  ┌──▼──────┐  └──────────────┐   │
│  │Kibana │  │  ES    │  │ Fleet   │   Certbot (TLS) │   │
│  │:5601  │  │ :9200  │  │ Server  │                 │   │
│  └───────┘  └────────┘  │  :8220  │                 │   │
│                          │  :8200  │                 │   │
│                          └─────────┘                 │   │
└──────────────────────────────────────────────────────────┘
                         │ HTTPS (port 8220)
          ┌──────────────┼──────────────┐
          ▼              ▼              ▼
   ┌─────────────┐ ┌─────────────┐ ┌─────────────┐
   │ App Server  │ │  Web Server │ │  DB Server  │
   │Elastic Agent│ │Elastic Agent│ │Elastic Agent│
   └─────────────┘ └─────────────┘ └─────────────┘
```

**Key design decisions:**

- **No Logstash overhead** — Elastic Agent ships logs and metrics directly to Elasticsearch. Transformations and JSON decodes are performed by Elasticsearch Ingest Pipelines, which are faster, lightweight, and managed via Kibana.
- **Elastic Agent runs on monitored servers** — Not on the ELK server itself. Client servers communicate back to Fleet Server over HTTPS (port `8220`).
- **Fleet Server** — Centralized control plane in Kibana that manages agent policies, auto-updates integrations, and tracks agent health.
- **Automated S3 Backups & Lean Local Storage** — Local storage retains 7 days of logs (`ILM_DELETE_AFTER=7d`) for live querying and dashboards, while AWS S3 stores 30 days of daily snapshots cheaply. Snapshots can be restored on demand in minutes.
- **Dual-Layer TLS** — Nginx terminates public HTTPS with Let's Encrypt certificates (or self-signed if IP-only), while Elasticsearch, Kibana, and Fleet Server communicate over internal self-signed TLS.

---

## 2. Prerequisites & Firewall Ports

### ELK Server Requirements

| Requirement | Minimum | Recommended |
|---|---|---|
| CPU | 2 cores | 4+ cores |
| RAM | 4 GB | 8 GB+ |
| Disk | 30 GB SSD | 100 GB+ NVMe / GP3 |
| OS | Ubuntu 20.04/22.04/24.04, Debian 11/12, RHEL 8/9, Amazon Linux 2023 | Ubuntu 24.04 LTS |

### Required Inbound Firewall Ports (AWS Security Group)

| Port | Protocol | Service | Purpose |
|---|---|---|---|
| `80` | TCP | HTTP | Let's Encrypt ACME verification & redirect to 443 |
| `443` | TCP | HTTPS | Kibana Web UI |
| `9200` | TCP | Elasticsearch | External API ingestion / remote queries (via Nginx SSL) |
| `8220` | TCP | Fleet Server | Remote Elastic Agents connect here to receive policies |
| `8200` | TCP | APM Server | Application Performance Monitoring traces (optional) |

> ⚠️ **Never expose port `9300`** publicly. It is used exclusively for internal Elasticsearch node-to-node transport.

### Remote Servers (for Elastic Agent)
- **RAM**: ~256 MB free
- **OS**: Linux (Debian, Ubuntu, RHEL, CentOS, Amazon Linux), macOS
- **Network**: Outbound access to the ELK server on port `8220` and `9200`

---

## 3. Project Structure

```text
elk/
├── .env                         ← Cluster & secret configuration (git-ignored)
├── .env.example                 ← Template with production defaults
├── docker-compose.yml           ← Elasticsearch, Kibana, Nginx, Certbot services
├── README.md                    ← Full architectural and operational documentation
├── .gitignore                   ← Excludes .env and auto-generated runtime certs
│
├── scripts/                     ← 📁 Operational & Lifecycle Scripts
│   ├── 01-prepare-server.sh     ← Step 1: Run ONCE on fresh Linux server (Docker, kernel tuning, .env)
│   ├── 02-start-elk.sh          ← Step 2: Starts/stops core ELK stack & Nginx SSL proxy
│   ├── 03-start-fleet.sh        ← Step 3: Starts Fleet Server container (run after Kibana is ready)
│   ├── 04-setup-s3-backup.sh    ← Step 4: Registers AWS S3 repository & 30d daily SLM policy
│   ├── update-policies.sh       ← Maintenance: Fast live update of ILM & templates in ~1s (no restarts!)
│   └── install-agent.sh         ← Remote: Run on client servers to ship logs/metrics to Fleet
│
└── nginx/
    └── templates/               ← Nginx reverse proxy templates (dynamic SSL setup)
        ├── kibana-domain.conf.tmpl  ← Let's Encrypt domain SSL config
        └── kibana-ip.conf.tmpl      ← Self-signed IP SSL config (default)
```

> 💡 **Auto-Created Runtime Directories:** Folders like `letsencrypt/` and `certbot-www/` are git-ignored and automatically created at runtime with proper permissions when running `01-prepare-server.sh` or `02-start-elk.sh`.

---

## 4. Configuration — `.env` Reference

Copy `.env.example` to `.env` (or let `01-prepare-server.sh` generate it with random secure passwords):

```bash
cp .env.example .env
nano .env
```

### 4.1 Cluster & Security

| Variable | Default | Description |
|---|---|---|
| `STACK_VERSION` | `9.5.0` | Elastic Stack version. Must match across all containers and agents. |
| `CLUSTER_NAME` | `elk-cluster` | Name of the Elasticsearch cluster. |
| `ELASTIC_PASSWORD` | *(random)* | Password for the built-in `elastic` superuser. |
| `KIBANA_SYSTEM_PASSWORD` | *(random)* | Password for internal `kibana_system` service user. |
| `KIBANA_ENCRYPTION_KEY` | *(32+ chars)* | Encrypts saved objects and sessions in Kibana. |
| `KIBANA_REPORTING_ENCRYPT_KEY` | *(32+ chars)* | Encrypts generated reports in Kibana. |

### 4.2 Network & TLS SANs

| Variable | Example | Description |
|---|---|---|
| `ES_PORT` | `9200` | Elasticsearch HTTPS API port |
| `KIBANA_PORT` | `5601` | Internal Kibana port (proxied via Nginx 443) |
| `FLEET_SERVER_PORT` | `8220` | Fleet Server port |
| `ELK_SERVER_PUBLIC_IP` | `13.60.236.39` | Public IP of your ELK host (baked into TLS certs as SAN) |
| `ELK_SERVER_DOMAIN` | `elk.mycompany.com` | Domain pointing to this server (triggers Let's Encrypt) |

### 4.3 Memory & Limits

| Variable | Default | Description |
|---|---|---|
| `ES_JVM_HEAP` | `1g` (or `3g`) | Set to ~50% of available RAM (e.g. `3g` on an 8GB machine). |
| `ES_MEM_LIMIT` | `2g` (or `6g`) | Docker memory limit for Elasticsearch container. |
| `KIBANA_MEM_LIMIT` | `1g` | Docker memory limit for Kibana container. |
| `FLEET_MEM_LIMIT` | `512m` | Docker memory limit for Fleet Server container. |

### 4.4 Ingestion & ILM Retention (Lean S3 Hybrid)

| Variable | Value | Description |
|---|---|---|
| `ILM_ROLLOVER_MAX_AGE` | `1d` | Rolls active index daily to keep shard sizes manageable. |
| `ILM_ROLLOVER_MAX_SHARD_SIZE` | `10gb` | Rolls index earlier if a shard hits 10 GB. |
| `ILM_DELETE_AFTER` | `7d` | **Local Retention:** Purges local indices after 7 days (S3 holds 30d snapshots). |
| `ES_REFRESH_INTERVAL` | `5s` | Documents become searchable every 5 seconds for fast live debugging. |
| `ES_DYNAMIC_MAPPING` | `true` | Auto-detects new JSON fields so application logs are **never rejected**. |
| `ES_MAPPING_TOTAL_FIELDS_LIMIT` | `2000` | Supports high field counts (ECS + custom app logs). |

---

## 5. Step-by-Step Deployment on a Fresh Server

### Step 1 — Prepare the Host Machine
Run the preparation script on a clean Linux server:
```bash
sudo ./scripts/01-prepare-server.sh
```
This script automatically:
1. Installs Docker Engine and the Docker Compose plugin (v2).
2. Creates the `docker` group, adds your non-root user (e.g. `ubuntu`), and fixes Docker socket permissions so `sudo` is never needed for running containers.
3. Allocates and enables a **4GB swapfile** with `vm.swappiness=1` (vital emergency OOM protection for cloud VPS instances).
4. Configures and persists `vm.max_map_count=262144` and security limits in `/etc/sysctl.d/99-elk.conf`.
5. Installs `curl`, `openssl`, `jq`, and `unzip`.
6. Generates a secure `.env` file with strong, 32-character random passwords if none exists and transfers ownership to your non-root user.

### Step 2 — Review Configuration
Inspect and customize `.env` (ensure IP or domain is set):
```bash
nano .env
```

### Step 3 — Start the ELK Stack
Launch the core containers:
```bash
./scripts/02-start-elk.sh
```
This script will:
1. Provision SSL certificates (via Let's Encrypt for domains or self-signed for IPs).
2. Start Elasticsearch, Kibana, Nginx, and Certbot.
3. Wait for Elasticsearch and Kibana health checks to turn green/available.
4. Apply cluster settings, ILM policies, and index templates.

### Step 4 — Log into Kibana
Open in your browser:
* **With Domain:** `https://elk.mycompany.com`
* **With IP:** `https://<YOUR_ELK_SERVER_IP>`

Login credentials:
* **Username:** `elastic`
* **Password:** *(value of `ELASTIC_PASSWORD` in `.env`)*

---

## 6. Setting Up Fleet Server

Fleet Server connects to Kibana and Elasticsearch to manage all remote agents.

### Step 1 — Generate a Fleet Server Token in Kibana
1. Open Kibana → **Management → Fleet**.
2. Click **"Add Fleet Server"**.
3. Create a policy:
   * **Name**: `Fleet Server Policy`
   * **Policy ID**: `fleet-server-policy`
4. Click **"Generate Fleet Server policy"** and copy the **Service Token**.

### Step 2 — Launch Fleet Server
Run the startup script:
```bash
./scripts/03-start-fleet.sh
```
Paste the token when prompted. The script connects Fleet Server to the internal Docker network and registers it with Kibana.

### Step 3 — Update Fleet Output Host (Crucial)
By default, Kibana sets the Elasticsearch output to `https://elasticsearch:9200`, which remote agents cannot reach.
1. In Kibana, go to **Management → Fleet → Settings**.
2. Under **Outputs**, click the edit icon for `default`.
3. Change **Hosts** to your public URL:
   ```text
   https://elk.mycompany.com:9200
   ```
   *(or `https://<YOUR_PUBLIC_IP>:9200`)*
4. Click **Save and Apply**.

---

## 7. Installing Elastic Agent on Remote Servers

Run this on any external application server, web server, or database host you want to monitor.

### Step 1 — Get an Enrollment Token
In Kibana: **Management → Fleet → Enrollment Tokens → Create enrollment token** (e.g. `production-vms`).

### Step 2 — Run the Remote Installer
Copy `scripts/install-agent.sh` to the remote server and run:

```bash
# On your remote host:
sudo ./install-agent.sh \
  --fleet-url https://elk.mycompany.com:8220 \
  --token     <YOUR_ENROLLMENT_TOKEN>
```
*(Add `--insecure` if connecting via IP address with a self-signed certificate).*

The agent will download, install as a `systemd` service, enroll with Fleet, and begin streaming system metrics and container logs immediately.

---

## 8. Decoupled Updates: Changing Retention & Settings Live

You **never** have to rerun `02-start-elk.sh` or restart containers just to change retention, refresh intervals, or mapping rules.

1. Edit the settings in `.env`:
   ```bash
   nano .env
   # E.g. change ILM_DELETE_AFTER=14d
   # E.g. change ES_REFRESH_INTERVAL=2s
   ```
2. Run the policy updater:
   ```bash
   ./scripts/update-policies.sh
   ```
3. Elasticsearch updates the live ILM policy and index template via API in **~1 second with zero downtime**.

*(You can also use `./scripts/02-start-elk.sh --policies-only`).*

---

## 9. AWS S3 Backups & Restoring Snapshots

### 9.1 Configuring Automated Daily Backups
1. Create an AWS S3 bucket (e.g. `my-company-elk-backups`) and generate IAM credentials with S3 read/write permissions.
2. Add your AWS details to `.env`:
   ```ini
   AWS_ACCESS_KEY_ID=AKIA...
   AWS_SECRET_ACCESS_KEY=wJalr...
   S3_SNAPSHOT_BUCKET=my-company-elk-backups
   S3_SNAPSHOT_REGION=us-east-1
   ```
3. Run the S3 configuration script:
   ```bash
   ./scripts/04-setup-s3-backup.sh
   ```
This securely adds the keys to the Elasticsearch keystore, registers the `s3_backup` repository, and creates an automated daily Snapshot Lifecycle Management (SLM) policy that runs every midnight and retains snapshots for 30 days.

### 9.2 Restoring Snapshots from S3 Without Conflicts
If you need to view old logs from S3:

1. In Kibana, go to **Management → Stack Management → Snapshot and Restore**.
2. Click the **Snapshots** tab and click on the snapshot you want to restore.
3. Click the **Restore** button.
4. **Important configuration to avoid index collision with active data streams**:
   * **Data streams and indices**: Choose *Selected data streams and indices* (e.g. `logs-docker.container_logs-*`).
   * **Rename data streams and indices**: Toggle **ON**
     * **Capture pattern**: `(.+)`
     * **Replacement pattern**: `restored_$1`
   * **Restore global state**: **OFF** (Do not overwrite active cluster settings)
   * **Restore feature state**: **OFF** (Do not overwrite current users/security)
5. Click **Next** through the steps and click **Restore snapshot**.
6. In Kibana **Data Views**, create a data view for `restored_*` to search the restored historical data in **Discover**!

---

## 10. Managing the Stack

| Task | Command |
|---|---|
| **Start / Restart Stack** | `./scripts/02-start-elk.sh` |
| **Stop Stack (Data Preserved)** | `./scripts/02-start-elk.sh --down` |
| **Destroy Stack & Volumes (Data Loss)** | `./scripts/02-start-elk.sh --clean` |
| **Update Policies (ILM, Templates)** | `./scripts/update-policies.sh` |
| **Start Fleet Server** | `./scripts/03-start-fleet.sh` |
| **View Live Container Logs** | `docker compose logs -f [service_name]` |
| **Check Container Health** | `docker compose ps` |
| **Check Remote Agent Status** | `sudo elastic-agent status` (on remote host) |

---

## 11. Security Notes & TLS

### Dual-Layer TLS Architecture
* **Public Layer (Nginx)**: Serves a public Let's Encrypt certificate on ports `443`, `9200`, `8220`, and `8200`. Remote agents and browsers validate this certificate using standard root CAs.
* **Internal Layer**: Internal container communication (Elasticsearch, Kibana, Fleet Server) is secured using a private root CA generated at startup in the `certs` Docker volume.

### Security Checklist
* [ ] Change `ELASTIC_PASSWORD` and `KIBANA_SYSTEM_PASSWORD` in `.env`.
* [ ] Ensure `KIBANA_ENCRYPTION_KEY` and `KIBANA_REPORTING_ENCRYPT_KEY` are at least 32 characters.
* [ ] Ensure port `9300` is **blocked** by your firewall/security group.
* [ ] Keep `.env` restricted: `chmod 600 .env`.

---

## 12. Resource Limits Explained

- **`ES_JVM_HEAP` (`-Xms == -Xmx`)**: Setting minimum and maximum heap identical prevents JVM heap resizing during log ingestion spikes, eliminating major GC pauses.
- **`bootstrap.memory_lock=true`**: Locks the JVM heap into RAM, preventing the Linux kernel from swapping memory to disk.
- **Circuit Breakers (`70% total`, `60% request`)**: Protects Elasticsearch from Out-Of-Memory crashes if huge aggregations or search requests are executed.
- **ZSTD Best Compression**: Automatically enabled by the index template, saving ~60–70% disk space compared to default LZ4 compression.

---

## 13. Production Quirks, Gotchas & Debugging Runbook

This section covers the real-world operational quirks that happen in production and how to solve them immediately:

### Quirk 1: "I see logs when running `docker logs`, but nothing appears in Kibana"
1. **The Time Picker Pitfall**:
   - `docker logs <container>` dumps the *entire historical output* of a container from days or weeks ago.
   - Elastic Agent extracts the log's original creation timestamp and stores it as `@timestamp`.
   - In Kibana Discover, the top-right time picker defaults to **"Last 15 minutes"**. If your container only emitted logs hours or days ago, Kibana will show **0 results**.
   - **Fix**: Change the time picker to **"Today"**, **"Last 7 days"**, or **"Last 30 days"**.
2. **The Silent / Idle Container**:
   - If a container is idle and not writing to `stdout` right now, Elastic Agent has nothing to ship.
   - **Test live shipping**: Trigger an action or run:
     ```bash
     docker exec <container_name> sh -c "echo 'TEST LOG AT \$(date)'"
     ```
     With Kibana set to "Last 15 minutes", you should see this live log pop up within 5 seconds.
3. **Application Logging to File Instead of Stdout**:
   - Docker container log collectors only read `/var/lib/docker/containers/*/*-json.log` (`stdout`/`stderr`).
   - If your application writes to `/var/log/app.log` inside the container without printing to console, Docker cannot capture it.
   - **Fix**: Configure your app logger to output to console/stdout, or symlink the file to `/dev/stdout`.

### Quirk 2: "Log agent noise (e.g. Promtail / internal errors) shows up as container logs"
- Elastic Agent's Docker integration captures stdout/stderr from **every** container on the host, including log collectors like Promtail.
- **Filter in Kibana Discover**:
  ```kql
  container.name : "my-app" and not container.name : ("promtail" or "elastic-agent")
  ```

### Quirk 3: S3 Snapshot Restore Fails with "open index with same name already exists"
- **The Error**:
  ```text
  cannot restore index [.ds-logs-docker...] because an open index with same name already exists in the cluster
  ```
- **Why**: Elastic Agent writes to **Data Streams**. Data stream backing indices look like `.ds-logs-docker.container_logs-default-2026.09.04-000001`. You cannot restore over an active open index without deleting live data.
- **The Solution**: In Kibana Snapshot Restore (or via API), **rename during restore**:
  - Toggle ON **Rename data streams and indices**.
  - **Capture pattern**: `(.+)` *(do NOT use `data_(.+)`, which is just Kibana's grey example placeholder!)*
  - **Replacement pattern**: `restored_$1`
  - Turn **OFF** *Restore global state* and *Restore feature state*.
- **To View**: In Kibana → **Data Views**, create a view for `restored_*`, open Discover, and browse the snapshot logs!
- **To Clean Up Later**: In Dev Tools, run `DELETE /restored_*` to free disk space when done.

### Quirk 4: Remote Agents Go Offline (Fleet Output URL Trap)
- When Fleet Server starts, Kibana often initializes the default Elasticsearch output to `https://elasticsearch:9200`.
- That hostname only resolves inside the Docker network. Remote client machines cannot resolve `elasticsearch:9200` and will fail to connect.
- **Fix**: In Kibana → **Management → Fleet → Settings → Outputs → default**, change the URL to `https://elk.yourdomain.com:9200` (or your public IP).

### Quirk 5: Single-Node Storage Myth (Why Hot/Warm/Cold is a waste locally)
- In a multi-node cluster, Hot is on NVMe and Warm/Cold is on cheap HDDs.
- On a **single node**, Hot, Warm, and Cold all live on the **same physical EBS disk**.
- Running warm/cold phases locally only burns CPU/RAM for force-merges without saving storage costs.
- **The Lean Solution**: Retain 7 days locally (`ILM_DELETE_AFTER=7d`), and let S3 hold the 30-day backups via automated SLM (`04-setup-s3-backup.sh`).

---

## 14. Troubleshooting & Handy API Commands

### 14.1 Health Check Commands (ES, Kibana, Fleet, Elastic Agent)

#### 1. Quick Stack Health Summary
Check all container runtime states and Docker healthcheck statuses at a glance:
```bash
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
```

#### 2. Elasticsearch Health
```bash
# Docker native health status (healthy / unhealthy / starting)
docker inspect --format '{{.State.Health.Status}}' elasticsearch

# Detailed cluster health (green / yellow / red, node count, unassigned shards)
docker exec -it elasticsearch curl -sk \
  --cacert config/certs/ca/ca.crt \
  -u "elastic:${ELASTIC_PASSWORD}" \
  "https://localhost:9200/_cluster/health?pretty"
```

#### 3. Kibana Health
```bash
# Docker native health status
docker inspect --format '{{.State.Health.Status}}' kibana

# Detailed Kibana service status (overall health and plugin states)
docker exec -it kibana curl -sk \
  -u "kibana_system:${KIBANA_SYSTEM_PASSWORD}" \
  "http://localhost:5601/api/status" | grep -o '"overall":{"level":"[^"]*"'

# Test Kibana login endpoint response
curl -skI "https://localhost:5601/login" | head -n 5
```

#### 4. Fleet Server Health (ELK Host)
Fleet Server runs as an Elastic Agent in Server mode inside Docker:
```bash
# Direct HTTP health check (returns {"status":"HEALTHY"})
docker exec -it fleet-server curl -sk "https://localhost:8220/api/status"

# Internal Elastic Agent daemon status inside the Fleet container
docker exec -it fleet-server elastic-agent status

# Test via Nginx reverse proxy (public endpoint)
curl -sk "https://${ELK_SERVER_DOMAIN:-localhost}:8220/api/status"
```

#### 5. Elastic Agent Health (Remote Client Server)
Run these commands on any remote client machine shipping logs to this cluster:
```bash
# Check systemd service status
sudo systemctl status elastic-agent

# Detailed Elastic Agent sub-process health (Filebeat, Metricbeat, Endpoint)
sudo elastic-agent status

# If Elastic Agent is running as a Docker container on the client:
docker exec -it <agent_container_name> elastic-agent status

# Stream live Elastic Agent logs for diagnostics
sudo journalctl -u elastic-agent -f
```

---

### 14.2 Checking Health Directly from the Working / Installation Directory (Most Accurate)

Running status commands directly from each component's working directory accesses deep daemon status, component sub-processes (Filebeat, Metricbeat), and raw diagnostic bundles:

#### 1. Elastic Agent (On Remote Host: `/opt/Elastic/Agent`)
The official Elastic Agent installs into `/opt/Elastic/Agent`. Navigating into this directory provides the most accurate and unbuffered diagnostic status:
```bash
cd /opt/Elastic/Agent

# 1. Component breakdown with status of every sub-daemon (Filebeat, Metricbeat, APM)
sudo ./elastic-agent status

# 2. Detailed YAML output (lists all stream endpoints, units, check-in timestamps, errors)
sudo ./elastic-agent status --output yaml

# 3. Generate a complete diagnostics bundle zip (includes logs, config, system metrics)
sudo ./elastic-agent diagnostics

# 4. View raw JSON logs directly from the active version directory:
tail -f /opt/Elastic/Agent/data/elastic-agent-*/logs/elastic-agent-*.ndjson
```

#### 2. Fleet Server (Docker Working Directory: `/usr/share/elastic-agent`)
Because Fleet Server runs as an Elastic Agent in server mode inside Docker, you can invoke diagnostics directly in its working directory:
```bash
# Execute status directly from the agent's working directory inside the container
docker exec -it -w /usr/share/elastic-agent fleet-server ./elastic-agent status

# Full YAML status tree showing Fleet Server connection to ES & active policy revision
docker exec -it -w /usr/share/elastic-agent fleet-server ./elastic-agent status --output yaml

# Generate Fleet Server diagnostics bundle inside container
docker exec -it -w /usr/share/elastic-agent fleet-server ./elastic-agent diagnostics
```

#### 3. Elasticsearch (Docker Working Directory: `/usr/share/elasticsearch`)
Run checks directly inside the Elasticsearch root directory:
```bash
# Inspect node allocation and shard allocation directly:
docker exec -it -w /usr/share/elasticsearch elasticsearch curl -sk \
  --cacert config/certs/ca/ca.crt \
  -u "elastic:${ELASTIC_PASSWORD}" \
  "https://localhost:9200/_nodes/stats/jvm,os,process?pretty"

# Check disk & JVM heap usage percentages directly:
docker exec -it -w /usr/share/elasticsearch elasticsearch curl -sk \
  --cacert config/certs/ca/ca.crt \
  -u "elastic:${ELASTIC_PASSWORD}" \
  "https://localhost:9200/_cat/nodes?v&h=name,ip,heap.percent,ram.percent,cpu,disk.used_percent"
```

#### 4. Kibana (Docker Working Directory: `/usr/share/kibana`)
```bash
# Query the internal status API directly via Node.js from within Kibana's root:
docker exec -it -w /usr/share/kibana kibana curl -sk \
  -u "kibana_system:${KIBANA_SYSTEM_PASSWORD}" \
  "http://localhost:5601/api/status" | jq '.status.overall, .metrics.process' 2>/dev/null || true
```

### 14.3 Container Log Inspection
```bash
# View Elasticsearch logs
docker compose logs -f --tail 50 elasticsearch

# View Kibana logs
docker compose logs -f --tail 50 kibana

# View Fleet Server logs
docker logs -f --tail 50 fleet-server

# View Nginx reverse proxy logs (requests & upstream proxies)
docker compose logs -f --tail 50 nginx
```

### 14.4 Unblocking Read-Only Flood Stage (If Disk Hit 95%)
When disk hits 95%, Elasticsearch locks all indices to read-only mode (`read_only_allow_delete: true`). Once disk space is freed, unlock it with:
```bash
docker exec -it elasticsearch curl -sk \
  --cacert config/certs/ca/ca.crt \
  -u "elastic:${ELASTIC_PASSWORD}" \
  -X PUT "https://localhost:9200/_all/_settings" \
  -H "Content-Type: application/json" \
  -d '{"index.blocks.read_only_allow_delete": null}'
```

### 14.5 Useful Elasticsearch API Commands
Run from the ELK host:
```bash
# Check cluster health
docker exec elasticsearch curl -sk --cacert config/certs/ca/ca.crt -u "elastic:${ELASTIC_PASSWORD}" https://localhost:9200/_cluster/health?pretty

# List index sizes
docker exec elasticsearch curl -sk --cacert config/certs/ca/ca.crt -u "elastic:${ELASTIC_PASSWORD}" "https://localhost:9200/_cat/indices?v&s=store.size:desc"

# Check active recovery / restore progress
docker exec elasticsearch curl -sk --cacert config/certs/ca/ca.crt -u "elastic:${ELASTIC_PASSWORD}" "https://localhost:9200/_cat/recovery?v&active_only=true"

# Inspect current ILM policy
docker exec elasticsearch curl -sk --cacert config/certs/ca/ca.crt -u "elastic:${ELASTIC_PASSWORD}" "https://localhost:9200/_ilm/policy/elk-logs-policy?pretty"
```

### 14.6 Changing or Resetting Passwords on a Running Cluster

> ⚠️ **Important:** Elasticsearch stores credentials in its internal security index inside the `esdata` volume. Changing `ELASTIC_PASSWORD` or `KIBANA_SYSTEM_PASSWORD` in `.env` only sets initial credentials during first boot. On an already-running cluster, changing `.env` alone will **not** update the database.

Use the built-in Elasticsearch reset tool:

```bash
# 1. Reset elastic user password interactively (enter your desired password):
docker exec -it elasticsearch bin/elasticsearch-reset-password -u elastic -i

# 2. Reset kibana_system user password interactively:
docker exec -it elasticsearch bin/elasticsearch-reset-password -u kibana_system -i
```

After resetting:
1. Update both values in `.env` (`ELASTIC_PASSWORD` and `KIBANA_SYSTEM_PASSWORD`) so other maintenance scripts stay in sync.
2. Restart Kibana to pick up the new credentials:
   ```bash
   docker compose restart kibana
   ```

---

## 15. Under the Hood: Script Reference

| Script | How it Works |
|---|---|
| **`01-prepare-server.sh`** | Verifies root privileges, detects distro, installs Docker & Compose v2, creates `docker` group, adds non-root user, allocates a 4GB swapfile with `vm.swappiness=1`, tunes memory maps (`vm.max_map_count=262144`), increases file limits, and generates `.env` with random keys. |
| **`02-start-elk.sh`** | Loads `.env`, provisions Let's Encrypt certificates (if domain provided), starts containers via `docker compose up -d`, waits for healthchecks on ports `9200` and `5601`, configures Fleet output fingerprints, and invokes `update-policies.sh`. |
| **`03-start-fleet.sh`** | Prompts for the Kibana enrollment token, detects the Docker network and `certs` volume, and launches the `fleet-server` container connected to Elasticsearch with root CA certificates mounted. |
| **`04-setup-s3-backup.sh`** | Injects AWS keys into the secure Elasticsearch keystore (`elasticsearch-keystore add s3.client.default...`), reloads secure settings, registers the S3 snapshot repository, and creates the daily SLM policy. |
| **`update-policies.sh`** | Lightweight updater that connects directly to Elasticsearch via `curl` inside the container to apply cluster watermarks, the `elk-logs-policy` (7-day retention), and `elk-default-logs` index template (dynamic mapping & 5s refresh). Runs in ~1 second with zero container restarts. |
| **`install-agent.sh`** | Standalone installer for remote Linux/macOS client servers. Detects OS and CPU architecture, downloads the official Elastic Agent package, installs via `dpkg`/`rpm`/`tar`, enables the `elastic-agent` systemd service, and enrolls with Fleet Server. |
