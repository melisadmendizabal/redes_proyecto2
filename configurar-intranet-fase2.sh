#!/usr/bin/env bash
# Ejecutar como root en la EC2 de la intranet (Amazon Linux 2023).
# desplegar-intranet-fase2.sh lo pasa como user data a vm-intranet-rrhh.
set -euo pipefail

intranet_ip=${1:-10.10.0.101}
fqdn=rrhh.mansiondeldisfraz.local
web_root=/usr/share/nginx/rrhh

# La subred Data Center no tiene Internet: dnf llega a los repositorios por el endpoint de S3
for intento in $(seq 1 20); do
  dnf install -y nginx && break
  echo "REDES INTRANET dnf intento ${intento} fallido, reintentando"
  sleep 15
done
rpm -q nginx >/dev/null

if [[ ! -e /etc/nginx/nginx.conf.fase2-original ]]; then
  cp -p /etc/nginx/nginx.conf /etc/nginx/nginx.conf.fase2-original
fi

cat >/etc/nginx/nginx.conf <<'EOF'
user nginx;
worker_processes auto;
error_log /var/log/nginx/error.log notice;
pid /run/nginx.pid;

include /usr/share/nginx/modules/*.conf;

events {
    worker_connections 1024;
}

http {
    log_format main '$remote_addr - $remote_user [$time_local] "$request" '
                    '$status $body_bytes_sent "$http_referer" "$http_user_agent"';
    access_log /var/log/nginx/access.log main;

    sendfile on;
    keepalive_timeout 65;
    server_tokens off;
    types_hash_max_size 4096;

    include /etc/nginx/mime.types;
    default_type application/octet-stream;

    include /etc/nginx/conf.d/*.conf;
}
EOF

cat >/etc/nginx/conf.d/rrhh.conf <<'EOF'
# Cualquier nombre distinto al de la intranet: se cierra la conexion sin responder
server {
    listen 80 default_server;
    server_name _;
    return 444;
}

# Virtual host de la intranet de Recursos Humanos
server {
    listen 80;
    server_name rrhh.mansiondeldisfraz.local;

    root /usr/share/nginx/rrhh;
    index index.html;
    charset utf-8;

    access_log /var/log/nginx/rrhh.access.log main;

    add_header X-Content-Type-Options "nosniff" always;
    add_header X-Frame-Options "DENY" always;

    location / {
        try_files $uri $uri/ =404;
    }
}
EOF

mkdir -p "$web_root"
cat >"$web_root/index.html" <<'EOF'
<!DOCTYPE html>
<html lang="es">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Intranet RRHH · Mansión del Disfraz</title>
<style>
  body { margin: 0; font-family: Arial, Helvetica, sans-serif; background: #f4f4f4; color: #141414; }
  header { background: #141414; color: #fff; padding: 24px 40px; border-bottom: 6px solid #fac800; }
  header h1 { margin: 0; font-size: 28px; }
  header p { margin: 6px 0 0; color: #ccc; }
  main { max-width: 960px; margin: 32px auto; padding: 0 20px; display: grid; gap: 20px; grid-template-columns: repeat(auto-fit, minmax(280px, 1fr)); }
  section { background: #fff; border-radius: 12px; padding: 20px 24px; box-shadow: 0 1px 3px rgba(0,0,0,.08); }
  h2 { margin-top: 0; font-size: 20px; border-left: 6px solid #fac800; padding-left: 10px; }
  li { margin: 6px 0; }
  footer { text-align: center; font-size: 13px; color: #666; padding: 24px; }
</style>
</head>
<body>
<header>
  <h1>Intranet de Recursos Humanos</h1>
  <p>Mansión del Disfraz · Portal interno para colaboradores</p>
</header>
<main>
  <section>
    <h2>Avisos</h2>
    <ul>
      <li>El pago de la segunda quincena de noviembre se acredita el día 30.</li>
      <li>Capacitación de atención al cliente para Ventas: viernes 20, 9:00.</li>
      <li>Gracias a todo el equipo por la temporada alta de octubre.</li>
    </ul>
  </section>
  <section>
    <h2>Trámites</h2>
    <ul>
      <li>Solicitud de vacaciones: con 15 días de anticipación a tu jefe inmediato.</li>
      <li>Constancia laboral: se entrega en 2 días hábiles.</li>
      <li>Actualización de datos personales: en la oficina de RRHH.</li>
    </ul>
  </section>
  <section>
    <h2>Contacto</h2>
    <ul>
      <li>Recursos Humanos: extensión 120</li>
      <li>Horario: lunes a viernes, 8:00 a 17:00</li>
    </ul>
  </section>
</main>
<footer>Servidor vm-intranet-rrhh · 10.10.0.101 · Acceso solo desde la red interna</footer>
</body>
</html>
EOF

chown -R root:root "$web_root"
chmod 0755 "$web_root"
chmod 0644 "$web_root/index.html"
restorecon -R "$web_root" /etc/nginx 2>/dev/null || true

nginx -t
systemctl enable nginx
systemctl restart nginx

code=$(curl -s -o /dev/null -w '%{http_code}' -H "Host: ${fqdn}" "http://${intranet_ip}/")
[[ "$code" == "200" ]]
printf 'REDES INTRANET OK %s %s HTTP %s\n' "$fqdn" "$intranet_ip" "$code"
code_otro=$(curl -s -o /dev/null -w '%{http_code}' "http://${intranet_ip}/" || true)
printf 'REDES INTRANET host desconocido HTTP %s (000 = Nginx cerro la conexion con 444)\n' "$code_otro"
