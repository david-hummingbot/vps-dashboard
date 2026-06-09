const REFRESH_MS = 30_000;

function fmtUptime(seconds) {
  if (!seconds) return '–';
  const d = Math.floor(seconds / 86400);
  const h = Math.floor((seconds % 86400) / 3600);
  const m = Math.floor((seconds % 3600) / 60);
  if (d > 0) return `${d}d ${h}h`;
  if (h > 0) return `${h}h ${m}m`;
  return `${m}m`;
}

function fmtBytes(mb) {
  if (mb >= 1024) return `${(mb / 1024).toFixed(1)} GB`;
  return `${Math.round(mb)} MB`;
}

function levelClass(pct) {
  if (pct >= 90) return 'high';
  if (pct >= 70) return 'medium';
  return 'low';
}

function ringGaugeSVG(pct, id) {
  const r = 28;
  const circ = 2 * Math.PI * r;
  const offset = circ - (pct / 100) * circ;
  const cls = levelClass(pct);
  return `
    <div class="ring-gauge">
      <svg viewBox="0 0 64 64" width="72" height="72">
        <circle class="ring-bg" cx="32" cy="32" r="${r}"/>
        <circle class="ring-fill ${cls}" cx="32" cy="32" r="${r}"
          stroke-dasharray="${circ.toFixed(2)}"
          stroke-dashoffset="${offset.toFixed(2)}"/>
      </svg>
      <div class="ring-text">${Math.round(pct)}%</div>
    </div>`;
}

function containerStatusClass(status) {
  if (status === 'running') return 'running';
  if (status === 'exited')  return 'exited';
  if (status === 'paused')  return 'paused';
  if (status === 'restarting') return 'restarting';
  return 'other';
}

function renderNode(node) {
  const online = node.is_online;
  const cpu  = node.cpu_percent  ?? 0;
  const ram  = node.ram_percent  ?? 0;
  const disk = node.disk_percent ?? 0;
  const containers = node.containers ?? [];

  const MAX_CONTAINERS = 8;
  const shown = containers.slice(0, MAX_CONTAINERS);
  const extra = containers.length - shown.length;

  const containerHTML = shown.length === 0
    ? `<div class="containers-empty">No containers</div>`
    : shown.map(c => `
        <div class="container-item">
          <span class="container-name" title="${c.name}">${c.name}</span>
          <span class="container-image" title="${c.image}">${c.image ?? ''}</span>
          <span class="container-status ${containerStatusClass(c.status)}">${c.status}</span>
        </div>`).join('') + (extra > 0 ? `<div class="containers-more">+${extra} more</div>` : '');

  const lastSeen = node.last_seen
    ? new Date(node.last_seen).toLocaleTimeString()
    : '–';

  return `
    <div class="node-card ${online ? '' : 'offline'}">
      <div class="card-header">
        <div class="node-name-wrap">
          <span class="status-dot ${online ? 'online' : 'offline'}"></span>
          <span class="node-name">${node.name}</span>
        </div>
        <span class="node-badge ${online ? 'online' : 'offline'}">${online ? 'Online' : 'Offline'}</span>
      </div>
      <div class="card-body">
        ${online ? `
          <div class="gauges-row">
            <div class="gauge-item">
              ${ringGaugeSVG(cpu, node.name + '-cpu')}
              <span class="gauge-label">CPU</span>
            </div>
            <div class="gauge-item">
              ${ringGaugeSVG(ram, node.name + '-ram')}
              <span class="gauge-label">RAM</span>
            </div>
            <div class="gauge-item" style="justify-content:center;flex:1.2;">
              <div style="width:100%">
                <div class="disk-label-row">
                  <span>Disk</span>
                  <span>${Math.round(disk)}%</span>
                </div>
                <div class="bar-track">
                  <div class="bar-fill ${levelClass(disk)}" style="width:${disk}%"></div>
                </div>
              </div>
            </div>
          </div>
          <div class="meta-row">
            <span class="meta-item">
              <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
                <circle cx="12" cy="12" r="10"/><polyline points="12 6 12 12 16 14"/>
              </svg>
              Up ${fmtUptime(node.uptime_seconds)}
            </span>
            <span class="meta-item">
              <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
                <rect x="2" y="3" width="20" height="14" rx="2"/>
              </svg>
              ${containers.length} container${containers.length !== 1 ? 's' : ''}
            </span>
            <span class="meta-item" style="margin-left:auto">Updated ${lastSeen}</span>
          </div>
          <div class="containers-label">Containers</div>
          <div class="containers-list">${containerHTML}</div>
        ` : `
          <div class="offline-notice">
            Node offline — last seen ${lastSeen}
          </div>
        `}
      </div>
    </div>`;
}

function alertIcon(type) {
  const map = {
    node_offline: 'node_offline',
    node_online:  'node_online',
    container_stopped: 'container_stopped',
    container_removed: 'container_removed',
    high_cpu:  'high_cpu',
    high_ram:  'high_ram',
    high_disk: 'high_disk',
  };
  return map[type] || 'high_cpu';
}

function renderAlert(a) {
  const ts = new Date(a.timestamp).toLocaleString();
  return `
    <div class="alert-item ${a.resolved ? 'resolved' : ''}">
      <span class="alert-dot ${alertIcon(a.alert_type)}"></span>
      <div class="alert-body">
        <div class="alert-msg">${a.message}</div>
        <div class="alert-meta">
          <span>${a.node_name}</span>
          <span>${ts}</span>
          ${a.resolved ? '<span>Resolved</span>' : ''}
        </div>
      </div>
    </div>`;
}

async function refresh() {
  try {
    const [nodes, alerts] = await Promise.all([
      fetch('/api/nodes').then(r => r.json()),
      fetch('/api/alerts?limit=30').then(r => r.json()),
    ]);

    const grid = document.getElementById('nodesGrid');
    if (nodes.length === 0) {
      grid.innerHTML = '<p style="color:var(--text-muted);padding:16px">No nodes registered yet. Install the agent on your servers.</p>';
    } else {
      grid.innerHTML = nodes
        .sort((a, b) => a.name.localeCompare(b.name))
        .map(renderNode)
        .join('');
    }

    const alertsList = document.getElementById('alertsList');
    alertsList.innerHTML = alerts.length === 0
      ? '<div class="alerts-empty">No alerts</div>'
      : alerts.map(renderAlert).join('');

    const online = nodes.filter(n => n.is_online).length;
    const total  = nodes.length;
    const summary = document.getElementById('statusSummary');
    summary.textContent = `${online}/${total} online`;
    summary.style.color = online === total ? 'var(--green)' : online === 0 ? 'var(--red)' : 'var(--yellow)';

    document.getElementById('lastUpdated').textContent =
      'Updated ' + new Date().toLocaleTimeString();
  } catch (e) {
    console.error('Refresh failed:', e);
  }
}

refresh();
setInterval(refresh, REFRESH_MS);
