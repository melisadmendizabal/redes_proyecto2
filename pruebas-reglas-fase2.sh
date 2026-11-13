#!/usr/bin/env bash
# =====================================================================
# Pruebas de las reglas internas (Fase 2). Ejecutar en CloudShell
# despues de reglas-internas-fase2.sh. Toma screenshot de cada salida.
# Uso:   bash pruebas-reglas-fase2.sh | tee ~/evidencia-aws/pruebas-reglas-fase2.log
#
# Las VM publicas (Ventas, Visitas) se acceden por SSH directo. Las privadas
# (TI, Data Center, intranet) por el EC2 Instance Connect Endpoint de TI.
# =====================================================================
set -uo pipefail
export AWS_PAGER=""
export AWS_DEFAULT_REGION="${REGION:-us-east-1}"
PROJ="proyecto-redes"
FQDN="rrhh.mansiondeldisfraz.local"
KEYFILE="$HOME/proyecto-key.pem"
SSH_OPTS="-i $KEYFILE -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=15 -o LogLevel=ERROR"

attr () {   # $1 = nombre de la instancia, $2 = atributo (InstanceId / PrivateIpAddress / PublicIpAddress)
  aws ec2 describe-instances \
    --filters "Name=tag:Name,Values=$1" "Name=tag:Project,Values=$PROJ" "Name=instance-state-name,Values=running" \
    --query "Reservations[0].Instances[0].$2" --output text
}
existe () { [ -n "$1" ] && [ "$1" != "None" ]; }

N=0
remoto () {   # $1 = titulo, $2 = IP publica o instance-id, $3 = comando, $4 = "eice" si la VM es privada
  N=$((N + 1))
  echo
  echo "##### PRUEBA REGLAS $N: $1"
  if [ "${4:-}" = "eice" ]; then
    ssh $SSH_OPTS -o "ProxyCommand=aws ec2-instance-connect open-tunnel --instance-id $2" ec2-user@"$2" "$3"
  else
    ssh $SSH_OPTS ec2-user@"$2" "$3"
  fi
}

# Comandos remotos. Cada uno termina en una linea "RESULTADO: ..." facil de leer en la captura.
c_ping_ssh () {   # $1 = IP destino: ping + intento de conexion TCP al puerto 22
  echo "hostname; hostname -I; echo '--- ICMP hacia $1'; ping -c 3 -W 2 $1 && echo 'RESULTADO ICMP: responde' || echo 'RESULTADO ICMP: sin respuesta (bloqueado)'; echo '--- TCP 22 hacia $1'; timeout 4 bash -c '</dev/tcp/$1/22' 2>/dev/null && echo 'RESULTADO TCP 22: conexion abierta' || echo 'RESULTADO TCP 22: sin conexion (bloqueado)'"
}
c_ping () {
  echo "hostname; hostname -I; echo '--- ICMP hacia $1'; ping -c 3 -W 2 $1 && echo 'RESULTADO ICMP: responde' || echo 'RESULTADO ICMP: sin respuesta (bloqueado)'"
}
c_tcp () {        # $1 = IP, $2 = puerto
  echo "hostname; hostname -I; echo '--- TCP $2 hacia $1'; timeout 4 bash -c '</dev/tcp/$1/$2' 2>/dev/null && echo 'RESULTADO TCP $2: conexion abierta' || echo 'RESULTADO TCP $2: sin conexion (bloqueado)'"
}
c_intranet () {   # $1 = "" para resolver por DNS, o la IP para fijar el nombre con --resolve
  local fijar=""
  [ -n "$1" ] && fijar="--resolve $FQDN:80:$1"
  echo "hostname; hostname -I; echo '--- DNS'; getent hosts $FQDN || echo '$FQDN no resuelve'; echo '--- HTTP'; curl -sS --max-time 5 $fijar -o /dev/null -w 'HTTP %{http_code}\n' http://$FQDN/ && echo 'RESULTADO: intranet accesible' || echo 'RESULTADO: sin respuesta (bloqueado)'"
}

[ -f "$KEYFILE" ] || { echo "Falta $KEYFILE en CloudShell"; exit 1; }

# Si CloudShell cambio de IP publica, la autoriza en startup-sg para entrar a Ventas y Visitas (idempotente)
SG=$(aws ec2 describe-security-groups \
      --filters "Name=tag:Project,Values=$PROJ" "Name=group-name,Values=startup-sg" \
      --query "SecurityGroups[0].GroupId" --output text)
