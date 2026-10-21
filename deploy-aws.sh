#!/usr/bin/env bash
# =====================================================================
# CC3067 Redes - Proyecto Final Fase 1 (version AWS)
# Despliega una VPC segmentada (Ventas, TI, Data Center, Visitas)
# y EC2 de prueba. Ejecutar en AWS CloudShell.
#
# Uso:   bash deploy-aws.sh
# Opcional: REGION=us-east-2 ITYPE=t3.small BONUS=0 bash deploy-aws.sh
# =====================================================================
set -euo pipefail
export AWS_PAGER=""

# ---------- Variables ----------
REGION="${REGION:-us-east-1}"
export AWS_DEFAULT_REGION="$REGION"
ITYPE="${ITYPE:-t3.micro}"       # elegible para el Free plan (x86)
BONUS="${BONUS:-1}"              # 1 = crea vm-visitas-1 para demostrar aislamiento
PROJ="proyecto-redes"
KEY="proyecto-key"
KEYFILE="$HOME/proyecto-key.pem"

VPC_CIDR="10.10.0.0/24"
CIDR_VENTAS="10.10.0.0/27"       # 25 hosts
CIDR_TI="10.10.0.32/27"          # 15 hosts
CIDR_VISITAS="10.10.0.64/27"     # ~25 invitados
CIDR_DC="10.10.0.96/28"          # 5 servidores

tag () { aws ec2 create-tags --resources "$1" \
           --tags "Key=Name,Value=$2" "Key=Project,Value=$PROJ" >/dev/null; }

# ---------- 0. Evitar duplicados ----------
EXIST=$(aws ec2 describe-vpcs --filters "Name=tag:Project,Values=$PROJ" \
        --query "Vpcs[0].VpcId" --output text)
if [ "$EXIST" != "None" ]; then
  echo "Ya existe una VPC del proyecto ($EXIST) en $REGION."
  echo "Ejecuta primero: bash limpiar-aws.sh"
  exit 1
fi

AZ="${AZ:-$(aws ec2 describe-availability-zones --query 'AvailabilityZones[0].ZoneName' --output text)}"
echo "==> Region: $REGION | Zona: $AZ | Instancia: $ITYPE"

# ---------- 1. VPC ----------
echo "==> Creando VPC $VPC_CIDR"
VPC=$(aws ec2 create-vpc --cidr-block "$VPC_CIDR" --query Vpc.VpcId --output text)
aws ec2 modify-vpc-attribute --vpc-id "$VPC" --enable-dns-hostnames
tag "$VPC" vpc-startup

# ---------- 2. Subredes ----------
mk_subnet () {   # $1 = nombre, $2 = CIDR
  local id
  id=$(aws ec2 create-subnet --vpc-id "$VPC" --cidr-block "$2" \
        --availability-zone "$AZ" --query Subnet.SubnetId --output text)
  tag "$id" "$1"
  echo "$id"
}
echo "==> Creando subredes"
SN_VENTAS=$(mk_subnet snet-ventas     "$CIDR_VENTAS")
SN_TI=$(mk_subnet     snet-ti         "$CIDR_TI")
SN_VISITAS=$(mk_subnet snet-visitas   "$CIDR_VISITAS")
SN_DC=$(mk_subnet     snet-datacenter "$CIDR_DC")

# ---------- 3. Internet Gateway y ruta publica (solo Ventas y Visitas, donde hay VMs de prueba) ----------
echo "==> Creando Internet Gateway y tabla de rutas publica"
IGW=$(aws ec2 create-internet-gateway --query InternetGateway.InternetGatewayId --output text)
tag "$IGW" igw-startup
aws ec2 attach-internet-gateway --internet-gateway-id "$IGW" --vpc-id "$VPC"

RT=$(aws ec2 create-route-table --vpc-id "$VPC" --query RouteTable.RouteTableId --output text)
tag "$RT" rt-publica
aws ec2 create-route --route-table-id "$RT" --destination-cidr-block 0.0.0.0/0 --gateway-id "$IGW" >/dev/null
for S in "$SN_VENTAS" "$SN_VISITAS"; do
  aws ec2 associate-route-table --route-table-id "$RT" --subnet-id "$S" >/dev/null
  aws ec2 modify-subnet-attribute --subnet-id "$S" --map-public-ip-on-launch
done
# TI y Data Center quedan privadas (solo ruta local de la VPC)

