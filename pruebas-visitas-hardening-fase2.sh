#!/usr/bin/env bash

# Uso:   bash pruebas-visitas-hardening-fase2.sh | tee ~/evidencia-aws/pruebas-visitas-hardening-fase2.log
#        SOLO_VISITAS=1 bash pruebas-visitas-hardening-fase2.sh | tee ~/evidencia-aws/pruebas-visitas-nacl.log
#        (la segunda forma corre solo la parte A; usarla despues de reglas-visitas-fase2.sh y
#         ANTES del hardening, para capturar el bloqueo que hace la nube por si sola)
#
# Cada prueba compara el resultado con el esperado y marca ">> OK" o ">> FALLO".
# Al final se imprime el total. Todas las VM se acceden por eice-ti; la VM del DNS,
# saltando por vm-ti-1. Este script no modifica nada en AWS ni en las VM.
# =====================================================================
set -uo pipefail
exec 2>&1
export AWS_PAGER=""
export AWS_DEFAULT_REGION="${REGION:-us-east-1}"
PROJ="proyecto-redes"
DOMINIO="${1:-${DOMINIO:-mansiondeldisfraz.duckdns.org}}"
FQDN="rrhh.mansiondeldisfraz.local"
DNS_INTERNO="10.10.1.4"
DIR="$(cd "$(dirname "$0")" && pwd)"
HARD="$DIR/hardening-fase2.sh"
KEYFILE="$HOME/proyecto-key.pem"
SSH_OPTS="-i $KEYFILE -o IdentitiesOnly=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=20 -o LogLevel=ERROR"
SSH_INTERNO="-o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5"

attr () {
  aws ec2 describe-instances \
    --filters "Name=tag:Name,Values=$1" "Name=tag:Project,Values=$PROJ" "Name=instance-state-name,Values=running" \
    --query "Reservations[0].Instances[0].$2" --output text
}
existe () { [ -n "$1" ] && [ "$1" != "None" ]; }
proxy_eice () { echo "aws ec2-instance-connect open-tunnel --instance-id $1"; }
en_vm () {   # $1 = instance-id o IP (VM del DNS, por vm-ti-1), resto = comando remoto
  local destino=$1 proxy opts=$SSH_OPTS; shift
  if [[ "$destino" == i-* ]]; then proxy=$(proxy_eice "$destino")
  else
    proxy="ssh $SSH_OPTS -o 'ProxyCommand=$(proxy_eice "$TI_ID")' -W %h:%p ec2-user@$TI_ID"
    if [ "$DNS_EIC" = 1 ]; then   # VM sin key pair: EC2 Instance Connect le deposita una llave temporal (60 s)
      aws ec2-instance-connect send-ssh-public-key --instance-id "$DNS_ID" --instance-os-user ec2-user \
        --ssh-public-key "file://$LLAVE_TMP.pub" </dev/null >/dev/null || return 1
      opts=${SSH_OPTS/-i $KEYFILE/-i $LLAVE_TMP}
    fi
  fi
  ssh $opts -o "ProxyCommand=$proxy" "ec2-user@$destino" "$@"
}

#  Evaluacion automatica 
N=0; OK=0; FALLOS=0; LISTA_FALLOS=""
evaluar () {   # $1 = esperado (PERMITIDO/BLOQUEADO/CUMPLE), $2 = salida con lineas "ESTADO=..."
  local estados
  estados=$(grep -o 'ESTADO=[A-Z_]*' <<<"$2" | sort -u | tr '\n' ' ')
  if [ -z "$estados" ]; then
    echo ">> FALLO: sin resultado (no se pudo ejecutar la prueba)"
  elif [ "$estados" = "ESTADO=$1 " ]; then
    echo ">> OK (esperado $1)"; OK=$((OK + 1)); return
  else
    echo ">> FALLO: esperado $1, obtenido ${estados}"
  fi
  FALLOS=$((FALLOS + 1)); LISTA_FALLOS="$LISTA_FALLOS $N"
}
remota () {   # $1 = titulo, $2 = esperado, $3 = instance-id/IP de origen, $4 = comando remoto
  N=$((N + 1)); echo; echo "##### PRUEBA P5-$N: $1"
  local salida
  salida=$(en_vm "$3" "echo \"origen: \$(hostname) \$(hostname -I)\"; $4" </dev/null 2>&1)
  echo "$salida"; evaluar "$2" "$salida"
}
local_ () {   # $1 = titulo, $2 = esperado, $3 = comando local (CloudShell = Internet)
  N=$((N + 1)); echo; echo "##### PRUEBA P5-$N: $1"
  local salida
  salida=$(bash -c "$3" 2>&1)
  echo "$salida"; evaluar "$2" "$salida"
}

