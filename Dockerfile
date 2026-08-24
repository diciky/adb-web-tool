FROM node:20-slim

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl unzip ca-certificates python3 make g++ \
    && (apt-get install -y adb || apt-get install -y android-tools-adb) \
    && rm -rf /var/lib/apt/lists/*

RUN adb version || echo "adb 未安装，请检查"

WORKDIR /app

COPY server/package.json ./server/package.json
RUN cd server && npm install --omit=dev

COPY server/ ./server/
COPY web/ ./web/
RUN cd web && npm install && npm run build

ENV PORT=8877
ENV DATA_DIR=/data
# 注意：不声明 VOLUME。数据持久化由部署方负责（docker-compose 已挂载 ./data:/data，
# 或 docker run -v <宿主目录>:/data）。若在镜像里声明 VOLUME，没挂载时 Docker 会创建
# 匿名卷，容器重建后数据看似丢失。
EXPOSE 8877

CMD ["node", "server/src/index.js"]
