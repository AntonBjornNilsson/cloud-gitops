// grafana-folder: Security
// Trivy config audit and RBAC assessment: failed Kubernetes manifest checks
// grouped by check, so one misconfiguration can be fixed everywhere at once,
// plus risky Roles/ClusterRoles.
local grafonnet = import 'grafonnet-v11.0.0/main.libsonnet';
local t = import 'trivy.libsonnet';

local dashboard = grafonnet.dashboard;
local row = grafonnet.panel.row;
local barGauge = grafonnet.panel.barGauge;

local audits = t.active('trivy_configaudits_info{namespace=~"$namespace", config_audit_id=~"$check", severity=~"$severity", config_audit_success="false"}');
local rbac = 'trivy_rbacassessments_info{namespace=~"$namespace", severity=~"$severity", rbac_assessment_success="false"}';
local CHECK = 'config_audit_id, severity, config_audit_title, config_audit_category, config_audit_description';
local clusterRbac(sev) =
  'sum by (name) (trivy_clusterrole_clusterrbacassessments{severity="%s"}) or 0 * sum by (name) (trivy_clusterrole_clusterrbacassessments{severity=~"$severity"} > 0)' % sev;

dashboard.new('Trivy / Config & RBAC audit')
+ dashboard.withUid('trivy-config-audit')
+ dashboard.withDescription('Failed Trivy config-audit checks grouped by check and resource, and RBAC assessment findings for Roles and ClusterRoles.')
+ dashboard.withTags(['security', 'trivy'])
+ dashboard.withTimezone('browser')
+ dashboard.time.withFrom('now-1h')
+ dashboard.time.withTo('now')
+ dashboard.withRefresh('5m')
+ dashboard.withLinks(t.links)
+ dashboard.withVariables([
  t.queryVar('namespace', 'Namespace', 'label_values(trivy_configaudits_info, namespace)'),
  t.queryVar('check', 'Check', 'label_values(trivy_configaudits_info{namespace=~"$namespace", severity=~"$severity"}, config_audit_id)'),
  t.severityVar,
  t.inactiveVar,
])
+ dashboard.withPanels([
  row.new('Config audit') + t.pos(0, 0, 24, 1),
  t.statPanel('Failed checks', 'count(%s)' % audits, 'orange', 'Check x resource pairs.') + t.pos(0, 1, 6, 4),
  t.statPanel('Distinct checks', 'count(count by (config_audit_id) (%s))' % audits, 'orange') + t.pos(6, 1, 6, 4),
  t.statPanel('Resources affected', 'count(count by (namespace, resource_kind, resource_name) (%s))' % audits, 'orange') + t.pos(12, 1, 6, 4),
  t.statPanel('Role findings', 'count(%s)' % rbac, 'orange') + t.pos(18, 1, 6, 4),

  t.tablePanel(
    'Checks',
    [t.instant('count by (%s) (%s)' % [CHECK, audits])],
    [
      ['config_audit_id', 'Check'],
      ['severity', 'Severity'],
      ['Value', 'Resources'],
      ['config_audit_title', 'Title'],
      ['config_audit_description', 'Description'],
      ['config_audit_category', 'Category'],
    ],
    [
      t.severityColumn('Severity'),
      t.linkColumn('Check', [t.link('Filter on this check', '/d/trivy-config-audit/?${namespace:queryparam}&var-check=${__value.raw}&var-severity=All&${inactive:queryparam}&${__url_time_range}')]),
      t.override('Description', { 'custom.width': 600 }),
    ],
    'Resources',
    'One row per check. Fixing it usually means one change in a shared pattern (securityContext, resources, probes) across many manifests.',
  ) + t.pos(0, 5, 16, 12),

  barGauge.new('Failed checks by namespace')
  + barGauge.queryOptions.withTargets([
    t.instant('sort_desc(count by (namespace) (%s))' % audits) + { format: 'time_series', legendFormat: '{{namespace}}' },
  ])
  + barGauge.options.withOrientation('horizontal')
  + barGauge.options.withDisplayMode('basic')
  + barGauge.options.withShowUnfilled(true)
  + barGauge.options.reduceOptions.withCalcs(['lastNotNull'])
  + barGauge.standardOptions.color.withMode('continuous-YlRd')
  + barGauge.standardOptions.withLinks([t.link('Filter on this namespace', '/d/trivy-config-audit/?var-namespace=${__field.labels.namespace}&${check:queryparam}&${severity:queryparam}&${inactive:queryparam}&${__url_time_range}')])
  + t.pos(16, 5, 8, 12),

  t.tablePanel(
    'Failing resources',
    [t.instant(audits)],
    [
      ['namespace', 'Namespace'],
      ['resource_kind', 'Kind'],
      ['resource_name', 'Resource'],
      ['severity', 'Severity'],
      ['config_audit_id', 'Check'],
      ['config_audit_title', 'Title'],
      ['config_audit_description', 'Description'],
    ],
    [
      t.severityColumn('Severity'),
      t.linkColumn('Resource', [t.workloadLink]),
      t.override('Description', { 'custom.width': 600 }),
    ],
    null,
    'Narrow with the Check variable or by clicking a check above.',
  ) + t.pos(0, 17, 24, 12),

  row.new('RBAC assessment') + t.pos(0, 29, 24, 1),
  t.tablePanel(
    'Role findings',
    [t.instant(rbac)],
    [
      ['namespace', 'Namespace'],
      ['name', 'Report'],
      ['severity', 'Severity'],
      ['rbac_assessment_id', 'Check'],
      ['rbac_assessment_title', 'Title'],
      ['rbac_assessment_description', 'Description'],
    ],
    [
      t.severityColumn('Severity'),
      t.override('Description', { 'custom.width': 600 }),
    ],
    null,
    'Report is "role-<name>", or "role-<hash>" for long names: `kubectl get rbacassessmentreport -n <namespace> <report> -o yaml` shows the role and the offending rules. Roles shipped by Helm charts are usually expected; look for our own.',
  ) + t.pos(0, 30, 24, 10),

  t.tablePanel(
    'ClusterRole findings',
    [
      t.instant(clusterRbac('Critical'), 'A'),
      t.instant(clusterRbac('High'), 'B'),
      t.instant(clusterRbac('Medium'), 'C'),
      t.instant(clusterRbac('Low'), 'D'),
    ],
    [
      ['name', 'Report'],
      ['Value #A', 'Critical'],
      ['Value #B', 'High'],
      ['Value #C', 'Medium'],
      ['Value #D', 'Low'],
    ],
    [
      t.countColumn('Critical', 'dark-red'),
      t.countColumn('High', 'orange'),
      t.countColumn('Medium', 'yellow'),
      t.countColumn('Low', 'blue'),
    ],
    'Critical',
    'trivy-operator only exports counts for ClusterRoles. `kubectl get clusterrbacassessmentreport <report> -o yaml` shows the checks; the trivy-operator.resource.name label names the ClusterRole.',
  ) + t.pos(0, 40, 24, 10),
])
