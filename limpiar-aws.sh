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
aws ec2 describe-vpc-endpoints --filters "$F"                > "$OUT/vpc-endpoints.json"
aws ec2 describe-instance-connect-endpoints --filters "$F"   > "$OUT/instance-connect-endpoints.json"

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

echo "==> Borrando endpoints de la VPC (S3 de la intranet)"
EPS=$(aws ec2 describe-vpc-endpoints --filters "$F" --query "VpcEndpoints[].VpcEndpointId" --output text)
if [ -n "$EPS" ]; then
  aws ec2 delete-vpc-endpoints --vpc-endpoint-ids $EPS >/dev/null
fi

echo "==> Borrando EC2 Instance Connect Endpoint (subred TI)"
for E in $(aws ec2 describe-instance-connect-endpoints --filters "$F" \
           --query "InstanceConnectEndpoints[?State!='delete-complete'].InstanceConnectEndpointId" --output text); do
  aws ec2 delete-instance-connect-endpoint --instance-connect-endpoint-id "$E" >/dev/null
  for _ in $(seq 1 60); do   # su interfaz de red impide borrar la subred TI hasta que termine
    ESTADO=$(aws ec2 describe-instance-connect-endpoints --instance-connect-endpoint-ids "$E" \
             --query "InstanceConnectEndpoints[0].State" --output text 2>/dev/null || echo delete-complete)
    case "$ESTADO" in delete-complete|None) break ;; esac
    sleep 10
  done
done

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