const express = require("express");
const multer = require("multer");
const AdmZip = require("adm-zip");
const { Client } = require("pg");
const Docker = require("dockerode");
const { spawn } = require("child_process");
const fs = require("fs");
const path = require("path");
const os = require("os");

const app = express();
const uploadDisk = multer({
  storage: multer.diskStorage({
    destination: os.tmpdir(),
    filename: (_req, _file, cb) => cb(null, `upload-sql-${Date.now()}.sql`),
  }),
  limits: { fileSize: 20 * 1024 * 1024 * 1024 },
});
const upload = multer({ storage: multer.memoryStorage(), limits: { fileSize: 200 * 1024 * 1024 } });
const docker = new Docker({ socketPath: "/var/run/docker.sock" });

const DEPLOY_KEY = process.env.DEPLOY_KEY;
const FUNCTIONS_DIR = process.env.FUNCTIONS_DIR || "/home/deno/functions";
const DB_URL = process.env.SUPABASE_DB_URL;
const FUNCTIONS_CONTAINER = process.env.FUNCTIONS_CONTAINER || "supabase-functions";
const ENV_FILE = process.env.ENV_FILE || "/supabase-host/.env";
const PORT = process.env.PORT || 9191;

if (!DEPLOY_KEY) {
  console.error("FATAL: DEPLOY_KEY env var is required");
  process.exit(1);
}

function requireKey(req, res, next) {
  const key = req.headers["x-deploy-key"];
  if (!key || key !== DEPLOY_KEY) {
    return res.status(401).json({ error: "Unauthorized" });
  }
  next();
}

app.get("/deploy/health", (req, res) => {
  res.json({ status: "ok", timestamp: new Date().toISOString() });
});

// ── Functions deploy ────────────────────────────────────────────────────────
app.post("/deploy/functions", requireKey, upload.single("bundle"), async (req, res) => {
  if (!req.file) return res.status(400).json({ error: "Missing bundle file" });

  try {
    console.log(`[functions] Received bundle ${req.file.size} bytes`);
    const zip = new AdmZip(req.file.buffer);
    const entries = zip.getEntries();
    let count = 0;
    for (const entry of entries) {
      if (entry.isDirectory) continue;
      const entryName = entry.entryName.replace(/\\/g, "/");
      const destPath = path.join(FUNCTIONS_DIR, entryName);
      fs.mkdirSync(path.dirname(destPath), { recursive: true });
      fs.writeFileSync(destPath, entry.getData());
      count++;
    }
    console.log(`[functions] Extracted ${count} files to ${FUNCTIONS_DIR}`);
    const container = docker.getContainer(FUNCTIONS_CONTAINER);
    await container.restart({ t: 5 });
    console.log(`[functions] Restarted container ${FUNCTIONS_CONTAINER}`);
    res.json({ success: true, files: count, container: FUNCTIONS_CONTAINER });
  } catch (err) {
    console.error("[functions] Error:", err.message);
    res.status(500).json({ error: err.message });
  }
});

// ── DB push (migrations) ────────────────────────────────────────────────────
app.post("/deploy/db/push", requireKey, upload.single("bundle"), async (req, res) => {
  if (!req.file) return res.status(400).json({ error: "Missing bundle file" });
  const zip = new AdmZip(req.file.buffer);
  const migrations = zip.getEntries()
    .filter((e) => !e.isDirectory && e.entryName.endsWith(".sql"))
    .sort((a, b) => a.entryName.localeCompare(b.entryName))
    .map((e) => ({ name: path.basename(e.entryName), sql: e.getData().toString("utf8") }));

  if (migrations.length === 0) return res.status(400).json({ error: "No .sql files found" });
  console.log(`[db] Received ${migrations.length} migration(s)`);

  const client = new Client({ connectionString: DB_URL });
  await client.connect();
  try {
    await client.query(`
      CREATE TABLE IF NOT EXISTS public._deploy_migrations (
        name TEXT PRIMARY KEY,
        applied_at TIMESTAMPTZ NOT NULL DEFAULT now()
      )
    `);
    const { rows } = await client.query("SELECT name FROM public._deploy_migrations");
    const applied = new Set(rows.map((r) => r.name));
    const results = [];
    for (const { name, sql } of migrations) {
      if (applied.has(name)) { results.push({ name, status: "skipped" }); continue; }
      try {
        await client.query("BEGIN");
        await client.query(sql);
        await client.query("INSERT INTO public._deploy_migrations (name) VALUES ($1)", [name]);
        await client.query("COMMIT");
        results.push({ name, status: "applied" });
        console.log(`[db] Applied: ${name}`);
      } catch (err) {
        await client.query("ROLLBACK");
        results.push({ name, status: "error", error: err.message });
        console.error(`[db] Failed ${name}: ${err.message}`);
        break;
      }
    }
    res.json({ success: true, results });
  } finally { await client.end(); }
});

