# Supabase Self-Hosted

Toolkit para deploy e gerenciamento de Supabase self-hosted com **PostgreSQL externo** e **deploy remoto** via API.

## Arquitetura

```
Internet
  │
  ▼
┌──────────┐    ┌──────────┐
│  Nginx   │───▶│   Kong   │──▶ Auth (GoTrue)
│  (SSL)   │    │ (Gateway)│──▶ REST (PostgREST)
└──────────┘    └──────────┘──▶ Realtime
  │                          ──▶ Storage
  ├──▶ Studio (/studio/)     ──▶ Meta
  └──▶ Deploy Service        ──▶ Edge Functions
       (/deploy/)
                                    │
                                    ▼
                             ┌──────────────┐
                             │  PostgreSQL   │
                             │  (externo)    │
                             └──────────────┘
```

**10 serviços Docker** orquestrados via `docker-compose.yml`:

| Serviço | Imagem | Função |
|---|---|---|
| nginx | `nginx:alpine` | Reverse proxy + SSL termination |
| kong | `kong:2.8.1` | API gateway (declarativo, sem DB) |
| auth | `supabase/gotrue` | Autenticação (email, OAuth) |
| rest | `postgrest/postgrest` | API REST automática sobre Postgres |
| realtime | `supabase/realtime` | WebSocket subscriptions com RLS |
| storage | `supabase/storage-api` | Upload/download de arquivos |
| meta | `supabase/postgres-meta` | Metadata do Postgres para Studio |
| studio | `supabase/studio` | Dashboard web do Supabase |
| functions | `supabase/edge-runtime` | Deno edge functions |
| deploy-service | Custom (Node.js) | API de deploy remoto |

## Pré-requisitos

- Docker e Docker Compose
- PostgreSQL externo acessível pelos containers
- Certificados SSL (fullchain.crt + server.key)
- Node.js 20+ (para scripts de setup)

## Setup

### 1. Inicializar o banco de dados

Execute no PostgreSQL externo:

```bash
psql -h SEU_HOST -U postgres -f scripts/init-database.sql
```

> Antes de rodar, substitua `TROQUE_PELA_SUA_SENHA` pelas senhas reais no arquivo.

### 2. Configurar variáveis de ambiente

```bash
cp .env.example .env
```

Edite `.env` com os valores do seu ambiente (host do Postgres, senhas, domínio, SMTP, etc).

### 3. Gerar chaves JWT

```bash
node scripts/generate-keys.mjs
```

Copie os valores gerados para:
- `ANON_KEY` e `SERVICE_ROLE_KEY` no `.env`
- Credenciais dos consumers `anon` e `service_role` no `volumes/kong/kong.yml`

### 4. Colocar certificados SSL

```bash
cp fullchain.crt cert/fullchain.crt
cp server.key cert/server.key
```

### 5. Subir os serviços

```bash
docker compose up -d
```

O Studio fica acessível em `https://seu-dominio/studio/`.

## CLI (supabaseself)

CLI para gerenciar a instância remotamente via deploy-service.

```bash
# Configurar host e chave de deploy
./supabaseself config

# Deploy de edge functions
./supabaseself functions deploy

# Aplicar migrations
./supabaseself db push

# Ver status das migrations
./supabaseself db status

# Executar SQL arbitrário
./supabaseself db exec arquivo.sql

# Dump do banco
./supabaseself db dump -o backup.sql

# Logs das functions
./supabaseself functions logs

# Variáveis de ambiente
./supabaseself functions set-env CHAVE=valor
./supabaseself functions get-env
./supabaseself functions delete-env CHAVE

# Atualizar container
./supabaseself docker pull-restart nome-do-servico
```

Disponível em Bash (`supabaseself`) e PowerShell (`supabaseself.ps1`).

## Deploy Remoto

O `deploy-service` expõe uma API REST em `/deploy/` protegida por `X-Deploy-Key`:

| Endpoint | Método | Função |
|---|---|---|
| `/deploy/health` | GET | Health check |
| `/deploy/functions` | POST | Deploy de edge functions (zip) |
| `/deploy/db/push` | POST | Aplicar migrations SQL |
| `/deploy/db/baseline` | POST | Marcar migrations como aplicadas |
| `/deploy/db/status` | GET | Listar migrations aplicadas |
| `/deploy/db/exec` | POST | Executar SQL (streaming) |
| `/deploy/db/dump` | POST | Iniciar pg_dump |
| `/deploy/db/dump/:jobId` | GET | Download do dump |
| `/deploy/functions/env` | GET/POST | Listar/definir env vars |
| `/deploy/functions/env/:key` | GET/DELETE | Consultar/remover env var |
| `/deploy/functions/logs` | GET | Logs do container |
| `/deploy/docker/pull-restart` | POST | Pull + restart de container |

Para automação via CI/CD, use `scripts/deploy-supabase-prod.mjs`:

```bash
node scripts/deploy-supabase-prod.mjs --functions --migrations
```

## Estrutura do Projeto

```
├── docker-compose.yml          # Stack completa
├── .env.example                # Template de configuração
├── supabaseself                # CLI Bash
├── supabaseself.ps1            # CLI PowerShell
├── cert/                       # Certificados SSL
├── docker_services/
│   └── deploy-service/         # API de deploy remoto
│       ├── Dockerfile
│       ├── index.js
│       └── package.json
├── scripts/
│   ├── init-database.sql       # Setup inicial do Postgres
│   ├── generate-keys.mjs       # Gerador de JWT keys
│   └── deploy-supabase-prod.mjs # Deploy automatizado
└── volumes/
    ├── functions/main/index.ts # Edge function router
    ├── kong/kong.yml           # Config do API gateway
    └── nginx/nginx.conf        # Config do reverse proxy
```

## Licença

Uso interno.
