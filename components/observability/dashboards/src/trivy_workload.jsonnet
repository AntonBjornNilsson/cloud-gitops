// grafana-folder: Security
// Trivy drilldown for one or more workloads: which image, which packages to
// bump to which version, and the individual CVEs, exposed secrets and failed
// config checks behind the counts on the "Trivy Operator" dashboard.
local grafonnet = import 'grafonnet-v11.0.0/main.libsonnet';
local t = import 'trivy.libsonnet';

local dashboard = grafonnet.dashboard;
local row = grafonnet.panel.row;

local sel = 'namespace=~"$namespace", resource_name=~"$workload", container_name=~"$container"';
local vuln = 'trivy_vulnerability_id{%s, severity=~"$severity"}' % sel;
local secrets = 'trivy_exposedsecrets_info{%s}' % sel;
local audits = 'trivy_configaudits_info{namespace=~"$namespace", resource_name=~"$workload", config_audit_success="false"}';

local distinctCves(sev) =
  'count(count by (vuln_id) (%s))' % t.active('trivy_vulnerability_id{%s, severity="%s"}' % [sel, sev]);

local FIX = 'image_repository, image_tag, resource, installed_version, fixed_version';
local CVE = 'vuln_id, severity, vuln_score, vuln_title, resource, installed_version, fixed_version, image_repository, image_tag, published_date';

dashboard.new('Trivy / Workload drilldown')
+ dashboard.withUid('trivy-workload')
+ dashboard.withDescription('Per-workload Trivy findings: images, packages to upgrade, CVEs, exposed secrets and failed config checks.')
+ dashboard.withTags(['security', 'trivy'])
+ dashboard.withTimezone('browser')
+ dashboard.time.withFrom('now-1h')
+ dashboard.time.withTo('now')
+ dashboard.withRefresh('5m')
+ dashboard.withLinks(t.links)
+ dashboard.withVariables([
  t.queryVar('namespace', 'Namespace', 'label_values(trivy_image_info, namespace)'),
  t.queryVar('workload', 'Workload',
             'query_result(%s)' % t.active('count by (namespace, resource_name) (trivy_image_info{namespace=~"$namespace"})'),
             '/resource_name="([^"]+)"/'),
  t.queryVar('container', 'Container', 'label_values(trivy_image_info{namespace=~"$namespace", resource_name=~"$workload"}, container_name)'),
  t.severityVar,
  t.inactiveVar,
])
+ dashboard.withPanels([
  row.new('Summary') + t.pos(0, 0, 24, 1),
  t.statPanel('Critical CVEs', distinctCves('Critical'), 'dark-red') + t.pos(0, 1, 4, 4),
  t.statPanel('High CVEs', distinctCves('High'), 'orange') + t.pos(4, 1, 4, 4),
  t.statPanel('Medium CVEs', distinctCves('Medium'), 'yellow') + t.pos(8, 1, 4, 4),
  t.statPanel('Unknown CVEs', distinctCves('Unknown'), 'text',
              'CVEs without a vendor severity yet (usually very recent ones). Check the score column.') + t.pos(12, 1, 4, 4),
  t.statPanel('Exposed secrets', 'count(%s)' % t.active(secrets), 'purple') + t.pos(16, 1, 4, 4),
  t.statPanel('Failed config checks', 'count(%s)' % t.active(audits), 'orange') + t.pos(20, 1, 4, 4),

  t.imageTable('Images', sel, 'One row per container image. Click a workload to narrow the dashboard to it.')
  + t.pos(0, 5, 24, 8),

  row.new('What to fix') + t.pos(0, 13, 24, 1),
  t.tablePanel(
    'Packages to upgrade',
    [
      t.instant('max by (%s) (%s)' % [FIX, t.severityRank(t.active(vuln))], 'A'),
      t.instant('count by (%s) (count by (%s, vuln_id) (%s))' % [FIX, FIX, t.active(vuln)], 'B'),
      t.instant('max by (%s) (label_value(%s, "vuln_score"))' % [FIX, t.active(vuln)], 'C'),
    ],
    [
      ['image_repository', 'Image'],
      ['image_tag', 'Tag'],
      ['resource', 'Package'],
      ['installed_version', 'Installed'],
      ['fixed_version', 'Fixed in'],
      ['Value #A', 'Worst severity'],
      ['Value #B', 'CVEs'],
      ['Value #C', 'Max score'],
    ],
    [
      t.severityRankColumn('Worst severity'),
      t.override('Max score', { decimals: 1 }),
    ],
    'Worst severity',
    'Each row is one package upgrade that closes the listed number of CVEs. Usually fixed by bumping the image tag; if the upstream image has not picked up the fix yet, the package is a transitive dependency of the app.',
  ) + t.pos(0, 14, 24, 10),

  t.tablePanel(
    'CVEs',
    [t.instant('max by (%s) (%s)' % [CVE, t.active(vuln)])],
    [
      ['vuln_id', 'CVE'],
      ['severity', 'Severity'],
      ['vuln_score', 'Score'],
      ['resource', 'Package'],
      ['installed_version', 'Installed'],
      ['fixed_version', 'Fixed in'],
      ['vuln_title', 'Title'],
      ['image_repository', 'Image'],
      ['image_tag', 'Tag'],
      ['published_date', 'Published'],
    ],
    [
      t.severityColumn('Severity'),
      t.linkColumn('CVE', [t.osvLink, t.cveLink]),
      t.override('Title', { 'custom.width': 500 }),
      t.override('Score', { decimals: 1, 'custom.width': 70 }),
    ],
    'Score',
    'Click a CVE for the advisory or for every workload it affects.',
  ) + t.pos(0, 24, 24, 14)
  + { transformations+: [{ id: 'convertFieldType', options: { conversions: [{ targetField: 'Score', destinationType: 'number' }] } }] },

  row.new('Secrets and configuration') + t.pos(0, 38, 24, 1),
  t.tablePanel(
    'Exposed secrets',
    [t.instant(t.active(secrets))],
    [
      ['namespace', 'Namespace'],
      ['resource_name', 'Workload'],
      ['container_name', 'Container'],
      ['image_repository', 'Image'],
      ['image_tag', 'Tag'],
      ['severity', 'Severity'],
      ['secret_title', 'Secret'],
      ['secret_category', 'Category'],
      ['secret_target', 'File'],
    ],
    [t.severityColumn('Severity')],
    null,
    'Credentials or private keys baked into the image. In upstream images these are usually test fixtures or snakeoil certs; in our own images, rotate them.',
  ) + t.pos(0, 39, 24, 8),

  t.tablePanel(
    'Failed config checks',
    [t.instant(t.active(audits))],
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
      t.linkColumn('Check', [t.link('All resources failing this check', '/d/trivy-config-audit/?var-namespace=All&var-check=${__value.raw}&var-severity=All&${inactive:queryparam}&${__url_time_range}')]),
    ],
    null,
    'Kubernetes manifest checks for the selected workloads (pod spec of the ReplicaSet/StatefulSet/...). Fix them in the manifest or HelmRelease values.',
  ) + t.pos(0, 47, 24, 10),
])
