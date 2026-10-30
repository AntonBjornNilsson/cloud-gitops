# Harbor (planned, not enabled)

Container registry at `harbor.${domain}` (LAN only, Harbor's own login, no Authelia), for two things:

1. **Pull-through cache** for Docker Hub (rate limits), GHCR, Quay and registry.k8s.io.
2. **Our own images** in the `homelab` project: `harbor.${domain}/homelab/<image>:<tag>`.

Enable by uncommenting `storage/harbor/system-harbor.yaml` in `components/kustomization.yaml`
(after the secrets below exist).

## How the cluster uses it

No image names change. The `registry-mirror` DaemonSet (`config/registry-mirror.yaml`) writes containerd
mirror config on every node:

```
docker.io       -> https://harbor.${domain}/v2/dockerhub   (proxy project "dockerhub")
ghcr.io         -> https://harbor.${domain}/v2/ghcr
quay.io         -> https://harbor.${domain}/v2/quay
registry.k8s.io -> https://harbor.${domain}/v2/k8s
```

So `image: busybox:1.37` is pulled through Harbor and cached. The upstream registry is still the
`server`, so if Harbor is down or can't serve an image, containerd pulls directly as it does today.
That also avoids a circular dependency: Harbor's own images come from Docker Hub.

Own images are pulled by their full name. The `homelab` project is public (anonymous pull, LAN only),
so no `imagePullSecrets` are needed. Pushing needs the robot account:

```bash
docker login harbor.<domain> -u 'robot$homelab+push'
docker push harbor.<domain>/homelab/<image>:<tag>
```

## Layout

| File | What |
|---|---|
| `harbor.yaml` | Namespace, HelmRepository, HelmRelease (goharbor `harbor` chart), admin password and secret key Secrets |
| `cilium-policy.yaml` | Ingress from Traefik on 8080, metrics on 8001; egress HTTPS to upstream registries |
| `config/app/configure.py` | Harbor configuration from code, via the API: proxy registries and projects, `homelab` project, push robot, weekly GC |
| `config/harbor-config.yaml` | CronJob running `configure.py` every 30 min |
| `config/registry-mirror.yaml` | Node DaemonSet that writes the containerd mirror config (Kyverno exceptions already in `kyverno-policies.yaml`) |

`system-harbor-config` depends on `system-harbor`, so the mirrors switch on only after Harbor is Ready.

## Secrets to add (`storage-substitutions`)

| Key | Notes |
|---|---|
| `harbor_admin_password` | UI `admin` login, also used by the config job |
| `harbor_secret_key` | Exactly 16 characters. Encrypts stored registry credentials; never change it after install |
| `harbor_db_password` | Internal PostgreSQL password; set once |
| `harbor_push_robot_secret` | Secret of `robot$homelab+push`: 8+ characters with upper and lower case and a digit |
| `harbor_dockerhub_username` / `harbor_dockerhub_token` | Optional (may be empty): Docker Hub account with a read-only access token, for the higher authenticated limit |

Then run `scripts/check-substitutions.py --context=<admin>`.

## Enable checklist

1. Add the secrets above and uncomment the line in `components/kustomization.yaml`.
2. After `system-harbor` is Ready, run the config job once instead of waiting up to 30 min:
   `kubectl -n harbor create job --from=cronjob/harbor-config harbor-config-init`
3. Check that nodes resolve `harbor.${domain}` to the Traefik IP (containerd uses the node's resolver,
   not cluster DNS). If they don't, pulls still work but bypass the cache.
4. Check that containerd picked up the mirror config on each node: `/run/k0s/containerd-cri.toml` must contain
   `config_path = "/etc/k0s/containerd.d/certs.d"`. If k0s didn't reload containerd for the new drop-in,
   restart the k0s worker service on that node once. Running containers are not affected.
5. Pull something new, for example a fresh `busybox` tag in a test pod, and check that it appears in the
   `dockerhub` project in the Harbor UI.
6. Add a VMPodScrape in `victoriametrics/scrapes/` for port 8001, and Harbor to the homepage and Grafana if wanted.
7. Document Harbor in the cloud-gitops skill (and the claude-agent `rules.md`, if relevant).

## Open points

- **Traefik encoded characters:** `websecure` sets `allowEncodedPercent=false`. The Harbor UI double-encodes
  nested repository names (`library%252Fnginx`), so the UI pages for those repositories return 400.
  Pulls and pushes are not affected. Options: allow encoded percent on `websecure`, or give Harbor its own entrypoint.
- **Large pushes:** Traefik v3's default entrypoint `readTimeout` is 60s. Very large layers on a slow link
  could hit it; raise `respondingTimeouts.readTimeout` if pushes fail.
- **containerd 2:** the drop-in uses the containerd 1.7 format (`version = 2`, `io.containerd.grpc.v1.cri`).
  k0s releases that ship containerd 2 refuse to start with it. Convert it to `version = 3` /
  `io.containerd.cri.v1.images` in `registry-mirror.yaml` **before** that k0s upgrade.
- **Storage:** 30Gi registry PVC on Longhorn for now. Only the database is backed up: cached images can be
  pulled again, and own images are expected to be rebuildable from Git. On the NAS, the registry
  belongs on the HDD pool (large, sequential) and the database on the SSD pool.
- **Disabling Harbor:** the mirror config stays on the nodes (pulls still work through the upstream fallback,
  just a little slower). Remove `/etc/k0s/containerd.d/registry-mirrors.toml` and `certs.d/` on each node.
  Disabling the HelmRelease also deletes its PVCs, but the Longhorn volumes are kept (Retain).
- **Login:** Harbor uses local users (admin and robots). Authelia OIDC is possible, but Harbor only switches
  auth mode while it has no local users besides admin; decide that before creating any.
