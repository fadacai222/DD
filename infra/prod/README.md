# DD Production Self-host

This directory is the production single-host Compose baseline for U20-U23. It is intentionally separate from `infra/dev/` and does not reuse Mailpit, wildcard CORS, public database ports, or development secrets.

## 1. Topology

```text
Internet
  |
  +-- TCP 80 ------------------------------> Caddy (ACME HTTP challenge / redirect)
  |
  +-- TCP 443 --> HAProxy SNI mux
  |                |
  |                +-- turn.example.com ---> LiveKit embedded TURN/TLS :443
  |                |
  |                +-- all other SNI ------> Caddy :443
  |                                           +-- api.example.com   -> DD API :18473
  |                                           +-- rtc.example.com   -> LiveKit signal :7880 (WSS)
  |                                           +-- media.example.com -> MinIO :9000 (selfhost-storage mode only)
  |
  +-- UDP 443 ------------------------------> LiveKit TURN/UDP
  +-- TCP 7881 -----------------------------> LiveKit ICE/TCP
  +-- UDP 50000-50100 (configurable) -------> LiveKit ICE/UDP

Internal Compose network only:
  DD API <-> PostgreSQL
  DD API <-> Redis
  DD API/Worker <-> S3/MinIO
  DD API <-> LiveKit
  Worker <-> PostgreSQL/S3
```

PostgreSQL, Redis, MinIO Console, API port 18473, and LiveKit signal port 7880 are **not** published directly on the host.

TCP/443 is shared safely by TLS SNI in the default `DD_INGRESS_MODE=caddy` topology: the TURN hostname is passed through to LiveKit so LiveKit owns the TURN certificate; normal HTTPS/WSS is passed through to Caddy. UDP/443 is deliberately reserved for TURN/UDP, so this baseline does not enable HTTP/3/QUIC on Caddy.

A second supported topology is `DD_INGRESS_MODE=bt-nginx`, intended for Debian hosts where BaoTa/Nginx already owns TCP 80/443. It loads `compose.bt.yml`, does not start DD Caddy/HAProxy, binds API/LiveKit signaling/MinIO only to loopback high ports, and exposes TURN/UDP + TURN/TLS on configurable non-443 ports (the provided BaoTa template uses `3478/UDP` and `5349/TCP`). See `docs/runbooks/bt-panel-production.md`.

LiveKit's embedded TURN does not expose plain TURN/TCP. In the default topology the fallback chain is ICE/UDP -> TURN/UDP -> ICE/TCP (`7881`) -> TURN/TLS (`443/TCP`); BaoTa mode uses the configured TURN ports instead. A deployment that specifically requires plain TURN/TCP must add an external TURN implementation such as Coturn and explicitly configure LiveKit `turn_servers`; that optional topology is not silently enabled here.

## 2. Required host/network

Use a Linux production host with Docker Engine + Docker Compose v2. The host needs a real inbound-reachable public IPv4 address. If the machine is behind a router/NAT, forward every public port listed below to this host. A CGNAT-only connection is not sufficient for inbound RTC without an upstream public relay/edge. LiveKit is configured with `use_external_ip: true`; if a valid NAT mapping does not permit LiveKit's self-ping validation, `DD_LIVEKIT_SKIP_EXTERNAL_IP_VALIDATION=true` is available, but only after `DD_PUBLIC_IP` and the forwarding rules are independently verified.

Create DNS A records pointing to `DD_PUBLIC_IP`:

- `DD_API_DOMAIN`
- `DD_LIVEKIT_DOMAIN`
- `DD_TURN_DOMAIN`
- `DD_S3_DOMAIN` when using bundled MinIO

Required inbound firewall/security-group rules depend on ingress mode.

Default Caddy/HAProxy mode:

| Port | Protocol | Purpose |
|---|---|---|
| 80 | TCP | Caddy ACME HTTP challenge / redirect |
| 443 | TCP | HTTPS, WSS, and TURN/TLS selected by SNI |
| 443 | UDP | TURN/UDP fallback |
| 7881 | TCP | LiveKit ICE/TCP fallback |
| `DD_RTC_UDP_PORT_START..END` | UDP | LiveKit ICE media; default `50000..50100` |

BaoTa/Nginx coexistence mode keeps Nginx on TCP 80/443 and adds only `DD_TURN_UDP_PORT` (default template `3478/UDP`), `DD_TURN_TLS_PORT` (default template `5349/TCP`), TCP 7881, and the configured RTC UDP range. API/RTC/MinIO reverse-proxy backends bind to `127.0.0.1` only.

