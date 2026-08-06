# Elastic Stack (ELK) Setup — Full Documentation

> **Stack:** Elasticsearch · Kibana · Fleet Server  
> **Version:** 9.x (configured via `.env`, default `9.5.0`)  
> **Deployment:** Docker Compose (single-node)  
> **Agent:** Elastic Agent on remote servers (managed via Fleet)

---

## Table of Contents

1. [Architecture Overview](#1-architecture-overview)
2. [Prerequisites](#2-prerequisites)
3. [Project Structure](#3-project-structure)
4. [Configuration — `.env` Reference](#4-configuration----env-reference)
5. [Starting the ELK Server](#5-starting-the-elk-server)
6. [Installing Elastic Agent on Remote Servers](#6-installing-elastic-agent-on-remote-servers)
7. [Managing the Stack](#7-managing-the-stack)
8. [Security Notes](#8-security-notes)
9. [Resource Limits Explained](#9-resource-limits-explained)
10. [Troubleshooting](#10-troubleshooting)

---

## 1. Architecture Overview

```
┌─────────────────────────────────────────────────┐
│              ELK SERVER (Docker Compose)         │
│                                                  │
│  ┌──────────────┐   ┌──────────────┐            │
│  │Elasticsearch │   │    Kibana    │             │
│  │  :9200       │◄──│  :5601       │             │
│  └──────┬───────┘   └──────────────┘            │
│         │                                        │
│  ┌──────┴───────┐                               │
│  │ Fleet Server │  ← Remote agents connect here  │
│  │  :8220       │                               │
│  └──────────────┘                               │
└────────────────────────┬────────────────────────┘
                         │  HTTPS (port 8220)
          ┌──────────────┼──────────────┐
          ▼              ▼              ▼
   ┌─────────────┐ ┌─────────────┐ ┌─────────────┐
   │ App Server  │ │  Web Server │ │  DB Server  │
   │             │ │             │ │             │
   │Elastic Agent│ │Elastic Agent│ │Elastic Agent│
   │(installed   │ │(installed   │ │(installed   │
   │ via script) │ │ via script) │ │ via script) │
   └─────────────┘ └─────────────┘ └─────────────┘
```

**Key design decisions:**
- **No Logstash** — Elastic Agent ships data directly to Elasticsearch. Parsing is done via Elasticsearch Ingest Pipelines, which are free, faster, and managed in Kibana.
- **Elastic Agent is NOT on the ELK server** — It runs on the servers you want to monitor (app, web, DB servers).
- **Fleet Server** is the control plane. It manages policies, integrations, and configuration for all remote agents from a central UI in Kibana.

---

## 2. Prerequisites

### ELK Server

| Requirement | Minimum | Recommended |
|---|---|---|
| CPU | 2 cores | 4+ cores |
| RAM | 4 GB | 8 GB+ |
| Disk | 20 GB | 100 GB+ |
| OS | Linux (any), macOS | Ubuntu 22.04 LTS |

**Required software:**
```bash
# Docker Engine (v20.10+)
docker --version

# Docker Compose Plugin (v2.x)
docker compose version

# curl
curl --version
```

> **macOS:** Install [Docker Desktop](https://www.docker.com/products/docker-desktop/). It handles all system tuning automatically.

> **Linux:** After installing Docker, you must also set:
> ```bash
> sudo sysctl -w vm.max_map_count=262144
> echo "vm.max_map_count=262144" | sudo tee /etc/sysctl.d/99-elk.conf
> ```
> The `setup.sh` script does this automatically.

### Remote Servers (for Elastic Agent)

| Requirement | Minimum |
|---|---|
| RAM | 256 MB free |
| OS | Ubuntu/Debian, RHEL/CentOS/Amazon Linux, macOS |
| Network | Outbound TCP to ELK server on port `8220` |
| Privileges | `sudo` / root access |

---

## 3. Project Structure

```
elk/
├── .env                  ← All configuration lives here (DO NOT COMMIT)
├── .gitignore            ← Excludes .env and certs from git
├── docker-compose.yml    ← Service definitions: ES, Kibana, Fleet Server
├── setup.sh              ← One-shot start/stop/clean script
├── install-agent.sh      ← Run on REMOTE servers to enroll Elastic Agent
├── README.md             ← This file
└── config/
    └── certs/            ← Auto-generated TLS certificates (DO NOT COMMIT)
        ├── ca/
        │   ├── ca.crt    ← CA certificate (copy to remote servers)
        │   └── ca.key
        ├── elasticsearch/
        ├── kibana/
        └── fleet-server/
```

> ⚠️ **`.env` and `config/certs/` are in `.gitignore`** — never commit secrets or private keys.

---

## 4. Configuration — `.env` Reference

All configuration is done in the [`.env`](.env) file. **Edit this file before running `setup.sh`.**

### 4.1 Version

| Variable | Default | Description |
|---|---|---|
| `STACK_VERSION` | `8.14.3` | Elastic Stack version. Must match across ELK server and all remote agents. |

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
| `KIBANA_SYSTEM_PASSWORD` | Password for the internal `kibana_system` user |
| `KIBANA_ENCRYPTION_KEY` | **Min 32 characters.** Used to encrypt saved objects and sessions. |
| `KIBANA_REPORTING_ENCRYPT_KEY` | **Min 32 characters.** Used to encrypt reports. |
| `FLEET_ENROLLMENT_TOKEN` | Leave blank — `setup.sh` fills this automatically after Fleet is ready. |

**Generate secure random keys:**
```bash
# Generate a 32-char random key
openssl rand -base64 32
```

### 4.4 Network / Ports

| Variable | Default | Description |
|---|---|---|
| `ES_PORT` | `9200` | Elasticsearch HTTPS API port |
| `ES_TRANSPORT_PORT` | `9300` | Elasticsearch node-to-node transport (internal) |
| `KIBANA_PORT` | `5601` | Kibana HTTPS UI port |
| `FLEET_SERVER_PORT` | `8220` | Fleet Server port (remote agents connect here) |
| `APM_SERVER_PORT` | `8200` | APM Server port (application performance monitoring) |

### 4.5 JVM Heap Size

| Variable | Default | Description |
|---|---|---|
| `ES_JVM_HEAP` | `1g` | Elasticsearch heap size. Sets both `-Xms` and `-Xmx` to the same value. |

> **Rule of thumb:** Set to 50% of available RAM, with a maximum of **31g**. Never exceed 31g — the JVM's compressed oops optimisation breaks above that.

```
4 GB RAM  →  ES_JVM_HEAP=2g
8 GB RAM  →  ES_JVM_HEAP=4g
16 GB RAM →  ES_JVM_HEAP=8g
```

> The Docker container memory limit (`ES_MEM_LIMIT`) must be **at least 2× the heap size** to leave room for the OS page cache.

### 4.6 Docker Resource Limits

| Variable | Default | Description |
|---|---|---|
| `ES_MEM_LIMIT` | `2g` | Hard RAM limit for the Elasticsearch container |
| `ES_CPU_LIMIT` | `2.0` | CPU cores allocated to Elasticsearch |
| `KIBANA_MEM_LIMIT` | `1g` | Hard RAM limit for Kibana |
| `KIBANA_CPU_LIMIT` | `1.0` | CPU cores for Kibana |
| `FLEET_MEM_LIMIT` | `512m` | Hard RAM limit for Fleet Server |
| `FLEET_CPU_LIMIT` | `0.5` | CPU cores for Fleet Server |

### 4.7 Elasticsearch Cluster Limits

#### Shard & Recovery

| Variable | Default | Description |
|---|---|---|
| `ES_MAX_SHARDS_PER_NODE` | `1000` | Maximum total shards this node can hold. Prevents runaway index creation. |
| `ES_RECOVERY_MAX_BYTES_PER_SEC` | `40mb` | Bandwidth cap for shard recovery. Prevents recovery from saturating the network. |

#### Circuit Breakers
Circuit breakers stop operations that would cause an OutOfMemoryError.

| Variable | Default | Description |
|---|---|---|
| `ES_CIRCUIT_BREAKER_REQUEST_LIMIT` | `60%` | Max heap a single request can use |
| `ES_CIRCUIT_BREAKER_TOTAL_LIMIT` | `70%` | Total heap all in-flight requests can use |
| `ES_CIRCUIT_BREAKER_FIELDDATA_LIMIT` | `40%` | Max heap used for fielddata (aggregations) |
| `ES_INDICES_FIELDDATA_CACHE_SIZE` | `20%` | Size of the fielddata cache (subset of heap) |

#### Disk Watermarks
Controls when Elasticsearch stops writing to protect disk space.

| Variable | Default | What happens |
|---|---|---|
| `ES_WATERMARK_LOW` | `85%` | Elasticsearch stops routing new shards to this node |
| `ES_WATERMARK_HIGH` | `90%` | Elasticsearch starts moving shards away from this node |
| `ES_WATERMARK_FLOOD_STAGE` | `95%` | All indices on this node become **read-only** |

> If an index is stuck in read-only after disk frees up, run:
> ```bash
> curl -sk -u elastic:$PASS https://localhost:9200/_all/_settings \
>   -H "Content-Type: application/json" \
>   -X PUT -d '{"index.blocks.read_only_allow_delete": null}'
> ```

#### Thread Pools

| Variable | Default | Description |
|---|---|---|
| `ES_THREADPOOL_WRITE_QUEUE` | `500` | Max queued write requests before rejecting |
| `ES_THREADPOOL_SEARCH_QUEUE` | `1000` | Max queued search requests before rejecting |

### 4.8 Fleet Server

| Variable | Default | Description |
|---|---|---|
| `FLEET_SERVER_POLICY` | `fleet-server-policy` | Fleet policy ID for the Fleet Server itself |
| `FLEET_SERVER_HOST` | `0.0.0.0` | Interface Fleet Server listens on |
| `ELK_SERVER_PUBLIC_IP` | `YOUR_ELK_SERVER_IP_OR_HOSTNAME` | **Must set this.** The IP/hostname remote agents use to reach Fleet Server. |

---

## 5. Starting the ELK Server

### Step 1 — Configure `.env`

```bash
cd elk/

# Edit the .env file
nano .env
```

Minimum required changes:
```bash
ELASTIC_PASSWORD=your_strong_password_here
KIBANA_SYSTEM_PASSWORD=another_strong_password
KIBANA_ENCRYPTION_KEY=a-random-string-of-at-least-32-chars
KIBANA_REPORTING_ENCRYPT_KEY=another-random-string-32-chars-min
ELK_SERVER_PUBLIC_IP=10.0.0.5        # your ELK server's IP or hostname
ES_JVM_HEAP=4g                       # ~50% of your RAM
ES_MEM_LIMIT=8g                      # ~2x the heap
```

### Step 2 — Run the setup script

```bash
chmod +x setup.sh
./setup.sh
```

The script will:
1. ✅ Validate all required environment variables
2. ✅ Check Docker and system requirements
3. ✅ Set `vm.max_map_count` on Linux (requires sudo)
4. ✅ Pull all Docker images
5. ✅ Start Elasticsearch, Kibana, and Fleet Server
6. ✅ Wait for all services to become healthy
7. ✅ Auto-generate a Fleet enrollment token and save it to `.env`
8. ✅ Apply cluster-level settings (watermarks, circuit breakers, thread pools)
9. ✅ Print a service summary table

### Step 3 — Access Kibana

Once complete, open:
```
https://<ELK_SERVER_IP>:5601
```

Login with:
- **Username:** `elastic`
- **Password:** the value of `ELASTIC_PASSWORD` in `.env`

> ⚠️ Your browser will warn about an untrusted certificate. This is expected — the cert is self-signed. Accept the exception to proceed.  
> For production, replace with a cert from Let's Encrypt or your CA.

---

## 6. Installing Elastic Agent on Remote Servers

Elastic Agent runs on each server you want to monitor — **not** on the ELK server itself.

### Step 1 — Get the Enrollment Token

In Kibana: **Management → Fleet → Enrollment Tokens → Create enrollment token**

Give it a meaningful name (e.g., `web-servers`, `app-servers`) and copy the token.



### Step 3 — Copy and Run `install-agent.sh`

```bash
# Copy the script to the remote server
scp install-agent.sh user@remote-server:/tmp/

# SSH into the remote server
ssh user@remote-server

# Run the installer
sudo bash /tmp/install-agent.sh \
  --fleet-url https://elk.kaushiksanil.bar:8220 \
  --token     AbCdEfGhIjKlMnOpQrStUvWxYz==
```

The script will:
1. Detect the OS and CPU architecture automatically (supports Ubuntu/Debian, RHEL/CentOS/Amazon Linux, macOS)
2. Download the correct Elastic Agent package
3. Install it via the system package manager (`dpkg`, `rpm`, or `tar`)
4. Enroll the agent with the Fleet Server using the provided token
5. Start and enable the `elastic-agent` systemd service

### Step 4 — Verify in Kibana

**Kibana → Management → Fleet → Agents**

The new agent should appear as **Healthy** within 30–60 seconds.

### `install-agent.sh` Options

| Flag | Required | Description |
|---|---|---|
| `--fleet-url` | **Required** | The public URL of the Fleet Server (e.g. `https://elk.domain.com:8220`) |
| `--token` | **Required** | Enrollment token from Kibana |
| `--version` | No | Elastic Agent version (default: matches `STACK_VERSION` in `.env`) |

---

## 7. Managing the Stack

### Start the stack
```bash
./setup.sh
```

### Stop the stack (data preserved)
```bash
./setup.sh --down
```

### Destroy everything — containers AND data
```bash
./setup.sh --clean
# ⚠️  This deletes all Elasticsearch data, Kibana saved objects, and certificates.
```

### View live logs
```bash
docker compose logs -f                    # all services
docker compose logs -f elasticsearch
docker compose logs -f kibana
docker compose logs -f fleet-server
```

### Restart a single service
```bash
docker compose restart kibana
docker compose restart elasticsearch
```

### Check service health
```bash
docker compose ps

# Elasticsearch cluster health
curl -sk -u elastic:$ELASTIC_PASSWORD \
  https://localhost:9200/_cluster/health?pretty

# Kibana status
curl -sk -u elastic:$ELASTIC_PASSWORD \
  https://localhost:5601/api/status | python3 -m json.tool
```

### Check remote agent status (on the remote server)
```bash
sudo elastic-agent status

# View agent logs
sudo journalctl -u elastic-agent -f
```

### Unenroll / uninstall agent (on the remote server)
```bash
sudo elastic-agent uninstall
```

---

## 8. Security Notes

### 8.1 TLS and Subject Alternative Names (SANs)

This is the most important thing to understand about TLS in this setup.

**The problem:** The ELK server uses a self-signed CA. By default, remote agents would need `--insecure` to connect to Fleet Server — meaning no certificate validation.

**The solution:** At cert generation time, `setup.sh` injects your server's **public IP** and/or **domain name** into every certificate as a SAN (Subject Alternative Name). This means:

- Agents connect to `https://elk.company.com:8220` or `https://10.0.0.5:8220`
- They verify the cert using `--certificate-authorities=ca.crt`
- TLS is fully verified. No `--insecure` needed.

**The two variables that control this:**

```bash
# In .env
ELK_SERVER_PUBLIC_IP=10.0.0.5          # IP of your ELK server
ELK_SERVER_DOMAIN=elk.mycompany.com    # domain pointing to ELK server
```

Both are optional individually, but **at least one must be set** for proper remote TLS.

| Scenario | What to set | Agent `--fleet-url` |
|---|---|---|
| Only have an IP | `ELK_SERVER_PUBLIC_IP=10.0.0.5` | `https://10.0.0.5:8220` |
| Have a domain | `ELK_SERVER_DOMAIN=elk.co.com` | `https://elk.co.com:8220` |
| Have both (recommended) | Set both | Use domain |

> ⚠️ **SAN values are baked into the certificate at first `./setup.sh` run.** If you change them later, you must regenerate certificates:
> ```bash
> ./setup.sh --clean     # destroys ALL data
> # Edit .env with new IP/domain
> ./setup.sh             # regenerates certs with new SANs
> ```
> If you want to keep your data, snapshot your indices before `--clean`.

### 8.2 What does the CA cert do?

The `ca.crt` file is the **Certificate Authority** — it tells agents "trust any cert signed by this CA". Since all ELK certs are signed by this CA:
- Agents with `ca.crt` → verify Fleet Server cert → full TLS ✅
- Agents without `ca.crt` → must use `--insecure` → no verification ❌

**Always copy `ca.crt` to remote servers before enrolling:**
```bash
scp user@elk-server:/path/to/elk/config/certs/ca/ca.crt /tmp/elk-ca.crt
```

### 8.3 Other Security Notes

| Topic | Detail |
|---|---|
| **Passwords** | Change `ELASTIC_PASSWORD` and `KIBANA_SYSTEM_PASSWORD` before production |
| **Encryption keys** | `KIBANA_ENCRYPTION_KEY` and `KIBANA_REPORTING_ENCRYPT_KEY` must be ≥ 32 chars. Changing them makes all saved objects unreadable. |
| **`.env` file** | Never commit to version control — contains all secrets |
| **`config/certs/ca.key`** | Never share or commit the private key |
| **Firewall** | Expose only `5601` (Kibana) and `8220` (Fleet) externally. Never expose `9300` (transport). |
| **Production CA** | For proper production, replace self-signed certs with Let's Encrypt or your internal PKI. See [Elastic TLS docs](https://www.elastic.co/guide/en/elasticsearch/reference/current/security-basic-setup-https.html). |


---

## 9. Resource Limits Explained

### Why lock JVM heap (`-Xms == -Xmx`)?

Setting minimum and maximum heap to the **same value** prevents the JVM from dynamically resizing the heap, which causes GC pauses. This is the official Elastic recommendation.

### Why `bootstrap.memory_lock=true`?

This tells the OS not to swap the JVM heap to disk. Swapping causes severe Elasticsearch performance degradation and can cause cluster instability.

### Why do circuit breakers exist?

Without circuit breakers, a large aggregation query could load the entire fielddata into memory and crash Elasticsearch with an OOM error. Circuit breakers reject the request early with a `429` instead.

### Recommended sizing

| RAM | `ES_JVM_HEAP` | `ES_MEM_LIMIT` | `KIBANA_MEM_LIMIT` |
|---|---|---|---|
| 4 GB | `1g` | `2g` | `1g` |
| 8 GB | `3g` | `6g` | `1g` |
| 16 GB | `6g` | `12g` | `2g` |
| 32 GB | `14g` | `28g` | `2g` |
| 64 GB | `30g` | `60g` | `4g` |

> Never exceed `31g` for `ES_JVM_HEAP`.

---

## 10. Troubleshooting

### Elasticsearch fails to start

**Symptom:** Container exits immediately.  
**Check logs:**
```bash
docker compose logs elasticsearch | tail -50
```

**Common causes:**
- `vm.max_map_count` too low (Linux only) → run `sudo sysctl -w vm.max_map_count=262144`
- Heap too large for available RAM → reduce `ES_JVM_HEAP`
- Port `9200` already in use → change `ES_PORT` in `.env`

---

### Kibana shows "Kibana server is not ready yet"

**Wait** — Kibana takes 60–120 seconds after Elasticsearch is healthy. If it doesn't recover:
```bash
docker compose logs kibana | tail -50
```
- Encryption key too short → check `KIBANA_ENCRYPTION_KEY` is ≥ 32 chars
- Wrong `KIBANA_SYSTEM_PASSWORD` → re-run `./setup.sh` (it resets the password)

---

### Remote agent can't connect to Fleet Server

**Check:**
1. Port `8220` is open on the ELK server firewall
2. `ELK_SERVER_PUBLIC_IP` in `.env` is correct and reachable from the remote server
3. The Fleet URL is accessible from the remote server

**Test connectivity from the remote server:**
```bash
curl -sk https://<ELK_SERVER_IP>:8220/api/status
# Should return: {"name":"fleet-server","status":"HEALTHY",...}
```

---

### Index is read-only (disk full)

When disk hits `ES_WATERMARK_FLOOD_STAGE` (default: 95%), Elasticsearch makes all indices read-only.

**Fix:**
```bash
# 1. Free up disk space on the ELK server

# 2. Re-enable writes
curl -sk -u elastic:$ELASTIC_PASSWORD \
  -X PUT https://localhost:9200/_all/_settings \
  -H "Content-Type: application/json" \
  -d '{"index.blocks.read_only_allow_delete": null}'
```

---

### Forget the elastic password

```bash
# Reset from inside the Elasticsearch container
docker exec -it elasticsearch \
  bin/elasticsearch-reset-password -u elastic --batch

# Or set a specific password
docker exec -it elasticsearch \
  bin/elasticsearch-reset-password -u elastic -i
```

---

### Useful API commands

```bash
# Shortcut — set these in your shell
export ES="https://localhost:9200"
export AUTH="-u elastic:$(grep ELASTIC_PASSWORD .env | cut -d= -f2)"
export CA="--cacert config/certs/ca/ca.crt"

# Cluster health
curl -sk $CA $AUTH $ES/_cluster/health?pretty

# Current cluster settings
curl -sk $CA $AUTH $ES/_cluster/settings?pretty&flat_settings=true

# Node stats (JVM, heap, GC)
curl -sk $CA $AUTH $ES/_nodes/stats/jvm?pretty

# Index list with sizes
curl -sk $CA $AUTH "$ES/_cat/indices?v&s=store.size:desc"

# Shard allocation
curl -sk $CA $AUTH "$ES/_cat/shards?v"

# Check disk usage
curl -sk $CA $AUTH "$ES/_cat/allocation?v"
```
