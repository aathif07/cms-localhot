# =============================================================================
# Stage 1: Install all dependencies (shared between server and front builds)
# =============================================================================
FROM node:24-alpine AS deps

WORKDIR /app

# Copy workspace manifests and config first for better layer caching
COPY package.json yarn.lock .yarnrc.yml tsconfig.base.json nx.json ./
COPY .yarn/releases ./.yarn/releases
COPY .yarn/patches ./.yarn/patches

# Copy only the package.json files needed for the production build
COPY packages/twenty-emails/package.json         ./packages/twenty-emails/
COPY packages/twenty-server/package.json         ./packages/twenty-server/
COPY packages/twenty-server/patches              ./packages/twenty-server/patches
COPY packages/twenty-ui/package.json             ./packages/twenty-ui/
COPY packages/twenty-shared/package.json         ./packages/twenty-shared/
COPY packages/twenty-front/package.json          ./packages/twenty-front/
COPY packages/twenty-sdk/package.json            ./packages/twenty-sdk/
COPY packages/twenty-client-sdk/package.json     ./packages/twenty-client-sdk/

# Install all dependencies (dev + prod) needed for the build
RUN yarn && yarn cache clean && npx nx reset


# =============================================================================
# Stage 2: Build the backend (twenty-server and its workspace dependencies)
# =============================================================================
FROM deps AS server-build

# Copy source for all packages required by twenty-server
COPY packages/twenty-emails     ./packages/twenty-emails
COPY packages/twenty-shared     ./packages/twenty-shared
COPY packages/twenty-ui         ./packages/twenty-ui
COPY packages/twenty-sdk        ./packages/twenty-sdk
COPY packages/twenty-client-sdk ./packages/twenty-client-sdk
COPY packages/twenty-server     ./packages/twenty-server

# Compile translations then build the server
RUN npx nx run twenty-server:lingui:extract && \
    npx nx run twenty-server:lingui:compile && \
    npx nx run twenty-emails:lingui:extract && \
    npx nx run twenty-emails:lingui:compile

RUN npx nx run twenty-server:build

# Strip type declarations and compiled tests — source maps are kept for Sentry
RUN find /app/packages/twenty-server/dist -name '*.d.ts' -delete \
 && rm -rf /app/packages/twenty-server/dist/packages/twenty-server/test

# Prune to production-only node_modules
RUN yarn workspaces focus --production \
      twenty-emails twenty-shared twenty-sdk twenty-client-sdk twenty-server


# =============================================================================
# Stage 3: Build the frontend (twenty-front)
# =============================================================================
FROM deps AS front-build

ARG REACT_APP_SERVER_BASE_URL

COPY packages/twenty-front      ./packages/twenty-front
COPY packages/twenty-ui         ./packages/twenty-ui
COPY packages/twenty-shared     ./packages/twenty-shared
COPY packages/twenty-sdk        ./packages/twenty-sdk
COPY packages/twenty-client-sdk ./packages/twenty-client-sdk

RUN npx nx run twenty-front:lingui:extract && \
    npx nx run twenty-front:lingui:compile

# Use a pre-built frontend if available (e.g. built on the host), otherwise build it
RUN if [ -d /app/packages/twenty-front/build ]; then \
      echo "Using pre-built frontend from host"; \
    else \
      NODE_OPTIONS="--max-old-space-size=8192" npx nx build twenty-front; \
    fi


# =============================================================================
# Stage 4: Production runtime image
# =============================================================================
FROM node:24-alpine AS runtime

RUN apk add --no-cache curl jq postgresql-client

WORKDIR /app/packages/twenty-server

ARG REACT_APP_SERVER_BASE_URL
ENV REACT_APP_SERVER_BASE_URL=$REACT_APP_SERVER_BASE_URL

ARG APP_VERSION
ENV APP_VERSION=$APP_VERSION

# Workspace root config
COPY --chown=1000 --from=server-build /app/package.json /app/yarn.lock /app/.yarnrc.yml /app/
COPY --chown=1000 --from=server-build /app/tsconfig.base.json /app/nx.json /app/
COPY --chown=1000 --from=server-build /app/.yarn /app/.yarn
COPY --chown=1000 --from=server-build /app/node_modules /app/node_modules

# Server package (compiled dist + package.json; no source)
COPY --chown=1000 --from=server-build /app/packages/twenty-server/package.json /app/packages/twenty-server/
COPY --chown=1000 --from=server-build /app/packages/twenty-server/dist         /app/packages/twenty-server/dist
COPY --chown=1000 --from=server-build /app/packages/twenty-server/patches      /app/packages/twenty-server/patches

# Workspace packages (dist + package.json; node_modules symlinks resolve to these)
COPY --chown=1000 --from=server-build /app/packages/twenty-shared/package.json     /app/packages/twenty-shared/
COPY --chown=1000 --from=server-build /app/packages/twenty-shared/dist             /app/packages/twenty-shared/dist
COPY --chown=1000 --from=server-build /app/packages/twenty-emails/package.json     /app/packages/twenty-emails/
COPY --chown=1000 --from=server-build /app/packages/twenty-emails/dist             /app/packages/twenty-emails/dist
COPY --chown=1000 --from=server-build /app/packages/twenty-sdk/package.json        /app/packages/twenty-sdk/
COPY --chown=1000 --from=server-build /app/packages/twenty-client-sdk/package.json /app/packages/twenty-client-sdk/
COPY --chown=1000 --from=server-build /app/packages/twenty-client-sdk/dist         /app/packages/twenty-client-sdk/dist
COPY --chown=1000 --from=server-build /app/packages/twenty-ui/package.json         /app/packages/twenty-ui/
COPY --chown=1000 --from=server-build /app/packages/twenty-front/package.json      /app/packages/twenty-front/

# Frontend static assets served by the NestJS server from dist/front
COPY --chown=1000 --from=front-build /app/packages/twenty-front/build /app/packages/twenty-server/dist/front

# Entrypoint from the docker package (handles DB migrations and cron registration)
COPY --chown=1000 packages/twenty-docker/twenty/entrypoint.sh /app/entrypoint.sh
RUN chmod +x /app/entrypoint.sh

RUN mkdir -p /app/.local-storage /app/packages/twenty-server/.local-storage && \
    chown 1000:1000 /app/.local-storage /app/packages/twenty-server/.local-storage

EXPOSE 3000

USER 1000

LABEL org.opencontainers.image.source=https://github.com/twentyhq/twenty
LABEL org.opencontainers.image.description="Production Twenty image (Railway) with backend and frontend."

CMD ["node", "dist/main"]
ENTRYPOINT ["/app/entrypoint.sh"]
