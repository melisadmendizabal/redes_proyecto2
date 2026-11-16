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
# Todas las VM se acceden por el EC2 Instance Connect Endpoint de TI (eice-ti). Desde la Fase 2
# (reglas de la persona 3 y hardening de la persona 5) ya no se salta por vm-ventas-1.
remoto () {   # $1 = titulo, $2 = instance-id, $3 = comando
  N=$((N + 1))
  echo
  echo "##### PRUEBA INTRANET $N: $1"
  ssh $SSH_OPTS -o "ProxyCommand=aws ec2-instance-connect open-tunnel --instance-id $2" ec2-user@"$2" "$3" </dev/null
}

[ -f "$KEYFILE" ] || { echo "Falta $KEYFILE en CloudShell"; exit 1; }

# IP publica de CloudShell (solo se muestra en la prueba desde Internet)
MYIP=$(curl -s https://checkip.amazonaws.com | tr -d '[:space:]')

V1_ID=$(attr vm-ventas-1 InstanceId)
V2_ID=$(attr vm-ventas-2 InstanceId)
TI_ID=$(attr vm-ti-1 InstanceId)
DC_ID=$(attr vm-datacenter-1 InstanceId)
VV_ID=$(attr vm-visitas-1 InstanceId)
IN_ID=$(attr vm-intranet-rrhh InstanceId)
IN_PRIV=$(attr vm-intranet-rrhh PrivateIpAddress)
IN_PUB=$(attr vm-intranet-rrhh PublicIpAddress)
existe "$IN_PRIV" || { echo "No hay vm-intranet-rrhh en ejecucion. Ejecuta: bash desplegar-intranet-fase2.sh"; exit 1; }
echo "vm-intranet-rrhh = $IN_PRIV (IP publica: $IN_PUB)"

echo "==> Esperando a que Nginx quede activo en la intranet"
for _ in $(seq 1 15); do
  ssh $SSH_OPTS -o "ProxyCommand=aws ec2-instance-connect open-tunnel --instance-id $IN_ID" ec2-user@"$IN_ID" \
    "systemctl is-active --quiet nginx" </dev/null 2>/dev/null && break
  sleep 20
done

CMD_SERVIDOR="hostname; hostname -I; sudo nginx -t; echo -n 'nginx: '; systemctl is-active nginx; sudo ss -tlnp | grep ':80 '; echo '--- /etc/nginx/conf.d/rrhh.conf'; cat /etc/nginx/conf.d/rrhh.conf"
CMD_NOMBRE="hostname; hostname -I; echo '--- DNS'; getent hosts $FQDN || echo '$FQDN no resuelve'; echo '--- HTTP'; curl -sS --max-time 5 -D - -o /tmp/rrhh.html http://$FQDN/ && grep -o '<title>.*</title>' /tmp/rrhh.html"
CMD_IP="hostname; hostname -I; echo '--- HTTP (nombre fijado a $IN_PRIV con --resolve)'; curl -sS --max-time 5 --resolve $FQDN:80:$IN_PRIV -D - -o /tmp/rrhh.html http://$FQDN/ && grep -o '<title>.*</title>' /tmp/rrhh.html"
CMD_HOST="hostname; hostname -I; echo '--- HTTP a la IP sin el nombre rrhh'; curl -sS --max-time 5 -o /dev/null -w 'HTTP %{http_code}\n' http://$IN_PRIV/ || echo 'RESULTADO: Nginx cerro la conexion (return 444) porque el Host no es $FQDN'"
CMD_BLOQUEO="hostname; hostname -I; echo '--- DNS'; getent hosts $FQDN || echo '$FQDN no resuelve'; echo '--- HTTP'; curl -sS --max-time 5 --resolve $FQDN:80:$IN_PRIV -o /dev/null -w 'HTTP %{http_code}\n' http://$FQDN/ || echo 'RESULTADO: sin respuesta, trafico bloqueado'"

remoto "vm-intranet-rrhh: Nginx activo, configuracion valida y virtual host" "$IN_ID" "$CMD_SERVIDOR"
remoto "vm-ventas-1 -> http://$FQDN (DEBE funcionar)" "$V1_ID" "$CMD_NOMBRE"
existe "$V2_ID" && remoto "vm-ventas-2 -> http://$FQDN (DEBE funcionar)" "$V2_ID" "$CMD_NOMBRE"
existe "$TI_ID" && remoto "vm-ti-1 -> http://$FQDN (DEBE funcionar)" "$TI_ID" "$CMD_NOMBRE"
existe "$DC_ID" && remoto "vm-datacenter-1 -> intranet por IP (DEBE funcionar)" "$DC_ID" "$CMD_IP"
remoto "vm-ventas-1 -> http://$IN_PRIV sin el nombre (DEBE FALLAR: Nginx solo atiende a $FQDN)" "$V1_ID" "$CMD_HOST"
existe "$VV_ID" && remoto "vm-visitas-1 -> intranet (DEBE FALLAR: la NACL y el SG bloquean Visitas)" "$VV_ID" "$CMD_BLOQUEO"

N=$((N + 1))
echo
echo "##### PRUEBA INTRANET $N: Internet (CloudShell) -> intranet (DEBE FALLAR)"
echo "Origen: CloudShell ($(uname -n)) con IP publica $MYIP"
echo "IP publica de vm-intranet-rrhh: $IN_PUB"
echo "--- DNS"
getent hosts "$FQDN" || echo "$FQDN no resuelve en Internet"
echo "--- HTTP"
curl -sS --max-time 5 -o /dev/null -w 'HTTP %{http_code}\n' "http://$IN_PRIV/" || echo "RESULTADO: sin respuesta, la intranet no es alcanzable desde Internet"