# Comandos (cada uno imprime ESTADO=PERMITIDO o ESTADO=BLOQUEADO) 
c_ping () { echo "echo '--- ping $1'; if ping -c 2 -W 2 $1; then echo 'RESULTADO ICMP: responde ESTADO=PERMITIDO'; else echo 'RESULTADO ICMP: sin respuesta ESTADO=BLOQUEADO'; fi"; }
c_tcp () {  # $1 = IP, resto = puertos
  local ip=$1 c=""; shift
  for p in "$@"; do
    c="$c echo '--- TCP $ip:$p'; if timeout 4 bash -c '</dev/tcp/$ip/$p' 2>/dev/null; then echo 'RESULTADO TCP $p: conexion abierta ESTADO=PERMITIDO'; else echo 'RESULTADO TCP $p: sin conexion ESTADO=BLOQUEADO'; fi;"
  done
  echo "$c"
}
c_ping_tcp () { echo "$(c_ping "$1"); $(c_tcp "$@")"; }
c_http () {  # $1 = URL, $2 = codigo esperado, $3 = opciones extra de curl
  echo "echo '--- curl $1'; c=\$(curl -sS --max-time 8 ${3:-} -o /dev/null -w '%{http_code}' $1); echo \"HTTP \$c\"; if [ \"\$c\" = '$2' ]; then echo 'RESULTADO: responde $2 ESTADO=PERMITIDO'; else echo 'RESULTADO: sin la respuesta esperada ESTADO=BLOQUEADO'; fi"
}
c_dns_interno () {  # consulta directa al DNS interno
  echo "echo '--- dig @$DNS_INTERNO rrhh'; r=\$(dig @$DNS_INTERNO $FQDN A +short +time=2 +tries=1 2>&1); echo \"respuesta: \$r\"; if echo \"\$r\" | grep -qx '10.10.0.101'; then echo 'ESTADO=PERMITIDO'; else echo 'ESTADO=BLOQUEADO'; fi"
}
c_ssh_password () {  # intenta entrar SOLO con contrasena: debe rechazarse
  echo "echo '--- ssh con contrasena hacia $1'; s=\$(ssh $SSH_INTERNO -o PubkeyAuthentication=no -o PreferredAuthentications=password,keyboard-interactive ec2-user@$1 true 2>&1); echo \"\$s\"; if echo \"\$s\" | grep -q 'Permission denied (publickey)'; then echo 'RESULTADO: el servidor solo ofrece llave publica ESTADO=BLOQUEADO'; else echo 'ESTADO=PERMITIDO'; fi"
}
c_tcp_local () { echo "if timeout 5 bash -c '</dev/tcp/$1/$2' 2>/dev/null; then echo 'RESULTADO TCP $2 en $1: abierto ESTADO=PERMITIDO'; else echo 'RESULTADO TCP $2 en $1: sin conexion ESTADO=BLOQUEADO'; fi"; }

[ -f "$KEYFILE" ] || { echo "Falta $KEYFILE en CloudShell"; exit 1; }
V1_ID=$(attr vm-ventas-1 InstanceId);     V1_PRIV=$(attr vm-ventas-1 PrivateIpAddress);  V1_PUB=$(attr vm-ventas-1 PublicIpAddress)
V2_PRIV=$(attr vm-ventas-2 PrivateIpAddress);  V2_PUB=$(attr vm-ventas-2 PublicIpAddress)
TI_ID=$(attr vm-ti-1 InstanceId);         TI_PRIV=$(attr vm-ti-1 PrivateIpAddress)
VV_ID=$(attr vm-visitas-1 InstanceId);    VV_PRIV=$(attr vm-visitas-1 PrivateIpAddress); VV_PUB=$(attr vm-visitas-1 PublicIpAddress)
DC_ID=$(attr vm-datacenter-1 InstanceId); DC_PRIV=$(attr vm-datacenter-1 PrivateIpAddress)
IN_PRIV=$(attr vm-intranet-rrhh PrivateIpAddress)
DMZ_ID=$(attr vm-dmz-web InstanceId);     DMZ_PRIV=$(attr vm-dmz-web PrivateIpAddress)
VPC=$(aws ec2 describe-vpcs --filters "Name=tag:Project,Values=$PROJ" --query "Vpcs[0].VpcId" --output text)
read -r DNS_ID DNS_IP DNS_KEY < <(aws ec2 describe-instances --filters "Name=tag:Name,Values=vm-dns-fase2" "Name=instance-state-name,Values=running" \
         --query "Reservations[0].Instances[0].[InstanceId,PrivateIpAddress,KeyName]" --output text)
