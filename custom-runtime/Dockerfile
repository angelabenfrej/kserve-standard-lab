FROM python:3.12-slim

RUN pip install --no-cache-dir fastapi uvicorn scikit-learn joblib

COPY server.py /app/server.py
WORKDIR /app

ENTRYPOINT ["python", "server.py"]
