# ============================================================================
# CarbonBoo 服务端镜像（FastAPI + uvicorn；MySQL 由 docker-compose 的 mysql 服务承担）
#
#   构建上下文 = server/（compose 里 build.context: ../..）
#   构建：docker compose -f deploy/docker/docker-compose.yml build
#
# 口径（与 server/deploy/README.md、AGENTS §7.2 一致）：
#   * 只装 requirements.txt 的锁定版本；不装 python-multipart（admin_web 用标准库解析表单）。
#   * 密钥**不进镜像**：server/.env 与 deploy/docker/.env 都由 .dockerignore 排除，
#     运行期通过 compose 的 env_file 注入进程环境（环境变量优先级高于 .env 文件）。
#   * 以非 root（uid/gid 10001）运行；只有 admin_web/static/uploads 需要可写。
#     `--workers 2` 与 pool_size=5 / max_overflow=5 是配套口径（2×(5+5)=20 < MySQL max_connections=30）。
# ============================================================================
FROM python:3.12-slim

# pypi.org 在本项目环境常常不可达，统一走阿里云镜像（可用 --build-arg 覆盖）
ARG PIP_INDEX_URL=https://mirrors.aliyun.com/pypi/simple/
ARG USER_UID=10001
ARG USER_GID=10001

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    TZ=Asia/Shanghai \
    LANG=C.UTF-8

RUN apt-get update \
    && apt-get install -y --no-install-recommends tzdata \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY requirements.txt /app/requirements.txt
RUN pip install --no-cache-dir -i "${PIP_INDEX_URL}" -r /app/requirements.txt

# 非 root 运行账号（与 compose 里的 user 口径一致）
RUN groupadd -g "${USER_GID}" carbonboo \
    && useradd -u "${USER_UID}" -g carbonboo -m -s /usr/sbin/nologin carbonboo

# 代码整份进镜像（.env / .venv / 缓存 由 Dockerfile.dockerignore 排除）
COPY --chown=carbonboo:carbonboo . /app

# 后台图标上传目录：镜像内先建好并给对属主，命名卷首次挂载时会继承这里的属主
RUN mkdir -p /app/admin_web/static/uploads/icons \
    && chown -R carbonboo:carbonboo /app/admin_web/static/uploads

USER carbonboo

EXPOSE 8000

# 探活走 /api/v1/health（扁平响应，不碰业务表）；用标准库，不额外装 curl
HEALTHCHECK --interval=15s --timeout=5s --start-period=30s --retries=5 \
    CMD python -c "import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:8000/api/v1/health', timeout=3).status == 200 else 1)"

# --proxy-headers + --forwarded-allow-ips=*：nginx 在另一个容器里，必须信任它的 X-Forwarded-For，
# 否则 app 侧按 IP 的登录限流（login_rate_limit_per_minute）会把所有请求都算到 nginx 头上。
CMD ["uvicorn", "app.main:app", \
     "--host", "0.0.0.0", "--port", "8000", "--workers", "2", \
     "--proxy-headers", "--forwarded-allow-ips", "*"]
