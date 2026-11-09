FROM python:3.12-slim
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1 DATA_PATH=/data/snapshot.sqlite3
WORKDIR /app
COPY requirements.txt .
RUN python -m pip install --no-cache-dir -r requirements.txt \
    && groupadd --gid 10001 health \
    && useradd --uid 10001 --gid health --no-create-home health \
    && mkdir /data && chown health:health /data && chmod 700 /data
COPY app ./app
USER 10001:10001
VOLUME ["/data"]
EXPOSE 8787
CMD ["python", "-m", "uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8787", "--no-access-log"]
