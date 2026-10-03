FROM node:22-bookworm-slim
ENV NODE_ENV=production PORT=8080
WORKDIR /app
COPY package.json pnpm-lock.yaml pnpm-workspace.yaml ./
RUN npm install --global pnpm@11.25.0 && pnpm install --prod --frozen-lockfile --ignore-scripts
COPY server ./server
USER node
EXPOSE 8080
CMD ["node", "server/index.mjs"]
