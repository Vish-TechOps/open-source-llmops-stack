# Ragas evaluation job: sends a small test set through LiteLLM (so every answer is a
# Langfuse trace), scores the answers with Ragas, and attaches the scores to those traces.
FROM python:3.12-slim

# ragas 0.4.3 imports langchain_community.chat_models.vertexai, which
# langchain-community 0.4 removed: keep langchain-community below 0.4.
RUN pip install --no-cache-dir "ragas==0.4.3" "langchain-community<0.4" \
    "langfuse>=4.7,<5" "openai>=1.60,<2"

RUN useradd -u 10001 -m ragas
WORKDIR /app
COPY evaluate.py testset.jsonl /app/
USER 10001
ENV HOME=/home/ragas PYTHONUNBUFFERED=1
ENTRYPOINT ["python", "/app/evaluate.py"]
