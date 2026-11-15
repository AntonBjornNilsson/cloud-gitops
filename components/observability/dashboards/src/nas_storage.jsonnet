// grafana-folder: Storage
// NAS storage from the cluster's side: the TrueNAS CSI controller (chart
// ServiceMonitor, CSI sidecars included), the VolumeSnapshot controller and the
// volumes it provisioned. Disk health is the "smartctl" dashboard; the NAS itself
// has its own UI.
// Mounted volumes keep working while the CSI controller is broken: it is needed
// to create, attach, resize, snapshot and delete volumes.
// truenas_csi_volume_operations_total and the snapshot-controller histogram only
// exist after the first such operation, hence the "no operations" placeholders.
local grafonnet = import 'grafonnet-v11.0.0/main.libsonnet';
local m = import 'media.libsonnet';

local dashboard = grafonnet.dashboard;
local q = m.q;

local csi = 'namespace="truenas-csi"';
// CSI calls the sidecars make constantly; left out of the operation panels
local housekeeping = 'Probe|GetPluginInfo|GetPluginCapabilities|ControllerGetCapabilities';
local ok = [{ color: 'green', value: null }, { color: 'red', value: 1 }];

dashboard.new('NAS Storage')
+ dashboard.withUid('nas-storage')
+ dashboard.withDescription('TrueNAS CSI driver (NAS API, volume operations), VolumeSnapshots and volume usage.')
+ dashboard.withTags(['storage', 'truenas', 'csi'])
+ dashboard.withTimezone('browser')
+ dashboard.time.withFrom('now-24h')
+ dashboard.time.withTo('now')
+ dashboard.withRefresh('1m')
+ dashboard.graphTooltip.withSharedCrosshair()
+ dashboard.withPanels([
  // --- Overview ---------------------------------------------------------------
  m.row('Overview', 0),
  m.stat('NAS API', 'max(truenas_csi_api_connected)', 0, 1, w=4,
         thresholds=[{ color: 'red', value: null }, { color: 'green', value: 1 }], noValue='no metrics',
         desc='The CSI controller\'s WebSocket connection to the TrueNAS API.')
  + grafonnet.panel.stat.standardOptions.withMappings(m.upDownMappings),
  m.stat('API reconnects (24h)', 'sum(increase(truenas_csi_api_reconnects_total[24h])) or vector(0)', 4, 1, w=4,
         decimals=0, thresholds=[{ color: 'green', value: null }, { color: 'orange', value: 1 }, { color: 'red', value: 4 }]),
  m.stat('Failed API calls (24h)', 'sum(increase(truenas_csi_api_calls_total{status!="success"}[24h])) or vector(0)', 8, 1, w=4,
         decimals=0, thresholds=ok),
  m.stat('Failed CSI operations (24h)', 'sum(increase(csi_sidecar_operations_seconds_count{%s, grpc_status_code!~"OK|Aborted"}[24h])) or vector(0)' % csi, 12, 1, w=4,
         decimals=0, thresholds=ok,
         desc='CreateVolume, attach, resize, snapshot and delete calls that failed. Aborted (a retry while the operation is still running) is left out.'),
  m.stat('PVCs on the NAS', 'count(kube_persistentvolumeclaim_info{storageclass=~"nas-.*"})', 16, 1, w=4,
         desc='Claims of the nas-iscsi and nas-nfs StorageClasses (the static media library PVs are not counted).'),
  m.stat('Snapshots in progress', 'max(snapshot_controller_operations_in_flight)', 20, 1, w=4,
         thresholds=[{ color: 'blue', value: null }], noValue='no metrics'),

  // --- TrueNAS API -------------------------------------------------------------
  m.row('TrueNAS API', 5),
  m.ts('API calls by method', [
    q('sum by (method) (rate(truenas_csi_api_calls_total[$__rate_interval])) > 0', '{{method}}'),
  ], 0, 6, 12, 8, 'ops', min=0)
  + grafonnet.panel.timeSeries.standardOptions.withNoValue('no API calls (idle between volume operations)'),
  m.ts('API call duration (p95)', [
    q('histogram_quantile(0.95, sum by (method, le) (rate(truenas_csi_api_call_duration_seconds_bucket[$__rate_interval])))', '{{method}}'),
  ], 12, 6, 12, 8, 's', min=0)
  + grafonnet.panel.timeSeries.standardOptions.withNoValue('no API calls (idle between volume operations)'),
  m.ts('Failed API calls', [
    q('sum by (method, status) (increase(truenas_csi_api_calls_total{status!="success"}[$__interval])) > 0', '{{method}} ({{status}})'),
  ], 0, 14, 12, 7, min=0, bars=true)
  + grafonnet.panel.timeSeries.standardOptions.withNoValue('no failed calls'),
  m.ts('Connection', [
    q('max(truenas_csi_api_connected)', 'connected'),
    q('sum(increase(truenas_csi_api_reconnects_total[$__interval]))', 'reconnects'),
  ], 12, 14, 12, 7, min=0, legendRight=false),

  // --- Volume operations ---------------------------------------------------------
  m.row('Volume operations (CSI)', 21),
  m.ts('Operations by method', [
    q('sum by (method_name, grpc_status_code) (increase(csi_sidecar_operations_seconds_count{%s, method_name!~".*/(%s)"}[$__interval])) > 0' % [csi, housekeeping],
      '{{method_name}} {{grpc_status_code}}'),
  ], 0, 22, 12, 8, min=0, bars=true,
    desc='Calls from the CSI sidecars (provisioner, attacher, snapshotter, resizer) to the driver, by result.')
  + grafonnet.panel.timeSeries.standardOptions.withNoValue('no volume operations'),
  m.ts('Operation duration (p95)', [
    q('histogram_quantile(0.95, sum by (method_name, le) (rate(csi_sidecar_operations_seconds_bucket{%s, method_name!~".*/(%s)"}[$__rate_interval])))' % [csi, housekeeping],
      '{{method_name}}'),
  ], 12, 22, 12, 8, 's', min=0)
  + grafonnet.panel.timeSeries.standardOptions.withNoValue('no volume operations'),
  m.labelTable('Failed operations (time range)',
               'sum by (method_name, grpc_status_code) (increase(csi_sidecar_operations_seconds_count{%s, grpc_status_code!="OK"}[$__range])) > 0' % csi,
               0, 30, 12, 7,
               rename={ method_name: 'Method', grpc_status_code: 'Code', Value: 'Count' },
               overrides=[m.byName('Count', [m.decimals(0), m.width(80)])],
               desc='Empty = no failures. Details are in the controller log below and in `kubectl get events -A`.'),
  m.ts('Volumes created, expanded, snapshotted, deleted', [
    q('sum by (operation, protocol, status) (increase(truenas_csi_volume_operations_total[$__interval])) > 0', '{{operation}} {{protocol}} {{status}}'),
  ], 12, 30, 12, 7, min=0, bars=true,
    desc='Driver-side count of finished volume operations (no data until the first one after the controller started).')
  + grafonnet.panel.timeSeries.standardOptions.withNoValue('no volume operations yet'),

  // --- Snapshots -------------------------------------------------------------------
  m.row('VolumeSnapshots (snapshot-controller)', 37),
  m.ts('Snapshot operations', [
    q('sum by (operation_name, operation_status) (increase(snapshot_controller_operation_total_seconds_count[$__interval])) > 0', '{{operation_name}} {{operation_status}}'),
  ], 0, 38, 8, 7, min=0, bars=true, legendRight=false,
    desc='Status "unknown" is how the controller records a failure.')
  + grafonnet.panel.timeSeries.standardOptions.withNoValue('no snapshot operations yet'),
  m.ts('Snapshot operation duration (p95)', [
    q('histogram_quantile(0.95, sum by (operation_name, le) (rate(snapshot_controller_operation_total_seconds_bucket[$__rate_interval])))', '{{operation_name}}'),
  ], 8, 38, 8, 7, 's', min=0, legendRight=false)
  + grafonnet.panel.timeSeries.standardOptions.withNoValue('no snapshot operations yet'),
  m.ts('Operations in progress', [
    q('max(snapshot_controller_operations_in_flight)', 'in flight'),
  ], 16, 38, 8, 7, min=0, legendRight=false),

  // --- Volumes -------------------------------------------------------------------------
  m.row('Volumes', 45),
  m.barGauge('Fullest volumes', [
    q('topk(15, max by (namespace, persistentvolumeclaim) (kubelet_volume_stats_used_bytes / kubelet_volume_stats_capacity_bytes))', '{{namespace}}/{{persistentvolumeclaim}}'),
  ], 0, 46, 12, 10, 'percentunit',
    thresholds=[{ color: 'green', value: null }, { color: 'orange', value: 0.8 }, { color: 'red', value: 0.9 }], max=1,
    desc='Filesystem usage of mounted volumes, as the kubelet sees it. Volumes that are not mounted right now are missing.'),
  m.labelTable('Claims by StorageClass',
               'count by (storageclass) (kube_persistentvolumeclaim_info)',
               12, 46, 6, 10,
               rename={ storageclass: 'StorageClass', Value: 'PVCs' },
               overrides=[m.byName('PVCs', [m.decimals(0)])]),
  m.labelTable('Claims not Bound',
               'max by (namespace, persistentvolumeclaim, phase) (kube_persistentvolumeclaim_status_phase{phase!="Bound"}) == 1',
               18, 46, 6, 10,
               rename={ persistentvolumeclaim: 'PVC', phase: 'Phase' },
               exclude={ namespace: false, Value: true },
               desc='Empty = every claim is bound.'),

  // --- Pods -----------------------------------------------------------------------------
  m.row('Pods', 56),
  m.ts('CPU', [
    q('sum by (pod) (rate(container_cpu_usage_seconds_total{namespace=~"truenas-csi|snapshot-controller", container!=""}[$__rate_interval]))', '{{pod}}'),
  ], 0, 57, 12, 7, 'cores', min=0, legendRight=false),
  m.ts('Memory', [
    q('sum by (pod) (container_memory_working_set_bytes{namespace=~"truenas-csi|snapshot-controller", container!=""})', '{{pod}}'),
  ], 12, 57, 12, 7, 'bytes', min=0, legendRight=false),
  m.logs('Errors and warnings', m.errorLogs('truenas-csi|snapshot-controller'), 0, 64, 24, 10),
])
