// grafana-folder: Networking
// Remote access: the two ways into the homelab from outside.
// - Cloudflare tunnel (public hostnames): cloudflared connectors and the cfgate
//   controller that manages tunnel, DNS and Access from Git
//   (components/networking/cfgate; VMPodScrape cloudflared + chart ServiceMonitor).
// - Tailscale subnet router (tailnet devices -> home LAN): the Connector's proxy
//   pod (components/networking/tailscale; ProxyClass metrics). Upstream calls
//   these metrics unstable, so re-check names after operator bumps.
local grafonnet = import 'grafonnet-v11.0.0/main.libsonnet';
local m = import 'media.libsonnet';

local dashboard = grafonnet.dashboard;
local q = m.q;

local cfgate = 'namespace="cfgate-system"';
local ok = [{ color: 'green', value: null }, { color: 'red', value: 1 }];

dashboard.new('Remote Access')
+ dashboard.withUid('remote-access')
+ dashboard.withDescription('Cloudflare tunnel (cloudflared + cfgate) and the Tailscale subnet router.')
+ dashboard.withTags(['networking', 'cloudflare', 'tailscale'])
+ dashboard.withTimezone('browser')
+ dashboard.time.withFrom('now-24h')
+ dashboard.time.withTo('now')
+ dashboard.withRefresh('1m')
+ dashboard.graphTooltip.withSharedCrosshair()
+ dashboard.withPanels([
  // --- Overview ---------------------------------------------------------------
  m.row('Overview', 0),
  m.stat('Tunnel edge connections', 'sum(cloudflared_tunnel_ha_connections)', 0, 1, w=4,
         thresholds=[{ color: 'red', value: null }, { color: 'green', value: 1 }], noValue='0',
         desc='Connections from all cloudflared connectors to the Cloudflare edge (4 per connector). 0 = every public hostname is down.'),
  m.stat('Degraded connectors', 'count(cloudflared_tunnel_ha_connections < 4) or vector(0)', 4, 1, w=4,
         thresholds=[{ color: 'green', value: null }, { color: 'orange', value: 1 }],
         desc='Connectors with fewer than 4 edge connections (some edge locations unreachable).'),
  m.stat('Tunnel requests/s', 'sum(rate(cloudflared_tunnel_total_requests[$__rate_interval]))', 8, 1, w=4,
         unit='reqps', decimals=2, graph=true),
  m.stat('Origin errors (24h)', 'sum(increase(cloudflared_tunnel_request_errors[24h])) or vector(0)', 12, 1, w=4,
         thresholds=ok, decimals=0,
         desc='Requests cloudflared could not proxy to Traefik (Service traefik-public).'),
  m.stat('Tailnet routes approved', 'sum(tailscaled_approved_routes) / sum(tailscaled_advertised_routes)', 16, 1, w=4,
         unit='percentunit', decimals=0, noValue='no metrics',
         thresholds=[{ color: 'red', value: null }, { color: 'green', value: 1 }],
         desc='Advertised subnet routes that are approved in the Tailscale admin console. Below 100%: those subnets are unreachable from the tailnet.'),
  m.stat('Tailscale health warnings', 'sum(tailscaled_health_messages{type="warning"})', 20, 1, w=4,
         thresholds=ok, noValue='no metrics',
         desc='tailscaled health warnings (logged out, key expiry, no DERP, DNS). Details: `tailscale status` in the ts-* pod.'),

  // --- Cloudflare tunnel --------------------------------------------------------
  m.row('Cloudflare tunnel (cloudflared)', 5),
  m.ts('Requests by status code', [
    q('sum by (status_code) (rate(cloudflared_tunnel_response_by_code[$__rate_interval]))', '{{status_code}}'),
  ], 0, 6, 12, 8, 'reqps', stack=true, min=0,
    desc='Responses returned to Cloudflare. 404s are usually scanners hitting paths no route serves.'),
  m.ts('Origin errors', [
    q('sum by (pod) (rate(cloudflared_tunnel_request_errors[$__rate_interval]))', '{{pod}}'),
  ], 12, 6, 6, 8, 'reqps', min=0, bars=true, legendRight=false,
    desc='Requests that failed between cloudflared and Traefik.'),
  m.ts('Open requests and sessions', [
    q('sum(cloudflared_tunnel_concurrent_requests_per_tunnel)', 'HTTP requests'),
    q('sum(cloudflared_tcp_active_sessions)', 'TCP sessions'),
    q('sum(cloudflared_udp_active_sessions)', 'UDP sessions'),
  ], 18, 6, 6, 8, min=0, legendRight=false),

  m.ts('Edge connections per connector', [
    q('sum by (pod) (cloudflared_tunnel_ha_connections)', '{{pod}}'),
  ], 0, 14, 8, 8, min=0, legendRight=false),
  m.labelTable('Edge locations', 'max by (pod, connection_id, edge_location) (cloudflared_tunnel_server_locations)',
               8, 14, 8, 8,
               rename={ pod: 'Connector', connection_id: 'Connection', edge_location: 'Edge location' },
               exclude={ pod: false, Value: true },
               desc='Cloudflare data centre each connection is attached to.'),
  m.ts('QUIC round-trip time to the edge', [
    q('max by (pod, conn_index) (quic_client_smoothed_rtt)', '{{pod}} #{{conn_index}}'),
  ], 16, 14, 8, 8, 'ms', min=0, legendRight=false),

  // (cloudflared_proxy_connect_latency only counts TCP/WARP private-network
  // sessions, which this tunnel does not carry, so it is not shown.)
  m.ts('Requests per connector', [
    q('sum by (pod) (rate(cloudflared_tunnel_total_requests[$__rate_interval]))', '{{pod}}'),
  ], 0, 22, 12, 7, 'reqps', min=0, legendRight=false,
    desc='Cloudflare spreads requests over all connected connectors; one at zero while the other serves is a connector that lost the edge.'),
  m.ts('Tunnel configuration version', [
    q('max by (pod) (cloudflared_orchestration_config_version)', '{{pod}}'),
  ], 12, 22, 12, 7, legendRight=false,
    desc='Goes up each time cfgate pushes new ingress rules. Connectors on different versions have not all applied the latest config.'),

  // --- cfgate controller -----------------------------------------------------------
  m.row('cfgate controller', 29),
  m.ts('Reconciles by controller', [
    q('sum by (controller) (rate(controller_runtime_reconcile_total{%s}[$__rate_interval]))' % cfgate, '{{controller}}'),
  ], 0, 30, 8, 8, 'ops', min=0, legendRight=false),
  m.ts('Reconcile errors', [
    q('sum by (controller) (increase(controller_runtime_reconcile_errors_total{%s}[$__interval]))' % cfgate, '{{controller}}'),
  ], 8, 30, 8, 8, min=0, bars=true, legendRight=false,
    desc='Failed syncs to Cloudflare (API errors, invalid resources). Check the resource status and the cfgate log below.'),
  m.ts('Time since last completed reconcile', [
    q('time() - max by (controller) (cfgate_controller_last_completed_reconcile_timestamp_seconds)', '{{controller}}'),
  ], 16, 30, 8, 8, 's', min=0, legendRight=false,
    desc='The Cloudflare controllers requeue every few minutes; a line that keeps climbing is a stuck controller.'),
  m.ts('Reconcile duration (p95)', [
    q('histogram_quantile(0.95, sum by (controller, le) (rate(controller_runtime_reconcile_time_seconds_bucket{%s}[$__rate_interval])))' % cfgate, '{{controller}}'),
  ], 0, 38, 12, 7, 's', min=0, legendRight=false),
  m.ts('Work queue depth', [
    q('sum by (name) (workqueue_depth{%s})' % cfgate, '{{name}}'),
  ], 12, 38, 12, 7, min=0, legendRight=false),

  // --- Tailscale ------------------------------------------------------------------
  m.row('Tailscale subnet router', 45),
  m.ts('Traffic by path', [
    q('sum by (path) (rate(tailscaled_inbound_bytes_total[$__rate_interval]))', 'in {{path}}'),
    q('-sum by (path) (rate(tailscaled_outbound_bytes_total[$__rate_interval]))', 'out {{path}}'),
  ], 0, 46, 12, 8, 'Bps',
    desc='In from the tailnet (positive) and out to it (negative). "derp" is relayed through Tailscale servers; "direct_*" is peer-to-peer.'),
  m.ts('Dropped outbound packets', [
    q('sum by (reason) (rate(tailscaled_outbound_dropped_packets_total[$__rate_interval]))', '{{reason}}'),
  ], 12, 46, 6, 8, 'pps', min=0, legendRight=false,
    desc='unknown_protocol is normal noise (protocols WireGuard does not carry); error is not.'),
  m.stat('Advertised routes', 'sum(tailscaled_advertised_routes)', 18, 46, noValue='no metrics'),
  m.stat('Approved routes', 'sum(tailscaled_approved_routes)', 21, 46, noValue='no metrics'),
  m.stat('Home DERP region', 'max(tailscaled_home_derp_region_id)', 18, 50, noValue='-',
         desc='ID of the nearest Tailscale relay region. Changes when connectivity changes.'),
  m.stat('Health warnings', 'sum(tailscaled_health_messages{type="warning"})', 21, 50, thresholds=ok, noValue='-'),

  // --- Pods -----------------------------------------------------------------------
  m.row('Pods', 54),
  m.ts('CPU', [
    q('sum by (pod) (rate(container_cpu_usage_seconds_total{namespace=~"cfgate-system|tailscale", container!=""}[$__rate_interval]))', '{{pod}}'),
  ], 0, 55, 12, 7, 'cores', min=0, legendRight=false),
  m.ts('Memory', [
    q('sum by (pod) (container_memory_working_set_bytes{namespace=~"cfgate-system|tailscale", container!=""})', '{{pod}}'),
  ], 12, 55, 12, 7, 'bytes', min=0, legendRight=false),
  m.logs('Errors and warnings', m.errorLogs('cfgate-system|tailscale'), 0, 62, 24, 10),
])
