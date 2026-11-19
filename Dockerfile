# ปักเลขรุ่น nginx (ไม่ใช้ 1.30-alpine ลอย) — เครื่องที่มี image เก่าใน cache จะ build ได้ 1.30.x เดิมถ้าไม่ใส่ --pull
# 1.30.7 = แพตช์ความปลอดภัย 18 พ.ย. 2026 (CVE-2026-118899 TLS1.3, CVE-2026-123007 HTTP/2 ฯลฯ) · อัปรุ่นถัดไป: แก้บรรทัดนี้
FROM nginx:1.30.7-alpine

# openssl → dummy cert ตอน boot · inotify-tools → เฝ้าไฟล์ cert เพื่อ auto-reload
RUN apk add --no-cache openssl inotify-tools

# Nginx config (main + shared snippets + per-project vhosts)
# ใส่ไว้ใน image เพื่อให้ image รันได้เอง; compose จะ mount ทับให้แก้ได้โดยไม่ต้อง rebuild
COPY nginx/nginx.conf /etc/nginx/nginx.conf
COPY nginx/snippets/  /etc/nginx/snippets/
COPY nginx/projects/  /etc/nginx/projects/

# 10-*: สร้าง dummy cert ก่อน nginx start · 20-*: reload เมื่อ cert เปลี่ยน
COPY docker-entrypoint.d/10-init-dummy-cert.sh          /docker-entrypoint.d/10-init-dummy-cert.sh
COPY docker-entrypoint.d/20-reload-nginx-on-cert-change.sh /docker-entrypoint.d/20-reload-nginx-on-cert-change.sh
RUN chmod +x /docker-entrypoint.d/10-init-dummy-cert.sh \
             /docker-entrypoint.d/20-reload-nginx-on-cert-change.sh
