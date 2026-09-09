FROM node:20-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    postgresql-client \
    curl \
    gnupg \
    ca-certificates \
    lsb-release \
    apt-transport-https \
 && curl -fsSL https://download.docker.com/linux/debian/gpg \
      | gpg --dearmor -o /usr/share/keyrings/docker.gpg \
 && echo "deb [arch=amd64 signed-by=/usr/share/keyrings/docker.gpg] https://download.docker.com/linux/debian $(lsb_release -cs) stable" \
      > /etc/apt/sources.list.d/docker.list \
 && apt-get update && apt-get install -y --no-install-recommends \
    docker-ce-cli \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY package.json ./
RUN npm install --omit=dev

COPY index.js ./

EXPOSE 9191

CMD ["node", "index.js"]
