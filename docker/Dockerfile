# ==============================================================================
# GitNexus Docker Image
# Multi-stage build: web-ui (static) + backend (runtime)
# ==============================================================================

# ------------------------------------------------------------------------------
# Stage 1: Build the web-ui static files
# ------------------------------------------------------------------------------
FROM node:22-trixie AS web-builder

RUN corepack enable && corepack prepare pnpm@latest --activate

WORKDIR /build

# gitnexus-web depends on gitnexus-shared via file:../gitnexus-shared.
# Build it first so TypeScript can resolve the package's dist declarations.
COPY gitnexus-shared/package.json gitnexus-shared/package-lock.json* ./gitnexus-shared/
RUN npm ci --prefix gitnexus-shared
COPY gitnexus-shared/ ./gitnexus-shared/
RUN npm run build --prefix gitnexus-shared

# vite.config.ts reads the backend package.json for the required Node version.
COPY gitnexus/package.json ./gitnexus/package.json

WORKDIR /build/gitnexus-web
COPY gitnexus-web/package.json gitnexus-web/pnpm-lock.yaml* gitnexus-web/package-lock.json* ./

# Install deps — use npm install (lockfile may be out of sync with package.json)
RUN if [ -f pnpm-lock.yaml ]; then \
      pnpm install --frozen-lockfile; \
    elif [ -f package-lock.json ]; then \
      npm install; \
    else \
      pnpm install; \
    fi

COPY gitnexus-web/ ./

RUN if [ -f pnpm-lock.yaml ]; then \
      pnpm run build; \
    else \
      npm run build; \
    fi

# ------------------------------------------------------------------------------
# Stage 2: Build the backend
# ------------------------------------------------------------------------------
FROM node:22-trixie AS backend-builder

# Required for tree-sitter native compilation
RUN apt-get update && apt-get install -y \
    python3 \
    make \
    g++ \
    git \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build

# gitnexus depends on gitnexus-shared via file:../gitnexus-shared.
COPY gitnexus-shared/package.json gitnexus-shared/package-lock.json* ./gitnexus-shared/
RUN npm ci --prefix gitnexus-shared
COPY gitnexus-shared/ ./gitnexus-shared/
RUN npm run build --prefix gitnexus-shared

WORKDIR /build/gitnexus
COPY gitnexus/package.json gitnexus/package-lock.json* ./
COPY gitnexus/scripts/ ./scripts/

# Install all deps (including devDependencies for tsc build)
# --ignore-scripts: skip prepare (which runs tsc) since source files aren't copied yet
RUN npm ci --ignore-scripts

# Run postinstall manually (patches tree-sitter-swift binding.gyp for native compilation)
RUN npm run postinstall

# Rebuild only @ladybugdb/core native module (compiles lbugjs.node via install.js)
# Don't rebuild all modules — tree-sitter-swift fails and isn't needed for serve
RUN cd node_modules/@ladybugdb/core && node install.js

COPY gitnexus/ ./

# Build TypeScript (now that source files are present)
RUN npm run build

# Prune devDependencies for runtime image
RUN npm prune --production

# ------------------------------------------------------------------------------
# Stage 3: Runtime image
# ------------------------------------------------------------------------------
FROM node:22-trixie-slim

# Git is needed for `gitnexus analyze` (git rev-parse, etc.)
# Python3 is needed for entrypoint registry generation
RUN apt-get update && apt-get install -y \
    git \
    python3 \
    && rm -rf /var/lib/apt/lists/*

# Create app user
# Use UID 1000 to match the `node` user (already exists in node:22 base images)
# and the typical host user UID. This ensures the app can read/write .gitnexus/
# files through the OverlayFS merged view without copy-up (same UID = same perms).
# No need for useradd — `node` user already exists with UID 1000.

WORKDIR /app

# Copy backend
COPY --from=backend-builder /build/gitnexus/dist/ ./dist/
COPY --from=backend-builder /build/gitnexus/node_modules/ ./node_modules/
COPY --from=backend-builder /build/gitnexus/package.json ./
COPY --from=backend-builder /build/gitnexus/vendor/ ./vendor/
COPY --from=backend-builder /build/gitnexus/hooks/ ./hooks/
COPY --from=backend-builder /build/gitnexus/skills/ ./skills/
COPY --from=backend-builder /build/gitnexus/scripts/ ./scripts/

# Copy built web-ui static files
COPY --from=web-builder /build/gitnexus-web/dist/ /srv/web/

# Inject a script that sets the backend URL to the current origin.
# The web-ui defaults to http://localhost:4747 which won't work through the
# Caddy reverse proxy. This script runs before the React app loads and sets
# localStorage so the useBackend hook picks up the correct origin-relative URL.
RUN sed -i 's|<head>|<head><script>try{if(!localStorage.getItem("gitnexus-backend-url"))localStorage.setItem("gitnexus-backend-url",location.origin)}catch(e){}</script>|' /srv/web/index.html

# Copy entrypoint script
COPY docker/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# Install gosu for privilege dropping (entrypoint runs as root for OverlayFS,
# then drops to `node` user for the actual app)
RUN apt-get update && apt-get install -y gosu && rm -rf /var/lib/apt/lists/*

# Create directories for data and overlay mounts
RUN mkdir -p /home/node/.gitnexus /repos /repos-data /tmp/overlay \
    && chown -R node:node /app /home/node/.gitnexus /repos /repos-data /tmp/overlay /srv/web

# Make the CLI available globally
RUN ln -s /app/dist/cli/index.js /usr/local/bin/gitnexus \
    && chmod +x /app/dist/cli/index.js

# Entrypoint runs as root (needs mount for OverlayFS), then drops to `node` user
# USER node  -- intentionally omitted; entrypoint handles privilege drop

# Backend API port
EXPOSE 4747

# Entrypoint: create OverlayFS mounts, build registry, then exec as node user
ENTRYPOINT ["entrypoint.sh"]

# Default: start the backend server, bound to 0.0.0.0 for container access
CMD ["node", "--max-old-space-size=4096", "dist/cli/index.js", "serve", "--host", "0.0.0.0"]