// ── DB baseline ─────────────────────────────────────────────────────────────
app.post("/deploy/db/baseline", requireKey, upload.single("bundle"), async (req, res) => {
  if (!req.file) return res.status(400).json({ error: "Missing bundle file" });
  const zip = new AdmZip(req.file.buffer);
  const names = zip.getEntries()
    .filter((e) => !e.isDirectory && e.entryName.endsWith(".sql"))
    .sort((a, b) => a.entryName.localeCompare(b.entryName))
    .map((e) => path.basename(e.entryName));

  if (names.length === 0) return res.status(400).json({ error: "No .sql files found" });
  const client = new Client({ connectionString: DB_URL });
  await client.connect();
  try {
    await client.query(`CREATE TABLE IF NOT EXISTS public._deploy_migrations (name TEXT PRIMARY KEY, applied_at TIMESTAMPTZ NOT NULL DEFAULT now())`);
    const { rows } = await client.query("SELECT name FROM public._deploy_migrations");
    const already = new Set(rows.map((r) => r.name));
    let marked = 0;
    for (const name of names) {
      if (!already.has(name)) { await client.query("INSERT INTO public._deploy_migrations (name) VALUES ($1)", [name]); marked++; }
    }
    res.json({ success: true, marked, skipped: already.size });
  } finally { await client.end(); }
});

// ── DB status ───────────────────────────────────────────────────────────────
app.get("/deploy/db/status", requireKey, async (req, res) => {
  const client = new Client({ connectionString: DB_URL });
  await client.connect();
  try {
    await client.query(`CREATE TABLE IF NOT EXISTS public._deploy_migrations (name TEXT PRIMARY KEY, applied_at TIMESTAMPTZ NOT NULL DEFAULT now())`);
    const { rows } = await client.query("SELECT name, applied_at FROM public._deploy_migrations ORDER BY applied_at");
    res.json({ applied: rows });
  } catch (err) { res.status(500).json({ error: err.message }); }
  finally { await client.end(); }
});

// ── Env file helpers ────────────────────────────────────────────────────────
function parseEnvFile(filePath) {
  if (!fs.existsSync(filePath)) return {};
  const vars = {};
  for (const line of fs.readFileSync(filePath, "utf8").split("\n")) {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith("#")) continue;
    const idx = trimmed.indexOf("=");
    if (idx === -1) continue;
    vars[trimmed.slice(0, idx).trim()] = trimmed.slice(idx + 1);
  }
  return vars;
}

function writeEnvFile(filePath, vars) {
  fs.writeFileSync(filePath, Object.entries(vars).map(([k, v]) => `${k}=${v}`).join("\n") + "\n", "utf8");
}

async function restartFunctionsContainer() {
  const container = docker.getContainer(FUNCTIONS_CONTAINER);
  await container.restart({ t: 5 });
}

app.get("/deploy/functions/env", requireKey, (req, res) => {
  try {
    const vars = parseEnvFile(ENV_FILE);
    const masked = Object.fromEntries(Object.entries(vars).map(([k, v]) => [k, v.length > 4 ? v.slice(0, 4) + "***" : "***"]));
    res.json({ file: ENV_FILE, vars: masked, count: Object.keys(vars).length });
  } catch (err) { res.status(500).json({ error: err.message }); }
});

