// Direct bridge to Studio plugin - bypasses MCP stdio, talks HTTP directly
const http = require('http');

const args = process.argv.slice(2);
const endpoint = args[0]; // e.g. "execute", "getChildren", "search"
const data = args[1] ? JSON.parse(args[1]) : {};

if (!endpoint) {
  console.error('Usage: node mcp-cmd.cjs <endpoint> [json_data]');
  console.error('  endpoints: execute, getChildren, getProperties, search, getScriptSource, createInstance');
  process.exit(1);
}

const requestId = 'req-' + Date.now();
let studioId = null;
let pendingCommand = { requestId, endpoint, data };
let resolved = false;

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url || '/', 'http://localhost:3002');
  const path = url.pathname;
  
  const sendJson = (status, obj) => {
    res.writeHead(status, {
      'Content-Type': 'application/json',
      'Access-Control-Allow-Origin': '*',
      'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
      'Access-Control-Allow-Headers': 'Content-Type',
    });
    res.end(JSON.stringify(obj));
  };

  if (req.method === 'OPTIONS') { sendJson(200, {}); return; }

  const body = await new Promise((resolve) => {
    const chunks = [];
    req.on('data', c => chunks.push(c));
    req.on('end', () => {
      try { resolve(JSON.parse(Buffer.concat(chunks).toString())); }
      catch { resolve({}); }
    });
  });

  if (path === '/health') {
    sendJson(200, { status: 'ok', service: 'mcp-cmd-bridge' });
    return;
  }

  if (path === '/register' && req.method === 'POST') {
    studioId = body.studioId;
    console.error('[Bridge] Studio connected: ' + (body.placeName || 'unknown'));
    sendJson(200, { success: true });
    return;
  }

  if (path === '/poll' && req.method === 'GET') {
    const sid = url.searchParams.get('studioId');
    if (!studioId) studioId = sid;
    
    if (pendingCommand && !resolved) {
      const cmd = pendingCommand;
      pendingCommand = null;
      sendJson(200, { command: cmd });
    } else {
      sendJson(200, { command: null });
    }
    return;
  }

  if (path === '/response' && req.method === 'POST') {
    resolved = true;
    if (body.success !== false && !body.error) {
      console.log(JSON.stringify(body.data, null, 2));
    } else {
      console.error('Error:', body.error || 'unknown error');
      console.log(JSON.stringify(body, null, 2));
    }
    // Give time for output to flush, then exit
    setTimeout(() => { server.close(); process.exit(0); }, 200);
    return;
  }

  if (path === '/disconnect') {
    sendJson(200, { success: true });
    return;
  }

  sendJson(404, { error: 'Not found' });
});

server.listen(3002, '127.0.0.1', () => {
  console.error('[Bridge] Listening on port 3002, waiting for Studio to poll...');
});

// Timeout after 15s
setTimeout(() => {
  if (!resolved) {
    console.error('[Bridge] Timeout - Studio may not be connected');
    server.close();
    process.exit(1);
  }
}, 15000);
