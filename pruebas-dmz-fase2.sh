#!/usr/bin/env bash
# =====================================================================
# Pruebas de la DMZ y la web publica (Fase 2). Ejecutar en CloudShell
# despues de habilitar-https-fase2.sh. Toma screenshot de cada salida.
# Uso:   bash pruebas-dmz-fase2.sh mansiondeldisfraz.duckdns.org | tee ~/evidencia-aws/pruebas-dmz-fase2.log
#
# CloudShell hace de cliente de Internet. Todas las VM se acceden por el
# EC2 Instance Connect Endpoint de TI (eice-ti): este script no modifica
# ningun Security Group.
# =====================================================================
set -uo pipefail
exec 2>&1   # los errores (timeouts de curl, handshakes rechazados) tambien quedan en el registro
export AWS_PAGER=""
export AWS_DEFAULT_REGION="${REGION:-us-east-1}"
PROJ="proyecto-redes"
DOMINIO="${1:-${DOMINIO:-mansiondeldisfraz.duckdns.org}}"
FQDN_INTRANET="rrhh.mansiondeldisfraz.local"
DNS_INTERNO="10.10.1.4"
KEYFILE="$HOME/proyecto-key.pem"
SSH_OPTS="-i $KEYFILE -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=15 -o LogLevel=ERROR"

attr () {   # $1 = nombre de la instancia, $2 = atributo (InstanceId / PrivateIpAddress / PublicIpAddress)
  aws ec2 describe-instances \
    --filters "Name=tag:Name,Values=$1" "Name=tag:Project,Values=$PROJ" "Name=instance-state-name,Values=running" \
    --query "Reservations[0].Instances[0].$2" --output text
}
existe () { [ -n "$1" ] && [ "$1" != "None" ]; }

N=0
titulo () { N=$((N + 1)); echo; echo "##### PRUEBA DMZ $N: $1"; }
remoto () {   # $1 = titulo, $2 = instance-id, $3 = comando
  titulo "$1"
  ssh $SSH_OPTS -o "ProxyCommand=aws ec2-instance-connect open-tunnel --instance-id $2" ec2-user@"$2" "$3"
}

# Comandos remotos. Cada uno termina en lineas "RESULTADO ..." faciles de leer en la captura.
c_ping_tcp () {   # $1 = IP destino, resto = puertos TCP
  local ip=$1; shift
  local c="hostname; hostname -I; echo '--- ICMP hacia $ip'; ping -c 3 -W 2 $ip && echo 'RESULTADO ICMP: responde' || echo 'RESULTADO ICMP: sin respuesta (bloqueado)'"
  for p in "$@"; do
    c="$c; timeout 4 bash -c '</dev/tcp/$ip/$p' 2>/dev/null && echo 'RESULTADO TCP $p: conexion abierta' || echo 'RESULTADO TCP $p: sin conexion (bloqueado)'"
  done
  echo "$c"
}
c_web_privada () {   # $1 = IP privada de la DMZ: HTTP por IP y HTTPS con el nombre publico fijado a esa IP
  echo "hostname; hostname -I; echo '--- HTTP hacia $1'; curl -sS --max-time 5 -o /dev/null -w 'HTTP %{http_code} -> %{redirect_url}\n' http://$1/ && echo 'RESULTADO HTTP: responde' || echo 'RESULTADO HTTP: sin respuesta (bloqueado)'; echo '--- HTTPS hacia $1 como $DOMINIO'; curl -sS --max-time 5 --resolve $DOMINIO:443:$1 -o /dev/null -w 'HTTPS %{http_code}\n' https://$DOMINIO/ && echo 'RESULTADO HTTPS: responde' || echo 'RESULTADO HTTPS: sin respuesta (bloqueado)'"
}
c_web_publica () {   # la web por su dominio publico, saliendo a Internet
  echo "hostname; hostname -I; echo '--- DNS publico'; getent hosts $DOMINIO || echo '$DOMINIO no resuelve'; echo '--- HTTPS'; curl -sS --max-time 8 -o /dev/null -w 'HTTPS %{http_code}\n' https://$DOMINIO/ && echo 'RESULTADO: web publica accesible por su dominio' || echo 'RESULTADO: sin respuesta'"
}
c_intranet () {   # $1 = IP de la intranet
  echo "hostname; hostname -I; echo '--- HTTP hacia la intranet $1'; curl -sS --max-time 5 -H 'Host: $FQDN_INTRANET' -o /dev/null -w 'HTTP %{http_code}\n' http://$1/ && echo 'RESULTADO: intranet accesible' || echo 'RESULTADO: sin respuesta (bloqueado)'"
}
c_dns_interno () {
  echo "hostname; hostname -I; echo '--- Nombre interno'; getent hosts $FQDN_INTRANET || echo 'RESULTADO DNS: $FQDN_INTRANET no resuelve desde la DMZ'; echo '--- TCP 53 hacia $DNS_INTERNO'; timeout 4 bash -c '</dev/tcp/$DNS_INTERNO/53' 2>/dev/null && echo 'RESULTADO TCP 53: conexion abierta' || echo 'RESULTADO TCP 53: sin conexion (bloqueado)'"
}
c_internet () {
  echo "hostname; hostname -I; echo '--- HTTPS saliente (actualizaciones y certificados)'; curl -sS --max-time 8 https://checkip.amazonaws.com && echo 'RESULTADO HTTPS saliente: permitido (la IP mostrada es la Elastic IP)' || echo 'RESULTADO HTTPS saliente: bloqueado'; echo '--- HTTP saliente (puerto 80)'; curl -sS --max-time 5 -o /dev/null -w 'HTTP %{http_code}\n' http://example.com/ && echo 'RESULTADO HTTP saliente: permitido' || echo 'RESULTADO HTTP saliente: bloqueado (dmz-web-sg solo deja salir 443)'"
}
c_servidor () {
  echo "hostname; hostname -I; echo '--- nginx -t'; sudo nginx -t 2>&1; echo '--- Servicios'; systemctl is-active nginx; systemctl list-timers --all --no-pager | grep -i certbot || true; echo '--- Puertos en escucha (ss -tulpn)'; sudo ss -tulpn; echo '--- Certificado'; sudo openssl x509 -in /etc/letsencrypt/live/$DOMINIO/cert.pem -noout -subject -issuer -dates 2>/dev/null || echo 'Sin certificado todavia'"
}