app.get("/deploy/functions/env/:key", requireKey, (req, res) => {
  try {
    const vars = parseEnvFile(ENV_FILE);
    if (!(req.params.key in vars)) return res.status(404).json({ error: `Key not found: ${req.params.key}` });
    res.json({ key: req.params.key, value: vars[req.params.key] });
  } catch (err) { res.status(500).json({ error: err.message }); }
});

app.use(express.json({ limit: "1mb" }));
app.post("/deploy/functions/env", requireKey, async (req, res) => {
  try {
    const updates = {};
    if (Array.isArray(req.body.pairs)) {
      for (const pair of req.body.pairs) {
        const idx = pair.indexOf("=");
        if (idx === -1) return res.status(400).json({ error: `Invalid pair: ${pair}` });
        updates[pair.slice(0, idx).trim()] = pair.slice(idx + 1);
      }
    } else { Object.assign(updates, req.body); }
    if (Object.keys(updates).length === 0) return res.status(400).json({ error: "No keys provided" });
    const vars = parseEnvFile(ENV_FILE);
    const changed = [];
    for (const [key, value] of Object.entries(updates)) {
      const isNew = !(key in vars);
      vars[key] = value;
      changed.push({ key, action: isNew ? "created" : "updated" });
    }
    writeEnvFile(ENV_FILE, vars);
    await restartFunctionsContainer();
    res.json({ success: true, changed, container: FUNCTIONS_CONTAINER });
  } catch (err) { res.status(500).json({ error: err.message }); }
});

app.delete("/deploy/functions/env/:key", requireKey, async (req, res) => {
  try {
    const vars = parseEnvFile(ENV_FILE);
    if (!(req.params.key in vars)) return res.status(404).json({ error: `Key not found: ${req.params.key}` });
    delete vars[req.params.key];
    writeEnvFile(ENV_FILE, vars);
    await restartFunctionsContainer();
    res.json({ success: true, deleted: req.params.key, container: FUNCTIONS_CONTAINER });
  } catch (err) { res.status(500).json({ error: err.message }); }
});

// ── Functions verify/ls ─────────────────────────────────────────────────────
app.get("/deploy/functions/verify/:funcname", requireKey, (req, res) => {
  const funcFile = path.join(FUNCTIONS_DIR, req.params.funcname, "index.ts");
  if (!fs.existsSync(funcFile)) return res.status(404).json({ error: `Not found: ${funcFile}` });
  const stat = fs.statSync(funcFile);
  res.json({ path: funcFile, size: stat.size, modified: stat.mtime, preview: fs.readFileSync(funcFile, "utf8").split("\n").slice(0, 10).join("\n") });
});

app.get("/deploy/functions/ls", requireKey, (req, res) => {
  const target = path.join(FUNCTIONS_DIR, req.query.dir || "");
  if (!fs.existsSync(target)) return res.status(404).json({ error: `Not found: ${target}` });
  const entries = fs.readdirSync(target, { withFileTypes: true }).map((e) => ({
    name: e.name, type: e.isDirectory() ? "dir" : "file",
    modified: e.isDirectory() ? null : fs.statSync(path.join(target, e.name)).mtime,
  }));
  res.json({ path: target, entries });
});

// ── Logs ────────────────────────────────────────────────────────────────────
function lineMatchesFunc(line, funcName) {
  if (!funcName) return true;
  return line.toLowerCase().includes(funcName.toLowerCase());
}

function stripDockerHeader(buf) {
  const lines = [];
  let offset = 0;
  while (offset + 8 <= buf.length) {
    const size = buf.readUInt32BE(offset + 4);
    if (offset + 8 + size > buf.length) break;
    lines.push(buf.slice(offset + 8, offset + 8 + size).toString("utf8"));
    offset += 8 + size;
  }
  return lines.length > 0 ? lines.join("") : buf.toString("utf8");
}

