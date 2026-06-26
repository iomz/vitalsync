FROM python:3.13-slim

WORKDIR /app

COPY receiver/pyproject.toml ./receiver/
COPY receiver/src ./receiver/src

RUN pip install --no-cache-dir ./receiver

EXPOSE 8790

CMD ["python", "-m", "vitalsync_receiver"]

