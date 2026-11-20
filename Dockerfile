FROM mcr.microsoft.com/playwright/python:v1.65.2-noble

WORKDIR /app

ENV PYTHONUNBUFFERED=1

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY checker.py .

CMD ["python", "-u", "checker.py"]
