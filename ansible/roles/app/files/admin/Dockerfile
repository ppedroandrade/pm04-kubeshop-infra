FROM python:3.12-alpine
RUN apk add --no-cache openssh-client \
 && adduser -D -u 10001 admin
WORKDIR /app
COPY app.py index.html login.html ./
USER 10001
EXPOSE 8080
HEALTHCHECK --interval=15s --timeout=3s CMD wget -q -O /dev/null http://127.0.0.1:8080/admin/healthz || exit 1
CMD ["python", "-u", "app.py"]
