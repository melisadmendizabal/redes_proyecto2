#!/usr/bin/env bash
# =====================================================================
# CC3067 Redes - Proyecto Final Fase 2
# Despliega la intranet de RRHH (Nginx) en la subred Data Center de
# vpc-startup con la IP fija 10.10.0.101. Ejecutar en AWS CloudShell.
#
# Uso:   bash desplegar-intranet-fase2.sh
# =====================================================================
set -euo pipefail
export AWS_PAGER=""

REGION="${REGION:-us-east-1}"
export AWS_DEFAULT_REGION="$REGION"
ITYPE="${ITYPE:-t3.micro}"
PROJ="proyecto-redes"
KEY="proyecto-key"
NAME="vm-intranet-rrhh"
INTRANET_IP="10.10.0.101"
CIDR_VENTAS="10.10.0.0/27"
CIDR_TI="10.10.0.32/27"
CIDR_DC="10.10.0.96/28"
DIR="$(cd "$(dirname "$0")" && pwd)"
USERDATA="$DIR/configurar-intranet-fase2.sh"
OUT="$HOME/evidencia-aws"

tag () { aws ec2 create-tags --resources "$1" \
           --tags "Key=Name,Value=$2" "Key=Project,Value=$PROJ" >/dev/null; }

[ -f "$USERDATA" ] || { echo "No se encontro $USERDATA"; exit 1; }

# ---------- 0. Recursos de la Fase 1 ----------
VPC=$(aws ec2 describe-vpcs --filters "Name=tag:Project,Values=$PROJ" \
      --query "Vpcs[0].VpcId" --output text)
[ "$VPC" != "None" ] || { echo "No existe vpc-startup en $REGION. Ejecuta primero deploy-aws.sh"; exit 1; }
SN_DC=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC" "Name=tag:Name,Values=snet-datacenter" \
        --query "Subnets[0].SubnetId" --output text)
RT_MAIN=$(aws ec2 describe-route-tables --filters "Name=vpc-id,Values=$VPC" "Name=association.main,Values=true" \
          --query "RouteTables[0].RouteTableId" --output text)
aws ec2 describe-key-pairs --key-names "$KEY" >/dev/null 2>&1 || { echo "No existe el key pair $KEY en $REGION"; exit 1; }
echo "==> VPC $VPC | Subred Data Center $SN_DC | Tabla principal $RT_MAIN"

# ---------- 1. Evitar duplicados y verificar que la IP este libre ----------
EXIST=$(aws ec2 describe-instances --filters "Name=tag:Name,Values=$NAME" "Name=tag:Project,Values=$PROJ" \
        "Name=instance-state-name,Values=pending,running,stopping,stopped" \
        --query "Reservations[0].Instances[0].InstanceId" --output text)
if [ "$EXIST" != "None" ]; then
  echo "La intranet ya existe ($EXIST). Siguiente paso: bash pruebas-intranet-fase2.sh"
  exit 0
fi
OCUPADA=$(aws ec2 describe-network-interfaces \
          --filters "Name=vpc-id,Values=$VPC" "Name=addresses.private-ip-address,Values=$INTRANET_IP" \
          --query "NetworkInterfaces[0].NetworkInterfaceId" --output text)
if [ "$OCUPADA" != "None" ]; then
  echo "La IP $INTRANET_IP ya esta en uso por la interfaz $OCUPADA:"
  aws ec2 describe-network-interfaces --network-interface-ids "$OCUPADA" \
    --query "NetworkInterfaces[0].[Attachment.InstanceId,Description]" --output text
  echo "Libera esa IP o acuerda otra con el equipo (el registro DNS de rrhh apunta a $INTRANET_IP)."
  exit 1
fi

# ---------- 2. Endpoint de S3 para que la subred privada instale paquetes sin salir a Internet ----------
VPCE=$(aws ec2 describe-vpc-endpoints --filters "Name=vpc-id,Values=$VPC" \
       "Name=service-name,Values=com.amazonaws.$REGION.s3" "Name=vpc-endpoint-state,Values=available,pending" \
       --query "VpcEndpoints[0].VpcEndpointId" --output text)
