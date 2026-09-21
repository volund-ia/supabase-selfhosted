#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════════════════════
# Supabase Self-Hosted — Instalador Interativo
# Compativel com Ubuntu 20.04+, Debian 11+
# ══════════════════════════════════════════════════════════════════════════════
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Cores (desabilitadas se nao for terminal) ────────────────────────────────
if [[ -t 1 ]]; then
    R='\033[0;31m' G='\033[0;32m' Y='\033[1;33m'
    B='\033[0;34m' C='\033[0;36m' W='\033[1m' N='\033[0m'
else
    R='' G='' Y='' B='' C='' W='' N=''
fi

info()  { printf "${B}ℹ${N}  %s\n" "$*"; }
ok()    { printf "${G}✔${N}  %s\n" "$*"; }
warn()  { printf "${Y}⚠${N}  %s\n" "$*"; }
err()   { printf "${R}✖${N}  %s\n" "$*" >&2; }
step()  { printf "\n${W}${C}── %s ──${N}\n\n" "$*"; }

ask() {
    local result
    if [[ -n "${2:-}" ]]; then
        read -rp "$(printf "  ${W}%s${N} [%s]: " "$1" "$2")" result
        printf '%s' "${result:-$2}"
    else
        read -rp "$(printf "  ${W}%s${N}: " "$1")" result
        printf '%s' "$result"
    fi
}

ask_secret() {
    local result
    if [[ -n "${2:-}" ]]; then
        read -rsp "$(printf "  ${W}%s${N} [******]: " "$1")" result; echo >&2
        printf '%s' "${result:-$2}"
    else
        read -rsp "$(printf "  ${W}%s${N}: " "$1")" result; echo >&2
        printf '%s' "$result"
    fi
}

confirm() {
    local r
    while true; do
        read -rp "$(printf "  ${W}%s${N} [%s]: " "${1:-Continuar?}" "${2:-s}")" r
        case "${r:-${2:-s}}" in
            [sSyY]*) return 0 ;; [nN]*) return 1 ;;
            *) echo "  Responda s ou n." ;;
        esac
    done
}