DNS_EIC=0; LLAVE_TMP=""
if existe "$DNS_ID" && [ "$DNS_KEY" != "proyecto-key" ]; then   # vm-dns-fase2 se creo sin key pair
  DNS_EIC=1
  LLAVE_TMP="$(mktemp -d)/dns-eic"
  ssh-keygen -q -t ed25519 -N '' -f "$LLAVE_TMP"
  trap 'rm -rf "$(dirname "$LLAVE_TMP")"' EXIT
fi
existe "$TI_ID" && existe "$VV_ID" || { echo "Faltan vm-ti-1 o vm-visitas-1 en ejecucion"; exit 1; }

echo "vm-ventas-1 $V1_PRIV ($V1_PUB) | vm-ventas-2 $V2_PRIV | vm-ti-1 $TI_PRIV | vm-visitas-1 $VV_PRIV ($VV_PUB)"
echo "vm-datacenter-1 $DC_PRIV | vm-intranet-rrhh $IN_PRIV | vm-dmz-web $DMZ_PRIV | vm-dns-fase2 $DNS_IP | dominio $DOMINIO"

# 0. Configuracion aplicada (sin veredicto: son las tablas para la captura) 
echo; echo "##### CONFIGURACION: visitas-sg, nacl-visitas y Security Groups endurecidos"
aws ec2 describe-instances --instance-ids "$VV_ID" \
  --query "Reservations[0].Instances[0].[Tags[?Key=='Name']|[0].Value,SubnetId,SecurityGroups[0].GroupName]" --output table
for G in visitas-sg startup-sg intranet-rrhh-sg; do
  echo "--- $G (entrada)"
  aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$VPC" "Name=group-name,Values=$G" \
    --query "SecurityGroups[0].IpPermissions[].[IpProtocol,FromPort,ToPort,join(', ',IpRanges[].CidrIp)]" --output table
done
echo "--- nacl-visitas (Egress False = entrada, True = salida)"
aws ec2 describe-network-acls --filters "Name=vpc-id,Values=$VPC" "Name=tag:Name,Values=nacl-visitas" \
  --query "sort_by(NetworkAcls[0].Entries,&RuleNumber)[].[Egress,RuleNumber,RuleAction,Protocol,CidrBlock,PortRange.From,PortRange.To,IcmpTypeCode.Type]" --output table

# A. Visitas: solo Internet 
remota "vm-visitas-1 -> Internet por HTTPS (DEBE funcionar)" PERMITIDO "$VV_ID" \
  "curl -sS --max-time 8 https://checkip.amazonaws.com; $(c_http https://checkip.amazonaws.com 200)"
remota "vm-visitas-1 -> Internet por HTTP 80 (DEBE funcionar)" PERMITIDO "$VV_ID" "$(c_http http://example.com/ 200)"
remota "vm-visitas-1 -> DNS publico (DEBE resolver)" PERMITIDO "$VV_ID" \
  "if getent hosts amazon.com; then echo 'ESTADO=PERMITIDO'; else echo 'ESTADO=BLOQUEADO'; fi"
