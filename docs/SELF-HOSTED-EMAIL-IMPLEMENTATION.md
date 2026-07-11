# Self-Hosted Email — Implementation Plan (Claude Code driver)

You (Claude Code) are the implementation driver for a self-hosted email system. Work through this file **phase by phase, in order**. The human operator (Ed) runs a Talos K8s cluster (`geekzoo-prod`, kube-context `geekzoo-geekzoo-prod`) managed by Flux + Cilium, sends mail outbound via AWS SES, and fronts inbound mail through a GCP free-tier VM running `frps`.

> **Revision:** 2026-06-24. Rewritten from the original draft to match what's actually being built. Domain is **macbytes.io** (migrating off iCloud). Key stack decisions are baked in below — see **Decisions log**.

---

## Decisions log (what changed from the original draft)

| Topic | Decision |
|---|---|
| Domain | `macbytes.io` — a **live iCloud custom-email domain** being migrated off. Apex MX stays on iCloud until the Phase-4 cutover. |
| SES region | **us-east-2** (not us-east-1). SMTP relay `email-smtp.us-east-2.amazonaws.com:587`; MAIL FROM MX `feedback-smtp.us-east-2.amazonaws.com`. |
| Secrets | **External Secrets Operator → AWS SSM Parameter Store** (`/k3s-geekzoo/mail/*`, region us-east-2) via ClusterSecretStore `secretstore-aws-parameter-store`. **Not** SOPS/kubeseal. |
| TLS | **cert-manager** ClusterIssuer `letsencrypt-prod` (Cloudflare DNS-01); cert mounted into Stalwart. **Not** Stalwart self-ACME. |
| Exposure (HTTPS) | Reuse the **existing shared Cloudflare tunnel** (`apps/cloudflare`), add hostnames. **Not** a new tunnel. |
| Flux | New top-level **`mail`** area: `clusters/production/13-mail.yaml`, `dependsOn: [storage, infra-configs, secrets]`. |
| Namespace | `mail`, added to `infrastructure/namespaces/namespaces.yaml`, unlabeled (cluster-default PSA, matching apps/plane). |
| Storage | `ceph-block` (Rook RBD) RWO. Stalwart PVC **added to backups in v1** (holds mail + calendars + contacts). |
| Scope | v1 **includes native mobile clients** (IMAP 993, submission 587 + 465) and **calendar + contacts (CalDAV/CardDAV)** + autodiscovery. (Was Phase 7.) |
| Mail server | **Stalwart v0.16.10** (verified: production CalDAV/CardDAV on the HTTP listener; IMAP + submission first-class). Single replica. |
| DAV host | **`dav.macbytes.io`** (proxied) serves CalDAV/CardDAV/JMAP. `mail.macbytes.io` stays grey-cloud for raw mail. `webmail.macbytes.io` = Bulwark. |
| Submission ports | Offer **both** 465 (implicit TLS) and 587 (STARTTLS). |
| PROXY protocol | **Skipped in v1** (Stalwart sees the frpc IP; content spam filter still works). Can enable later — all-or-nothing per listener incl. `:25`. |
| Image pinning | Pin tags, **omit** the `$imagepolicy` marker (matches plane/cloudflared). |

---

## Working agreement (read first, follow throughout)

1. **Step through phases in order.** Complete every task and meet the **Acceptance criteria** before moving on.
2. **Stop at every `[HUMAN]` checkpoint.** Print exactly what Ed must do, then **wait for confirmation**. Never proceed past a `[HUMAN]` step alone.
3. **Confirm before irreversible cloud actions.** Before creating/deleting any GCP/AWS resource, show the exact command and ask for a yes.
4. **Follow existing repo conventions.** Match the Flux Kustomization structure, namespacing, and naming. Secrets = **ESO + AWS SSM** (per the Decisions log).
5. **Never write secret values in plaintext to the repo.** Real values live in **SSM SecureString** (`/k3s-geekzoo/mail/*`); manifests reference them via `ExternalSecret`. Generate/store secrets with `aws ssm put-parameter --type SecureString` (never echoed to the transcript).
6. **Surface exact values for the human.** When a later phase needs an earlier output (the VM static IP, DKIM tokens), print it and say where it's used.
7. **Update the Progress tracker** (bottom of this file) as each item completes. Keep it resumable.
8. **Prefer Flux reconciliation over imperative `kubectl apply`.** Write manifests to the repo, commit, let Flux apply. Use `kubectl`/`flux` to verify or `flux reconcile`.
9. **When something fails, stop and diagnose** — show logs/errors, propose a fix; don't silently retry destructive operations.

