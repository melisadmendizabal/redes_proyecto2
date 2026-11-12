#!/usr/bin/env bash
# =====================================================================
# Pruebas de la intranet de RRHH (Fase 2). Ejecutar en CloudShell.
# Toma screenshot de cada salida.
# Uso:   bash pruebas-intranet-fase2.sh | tee ~/evidencia-aws/pruebas-intranet-fase2.log
# =====================================================================
set -uo pipefail
export AWS_PAGER=""
export AWS_DEFAULT_REGION="${REGION:-us-east-1}"
PROJ="proyecto-redes"
FQDN="rrhh.mansiondeldisfraz.local"
KEYFILE="$HOME/proyecto-key.pem"
SSH_OPTS="-i $KEYFILE -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -o LogLevel=ERROR"

attr () {   # $1 = nombre de la instancia, $2 = atributo (PrivateIpAddress / PublicIpAddress)
  aws ec2 describe-instances \
    --filters "Name=tag:Name,Values=$1" "Name=tag:Project,Values=$PROJ" "Name=instance-state-name,Values=running" \
    --query "Reservations[0].Instances[0].$2" --output text
}

existe () { [ -n "$1" ] && [ "$1" != "None" ]; }

N=0
remoto () {   # $1 = titulo, $2 = IP para SSH, $3 = comando, $4 = "salto" si la VM es privada
  N=$((N + 1))
  echo
  echo "##### PRUEBA INTRANET $N: $1"
  if [ "${4:-}" = "salto" ]; then
    ssh $SSH_OPTS -o "ProxyCommand=ssh $SSH_OPTS -W %h:%p ec2-user@$V1_PUB" ec2-user@"$2" "$3"
  else
    ssh $SSH_OPTS ec2-user@"$2" "$3"
  fi
}

[ -f "$KEYFILE" ] || { echo "Falta $KEYFILE en CloudShell"; exit 1; }

# Si CloudShell cambio de IP publica, la autoriza en el SG de la Fase 1 para entrar al bastion (idempotente)
SG=$(aws ec2 describe-security-groups \
      --filters "Name=tag:Project,Values=$PROJ" "Name=group-name,Values=startup-sg" \
      --query "SecurityGroups[0].GroupId" --output text)
MYIP=$(curl -s https://checkip.amazonaws.com | tr -d '[:space:]')
aws ec2 authorize-security-group-ingress --group-id "$SG" --protocol tcp --port 22 \
  --cidr "${MYIP}/32" >/dev/null 2>&1 || true

V1_PUB=$(attr vm-ventas-1 PublicIpAddress)
V2_PUB=$(attr vm-ventas-2 PublicIpAddress)
TI_PRIV=$(attr vm-ti-1 PrivateIpAddress)
DC_PRIV=$(attr vm-datacenter-1 PrivateIpAddress)
VV_PUB=$(attr vm-visitas-1 PublicIpAddress)
IN_PRIV=$(attr vm-intranet-rrhh PrivateIpAddress)
IN_PUB=$(attr vm-intranet-rrhh PublicIpAddress)
existe "$IN_PRIV" || { echo "No hay vm-intranet-rrhh en ejecucion. Ejecuta: bash desplegar-intranet-fase2.sh"; exit 1; }
echo "vm-intranet-rrhh = $IN_PRIV (IP publica: $IN_PUB)"

echo "==> Esperando a que Nginx quede activo en la intranet"
for _ in $(seq 1 15); do
  ssh $SSH_OPTS -o "ProxyCommand=ssh $SSH_OPTS -W %h:%p ec2-user@$V1_PUB" ec2-user@"$IN_PRIV" \
    "systemctl is-active --quiet nginx" 2>/dev/null && break
  sleep 20
done

CMD_SERVIDOR="hostname; hostname -I; sudo nginx -t; echo -n 'nginx: '; systemctl is-active nginx; sudo ss -tlnp | grep ':80 '; echo '--- /etc/nginx/conf.d/rrhh.conf'; cat /etc/nginx/conf.d/rrhh.conf"
CMD_NOMBRE="hostname; hostname -I; echo '--- DNS'; getent hosts $FQDN || echo '$FQDN no resuelve'; echo '--- HTTP'; curl -sS --max-time 5 -D - -o /tmp/rrhh.html http://$FQDN/ && grep -o '<title>.*</title>' /tmp/rrhh.html"
CMD_IP="hostname; hostname -I; echo '--- HTTP (nombre fijado a $IN_PRIV con --resolve)'; curl -sS --max-time 5 --resolve $FQDN:80:$IN_PRIV -D - -o /tmp/rrhh.html http://$FQDN/ && grep -o '<title>.*</title>' /tmp/rrhh.html"
CMD_HOST="hostname; hostname -I; echo '--- HTTP a la IP sin el nombre rrhh'; curl -sS --max-time 5 -o /dev/null -w 'HTTP %{http_code}\n' http://$IN_PRIV/ || echo 'RESULTADO: Nginx cerro la conexion (return 444) porque el Host no es $FQDN'"
CMD_BLOQUEO="hostname; hostname -I; echo '--- DNS'; getent hosts $FQDN || echo '$FQDN no resuelve'; echo '--- HTTP'; curl -sS --max-time 5 --resolve $FQDN:80:$IN_PRIV -o /dev/null -w 'HTTP %{http_code}\n' http://$FQDN/ || echo 'RESULTADO: sin respuesta, trafico bloqueado'"

remoto "vm-intranet-rrhh: Nginx activo, configuracion valida y virtual host" "$IN_PRIV" "$CMD_SERVIDOR" salto
remoto "vm-ventas-1 -> http://$FQDN (DEBE funcionar)" "$V1_PUB" "$CMD_NOMBRE"
existe "$V2_PUB"  && remoto "vm-ventas-2 -> http://$FQDN (DEBE funcionar)" "$V2_PUB" "$CMD_NOMBRE"
existe "$TI_PRIV" && remoto "vm-ti-1 -> http://$FQDN (DEBE funcionar)" "$TI_PRIV" "$CMD_NOMBRE" salto
existe "$DC_PRIV" && remoto "vm-datacenter-1 -> intranet por IP (DEBE funcionar)" "$DC_PRIV" "$CMD_IP" salto
remoto "vm-ventas-1 -> http://$IN_PRIV sin el nombre (DEBE FALLAR: Nginx solo atiende a $FQDN)" "$V1_PUB" "$CMD_HOST"
existe "$VV_PUB"  && remoto "vm-visitas-1 -> intranet (DEBE FALLAR: la NACL y el SG bloquean Visitas)" "$VV_PUB" "$CMD_BLOQUEO"

N=$((N + 1))
echo
echo "##### PRUEBA INTRANET $N: Internet (CloudShell) -> intranet (DEBE FALLAR)"
echo "Origen: CloudShell ($(uname -n)) con IP publica $MYIP"
echo "IP publica de vm-intranet-rrhh: $IN_PUB"
echo "--- DNS"
getent hosts "$FQDN" || echo "$FQDN no resuelve en Internet"
echo "--- HTTP"
curl -sS --max-time 5 -o /dev/null -w 'HTTP %{http_code}\n' "http://$IN_PRIV/" || echo "RESULTADO: sin respuesta, la intranet no es alcanzable desde Internet"