remota "vm-visitas-1 -> web publica https://$DOMINIO (DEBE funcionar)" PERMITIDO "$VV_ID" "$(c_http "https://$DOMINIO/" 200)"
existe "$V1_PRIV" && remota "vm-visitas-1 -> vm-ventas-1 $V1_PRIV (DEBE FALLAR)" BLOQUEADO "$VV_ID" "$(c_ping_tcp "$V1_PRIV" 22)"
remota "vm-visitas-1 -> vm-ti-1 $TI_PRIV (DEBE FALLAR)" BLOQUEADO "$VV_ID" "$(c_ping_tcp "$TI_PRIV" 22)"
existe "$DC_PRIV" && remota "vm-visitas-1 -> vm-datacenter-1 $DC_PRIV (DEBE FALLAR)" BLOQUEADO "$VV_ID" "$(c_ping_tcp "$DC_PRIV" 22)"
existe "$IN_PRIV" && remota "vm-visitas-1 -> intranet $IN_PRIV (DEBE FALLAR)" BLOQUEADO "$VV_ID" \
  "getent hosts $FQDN || echo '$FQDN no resuelve'; $(c_tcp "$IN_PRIV" 80)"
existe "$DMZ_PRIV" && remota "vm-visitas-1 -> DMZ por IP privada $DMZ_PRIV (DEBE FALLAR)" BLOQUEADO "$VV_ID" "$(c_tcp "$DMZ_PRIV" 22 80 443)"
remota "vm-visitas-1 -> DNS interno $DNS_INTERNO (DEBE FALLAR)" BLOQUEADO "$VV_ID" "$(c_dns_interno); $(c_tcp "$DNS_INTERNO" 53)"
remota "vm-ti-1 -> vm-visitas-1 $VV_PRIV (TI llega a todo, DEBE funcionar)" PERMITIDO "$TI_ID" "$(c_ping_tcp "$VV_PRIV" 22)"
existe "$V1_ID" && remota "vm-ventas-1 -> vm-visitas-1 $VV_PRIV (DEBE FALLAR)" BLOQUEADO "$V1_ID" "$(c_ping_tcp "$VV_PRIV" 22)"
existe "$VV_PUB" && local_ "Internet (CloudShell) -> vm-visitas-1 $VV_PUB puerto 22 (DEBE FALLAR)" BLOQUEADO "$(c_tcp_local "$VV_PUB" 22)"

if [ "${SOLO_VISITAS:-0}" != 1 ]; then   # SOLO_VISITAS=1: solo la parte A (antes del hardening)
# ---------- B. Hardening: verificacion dentro de cada VM 
verificar_vm () {   # $1 = nombre, $2 = rol, $3 = instance-id o IP
  N=$((N + 1)); echo; echo "##### PRUEBA P5-$N: hardening de $1 (rol $2): SSH, firewall del SO, puertos y sysctl"
  local salida
  salida=$(tr -d '\r' <"$HARD" | en_vm "$3" "sudo bash -s -- --verificar $2" 2>&1)
  echo "$salida"; evaluar CUMPLE "$salida"
}
for par in vm-ventas-1:ventas vm-ventas-2:ventas vm-ti-1:ti vm-datacenter-1:datacenter vm-visitas-1:visitas \
           vm-intranet-rrhh:intranet vm-dmz-web:dmz; do
  id=$(attr "${par%%:*}" InstanceId)
  existe "$id" && verificar_vm "${par%%:*}" "${par##*:}" "$id"
done
existe "$DNS_IP" && verificar_vm vm-dns-fase2 dns "$DNS_IP"

# ---------- C. Puertos cerrados por el hardening 
existe "$V1_PUB" && local_ "Internet (CloudShell) -> vm-ventas-1 $V1_PUB puerto 22 (DEBE FALLAR)" BLOQUEADO "$(c_tcp_local "$V1_PUB" 22)"
existe "$V2_PUB" && local_ "Internet (CloudShell) -> vm-ventas-2 $V2_PUB puerto 22 (DEBE FALLAR)" BLOQUEADO "$(c_tcp_local "$V2_PUB" 22)"
existe "$V1_ID" && remota "vm-ventas-1 -> SSH de ventas-2, Data Center e intranet (solo TI administra, DEBE FALLAR)" BLOQUEADO "$V1_ID" \
  "$(existe "$V2_PRIV" && c_tcp "$V2_PRIV" 22) $(existe "$DC_PRIV" && c_tcp "$DC_PRIV" 22) $(existe "$IN_PRIV" && c_tcp "$IN_PRIV" 22)"