if [ "$VPCE" = "None" ]; then
  echo "==> Creando endpoint de S3 (gateway) en la tabla principal"
  VPCE=$(aws ec2 create-vpc-endpoint --vpc-id "$VPC" --vpc-endpoint-type Gateway \
         --service-name "com.amazonaws.$REGION.s3" --route-table-ids "$RT_MAIN" \
         --query "VpcEndpoint.VpcEndpointId" --output text)
  tag "$VPCE" vpce-s3-privadas
else
  aws ec2 modify-vpc-endpoint --vpc-endpoint-id "$VPCE" --add-route-table-ids "$RT_MAIN" >/dev/null 2>&1 || true
fi
for _ in $(seq 1 30); do
  ESTADO=$(aws ec2 describe-vpc-endpoints --vpc-endpoint-ids "$VPCE" --query "VpcEndpoints[0].State" --output text)
  [ "$ESTADO" = "available" ] && break
  sleep 5
done
echo "==> Endpoint $VPCE: $ESTADO"

# ---------- 3. Security Group de la intranet: HTTP solo desde Ventas, TI y Data Center ----------
SG=$(aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$VPC" "Name=group-name,Values=intranet-rrhh-sg" \
     --query "SecurityGroups[0].GroupId" --output text)
if [ "$SG" = "None" ]; then
  echo "==> Creando Security Group intranet-rrhh-sg"
  SG=$(aws ec2 create-security-group --group-name intranet-rrhh-sg \
        --description "Intranet RRHH: HTTP interno, SSH desde Ventas y TI" --vpc-id "$VPC" \
        --query GroupId --output text)
  tag "$SG" sg-intranet-rrhh
  aws ec2 authorize-security-group-ingress --group-id "$SG" --ip-permissions \
    "IpProtocol=tcp,FromPort=80,ToPort=80,IpRanges=[{CidrIp=${CIDR_VENTAS},Description=http-ventas},{CidrIp=${CIDR_TI},Description=http-ti},{CidrIp=${CIDR_DC},Description=http-datacenter}]" \
    "IpProtocol=tcp,FromPort=22,ToPort=22,IpRanges=[{CidrIp=${CIDR_VENTAS},Description=ssh-salto-ventas},{CidrIp=${CIDR_TI},Description=ssh-ti}]" >/dev/null
fi
echo "==> Security Group $SG"

# ---------- 4. Instancia de la intranet ----------
AMI=$(aws ssm get-parameter \
      --name /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 \
      --query Parameter.Value --output text)
echo "==> Lanzando $NAME con IP $INTRANET_IP"
ID=$(aws ec2 run-instances --image-id "$AMI" --instance-type "$ITYPE" --key-name "$KEY" \
      --subnet-id "$SN_DC" --private-ip-address "$INTRANET_IP" --security-group-ids "$SG" \
      --metadata-options "HttpTokens=required,HttpEndpoint=enabled" \
      --user-data "file://$USERDATA" \
      --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$NAME},{Key=Project,Value=$PROJ}]" \
      --query 'Instances[0].InstanceId' --output text)
echo "==> Esperando a que arranque (2-3 min)"
aws ec2 wait instance-running   --instance-ids "$ID"
aws ec2 wait instance-status-ok --instance-ids "$ID"

# ---------- 5. Evidencia de configuracion ----------
mkdir -p "$OUT"
aws ec2 describe-instances --instance-ids "$ID"   > "$OUT/intranet-instancia.json"
aws ec2 describe-security-groups --group-ids "$SG" > "$OUT/intranet-security-group.json"
aws ec2 describe-vpc-endpoints --vpc-endpoint-ids "$VPCE" > "$OUT/intranet-vpc-endpoint-s3.json"

echo
aws ec2 describe-instances --instance-ids "$ID" \
  --query 'Reservations[].Instances[].[Tags[?Key==`Name`]|[0].Value,InstanceId,PrivateIpAddress,PublicIpAddress,State.Name]' \
  --output table
echo "Evidencia guardada en $OUT"