Do **not** open PostgreSQL 5432, Redis 6379, MinIO 9000/9001, LiveKit 7880, or API 18473 to the public Internet for this topology.

## 3. Configure

```bash
cd /opt/dd/infra/prod
cp .env.example .env
```

For BaoTa/Nginx coexistence, use the helper instead:

```bash
bash scripts/prepare-bt.sh your-domain.tld YOUR_PUBLIC_IP your@email.tld
```

It creates `.env` from `.env.bt.example` with separate `api/rtc/turn/media` hostnames and safe high-port defaults.

Edit `.env` and replace every example domain/IP **and** the placeholder release values. Use an immutable release/image tag, for example `DD_RELEASE_VERSION=0.9.0` and `DD_IMAGE_TAG=v0.9.0`; `dev` and `latest` are rejected. `preflight.sh` deliberately rejects `example.com`, RFC1918/CGNAT addresses, documentation IP ranges, and development image tags so the template cannot accidentally pass as production configuration.

Choose object storage mode:

### Bundled MinIO

```dotenv
DD_OBJECT_STORAGE_MODE=minio
DD_S3_DOMAIN=media.your-domain.tld
DD_CADDYFILE=./Caddyfile.minio
DD_MEDIA_S3_ENDPOINT=https://media.your-domain.tld
DD_MEDIA_S3_BUCKET=dd-media
DD_BACKUP_S3_ENDPOINT=http://minio:9000
```

The server uses the same S3 endpoint for presigned client URLs and server-side HEAD/DELETE requests. Caddy receives an internal Docker DNS alias for `DD_S3_DOMAIN`, avoiding dependence on NAT hairpin routing from API containers back to the host's public address.

Bundled MinIO enables bucket versioning, keeps the bucket private, and creates separate application and backup users. The shipped least-privilege policies currently target bucket `dd-media`; preflight therefore rejects a different bundled bucket name.

### External S3-compatible storage

```dotenv
DD_OBJECT_STORAGE_MODE=external-s3
DD_CADDYFILE=./Caddyfile.external-s3
DD_MEDIA_S3_ENDPOINT=https://s3-provider.example
DD_BACKUP_S3_ENDPOINT=https://s3-provider.example
```

Use two real credential pairs: `media_s3_*` for normal object access and `backup_s3_*` for backup/restore. The external provider must support the S3 operations DD uses and should have versioning/replication enabled according to your DR requirements.

## 4. Secrets

Generate non-provider secrets without committing them:

```bash
bash scripts/init-secrets.sh
```

Real secrets live under `infra/prod/secrets/`, which is deny-by-default in Git. See `secrets/README.md` for the full inventory.

`init-secrets.sh` never overwrites an existing non-empty secret. In external-S3 mode, S3 credentials are left for the operator to supply.

### TURN/TLS certificate

Install a publicly trusted certificate and matching key for exactly `DD_TURN_DOMAIN`:

```text
secrets/turn_cert.pem
secrets/turn_key.pem
```

A self-signed certificate is intentionally **not** generated as a production fallback. Certificate renewal is an operator responsibility; `preflight.sh` checks hostname coverage, key match, and rejects a certificate expiring within 24 hours.

Caddy obtains/renews certificates for API/RTC/MinIO hostnames. The TURN hostname is not terminated by Caddy, so its certificate must be renewed separately by your ACME/certificate workflow.

## 5. Preflight and first deploy

```bash
bash scripts/preflight.sh
bash scripts/deploy.sh
```

Preflight validates:

- required domains/public IP and non-wildcard HTTPS origins;
- required secret files and minimum secret lengths;
- TURN certificate hostname, expiry, and private-key match;
- backup interval <= configured RPO;
- RTC public port range;
- Docker Compose model;
- selected Caddy configuration;
- HAProxy SNI routing configuration;
- LiveKit production port configuration.

`deploy.sh` is for a **first installation**. If an API container is already running it refuses to proceed; existing installations must use `upgrade.sh`.

After DNS and certificates are live:

```bash
bash scripts/deployment-check.sh --public
```

This checks DD live/readiness, public HTTPS, LiveKit TLS ingress, and the TURN/TLS TCP/443 certificate/SNI route. It cannot prove carrier UDP/NAT behavior from the server itself.

