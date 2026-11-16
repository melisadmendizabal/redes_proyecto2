#!/usr/bin/env bash
# =====================================================================
# CC3067 Redes - Proyecto Final Fase 2 - HTTPS de la web publica (extra)
# Obtiene el certificado de Let's Encrypt para el dominio publico, activa
# HTTPS en vm-dmz-web y fuerza la redireccion HTTP -> HTTPS.
# Requisito: el dominio ya apunta a la Elastic IP de vm-dmz-web (DuckDNS).
#
# Ejecutar en AWS CloudShell despues de desplegar-dmz-fase2.sh.
# Uso:   bash habilitar-https-fase2.sh mansiondeldisfraz.duckdns.org
# =====================================================================
set -euo pipefail
export AWS_PAGER=""
export AWS_DEFAULT_REGION="${REGION:-us-east-1}"
PROJ="proyecto-redes"
DOMINIO="${1:-${DOMINIO:-}}"
KEYFILE="$HOME/proyecto-key.pem"
SSH_OPTS="-i $KEYFILE -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=15 -o LogLevel=ERROR"
DIR="$(cd "$(dirname "$0")" && pwd)"
OUT="$HOME/evidencia-aws"

[ -n "$DOMINIO" ] || { echo "Uso: bash $0 <dominio publico>"; exit 1; }
[ -f "$KEYFILE" ] || { echo "Falta $KEYFILE en CloudShell"; exit 1; }

ID=$(aws ec2 describe-instances --filters "Name=tag:Name,Values=vm-dmz-web" "Name=tag:Project,Values=$PROJ" \
     "Name=instance-state-name,Values=running" --query "Reservations[0].Instances[0].InstanceId" --output text)
[ "$ID" != "None" ] || { echo "No hay vm-dmz-web en ejecucion. Ejecuta primero: bash desplegar-dmz-fase2.sh"; exit 1; }
EIP=$(aws ec2 describe-instances --instance-ids "$ID" \
      --query "Reservations[0].Instances[0].PublicIpAddress" --output text)

# ---------- 1. El dominio debe resolver a la Elastic IP ----------
# Si apunta a otra IP, Let's Encrypt validaria contra otra maquina y la emision falla.
IP_DOMINIO=$(getent ahostsv4 "$DOMINIO" | awk 'NR==1 {print $1}' || true)
echo "==> $DOMINIO -> ${IP_DOMINIO:-no resuelve} | Elastic IP de vm-dmz-web: $EIP"
if [ "$IP_DOMINIO" != "$EIP" ]; then
  echo "El dominio todavia no apunta a $EIP. Actualiza la IP en https://www.duckdns.org y espera un minuto."
  exit 1
fi

# ---------- 2. El reto HTTP-01 entra por el puerto 80 desde Internet ----------
CODE=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "http://$DOMINIO/" || true)
echo "==> http://$DOMINIO responde HTTP $CODE desde Internet"
case "$CODE" in
  200|301) ;;
  *) echo "El puerto 80 no responde desde Internet; revisa dmz-web-sg, nacl-dmz y Nginx"; exit 1 ;;
esac

# ---------- 3. Certificado y configuracion HTTPS dentro de la VM ----------
# Se entra por el EC2 Instance Connect Endpoint de TI (eice-ti): el SSH no esta expuesto a Internet.
mkdir -p "$OUT"
TUNEL="ProxyCommand=aws ec2-instance-connect open-tunnel --instance-id $ID"
ssh $SSH_OPTS -o "$TUNEL" ec2-user@"$ID" "cat > /tmp/configurar-web-publica-fase2.sh" \
  < "$DIR/configurar-web-publica-fase2.sh"
ssh $SSH_OPTS -o "$TUNEL" ec2-user@"$ID" \
  "sudo bash /tmp/configurar-web-publica-fase2.sh --https $DOMINIO" 2>&1 | tee "$OUT/dmz-https.log"

# ---------- 4. Verificacion desde Internet (CloudShell) ----------
echo
echo "==> Verificacion desde CloudShell (Internet)" | tee -a "$OUT/dmz-https.log"
curl -sS -o /dev/null --max-time 10 \
  -w "http://$DOMINIO/  -> HTTP %{http_code}, redirige a %{redirect_url}\n" "http://$DOMINIO/" | tee -a "$OUT/dmz-https.log"
curl -sS -o /dev/null --max-time 10 \
  -w "https://$DOMINIO/ -> HTTP %{http_code}, verificacion del certificado %{ssl_verify_result} (0 = valido)\n" \
  "https://$DOMINIO/" | tee -a "$OUT/dmz-https.log"
echo | openssl s_client -connect "$DOMINIO:443" -servername "$DOMINIO" 2>/dev/null \
  | openssl x509 -noout -subject -issuer -dates | tee -a "$OUT/dmz-https.log"
echo "Registro guardado en $OUT/dmz-https.log"
echo "Siguiente paso: bash pruebas-dmz-fase2.sh $DOMINIO | tee $OUT/pruebas-dmz-fase2.log"