### Tag legend
- `[AGENT]` — Claude does this (write files, run CLI, verify).
- `[HUMAN]` — stop, instruct Ed, wait: account signups, console clicks, approvals, reading email, physical/account-bound steps.
- `[GATE]` — verification checkpoint; must pass before continuing.

---

## Architecture (v1 = webmail + native clients + calendar/contacts)

```
Inbound MX:    sender → frps :25  (GCP VM) → frp tunnel → frpc pod → Stalwart :2525  (internal)
Native mail:   client → mail.macbytes.io (grey-cloud A → frps IP)
                 frps :993/:587/:465 → frp tunnel → frpc pod → Stalwart :9993/:5587/:5465 (internal)
                 TLS terminates at Stalwart (cert for mail./imap./smtp.macbytes.io)
Outbound:      Stalwart → SES email-smtp.us-east-2.amazonaws.com:587 (STARTTLS) → internet
Webmail:       browser → Cloudflare tunnel → Traefik → Bulwark :3000 → Stalwart JMAP :8080 (internal)
Cal/Contacts:  client → dav.macbytes.io (proxied) → Cloudflare tunnel → Traefik → Stalwart HTTP :8080
                 (CalDAV /dav/cal, CardDAV /dav/card, JMAP, /.well-known — SAME listener as webmail/JMAP)
Autodiscovery: autoconfig./autodiscover.macbytes.io (proxied) → tunnel → Traefik → Stalwart :8080
Admin:         kubectl port-forward to Stalwart :8080 webadmin (not publicly exposed in v1)
```

**Two front doors, one Stalwart:**
- **Raw TCP (mail ports)** → `frps` on the GCP VM. cloudflared (free plan) cannot carry public raw TCP — that needs paid Spectrum — so `25/587/465/993` all go through frps like `:25`. `frp` is a transparent L4 pipe; it does **not** terminate TLS — implicit-TLS (993/465) and STARTTLS (587) terminate at **Stalwart**.
- **HTTPS (DAV/JMAP/webmail/autoconfig)** → the **existing Cloudflare tunnel** → Traefik → Stalwart `:8080`. Never touches the GCP VM → zero GCP egress, no new listener (DAV is auto-served by the HTTP listener).

**Port strategy (keeps the K8s side PodSecurity-`restricted`-compliant):**
- Stalwart binds **unprivileged** ports in-pod: SMTP `2525`, submission `5587`, submissions `5465`, IMAPS `9993`, HTTP/JMAP/DAV `8080`. *(Exact internal numbers confirmed at implementation; must not collide.)*
- `frps` on the VM holds `CAP_NET_BIND_SERVICE` (via systemd) and binds the privileged ports `25/587/465/993`, forwarding through the tunnel to Stalwart's unprivileged ports.
- Outbound to SES is a normal egress connection; no binding.

**DNS-split trap (the subtlest part):** `mail.macbytes.io` (and `imap.`/`smtp.` CNAMEs) **must be DNS-only / grey-cloud** (A → frps IP) so raw IMAP/SMTP reach frps — Cloudflare won't proxy mail ports. The HTTPS hosts (`dav.`, `webmail.`, `autoconfig.`, `autodiscover.`) **must be proxied / orange-cloud** so they ride the tunnel. A single orange-clouded `mail.` would silently break direct IMAP/SMTP.

---

## Phase 0 — Preconditions & long-lead items ✅ COMPLETE (2026-06-24)

### 0.1 `[HUMAN]` Accounts & APIs
- [x] AWS account (868722715040), Cloudflare hosts `macbytes.io`.
- [ ] GCP project with **billing enabled** + **Compute Engine API** — *Ed has a project; needs to log in + confirm (gate for Phase 1).*

