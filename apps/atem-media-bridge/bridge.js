#!/usr/bin/env node
//
// atem-media-bridge — keeps the ATEM media pool in sync with disk.
//
// Long-running daemon. On startup it does one upload pass over the
// configured slots, then listens on HTTP for refresh requests so
// Companion (or anything else on localhost) can re-push the pool on
// demand. ATEM Mini Pro's pool is volatile — a hard power cycle wipes
// every slot, so periodic / explicit re-pushes are how we keep it
// known-good.
//
// HTTP API:
//   POST /refresh         → upload all configured slots, return summary
//   POST /refresh/<index> → upload only one slot, return summary
//   GET  /state           → JSON: connected, last_run, last_result
//   GET  /healthz         → 200 if ATEM is connected
//
// Reads /etc/atem-media-bridge/slots.yaml. Image bytes resolve against
// /opt/atem-media/. Sharp handles PNG/JPG/BMP → 1920x1080 BGRA.

'use strict';

const fs = require('fs');
const http = require('http');
const path = require('path');
const { Atem } = require('atem-connection');
const sharp = require('sharp');
const YAML = require('yaml');

const CONFIG_PATH = process.env.ATEM_MEDIA_CONFIG
  || '/etc/atem-media-bridge/slots.yaml';
const MEDIA_DIR = process.env.ATEM_MEDIA_DIR
  || '/opt/atem-media';
const HTTP_HOST = process.env.ATEM_MEDIA_HTTP_HOST || '127.0.0.1';
const HTTP_PORT = parseInt(process.env.ATEM_MEDIA_HTTP_PORT || '9991', 10);
const ATEM_WIDTH = 1920;
const ATEM_HEIGHT = 1080;
const UPLOAD_TIMEOUT_MS = 60_000;

let runtime = {
  cfg: null,
  atem: null,
  connected: false,
  last_run: null,        // ISO timestamp of last upload pass
  last_result: null,     // { ok, failed, total }
  inflight: false,       // upload pass in progress?
};

function log(level, msg, extra = {}) {
  console.log(JSON.stringify({
    ts: new Date().toISOString(),
    level,
    msg,
    ...extra,
  }));
}

function loadConfig() {
  const raw = fs.readFileSync(CONFIG_PATH, 'utf8');
  const cfg = YAML.parse(raw);
  if (!cfg || typeof cfg !== 'object') {
    throw new Error(`invalid YAML: ${CONFIG_PATH}`);
  }
  if (!cfg.atem_host) throw new Error('missing atem_host in config');
  if (!Array.isArray(cfg.slots) || cfg.slots.length === 0) {
    throw new Error('missing or empty slots[] in config');
  }
  return cfg;
}

async function encodeImage(filePath) {
  const stat = fs.statSync(filePath);
  if (stat.size === 0) throw new Error(`empty file: ${filePath}`);

  const { data, info } = await sharp(filePath)
    .resize(ATEM_WIDTH, ATEM_HEIGHT, {
      fit: 'contain',
      background: { r: 0, g: 0, b: 0, alpha: 0 },
    })
    .raw()
    .ensureAlpha()
    .toBuffer({ resolveWithObject: true });

  if (info.width !== ATEM_WIDTH || info.height !== ATEM_HEIGHT) {
    throw new Error(
      `unexpected post-resize dims: ${info.width}x${info.height}`
    );
  }

  // RGBA → premultiplied BGRA, top-left origin.
  const px = ATEM_WIDTH * ATEM_HEIGHT;
  const bgra = Buffer.alloc(px * 4);
  for (let i = 0; i < px; i++) {
    const o = i * 4;
    const r = data[o];
    const g = data[o + 1];
    const b = data[o + 2];
    const a = data[o + 3];
    const aN = a / 255;
    bgra[o]     = Math.round(b * aN);
    bgra[o + 1] = Math.round(g * aN);
    bgra[o + 2] = Math.round(r * aN);
    bgra[o + 3] = a;
  }
  return bgra;
}

function withTimeout(promise, ms, label) {
  return new Promise((resolve, reject) => {
    const t = setTimeout(
      () => reject(new Error(`${label} timed out after ${ms}ms`)),
      ms,
    );
    promise.then(
      (v) => { clearTimeout(t); resolve(v); },
      (e) => { clearTimeout(t); reject(e); },
    );
  });
}

async function uploadSlot(slot) {
  const filePath = path.join(MEDIA_DIR, slot.file);
  if (!fs.existsSync(filePath)) {
    log('warn', 'file missing — skipping slot', {
      index: slot.index, file: filePath,
    });
    return { ok: false, reason: 'missing-file' };
  }

  log('info', 'encoding', { index: slot.index, file: filePath });
  const bgra = await encodeImage(filePath);

  log('info', 'uploading', {
    index: slot.index,
    bytes: bgra.length,
    name: slot.name,
  });

  await withTimeout(
    runtime.atem.uploadStill(
      slot.index, bgra, slot.name || `slot ${slot.index}`, ''
    ),
    UPLOAD_TIMEOUT_MS,
    `uploadStill slot ${slot.index}`,
  );

  log('info', 'uploaded', { index: slot.index });
  return { ok: true };
}

