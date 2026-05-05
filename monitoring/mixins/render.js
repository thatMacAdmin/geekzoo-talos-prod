const fs = require('fs');
const path = require('path');

const root = path.resolve(__dirname, '..', 'configs', 'generated');
fs.mkdirSync(root, { recursive: true });

const dashboards = JSON.parse(fs.readFileSync('/tmp/kubernetes-mixin-dashboards.json', 'utf8'));
const alerts = JSON.parse(fs.readFileSync('/tmp/kubernetes-mixin-alerts.json', 'utf8'));
const rules = JSON.parse(fs.readFileSync('/tmp/kubernetes-mixin-rules.json', 'utf8'));

for (const group of rules.groups ?? []) {
  for (const rule of group.rules ?? []) {
    if (rule.record === 'apiserver_request:availability30d') {
      rule.expr = `clamp_max(clamp_min((\n${rule.expr.trim()}\n), 0), 1)\n`;
    }
  }
}

function sanitizeName(name) {
  return name
    .replace(/\.json$/, '')
    .replace(/[^a-z0-9-]+/gi, '-')
    .replace(/^-+|-+$/g, '')
    .toLowerCase();
}

function writeJsonDocs(filename, docs) {
  const content = docs.map((doc) => JSON.stringify(doc, null, 2)).join('\n---\n') + '\n';
  fs.writeFileSync(path.join(root, filename), content);
}

const dashboardDocs = Object.entries(dashboards).map(([filename, dashboard]) => ({
  apiVersion: 'v1',
  kind: 'ConfigMap',
  metadata: {
    name: `kubernetes-mixin-${sanitizeName(filename)}`,
    namespace: 'monitoring',
    labels: {
      grafana_dashboard: '1',
    },
    annotations: {
      grafana_folder: 'Kubernetes',
    },
  },
  data: {
    [filename]: JSON.stringify(dashboard, null, 2),
  },
}));

writeJsonDocs('kubernetes-mixin-dashboards.yaml', dashboardDocs);

writeJsonDocs('kubernetes-mixin-rules.yaml', [
  {
    apiVersion: 'operator.victoriametrics.com/v1beta1',
    kind: 'VMRule',
    metadata: {
      name: 'kubernetes-mixin-recording-rules',
      namespace: 'monitoring',
    },
    spec: rules,
  },
  {
    apiVersion: 'operator.victoriametrics.com/v1beta1',
    kind: 'VMRule',
    metadata: {
      name: 'kubernetes-mixin-alerts',
      namespace: 'monitoring',
    },
    spec: alerts,
  },
]);
