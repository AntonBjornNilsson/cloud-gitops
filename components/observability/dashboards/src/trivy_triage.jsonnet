// grafana-folder: Security
// Trivy triage: cluster-wide entry point into the drilldown dashboards. Worst
// images first, and the 30-day trend to see whether update PRs pay off.
local grafonnet = import 'grafonnet-v11.0.0/main.libsonnet';
local t = import 'trivy.libsonnet';

local dashboard = grafonnet.dashboard;
local row = grafonnet.panel.row;
local timeSeries = grafonnet.panel.timeSeries;
local prometheus = grafonnet.query.prometheus;

local distinctCves(sev) =
  'count(count by (vuln_id) (%s))' % t.active('trivy_vulnerability_id{severity="%s"}' % sev);

local sevColor(name, color) = t.override(name, { color: { mode: 'fixed', fixedColor: color } });

dashboard.new('Trivy / Triage')
+ dashboard.withUid('trivy-triage')
+ dashboard.withDescription('Cluster-wide Trivy entry point: worst images first, with links into the workload, CVE and config-audit drilldowns.')
+ dashboard.withTags(['security', 'trivy'])
+ dashboard.withTimezone('browser')
+ dashboard.time.withFrom('now-30d')
+ dashboard.time.withTo('now')
+ dashboard.withRefresh('5m')
+ dashboard.withLinks(t.links)
+ dashboard.withVariables([
  t.severityVar,
  t.inactiveVar,
])
+ dashboard.withPanels([
  row.new('Now') + t.pos(0, 0, 24, 1),
  t.statPanel('Critical CVEs', distinctCves('Critical'), 'dark-red', 'Distinct fixable CVEs across all running images.') + t.pos(0, 1, 4, 4),
  t.statPanel('High CVEs', distinctCves('High'), 'orange') + t.pos(4, 1, 4, 4),
  t.statPanel('Medium CVEs', distinctCves('Medium'), 'yellow') + t.pos(8, 1, 4, 4),
  t.statPanel('Images with criticals',
              'count(count by (image_repository, image_tag) (%s))' % t.active('trivy_vulnerability_id{severity="Critical"}'),
              'dark-red') + t.pos(12, 1, 4, 4),
  t.statPanel('Exposed secrets', 'count(%s)' % t.active('trivy_exposedsecrets_info'), 'purple') + t.pos(16, 1, 4, 4),
  t.statPanel('Failed config checks', 'count(%s)' % t.active('trivy_configaudits_info{config_audit_success="false"}'), 'orange') + t.pos(20, 1, 4, 4),

  t.imageTable('Images by findings', 'namespace=~".*"',
               'Sorted by critical CVEs. Click a workload for the packages to bump and the CVEs behind the counts.')
  + t.pos(0, 5, 24, 14),

  row.new('Trend') + t.pos(0, 19, 24, 1),
  timeSeries.new('Vulnerability findings by severity')
  + timeSeries.queryOptions.withTargets([
    prometheus.new('VictoriaMetrics', 'sum by (severity) (trivy_image_vulnerabilities{severity=~"$severity"})')
    + prometheus.withLegendFormat('{{severity}}'),
  ])
  + timeSeries.queryOptions.withInterval('1h')
  + timeSeries.panelOptions.withDescription('CVE x workload findings (a CVE in three workloads counts three times). Drops after update PRs merge; rises when new CVEs are published for unchanged images.')
  + timeSeries.fieldConfig.defaults.custom.withFillOpacity(10)
  + timeSeries.options.legend.withDisplayMode('table')
  + timeSeries.options.legend.withPlacement('right')
  + timeSeries.options.legend.withCalcs(['lastNotNull', 'min', 'max'])
  + timeSeries.standardOptions.withOverrides([
    sevColor('Critical', 'dark-red'),
    sevColor('High', 'orange'),
    sevColor('Medium', 'yellow'),
    sevColor('Low', 'blue'),
    sevColor('Unknown', 'text'),
  ])
  + t.pos(0, 20, 16, 10),
  timeSeries.new('Exposed secrets and failed config checks')
  + timeSeries.queryOptions.withTargets([
    prometheus.new('VictoriaMetrics', 'sum(trivy_image_exposedsecrets)') + prometheus.withLegendFormat('exposed secrets'),
    prometheus.new('VictoriaMetrics', 'sum(trivy_resource_configaudits)') + prometheus.withLegendFormat('config audit findings'),
  ])
  + timeSeries.queryOptions.withInterval('1h')
  + timeSeries.options.legend.withDisplayMode('list')
  + timeSeries.options.legend.withPlacement('bottom')
  + t.pos(16, 20, 8, 10),
])