### 0.2 SES setup (us-east-2) — done via `aws sesv2` CLI
- [x] Domain identity `macbytes.io`, **Easy DKIM RSA-2048** → **VERIFIED**, DKIM **SUCCESS**, `VerifiedForSending: true`.
- [x] Custom MAIL FROM `bounce.macbytes.io`, on-MX-failure = use default (status PENDING → self-clears; non-blocking).
- [x] **Production access granted** — `ProductionAccessEnabled: true`, quota 50,000/day @ 14/s (us-east-2). Unblocks Phase 6 and the SES cutover (Brevo sandbox-era fallback retired in the Stalwart plan).
- [x] **SMTP credentials**: dedicated IAM user `ses-smtp-macbytes` (send-only), creds in SSM.

### 0.3 Secrets — all in SSM SecureString (`/k3s-geekzoo/mail/`, us-east-2)
- [x] `ses-smtp-username`, `ses-smtp-password` (region-derived SMTP password).
- [x] `frp-auth-token` (`openssl rand -hex 32`).
- [x] **No separate Cloudflare token needed** — cert-manager already holds `cloudflare-certmanager-secret` (SSM `/k3s-geekzoo/cloudflare-certmanager-secret`, key `api-token`, Zone:DNS:Edit) and issues the cert centrally.

### 0.4 CLI auth & tooling
- [x] `aws` authenticated (account root), `kubectl` context `geekzoo-geekzoo-prod`, `flux check` passes.
- [ ] `gcloud` **not installed** — required for Phase 1.

### 0.5 `[AGENT]` Repo conventions — mapped
Apps live in flat per-app dirs; raw `Deployment`/`StatefulSet` for single images, HelmRelease only for vendor charts. Flux 3-level chain (`FluxInstance` → `clusters/production/NN-*.yaml` Kustomization CRs → area dirs). Secrets = ESO+SSM. TLS = cert-manager `letsencrypt-prod` (DNS-01). Exposure = one shared Cloudflare tunnel `kubernetes` + Traefik `IngressRoute` (websecure; global web→443 redirect exists). Storage = `ceph-block`. Namespaces central. Image-automation opt-in.

### `[GATE]` Phase 0 ✅
SES verified + production access requested; secrets staged in SSM; repo understood. (gcloud install is folded into the Phase-1 `[HUMAN]` gate.)

---

## Phase 1 — GCP VM + frps

### 1.0 `[HUMAN]` GCP prerequisites
- [ ] Log into the GCP project; confirm billing + Compute Engine API; install gcloud (`brew install --cask google-cloud-sdk`), `gcloud auth login`, `gcloud config set project <ID>`. Provide the **project ID**.
- [ ] (Recommended) ~$5/mo budget alert.

### 1.1 `[AGENT]` Reserve static IP + create the VM
Free-tier e2-micro requires `us-central1`/`us-east1`/`us-west1` — use **us-east1**. Confirm before running.
```bash
gcloud compute addresses create mail-relay-ip --region=us-east1
IP=$(gcloud compute addresses describe mail-relay-ip --region=us-east1 --format='get(address)')
echo "Static IP: $IP"   # → Phase 2 (mail. A record) + Phase 4 (frpc serverAddr)

gcloud compute instances create mail-relay \
  --zone=us-east1-b --machine-type=e2-micro \
  --image-family=debian-12 --image-project=debian-cloud \
  --boot-disk-size=30GB --boot-disk-type=pd-standard \
  --address="$IP" --network-tier=PREMIUM --tags=mail-relay
```
> e2-micro compute is free-tier; the **static IPv4 is ~$3/mo**. Free-tier egress is **~1 GB/mo** (North America) — fine because only mail ports (25/587/465/993) traverse the VM; bulk mailbox reads go via the Cloudflare tunnel (webmail/JMAP/DAV), not the VM.

### 1.2 `[AGENT]` Firewall rules
```bash
# Inbound SMTP MX from the world
gcloud compute firewall-rules create allow-smtp \
  --direction=INGRESS --action=ALLOW --rules=tcp:25 \
  --source-ranges=0.0.0.0/0 --target-tags=mail-relay
# Native mail-client ports (submission + IMAPS)
gcloud compute firewall-rules create allow-mail-clients \
  --direction=INGRESS --action=ALLOW --rules=tcp:587,tcp:465,tcp:993 \
  --source-ranges=0.0.0.0/0 --target-tags=mail-relay
# frp control channel (home IP is dynamic; protected by token + TLS)
gcloud compute firewall-rules create allow-frp \
  --direction=INGRESS --action=ALLOW --rules=tcp:7000 \
  --source-ranges=0.0.0.0/0 --target-tags=mail-relay
```
- [ ] `[HUMAN]` Provide current home/public IP to lock SSH:
```bash
gcloud compute firewall-rules create allow-ssh-me \
  --direction=INGRESS --action=ALLOW --rules=tcp:22 \
  --source-ranges=<YOUR_IP>/32 --target-tags=mail-relay
```

