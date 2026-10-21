#!/usr/bin/env bash
# =====================================================================
# Pruebas de conectividad (ping) entre instancias EC2. Ejecutar en CloudShell.
# Entra por SSH a cada instancia y hace ping a la IP privada de la otra.
# Toma screenshot de cada salida.
# =====================================================================
set -uo pipefail
export AWS_PAGER=""
export AWS_DEFAULT_REGION="${REGION:-us-east-1}"
PROJ="proyecto-redes"
KEYFILE="$HOME/proyecto-key.pem"
SSH_OPTS="-i $KEYFILE -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -o LogLevel=ERROR"

attr () {   # $1 = nombre de la instancia, $2 = atributo (PrivateIpAddress / PublicIpAddress)
  aws ec2 describe-instances \
    --filters "Name=tag:Name,Values=$1" "Name=tag:Project,Values=$PROJ" "Name=instance-state-name,Values=running" \
    --query "Reservations[0].Instances[0].$2" --output text
}

# Si CloudShell cambio de IP publica desde el despliegue, autoriza la actual (idempotente)
SG=$(aws ec2 describe-security-groups \
      --filters "Name=tag:Project,Values=$PROJ" "Name=group-name,Values=startup-sg" \
      --query "SecurityGroups[0].GroupId" --output text)
MYIP=$(curl -s https://checkip.amazonaws.com | tr -d '[:space:]')
aws ec2 authorize-security-group-ingress --group-id "$SG" --protocol tcp --port 22 \
  --cidr "${MYIP}/32" >/dev/null 2>&1 || true

V1_PRIV=$(attr vm-ventas-1 PrivateIpAddress); V1_PUB=$(attr vm-ventas-1 PublicIpAddress)
V2_PRIV=$(attr vm-ventas-2 PrivateIpAddress); V2_PUB=$(attr vm-ventas-2 PublicIpAddress)
echo "vm-ventas-1 = $V1_PRIV (publica $V1_PUB)"
echo "vm-ventas-2 = $V2_PRIV (publica $V2_PUB)"

echo
echo "##### PRUEBA 1: vm-ventas-1 -> vm-ventas-2 (misma subred, DEBE funcionar)"
ssh $SSH_OPTS ec2-user@"$V1_PUB" "hostname; hostname -I; ping -c 4 $V2_PRIV"

echo
echo "##### PRUEBA 2: vm-ventas-2 -> vm-ventas-1 (sentido inverso, DEBE funcionar)"
ssh $SSH_OPTS ec2-user@"$V2_PUB" "hostname; hostname -I; ping -c 4 $V1_PRIV"

VV_PUB=$(attr vm-visitas-1 PublicIpAddress)
if [ -n "$VV_PUB" ] && [ "$VV_PUB" != "None" ]; then
  VV_PRIV=$(attr vm-visitas-1 PrivateIpAddress)
  echo
  echo "##### PRUEBA 3 (bonus): vm-visitas-1 ($VV_PRIV) -> vm-ventas-1 (DEBE FALLAR: la NACL aisla Visitas)"
  ssh $SSH_OPTS ec2-user@"$VV_PUB" "hostname; hostname -I; ping -c 4 -W 2 $V1_PRIV"
fi