[ -f "$KEYFILE" ] || { echo "Falta $KEYFILE en CloudShell"; exit 1; }

VPC=$(aws ec2 describe-vpcs --filters "Name=tag:Project,Values=$PROJ" --query "Vpcs[0].VpcId" --output text)
DMZ_ID=$(attr vm-dmz-web InstanceId);        DMZ_PRIV=$(attr vm-dmz-web PrivateIpAddress); EIP=$(attr vm-dmz-web PublicIpAddress)
TI_ID=$(attr vm-ti-1 InstanceId);            TI_PRIV=$(attr vm-ti-1 PrivateIpAddress)
V1_ID=$(attr vm-ventas-1 InstanceId);        V1_PRIV=$(attr vm-ventas-1 PrivateIpAddress)
DC_ID=$(attr vm-datacenter-1 InstanceId);    DC_PRIV=$(attr vm-datacenter-1 PrivateIpAddress)
VV_ID=$(attr vm-visitas-1 InstanceId)
IN_PRIV=$(attr vm-intranet-rrhh PrivateIpAddress)
existe "$DMZ_ID" || { echo "No hay vm-dmz-web en ejecucion. Ejecuta: bash desplegar-dmz-fase2.sh"; exit 1; }

echo "Dominio publico  = $DOMINIO"
echo "vm-dmz-web       = $DMZ_PRIV ($DMZ_ID) | Elastic IP $EIP"
echo "vm-ti-1          = $TI_PRIV"
echo "vm-ventas-1      = $V1_PRIV"
echo "vm-datacenter-1  = $DC_PRIV"
echo "vm-intranet-rrhh = $IN_PRIV"

# ---------- 0. Configuracion aplicada ----------
titulo "Configuracion de la DMZ (subred, rutas, NACL y Security Group)"
aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC" "Name=tag:Name,Values=snet-dmz" \
  --query "Subnets[].[Tags[?Key=='Name']|[0].Value,SubnetId,CidrBlock,AvailabilityZone,MapPublicIpOnLaunch]" --output table
aws ec2 describe-route-tables --filters "Name=vpc-id,Values=$VPC" "Name=tag:Name,Values=rt-dmz" \
  --query "RouteTables[0].Routes[].[DestinationCidrBlock,GatewayId,State]" --output table
aws ec2 describe-network-acls --filters "Name=vpc-id,Values=$VPC" "Name=tag:Name,Values=nacl-dmz" \
  --query "sort_by(NetworkAcls[0].Entries,&RuleNumber)[].[Egress,RuleNumber,RuleAction,Protocol,CidrBlock,PortRange.From,PortRange.To]" --output table
aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$VPC" "Name=group-name,Values=dmz-web-sg" \
  --query "SecurityGroups[0].IpPermissions[].[IpProtocol,FromPort,ToPort,IpRanges[0].CidrIp,IpRanges[0].Description]" --output table
aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$VPC" "Name=group-name,Values=dmz-web-sg" \
  --query "SecurityGroups[0].IpPermissionsEgress[].[IpProtocol,FromPort,ToPort,IpRanges[0].CidrIp,IpRanges[0].Description]" --output table

# ---------- A. Servidor web ----------
remoto "vm-dmz-web: Nginx, puertos en escucha y certificado" "$DMZ_ID" "$(c_servidor)"

# ---------- B. Internet (CloudShell) -> web publica ----------
titulo "Internet -> DNS publico de $DOMINIO (DEBE resolver a la Elastic IP)"
IP_DOMINIO=$(getent ahostsv4 "$DOMINIO" | awk 'NR==1 {print $1}')
echo "$DOMINIO -> ${IP_DOMINIO:-no resuelve} | Elastic IP = $EIP"
[ "$IP_DOMINIO" = "$EIP" ] && echo "RESULTADO DNS: coincide" || echo "RESULTADO DNS: NO coincide"

