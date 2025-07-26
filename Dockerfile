# ---- Stage 1: Node dependencies and frontend build ----
FROM node:18-alpine AS frontend-builder

WORKDIR /app

# Copy package files for caching
COPY package.json pnpm-lock.yaml* ./
COPY next.config.mjs postcss.config.mjs* tailwind.config.js* tsconfig.json* ./

# Install pnpm and dependencies
RUN npm install -g pnpm && pnpm install --frozen-lockfile

# Copy source code
COPY app/ ./app/
COPY components/ ./components/
COPY contexts/ ./contexts/
COPY hooks/ ./hooks/
COPY lib/ ./lib/
COPY public/ ./public/
COPY styles/ ./styles/

# Set environment variables for Next.js build
ENV FRONTEND_URL="http://13.60.246.221"
ENV BACKEND_URL="http://13.60.246.221:8000"
ENV CHAT_URL="ws://13.60.246.221:5000"
ENV CHAT_WS_URL="ws://13.60.246.221:5000"
ENV NEXT_PUBLIC_API_URL="http://13.60.246.221:8000"
ENV NEXT_PUBLIC_CHAT_WS_URL="ws://13.60.246.221:5000"

# Use lightweight Python image
FROM python:3.10-slim

# Prevent Python from writing .pyc files
ENV PYTHONDONTWRITEBYTECODE=1
ENV PYTHONUNBUFFERED=1

# Set working directory
WORKDIR /app

# Install ffmpeg and dependencies
RUN apt-get update && \
    apt-get install -y ffmpeg git && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# Install Whisper and Torch
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy the rest of the source code
COPY . .

# Default command (can be overridden)
CMD ["python", "transcribe.py"]


# Build Next.js frontend
RUN pnpm build

# ---- Stage 2: Python dependencies and backend build ----
FROM python:3.11-slim AS backend-builder

WORKDIR /app
COPY requirements.txt .
RUN python -m venv /opt/venv && \
    /opt/venv/bin/pip install --upgrade pip && \
    /opt/venv/bin/pip install --timeout=1000 --no-cache-dir -r requirements.txt

# Copy only necessary backend files (NOT entire directory)
COPY *.py ./
COPY supervisord.conf ./

# ---- Stage 3: Final image ----
FROM python:3.11-slim

# System dependencies
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        supervisor \
        curl \
        nodejs \
        npm \
    && rm -rf /var/lib/apt/lists/*

# Copy Python environment and backend
COPY --from=backend-builder /opt/venv /opt/venv
COPY --from=backend-builder /app/*.py /app/
COPY --from=backend-builder /app/supervisord.conf /etc/supervisor/conf.d/supervisord.conf

# Copy frontend build output and package files
COPY --from=frontend-builder /app/.next /app/.next
COPY --from=frontend-builder /app/public /app/public
COPY --from=frontend-builder /app/package.json /app/package.json
COPY --from=frontend-builder /app/pnpm-lock.yaml /app/pnpm-lock.yaml
COPY --from=frontend-builder /app/next.config.mjs /app/next.config.mjs

WORKDIR /app

ENV PATH="/opt/venv/bin:$PATH" \
    PYTHONUNBUFFERED=1 \
    IN_DOCKER=true

# Create supervisor log directories
RUN mkdir -p /app/logs && \
    touch /app/logs/backend.out.log /app/logs/backend.err.log \
          /app/logs/chat.out.log /app/logs/chat.err.log \
          /app/logs/frontend.out.log /app/logs/frontend.err.log && \
    chmod -R 777 /app/logs

# Health check script
RUN printf '#!/bin/bash\n\
for i in {1..3}; do\n\
  curl -sf http://localhost:8000/api/health > /dev/null && exit 0\n\
  echo "Attempt $i: Health check failed, retrying..."\n\
  sleep 5\n\
done\n\
exit 1\n' > /healthcheck.sh && chmod +x /healthcheck.sh

# Install pnpm and production node_modules for Next.js runtime
RUN npm install -g pnpm && pnpm install --prod --frozen-lockfile

# Create non-root user
RUN useradd -m appuser
RUN chown -R appuser:appuser /app
USER appuser

EXPOSE 3000 5000 8000 80

HEALTHCHECK --interval=30s --timeout=15s --start-period=120s --retries=3 CMD ["/healthcheck.sh"]

CMD ["/usr/bin/supervisord", "-c", "/etc/supervisor/conf.d/supervisord.conf"]

FROM python:3.10-slim

# Install ffmpeg and git
RUN apt-get update && \
    apt-get install -y ffmpeg git && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

# Set working directory
WORKDIR /app

# Copy requirements and install dependencies
COPY requirements.txt .
RUN pip install --upgrade pip setuptools wheel
RUN pip install --no-cache-dir -r requirements.txt

# Copy the rest of the project
COPY . .

# Expose the port FastAPI will run on
EXPOSE 8000

# Run the FastAPI app using Uvicorn
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000"]
