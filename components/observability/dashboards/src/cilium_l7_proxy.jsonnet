// grafana-folder: Networking
// Cilium L7 proxy and Hubble Relay (components/networking/cilium; chart
// ServiceMonitors cilium-envoy and hubble-relay).
// cilium-envoy is the per-node Envoy that enforces HTTP-aware policy rules and
// produces the httpV2 flow metrics; it gets its policy from the Cilium agent over
// NPDS. Its "proxy" listener is real L7 traffic; admin/health/metrics listeners
// are left out. Envoy reports times in milliseconds.
// Hubble Relay only serves the Hubble UI and CLI; flow metrics come from the agents
// (community dashboards "Hubble ...").
local grafonnet = import 'grafonnet-v11.0.0/main.libsonnet';
local m = import 'media.libsonnet';

local dashboard = grafonnet.dashboard;
local q = m.q;

local proxy = 'envoy_http_conn_manager_prefix="proxy"';
local relay = 'namespace="kube-system", pod=~"hubble-relay-.*"';
local ok = [{ color: 'green', value: null }, { color: 'red', value: 1 }];

dashboard.new('Cilium L7 Proxy')
+ dashboard.withUid('cilium-l7-proxy')
+ dashboard.withDescription('cilium-envoy (L7 policy enforcement, NPDS policy stream) and Hubble Relay.')
+ dashboard.withTags(['networking', 'cilium', 'envoy', 'hubble'])
+ dashboard.withTimezone('browser')
+ dashboard.time.withFrom('now-24h')
+ dashboard.time.withTo('now')
+ dashboard.withRefresh('1m')
+ dashboard.graphTooltip.withSharedCrosshair()
+ dashboard.withPanels([
  // --- Overview ---------------------------------------------------------------
  m.row('Overview', 0),
  m.stat('Envoys connected to agent', 'sum(envoy_cilium_npds_control_plane_connected_state) / count(envoy_cilium_npds_control_plane_connected_state)', 0, 1, w=4,
         unit='percentunit', decimals=0, thresholds=[{ color: 'red', value: null }, { color: 'green', value: 1 }],
         desc='Share of cilium-envoy pods with a live policy (NPDS) stream to their Cilium agent. Envoys that never received an L7 policy report no stream.'),
  m.stat('Nodes failing policy updates', 'count(sum by (node) (increase(envoy_cilium_npds_update_failure[5m])) > 0) or vector(0)', 4, 1, w=4,
         thresholds=[{ color: 'green', value: null }, { color: 'orange', value: 1 }], decimals=0,
         desc='Envoys with failed NPDS updates in the last 5 minutes. A Cilium agent restart (e.g. an upgrade) causes a short burst; failures that last 30 minutes fire CiliumEnvoyPolicyUpdatesFailing.'),
  m.stat('Rejected policies (1h)', '(sum(increase(envoy_cilium_npds_update_rejected[1h])) or vector(0)) + (sum(increase(envoy_cilium_policy_updates_rejected[1h])) or vector(0))', 8, 1, w=4,
         thresholds=ok, decimals=0,
         desc='Policies Envoy refused (an L7 rule it cannot apply).'),
  m.stat('L7 requests/s', 'sum(rate(envoy_http_downstream_rq_total{%s}[$__rate_interval]))' % proxy, 12, 1, w=4,
         unit='reqps', decimals=2, graph=true),
  m.stat('L7 denied (24h)', 'sum(increase(envoy_cilium_access_denied[24h])) or vector(0)', 16, 1, w=4,
         decimals=0, thresholds=[{ color: 'blue', value: null }],
         desc='Requests denied by an L7 policy rule (403 from the proxy).'),
  m.stat('Relay peers healthy', 'sum(hubble_relay_pool_peer_connection_status{status=~"READY|IDLE"}) / sum(hubble_relay_pool_peer_connection_status)', 20, 1, w=4,
         unit='percentunit', decimals=0, noValue='no relay',
         thresholds=[{ color: 'orange', value: null }, { color: 'green', value: 1 }],
         desc='Cilium agents Hubble Relay can reach (IDLE = connected, no request open).'),

  // --- L7 traffic ---------------------------------------------------------------
  m.row('L7 traffic (proxy listener)', 5),
  m.ts('Requests by response class', [
    q('sum by (envoy_response_code_class) (rate(envoy_http_downstream_rq_xx{%s}[$__rate_interval]))' % proxy, '{{envoy_response_code_class}}xx'),
  ], 0, 6, 12, 8, 'reqps', stack=true, min=0),
  m.ts('Request duration', [
    q('histogram_quantile(0.5, sum by (le) (rate(envoy_http_downstream_rq_time_bucket{%s}[$__rate_interval])))' % proxy, 'p50'),
    q('histogram_quantile(0.95, sum by (le) (rate(envoy_http_downstream_rq_time_bucket{%s}[$__rate_interval])))' % proxy, 'p95'),
    q('histogram_quantile(0.99, sum by (le) (rate(envoy_http_downstream_rq_time_bucket{%s}[$__rate_interval])))' % proxy, 'p99'),
  ], 12, 6, 12, 8, 'ms', min=0, legendRight=false),
  m.ts('Active connections by node', [
    q('sum by (node) (envoy_http_downstream_cx_active{%s})' % proxy, '{{node}}'),
  ], 0, 14, 8, 8, min=0, legendRight=false),
  m.ts('Upstream connect failures', [
    q('sum by (envoy_cluster_name) (rate(envoy_cluster_upstream_cx_connect_fail{envoy_cluster_name!~"/envoy-admin|xds-grpc-cilium"}[$__rate_interval])) > 0', '{{envoy_cluster_name}}'),
  ], 8, 14, 8, 8, 'ops', min=0, legendRight=false,
    desc='Envoy could not connect to the destination pod after allowing the request.')
  + grafonnet.panel.timeSeries.standardOptions.withNoValue('none'),
  m.ts('Denied by L7 policy', [
    q('sum by (node) (rate(envoy_cilium_access_denied[$__rate_interval])) > 0', '{{node}}'),
  ], 16, 14, 8, 8, 'reqps', min=0, legendRight=false)
  + grafonnet.panel.timeSeries.standardOptions.withNoValue('none'),

  // --- Policy stream ----------------------------------------------------------------
  m.row('Policy updates (NPDS)', 22),
  m.ts('Policy updates by node', [
    q('sum by (node) (rate(envoy_cilium_npds_update_success[$__rate_interval]))', 'ok {{node}}'),
    q('sum by (node) (rate(envoy_cilium_npds_update_failure[$__rate_interval]))', 'failed {{node}}'),
    q('sum by (node) (rate(envoy_cilium_npds_update_rejected[$__rate_interval]))', 'rejected {{node}}'),
  ], 0, 23, 12, 8, 'ops', min=0,
    desc='Each Cilium agent restart (e.g. an upgrade) briefly shows thousands of failures while Envoy reconnects.'),
  m.ts('Connected to agent', [
    q('max by (node) (envoy_cilium_npds_control_plane_connected_state)', '{{node}}'),
  ], 12, 23, 6, 8, min=0, legendRight=false),
  m.ts('Policy update duration (p95)', [
    q('histogram_quantile(0.95, sum by (node, le) (rate(envoy_cilium_npds_update_duration_bucket[$__rate_interval])))', '{{node}}'),
  ], 18, 23, 6, 8, 'ms', min=0, legendRight=false),

  // --- Hubble Relay -------------------------------------------------------------------
  m.row('Hubble Relay', 31),
  m.ts('Peers by state', [
    q('sum by (status) (hubble_relay_pool_peer_connection_status) > 0', '{{status}}'),
  ], 0, 32, 8, 8, min=0, stack=true, legendRight=false,
    desc='Connections from the relay to each node\'s Cilium agent (port 4244).'),
  m.ts('Requests by method', [
    q('sum by (grpc_method) (rate(grpc_server_handled_total{%s}[$__rate_interval])) > 0' % relay, '{{grpc_method}}'),
  ], 8, 32, 8, 8, 'reqps', min=0, legendRight=false,
    desc='Hubble UI and `hubble observe` calls.')
  + grafonnet.panel.timeSeries.standardOptions.withNoValue('no requests (Hubble UI not in use)'),
  m.ts('Failed requests by code', [
    q('sum by (grpc_code) (rate(grpc_server_handled_total{%s, grpc_code!~"OK|Canceled"}[$__rate_interval])) > 0' % relay, '{{grpc_code}}'),
  ], 16, 32, 8, 8, 'reqps', min=0, legendRight=false,
    desc='Canceled is left out: it is a client closing a stream (e.g. leaving the Hubble UI).')
  + grafonnet.panel.timeSeries.standardOptions.withNoValue('none'),

  // --- Pods ---------------------------------------------------------------------------
  m.row('Pods', 40),
  m.ts('CPU', [
    q('sum by (pod) (rate(container_cpu_usage_seconds_total{namespace="kube-system", container=~"cilium-envoy|hubble-relay"}[$__rate_interval]))', '{{pod}}'),
  ], 0, 41, 12, 7, 'cores', min=0, legendRight=false),
  m.ts('Memory', [
    q('sum by (pod) (container_memory_working_set_bytes{namespace="kube-system", container=~"cilium-envoy|hubble-relay"})', '{{pod}}'),
  ], 12, 41, 12, 7, 'bytes', min=0, legendRight=false),
])