## 6. Controlled restart

Only stateless/front-door services are accepted by the convenience restart command:

```bash
bash scripts/restart.sh api worker
bash scripts/restart.sh livekit
bash scripts/restart.sh caddy tls-mux
```

The script refuses PostgreSQL/Redis/MinIO one-line restarts because stateful maintenance needs an explicit procedure.

Every long-running service has a restart policy and bounded Docker JSON-file logs. API/Worker run read-only, non-root, with all Linux capabilities dropped. PostgreSQL/Redis/MinIO/LiveKit/API/Worker/Caddy/HAProxy have health/liveness checks appropriate to their role and configurable CPU/memory ceilings.

## 7. Backup / retention / RPO / RTO

Defaults in `.env.example`:

```dotenv
DD_BACKUP_INTERVAL_HOURS=6
DD_BACKUP_RETENTION_DAYS=14
DD_RPO_HOURS=6
DD_RTO_HOURS=4
DD_BACKUP_ROOT=./backups
```

These are policy targets, **not performance guarantees**. RTO must be measured against your real database/object volume and hardware. `DD_BACKUP_INTERVAL_HOURS` is the cadence of the formal **quiesced cross-system DR recovery point**, and `DD_RPO_HOURS` is only supportable when those quiesced jobs actually complete successfully at that cadence. `preflight.sh` fails if the configured DR recovery-point interval is longer than the configured RPO.

For actual DR, `DD_BACKUP_ROOT` must be on encrypted storage independent of the application data disk, or verified backup sets must be copied off-host. Keeping backups only on the same physical disk as PostgreSQL/MinIO is not disaster recovery.

Online backup (low-downtime supplementary copy only):

```bash
bash scripts/backup.sh
```

Quiesced cross-system recovery point:

```bash
bash scripts/backup.sh --quiesce
```

The quiesced mode is the formal DR recovery-point mode. It stops API/Worker writers while taking the PostgreSQL dump and object mirror, so the database and object-store copy represent one bounded cross-system recovery point. Upgrade uses this mode automatically and restarts writers on completion/failure unless the caller explicitly owns the following maintenance phase.

`backup.sh` without `--quiesce` is intentionally marked `CONSISTENCY_MODE=online-db-first`. Because PostgreSQL is dumped before the object mirror while writers can continue changing both systems, that online copy **must not** be used to claim a strict cross-DB/Object RPO. Running online copies more frequently can reduce operational loss in some failures, but their frequency does not redefine `DD_BACKUP_INTERVAL_HOURS` or `DD_RPO_HOURS`.

Each backup set contains:

- PostgreSQL custom-format dump;
- migration status snapshot;
- current object-store mirror;
- source object listing;
- a snapshot of the non-secret production `.env` (`config.env`);
- non-secret recovery manifest;
- SHA-256 checksums.

Secret files are intentionally **not** copied into ordinary backup sets. Keep an independent encrypted/secret-manager backup of the files listed in `secrets/README.md`; a DR restore without those credentials cannot recreate the original cryptographic identity/integrations.

A backup is only accepted after `verify-backup.sh` strictly parses the data-only manifest, validates every checksum, and confirms `pg_restore --list` can parse the dump. The manifest is never sourced as shell code: unknown/duplicate keys, shell syntax, invalid IDs/timestamps/schema metadata, or other malformed fields make verification and restore fail closed. Retention runs only after the new backup passes verification.

The default six-hour **formal DR recovery-point** cron schedule is:

```cron
15 */6 * * * cd /opt/dd/infra/prod && /usr/bin/bash scripts/backup.sh --quiesce >> /var/log/dd-backup.log 2>&1
```

If you change this quiesced schedule, update `DD_BACKUP_INTERVAL_HOURS` to match the actual successful DR recovery-point cadence. Do not claim an RPO from `.env`, from an online-only backup schedule, or from a failed/unchecked cron run.

## 8. Restore

First verify the selected recovery point:

```bash
bash scripts/verify-backup.sh /opt/dd/infra/prod/backups/<backup-id>
```

Normal restore creates another verified safety backup first. Destructive restore requires an exact domain + backup-ID confirmation string:

```bash
bash scripts/restore.sh \
  --backup /opt/dd/infra/prod/backups/<backup-id> \
  --confirm 'RESTORE:api.your-domain.tld:<backup-id>'
```

Restore behavior:

