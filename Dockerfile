FROM mcr.microsoft.com/playwright/python:v1.65.2-noble

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY checker.py .

CMD ["python", "checker.py"]
