#!/usr/bin/env node

/**
 * Gera ANON_KEY e SERVICE_ROLE_KEY (JWT HS256) a partir do JWT_SECRET.
 *
 * Uso:
 *   node scripts/generate-keys.mjs                          # usa JWT_SECRET do .env
 *   node scripts/generate-keys.mjs "meu-jwt-secret-aqui"    # passa o secret direto
 *
 * Saida: dois JWTs prontos para colar no .env e no kong.yml.
 */

import { readFileSync } from "fs";
import { createHmac } from "crypto";

function base64url(str) {
  return Buffer.from(str)
    .toString("base64")
    .replace(/=/g, "")
    .replace(/\+/g, "-")
    .replace(/\//g, "_");
}

function signJWT(payload, secret) {
  const header = base64url(JSON.stringify({ alg: "HS256", typ: "JWT" }));
  const body = base64url(JSON.stringify(payload));
  const signature = createHmac("sha256", secret)
    .update(`${header}.${body}`)
    .digest("base64")
    .replace(/=/g, "")
    .replace(/\+/g, "-")
    .replace(/\//g, "_");
  return `${header}.${body}.${signature}`;
}

// Resolve o JWT_SECRET
let secret = process.argv[2];

if (!secret) {
  try {
    const envContent = readFileSync(".env", "utf-8");
    const match = envContent.match(/^JWT_SECRET=(.+)$/m);
    if (match) secret = match[1].trim();
  } catch {
    // .env nao encontrado
  }
}

if (!secret) {
  console.error("Erro: JWT_SECRET nao encontrado.");
  console.error("Passe como argumento ou defina no .env");
  console.error("");
  console.error('  node scripts/generate-keys.mjs "seu-secret-aqui"');
  process.exit(1);
}

if (secret.length < 32) {
  console.error(`Aviso: JWT_SECRET tem ${secret.length} caracteres (minimo recomendado: 32)`);
}

const now = Math.floor(Date.now() / 1000);
const exp = now + 10 * 365 * 24 * 60 * 60; // 10 anos

const anonKey = signJWT(
  { role: "anon", iss: "supabase", iat: now, exp },
  secret
);

const serviceRoleKey = signJWT(
  { role: "service_role", iss: "supabase", iat: now, exp },
  secret
);

console.log("=".repeat(70));
console.log("JWT_SECRET:", secret);
console.log("=".repeat(70));
console.log("");
console.log("ANON_KEY:");
console.log(anonKey);
console.log("");
console.log("SERVICE_ROLE_KEY:");
console.log(serviceRoleKey);
console.log("");
console.log("=".repeat(70));
console.log("");
console.log("Copie os valores acima para:");
console.log("  1. .env (ANON_KEY e SERVICE_ROLE_KEY)");
console.log("  2. volumes/kong/kong.yml (key: nos consumers anon e service_role)");
