# Supabase Self-Hosted

Deploy completo do Supabase em infraestrutura propria, com instalador interativo, PostgreSQL embarcado ou externo, e deploy remoto via API.

## Instalacao rapida

```bash
git clone git@github.com:volund-ia/supabase-selfhosted.git
cd supabase-selfhosted
chmod +x install.sh
./install.sh
```

O instalador faz tudo: verifica pre-requisitos, pergunta as configuracoes, gera chaves JWT, configura nginx/kong, e sobe os servicos Docker.

## Pre-requisitos

- **Ubuntu 20.04+** ou Debian 11+ (testado nessas distros)
- **Docker** e **Docker Compose v2**
- **openssl** e **curl** (geralmente ja instalados)

### Instalacao do Docker (se necessario)

```bash
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker $USER
# faça logout e login para aplicar o grupo
```

## O que o instalador pergunta

O `install.sh` e interativo e guia voce por todas as decisoes:

| Etapa | Pergunta | Opcoes |
|---|---|---|
| **Modo** | Desenvolvimento ou Producao? | Dev: HTTP + Postgres embarcado. Prod: HTTPS + externo |
| **Dominio** | URL da API e do site | Dev: localhost com portas customizaveis |
| **PostgreSQL** | Embarcado ou externo? | Embarcado: zero config. Externo: host/porta/senha |
| **JWT** | Gerar automaticamente ou informar? | Gera secret + ANON_KEY + SERVICE_ROLE_KEY |
| **SSL** | Caminhos dos certificados | Aceita Let's Encrypt ou certs customizados |
| **SMTP** | Configurar envio de e-mails? | Opcional — host, porta, credenciais |
| **Studio** | Nome da org e projeto | Exibidos no dashboard |
| **Deploy Key** | Chave de autenticacao da API | Gerada automaticamente ou manual |

### Exemplo: desenvolvimento local

```
Escolha: 1 (Desenvolvimento local)
Porta HTTP do Nginx: 8080
Porta da API: 8000
Senha do Postgres: [Enter para "postgres"]
JWT Secret: 1 (Gerar automaticamente)
SMTP: n (nao configurar)
Organizacao: Minha Org
Projeto: Meu Projeto
Deploy Key: [Enter para "local-deploy-key"]
```

Resultado: stack completa rodando em `http://localhost:8000` (API) e `http://localhost:8080/studio/` (dashboard).

### Exemplo: producao

```
Escolha: 2 (Producao)
Dominio da API: api.meudominio.com.br
Dominio do site: app.meudominio.com.br
PostgreSQL: 1 (Externo)
Host: 10.0.0.100
Senha: [sua senha]
JWT Secret: 1 (Gerar automaticamente)
Certificado: /etc/letsencrypt/live/api.meudominio.com.br/fullchain.pem
Chave: /etc/letsencrypt/live/api.meudominio.com.br/privkey.pem
SMTP: s
Deploy Key: 1 (Gerar automaticamente)
```

## Arquivos gerados pelo instalador

| Arquivo | Conteudo |
|---|---|
| `.env` | Todas as variaveis de ambiente (senhas, JWT, URLs, portas) |
| `volumes/kong/kong.yml` | Chaves JWT atualizadas nos consumers do API gateway |
| `volumes/nginx/nginx.conf` | Configuracao HTTP ou HTTPS conforme o modo |
| `cert/fullchain.crt` + `cert/server.key` | Certificados SSL (se produção) |

Backups dos arquivos anteriores sao criados automaticamente (`.bak`).

## Arquitetura

```
Internet
  │
  ▼
┌──────────┐    ┌──────────┐
│  Nginx   │───▶│   Kong   │──▶ Auth (GoTrue)
│ (proxy)  │    │(gateway) │──▶ REST (PostgREST)
└──────────┘    └──────────┘──▶ Realtime
  │                          ──▶ Storage
  ├──▶ Studio (/studio/)     ──▶ Meta
  └──▶ Deploy Service        ──▶ Edge Functions
       (/deploy/)
                                    │
                                    ▼
                             ┌──────────────┐
                             │  PostgreSQL   │
                             └──────────────┘
```

