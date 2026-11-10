"""Ragas evaluation job for the LLMOps stack (GCP phase B).

For every model in MODELS (LiteLLM model names, e.g. "qwen-cpu,gemini"):
  1. ask each test-set question through LiteLLM, with a Langfuse trace id we choose,
     so the call shows up in Langfuse as a normal trace (LiteLLM's langfuse callback);
  2. score the answer with Ragas 0.4 metrics, judged by JUDGE_MODEL through LiteLLM:
       faithfulness        answer supported by the given context?   (needs contexts)
       answer_relevancy    answer addresses the question?           (needs embeddings)
       factual_correctness answer agrees with the reference answer?  (needs reference)
  3. attach each score to that same Langfuse trace.

Environment
  LITELLM_BASE_URL, LITELLM_API_KEY     LiteLLM proxy (OpenAI-compatible)
  MODELS                                comma-separated LiteLLM model names to evaluate
  JUDGE_MODEL, EMBEDDING_MODEL          LiteLLM model names for the judge and embeddings
  LANGFUSE_HOST, LANGFUSE_PUBLIC_KEY, LANGFUSE_SECRET_KEY
  RUN_ID                                tag that groups this run in Langfuse
  TESTSET                               JSONL path (default /app/testset.jsonl)
"""

import asyncio
import json
import os
import re
import sys
import time

from langfuse import Langfuse
from openai import AsyncOpenAI

BASE_URL = os.environ["LITELLM_BASE_URL"]
API_KEY = os.environ["LITELLM_API_KEY"]
MODELS = [m.strip() for m in os.environ.get("MODELS", "qwen-cpu,gemini").split(",") if m.strip()]
JUDGE_MODEL = os.environ.get("JUDGE_MODEL", "gemini")
EMBEDDING_MODEL = os.environ.get("EMBEDDING_MODEL", "gemini-embedding")
RUN_ID = os.environ.get("RUN_ID") or time.strftime("%Y%m%d-%H%M%S")
TESTSET = os.environ.get("TESTSET", "/app/testset.jsonl")
ANSWER_MAX_TOKENS = int(os.environ.get("ANSWER_MAX_TOKENS", "200"))
SCORING_CONCURRENCY = int(os.environ.get("SCORING_CONCURRENCY", "4"))

THINK_RE = re.compile(r"<think>.*?</think>", re.S)
SYSTEM_PROMPT = (
    "Answer the question using only the context. "
    "Be concise: two or three sentences, no lists."
)

client = AsyncOpenAI(base_url=BASE_URL, api_key=API_KEY, timeout=600, max_retries=1)
langfuse = Langfuse()  # reads LANGFUSE_HOST / LANGFUSE_PUBLIC_KEY / LANGFUSE_SECRET_KEY


def log(msg: str) -> None:
    print(msg, flush=True)


def load_testset(path: str) -> list[dict]:
    items = []
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if line:
                items.append(json.loads(line))
    return items


async def ask(model: str, item: dict) -> dict:
    """One question through LiteLLM. Returns the answer and the Langfuse trace id used."""
    trace_id = langfuse.create_trace_id()  # 32 hex chars, OpenTelemetry format
    context = "\n\n".join(item["contexts"])
    t0 = time.time()
    resp = await client.chat.completions.create(
        model=model,
        temperature=0,
        max_tokens=ANSWER_MAX_TOKENS,
        messages=[
            {"role": "system", "content": SYSTEM_PROMPT},
            {"role": "user", "content": f"Context:\n{context}\n\nQuestion: {item['question']}"},
        ],
        # LiteLLM reads `metadata` and passes it to its Langfuse callback.
        extra_body={
            "metadata": {
                "trace_id": trace_id,
                "trace_name": f"ragas-{model}",
                "generation_name": f"ragas-{model}",
                "session_id": f"ragas-{RUN_ID}",
                "tags": ["llmops-stack", "ragas", f"ragas-{RUN_ID}", model],
            }
        },
    )
    answer = THINK_RE.sub("", resp.choices[0].message.content or "").strip()
    return {"trace_id": trace_id, "answer": answer, "seconds": round(time.time() - t0, 1)}