1. verify the selected backup;
2. create a pre-restore safety backup unless explicitly in empty-target/failed-upgrade recovery mode;
3. stop API/Worker/RTC/ingress writers;
4. recreate the PostgreSQL database and restore the custom dump;
5. mirror the selected object backup to the target and remove target objects outside that recovery point;
6. run current `migrate status`, then **forward-only `migrate up`** if the recovery point is older;
7. restart services and run deployment checks.

The production restore script never invokes `migrate down`.

For a brand-new disaster target where no prior target data needs preservation:

```bash
bash scripts/restore.sh \
  --backup /opt/dd/infra/prod/backups/<backup-id> \
  --confirm 'RESTORE:api.your-domain.tld:<backup-id>' \
  --disaster-empty-target
```

## 9. Safe restore drill

This drill uses isolated temporary Docker containers, networks, and named volumes. It does **not** touch production volumes:

```bash
bash scripts/restore-drill.sh
```

The drill:

1. builds the real current DD migrate image;
2. applies the real migrations to a temporary PostgreSQL database;
3. writes database and MinIO evidence;
4. creates DB/object backups;
5. destroys both source containers **and their source data volumes**;
6. restores into brand-new PostgreSQL/MinIO volumes;
7. checks database evidence, object evidence, and migration status;
8. removes all drill containers/networks/volumes/images through an EXIT trap.

Run this after material backup tooling changes and periodically as an operational DR exercise.

## 10. N -> N+1 upgrade and rollback

Production migration policy is defined in `compatibility-policy.json`:

```text
backup
-> N+1 migrate status against N schema (preflight compatibility)
-> quiesced verified recovery point
-> N+1 migrate up (forward only)
-> N+1 migrate status
-> N migrate status against the newer schema (rollback compatibility gate)
-> start N+1 API/Worker
-> health checks
-> persist new image tag/version
```

Build from a clean checked-out release:

```bash
bash scripts/upgrade.sh \
  --to-tag v0.9.1 \
  --to-version 0.9.1 \
  --build \
  --restore-on-failure
```

Or use already-published images in the configured repositories:

```bash
bash scripts/upgrade.sh \
  --to-tag v0.9.1 \
  --to-version 0.9.1 \
  --pull \
  --restore-on-failure
```

The previous API/Worker/migrate images must still exist locally before the upgrade starts.

### Failed deployment rules

There is no invented database auto-rollback:

- If the previous release's own `migrate status` **accepts** the newer database, an application-only rollback is allowed and the old API/Worker can restart against that schema.
- If the previous release **rejects** the newer database, the old application is not restarted. With `--restore-on-failure`, the script restores the verified pre-upgrade DB+object recovery point; without that flag it leaves ingress/writers stopped and prints the explicit restore command.
- `migrate down` is never called by production upgrade/restore scripts.

Machine-readable evidence is written under `upgrade-state/<timestamp>-<from>-to-<to>/` with pre/post migration status and `evidence.env` including the old-release/new-schema compatibility result and rollback mode.

## 11. Migration compatibility drill

Use a real historical Git ref as release N and current HEAD as N+1:

```bash
bash scripts/upgrade-compat-drill.sh --from-ref <old-release-git-ref>
```

The drill compiles the old/current migrate binaries, applies the old schema, takes and validates a pre-upgrade backup, proves the current release accepts the old schema, migrates forward, checks whether the old release accepts the newer schema, then destroys the upgraded DB and proves the verified backup restores an old-release-compatible schema. No down migration is executed.

This is the machine-verifiable basis for the compatibility matrix; a compatibility result is evidence for that exact release pair, not a blanket promise about every version.

## 12. HUMAN-PENDING production validation

The following cannot be honestly proven by Compose syntax or loopback/server-side tests and remain `HUMAN-PENDING` until tested on the real public deployment:

- DNS propagation and cloud/router NAT rules from an external network;
- TURN/UDP on UDP/443 from carrier/mobile networks;
- ICE/TCP 7881 and TURN/TLS TCP/443 fallback when UDP is blocked;
- Android/Windows calls across different ISPs/carriers;
- Wi-Fi <-> mobile-network handover/reconnect behavior;
- at least one sustained real audio/video call (for example 30 minutes) while watching bandwidth/CPU;
- certificate renewal in the operator's real ACME workflow;
- measured RPO/RTO using production-size backups and an independent recovery host/storage location.

Do not mark U21/U22 as `HUMAN-PASS` based only on local automated tests.
