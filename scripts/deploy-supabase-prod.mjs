#!/usr/bin/env node
/**
 * deploy-supabase-prod.mjs
 *
 * Envia migrations pendentes e edge functions para o deployer rodando na VM de produção.
 * Requer Node 20+ (usa fetch e fs nativo).
 *
 * Uso:
 *   node scripts/deploy-supabase-prod.mjs              # migrations + functions
 *   node scripts/deploy-supabase-prod.mjs --migrations # só migrations
 *   node scripts/deploy-supabase-prod.mjs --functions  # só functions
 *
 * Variáveis de ambiente necessárias no .env (ou exportadas no shell):
 *   PROD_DEPLOYER_URL      → ex: http://SEU_IP:3001
 *   PROD_DEPLOYER_API_KEY  → mesma chave configurada no container deployer
 */

import fs from 'fs';
import path from 'path';
import { execSync } from 'child_process';
import { fileURLToPath } from 'url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(__dirname, '..');

// ─── Config ───────────────────────────────────────────────────────────────────

loadEnv(path.join(ROOT, '.env'));

const DEPLOYER_URL = process.env.PROD_DEPLOYER_URL?.replace(/\/$/, '');
const DEPLOYER_API_KEY = process.env.PROD_DEPLOYER_API_KEY;

if (!DEPLOYER_URL || !DEPLOYER_API_KEY) {
  console.error('❌ Configure PROD_DEPLOYER_URL e PROD_DEPLOYER_API_KEY no .env');
  process.exit(1);
}

const args = process.argv.slice(2);
const onlyMigrations = args.includes('--migrations');
const onlyFunctions = args.includes('--functions');
const runMigrations = !onlyFunctions;
const runFunctions = !onlyMigrations;

// ─── Main ─────────────────────────────────────────────────────────────────────

await healthCheck();

if (runMigrations) await deployMigrations();
if (runFunctions) await deployFunctions();

console.log('\n✅ Deploy concluído.');

// ─── Health check ─────────────────────────────────────────────────────────────

async function healthCheck() {
  process.stdout.write('🔍 Verificando deployer... ');
  try {
    const res = await fetch(`${DEPLOYER_URL}/health`);
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    console.log('OK');
  } catch (e) {
    console.error(`\n❌ Deployer inacessível em ${DEPLOYER_URL}: ${e.message}`);
    process.exit(1);
  }
}

// ─── Migrations ───────────────────────────────────────────────────────────────

async function deployMigrations() {
  console.log('\n📦 Carregando migrations...');

  const migrationsDir = path.join(ROOT, 'supabase', 'migrations');
  const files = fs
    .readdirSync(migrationsDir)
    .filter((f) => f.endsWith('.sql'))
    .sort();

  if (files.length === 0) {
    console.log('   Nenhuma migration encontrada.');
    return;
  }

  console.log(`   ${files.length} arquivo(s) encontrado(s).`);

  const migrations = files.map((name) => ({
    name,
    sql: fs.readFileSync(path.join(migrationsDir, name), 'utf-8'),
  }));

  process.stdout.write('🚀 Enviando para o deployer... ');

  const res = await fetch(`${DEPLOYER_URL}/deploy/migrations`, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'X-API-Key': DEPLOYER_API_KEY,
    },
    body: JSON.stringify({ migrations }),
  });

  const body = await res.json();

  if (!res.ok) {
    console.error(`\n❌ Falha (HTTP ${res.status}): ${body.error}`);
    if (body.results?.length) {
      console.error('   Resultados parciais:');
      for (const r of body.results) {
        const icon = r.status === 'applied' ? '✓' : '✗';
        console.error(`     ${icon} ${r.name}${r.error ? ` — ${r.error}` : ''}`);
      }
    }
    process.exit(1);
  }

  console.log('OK');
  console.log(`   Aplicadas: ${body.applied}  |  Já existentes (ignoradas): ${body.skipped}`);

  if (body.results?.length) {
    for (const r of body.results) {
      console.log(`     ✓ ${r.name}`);
    }
  }
}

// ─── Functions ────────────────────────────────────────────────────────────────

async function deployFunctions() {
  console.log('\n📦 Empacotando edge functions...');

  const functionsDir = path.join(ROOT, 'supabase', 'functions');
  const zipPath = path.join(ROOT, '.tmp-functions-deploy.zip');

  try {
    // Cria zip do diretório functions/ excluindo _deployer (pasta de scripts internos)
    execSync(
      `cd "${path.join(ROOT, 'supabase')}" && zip -r "${zipPath}" functions/ -x "functions/_deployer/*"`,
      { stdio: 'pipe' },
    );

    const zipBuffer = fs.readFileSync(zipPath);
    const sizeMB = (zipBuffer.length / 1024 / 1024).toFixed(2);
    console.log(`   Zip gerado: ${sizeMB} MB`);

    const formData = new FormData();
    formData.append('functions', new Blob([zipBuffer], { type: 'application/zip' }), 'functions.zip');

    process.stdout.write('🚀 Enviando para o deployer... ');

    const res = await fetch(`${DEPLOYER_URL}/deploy/functions`, {
      method: 'POST',
      headers: { 'X-API-Key': DEPLOYER_API_KEY },
      body: formData,
    });

    const body = await res.json();

    if (!res.ok) {
      console.error(`\n❌ Falha (HTTP ${res.status}): ${body.error}`);
      process.exit(1);
    }

    console.log('OK');
    console.log(`   Container reiniciado: ${body.container}`);
  } finally {
    if (fs.existsSync(zipPath)) fs.unlinkSync(zipPath);
  }
}

// ─── Helpers ──────────────────────────────────────────────────────────────────

function loadEnv(envPath) {
  if (!fs.existsSync(envPath)) return;
  const lines = fs.readFileSync(envPath, 'utf-8').split('\n');
  for (const line of lines) {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith('#')) continue;
    const eqIdx = trimmed.indexOf('=');
    if (eqIdx === -1) continue;
    const key = trimmed.slice(0, eqIdx).trim();
    const val = trimmed.slice(eqIdx + 1).trim().replace(/^["']|["']$/g, '');
    if (!(key in process.env)) process.env[key] = val;
  }
}
