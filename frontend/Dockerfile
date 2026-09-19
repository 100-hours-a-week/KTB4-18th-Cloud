# syntax=docker/dockerfile:1
FROM node:24-alpine AS build
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci
COPY . .
RUN npm run build
FROM nginx:1.28-alpine
COPY --from=build /app/dist /usr/share/nginx/html
RUN printf 'server { listen 8080; root /usr/share/nginx/html; location = /health { return 200 "ok"; } location / { try_files $uri $uri/ /index.html; } }\n' > /etc/nginx/conf.d/default.conf
EXPOSE 8080
