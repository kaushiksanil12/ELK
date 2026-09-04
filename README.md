# Elastic Stack (ELK) — Self-Hosted Production Setup

> **Stack:** Elasticsearch · Kibana · Fleet Server · Nginx (SSL) · Certbot  
> **Version:** 9.x (configured via `.env`, default `9.5.0`)  
> **Deployment:** Docker Compose (single-node)  
> **Agents:** Elastic Agent on remote servers, managed via Fleet

---

## Table of Contents

1. [Architecture Overview](#1-architecture-overview)
2. [Prerequisites](#2-prerequisites)
3. [Project Structure](#3-project-structure)
4. [Configuration — `.env` Reference](#4-configuration----env-reference)
5. [Starting the ELK Server](#5-starting-the-elk-server)
6. [Setting Up Fleet Server](#6-setting-up-fleet-server)
7. [Installing Elastic Agent on Remote Servers](#7-installing-elastic-agent-on-remote-servers)
8. [Managing the Stack](#8-managing-the-stack)
9. [Security Notes](#9-security-notes)
10. [Resource Limits Explained](#10-resource-limits-explained)
11. [Troubleshooting](#11-troubleshooting)
12. [Under the Hood: How the Scripts Work](#12-under-the-hood-how-the-scripts-work)

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
│      │           │          │          │                   │
│  ┌───▼───┐  ┌────▼───┐  ┌──▼──────┐  └──────────────┐   │
│  │Kibana │  │  ES    │  │ Fleet   │   Certbot (TLS)   │   │
│  │:5601  │  │ :9200  │  │ Server  │                   │   │
│  └───────┘  └────────┘  │  :8220  │                   │   │
│                          │  :8200  │                   │   │
│                          └─────────┘                   │   │
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

- **No Logstash** — Elastic Agent ships data directly to Elasticsearch. Parsing is handled via Elasticsearch Ingest Pipelines, which are free, faster, and managed entirely in Kibana.
- **Elastic Agent is NOT on the ELK server** — It runs on the servers you want to monitor (app, web, DB servers).
- **Fleet Server** is the control plane — manages agent policies, integrations, and configuration from a central UI in Kibana.
- **Nginx** terminates public SSL with a Let's Encrypt certificate and proxies to internal containers. Containers themselves use self-signed TLS internally.
- **Fleet Server is started separately** via `start-fleet.sh` after the main stack is running and a Fleet enrollment token has been generated in Kibana.

---

## 2. Prerequisites

### ELK Server

| Requirement | Minimum | Recommended |
|---|---|---|
| CPU | 2 cores | 4+ cores |
| RAM | 4 GB | 8 GB+ |
| Disk | 20 GB | 100 GB+ |
| OS | Linux (any), macOS | Ubuntu 22.04 LTS |

**Required Inbound Firewall Ports:**

| Port | Protocol | Service | Purpose |
|---|---|---|---|
| `80` | TCP | HTTP | Let's Encrypt ACME validation & HTTPS redirect |
| `443` | TCP | HTTPS | Kibana Web UI |
| `9200` | TCP | Elasticsearch | External ES API access (via Nginx SSL) |
| `8220` | TCP | Fleet Server | Remote Elastic Agents connect here |
| `8200` | TCP | APM Server | Application Performance Monitoring ingestion |

> ⚠️ Port `9300` (Elasticsearch transport) must **never** be exposed publicly — it is used only for internal node-to-node communication.

**Required Software:**
```bash
# Docker Engine (v20.10+)
docker --version

# Docker Compose Plugin (v2.x)
docker compose version

# curl, openssl, unzip (usually pre-installed on Ubuntu)
curl --version
```

> **Linux:** After installing Docker, you must also set:
> ```bash
> sudo sysctl -w vm.max_map_count=262144
> echo "vm.max_map_count=262144" | sudo tee /etc/sysctl.d/99-elk.conf
> ```
> `setup.sh` does this automatically.

### Remote Servers (for Elastic Agent)

| Requirement | Value |
|---|---|
| RAM | 256 MB free |
| OS | Ubuntu/Debian, RHEL/CentOS/Amazon Linux, macOS |
| Network | Outbound TCP to ELK server on port `8220` |
| Privileges | `sudo` / root |

---

## 3. Project Structure

```
elk/
├── .env                         ← All configuration (DO NOT COMMIT)
├── .env.example                 ← Template — copy to .env and edit
├── .gitignore                   ← Excludes .env, certs, and letsencrypt
├── docker-compose.yml           ← Elasticsearch, Kibana, Nginx, Certbot
├── setup.sh                     ← Main start/stop/clean script
├── start-fleet.sh               ← Start Fleet Server (run after setup.sh)
├── install-agent.sh             ← Run on REMOTE servers to install Elastic Agent
├── README.md                    ← This file
└── nginx/
    └── templates/
        └── kibana.conf.template ← Nginx SSL reverse proxy config
```

> ⚠️ **`.env`, `config/certs/`, and `letsencrypt/`** are in `.gitignore` — never commit secrets or private keys.

---

## 4. Configuration — `.env` Reference

Copy the example file and edit it before running anything:

```bash
cp .env.example .env
nano .env
```

### 4.1 Stack Version

| Variable | Default | Description |
|---|---|---|
| `STACK_VERSION` | `9.5.0` | Elastic Stack version. Must match across the ELK server and all remote agents. |

### 4.2 Cluster Identity

| Variable | Default | Description |
|---|---|---|
| `CLUSTER_NAME` | `elk-cluster` | Elasticsearch cluster name |
| `ELASTICSEARCH_NODE_NAME` | `es-node-01` | Name of this Elasticsearch node |

### 4.3 Security — Passwords & Keys

> ⚠️ **Change all of these before going to production.**

| Variable | Description |
|---|---|
| `ELASTIC_PASSWORD` | Password for the built-in `elastic` superuser |
| `KIBANA_SYSTEM_PASSWORD` | Password for the internal `kibana_system` user (used by Kibana to connect to ES) |
| `KIBANA_ENCRYPTION_KEY` | **Min 32 characters.** Encrypts Kibana saved objects and sessions. |
| `KIBANA_REPORTING_ENCRYPT_KEY` | **Min 32 characters.** Encrypts Kibana PDF reports. |

**Generate secure random keys:**
```bash
openssl rand -base64 32
```

### 4.4 Network / Ports

| Variable | Default | Description |
|---|---|---|
| `ES_PORT` | `9200` | Elasticsearch HTTPS API port |
| `KIBANA_PORT` | `5601` | Kibana internal port (accessed via Nginx on 443) |
| `FLEET_SERVER_PORT` | `8220` | Fleet Server port (remote agents connect here) |
| `APM_SERVER_PORT` | `8200` | APM Server port (application performance tracing) |

### 4.5 Server Identity (TLS SANs)

These values are injected into every TLS certificate at first run, allowing remote agents to connect with full certificate verification.

| Variable | Example | Description |
|---|---|---|
| `ELK_SERVER_PUBLIC_IP` | `13.60.236.39` | Public IP of your ELK server |
| `ELK_SERVER_DOMAIN` | `elk.mycompany.com` | Domain name pointing to your ELK server (used for Let's Encrypt SSL) |

| Scenario | What to set | Agent `--fleet-url` |
|---|---|---|
| Only have an IP | `ELK_SERVER_PUBLIC_IP=10.0.0.5` | `https://10.0.0.5:8220` |
| Have a domain (recommended) | Set both | `https://elk.mycompany.com:8220` |

> ⚠️ **SANs are baked into the certificate at first run.** If you change these values later, you must run `./setup.sh --clean` to regenerate certificates (this deletes all data).

### 4.6 JVM Heap Size

| Variable | Default | Description |
|---|---|---|
| `ES_JVM_HEAP` | `1g` | Elasticsearch heap size. Sets both `-Xms` and `-Xmx`. |

> **Rule of thumb:** 50% of available RAM, max **31g**. Never exceed 31g — JVM compressed oops break above that.

| RAM | `ES_JVM_HEAP` | `ES_MEM_LIMIT` | `KIBANA_MEM_LIMIT` |
|---|---|---|---|
| 4 GB | `1g` | `2g` | `1g` |
| 8 GB | `3g` | `6g` | `1g` |
| 16 GB | `6g` | `12g` | `2g` |
| 32 GB | `14g` | `28g` | `2g` |

### 4.7 Docker Resource Limits

| Variable | Default | Description |
|---|---|---|
| `ES_MEM_LIMIT` | `2g` | Hard RAM limit for Elasticsearch container |
| `ES_CPU_LIMIT` | `2.0` | CPU cores for Elasticsearch |
| `KIBANA_MEM_LIMIT` | `1g` | Hard RAM limit for Kibana container |
| `KIBANA_CPU_LIMIT` | `1.0` | CPU cores for Kibana |
| `FLEET_MEM_LIMIT` | `512m` | Hard RAM limit for Fleet Server container |
| `FLEET_CPU_LIMIT` | `0.5` | CPU cores for Fleet Server |

### 4.8 Log Retention & ILM

Controls how long data is kept and when it moves between storage tiers.

| Variable | Default | Description |
|---|---|---|
| `ILM_ROLLOVER_MAX_AGE` | `1d` | Roll to a new index every day |
| `ILM_ROLLOVER_MAX_SHARD_SIZE` | `10gb` | Or when a shard hits 10 GB |
| `ILM_WARM_AFTER` | `2d` | Move to warm (shrink + forcemerge) after 2 days |
| `ILM_COLD_AFTER` | `7d` | Move to cold (read-only) after 7 days |
| `ILM_DELETE_AFTER` | `30d` | **Main retention knob.** Delete data after 30 days. |
| `ES_DEFAULT_REPLICAS` | `0` | Always `0` for single-node (no peers to replicate to) |
| `ES_REFRESH_INTERVAL` | `30s` | How often new docs become searchable. 30s reduces I/O significantly vs the default 1s. |
| `ES_DYNAMIC_MAPPING` | `strict` | `strict` rejects docs with unknown fields, preventing field explosion. |

---

## 5. Starting the ELK Server

### Step 1 — Configure `.env`

```bash
cp .env.example .env
nano .env
```

Minimum required changes:
```bash
ELASTIC_PASSWORD=your_strong_password_here
KIBANA_SYSTEM_PASSWORD=another_strong_password
KIBANA_ENCRYPTION_KEY=a-random-string-of-at-least-32-chars
KIBANA_REPORTING_ENCRYPT_KEY=another-random-32-char-string
ELK_SERVER_PUBLIC_IP=13.60.236.39       # your ELK server's public IP
ELK_SERVER_DOMAIN=elk.mycompany.com     # domain pointing to ELK server
ES_JVM_HEAP=3g                          # ~50% of your RAM
ES_MEM_LIMIT=6g                         # ~2x the heap
```

### Step 2 — Run setup.sh

```bash
sudo chmod +x setup.sh start-fleet.sh install-agent.sh
sudo ./setup.sh
```

The script will automatically:
1. ✅ Validate all required environment variables
2. ✅ Check Docker version and system requirements
3. ✅ Set `vm.max_map_count` on Linux
4. ✅ Pull all Docker images
5. ✅ Generate TLS certificates with your IP/domain as SANs
6. ✅ Start Elasticsearch and wait for it to be healthy
7. ✅ Set the `kibana_system` password
8. ✅ Start Kibana and wait for it to be available
9. ✅ Start Nginx (SSL reverse proxy) and Certbot (auto-renewing Let's Encrypt)
10. ✅ Apply cluster-level settings (watermarks, circuit breakers)
11. ✅ Apply ILM policy and index template
12. ✅ Print a service summary

### Step 3 — Access Kibana

Once complete, open:
```
https://elk.mycompany.com
```
Or via IP:
```
https://13.60.236.39
```

Login with:
- **Username:** `elastic`
- **Password:** value of `ELASTIC_PASSWORD` in `.env`

---

## 6. Setting Up Fleet Server

Fleet Server is started **separately** after the main stack is running, because it requires an enrollment token that can only be generated from Kibana.

### Step 1 — Generate an enrollment token in Kibana

1. Open Kibana → **Management → Fleet**
2. Click **"Add Fleet Server"**
3. Create a new policy:
   - **Name:** `Fleet Server Policy`
   - **Policy ID:** `fleet-server-policy` ← must match exactly
4. Click **"Generate Fleet Server policy"**
5. Copy the **enrollment token** shown on screen

### Step 2 — Run start-fleet.sh

```bash
sudo bash ./start-fleet.sh
```

The script will:
- Prompt you to paste the enrollment token directly in the terminal
- Auto-detect the Docker network and volumes used by the main stack
- Start the `fleet-server` container connected to the same network
- Wait and confirm Fleet Server becomes `HEALTHY`

```
──── Fleet Server Setup ────

Paste your Fleet Server Enrollment Token below.
[WARN]  Get it from Kibana → Management → Fleet → Add Fleet Server

  Enrollment Token: <paste here>

[INFO]  Token received ✓
[INFO]  Starting Fleet Server container...
[INFO]  Fleet Server is HEALTHY ✓
[INFO]  Fleet Server URL: https://elk.mycompany.com:8220
```

### Step 3 — Configure Fleet Outputs (CRITICAL)

By default, Kibana tells agents to send their data to `https://elasticsearch:9200`. This works for the local Fleet Server, but **remote agents will fail to connect and go offline**.

You must change this to your public Elasticsearch URL:
1. Go to **Kibana → Management → Fleet → Settings**
2. Under **Outputs**, find `default` (Type: Elasticsearch) and click the Edit icon.
3. Change the **Hosts** field from `https://elasticsearch:9200` to `https://elk.mycompany.com:9200` (or your public IP).
4. Click **Save and Apply**.

### Step 4 — Verify in Kibana

Go to **Kibana → Management → Fleet → Agents**

The Fleet Server itself should appear as a connected agent with status **Healthy**.

---

## 7. Installing Elastic Agent on Remote Servers

Elastic Agent runs on each server you want to monitor — **not** on the ELK server.

### Step 1 — Get an enrollment token for your agents

In Kibana: **Management → Fleet → Enrollment Tokens → Create enrollment token**

Give it a meaningful name (e.g., `web-servers`, `app-servers`) and copy the token.

### Step 2 — Copy and run install-agent.sh

```bash
# Copy the script to the remote server
scp install-agent.sh user@remote-server:/tmp/

# SSH into the remote server
ssh user@remote-server

# Run the installer
sudo bash /tmp/install-agent.sh \
  --fleet-url https://elk.mycompany.com:8220 \
  --token     <enrollment-token-from-kibana>
```

The script will:
1. Detect OS and CPU architecture automatically (Ubuntu/Debian, RHEL/CentOS/Amazon Linux, macOS)
2. Download the correct Elastic Agent package for this stack version
3. Install via system package manager (`dpkg`, `rpm`, or `tar`)
4. Enroll the agent with Fleet Server using the provided token
5. Start and enable the `elastic-agent` systemd service

### Step 3 — Verify in Kibana

**Kibana → Management → Fleet → Agents**

The new agent should appear as **Healthy** within 30–60 seconds.

### install-agent.sh Options

| Flag | Required | Description |
|---|---|---|
| `--fleet-url` | ✅ | Public URL of Fleet Server (e.g. `https://elk.domain.com:8220`) |
| `--token` | ✅ | Enrollment token from Kibana |
| `--insecure` | No | Skip TLS verification (required if using an IP instead of a domain) |
| `--version` | No | Elastic Agent version (defaults to `STACK_VERSION` from `.env`) |

---

## 8. Managing the Stack

### Start the stack
```bash
sudo ./setup.sh
```

### Start Fleet Server (after setup.sh)
```bash
sudo bash ./start-fleet.sh
```

### Stop the stack (data preserved)
```bash
sudo ./setup.sh --down
```

### Destroy everything — containers AND all data
```bash
sudo ./setup.sh --clean
# ⚠️  Deletes all Elasticsearch data, Kibana saved objects, and TLS certificates.
```

### View live logs
```bash
sudo docker compose logs -f                    # all services
sudo docker compose logs -f elasticsearch
sudo docker compose logs -f kibana
sudo docker logs -f fleet-server
```

### Restart a single service
```bash
sudo docker compose restart kibana
sudo docker compose restart elasticsearch
sudo docker restart fleet-server
```

### Check container status
```bash
sudo docker ps -a
```

### Check remote agent status (on the remote server)
```bash
sudo elastic-agent status
sudo journalctl -u elastic-agent -f     # view agent logs
```

### Unenroll and uninstall agent (on the remote server)
```bash
sudo elastic-agent uninstall
```

---

## 9. Security Notes

### 9.1 TLS Architecture

This stack uses a **two-layer TLS** approach:

| Layer | Certificate | Purpose |
|---|---|---|
| **Public (Nginx)** | Let's Encrypt (trusted by all browsers) | Terminates public HTTPS on 443, 9200, 8220, 8200 |
| **Internal (self-signed)** | Auto-generated CA + node certs | Secures container-to-container communication |

Remote agents connect to Nginx's Let's Encrypt certificate — no custom CA needed on agent machines.

### 9.2 Subject Alternative Names (SANs)

At certificate generation time, `setup.sh` injects your server's **public IP** and **domain name** into every internal certificate as a SAN. This enables full TLS verification without `--insecure`.

```bash
# In .env
ELK_SERVER_PUBLIC_IP=13.60.236.39
ELK_SERVER_DOMAIN=elk.mycompany.com
```

> ⚠️ **SANs are baked into certs at first run.** To change them:
> ```bash
> sudo ./setup.sh --clean   # destroys all data
> # Edit .env with new IP/domain
> sudo ./setup.sh           # regenerates certs with new SANs
> ```

### 9.3 Security Checklist

| Item | Action |
|---|---|
| **Passwords** | Change `ELASTIC_PASSWORD` and `KIBANA_SYSTEM_PASSWORD` before production |
| **Encryption keys** | `KIBANA_ENCRYPTION_KEY` and `KIBANA_REPORTING_ENCRYPT_KEY` must be ≥ 32 chars. Changing them makes all saved objects unreadable — set them once and keep them safe. |
| **`.env` file** | Never commit to version control. Contains all secrets. |
| **Firewall** | Expose only `80`, `443`, `9200`, `8220`, `8200`. Never expose `9300` (ES transport). |
| **`ca.key`** | Never share or commit the private key from `config/certs/ca/ca.key`. |

---

## 10. Resource Limits Explained

### Why lock JVM heap (`-Xms == -Xmx`)?

Setting minimum and maximum heap to the **same value** prevents the JVM from dynamically resizing the heap, which causes GC pauses. This is the official Elastic recommendation for production.

### Why `bootstrap.memory_lock=true`?

Tells the OS not to swap the JVM heap to disk. Swapping causes severe Elasticsearch performance degradation and can cause cluster instability.

### Why circuit breakers?

Without circuit breakers, a large aggregation query could load the entire fielddata into memory and crash Elasticsearch with an OOM error. Circuit breakers reject the request early with a `429` response instead.

### Why `thread_pool` settings in `docker-compose.yml` (not the API)?

Elasticsearch 9.x no longer allows `thread_pool.write.queue_size` and `thread_pool.search.queue_size` to be updated dynamically via the cluster settings API. They must be set as container environment variables at startup, which is what this stack does.

---

## 11. Troubleshooting

### Elasticsearch fails to start

**Check logs:**
```bash
sudo docker compose logs elasticsearch | tail -50
```

**Common causes:**
- `vm.max_map_count` too low (Linux) → `sudo sysctl -w vm.max_map_count=262144`
- Heap too large for available RAM → reduce `ES_JVM_HEAP`
- Port conflict → check `sudo docker ps -a` for stale containers

---

### Kibana shows "Kibana server is not ready yet"

Kibana takes 60–120 seconds after Elasticsearch becomes healthy. If it doesn't recover:
```bash
sudo docker compose logs kibana | tail -50
```
- Wrong `KIBANA_SYSTEM_PASSWORD` → re-run `sudo ./setup.sh` (it resets the password automatically)
- Encryption key too short → `KIBANA_ENCRYPTION_KEY` must be ≥ 32 chars

---

### Nginx fails to start (port already allocated)

```bash
sudo docker ps -a             # find stale containers
sudo docker rm -f <id>        # remove them
sudo ./setup.sh --clean       # full clean start
sudo ./setup.sh
```

---

### Fleet Server stuck in STARTING

Fleet Server waits for a valid policy from Kibana. This happens when the `fleet-server-policy` doesn't exist yet.

**Fix:**
1. Open Kibana → **Management → Fleet → Add Fleet Server**
2. Create policy with ID `fleet-server-policy`
3. Re-run `sudo bash ./start-fleet.sh` with the new token

---

### Remote agent can't connect to Fleet Server

```bash
# Test from the remote server:
curl -sk https://elk.mycompany.com:8220/api/status
# Should return: {"status":"HEALTHY",...}
```

Check:
1. Port `8220` is open in your firewall/security group
2. `ELK_SERVER_DOMAIN` in `.env` matches your actual domain
3. Fleet Server is running: `sudo docker ps | grep fleet`

---

### Index is read-only (disk full)

When disk hits `ES_WATERMARK_FLOOD_STAGE` (default 95%), Elasticsearch marks all indices read-only.

```bash
# 1. Free up disk space

# 2. Re-enable writes (run from inside the elasticsearch container)
sudo docker exec elasticsearch \
  curl -sk --cacert config/certs/ca/ca.crt \
  -u "elastic:${ELASTIC_PASSWORD}" \
  -X PUT "https://localhost:9200/_all/_settings" \
  -H "Content-Type: application/json" \
  -d '{"index.blocks.read_only_allow_delete": null}'
```

---

### Reset the elastic password

```bash
# Reset interactively from inside the container
sudo docker exec -it elasticsearch \
  bin/elasticsearch-reset-password -u elastic -i
```

---

### Useful API one-liners

```bash
# Set these shortcuts in your shell session
export ES="https://localhost:9200"
export CA="--cacert config/certs/ca/ca.crt"
export AUTH="-u elastic:$(grep ^ELASTIC_PASSWORD .env | cut -d= -f2)"

# Cluster health
sudo docker exec elasticsearch curl -sk $CA $AUTH $ES/_cluster/health?pretty

# Node JVM stats
sudo docker exec elasticsearch curl -sk $CA $AUTH $ES/_nodes/stats/jvm?pretty

# Index sizes
sudo docker exec elasticsearch curl -sk $CA $AUTH "$ES/_cat/indices?v&s=store.size:desc"

# Shard allocation
sudo docker exec elasticsearch curl -sk $CA $AUTH "$ES/_cat/shards?v"

# Disk usage per node
sudo docker exec elasticsearch curl -sk $CA $AUTH "$ES/_cat/allocation?v"

# Current ILM policy
sudo docker exec elasticsearch curl -sk $CA $AUTH "$ES/_ilm/policy/elk-logs-policy?pretty"
```

---

## 12. AWS S3 Backups & Restores

To ensure you never lose your data, you can automatically stream your Elasticsearch snapshots to an AWS S3 bucket.

### Setting up Automated Daily Backups
1. Create an AWS S3 Bucket (e.g., `my-elk-backups`) and generate an IAM Access Key with read/write permissions for that bucket.
2. Add your AWS credentials and bucket details to the bottom of your `.env` file on your ELK server:
   ```ini
   AWS_ACCESS_KEY_ID=your_access_key
   AWS_SECRET_ACCESS_KEY=your_secret_key
   S3_SNAPSHOT_BUCKET=your_bucket_name
   S3_SNAPSHOT_REGION=us-east-1
   ```
3. Run the automated S3 setup script:
   ```bash
   sudo bash ./setup-s3.sh
   ```
This script securely injects your AWS credentials into the encrypted Elasticsearch keystore, registers the S3 repository, and configures a **Snapshot Lifecycle Management (SLM)** policy to automatically back up your cluster every day at midnight and retain the backups for 30 days.

### How to Restore Data from a Backup
If you ever need to restore an index (or check what is inside a backup), you can do it entirely through the Kibana UI—no terminal commands required!

1. Open **Kibana** in your browser.
2. Navigate to **Management → Stack Management → Snapshot and Restore**.
3. Click the **Snapshots** tab. You will see a list of all your daily backups stored in S3.
4. Click on any snapshot to view the indices contained within it.
5. To restore data, click the **Restore** icon next to the snapshot. A wizard will guide you to:
   - Select exactly which indices you want to restore (you can restore specific logs or the entire cluster).
   - Optionally rename the restored indices (e.g., restoring `logs-system` as `restored-logs-system`) so you can investigate the data without overwriting your live logs.
   - Click **Restore snapshot** and Kibana will stream the data directly back from S3 into your cluster!

---

## 13. Under the Hood: How the Scripts Work

To make this deployment reliable across different environments, much of the complexity is abstracted into three Bash scripts. If you need to debug or customize the stack, here is exactly what each script does.

### A. `setup.sh` (Main Stack Initializer)
This script handles the lifecycle of the core ELK stack (Elasticsearch, Kibana, Nginx, Certbot).
1. **Pre-flight Checks**: Validates that Docker and `curl` are installed, and that `.env` is populated with all required variables and valid memory syntax.
2. **System Requirements**: On Linux, it temporarily and persistently sets `vm.max_map_count=262144`, which is a strict kernel requirement for the Elasticsearch JVM.
3. **Nginx & SSL Configuration**:
   - If `ELK_SERVER_DOMAIN` is set, it temporarily spawns a standalone Certbot container on port 80 to provision a Let's Encrypt certificate. It then activates the `kibana.conf.template`.
   - If no domain is set (IP-only mode), it skips Let's Encrypt and activates `kibana-ip.conf.template`, which falls back to the self-signed certificates generated by the `elk-setup` container.
4. **Starts the Stack & Generates Certificates**: Runs `docker compose up -d`. This triggers the `elk-setup` container, which is responsible for the foundational security setup:
   - **CA Creation**: Uses `elasticsearch-certutil` to generate a root Certificate Authority (CA) if one doesn't exist.
   - **Node Certificates**: Generates self-signed certificates for Elasticsearch, Kibana, and Fleet Server using the CA, securely storing them in the `elk_certs` volume.
   - **Password Setup**: Once Elasticsearch boots, it securely sets the `elastic` and `kibana_system` passwords using the Elasticsearch API based on your `.env` values.
5. **Health Waiters**: Actively polls `curl` inside the Elasticsearch and Kibana containers (bypassing the host network) until their APIs report a healthy status.
6. **API Bootstrapping**:
   - Applies cluster-level settings (like max shards per node and disk watermark thresholds) via the Elasticsearch `_cluster/settings` API.
   - Applies the **Index Lifecycle Management (ILM)** policy via the `_ilm/policy` API to automatically rotate logs when they get too old or too large.
   - Applies the default index template via the `_index_template` API to enable `best_compression` (zstd) and limit dynamic mapping explosions.

### B. `start-fleet.sh` (Fleet Server Initializer)
Fleet Server is intentionally decoupled from `docker-compose.yml`. This is because Fleet Server requires a Kibana-generated enrollment token to start, meaning Kibana must be fully running and manually configured before Fleet Server can boot.
1. **Token Injection**: Interactively prompts for the Service Token generated in the Kibana UI.
2. **Environment Discovery**: Uses `docker volume ls` and `docker network ls` to dynamically locate the `elk_certs` volume and `elk_default` network created by `docker-compose.yml`.
3. **Container Launch**: Spawns the `fleet-server` container using a direct `docker run` command, attaching it to the discovered network and volumes.
4. **Trust Configuration**: Injects the self-signed CA cert (`ca.crt`) into the container so Fleet Server can securely authenticate against the Elasticsearch API.

### C. `install-agent.sh` (Remote Agent Installer)
This script is designed to be copied to any remote server (Ubuntu, RHEL, or macOS) to securely install and enroll an Elastic Agent.
1. **System Detection**: Reads `/etc/os-release` and `uname -m` to determine the operating system (`deb`, `rpm`, `tar`, `darwin`) and CPU architecture (`x86_64`, `arm64`).
2. **Dynamic Download**: Constructs the correct URL to Elastic's artifact repository and downloads the exact package for the detected architecture.
3. **Package Installation**: Installs the agent using the native package manager (`dpkg`, `rpm`, or `tar`).
4. **Service Management**: Uses `systemctl` (on Linux) to enable and start the agent daemon. (The agent must be running in the background before enrollment can succeed).
5. **Enrollment**: 
   - Uses `elastic-agent enroll --force` (for package managers) or `elastic-agent install` (for tarballs) to register the agent with your Fleet Server.
   - If you pass the `--insecure` flag (required for IP-only setups), it tells the agent to bypass strict TLS validation for the self-signed certificate served by Nginx.