app.get("/deploy/functions/logs", requireKey, async (req, res) => {
  const funcName = req.query.func || "";
  const tail = parseInt(req.query.lines) || 200;
  try {
    const container = docker.getContainer(FUNCTIONS_CONTAINER);
    const logBuffer = await new Promise((resolve, reject) => {
      container.logs({ stdout: true, stderr: true, tail, follow: false }, (err, data) => { if (err) reject(err); else resolve(data); });
    });
    const raw = stripDockerHeader(logBuffer);
    const lines = raw.split("\n").filter((l) => lineMatchesFunc(l, funcName));
    res.json({ func: funcName || "*", lines, count: lines.length });
  } catch (err) { res.status(500).json({ error: err.message }); }
});

app.get("/deploy/functions/logs/stream", requireKey, async (req, res) => {
  const funcName = req.query.func || "";
  res.setHeader("Content-Type", "text/event-stream");
  res.setHeader("Cache-Control", "no-cache");
  res.setHeader("X-Accel-Buffering", "no");
  res.flushHeaders();
  let logStream;
  try {
    const container = docker.getContainer(FUNCTIONS_CONTAINER);
    logStream = await new Promise((resolve, reject) => {
      container.logs({ stdout: true, stderr: true, follow: true, tail: 50, timestamps: true }, (err, stream) => { if (err) reject(err); else resolve(stream); });
    });
    let buffer = "";
    logStream.on("data", (chunk) => {
      let text = (chunk[0] <= 2 && chunk.length > 8) ? chunk.slice(8).toString("utf8") : chunk.toString("utf8");
      buffer += text;
      const parts = buffer.split("\n");
      buffer = parts.pop();
      for (const line of parts) {
        if (!line.trim() || !lineMatchesFunc(line, funcName)) continue;
        res.write(`data: ${JSON.stringify(line)}\n\n`);
      }
    });
    logStream.on("end", () => { res.write("data: [stream ended]\n\n"); res.end(); });
    logStream.on("error", (err) => { res.write(`data: [error] ${err.message}\n\n`); res.end(); });
    req.on("close", () => { try { logStream.destroy(); } catch (_) {} });
  } catch (err) { res.write(`data: [error] ${err.message}\n\n`); res.end(); }
});

// ── DB exec (SSE) ───────────────────────────────────────────────────────────
app.post("/deploy/db/exec", requireKey, uploadDisk.single("sql"), async (req, res) => {
  if (!req.file) return res.status(400).json({ error: "Missing sql file" });
  const tmpSql = req.file.path;
  res.setHeader("Content-Type", "text/event-stream");
  res.setHeader("Cache-Control", "no-cache");
  res.setHeader("X-Accel-Buffering", "no");
  res.flushHeaders();
  const send = (line) => res.write(`data: ${JSON.stringify(line)}\n\n`);
  send(`[exec] Arquivo: ${req.file.originalname || "upload.sql"} (${req.file.size} bytes)`);

  const ignoreErrors = req.query.ignore_errors === "1";
  const psqlArgs = [DB_URL, "-f", tmpSql];
  if (!ignoreErrors) psqlArgs.push("--set=ON_ERROR_STOP=1");
  psqlArgs.push("-v", "VERBOSITY=verbose", "-P", "pager=off", "-P", "tuples_only=off", "-e");
  if (ignoreErrors) send("[exec] ignore_errors ativo");

  const psql = spawn("psql", psqlArgs, { env: { ...process.env } });
  const flush = (d) => d.toString().split("\n").forEach((l) => { if (l !== "") send(l); });
  psql.stdout.on("data", flush);
  psql.stderr.on("data", flush);
  psql.on("close", (code, signal) => {
    try { fs.unlinkSync(tmpSql); } catch (_) {}
    const exitCode = signal ? -1 : (code ?? -1);
    res.write(`data: ${JSON.stringify({ __exit: exitCode })}\n\n`);
    res.end();
  });
});

