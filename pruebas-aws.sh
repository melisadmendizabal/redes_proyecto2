#!/usr/bin/env bash
# =====================================================================
# Pruebas de conectividad (ping) entre instancias EC2. Ejecutar en CloudShell.
# Entra por SSH a cada instancia y hace ping a las IP privadas de las demas subredes.
# Toma screenshot de cada salida.
# =====================================================================
set -uo pipefail
export AWS_PAGER=""
export AWS_DEFAULT_REGION="${REGION:-us-east-1}"
PROJ="proyecto-redes"
VPC_CIDR="10.10.0.0/24"
KEYFILE="$HOME/proyecto-key.pem"
SSH_OPTS="-i $KEYFILE -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -o LogLevel=ERROR"

attr () {   # $1 = nombre de la instancia, $2 = atributo (PrivateIpAddress / PublicIpAddress)
  aws ec2 describe-instances \
    --filters "Name=tag:Name,Values=$1" "Name=tag:Project,Values=$PROJ" "Name=instance-state-name,Values=running" \
    --query "Reservations[0].Instances[0].$2" --output text
}

existe () { [ -n "$1" ] && [ "$1" != "None" ]; }

N=0
prueba () {   # $1 = titulo, $2 = IP para SSH, $3 = IP destino del ping, $4 = "salto" si la VM es privada
  N=$((N + 1))
  echo
  echo "##### PRUEBA $N: $1"
  if [ "${4:-}" = "salto" ]; then
    ssh $SSH_OPTS -o "ProxyCommand=ssh $SSH_OPTS -W %h:%p ec2-user@$V1_PUB" \
      ec2-user@"$2" "hostname; hostname -I; ping -c 4 -W 2 $3"
  else
    ssh $SSH_OPTS ec2-user@"$2" "hostname; hostname -I; ping -c 4 -W 2 $3"
  fi
}

# Si CloudShell cambio de IP publica desde el despliegue, autoriza la actual (idempotente)
SG=$(aws ec2 describe-security-groups \
      --filters "Name=tag:Project,Values=$PROJ" "Name=group-name,Values=startup-sg" \
      --query "SecurityGroups[0].GroupId" --output text)
MYIP=$(curl -s https://checkip.amazonaws.com | tr -d '[:space:]')
aws ec2 authorize-security-group-ingress --group-id "$SG" --protocol tcp --port 22 \
  --cidr "${MYIP}/32" >/dev/null 2>&1 || true
# SSH interno para saltar a TI y Data Center desde vm-ventas-1 (idempotente)
aws ec2 authorize-security-group-ingress --group-id "$SG" --protocol tcp --port 22 \
  --cidr "$VPC_CIDR" >/dev/null 2>&1 || true

V1_PRIV=$(attr vm-ventas-1 PrivateIpAddress); V1_PUB=$(attr vm-ventas-1 PublicIpAddress)
V2_PRIV=$(attr vm-ventas-2 PrivateIpAddress); V2_PUB=$(attr vm-ventas-2 PublicIpAddress)
TI_PRIV=$(attr vm-ti-1 PrivateIpAddress)
DC_PRIV=$(attr vm-datacenter-1 PrivateIpAddress)
VV_PRIV=$(attr vm-visitas-1 PrivateIpAddress); VV_PUB=$(attr vm-visitas-1 PublicIpAddress)
echo "vm-ventas-1     = $V1_PRIV (publica $V1_PUB)"
echo "vm-ventas-2     = $V2_PRIV (publica $V2_PUB)"
existe "$TI_PRIV" && echo "vm-ti-1         = $TI_PRIV (privada)"
existe "$DC_PRIV" && echo "vm-datacenter-1 = $DC_PRIV (privada)"
existe "$VV_PUB"  && echo "vm-visitas-1    = $VV_PRIV (publica $VV_PUB)"

prueba "vm-ventas-1 -> vm-ventas-2 (misma subred, DEBE funcionar)" "$V1_PUB" "$V2_PRIV"
prueba "vm-ventas-2 -> vm-ventas-1 (sentido inverso, DEBE funcionar)" "$V2_PUB" "$V1_PRIV"

if existe "$TI_PRIV"; then
  prueba "vm-ventas-1 -> vm-ti-1 (Ventas -> TI, DEBE funcionar)" "$V1_PUB" "$TI_PRIV"
  prueba "vm-ti-1 -> vm-ventas-1 (TI -> Ventas, DEBE funcionar)" "$TI_PRIV" "$V1_PRIV" salto
fi

if existe "$DC_PRIV"; then
  prueba "vm-ventas-1 -> vm-datacenter-1 (Ventas -> Data Center, DEBE funcionar)" "$V1_PUB" "$DC_PRIV"
  prueba "vm-datacenter-1 -> vm-ventas-1 (Data Center -> Ventas, DEBE funcionar)" "$DC_PRIV" "$V1_PRIV" salto
fi

if existe "$TI_PRIV" && existe "$DC_PRIV"; then
  prueba "vm-ti-1 -> vm-datacenter-1 (TI -> Data Center, DEBE funcionar)" "$TI_PRIV" "$DC_PRIV" salto
  prueba "vm-datacenter-1 -> vm-ti-1 (Data Center -> TI, DEBE funcionar)" "$DC_PRIV" "$TI_PRIV" salto
fi

if existe "$VV_PUB"; then
  prueba "vm-visitas-1 -> vm-ventas-1 (DEBE FALLAR: la NACL aisla Visitas)" "$VV_PUB" "$V1_PRIV"
  existe "$TI_PRIV" && prueba "vm-visitas-1 -> vm-ti-1 (DEBE FALLAR: la NACL aisla Visitas)" "$VV_PUB" "$TI_PRIV"
  existe "$DC_PRIV" && prueba "vm-visitas-1 -> vm-datacenter-1 (DEBE FALLAR: la NACL aisla Visitas)" "$VV_PUB" "$DC_PRIV"
  prueba "vm-ventas-1 -> vm-visitas-1 (DEBE FALLAR: la NACL bloquea la respuesta de Visitas)" "$V1_PUB" "$VV_PRIV"
fi