async function uploadAll(filterIndex = null) {
  if (runtime.inflight) {
    return { ok: 0, failed: 0, total: 0, skipped: 'busy' };
  }
  runtime.inflight = true;
  try {
    if (!runtime.connected) throw new Error('atem not connected');

    const slots = (filterIndex === null)
      ? runtime.cfg.slots
      : runtime.cfg.slots.filter((s) => Number(s.index) === Number(filterIndex));

    if (filterIndex !== null && slots.length === 0) {
      throw new Error(`no slot with index=${filterIndex} in config`);
    }

    let ok = 0, failed = 0;
    for (const slot of slots) {
      try {
        const r = await uploadSlot(slot);
        if (r.ok) ok += 1; else failed += 1;
      } catch (err) {
        failed += 1;
        log('error', 'slot upload failed', {
          index: slot.index, err: err.message,
        });
      }
    }

    const result = { ok, failed, total: slots.length };
    runtime.last_run = new Date().toISOString();
    runtime.last_result = result;
    log('info', 'pass complete', result);
    return result;
  } finally {
    runtime.inflight = false;
  }
}

async function connectAtem() {
  runtime.atem = new Atem();
  runtime.atem.on('disconnected', () => {
    log('warn', 'atem disconnected');
    runtime.connected = false;
  });
  runtime.atem.on('error', (e) => log('warn', 'atem error', { err: String(e) }));

  await new Promise((resolve, reject) => {
    let settled = false;
    const settle = (fn) => { if (!settled) { settled = true; fn(); } };
    runtime.atem.once('connected', () => settle(resolve));
    runtime.atem.once('error', (e) => settle(() => reject(e)));
    setTimeout(() => settle(() => reject(new Error('connect timeout'))), 30_000);
    runtime.atem.connect(runtime.cfg.atem_host).catch(
      (e) => settle(() => reject(e))
    );
  });
  runtime.connected = true;
  log('info', 'atem connected', { atem_host: runtime.cfg.atem_host });

  // Re-mark connected on any future reconnect (atem-connection handles
  // reconnects internally for transient drops).
  runtime.atem.on('connected', () => {
    runtime.connected = true;
    log('info', 'atem reconnected');
  });
}

function jsonResponse(res, code, body) {
  res.writeHead(code, { 'content-type': 'application/json' });
  res.end(JSON.stringify(body));
}

function startHttp() {
  const server = http.createServer(async (req, res) => {
    try {
      if (req.method === 'GET' && req.url === '/healthz') {
        return jsonResponse(res, runtime.connected ? 200 : 503, {
          atem: runtime.connected ? 'ok' : 'down',
        });
      }
      if (req.method === 'GET' && req.url === '/state') {
        return jsonResponse(res, 200, {
          connected: runtime.connected,
          last_run: runtime.last_run,
          last_result: runtime.last_result,
          inflight: runtime.inflight,
          slot_count: runtime.cfg.slots.length,
        });
      }
      if (req.method === 'POST' && req.url === '/refresh') {
        const result = await uploadAll(null);
        return jsonResponse(res, 200, result);
      }
      const m = req.method === 'POST' && req.url.match(/^\/refresh\/(\d+)$/);
      if (m) {
        const result = await uploadAll(parseInt(m[1], 10));
        return jsonResponse(res, 200, result);
      }
      jsonResponse(res, 404, { error: 'not found' });
    } catch (err) {
      log('error', 'http handler', { url: req.url, err: err.message });
      jsonResponse(res, 500, { error: err.message });
    }
  });
  server.listen(HTTP_PORT, HTTP_HOST, () => {
    log('info', 'http listening', { host: HTTP_HOST, port: HTTP_PORT });
  });
}

async function main() {
  runtime.cfg = loadConfig();
  log('info', 'starting', {
    atem_host: runtime.cfg.atem_host,
    slot_count: runtime.cfg.slots.length,
    media_dir: MEDIA_DIR,
    http: `${HTTP_HOST}:${HTTP_PORT}`,
  });

  await connectAtem();

  // Start HTTP server first so /healthz reports "ok" while we run the
  // initial pass; Companion might call /refresh before we'd otherwise
  // be ready.
  startHttp();

  // Initial pass — same behavior as the old one-shot mode.
  await uploadAll(null);

  // Stay alive forever. SIGTERM cleans up.
  const shutdown = (sig) => {
    log('info', 'shutdown', { signal: sig });
    if (runtime.atem) {
      runtime.atem.disconnect().catch(() => {});
    }
    setTimeout(() => process.exit(0), 500);
  };
  process.on('SIGTERM', () => shutdown('SIGTERM'));
  process.on('SIGINT', () => shutdown('SIGINT'));
}

main().catch((err) => {
  log('fatal', err.message, { stack: err.stack });
  process.exit(2);
});
