#!/usr/bin/env bash
# =====================================================================
# CC3067 Redes - Proyecto Final Fase 2 - Servidor web publico (DMZ)
# Ejecutar como root en vm-dmz-web (Amazon Linux 2023).
#
#  Sin argumentos  : desplegar-dmz-fase2.sh lo pasa como user data.
#                    Instala Nginx y publica el sitio de Ventas por HTTP.
#  --https DOMINIO : habilitar-https-fase2.sh lo ejecuta por SSH cuando el
#                    dominio publico ya apunta a la Elastic IP. Obtiene el
#                    certificado de Let's Encrypt (reto HTTP-01 por webroot),
#                    activa HTTPS y fuerza la redireccion HTTP -> HTTPS.
# =====================================================================
set -euo pipefail

modo=${1:-http}
dominio=${2:-}
web_root=/usr/share/nginx/web-publica
acme_root=/var/www/letsencrypt
vhost=/etc/nginx/conf.d/web-publica.conf
respaldo_http=/etc/nginx/web-publica.conf.fase-http

# La DMZ sale a Internet por el Internet Gateway solo cuando la Elastic IP ya
# esta asociada (desplegar-dmz-fase2.sh lo hace al arrancar): por eso se reintenta.
instalar_con_reintentos () {
  for intento in $(seq 1 40); do
    dnf install -y "$@" && return 0
    echo "REDES WEB dnf intento ${intento} fallido, reintentando"
    sleep 15
  done
  return 1
}

escribir_nginx_conf () {
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
}