existe "$V1_PRIV" && remota "vm-ti-1 -> vm-ventas-1 con contrasena (solo llave publica, DEBE FALLAR)" BLOQUEADO "$TI_ID" "$(c_ssh_password "$V1_PRIV")"
if existe "$V1_ID" && existe "$IN_PRIV"; then
  N=$((N + 1)); echo; echo "##### PRUEBA P5-$N: salto SSH por vm-ventas-1 hacia la intranet (Ventas ya no es bastion, DEBE FALLAR)"
  salida=$(ssh $SSH_OPTS -o "ProxyCommand=ssh $SSH_OPTS -o 'ProxyCommand=$(proxy_eice "$V1_ID")' -W %h:%p ec2-user@$V1_ID" \
           ec2-user@"$IN_PRIV" true </dev/null 2>&1 && echo "conexion establecida ESTADO=PERMITIDO" \
           || echo "RESULTADO: vm-ventas-1 no reenvia conexiones (AllowTcpForwarding no) ESTADO=BLOQUEADO")
  echo "$salida"; evaluar BLOQUEADO "$salida"
fi
TODAS=""
for x in "$V1_PRIV" "$V2_PRIV" "$DC_PRIV" "$VV_PRIV" "$IN_PRIV" "$DMZ_PRIV" "$DNS_IP"; do existe "$x" && TODAS="$TODAS $x"; done
remota "vm-ti-1 -> SSH de todas las VM (la administracion sigue funcionando, DEBE funcionar)" PERMITIDO "$TI_ID" \
  "$(for x in $TODAS; do c_tcp "$x" 22; done)"

# ---------- D. Los servicios siguen funcionando despues del hardening 
existe "$V1_ID" && remota "vm-ventas-1 -> DNS interno: dig rrhh (DEBE funcionar)" PERMITIDO "$V1_ID" "$(c_dns_interno)"
existe "$V1_ID" && remota "vm-ventas-1 -> http://$FQDN por nombre (DEBE funcionar)" PERMITIDO "$V1_ID" \
  "getent hosts $FQDN; $(c_http "http://$FQDN/" 200)"
remota "vm-ti-1 -> http://$FQDN por nombre (DEBE funcionar)" PERMITIDO "$TI_ID" "$(c_http "http://$FQDN/" 200)"
existe "$DC_ID" && existe "$IN_PRIV" && remota "vm-datacenter-1 -> intranet (--resolve, DEBE funcionar)" PERMITIDO "$DC_ID" \
  "$(c_http "http://$FQDN/" 200 "--resolve $FQDN:80:$IN_PRIV")"
local_ "Internet -> http://$DOMINIO (DEBE redirigir 301 a HTTPS)" PERMITIDO "$(c_http "http://$DOMINIO/" 301)"
local_ "Internet -> https://$DOMINIO (DEBE funcionar)" PERMITIDO "$(c_http "https://$DOMINIO/" 200)"
existe "$V1_ID" && remota "vm-ventas-1 -> https://$DOMINIO por Internet (DEBE funcionar)" PERMITIDO "$V1_ID" "$(c_http "https://$DOMINIO/" 200)"
existe "$DMZ_ID" && remota "vm-dmz-web: renovacion del certificado (certbot renew --dry-run, DEBE funcionar)" PERMITIDO "$DMZ_ID" \
  "sudo certbot renew --dry-run --no-random-sleep-on-renew >/tmp/certbot-prueba.log 2>&1; rc=\$?; tail -4 /tmp/certbot-prueba.log; if [ \$rc -eq 0 ]; then echo 'ESTADO=PERMITIDO'; else echo 'ESTADO=BLOQUEADO'; fi"
existe "$DMZ_ID" && remota "vm-dmz-web -> vm-ti-1 e intranet (la DMZ sigue aislada, DEBE FALLAR)" BLOQUEADO "$DMZ_ID" \
  "$(c_tcp "$TI_PRIV" 22) $(existe "$IN_PRIV" && c_tcp "$IN_PRIV" 80)"
fi

# ---------- Resumen ----------
echo
echo "=================================================================="
echo "RESUMEN: $OK de $N pruebas con el resultado esperado; $FALLOS con fallo${LISTA_FALLOS:+ (pruebas:$LISTA_FALLOS)}"
echo "=================================================================="
[ "$FALLOS" -eq 0 ]