// ── DB dump ─────────────────────────────────────────────────────────────────
const dumpJobs = new Map();

app.post("/deploy/db/dump", requireKey, express.json({ limit: "1mb" }), (req, res) => {
  const opts = req.body || {};
  const fmt = opts.format || "plain";
  const ext = fmt === "custom" ? "dump" : fmt === "tar" ? "tar" : "sql";
  const jobId = `dump-${Date.now()}-${Math.random().toString(36).slice(2, 8)}`;
  const filename = `dump_${new Date().toISOString().replace(/[:.]/g, "-").slice(0, 19)}.${ext}`;
  const tmpFile = path.join(os.tmpdir(), `${jobId}.tmp`);

  const args = [DB_URL, "-f", tmpFile];
  if (fmt === "custom") args.push("-Fc");
  else if (fmt === "tar") args.push("-Ft");
  else args.push("-Fp");
  if (opts.schema_only) args.push("--schema-only");
  if (opts.data_only) args.push("--data-only");
  if (opts.no_owner) args.push("--no-owner");
  if (opts.no_acl) args.push("--no-acl");
  (opts.tables || []).forEach((t) => args.push("-t", t));
  (opts.schemas || []).forEach((s) => args.push("-n", s));
  (opts.exclude_tables || []).forEach((t) => args.push("-T", t));
  (opts.extra_args || []).forEach((a) => args.push(a));

  res.setHeader("Content-Type", "text/event-stream");
  res.setHeader("Cache-Control", "no-cache");
  res.setHeader("X-Accel-Buffering", "no");
  res.flushHeaders();
  const sse = (obj) => { try { res.write(`data: ${JSON.stringify(obj)}\n\n`); } catch (_) {} };

  dumpJobs.set(jobId, { tmpFile, filename, size: 0, error: null, done: false });
  sse({ status: "running", msg: `pg_dump iniciado (formato: ${fmt}, jobId: ${jobId})` });

  const pg = spawn("pg_dump", args, { env: { ...process.env } });
  let errBuf = "";
  pg.stderr.on("data", (d) => { errBuf += d.toString(); });

  const timer = setInterval(() => {
    try { if (fs.existsSync(tmpFile)) { sse({ status: "running", msg: `Escrevendo... ${(fs.statSync(tmpFile).size / 1024 / 1024).toFixed(2)} MB` }); } } catch (_) {}
  }, 2000);

  pg.on("close", (code, signal) => {
    clearInterval(timer);
    if (code !== 0 || signal) {
      const detail = errBuf.trim();
      dumpJobs.set(jobId, { tmpFile, filename, size: 0, error: detail, done: true });
      try { fs.unlinkSync(tmpFile); } catch (_) {}
      sse({ status: "error", error: detail, exitCode: code, signal });
      res.end();
      return;
    }
    const size = fs.statSync(tmpFile).size;
    dumpJobs.set(jobId, { tmpFile, filename, size, error: null, done: true });
    sse({ status: "done", jobId, filename, size });
    res.end();
    setTimeout(() => { const j = dumpJobs.get(jobId); if (j) { try { fs.unlinkSync(j.tmpFile); } catch (_) {} dumpJobs.delete(jobId); } }, 30 * 60 * 1000);
  });
});

app.get("/deploy/db/dump/:jobId", requireKey, (req, res) => {
  const job = dumpJobs.get(req.params.jobId);
  if (!job) return res.status(404).json({ error: "Job not found" });
  if (!job.done) return res.status(202).json({ status: "running" });
  if (job.error) return res.status(500).json({ error: job.error });
  if (!fs.existsSync(job.tmpFile)) return res.status(410).json({ error: "File expired" });
  const ext = path.extname(job.filename).toLowerCase();
  res.setHeader("Content-Type", ext === ".sql" ? "text/plain; charset=utf-8" : "application/octet-stream");
  res.setHeader("Content-Disposition", `attachment; filename="${job.filename}"`);
  res.setHeader("Content-Length", job.size);
  const stream = fs.createReadStream(job.tmpFile);
  stream.pipe(res);
  stream.on("close", () => { try { fs.unlinkSync(job.tmpFile); } catch (_) {} dumpJobs.delete(req.params.jobId); });
});

