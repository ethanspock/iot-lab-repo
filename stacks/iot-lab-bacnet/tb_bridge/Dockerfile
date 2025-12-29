FROM python:3.11-slim

WORKDIR /app
ENV PYTHONUNBUFFERED=1

COPY requirements.txt /app/requirements.txt
RUN pip install --no-cache-dir -r /app/requirements.txt

COPY bridge.py /app/bridge.py
COPY points.json /app/points.json

CMD ["python", "/app/bridge.py"]
