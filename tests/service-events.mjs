// Test-only receipt/response evidence. Never serialize headers, bodies or URLs.
import fs from 'node:fs';

export function event(service, kind, fields = {}) {
  const file = process.env.DSH_TEST_EVENT_LOG;
  if (!file) return;
  let phase = 'unassigned';
  try { phase = fs.readFileSync(process.env.DSH_TEST_PHASE_FILE, 'utf8').trim(); } catch {}
  if (!/^[a-zA-Z0-9_-]{1,80}$/.test(phase)) phase = 'invalid';
  const row = { service, kind, phase, pid: process.pid, monotonic_ns: process.hrtime.bigint().toString() };
  for (const key of ['request_id', 'connection_id', 'method', 'route', 'status', 'unauthorized',
                     'received_bytes', 'sent_bytes', 'local_port', 'remote_port']) {
    if (Object.hasOwn(fields, key)) row[key] = fields[key];
  }
  fs.appendFileSync(file, JSON.stringify(row) + '\n');
}

export function observe(service, req, res) {
  const route = (req.url ?? '').split('?')[0];
  const safeRoute = /^\/[-a-zA-Z0-9_/\.]{0,80}$/.test(route) ? route : '<redacted>';
  const request_id = `${process.pid}-${++sequence}`;
  const fields = { request_id, connection_id: connections.get(req.socket), method: req.method, route: safeRoute };
  event(service, 'request', fields);
  req.on('end', () => event(service, 'body_received', fields));
  res.on('finish', () => event(service, 'response_finished', { ...fields, status: res.statusCode,
    unauthorized: service === 'bridge' && res.statusCode === 401 }));
  return fields;
}
let sequence = 0;
const connections = new WeakMap();
export function observeConnections(service, server) {
  server.on('connection', (socket) => {
    const connection_id = `${process.pid}-tcp-${++sequence}`;
    connections.set(socket, connection_id);
    const fields = { connection_id, local_port: socket.localPort, remote_port: socket.remotePort };
    event(service, 'tcp_accepted', fields);
    // Counts only. This listener never logs/changes/consumes HTTP bytes.
    socket.on('data', () => event(service, 'tcp_read', { ...fields, received_bytes: socket.bytesRead }));
    socket.on('close', () => event(service, 'tcp_closed', { ...fields,
      received_bytes: socket.bytesRead, sent_bytes: socket.bytesWritten }));
  });
}