MYIP=$(curl -s https://checkip.amazonaws.com | tr -d '[:space:]')
aws ec2 authorize-security-group-ingress --group-id "$SG" --protocol tcp --port 22 \
  --cidr "${MYIP}/32" >/dev/null 2>&1 || true

V1_PUB=$(attr vm-ventas-1 PublicIpAddress);  V1_PRIV=$(attr vm-ventas-1 PrivateIpAddress)
V2_PUB=$(attr vm-ventas-2 PublicIpAddress)
TI_ID=$(attr vm-ti-1 InstanceId);            TI_PRIV=$(attr vm-ti-1 PrivateIpAddress)
DC_ID=$(attr vm-datacenter-1 InstanceId);    DC_PRIV=$(attr vm-datacenter-1 PrivateIpAddress)
VV_PUB=$(attr vm-visitas-1 PublicIpAddress); VV_PRIV=$(attr vm-visitas-1 PrivateIpAddress)
IN_ID=$(attr vm-intranet-rrhh InstanceId);   IN_PRIV=$(attr vm-intranet-rrhh PrivateIpAddress)
VPC=$(aws ec2 describe-vpcs --filters "Name=tag:Project,Values=$PROJ" --query "Vpcs[0].VpcId" --output text)
DMZ_PRIV=$(aws ec2 describe-instances --filters "Name=vpc-id,Values=$VPC" "Name=instance-state-name,Values=running" \
           --query "Reservations[].Instances[].PrivateIpAddress" --output text \
           | tr '\t' '\n' | awk -F. '$4>=112 && $4<=127' | head -1)   # primera VM dentro de 10.10.0.112/28
existe "$TI_ID" || { echo "No hay vm-ti-1 en ejecucion"; exit 1; }

echo "vm-ventas-1      = $V1_PRIV"
echo "vm-ti-1          = $TI_PRIV ($TI_ID)"
echo "vm-datacenter-1  = $DC_PRIV"
echo "vm-visitas-1     = $VV_PRIV"
echo "vm-intranet-rrhh = $IN_PRIV"
echo "VM en la DMZ     = ${DMZ_PRIV:-(todavia no hay)}"

# ---------- 0. Configuracion aplicada ----------
N=$((N + 1))
echo
echo "##### PRUEBA REGLAS $N: Configuracion de firewall de TI (Security Group + NACL)"
aws ec2 describe-instances --instance-ids "$TI_ID" \
  --query "Reservations[0].Instances[0].[Tags[?Key=='Name']|[0].Value,SubnetId,SecurityGroups[0].GroupName]" --output table
aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$VPC" "Name=group-name,Values=ti-sg" \
  --query "SecurityGroups[0].IpPermissions[].[IpProtocol,FromPort,ToPort,IpRanges[0].CidrIp,IpRanges[0].Description]" --output table
aws ec2 describe-network-acls --filters "Name=vpc-id,Values=$VPC" "Name=tag:Name,Values=nacl-ti" \
  --query "sort_by(NetworkAcls[0].Entries[?Egress==\`false\`],&RuleNumber)[].[RuleNumber,RuleAction,Protocol,CidrBlock,PortRange.From,PortRange.To,IcmpTypeCode.Type]" --output table

# ---------- A. TI -> todas las subredes (DEBEN funcionar) ----------
remoto "vm-ti-1 -> vm-ventas-1 (TI -> Ventas, DEBE funcionar)" "$TI_ID" "$(c_ping_ssh "$V1_PRIV")" eice
existe "$DC_PRIV" && remoto "vm-ti-1 -> vm-datacenter-1 (TI -> Data Center, DEBE funcionar)" "$TI_ID" "$(c_ping_ssh "$DC_PRIV")" eice
existe "$VV_PRIV" && remoto "vm-ti-1 -> vm-visitas-1 (TI -> Visitas, DEBE funcionar)" "$TI_ID" "$(c_ping_ssh "$VV_PRIV")" eice
existe "$IN_PRIV" && remoto "vm-ti-1 -> http://$FQDN (TI -> intranet, DEBE funcionar)" "$TI_ID" "$(c_intranet "")" eice
existe "$DMZ_PRIV" && remoto "vm-ti-1 -> DMZ $DMZ_PRIV puerto 80 (TI -> DMZ, DEBE funcionar si la DMZ acepta a TI)" "$TI_ID" "$(c_tcp "$DMZ_PRIV" 80)" eice

# ---------- B. Otras subredes -> TI (DEBEN FALLAR) ----------
remoto "vm-ventas-1 -> vm-ti-1 (Ventas -> TI, DEBE FALLAR)" "$V1_PUB" "$(c_ping_ssh "$TI_PRIV")"
existe "$V2_PUB"  && remoto "vm-ventas-2 -> vm-ti-1 (Ventas -> TI, DEBE FALLAR)" "$V2_PUB" "$(c_ping "$TI_PRIV")"
existe "$DC_ID"   && remoto "vm-datacenter-1 -> vm-ti-1 (Data Center -> TI, DEBE FALLAR)" "$DC_ID" "$(c_ping_ssh "$TI_PRIV")" eice
existe "$IN_ID"   && remoto "vm-intranet-rrhh -> vm-ti-1 (servidor del Data Center -> TI, DEBE FALLAR)" "$IN_ID" "$(c_ping_ssh "$TI_PRIV")" eice
existe "$VV_PUB"  && remoto "vm-visitas-1 -> vm-ti-1 (Visitas -> TI, DEBE FALLAR)" "$VV_PUB" "$(c_ping_ssh "$TI_PRIV")"

# ---------- C. Intranet: demas subredes si, Visitas e Internet no ----------
if existe "$IN_PRIV"; then
  remoto "vm-ventas-1 -> http://$FQDN (Ventas -> intranet, DEBE funcionar)" "$V1_PUB" "$(c_intranet "")"
  existe "$DC_ID"  && remoto "vm-datacenter-1 -> intranet (Data Center -> intranet, DEBE funcionar)" "$DC_ID" "$(c_intranet "$IN_PRIV")" eice
  existe "$VV_PUB" && remoto "vm-visitas-1 -> intranet (Visitas -> intranet, DEBE FALLAR)" "$VV_PUB" "$(c_intranet "$IN_PRIV")"

  N=$((N + 1))
  echo
  echo "##### PRUEBA REGLAS $N: Internet (CloudShell) -> intranet (DEBE FALLAR)"
  echo "Origen: CloudShell con IP publica $MYIP"
  echo "IP publica de vm-intranet-rrhh: $(attr vm-intranet-rrhh PublicIpAddress)"
  getent hosts "$FQDN" || echo "$FQDN no resuelve en Internet"
  curl -sS --max-time 5 -o /dev/null -w 'HTTP %{http_code}\n' "http://$IN_PRIV/" \
    || echo "RESULTADO: sin respuesta, la intranet no es alcanzable desde Internet"
fi