titulo "Internet -> http://$DOMINIO (DEBE redirigir a HTTPS)"
curl -sS -I --max-time 10 "http://$DOMINIO/" | grep -iE '^(HTTP|location)'
curl -sS -o /dev/null --max-time 10 -w 'RESULTADO: HTTP %{http_code} -> %{redirect_url}\n' "http://$DOMINIO/"

titulo "Internet -> https://$DOMINIO (DEBE funcionar con certificado valido)"
curl -sS -v -o /dev/null --max-time 10 "https://$DOMINIO/" 2>&1 | grep -E 'SSL connection|subject:|issuer:|expire date|^< HTTP'
curl -sS -I --max-time 10 "https://$DOMINIO/" | grep -iE '^(server|strict-transport-security|content-security-policy|x-frame-options|x-content-type-options):'
curl -sS -o /dev/null --max-time 10 -w 'RESULTADO: HTTPS %{http_code}, verificacion del certificado %{ssl_verify_result} (0 = valido)\n' "https://$DOMINIO/"

titulo "Internet -> IP directa $EIP (HTTP redirige al dominio, HTTPS sin nombre se rechaza)"
curl -sS -o /dev/null --max-time 10 -w "http://$EIP/  -> HTTP %{http_code} -> %{redirect_url}\n" "http://$EIP/"
curl -sS -k -o /dev/null --max-time 10 "https://$EIP/" && echo "RESULTADO HTTPS por IP: respondio" \
  || echo "RESULTADO HTTPS por IP: handshake rechazado (ssl_reject_handshake)"

titulo "Internet -> $EIP puerto 22 (SSH NO expuesto, DEBE FALLAR)"
timeout 5 bash -c "</dev/tcp/$EIP/22" 2>/dev/null && echo "RESULTADO TCP 22: conexion abierta" \
  || echo "RESULTADO TCP 22: sin conexion (bloqueado)"

# ---------- C. Red interna -> DMZ ----------
existe "$TI_ID" && remoto "vm-ti-1 -> DMZ $DMZ_PRIV (TI administra la DMZ, DEBE funcionar)" "$TI_ID" "$(c_ping_tcp "$DMZ_PRIV" 22 80 443)"
existe "$TI_ID" && remoto "vm-ti-1 -> web de la DMZ por IP privada (DEBE funcionar)" "$TI_ID" "$(c_web_privada "$DMZ_PRIV")"
existe "$V1_ID" && remoto "vm-ventas-1 -> DMZ $DMZ_PRIV por red privada (DEBE FALLAR)" "$V1_ID" "$(c_ping_tcp "$DMZ_PRIV" 22 80 443)"
existe "$V1_ID" && remoto "vm-ventas-1 -> https://$DOMINIO por Internet (DEBE funcionar)" "$V1_ID" "$(c_web_publica)"
existe "$VV_ID" && remoto "vm-visitas-1 -> DMZ $DMZ_PRIV por red privada (DEBE FALLAR)" "$VV_ID" "$(c_ping_tcp "$DMZ_PRIV" 22 80 443)"
existe "$VV_ID" && remoto "vm-visitas-1 -> https://$DOMINIO por Internet (DEBE funcionar)" "$VV_ID" "$(c_web_publica)"
existe "$DC_ID" && remoto "vm-datacenter-1 -> DMZ $DMZ_PRIV por red privada (DEBE FALLAR)" "$DC_ID" "$(c_ping_tcp "$DMZ_PRIV" 22 80 443)"

# ---------- D. DMZ -> red interna (DEBE FALLAR) y DMZ -> Internet ----------
existe "$TI_PRIV" && remoto "vm-dmz-web -> vm-ti-1 $TI_PRIV (DEBE FALLAR)" "$DMZ_ID" "$(c_ping_tcp "$TI_PRIV" 22)"
existe "$V1_PRIV" && remoto "vm-dmz-web -> vm-ventas-1 $V1_PRIV (DEBE FALLAR)" "$DMZ_ID" "$(c_ping_tcp "$V1_PRIV" 22)"
existe "$DC_PRIV" && remoto "vm-dmz-web -> vm-datacenter-1 $DC_PRIV (DEBE FALLAR)" "$DMZ_ID" "$(c_ping_tcp "$DC_PRIV" 22)"
existe "$IN_PRIV" && remoto "vm-dmz-web -> intranet $IN_PRIV (DEBE FALLAR)" "$DMZ_ID" "$(c_intranet "$IN_PRIV")"
remoto "vm-dmz-web -> DNS interno $DNS_INTERNO (DEBE FALLAR)" "$DMZ_ID" "$(c_dns_interno)"
remoto "vm-dmz-web -> Internet (solo HTTPS saliente)" "$DMZ_ID" "$(c_internet)"