| Servico | Imagem | Funcao |
|---|---|---|
| nginx | `nginx:alpine` | Reverse proxy + SSL termination |
| kong | `kong:2.8.1` | API gateway (key-auth, ACL, CORS) |
| auth | `supabase/gotrue` | Autenticacao (email, OAuth, Gov.br) |
| rest | `postgrest/postgrest` | API REST automatica sobre Postgres |
| realtime | `supabase/realtime` | WebSocket subscriptions com RLS |
| storage | `supabase/storage-api` | Upload/download de arquivos |
| meta | `supabase/postgres-meta` | Metadata para o Studio |
| studio | `supabase/studio` | Dashboard web |
| functions | `supabase/edge-runtime` | Deno edge functions |
| deploy-service | Custom (Node.js) | API de deploy remoto |
| db | `supabase/postgres` | PostgreSQL embarcado (opcional) |

## Comandos do dia-a-dia

```bash
# Status dos servicos
docker compose ps

# Ver logs (todos ou de um servico)
docker compose logs -f
docker compose logs -f auth

# Parar / iniciar
docker compose down
docker compose up -d

# Reiniciar um servico
docker compose restart auth

# Parar o Postgres embarcado (quando usar externo)
docker compose stop db
```

## Re-executar o instalador

O `install.sh` pode ser re-executado a qualquer momento. Ele:
1. Faz backup dos arquivos existentes (`.bak`)
2. Gera novas configuracoes
3. Reinicia os servicos

```bash
./install.sh
```

## CLI remoto (supabaseself)

CLI para gerenciar a instancia remotamente via deploy-service.

```bash
# Configurar host e chave de deploy
./supabaseself config

# Deploy de edge functions
./supabaseself functions deploy

# Aplicar migrations
./supabaseself db push

# Ver status das migrations
./supabaseself db status

# Executar SQL
./supabaseself db exec arquivo.sql

# Dump do banco
./supabaseself db dump -o backup.sql

# Logs das functions
./supabaseself functions logs

# Variaveis de ambiente
./supabaseself functions set-env CHAVE=valor
./supabaseself functions get-env
./supabaseself functions delete-env CHAVE

# Atualizar container
./supabaseself docker pull-restart nome-do-servico
```

Disponivel em **Bash** (`supabaseself`) e **PowerShell** (`supabaseself.ps1`).

## Deploy Service API

API REST em `/deploy/` protegida por `X-Deploy-Key`:

| Endpoint | Metodo | Funcao |
|---|---|---|
| `/deploy/health` | GET | Health check |
| `/deploy/functions` | POST | Deploy de edge functions (zip) |
| `/deploy/db/push` | POST | Aplicar migrations SQL |
| `/deploy/db/baseline` | POST | Marcar migrations como aplicadas |
| `/deploy/db/status` | GET | Listar migrations aplicadas |
| `/deploy/db/exec` | POST | Executar SQL (streaming SSE) |
| `/deploy/db/dump` | POST | Iniciar pg_dump |
| `/deploy/db/dump/:jobId` | GET | Download do dump |
| `/deploy/functions/env` | GET/POST | Listar/definir env vars |
| `/deploy/functions/env/:key` | GET/DELETE | Consultar/remover env var |
| `/deploy/functions/logs` | GET | Logs do container (SSE) |
| `/deploy/docker/pull-restart` | POST | Pull + restart de container |

## Estrutura do projeto

```
├── install.sh                  # Instalador interativo
├── docker-compose.yml          # Stack completa
├── .env.example                # Template de configuracao
├── supabaseself                # CLI Bash
├── supabaseself.ps1            # CLI PowerShell
├── cert/                       # Certificados SSL
├── docker_services/
│   └── deploy-service/         # API de deploy remoto
├── scripts/
│   ├── init-database.sql       # Setup inicial do Postgres
│   ├── generate-keys.mjs       # Gerador de JWT keys (Node.js)
│   └── deploy-supabase-prod.mjs # Deploy CI/CD
└── volumes/
    ├── functions/              # Edge functions (Deno)
    ├── kong/kong.yml           # Config do API gateway
    └── nginx/nginx.conf        # Config do reverse proxy
```

## Configuracao manual (sem instalador)

Se preferir configurar manualmente:

1. `cp .env.example .env` e preencha os valores
2. Gere JWT keys: `node scripts/generate-keys.mjs`
3. Atualize `volumes/kong/kong.yml` com as chaves
4. Configure `volumes/nginx/nginx.conf` (HTTP ou HTTPS)
5. Se Postgres externo: `psql -f scripts/init-database.sql`
6. Se HTTPS: coloque certs em `cert/fullchain.crt` e `cert/server.key`
7. `docker compose up -d`

## Licenca

Uso interno.
