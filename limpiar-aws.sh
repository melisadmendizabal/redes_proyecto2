#!/usr/bin/env bash
# =====================================================================
# Guarda la configuracion (entregable) en ~/evidencia-aws/ y BORRA todo
# lo creado por deploy-aws.sh. Ejecutar SOLO cuando ya tengas tus screenshots.
# Los JSON se descargan con Actions > Download file en CloudShell.
# =====================================================================
export AWS_PAGER=""
export AWS_DEFAULT_REGION="${REGION:-us-east-1}"
PROJ="proyecto-redes"
KEY="proyecto-key"
OUT="$HOME/evidencia-aws"

VPC=$(aws ec2 describe-vpcs --filters "Name=tag:Project,Values=$PROJ" \
      --query "Vpcs[0].VpcId" --output text)
if [ "$VPC" = "None" ]; then
  echo "No hay VPC del proyecto en $AWS_DEFAULT_REGION. Nada que borrar."
  exit 0
fi

echo "==> Guardando configuracion en $OUT"
mkdir -p "$OUT"
F="Name=vpc-id,Values=$VPC"
aws ec2 describe-vpcs --vpc-ids "$VPC"                       > "$OUT/vpc.json"
aws ec2 describe-subnets --filters "$F"                      > "$OUT/subnets.json"
aws ec2 describe-route-tables --filters "$F"                 > "$OUT/route-tables.json"
aws ec2 describe-network-acls --filters "$F"                 > "$OUT/network-acls.json"
aws ec2 describe-security-groups --filters "$F"              > "$OUT/security-groups.json"
aws ec2 describe-internet-gateways --filters "Name=attachment.vpc-id,Values=$VPC" > "$OUT/internet-gateway.json"
aws ec2 describe-instances --filters "$F"                    > "$OUT/instancias.json"

read -r -p "Se borrara TODA la VPC $VPC y sus recursos. Escribe SI para continuar: " R
[ "$R" = "SI" ] || { echo "Cancelado."; exit 0; }

echo "==> Terminando instancias"
IDS=$(aws ec2 describe-instances --filters "$F" \
      "Name=instance-state-name,Values=pending,running,stopping,stopped" \
      --query "Reservations[].Instances[].InstanceId" --output text)
if [ -n "$IDS" ]; then
  aws ec2 terminate-instances --instance-ids $IDS >/dev/null
  aws ec2 wait instance-terminated --instance-ids $IDS
fi

echo "==> Borrando subredes"
for S in $(aws ec2 describe-subnets --filters "$F" --query "Subnets[].SubnetId" --output text); do
  aws ec2 delete-subnet --subnet-id "$S"
done

echo "==> Borrando NACL, tablas de rutas y Security Group del proyecto"
for N in $(aws ec2 describe-network-acls --filters "$F" "Name=tag:Project,Values=$PROJ" \
           --query "NetworkAcls[].NetworkAclId" --output text); do
  aws ec2 delete-network-acl --network-acl-id "$N"
done
for R in $(aws ec2 describe-route-tables --filters "$F" "Name=tag:Project,Values=$PROJ" \
           --query "RouteTables[].RouteTableId" --output text); do
  aws ec2 delete-route-table --route-table-id "$R"
done
for G in $(aws ec2 describe-security-groups --filters "$F" "Name=tag:Project,Values=$PROJ" \
           --query "SecurityGroups[].GroupId" --output text); do
  aws ec2 delete-security-group --group-id "$G"
done

echo "==> Borrando Internet Gateway"
IGW=$(aws ec2 describe-internet-gateways --filters "Name=attachment.vpc-id,Values=$VPC" \
      --query "InternetGateways[0].InternetGatewayId" --output text)
if [ "$IGW" != "None" ]; then
  aws ec2 detach-internet-gateway --internet-gateway-id "$IGW" --vpc-id "$VPC"
  aws ec2 delete-internet-gateway --internet-gateway-id "$IGW"
fi

echo "==> Borrando VPC y llave SSH"
aws ec2 delete-vpc --vpc-id "$VPC"
aws ec2 delete-key-pair --key-name "$KEY" >/dev/null 2>&1
rm -f "$HOME/proyecto-key.pem"

echo "==> Listo. Verifica en la consola (EC2 y VPC) que no quede nada en esta region."