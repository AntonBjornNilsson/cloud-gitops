// grafana-folder: Security
// Trivy CVE explorer: start from a CVE or package and see every image and
// workload it affects, plus the most widespread CVEs and packages.
local grafonnet = import 'grafonnet-v11.0.0/main.libsonnet';
local t = import 'trivy.libsonnet';

local dashboard = grafonnet.dashboard;
local row = grafonnet.panel.row;
local barGauge = grafonnet.panel.barGauge;

local vuln = 'trivy_vulnerability_id{vuln_id=~"$cve", resource=~"$package", severity=~"$severity"}';
local avuln = t.active(vuln);
local IMG = 'image_repository, image_tag';
local DETAIL = 'vuln_id, severity, vuln_score, vuln_title, published_date, last_modified_date';

local topBars(title, expr, legend, link, description) =
  barGauge.new(title)
  + barGauge.queryOptions.withTargets([
    t.instant(expr) + { format: 'time_series', legendFormat: legend },
  ])
  + barGauge.options.withOrientation('horizontal')
  + barGauge.options.withDisplayMode('basic')
  + barGauge.options.withShowUnfilled(true)
  + barGauge.options.reduceOptions.withCalcs(['lastNotNull'])
  + barGauge.standardOptions.color.withMode('continuous-YlRd')
  + barGauge.standardOptions.withLinks([link])
  + barGauge.panelOptions.withDescription(description);

dashboard.new('Trivy / CVE explorer')
+ dashboard.withUid('trivy-cve')
+ dashboard.withDescription('Which images and workloads a CVE or package affects, and the most widespread CVEs and packages.')
+ dashboard.withTags(['security', 'trivy'])
+ dashboard.withTimezone('browser')
+ dashboard.time.withFrom('now-1h')
+ dashboard.time.withTo('now')
+ dashboard.withRefresh('5m')
+ dashboard.withLinks(t.links)
+ dashboard.withVariables([
  t.queryVar('cve', 'CVE', 'label_values(trivy_vulnerability_id{severity=~"$severity"}, vuln_id)'),
  t.queryVar('package', 'Package', 'label_values(trivy_vulnerability_id{vuln_id=~"$cve", severity=~"$severity"}, resource)'),
  t.severityVar,
  t.inactiveVar,
])
+ dashboard.withPanels([
  row.new('Summary') + t.pos(0, 0, 24, 1),
  t.statPanel('CVEs', 'count(count by (vuln_id) (%s))' % avuln, 'orange') + t.pos(0, 1, 6, 4),
  t.statPanel('Packages', 'count(count by (resource) (%s))' % avuln, 'orange') + t.pos(6, 1, 6, 4),
  t.statPanel('Images', 'count(count by (%s) (%s))' % [IMG, avuln], 'orange') + t.pos(12, 1, 6, 4),
  t.statPanel('Workloads', 'count(count by (namespace, resource_name) (%s))' % avuln, 'orange') + t.pos(18, 1, 6, 4),

  topBars('Most widespread CVEs (images affected)',
          'topk(20, count by (vuln_id) (count by (vuln_id, %s) (%s)))' % [IMG, avuln],
          '{{vuln_id}}',
          t.link('Filter on this CVE', '/d/trivy-cve/?var-cve=${__field.labels.vuln_id}&var-package=All&${severity:queryparam}&${inactive:queryparam}&${__url_time_range}'),
          'A CVE in many images usually comes from a shared base image or library.')
  + t.pos(0, 5, 12, 12),
  topBars('Packages with the most CVEs',
          'topk(20, count by (resource) (count by (resource, vuln_id) (%s)))' % avuln,
          '{{resource}}',
          t.link('Filter on this package', '/d/trivy-cve/?var-cve=All&var-package=${__field.labels.resource}&${severity:queryparam}&${inactive:queryparam}&${__url_time_range}'),
          'Distinct CVEs per package across all images.')
  + t.pos(12, 5, 12, 12),

  row.new('Details') + t.pos(0, 17, 24, 1),
  t.tablePanel(
    'CVEs',
    [t.instant('count by (%s) (count by (%s, %s) (%s))' % [DETAIL, DETAIL, IMG, avuln])],
    [
      ['vuln_id', 'CVE'],
      ['severity', 'Severity'],
      ['vuln_score', 'Score'],
      ['Value', 'Images'],
      ['vuln_title', 'Title'],
      ['published_date', 'Published'],
      ['last_modified_date', 'Modified'],
    ],
    [
      t.severityColumn('Severity'),
      t.linkColumn('CVE', [t.osvLink, t.link('Filter on this CVE', '/d/trivy-cve/?var-cve=${__value.raw}&var-package=All&var-severity=All&${inactive:queryparam}&${__url_time_range}')]),
      t.override('Title', { 'custom.width': 600 }),
    ],
    'Images',
  ) + t.pos(0, 18, 24, 10),

  t.tablePanel(
    'Affected workloads',
    [t.instant('max by (namespace, resource_kind, resource_name, container_name, %s, resource, installed_version, fixed_version, vuln_id, severity) (%s)' % [IMG, avuln])],
    [
      ['namespace', 'Namespace'],
      ['resource_kind', 'Kind'],
      ['resource_name', 'Workload'],
      ['container_name', 'Container'],
      ['image_repository', 'Image'],
      ['image_tag', 'Tag'],
      ['vuln_id', 'CVE'],
      ['severity', 'Severity'],
      ['resource', 'Package'],
      ['installed_version', 'Installed'],
      ['fixed_version', 'Fixed in'],
    ],
    [
      t.severityColumn('Severity'),
      t.linkColumn('Workload', [t.workloadLink]),
      t.linkColumn('CVE', [t.osvLink]),
    ],
    null,
    'Narrow with the CVE / Package variables; click a workload for everything else wrong with it.',
  ) + t.pos(0, 28, 24, 14),
])
