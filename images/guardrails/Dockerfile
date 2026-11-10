# Guardrails AI server for LiteLLM's `guardrails_ai` guardrail.
# Built by scripts/b13-build-images.sh with Cloud Build (no local Docker needed).
FROM python:3.12-slim

# guardrails-ai 0.11.0 pulls guardrails-api 0.4.4 (the FastAPI server); pin both.
RUN pip install --no-cache-dir "guardrails-ai[api]==0.11.0" "guardrails-api==0.4.4"

RUN useradd -u 10001 -m gr \
 && printf 'enable_metrics=false\nuse_remote_inferencing=false\n' > /home/gr/.guardrailsrc \
 && chown gr:gr /home/gr/.guardrailsrc
WORKDIR /app
COPY config.py middleware.py /app/

USER 10001
ENV HOME=/home/gr \
    GR_CONFIG_FILE_PATH=/app/config.py \
    GR_MIDDLEWARE_FILE_PATH=/app/middleware.py \
    PYTHONUNBUFFERED=1
EXPOSE 8000
# `guardrails start` binds 127.0.0.1 only; the uvicorn factory form binds all interfaces.
CMD ["uvicorn", "--factory", "guardrails_api.app:create_app", "--host", "0.0.0.0", "--port", "8000"]
