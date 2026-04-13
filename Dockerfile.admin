# ═══════════════════════════════════════════════════════════════════════════
# AegisRemit Admin Portal — Multi-stage Dockerfile
# Place at: Vantroxia-Labs/admin/Dockerfile
# ═══════════════════════════════════════════════════════════════════════════

# ── Stage 1: Build ─────────────────────────────────────────────────────────
FROM node:22-alpine AS build
WORKDIR /app

COPY package*.json ./
RUN npm ci

COPY . .

ARG VITE_API_BASE_URL=https://api.aegisremit.ng/api/v1
ARG VITE_USE_MOCK=false
ENV VITE_API_BASE_URL=$VITE_API_BASE_URL
ENV VITE_USE_MOCK=$VITE_USE_MOCK

RUN npm run build

# ── Stage 2: Serve with nginx ──────────────────────────────────────────────
FROM nginx:alpine AS runtime

# Custom nginx config for SPA routing
COPY --from=build /app/dist /usr/share/nginx/html

RUN cat > /etc/nginx/conf.d/default.conf << 'EOF'
server {
    listen 80;
    server_name _;
    root /usr/share/nginx/html;
    index index.html;

    # SPA fallback — all routes serve index.html
    location / {
        try_files $uri $uri/ /index.html;
    }

    # Cache static assets aggressively
    location ~* \.(js|css|png|jpg|jpeg|gif|ico|svg|woff|woff2)$ {
        expires 1y;
        add_header Cache-Control "public, immutable";
    }

    # Security headers
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;

    # Gzip
    gzip on;
    gzip_types text/css application/javascript application/json image/svg+xml;
    gzip_min_length 256;
}
EOF

EXPOSE 80
CMD ["nginx", "-g", "daemon off;"]