app.delete("/deploy/db/dump/:jobId", requireKey, (req, res) => {
  const job = dumpJobs.get(req.params.jobId);
  if (!job) return res.status(404).json({ error: "Job not found" });
  try { fs.unlinkSync(job.tmpFile); } catch (_) {}
  dumpJobs.delete(req.params.jobId);
  res.json({ deleted: req.params.jobId });
});

// ── DB tools ────────────────────────────────────────────────────────────────
app.get("/deploy/db/tools", requireKey, async (req, res) => {
  const { execFile } = require("child_process");
  const check = (cmd, args) => new Promise((resolve) => {
    execFile(cmd, args, { timeout: 10000 }, (err, stdout, stderr) => {
      resolve({ ok: !err, out: (stdout || stderr || "").trim(), err: err ? err.message : null });
    });
  });
  const [psqlVer, pgdumpVer, dbConn] = await Promise.all([
    check("psql", ["--version"]),
    check("pg_dump", ["--version"]),
    check("psql", [DB_URL, "-c", "SELECT current_database(), current_user, version()", "-t", "-A"]),
  ]);
  res.json({ psql: psqlVer, pg_dump: pgdumpVer, db: dbConn, db_url_set: !!DB_URL });
});

// ── Docker pull-restart ─────────────────────────────────────────────────────
app.post("/deploy/docker/pull-restart", requireKey, express.json({ limit: "1kb" }), (req, res) => {
  const service = (req.body && req.body.service) ? String(req.body.service).replace(/[^a-z0-9_.-]/gi, "") : "";
  if (!service) return res.status(400).json({ error: "Campo 'service' obrigatorio" });
  res.setHeader("Content-Type", "text/event-stream");
  res.setHeader("Cache-Control", "no-cache");
  res.setHeader("Connection", "keep-alive");
  res.flushHeaders();
  const emit = (line) => { res.write(`data: ${JSON.stringify(line)}\n\n`); console.log(`[docker] ${line}`); };
  (async () => {
    try {
      emit(`[find] Procurando container '${service}'...`);
      const containers = await docker.listContainers({ all: true });
      const match = containers.find((c) => c.Names.some((n) => { const bare = n.replace(/^\//, ""); return bare === service || bare.includes(service); }));
      if (!match) throw new Error(`Container '${service}' nao encontrado`);
      emit(`[find] Container: ${match.Names[0]}  imagem: ${match.Image}`);
      emit(`[pull] Pulling ${match.Image}...`);
      await new Promise((resolve, reject) => {
        const proc = spawn("docker", ["pull", match.Image], { env: { ...process.env, HOME: "/root" } });
        proc.stdout.on("data", (d) => d.toString().split("\n").forEach((l) => { if (l.trim()) emit(`[pull] ${l.trim()}`); }));
        proc.stderr.on("data", (d) => d.toString().split("\n").forEach((l) => { if (l.trim()) emit(`[pull] ${l.trim()}`); }));
        proc.on("close", (code) => code === 0 ? resolve() : reject(new Error(`docker pull falhou (exit ${code})`)));
      });
      emit(`[restart] Reiniciando ${match.Names[0]}...`);
      await docker.getContainer(match.Id).restart({ t: 10 });
      emit(`[ok] Container '${service}' reiniciado.`);
      res.write(`data: ${JSON.stringify({ __exit: 0 })}\n\n`);
    } catch (err) {
      emit(`[erro] ${err.message}`);
      res.write(`data: ${JSON.stringify({ __exit: 1, error: err.message })}\n\n`);
    }
    res.end();
  })();
});

app.listen(PORT, () => {
  console.log(`[deploy-service] Listening on port ${PORT}`);
  console.log(`[deploy-service] Functions dir: ${FUNCTIONS_DIR}`);
});