choose() {
    local prompt="$1"; shift
    local i=1
    for opt in "$@"; do printf "  %d) %s\n" "$i" "$opt"; ((i++)); done
    echo
    local c
    while true; do
        read -rp "$(printf "  ${W}%s${N}: " "$prompt")" c
        if [[ "$c" =~ ^[0-9]+$ ]] && (( c >= 1 && c <= $# )); then
            return $((c - 1))
        fi
        printf "  Escolha entre 1 e %d.\n" "$#"
    done
}

# ── JWT (HS256 puro com openssl) ─────────────────────────────────────────────
b64url() { openssl enc -base64 -A | tr '+/' '-_' | tr -d '='; }

gen_jwt() {
    local secret="$1" role="$2"
    local now; now=$(date +%s)
    local exp=$((now + 315360000))
    local h; h=$(printf '{"alg":"HS256","typ":"JWT"}' | b64url)
    local p; p=$(printf '{"role":"%s","iss":"supabase","iat":%d,"exp":%d}' \
                 "$role" "$now" "$exp" | b64url)
    local s; s=$(printf '%s.%s' "$h" "$p" \
                 | openssl dgst -sha256 -hmac "$secret" -binary | b64url)
    printf '%s.%s.%s' "$h" "$p" "$s"
}

# ── Pre-requisitos ───────────────────────────────────────────────────────────
check_prereqs() {
    step "Pre-requisitos"
    local fail=false
    for cmd in docker openssl curl; do
        if command -v "$cmd" &>/dev/null; then
            ok "$cmd"
        else
            err "$cmd nao encontrado"; fail=true
        fi
    done
    if docker compose version &>/dev/null; then
        ok "docker compose $(docker compose version --short 2>/dev/null || true)"
    else
        err "docker compose v2 nao encontrado"; fail=true
    fi
    if $fail; then err "Instale os itens acima e execute novamente."; exit 1; fi
}

# ══════════════════════════════════════════════════════════════════════════════
# GERACAO DE ARQUIVOS
# ══════════════════════════════════════════════════════════════════════════════

write_env() {
    local f="${SCRIPT_DIR}/.env"
    : > "$f"
    _p() { printf '%s\n' "$1" >> "$f"; }
    _v() { printf '%s=%s\n' "$1" "$2" >> "$f"; }

    _p "# Supabase Self-Hosted — gerado por install.sh ($(date '+%Y-%m-%d %H:%M'))"
    _p ""
    _p "# PostgreSQL"
    _v POSTGRES_HOST "$PG_HOST"
    _v POSTGRES_PORT "$PG_PORT"
    _v POSTGRES_USER "$PG_USER"
    _v POSTGRES_PASSWORD "$PG_PASS"
    _v POSTGRES_DB "$PG_DB"
    _p ""
    _p "# JWT"
    _v JWT_SECRET "$JWT_SECRET"
    _v ANON_KEY "$ANON_KEY"
    _v SERVICE_ROLE_KEY "$SERVICE_KEY"
    _p ""
    _p "# URLs"
    _v API_EXTERNAL_URL "$API_URL"
    _v SITE_URL "$SITE_URL"
    _p ""
    _p "# Auth (GoTrue)"
    _v GOTRUE_JWT_EXP 3600
    _v ADDITIONAL_REDIRECT_URLS ""
    _v GOTRUE_URI_ALLOW_LIST ""
    _v DISABLE_SIGNUP "false"
    _v ENABLE_EMAIL_AUTOCONFIRM "true"
    _p ""
    _p "# SMTP"
    _v SMTP_HOST "$SMTP_HOST"
    _v SMTP_PORT "$SMTP_PORT"
    _v SMTP_USER "$SMTP_USER"
    _v SMTP_PASS "$SMTP_PASS"
    _v SMTP_SENDER_NAME "$SMTP_NAME"
    _v SMTP_SENDER "${SMTP_FROM:-noreply@example.com}"
    _p ""
    _p "# Studio"
    _v STUDIO_ORG_NAME "$ORG_NAME"
    _v STUDIO_PROJECT_NAME "$PROJECT_NAME"
    _p ""
    _p "# PostgREST"
    _v PGRST_DB_SCHEMAS "public,storage,graphql_public"
    _p ""
    _p "# Realtime"
    _v SECRET_KEY_BASE "$SECRET_KEY_BASE"
    _p ""
    _p "# Nginx"
    _v NGINX_HTTP_PORT "$NGINX_HTTP"
    _v NGINX_HTTPS_PORT "$NGINX_HTTPS"
    _p ""
    _p "# Edge Functions"
    _v VERIFY_JWT "$VERIFY_JWT"
    _p ""
    _p "# Deploy Service"
    _v DEPLOY_KEY "$DEPLOY_KEY"
    _v PROD_DEPLOYER_URL "${API_URL}/deploy"
    _v PROD_DEPLOYER_API_KEY "$DEPLOY_KEY"
}

update_kong() {
    local f="${SCRIPT_DIR}/volumes/kong/kong.yml"
    awk -v a="$ANON_KEY" -v s="$SERVICE_KEY" '
        /^\s*- key:/ { n++
            if (n==1) sub(/- key: .*/, "- key: " a)
            if (n==2) sub(/- key: .*/, "- key: " s)
        } { print }
    ' "$f" > "${f}.tmp" && mv "${f}.tmp" "$f"
}

write_nginx_http() {
    cat > "${SCRIPT_DIR}/volumes/nginx/nginx.conf" << 'NGINX'
worker_processes auto;

events {
    worker_connections 1024;
}

http {
    client_max_body_size    100m;
    large_client_header_buffers 8 32k;

    upstream kong   { server kong:8000; }
    upstream studio { server studio:3000; }

    server {
        listen 80;
        server_name _;

        location /studio/_next/ {
            proxy_pass http://studio/_next/;
            proxy_set_header Host $host;
        }

        location /studio/ {
            proxy_pass         http://studio/;
            proxy_redirect     / /studio/;
            proxy_http_version 1.1;

            proxy_set_header Upgrade         $http_upgrade;
            proxy_set_header Connection      "upgrade";
            proxy_set_header Host            $host;
            proxy_set_header X-Real-IP       $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto http;

            sub_filter_once  off;
            sub_filter_types text/html application/javascript;
            sub_filter '/_next/' '/studio/_next/';
        }

        location / {
            proxy_pass http://kong;
            proxy_http_version 1.1;

            proxy_set_header Upgrade         $http_upgrade;
            proxy_set_header Connection      "upgrade";
            proxy_set_header Host            $host;
            proxy_set_header X-Real-IP       $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto http;
        }

        location /deploy/ {
            proxy_pass http://deploy-service:9191/deploy/;

            proxy_set_header Host              $host;
            proxy_set_header X-Real-IP         $remote_addr;
            proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto http;

            client_max_body_size 200m;
            proxy_read_timeout   300s;
            proxy_send_timeout   300s;
        }
    }
}
NGINX
}

write_nginx_https() {
    cat > "${SCRIPT_DIR}/volumes/nginx/nginx.conf" << 'NGINX'
worker_processes auto;

events {
    worker_connections 1024;
}

http {
    client_max_body_size    100m;
    large_client_header_buffers 8 32k;

    upstream kong   { server kong:8000; }
    upstream studio { server studio:3000; }

    # HTTP -> HTTPS redirect
    server {
        listen 80;
        server_name _;
        return 301 https://$host$request_uri;
    }

    server {
        listen 443 ssl;
        server_name _;

        ssl_certificate     /etc/nginx/ssl/fullchain.crt;
        ssl_certificate_key /etc/nginx/ssl/server.key;
        ssl_protocols       TLSv1.2 TLSv1.3;
        ssl_ciphers         HIGH:!aNULL:!MD5;

        location /studio/_next/ {
            proxy_pass http://studio/_next/;
            proxy_set_header Host $host;
        }

        location /studio/ {
            proxy_pass         http://studio/;
            proxy_redirect     / /studio/;
            proxy_redirect     http:// https://;
            proxy_http_version 1.1;

            proxy_set_header Upgrade         $http_upgrade;
            proxy_set_header Connection      "upgrade";
            proxy_set_header Host            $host;
            proxy_set_header X-Real-IP       $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto https;

            sub_filter_once  off;
            sub_filter_types text/html application/javascript;
            sub_filter '/_next/' '/studio/_next/';
        }

        location / {
            proxy_pass http://kong;
            proxy_http_version 1.1;

            proxy_set_header Upgrade         $http_upgrade;
            proxy_set_header Connection      "upgrade";
            proxy_set_header Host            $host;
            proxy_set_header X-Real-IP       $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto https;
        }

        location /deploy/ {
            proxy_pass http://deploy-service:9191/deploy/;

            proxy_set_header Host              $host;
            proxy_set_header X-Real-IP         $remote_addr;
            proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto https;

            client_max_body_size 200m;
            proxy_read_timeout   300s;
            proxy_send_timeout   300s;
        }
    }
}
NGINX
}

# ══════════════════════════════════════════════════════════════════════════════
# MAIN
# ══════════════════════════════════════════════════════════════════════════════
main() {
    printf "\n${W}${C}"
    printf '  ╔══════════════════════════════════════════════════════════╗\n'
    printf '  ║         Supabase Self-Hosted — Instalador               ║\n'
    printf '  ╚══════════════════════════════════════════════════════════╝\n'
    printf "${N}\n"

    check_prereqs

    # ── 1. Modo ──────────────────────────────────────────────────────────
    step "Modo de instalacao"
    choose "Escolha" \
        "Desenvolvimento local (HTTP, banco embarcado)" \
        "Producao (HTTPS, banco externo recomendado)"
    local MODE=$?

    # Defaults
    PG_HOST="db"; PG_PORT=5432; PG_USER="postgres"; PG_PASS="postgres"; PG_DB="postgres"
    local PG_EMBEDDED=true SSL=false
    NGINX_HTTP=8080; NGINX_HTTPS=8443
    VERIFY_JWT=false
    DEPLOY_KEY="local-deploy-key"
    ORG_NAME="Local Dev"; PROJECT_NAME="Supabase Local"
    SMTP_HOST=""; SMTP_PORT=587; SMTP_USER=""; SMTP_PASS=""; SMTP_FROM=""; SMTP_NAME="Supabase"
    SITE_URL="http://localhost:3000"

    if [[ $MODE -eq 1 ]]; then
        PG_EMBEDDED=false; SSL=true
        NGINX_HTTP=80; NGINX_HTTPS=443
        VERIFY_JWT=true
        DEPLOY_KEY=""; ORG_NAME="Minha Org"; PROJECT_NAME="Supabase"
    fi

    # ── 2. Dominio ───────────────────────────────────────────────────────
    step "Dominio e URLs"
    local DOMAIN API_PORT=8000

    if [[ $MODE -eq 1 ]]; then
        DOMAIN=$(ask "Dominio da API (ex: api.meudominio.com.br)" "")
        [[ -z "$DOMAIN" ]] && { err "Dominio obrigatorio para producao."; exit 1; }
        local SITE_DOMAIN
        SITE_DOMAIN=$(ask "Dominio do site/app" "app.${DOMAIN#api.}")
        API_URL="https://${DOMAIN}"
        SITE_URL="https://${SITE_DOMAIN}"
    else
        NGINX_HTTP=$(ask "Porta HTTP do Nginx" "$NGINX_HTTP")
        API_PORT=$(ask "Porta da API (Kong)" "$API_PORT")
        DOMAIN="localhost"
        API_URL="http://localhost:${API_PORT}"
    fi

    info "API: ${API_URL}"
    info "Site: ${SITE_URL}"

    # ── 3. PostgreSQL ────────────────────────────────────────────────────
    step "PostgreSQL"

    if [[ $MODE -eq 1 ]]; then
        choose "Tipo de PostgreSQL" \
            "Externo (recomendado para producao)" \
            "Embarcado no Docker"
        [[ $? -eq 1 ]] && PG_EMBEDDED=true || PG_EMBEDDED=false
    else
        choose "Tipo de PostgreSQL" \
            "Embarcado no Docker (zero config)" \
            "Externo (outra VM ou servidor)"
        [[ $? -eq 0 ]] && PG_EMBEDDED=true || PG_EMBEDDED=false
    fi

    if $PG_EMBEDDED; then
        info "Usando Postgres embarcado (supabase/postgres:15.6.1.143)"
        PG_HOST="db"
        PG_PASS=$(ask_secret "Senha do Postgres" "postgres")
    else
        PG_HOST=$(ask "Host do PostgreSQL" "10.0.0.100")
        PG_PORT=$(ask "Porta" "5432")
        PG_USER=$(ask "Usuario" "postgres")
        PG_PASS=$(ask_secret "Senha" "")
        PG_DB=$(ask "Database" "postgres")
        [[ -z "$PG_PASS" ]] && { err "Senha obrigatoria."; exit 1; }
    fi

    # ── 4. JWT ───────────────────────────────────────────────────────────
    step "JWT (JSON Web Tokens)"
    choose "JWT Secret" \
        "Gerar automaticamente (recomendado)" \
        "Informar manualmente"
    if [[ $? -eq 0 ]]; then
        JWT_SECRET=$(openssl rand -base64 48 | tr -d '\n')
        ok "JWT Secret gerado (${#JWT_SECRET} caracteres)"
    else
        JWT_SECRET=$(ask "JWT Secret (min. 32 caracteres)" "")
        (( ${#JWT_SECRET} < 32 )) && { err "Minimo 32 caracteres."; exit 1; }
    fi

    info "Gerando ANON_KEY e SERVICE_ROLE_KEY..."
    ANON_KEY=$(gen_jwt "$JWT_SECRET" "anon")
    SERVICE_KEY=$(gen_jwt "$JWT_SECRET" "service_role")
    ok "Chaves JWT geradas"

    # ── 5. SSL ───────────────────────────────────────────────────────────
    local CERT_PATH="" KEY_PATH=""
    if $SSL; then
        step "SSL / HTTPS"
        CERT_PATH=$(ask "Certificado fullchain (PEM)" "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem")
        KEY_PATH=$(ask "Chave privada (PEM)" "/etc/letsencrypt/live/${DOMAIN}/privkey.pem")
    fi

    # ── 6. SMTP ──────────────────────────────────────────────────────────
    step "SMTP (e-mail)"
    if confirm "Configurar envio de e-mails (SMTP)?" "n"; then
        SMTP_HOST=$(ask "Host SMTP" "smtp.gmail.com")
        SMTP_PORT=$(ask "Porta" "587")
        SMTP_USER=$(ask "Usuario" "")
        SMTP_PASS=$(ask_secret "Senha" "")
        SMTP_FROM=$(ask "E-mail remetente" "$SMTP_USER")
        SMTP_NAME=$(ask "Nome remetente" "Supabase")
    fi

    # ── 7. Studio ────────────────────────────────────────────────────────
    step "Studio (Dashboard)"
    ORG_NAME=$(ask "Organizacao" "$ORG_NAME")
    PROJECT_NAME=$(ask "Projeto" "$PROJECT_NAME")

    # ── 8. Deploy key ────────────────────────────────────────────────────
    step "Deploy Service"
    if [[ $MODE -eq 1 ]]; then
        choose "Deploy Key" "Gerar automaticamente" "Informar manualmente"
        if [[ $? -eq 0 ]]; then
            DEPLOY_KEY=$(openssl rand -hex 32)
            ok "Deploy Key gerada"
        else
            DEPLOY_KEY=$(ask "Deploy Key" "")
        fi
    else
        DEPLOY_KEY=$(ask "Deploy Key" "$DEPLOY_KEY")
    fi

    # ── Resumo ───────────────────────────────────────────────────────────
    step "Resumo da configuracao"

    printf "  %-16s ${W}%s${N}\n" "Modo:" "$([ $MODE -eq 0 ] && echo 'Desenvolvimento' || echo 'Producao')"
    printf "  %-16s ${W}%s${N}\n" "PostgreSQL:" "$($PG_EMBEDDED && echo 'Embarcado (Docker)' || echo "Externo (${PG_HOST}:${PG_PORT})")"
    printf "  %-16s ${W}%s${N}\n" "SSL:" "$($SSL && echo 'Habilitado' || echo 'Desabilitado')"
    printf "  %-16s ${W}%s${N}\n" "API:" "$API_URL"
    printf "  %-16s ${W}%s${N}\n" "Site:" "$SITE_URL"
    printf "  %-16s ${W}%s${N}\n" "SMTP:" "$([ -n "$SMTP_HOST" ] && echo "${SMTP_HOST}:${SMTP_PORT}" || echo 'Nao configurado')"
    printf "  %-16s ${W}%s${N}\n" "Studio:" "${ORG_NAME} / ${PROJECT_NAME}"
    printf "  %-16s ${W}%s${N}\n" "Deploy Key:" "${DEPLOY_KEY:0:16}..."
    echo

    confirm "Confirmar e instalar?" "s" || { info "Cancelado."; exit 0; }

    # ══════════════════════════════════════════════════════════════════════
    # EXECUCAO
    # ══════════════════════════════════════════════════════════════════════

    SECRET_KEY_BASE=$(openssl rand -base64 48 | tr -d '\n')

    # Backup de configs existentes
    for f in .env volumes/kong/kong.yml volumes/nginx/nginx.conf; do
        [[ -f "${SCRIPT_DIR}/$f" ]] && cp "${SCRIPT_DIR}/$f" "${SCRIPT_DIR}/${f}.bak" 2>/dev/null || true
    done

    step "Gerando configuracoes"

    write_env;    ok ".env"
    update_kong;  ok "volumes/kong/kong.yml"

    if $SSL; then write_nginx_https; else write_nginx_http; fi
    ok "volumes/nginx/nginx.conf"

    # Certificados SSL
    if $SSL; then
        mkdir -p "${SCRIPT_DIR}/cert"
        if [[ -f "$CERT_PATH" ]] && [[ -f "$KEY_PATH" ]]; then
            cp "$CERT_PATH" "${SCRIPT_DIR}/cert/fullchain.crt"
            cp "$KEY_PATH"  "${SCRIPT_DIR}/cert/server.key"
            ok "Certificados copiados para cert/"
        else
            warn "Certificados nao encontrados nos caminhos informados."
            warn "Copie-os antes de iniciar o stack:"
            warn "  cp $CERT_PATH cert/fullchain.crt"
            warn "  cp $KEY_PATH cert/server.key"
        fi
    fi

    # Inicializar banco externo
    if ! $PG_EMBEDDED; then
        step "Banco de dados externo"
        info "O banco externo precisa ser inicializado com roles e schemas."
        info "Script: scripts/init-database.sql"
        echo
        if confirm "Executar init-database.sql agora?" "s"; then
            info "Conectando em ${PG_HOST}:${PG_PORT}..."
            sed "s/TROQUE_PELA_SUA_SENHA/${PG_PASS}/g" "${SCRIPT_DIR}/scripts/init-database.sql" \
                | docker run --rm -i \
                    -e PGPASSWORD="$PG_PASS" \
                    postgres:15 \
                    psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d "$PG_DB" \
                         -v ON_ERROR_STOP=0 2>&1 | tail -10
            ok "Banco inicializado"
        else
            warn "Execute manualmente antes de iniciar os servicos:"
            warn "  psql -h ${PG_HOST} -U ${PG_USER} -d ${PG_DB} -f scripts/init-database.sql"
        fi
    fi

    # Docker pull & start
    step "Docker"

    if confirm "Baixar imagens e iniciar servicos agora?" "s"; then
        cd "$SCRIPT_DIR"

        info "Baixando imagens Docker (pode demorar na primeira vez)..."
        docker compose pull 2>&1 | tail -5
        ok "Imagens prontas"

        info "Iniciando servicos..."
        docker compose up -d 2>&1 | tail -5
        ok "Servicos iniciados"

        # Health check
        info "Aguardando servicos..."
        local i=0 health_url
        if [[ $MODE -eq 0 ]]; then
            health_url="http://localhost:${API_PORT}/auth/v1/health"
        else
            health_url="http://localhost:8000/auth/v1/health"
        fi

        while (( i < 30 )); do
            if curl -sf "$health_url" -H "apikey: ${ANON_KEY}" &>/dev/null 2>&1; then
                ok "Auth respondendo"
                break
            fi
            ((i++)); sleep 2
        done
        (( i >= 30 )) && warn "Auth demorou para responder. Verifique: docker compose logs auth"
    else
        info "Execute quando estiver pronto:"
        info "  cd ${SCRIPT_DIR} && docker compose up -d"
    fi

    # Nota sobre banco embarcado nao utilizado
    if ! $PG_EMBEDDED; then
        echo
        info "O container 'db' (Postgres embarcado) inicia junto com os demais."
        info "Para economizar recursos, pare-o:"
        info "  docker compose stop db"
    fi

    # ── Finalizacao ──────────────────────────────────────────────────────
    printf "\n${G}${W}"
    printf '  ══════════════════════════════════════════════════════════\n'
    printf '    Instalacao concluida!\n'
    printf '  ══════════════════════════════════════════════════════════\n'
    printf "${N}\n"

    if [[ $MODE -eq 0 ]]; then
        printf "  API:       ${W}%s${N}\n" "$API_URL"
        printf "  Studio:    ${W}http://localhost:%s/studio/${N}\n" "$NGINX_HTTP"
    else
        printf "  API:       ${W}%s${N}\n" "$API_URL"
        printf "  Studio:    ${W}https://%s/studio/${N}\n" "$DOMAIN"
    fi
    echo
    printf "  Comandos uteis:\n"
    printf "    ${W}docker compose logs -f${N}         Ver logs\n"
    printf "    ${W}docker compose down${N}            Parar tudo\n"
    printf "    ${W}docker compose up -d${N}           Iniciar tudo\n"
    printf "    ${W}docker compose ps${N}              Status dos servicos\n"
    printf "    ${W}./supabaseself config${N}          Configurar CLI remoto\n"
    echo

    if ! $PG_EMBEDDED; then
        info "Proximo passo: aplique as migrations do seu projeto"
        printf "  ${W}./supabaseself db push --dir ./caminho/das/migrations${N}\n"
    fi
    echo
}

main "$@"