escribir_sitio () {
  mkdir -p "$web_root" "$acme_root"
  cat >"$web_root/index.html" <<'EOF'
<!DOCTYPE html>
<html lang="es">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Mansión del Disfraz · Disfraces y accesorios</title>
<meta name="description" content="Venta y alquiler de disfraces, accesorios y maquillaje para fiestas, Halloween y eventos escolares.">
<style>
  * { box-sizing: border-box; }
  body { margin: 0; font-family: Arial, Helvetica, sans-serif; background: #f4f4f4; color: #141414; line-height: 1.5; }
  header { background: #141414; color: #fff; border-bottom: 6px solid #fac800; }
  .barra { max-width: 1040px; margin: 0 auto; padding: 16px 20px; display: flex; flex-wrap: wrap; align-items: center; justify-content: space-between; gap: 12px; }
  .marca { font-size: 22px; font-weight: bold; }
  .marca span { color: #fac800; }
  nav a { color: #fff; text-decoration: none; margin-left: 18px; font-size: 15px; }
  nav a:hover { color: #fac800; }
  .portada { max-width: 1040px; margin: 0 auto; padding: 48px 20px 56px; }
  .portada h1 { font-size: 38px; line-height: 1.15; margin: 0 0 12px; }
  .portada p { font-size: 18px; color: #ccc; max-width: 620px; margin: 0 0 24px; }
  .boton { display: inline-block; background: #fac800; color: #141414; font-weight: bold; padding: 12px 22px; border-radius: 8px; text-decoration: none; }
  main { max-width: 1040px; margin: 0 auto; padding: 8px 20px 40px; }
  h2 { font-size: 24px; margin: 36px 0 16px; border-left: 6px solid #fac800; padding-left: 10px; }
  .tarjetas { display: grid; gap: 18px; grid-template-columns: repeat(auto-fit, minmax(230px, 1fr)); }
  .tarjeta { background: #fff; border-radius: 12px; padding: 20px 22px; box-shadow: 0 1px 3px rgba(0,0,0,.08); }
  .tarjeta h3 { margin: 0 0 6px; font-size: 18px; }
  .tarjeta p { margin: 0; color: #444; font-size: 15px; }
  .precio { display: inline-block; margin-top: 10px; font-size: 13px; font-weight: bold; background: #fff4c2; padding: 3px 8px; border-radius: 6px; }
  li { margin: 6px 0; }
  footer { background: #141414; color: #aaa; text-align: center; font-size: 13px; padding: 24px 20px; }
  footer strong { color: #fff; }
  @media (max-width: 560px) { .portada h1 { font-size: 30px; } nav a { margin: 0 14px 0 0; } }
</style>
</head>
<body>
<header>
  <div class="barra">
    <div class="marca">Mansión del <span>Disfraz</span></div>
    <nav><a href="#catalogo">Catálogo</a><a href="#alquiler">Alquiler</a><a href="#visitanos">Visítanos</a></nav>
  </div>
  <div class="portada">
    <h1>Disfraces para cada fiesta, función y temporada</h1>
    <p>Venta y alquiler de disfraces para niños y adultos, accesorios y maquillaje artístico. Te ayudamos a armar el personaje completo.</p>
    <a class="boton" href="#catalogo">Ver catálogo</a>
  </div>
</header>
<main>
  <h2 id="catalogo">Catálogo</h2>
  <div class="tarjetas">
    <div class="tarjeta"><h3>Halloween y terror</h3><p>Vampiros, brujas, zombis y catrinas, con o sin maquillaje incluido.</p><span class="precio">Desde Q150</span></div>
    <div class="tarjeta"><h3>Infantiles</h3><p>Princesas, superhéroes, animales y personajes de cuentos, tallas 2 a 14.</p><span class="precio">Desde Q125</span></div>
    <div class="tarjeta"><h3>Época y tradición</h3><p>Trajes típicos, coloniales y de los años 20 u 80 para actos cívicos y obras de teatro.</p><span class="precio">Desde Q175</span></div>
    <div class="tarjeta"><h3>Accesorios y maquillaje</h3><p>Pelucas, máscaras, sombreros, capas, pintura facial y efectos especiales.</p><span class="precio">Desde Q25</span></div>
  </div>

  <h2 id="alquiler">Alquiler para eventos</h2>
  <div class="tarjetas">
    <div class="tarjeta"><h3>¿Cómo funciona?</h3><ol><li>Elige tu disfraz en tienda y prueba la talla.</li><li>Deja un depósito reembolsable.</li><li>Devuélvelo en 48 horas y recupera tu depósito.</li></ol></div>
    <div class="tarjeta"><h3>Grupos y colegios</h3><p>Paquetes para comparsas, desfiles y obras escolares. Reserva con una semana de anticipación para asegurar tallas.</p></div>
    <div class="tarjeta"><h3>Ajustes a la medida</h3><p>Nuestro taller hace arreglos sencillos de largo y cintura el mismo día.</p></div>
  </div>

  <h2 id="visitanos">Visítanos</h2>
  <div class="tarjetas">
    <div class="tarjeta"><h3>Horario</h3><ul><li>Lunes a viernes: 10:00 a 19:00</li><li>Sábado: 9:00 a 18:00</li><li>Domingo: 10:00 a 14:00</li></ul></div>
    <div class="tarjeta"><h3>Temporada alta</h3><p>En octubre y diciembre ampliamos el horario. Reserva tu alquiler con anticipación.</p></div>
    <div class="tarjeta"><h3>Pagos</h3><p>Efectivo y tarjetas de débito o crédito en tienda.</p></div>
  </div>
</main>
<footer><strong>Mansión del Disfraz</strong> · Sitio público del departamento de Ventas</footer>
</body>
</html>
EOF
  chown -R root:root "$web_root" "$acme_root"
  chmod 0755 "$web_root" "$acme_root"
  chmod 0644 "$web_root/index.html"
}

# Fase HTTP: el sitio se publica en el puerto 80 mientras se obtiene el certificado
conf_http () {
  cat <<'EOF'
# Fase HTTP del sitio publico (antes del certificado de Let's Encrypt)
server {
    listen 80 default_server;
    server_name _;

    root /usr/share/nginx/web-publica;
    index index.html;
    charset utf-8;

    access_log /var/log/nginx/web-publica.access.log main;

    add_header X-Content-Type-Options "nosniff" always;
    add_header X-Frame-Options "DENY" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;

    # Reto HTTP-01 de Let's Encrypt
    location ^~ /.well-known/acme-challenge/ {
        root /var/www/letsencrypt;
        default_type text/plain;
    }

    location / {
        try_files $uri $uri/ =404;
    }
}
EOF
}

# Configuracion final: HTTP solo redirige, HTTPS sirve el sitio con el certificado del dominio
conf_https () {
  cat <<EOF
# Puerto 80: todo se redirige a HTTPS con el nombre publico, salvo el reto de
# Let's Encrypt, que se sigue atendiendo por HTTP para renovar el certificado
server {
    listen 80 default_server;
    server_name _;

    access_log /var/log/nginx/web-publica.access.log main;

    location ^~ /.well-known/acme-challenge/ {
        root ${acme_root};
        default_type text/plain;
    }

    location / {
        return 301 https://${dominio}\$request_uri;
    }
}

# Puerto 443 sin el nombre del sitio (IP directa u otro dominio): se rechaza el handshake TLS
server {
    listen 443 ssl default_server;
    server_name _;
    ssl_reject_handshake on;
}

# Sitio publico de Ventas
server {
    listen 443 ssl;
    server_name ${dominio};

    ssl_certificate     /etc/letsencrypt/live/${dominio}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${dominio}/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305;
    ssl_prefer_server_ciphers off;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 1d;
    ssl_session_tickets off;

    root ${web_root};
    index index.html;
    charset utf-8;

    access_log /var/log/nginx/web-publica.access.log main;

    add_header Strict-Transport-Security "max-age=31536000" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-Frame-Options "DENY" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;
    add_header Content-Security-Policy "default-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; base-uri 'none'; form-action 'none'; frame-ancestors 'none'" always;

    location / {
        try_files \$uri \$uri/ =404;
    }
}
EOF
}

# Renovacion automatica: el paquete certbot de AL2023 trae certbot-renew.timer;
# el hook recarga Nginx cada vez que se renueva el certificado
configurar_renovacion () {
  mkdir -p /etc/letsencrypt/renewal-hooks/deploy
  cat >/etc/letsencrypt/renewal-hooks/deploy/recargar-nginx.sh <<'EOF'
#!/usr/bin/env bash
systemctl reload nginx
EOF
  chmod 0755 /etc/letsencrypt/renewal-hooks/deploy/recargar-nginx.sh
  systemctl enable --now certbot-renew.timer
}

modo_http () {
  instalar_con_reintentos nginx
  rpm -q nginx >/dev/null
  escribir_nginx_conf
  escribir_sitio
  conf_http >"$vhost"
  restorecon -R "$web_root" "$acme_root" /etc/nginx 2>/dev/null || true

  nginx -t
  systemctl enable nginx
  systemctl restart nginx

  code=$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1/)
  [[ "$code" == "200" ]]
  printf 'REDES WEB OK fase HTTP: http://127.0.0.1/ HTTP %s\n' "$code"
}

modo_https () {
  [[ -n "$dominio" ]] || { echo "Uso: $0 --https <dominio publico>"; exit 1; }
  [[ -f "$web_root/index.html" ]] || { echo "Falta la fase HTTP (user data de desplegar-dmz-fase2.sh)"; exit 1; }
  rpm -q certbot >/dev/null || dnf install -y certbot
  certbot --version

  if [[ -f "/etc/letsencrypt/live/${dominio}/fullchain.pem" ]]; then
    echo "REDES WEB ya existe un certificado para ${dominio}: se conserva"
  else
    # Primero contra el entorno de pruebas (staging), que no consume los limites de emision
    certbot certonly --webroot -w "$acme_root" -d "$dominio" --non-interactive \
      --agree-tos --register-unsafely-without-email --dry-run
    certbot certonly --webroot -w "$acme_root" -d "$dominio" --non-interactive \
      --agree-tos --register-unsafely-without-email
  fi

  # Se cambia la configuracion solo si nginx -t la acepta; si no, se restaura la fase HTTP
  [[ -e "$respaldo_http" ]] || cp -p "$vhost" "$respaldo_http"
  conf_https >"$vhost"
  if ! nginx -t; then
    cp -p "$respaldo_http" "$vhost"
    echo "REDES WEB configuracion HTTPS invalida: se restauro la fase HTTP"
    exit 1
  fi
  systemctl reload nginx
  configurar_renovacion

  # El reload es asincrono: se espera a que los procesos nuevos atiendan con la configuracion HTTPS
  for _ in $(seq 1 10); do
    code_http=$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1/ || true)
    [[ "$code_http" == "301" ]] && break
    sleep 1
  done
  [[ "$code_http" == "301" ]]
  curl -sS -o /dev/null -w 'REDES WEB OK http://127.0.0.1/ HTTP %{http_code} -> %{redirect_url}\n' http://127.0.0.1/
  code_https=$(curl -sS -o /dev/null -w '%{http_code}' --resolve "${dominio}:443:127.0.0.1" "https://${dominio}/")
  [[ "$code_https" == "200" ]]
  printf 'REDES WEB OK https://%s/ HTTP %s (certificado validado por curl)\n' "$dominio" "$code_https"
  certbot certificates --cert-name "$dominio" 2>/dev/null | grep -E 'Certificate Name|Domains|Expiry Date' || true
}

case "$modo" in
  http)    modo_http ;;
  --https) modo_https ;;
  *)       echo "Uso: $0 [--https <dominio publico>]"; exit 1 ;;
esac