def build_metrics():
    # Imported here so a broken Ragas install fails with a clear message, after the answers.
    from ragas.embeddings import embedding_factory
    from ragas.llms import llm_factory
    from ragas.metrics.collections import AnswerRelevancy, FactualCorrectness, Faithfulness

    judge = llm_factory(JUDGE_MODEL, provider="openai", client=client)
    embeddings = embedding_factory("openai", model=EMBEDDING_MODEL, client=client)
    return {
        "faithfulness": (Faithfulness(llm=judge), lambda it, a: {
            "user_input": it["question"], "response": a, "retrieved_contexts": it["contexts"]}),
        "answer_relevancy": (AnswerRelevancy(llm=judge, embeddings=embeddings), lambda it, a: {
            "user_input": it["question"], "response": a}),
        "factual_correctness": (FactualCorrectness(llm=judge), lambda it, a: {
            "response": a, "reference": it["reference"]}),
    }


async def score_one(metrics, sem, model, item, result) -> list[tuple[str, float | None, str]]:
    out = []
    for name, (metric, args) in metrics.items():
        async with sem:
            try:
                res = await metric.ascore(**args(item, result["answer"]))
                value = float(res.value)
                langfuse.create_score(
                    trace_id=result["trace_id"], name=name, value=value, data_type="NUMERIC",
                    comment=f"ragas 0.4 / judge {JUDGE_MODEL} / run {RUN_ID}",
                )
                out.append((name, value, ""))
            except Exception as e:  # keep going: one failed metric should not lose the rest
                out.append((name, None, f"{type(e).__name__}: {str(e)[:200]}"))
    return out


async def main() -> int:
    items = load_testset(TESTSET)
    log(f"run {RUN_ID}: {len(items)} questions x models {MODELS}; judge {JUDGE_MODEL}, embeddings {EMBEDDING_MODEL}")

    answers: dict[str, list[dict]] = {}
    for model in MODELS:
        answers[model] = []
        for i, item in enumerate(items, 1):
            try:
                r = await ask(model, item)  # sequential: the CPU model serves one at a time anyway
                log(f"[{model}] q{i} {r['seconds']}s: {r['answer'][:90]!r}")
            except Exception as e:
                r = {"trace_id": None, "answer": None, "error": f"{type(e).__name__}: {str(e)[:200]}"}
                log(f"[{model}] q{i} FAILED: {r['error']}")
            answers[model].append(r)

    metrics = build_metrics()
    sem = asyncio.Semaphore(SCORING_CONCURRENCY)
    summary: dict[str, dict[str, list[float]]] = {}
    errors = 0
    for model in MODELS:
        summary[model] = {name: [] for name in metrics}
        jobs = [
            score_one(metrics, sem, model, item, r)
            for item, r in zip(items, answers[model]) if r.get("answer")
        ]
        for res in await asyncio.gather(*jobs):
            for name, value, err in res:
                if value is None:
                    errors += 1
                    log(f"[{model}] {name} failed: {err}")
                else:
                    summary[model][name].append(value)

    langfuse.flush()

    log("\n" + "=" * 78)
    log(f"Ragas scores (mean over questions), run ragas-{RUN_ID}")
    log("=" * 78)
    header = f"{'model':<14}" + "".join(f"{n:>22}" for n in metrics)
    log(header)
    scored_models = 0
    for model in MODELS:
        row = f"{model:<14}"
        any_score = False
        for name in metrics:
            vals = summary[model][name]
            if vals:
                any_score = True
                row += f"{sum(vals) / len(vals):>16.2f} (n={len(vals)})"
            else:
                row += f"{'-':>22}"
        scored_models += any_score
        log(row)
    log("=" * 78)
    log(f"Scores are attached to the traces in Langfuse: filter by tag ragas-{RUN_ID}.")
    if errors:
        log(f"{errors} metric evaluation(s) failed (see lines above).")
    return 0 if scored_models == len(MODELS) else 1


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
