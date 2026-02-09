# ExClamavServer

A scalable REST API server for virus scanning powered by [ExClamav](https://github.com/csokun/ex_clamav). Designed for multi-instance deployment on Kubernetes (EKS) with shared state and shared volumes.

## Architecture

```
                    ┌─────────────┐
                    │   AWS ALB   │
                    │  (Ingress)  │
                    └──────┬──────┘
                           │
              ┌────────────┼────────────┐
              │            │            │
        ┌─────▼────┐  ┌────▼─────┐ ┌────▼─────┐
        │  Pod 0   │  │  Pod 1   │ │  Pod N   │
        │  Bandit  │  │  Bandit  │ │  Bandit  │
        │  ClamAV  │  │  ClamAV  │ │  ClamAV  │
        │  Engine  │  │  Engine  │ │  Engine  │
        └────┬─────┘  └────┬─────┘ └────┬─────┘
             │             │            │
     ┌───────┴─────────────┴────────────┴───────┐
     │           Shared Volumes (EFS)           │
     │  ┌──────────────┐  ┌──────────────────┐  │
     │  │ /var/lib/    │  │ /data/uploads/   │  │
     │  │   clamav/    │  │                  │  │
     │  │ (virus defs) │  │ (uploaded files) │  │
     │  └──────────────┘  └──────────────────┘  │
     └──────────────────────────────────────────┘
                           │
                    ┌──────▼──────┐
                    │ PostgreSQL  │
                    │ (scan jobs) │
                    └─────────────┘
```

### Key Design Decisions

| Concern | Solution | Rationale |
|---|---|---|
| **Shared scan state** | PostgreSQL | All instances read/write scan job records; atomic claim prevents duplicate scans |
| **Uploaded files** | EFS (ReadWriteMany) | All pods access the same uploaded files for scanning |
| **Virus definitions** | EFS (ReadWriteMany) | One `freshclam` update is visible to all pods; avoids redundant downloads |
| **Duplicate scan prevention** | `UPDATE ... WHERE status='pending'` | Atomic row-level claim ensures exactly one instance scans each file |
| **Engine hot-reload** | `DefinitionUpdater` + `ClamavGenServer` auto-reload | When `freshclam` updates definitions, each pod's engine reloads without downtime |
| **Async scanning** | `Task.Supervisor` | File scanning runs in supervised background tasks; upload returns immediately |

## API Reference

### POST /upload

Upload a file for virus scanning. The file is stored on the shared volume, a scan job is created in PostgreSQL, and an async scan is triggered.

**Request:**

```bash
curl -X POST http://localhost:4000/upload \
  -F "file=@/path/to/document.pdf"
```

**Response (202 Accepted):**

```json
{
  "status": "ok",
  "data": {
    "reference_id": "scan_a1b2c3d4e5f6789012345678abcdef01",
    "original_filename": "document.pdf",
    "file_size": 1048576,
    "status": "pending",
    "created_at": "2025-01-15T10:30:00.000000Z"
  }
}
```

**Error responses:**

| Status | Code | Cause |
|---|---|---|
| 400 | `bad_request` | No file uploaded, empty file, or missing filename |
| 413 | `payload_too_large` | File exceeds maximum upload size (default: 100 MB) |
| 500 | `internal_error` | Storage or database failure |

### GET /upload/:reference_id

Query the scan status and result for a previously uploaded file.

**Request:**

```bash
curl http://localhost:4000/upload/scan_a1b2c3d4e5f6789012345678abcdef01
```

**Response — scan in progress (200 OK):**

```json
{
  "status": "ok",
  "data": {
    "reference_id": "scan_a1b2c3d4e5f6789012345678abcdef01",
    "original_filename": "document.pdf",
    "file_size": 1048576,
    "status": "in_progress",
    "created_at": "2025-01-15T10:30:00.000000Z"
  }
}
```

**Response — scan completed, file is clean (200 OK):**

```json
{
  "status": "ok",
  "data": {
    "reference_id": "scan_a1b2c3d4e5f6789012345678abcdef01",
    "original_filename": "document.pdf",
    "file_size": 1048576,
    "status": "completed",
    "result": "clean",
    "created_at": "2025-01-15T10:30:00.000000Z"
  }
}
```

**Response — virus detected (200 OK):**

```json
{
  "status": "ok",
  "data": {
    "reference_id": "scan_a1b2c3d4e5f6789012345678abcdef01",
    "original_filename": "malware.exe",
    "file_size": 2048,
    "status": "completed",
    "result": "virus_found",
    "virus_name": "Win.Test.EICAR_HDB-1",
    "created_at": "2025-01-15T10:30:00.000000Z"
  }
}
```

**Response — scan failed (200 OK):**

```json
{
  "status": "ok",
  "data": {
    "reference_id": "scan_a1b2c3d4e5f6789012345678abcdef01",
    "original_filename": "broken.bin",
    "file_size": 512,
    "status": "failed",
    "error_message": "File not found: /data/uploads/scan_.../broken.bin",
    "created_at": "2025-01-15T10:30:00.000000Z"
  }
}
```

**Error responses:**

| Status | Code | Cause |
|---|---|---|
| 404 | `not_found` | No scan job found for the given `reference_id` |

### GET /health

Returns service health information including virus definition version, uptime, and instance identity. Used by Kubernetes probes.

**Request:**

```bash
curl http://localhost:4000/health
```

**Response (200 OK if healthy, 503 if unhealthy):**

```json
{
  "status": "ok",
  "data": {
    "healthy": true,
    "uptime_seconds": 3661,
    "uptime_human": "1h 1m 1s",
    "clamav": {
      "library_version": "1.4.2",
      "database_version": "main.cvd, daily.cvd, bytecode.cvd",
      "last_definition_update": "2025-01-15T09:00:00.000000Z",
      "last_update_result": "up_to_date",
      "update_interval_seconds": 3600
    },
    "instance": "ex-clamav-server-0@nonode@nohost"
  }
}
```

## Scan Job Lifecycle

```
  POST /upload
       │
       ▼
   ┌─────────┐    Task.Supervisor    ┌─────────────┐
   │ pending │ ──── spawns task ───▶ │ in_progress │
   └─────────┘    (atomic claim)     └──────┬──────┘
                                            │
                                   ClamAV scan_file()
                                            │
                             ┌──────────────┼──────────────┐
                             │              │              │
                             ▼              ▼              ▼
                      ┌───────────┐  ┌─────────────┐  ┌────────┐
                      │ completed │  │ completed   │  │ failed │
                      │  (clean)  │  │(virus_found)│  │        │
                      └───────────┘  └─────────────┘  └────────┘
```

## Local Development

### Prerequisites

- Elixir 1.18+ / Erlang/OTP 28+
- PostgreSQL 14+
- ClamAV development libraries (`libclamav-dev`)
- ClamAV virus definitions in `/var/lib/clamav`
- `freshclam` binary (for auto-updates)

### Setup

```bash
# Install ClamAV (Ubuntu/Debian)
sudo apt-get install -y libclamav-dev clamav clamav-freshclam

# Download initial virus definitions
sudo freshclam --datadir=/tmp/ex_clamav_server_db

# Navigate to the server directory
cd examples/ex_clamav_server

# Install dependencies
mix deps.get

# Create and migrate the database
mix ecto.setup

# Start the server
mix run --no-halt
```

The server will be available at `http://localhost:4000`.

### Quick Test

```bash
# Upload a file for scanning
curl -X POST http://localhost:4000/upload -F "file=@/etc/hostname"

# Check the result (replace with your reference_id)
curl http://localhost:4000/upload/scan_abc123...

# Health check
curl http://localhost:4000/health

# Test with EICAR test virus
echo 'X5O!P%@AP[4\PZX54(P^)7CC)7}$EICAR-STANDARD-ANTIVIRUS-TEST-FILE!$H+H*' > /tmp/eicar.txt
curl -X POST http://localhost:4000/upload -F "file=@/tmp/eicar.txt"
```

## Docker

A `docker-compose.yml` is provided in `examples/ex_clamav_server/` that starts PostgreSQL and the server together.

### Build & Run

```bash
# From examples/ex_clamav_server/
docker compose up --build
```

This will:
1. Build the server image from the repository root (the build context points to `../../`)
2. Start PostgreSQL 16 with a health check
3. Wait for PostgreSQL to be healthy, then start the server (runs migrations automatically on boot)

To run in the background:

```bash
docker compose up --build -d
```

To stop and remove containers:

```bash
docker compose down
```

To stop and also remove the named volumes (database data, virus definitions, uploads):

```bash
docker compose down -v
```

### Build Only

If you only need to build the image without starting services:

```bash
docker compose build
```

Or build directly with `docker build` from the **repository root**:

```bash
# From the repository root (clamav_ex/)
docker build -f examples/ex_clamav_server/Dockerfile -t ex-clamav-server:latest .
```

### Environment Variables

| Variable | Default | Description |
|---|---|---|
| `DATABASE_URL` | *required* | Ecto database URL (e.g., `ecto://user:pass@host:5432/db`) |
| `PORT` | `4000` | HTTP listen port |
| `CLAMAV_DB_PATH` | `/var/lib/clamav` | Path to ClamAV virus definition database |
| `UPLOAD_PATH` | `/data/uploads` | Path to store uploaded files for scanning |
| `CLAMAV_UPDATE_INTERVAL_HOURS` | `1` | Hours between `freshclam` update checks |
| `CLAMAV_UPDATE_ON_START` | `true` | Run `freshclam` on application start |
| `FRESHCLAM_CONFIG` | *(none)* | Optional path to a custom `freshclam.conf` |
| `POOL_SIZE` | `20` | Database connection pool size per instance |
| `DATABASE_SSL` | `false` | Enable SSL for database connections |
| `DATABASE_IPV6` | `false` | Use IPv6 for database connections |
| `LOG_LEVEL` | `info` | Log level: `debug`, `info`, `warning`, `error` |
| `MAX_UPLOAD_SIZE` | `104857600` | Maximum upload size in bytes (100 MB) |

### Entrypoint Commands

The Docker entrypoint supports several commands:

```bash
# Default: run migrations and start the server (what docker compose up does)
docker compose up

# Start with IEx console attached
docker compose run --rm ex-clamav-server start_iex

# Run migrations only (useful as a Kubernetes Job)
docker compose run --rm ex-clamav-server migrate

# Run freshclam only
docker compose run --rm ex-clamav-server freshclam

# Evaluate an Elixir expression
docker compose run --rm ex-clamav-server eval "ExClamavServer.Release.migrate()"

# Connect a remote IEx console to a running instance
docker compose exec ex-clamav-server /app/bin/ex_clamav_server remote
```

## Kubernetes Deployment (EKS)

### Prerequisites

1. **EKS cluster** with the [EFS CSI Driver](https://docs.aws.amazon.com/eks/latest/userguide/efs-csi.html) installed
2. **EFS filesystem** created and accessible from the cluster VPC
3. **EFS StorageClass** named `efs-sc` (or override in `values.yaml`)
4. **Container image** pushed to ECR or another registry accessible from the cluster
5. **Helm 3** installed locally

### Why StatefulSet + EFS?

| Requirement | Solution |
|---|---|
| Stable pod identity | StatefulSet gives each pod a predictable hostname (`ex-clamav-server-0`, `-1`, etc.) |
| Shared uploaded files | EFS PVC with `ReadWriteMany` — all pods see the same `/data/uploads` |
| Shared virus definitions | EFS PVC with `ReadWriteMany` — one `freshclam` update is visible to all pods |
| Shared scan state | PostgreSQL — any instance can create/read/update scan jobs |
| No duplicate scans | Atomic `UPDATE ... WHERE status='pending'` ensures exactly one pod claims each job |

> **Is sharing safe?** Yes — virus definition files (`.cvd`/`.cld`) are written atomically by `freshclam`. The ClamAV engine loads them once during `load_database`, so there's no risk of reading a partially-written file. Each pod's `DefinitionUpdater` detects changes via fingerprinting and reloads its own engine independently. Uploaded files are written once and read once (for scanning), so concurrent access is not a concern.

### Volume Scaling Evaluation

| Volume Type | Access Mode | Use Case | Scaling Behavior |
|---|---|---|---|
| **EFS** (`efs-sc`) | ReadWriteMany | Virus DB + Uploads | All pods share one volume. Scales horizontally. |
| **EBS** (`gp3`) | ReadWriteOnce | Per-pod local storage | Each pod gets its own volume. Requires per-pod `freshclam`. |
| **emptyDir** | N/A (ephemeral) | Temporary/test | Lost on pod restart. Not suitable for production. |

**Recommendation:** Use **EFS for both volumes** in production. This gives you:
- Single `freshclam` update visible to all pods (lower bandwidth, no redundant downloads)
- Uploaded files accessible from any pod (required for the scan-anywhere architecture)
- Horizontal scaling without volume bottlenecks

### Install

```bash
cd examples/ex_clamav_server/helm

# Add the Bitnami repo for the PostgreSQL subchart
helm repo add bitnami https://charts.bitnami.com/bitnami
helm repo update

# Update subchart dependencies
helm dependency update ex-clamav-server

# Install with default values (2 replicas, built-in PostgreSQL)
helm install clamav ex-clamav-server \
  --namespace clamav-system \
  --create-namespace \
  --set image.repository=<your-ecr-repo>/ex-clamav-server \
  --set image.tag=latest
```

### Install with Custom Values

Create a `my-values.yaml`:

```yaml
replicaCount: 3

image:
  repository: 123456789.dkr.ecr.us-east-1.amazonaws.com/ex-clamav-server
  tag: "0.1.0"

config:
  clamavUpdateIntervalHours: "2"
  logLevel: info

persistence:
  uploads:
    storageClass: "efs-sc"
    size: 100Gi
  clamavDb:
    storageClass: "efs-sc"
    size: 5Gi

resources:
  requests:
    cpu: "1"
    memory: 1Gi
  limits:
    cpu: "4"
    memory: 4Gi

ingress:
  enabled: true
  className: alb
  annotations:
    alb.ingress.kubernetes.io/scheme: internet-facing
    alb.ingress.kubernetes.io/target-type: ip
    alb.ingress.kubernetes.io/healthcheck-path: /health
  hosts:
    - host: clamav-api.example.com
      paths:
        - path: /
          pathType: Prefix

postgresql:
  auth:
    postgresPassword: "super-secret-password"
    username: "ex_clamav_server"
    password: "super-secret-password"
    database: "ex_clamav_server_prod"
  primary:
    persistence:
      size: 20Gi

autoscaling:
  enabled: true
  minReplicas: 2
  maxReplicas: 8
  targetCPUUtilizationPercentage: 70
```

```bash
helm install clamav ex-clamav-server \
  --namespace clamav-system \
  --create-namespace \
  -f my-values.yaml
```

### Using an External Database

If you have an existing PostgreSQL (e.g., Amazon RDS), disable the subchart:

```yaml
postgresql:
  enabled: false

existingDatabaseSecret: "my-rds-secret"
existingDatabaseSecretKey: "DATABASE_URL"
```

Create the secret:

```bash
kubectl create secret generic my-rds-secret \
  --namespace clamav-system \
  --from-literal=DATABASE_URL="ecto://user:pass@my-rds.cluster-xxx.us-east-1.rds.amazonaws.com:5432/ex_clamav_server_prod"
```

### Upgrading

```bash
helm upgrade clamav ex-clamav-server \
  --namespace clamav-system \
  -f my-values.yaml
```

### Uninstalling

```bash
helm uninstall clamav --namespace clamav-system

# Optionally clean up PVCs
kubectl delete pvc -n clamav-system -l app.kubernetes.io/name=ex-clamav-server
```

## Supervision Tree

```
ExClamavServer.Supervisor (rest_for_one)
├── ExClamavServer.Repo                    — Ecto/PostgreSQL connection pool
├── ExClamavServer.DefinitionUpdater       — Periodic freshclam + pub/sub
├── ExClamavServer.ScanEngine              — ClamAV NIF engine (auto-reload)
├── ExClamavServer.ScanTaskSupervisor      — Task.Supervisor for async scans
└── Bandit (HTTP)                          — Plug router on port 4000
```

The `rest_for_one` strategy ensures that if the definition updater or scan engine crashes, all downstream children (including the HTTP server) are restarted in order.

## Project Structure

```
examples/ex_clamav_server/
├── config/
│   ├── config.exs              # Base configuration
│   ├── dev.exs                 # Development overrides
│   ├── prod.exs                # Production compile-time config
│   ├── runtime.exs             # Runtime config from environment variables
│   └── test.exs                # Test configuration
├── helm/
│   └── ex-clamav-server/
│       ├── Chart.yaml           # Helm chart metadata
│       ├── values.yaml          # Default values
│       └── templates/
│           ├── _helpers.tpl     # Template helper functions
│           ├── configmap.yaml   # Application configuration
│           ├── hpa.yaml         # Horizontal Pod Autoscaler
│           ├── ingress.yaml     # Ingress (ALB)
│           ├── pdb.yaml         # Pod Disruption Budget
│           ├── pvc.yaml         # Persistent Volume Claims (EFS)
│           ├── secret.yaml      # Database credentials
│           ├── service.yaml     # ClusterIP + headless services
│           ├── serviceaccount.yaml
│           └── statefulset.yaml # Main workload
├── lib/
│   ├── ex_clamav_server.ex             # Top-level module (uptime, paths)
│   └── ex_clamav_server/
│       ├── application.ex              # OTP Application & supervision tree
│       ├── release.ex                  # Release tasks (migrate, rollback)
│       ├── repo.ex                     # Ecto Repo
│       ├── router.ex                   # Plug Router (API endpoints)
│       ├── scan_job.ex                 # Ecto schema & query helpers
│       ├── scan_worker.ex              # Async scan task logic
│       └── upload_handler.ex           # File upload processing
├── priv/
│   └── repo/
│       └── migrations/
│           └── 20250101000000_create_scan_jobs.exs
├── Dockerfile                  # Multi-stage build
├── docker-entrypoint.sh        # Container entrypoint
├── mix.exs                     # Project definition
└── README.md                   # This file
```

## License

Same as the parent [ExClamav](https://github.com/csokun/ex_clamav) project — GPL-2.0-only.
