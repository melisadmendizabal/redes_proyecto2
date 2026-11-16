#!/usr/bin/env bash
# =====================================================================
# Guarda la configuracion de la DMZ en ~/evidencia-aws/ y BORRA solo lo
# creado por desplegar-dmz-fase2.sh: vm-dmz-web, eip-dmz-web, snet-dmz,
# rt-dmz, nacl-dmz y dmz-web-sg. El resto de vpc-startup no se toca.
# Ejecutar en CloudShell cuando ya no se necesite la web publica
# (la Elastic IP y la instancia cobran mientras existan).
# =====================================================================
export AWS_PAGER=""
export AWS_DEFAULT_REGION="${REGION:-us-east-1}"
PROJ="proyecto-redes"
OUT="$HOME/evidencia-aws"

VPC=$(aws ec2 describe-vpcs --filters "Name=tag:Project,Values=$PROJ" --query "Vpcs[0].VpcId" --output text)
if [ "$VPC" = "None" ]; then
  echo "No hay VPC del proyecto en $AWS_DEFAULT_REGION. Nada que borrar."
  exit 0
fi
F="Name=vpc-id,Values=$VPC"
ID=$(aws ec2 describe-instances --filters "$F" "Name=tag:Name,Values=vm-dmz-web" \
     "Name=instance-state-name,Values=pending,running,stopping,stopped" \
     --query "Reservations[0].Instances[0].InstanceId" --output text)
ALLOC=$(aws ec2 describe-addresses --filters "Name=tag:Name,Values=eip-dmz-web" "Name=tag:Project,Values=$PROJ" \
        --query "Addresses[0].AllocationId" --output text)
SN_DMZ=$(aws ec2 describe-subnets --filters "$F" "Name=tag:Name,Values=snet-dmz" --query "Subnets[0].SubnetId" --output text)
RT_DMZ=$(aws ec2 describe-route-tables --filters "$F" "Name=tag:Name,Values=rt-dmz" --query "RouteTables[0].RouteTableId" --output text)
NACL=$(aws ec2 describe-network-acls --filters "$F" "Name=tag:Name,Values=nacl-dmz" --query "NetworkAcls[0].NetworkAclId" --output text)
SG=$(aws ec2 describe-security-groups --filters "$F" "Name=group-name,Values=dmz-web-sg" --query "SecurityGroups[0].GroupId" --output text)

echo "==> Guardando configuracion de la DMZ en $OUT"
mkdir -p "$OUT"
[ "$SN_DMZ" = "None" ] || aws ec2 describe-subnets --subnet-ids "$SN_DMZ"           > "$OUT/dmz-subred.json"
[ "$RT_DMZ" = "None" ] || aws ec2 describe-route-tables --route-table-ids "$RT_DMZ" > "$OUT/dmz-route-table.json"
[ "$NACL" = "None" ]   || aws ec2 describe-network-acls --network-acl-ids "$NACL"   > "$OUT/dmz-nacl.json"
[ "$SG" = "None" ]     || aws ec2 describe-security-groups --group-ids "$SG"        > "$OUT/dmz-security-group.json"
[ "$ID" = "None" ]     || aws ec2 describe-instances --instance-ids "$ID"           > "$OUT/dmz-instancia.json"
[ "$ALLOC" = "None" ]  || aws ec2 describe-addresses --allocation-ids "$ALLOC"      > "$OUT/dmz-elastic-ip.json"

echo "Instancia $ID | Elastic IP $ALLOC | Subred $SN_DMZ | Rutas $RT_DMZ | NACL $NACL | SG $SG"
read -r -p "Se borrara SOLO la DMZ (recursos de arriba). Escribe SI para continuar: " R
[ "$R" = "SI" ] || { echo "Cancelado."; exit 0; }

if [ "$ID" != "None" ]; then
  echo "==> Terminando vm-dmz-web"
  aws ec2 terminate-instances --instance-ids "$ID" >/dev/null
  aws ec2 wait instance-terminated --instance-ids "$ID"
fi

if [ "$ALLOC" != "None" ]; then
  echo "==> Liberando la Elastic IP (deja de cobrar)"
  ASOC=$(aws ec2 describe-addresses --allocation-ids "$ALLOC" --query "Addresses[0].AssociationId" --output text)
  [ "$ASOC" = "None" ] || aws ec2 disassociate-address --association-id "$ASOC"
  aws ec2 release-address --allocation-id "$ALLOC"
fi

reintentar () {   # la interfaz de red de la instancia tarda unos segundos en desaparecer
  for _ in $(seq 1 12); do "$@" 2>/dev/null && return 0; sleep 10; done
  "$@"
}
if [ "$SN_DMZ" != "None" ]; then
  echo "==> Borrando subred snet-dmz"
  reintentar aws ec2 delete-subnet --subnet-id "$SN_DMZ"
fi
[ "$RT_DMZ" = "None" ] || { echo "==> Borrando rt-dmz";     aws ec2 delete-route-table --route-table-id "$RT_DMZ"; }
[ "$NACL" = "None" ]   || { echo "==> Borrando nacl-dmz";   aws ec2 delete-network-acl --network-acl-id "$NACL"; }
[ "$SG" = "None" ]     || { echo "==> Borrando dmz-web-sg"; reintentar aws ec2 delete-security-group --group-id "$SG"; }

echo "==> Listo. Verifica en la consola (EC2 > Elastic IPs e Instancias) que no quede nada de la DMZ."