# ---------- 4. NACL: las subredes internas rechazan trafico originado en Visitas ----------
echo "==> Creando Network ACL nacl-internas (aislamiento de Visitas)"
NACL=$(aws ec2 create-network-acl --vpc-id "$VPC" --query NetworkAcl.NetworkAclId --output text)
tag "$NACL" nacl-internas
aws ec2 create-network-acl-entry --network-acl-id "$NACL" --ingress --rule-number 50 \
  --protocol -1 --rule-action deny  --cidr-block "$CIDR_VISITAS"
aws ec2 create-network-acl-entry --network-acl-id "$NACL" --ingress --rule-number 100 \
  --protocol -1 --rule-action allow --cidr-block 0.0.0.0/0
aws ec2 create-network-acl-entry --network-acl-id "$NACL" --egress  --rule-number 100 \
  --protocol -1 --rule-action allow --cidr-block 0.0.0.0/0

for S in "$SN_VENTAS" "$SN_TI" "$SN_DC"; do
  ASSOC=$(aws ec2 describe-network-acls --filters "Name=association.subnet-id,Values=$S" \
          --query "NetworkAcls[0].Associations[?SubnetId=='$S'].NetworkAclAssociationId" --output text)
  aws ec2 replace-network-acl-association --association-id "$ASSOC" --network-acl-id "$NACL" >/dev/null
done

# ---------- 5. Security Group: SSH desde CloudShell + ICMP dentro de la VPC ----------
echo "==> Creando Security Group sg-startup"
MYIP=$(curl -s https://checkip.amazonaws.com | tr -d '[:space:]')
SG=$(aws ec2 create-security-group --group-name startup-sg \
      --description "SSH desde CloudShell e ICMP interno" --vpc-id "$VPC" \
      --query GroupId --output text)
tag "$SG" sg-startup
aws ec2 authorize-security-group-ingress --group-id "$SG" --ip-permissions \
  "IpProtocol=tcp,FromPort=22,ToPort=22,IpRanges=[{CidrIp=${MYIP}/32,Description=ssh-cloudshell}]" \
  "IpProtocol=icmp,FromPort=-1,ToPort=-1,IpRanges=[{CidrIp=${VPC_CIDR},Description=icmp-vpc}]" >/dev/null

# ---------- 6. Llave SSH (se guarda en ~/ de CloudShell, que es persistente) ----------
if [ ! -f "$KEYFILE" ] || ! aws ec2 describe-key-pairs --key-names "$KEY" >/dev/null 2>&1; then
  echo "==> Creando llave SSH $KEY"
  rm -f "$KEYFILE"
  aws ec2 delete-key-pair --key-name "$KEY" >/dev/null 2>&1 || true
  aws ec2 create-key-pair --key-name "$KEY" --query KeyMaterial --output text > "$KEYFILE"
  chmod 400 "$KEYFILE"
fi

# ---------- 7. Instancias EC2 ----------
AMI=$(aws ssm get-parameter \
      --name /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 \
      --query Parameter.Value --output text)

run_vm () {   # $1 = nombre, $2 = subred
  aws ec2 run-instances --image-id "$AMI" --instance-type "$ITYPE" --key-name "$KEY" \
    --subnet-id "$2" --security-group-ids "$SG" \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$1},{Key=Project,Value=$PROJ}]" \
    --query 'Instances[0].InstanceId' --output text
}

echo "==> Lanzando instancias"
IDS=()
IDS+=("$(run_vm vm-ventas-1 "$SN_VENTAS")")
IDS+=("$(run_vm vm-ventas-2 "$SN_VENTAS")")
if [ "$BONUS" = "1" ]; then
  IDS+=("$(run_vm vm-visitas-1 "$SN_VISITAS")")
fi

echo "==> Esperando a que arranquen (1-2 min)"
aws ec2 wait instance-running   --instance-ids "${IDS[@]}"
aws ec2 wait instance-status-ok --instance-ids "${IDS[@]}"

# ---------- 8. Resumen ----------
echo
echo "==> Listo. Instancias:"
aws ec2 describe-instances \
  --filters "Name=tag:Project,Values=$PROJ" "Name=instance-state-name,Values=running" \
  --query 'Reservations[].Instances[].[Tags[?Key==`Name`]|[0].Value,PrivateIpAddress,PublicIpAddress,InstanceType]' \
  --output table
echo
echo "Siguiente paso: bash pruebas-aws.sh"