### 1.3 `[AGENT]` Install frps on the VM
`gcloud compute ssh mail-relay --zone=us-east1-b`, then:
- [ ] Look up the **current** frp release at `github.com/fatedier/frp/releases`; download `linux_amd64`. **Record the version** — frpc (Phase 4) must match.
- [ ] Install `frps` to `/usr/local/bin/`; create `/etc/frp/frps.toml` (pull the token from SSM, do not hardcode):
```toml
bindPort = 7000
auth.method = "token"
auth.token = "<from SSM /k3s-geekzoo/mail/frp-auth-token>"
transport.tls.force = true
```
- [ ] `/etc/systemd/system/frps.service` (capability lets it bind the low ports):
```ini
[Unit]
Description=frp server
After=network.target
[Service]
Type=simple
ExecStart=/usr/local/bin/frps -c /etc/frp/frps.toml
Restart=always
RestartSec=5
DynamicUser=yes
AmbientCapabilities=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
[Install]
WantedBy=multi-user.target
```
- [ ] `systemctl daemon-reload && systemctl enable --now frps`; confirm active + `ss -tlnp | grep 7000`.

### `[GATE]` Phase 1
VM running, static IP recorded, firewall rules present (25/587/465/993/7000/22), `frps` active on 7000. (Mail ports won't pass a banner test until frpc connects in Phase 4.)

---

## Phase 2 — DNS records

### 2.1 SES-side records — ✅ DONE (2026-06-24, via Cloudflare API)
- [x] 3 DKIM CNAMEs (`<token>._domainkey` → `<token>.dkim.amazonses.com`), grey-cloud.
- [x] MAIL FROM: `bounce` MX → `feedback-smtp.us-east-2.amazonaws.com`; `bounce` TXT → `v=spf1 include:amazonses.com ~all`.
- [x] Apex SPF **merged**: `v=spf1 include:icloud.com include:amazonses.com ~all` (iCloud preserved).
- [x] Existing `_dmarc` (p=none, Cloudflare rua) left as-is — already the permissive start Phase 6 wants. iCloud `sig1` DKIM + `apple-domain` TXTs untouched.

### 2.2 `[AGENT]` Host records (after Phase 1 gives the static IP) — staged early, safe (don't affect iCloud)
| Host | Type | Value | Cloudflare |
|---|---|---|---|
| `mail` | A | `<frps static IP>` | **grey** (DNS-only) — raw IMAP/SMTP + Apple name-guessing |
| `imap` | CNAME | `mail.macbytes.io` | **grey** |
| `smtp` | CNAME | `mail.macbytes.io` | **grey** |
| `dav` | CNAME | `<tunnel CNAME target>` | **orange** (proxied) — CalDAV/CardDAV/JMAP |
| `autoconfig` | CNAME | `<tunnel CNAME target>` | **orange** — Thunderbird/K-9 |
| `autodiscover` | CNAME | `<tunnel CNAME target>` | **orange** — Outlook/eM Client |
| `webmail` | CNAME | `<tunnel CNAME target>` | **orange** — Bulwark UI |

### 2.3 `[AGENT]` Autodiscovery SRV / TXT
```
_imaps._tcp        SRV 0 1 993 mail.macbytes.io.
_submission._tcp   SRV 0 1 587 mail.macbytes.io.
_submissions._tcp  SRV 0 1 465 mail.macbytes.io.
_imap._tcp         SRV 0 0 0 .     # suppress plaintext
_pop3._tcp         SRV 0 0 0 .
_pop3s._tcp        SRV 0 0 0 .
_caldavs._tcp      SRV 0 1 443 dav.macbytes.io.
_carddavs._tcp     SRV 0 1 443 dav.macbytes.io.
_caldav._tcp       SRV 0 0 0 .     # suppress non-TLS DAV
_carddav._tcp      SRV 0 0 0 .
# Optional TXT path hints — VERIFY exact path on the live instance before adding:
#_caldavs._tcp     TXT "path=/dav/cal/"
#_carddavs._tcp    TXT "path=/dav/card/"
```

### 2.4 DEFERRED to Phase 4 cutover (breaks iCloud inbound — only when Stalwart can receive)
- [ ] Apex `MX @` iCloud → `10 mail.macbytes.io`.

### `[GATE]` Phase 2
SES verified ✅. Host + autodiscovery records resolve; grey/orange cloud split correct (`dig +short A mail.macbytes.io` returns the frps IP, not a Cloudflare anycast addr).

---

## Phase 3 — Stalwart on K8s (Flux)

### 3.1 `[AGENT]` Secrets (ESO → SSM)
- [ ] `secrets/external-secrets/mail-secrets.yaml` (`ExternalSecret`, ns `mail`, ClusterSecretStore `secretstore-aws-parameter-store`) materializing `ses-smtp-username`, `ses-smtp-password`, `frp-auth-token` from `/k3s-geekzoo/mail/*` (explicit `data[]` per-key idiom, like `open-webui-oidc`). Register in `secrets/external-secrets/kustomization.yaml`. **No SOPS, no plaintext.**

### 3.2 `[AGENT]` cert-manager Certificate (mounted into Stalwart)
- [ ] `mail/stalwart/certificate.yaml` — `secretName: stalwart-tls-certificate`, `issuerRef: letsencrypt-prod` (ClusterIssuer), `dnsNames: [mail.macbytes.io, imap.macbytes.io, smtp.macbytes.io, dav.macbytes.io, autoconfig.macbytes.io, autodiscover.macbytes.io]`.
  - `mail./imap./smtp.` SANs are **client-validated** on the raw-TCP path (no Cloudflare in between) — required.
  - `dav./autoconfig./autodiscover.` are proxied: the client sees Cloudflare's edge cert; these SANs make Traefik present a matching origin cert (origin uses `noTLSVerify`). Include for cleanliness.

### 3.3 `[AGENT]` Stalwart workload (`mail/stalwart/`)
- **Store:** embedded RocksDB on one `ceph-block` PVC. Single replica. (Workload kind — StatefulSet vs Deployment+`Recreate` — open Phase-3 decision; lean StatefulSet for stable volume identity.)
- **Listeners (unprivileged, in-pod):** SMTP `2525`, submission `5587` (STARTTLS), submissions `5465` (implicit TLS), IMAPS `9993` (implicit TLS), HTTP/JMAP/DAV `8080`. ClusterIP Service `stalwart.mail.svc.cluster.local`.
  - **CalDAV/CardDAV/WebDAV need no extra listener** — auto-served on `:8080`. Confirm `/.well-known/caldav` + `/.well-known/carddav` redirect to `/dav/cal/` + `/dav/card/` (record the exact status/Location before baking SRV `path=` TXT).
  - Verify the TLS-key TOML form against the installed v0.16.10 config reference (`tls.implicit` vs `[listener.tls]` table).
- **Cert:** mount `stalwart-tls-certificate`; point listeners at `tls.crt`/`tls.key`.
- **Outbound relay:** smarthost `email-smtp.us-east-2.amazonaws.com:587`, STARTTLS, SES SMTP creds from the secret. **Disable DANE + MTA-STS** on the relay path.
- **DKIM signing OFF** (SES Easy DKIM signs). Inbound DKIM **verification** stays on.
- **securityContext:** `runAsNonRoot`, drop ALL caps, `seccompProfile: RuntimeDefault` (mirror vaultwarden; UID/GID 65534 + fsGroup).
- **PROXY protocol:** skipped in v1 (Stalwart sees the frpc IP on mail ports).
- Create Ed's admin account + first user identity at `macbytes.io`.

### 3.4 `[HUMAN]` Commit & reconcile
- [ ] Review diff, commit/push. `flux reconcile kustomization mail --with-source`.

### 3.5 `[AGENT]` Verify
- [ ] Stalwart Running/Ready; PVC bound; cert `Ready=True` with all 6 SANs; listeners up (2525/5587/5465/9993/8080).
- [ ] `kubectl port-forward` to `:8080` webadmin; account exists.

### `[GATE]` Phase 3
Stalwart healthy, cert issued (6 SANs), admin reachable via port-forward, outbound relay + listeners configured.

---

## Phase 4 — frpc on K8s (Flux) + inbound cutover

### 4.1 `[AGENT]` frpc (`mail/frpc/`)
Token via the ESO secret (env), not the ConfigMap. Match the frp **version** from Phase 1. `frpc.toml`:
```toml
serverAddr = "<frps static IP>"
serverPort = 7000
auth.method = "token"
auth.token = "<from secret>"
transport.tls.enable = true

[[proxies]]
name = "smtp"          # MX
type = "tcp"
localIP = "stalwart.mail.svc.cluster.local"
localPort = 2525
remotePort = 25

[[proxies]]
name = "submission"    # 587 STARTTLS
type = "tcp"
localIP = "stalwart.mail.svc.cluster.local"
localPort = 5587
remotePort = 587

[[proxies]]
name = "submissions"   # 465 implicit TLS
type = "tcp"
localIP = "stalwart.mail.svc.cluster.local"
localPort = 5465
remotePort = 465

[[proxies]]
name = "imaps"         # 993 implicit TLS
type = "tcp"
localIP = "stalwart.mail.svc.cluster.local"
localPort = 9993
remotePort = 993
```
Deployment: `image: snowdreamtech/frpc:<VER>` (multi-arch), 1 replica, restricted securityContext (`runAsNonRoot`, `allowPrivilegeEscalation: false`, drop ALL, `seccompProfile: RuntimeDefault`). Build the config with `configMapGenerator` (like `apps/cloudflare`).

### 4.2 `[HUMAN]` Commit & reconcile.

### 4.3 `[AGENT]` Verify inbound path (pre-cutover)
- [ ] frpc logs "start proxy success" for all 4; frps (VM) logs each proxy registered.
- [ ] External SMTP banner test on `mail.macbytes.io:25` → `220` (MXToolbox / external host — **not** the home network; Spectrum blocks outbound :25).
- [ ] `openssl s_client -connect mail.macbytes.io:993` + `:587 -starttls smtp` → handshake presents the cert (SAN match), `* OK` / `250-AUTH`.

### 4.4 `[HUMAN]` Inbound cutover
- [ ] Flip apex `MX @` iCloud → `10 mail.macbytes.io`. Send a test from an outside mailbox to `you@macbytes.io`; confirm it lands in Stalwart.

### `[GATE]` Phase 4
Inbound mail delivered to Stalwart over the tunnel; mail-client ports answer with the right cert.

---

## Phase 5 — Webmail + HTTPS ingress (Bulwark + Cloudflare tunnel + Traefik)

### 5.1 `[AGENT]` Bulwark webmail (`mail/bulwark/`)
- Deploy `ghcr.io/bulwarkmail/webmail` (**pin ≥ 1.4.10** — earlier had auth-bypass CVE-2026-34834) → Stalwart JMAP `http://stalwart.mail.svc.cluster.local:8080`. ClusterIP `3000`. Restricted securityContext. Own cert (`bulwark-tls-certificate`).
- *Note:* evaluate whether Stalwart v0.16's built-in web UI suffices — if so, Bulwark could be dropped (one fewer component + CVE surface).

### 5.2 `[AGENT]` Cloudflare tunnel hostnames (reuse the shared tunnel)
- [ ] In `apps/cloudflare/cloudflared-config.yaml`, insert **before** the final `- service: http_status:404`, one block each for `webmail`, `dav`, `autoconfig`, `autodiscover` → `https://traefik.traefik.svc.cluster.local:443` with `originRequest.noTLSVerify: true` + `originServerName`/`httpHostHeader` = the hostname (match existing entries). No new tunnel/secret.

### 5.3 `[AGENT]` Traefik IngressRoutes (`mail/`)
- [ ] websecure `IngressRoute` per host: `webmail` → Bulwark `:3000`; `dav`/`autoconfig`/`autodiscover` → Stalwart `:8080`. `tls.secretName` = the matching cert secret. No redirect middleware (global web→443 redirect exists).

### `[GATE]` Phase 5
`webmail.macbytes.io` loads Bulwark, login works, inbox shows the Phase-4 test mail; `dav.macbytes.io/.well-known/caldav` redirects correctly.

---

## Phase 6 — Deliverability + DMARC ramp

### 6.1 `[HUMAN]` Real send test (needs SES production access)
- [x] Confirm `aws sesv2 get-account --region us-east-2 --query ProductionAccessEnabled` = `true` (granted; 50k/day, 14/s). Active Stalwart route flipped Brevo → SES (configmap-plan.yaml `MtaOutboundStrategy.route.else`).
- [ ] From Bulwark (or a native client), send to a **Gmail** you control. Gmail → **Show original**: confirm **SPF pass+aligned**, **DKIM pass+aligned**, **DMARC pass**. Also run **mail-tester.com** (target 10/10).

### 6.2 `[AGENT]` Debug if needed
Headers diagnosis: MAIL FROM alignment → recheck `bounce` records; DKIM alignment → SES Easy DKIM verified + Stalwart not double-signing.

### 6.3 `[HUMAN]` Tighten DMARC over time
- [ ] After ~1 week of clean `rua` reports: `p=none` → `p=quarantine`. Later: → `p=reject`.

---

## Phase 6.5 — Client onboarding & autodiscovery validation
- [ ] Thunderbird/K-9: add account from email address only (Mozilla autoconfig at `autoconfig.macbytes.io`).
- [ ] Apple Calendar/Contacts: add from email + password (RFC 6764 SRV + `.well-known`).
- [ ] Apple Mail: name-guessing hits `imap.`/`smtp.` on 993/465 with valid cert; optionally ship a signed `.mobileconfig` bundling IMAP+SMTP+CalDAV+CardDAV (+ app password) for one-tap.
- [ ] Provision **per-client app passwords** in Stalwart (not the primary credential).
- [ ] 48–72h **sync soak**: create/edit/delete events + contacts both directions; recurring event + invite; watch for duplication/loss (DAV is pre-1.0-newer than the mail core).

---

## Phase 7 — Optional extensions (post-v1)
- Move Stalwart's store to external Postgres (CNPG) + S3 (TrueNAS/ceph-bucket) for resilience.
- Monitoring: alert on frpc/frps disconnect, SES bounce/complaint rate, and cert expiry (the 6-SAN cert).

---

## Validation & timers playbook
| Item | How to check | Timer | Done = |
|---|---|---|---|
| SES domain/DKIM | `aws sesv2 get-email-identity --email-identity macbytes.io --region us-east-2` | ✅ done (~4 min) | Verification + DKIM `SUCCESS` |
| SES MAIL FROM | same, `MailFromAttributes.MailFromDomainStatus` | mins–1 h | `SUCCESS` (non-blocking) |
| SES production access | `aws sesv2 get-account --region us-east-2 --query ProductionAccessEnabled` | 1–3 business days | `true` (AWS also emails) |
| DNS propagation | `dig +short <name>`; whatsmydns.net | secs–5 min (TTL auto ~300s) | resolves to expected value |
| DNS-split correct | `dig +short A mail.macbytes.io` (must be frps IP, not Cloudflare anycast) | secs | grey=raw IP, orange=Cloudflare IPs |
| LE cert (cert-manager) | `kubectl -n mail get certificate,certificaterequest,order,challenge` | ~2–10 min | `Ready=True`, all 6 SANs |
| Mail-client ports | `nc -vz mail.macbytes.io 993/587/465` (external host) | secs after Phase 4 | open |
| IMAPS/submission TLS | `openssl s_client -connect mail.macbytes.io:993` / `:587 -starttls smtp` | instant | cert SAN match + `* OK`/`250-AUTH` |
| DAV well-known | `curl -I https://dav.macbytes.io/.well-known/caldav` then auth `PROPFIND` | instant | 301/307 → `/dav/cal/`; PROPFIND `207` |
| Deliverability | Gmail "Show original"; mail-tester.com; MXToolbox | after first send | SPF/DKIM/DMARC pass+aligned; 10/10 |
| DMARC rua reports | inbox at the `_dmarc` rua address | ~daily | clean reports → ramp policy |
| GCP egress | GCP console → VM monitoring / billing | monthly (weekly during initial sync) | < ~1 GB/mo |

---

## Progress tracker (keep updated)
- [x] Phase 0 — SES verified, production access requested, secrets in SSM, repo understood
- [x] Phase 1 — GCP VM + frps live (IP 35.196.228.211; frps v0.69.1 on :7000; firewall 25/587/465/993/7000 + SSH-locked)
- [x] Phase 2.1 — SES-side DNS published (DKIM, bounce, merged SPF)
- [~] Phase 2.2/2.3 — mail A → 35.196.228.211 (grey) + imap/smtp CNAME added; DAV/autoconfig/autodiscover (proxied) + SRV pending Phase 5/6.5
- [x] Phase 3 — Stalwart healthy (listeners 2525/5587/5465/9993/8080, 6-SAN cert mounted, SES relay, DKIM-off, admin edward@macbytes.io; TLS verified; Flux dd80985)
- [ ] Phase 4 — inbound path live + apex MX cutover (test mail received)
- [ ] Phase 5 — webmail + dav/autoconfig/autodiscover reachable over the tunnel
- [ ] Phase 6 — outbound passes aligned SPF/DKIM/DMARC; mail-tester 10/10
- [ ] Phase 6.5 — native mail + calendar + contacts onboard via autodiscovery; 48–72h soak
- [ ] Stalwart PVC added to backups (v1)
- [ ] DMARC → p=quarantine
- [ ] DMARC → p=reject

## Second domain: edtheadmin.io (added 2026-07-11)

Scope: "minimal + autodiscovery" tier — full send/receive, native-client autodiscovery,
shared webmail (`webmail.macbytes.io` serves both domains). No dedicated Bulwark, no
`dav.edtheadmin.io` (future). frps/frpc/SES-creds/listeners unchanged (port-based, account-wide).

- [x] Cloudflare token fix — cert-manager DNS-01 token widened to all zones (was macbytes.io-only; would have broken the cert re-issue)
- [x] SES identity `edtheadmin.io` (us-east-2) + MAIL FROM `bounce.edtheadmin.io` — VerifiedForSending, DKIM SUCCESS, MAIL FROM SUCCESS
- [x] DNS (via cert-manager CF token, all records): apex MX → mail.edtheadmin.io, A mail → 35.196.228.211 (grey), imap/smtp CNAMEs (grey), 3× DKIM CNAMEs, SPF apex+bounce, `_dmarc` (rua → dmarc@macbytes.io), bounce MX → feedback-smtp.us-east-2.**amazonses.com** (NOT amazonaws.com), SRV set, autoconfig/autodiscover proxied CNAMEs → tunnel
- [x] DMARC external-report authorization: `edtheadmin.io._report._dmarc.macbytes.io TXT "v=DMARC1"` on the macbytes.io zone (required for cross-domain rua)
- [x] Repo (commit 9065a92): +5 cert SANs, Domain upsert in configmap-plan, autodiscovery IngressRoute matchers, 2 cloudflared ingress entries
- [x] Cert re-issued with 13 SANs; Stalwart restarted to load it; `mail.edtheadmin.io:993` presents edtheadmin SANs
- [x] Stalwart Domain applied live via `stalwart-cli apply` (domain id `c`) — auth via `edward` account; NOTE: `/k3s-geekzoo/mail/stalwart-recovery-admin` SSM cred is STALE (401)
- [x] Autoconfig verified end-to-end: `https://autoconfig.edtheadmin.io/mail/config-v1.1.xml` → 200 (advertises mail.macbytes.io as host — expected, defaultHostname unchanged)
- [x] First mailbox created: ed@edtheadmin.io (2026-07-11)
- [x] Inbound/outbound round-trip validated by operator (2026-07-11)

## Human-action summary
1. ✅ SES (us-east-2): identity + Easy DKIM + MAIL FROM + production-access request + SMTP creds — done via CLI.
2. ✅ DNS SES-side records (DKIM, bounce, merged SPF) — done via Cloudflare API.
3. **GCP:** log into the project, confirm billing + Compute Engine API, install/auth gcloud, give the project ID. Provide home IP for the SSH rule.
4. Review/approve commits as each Flux area lands.
5. Inbound cutover approval (flip apex MX off iCloud).
6. Run the Gmail "Show original" + mail-tester deliverability test once production access is granted.
7. Onboard clients (app passwords; optional Apple `.mobileconfig`); step DMARC none → quarantine → reject.
