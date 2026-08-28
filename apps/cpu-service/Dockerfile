# cpu-service — two-stage build; runtime image contains no build toolchain.
#
# Uses `npm ci` rather than `npm install`: it installs the EXACT dependency tree
# recorded in package-lock.json and fails if the lockfile deviates from package.json.
# The same commit always yields the same image — matching deterministic builds in
# memory-service (strictly pinned requirements.txt) and disk-service (pinned pom.xml).
#
# Practical effect: upstream minor releases cannot break builds without code changes.
# Upgrading dependencies requires updating the lockfile, visible in pull request diffs.
FROM node:20-alpine AS builder
WORKDIR /app

COPY package*.json ./
RUN npm ci

COPY tsconfig.json ./
COPY src ./src
RUN npm run build

# Prune devDependencies in the builder stage before copying. This installs dependencies
# ONCE instead of twice, keeping TypeScript and ts-node out of the final image.
RUN npm prune --omit=dev

FROM node:20-alpine AS runner
WORKDIR /app
ENV NODE_ENV=production
ENV PORT=4001

# --chown ensures files are owned by the process user. Without it, files belong to root
# and a process with uid 1000 may not be able to read them.
COPY --from=builder --chown=node:node /app/node_modules ./node_modules
COPY --from=builder --chown=node:node /app/dist ./dist
COPY --chown=node:node package.json ./

# Run non-root directly from the image, without relying on external Kubernetes securityContext.
# `node` is a pre-existing user in node:20-alpine with uid 1000 — matching the manifest.
USER node

EXPOSE 4001
CMD ["node", "dist/index.js"]
