# LiteLLM proxy built from the SAME pinned, checksum-verified wheel as local phase A.
# LiteLLM's own PyPI packages AND Docker images were compromised on 2026-10-21 (1.107.0),
# so this image does not start FROM theirs: it verifies the wheel hash during the build
# and fails if it does not match LITELLM_SHA256.
FROM python:3.12-slim

ARG LITELLM_VERSION
ARG LITELLM_SHA256
ARG LANGFUSE_SDK_SPEC="langfuse>=4.7,<5"

RUN test -n "$LITELLM_VERSION" && test -n "$LITELLM_SHA256" \
 && pip download --no-cache-dir --no-deps --only-binary=:all: --dest /tmp/w "litellm==${LITELLM_VERSION}" \
 && whl=$(ls /tmp/w/litellm-${LITELLM_VERSION}-*.whl) \
 && echo "wheel: $whl" \
 && echo "${LITELLM_SHA256}  ${whl}" | sha256sum -c - \
 && pip install --no-cache-dir "${whl}[proxy]" "${LANGFUSE_SDK_SPEC}" google-auth \
 && rm -rf /tmp/w \
 && site=$(python -c 'import sysconfig; print(sysconfig.get_paths()["purelib"])') \
 && if ls "$site" | grep -E '^(litellm_init\.pth|cook\.pth|cook\.py|sitecustomize\.py)$'; then echo "INCIDENT FILES FOUND"; exit 1; fi

RUN useradd -u 10001 -m litellm
USER 10001
ENV HOME=/home/litellm TZ=UTC PYTHONUNBUFFERED=1
EXPOSE 4000
ENTRYPOINT ["litellm"]
CMD ["--config", "/etc/litellm/config.yaml", "--host", "0.0.0.0", "--port", "4000"]
