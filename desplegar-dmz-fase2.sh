#!/usr/bin/env bash
# =====================================================================
# CC3067 Redes - Proyecto Final Fase 2 - DMZ y servidor web publico
# Crea en vpc-startup:
#  1. snet-dmz    : subred DMZ 10.10.0.112/28, en la misma zona que TI
#  2. rt-dmz      : tabla de rutas propia (local + Internet por igw-startup,
#                   sin ruta al peering del DNS interno)
#  3. nacl-dmz    : Network ACL (sin estado) de la subred DMZ
#  4. dmz-web-sg  : Security Group (con estado) del servidor web
#  5. eip-dmz-web : Elastic IP, la IP publica fija a la que apunta el dominio
#  6. vm-dmz-web  : EC2 con Nginx en la IP fija 10.10.0.116
#                   (user data: configurar-web-publica-fase2.sh)
#
# Ejecutar en AWS CloudShell.   Uso:  bash desplegar-dmz-fase2.sh
# Siguiente paso: apuntar el dominio a la Elastic IP y correr habilitar-https-fase2.sh
# =====================================================================
set -euo pipefail
export AWS_PAGER=""

REGION="${REGION:-us-east-1}"
export AWS_DEFAULT_REGION="$REGION"
ITYPE="${ITYPE:-t3.micro}"
PROJ="proyecto-redes"
KEY="proyecto-key"
NAME="vm-dmz-web"
VPC_CIDR="10.10.0.0/24"          # Ventas, TI, Visitas, Data Center y DMZ
CIDR_TI="10.10.0.32/27"
CIDR_DMZ="10.10.0.112/28"
CIDR_DNS_VPC="10.10.1.0/28"      # vpc-dns-fase2 (peering), DNS interno en 10.10.1.4
WEB_IP="10.10.0.116"             # primera IP utilizable: AWS reserva .112-.115 y .127
DIR="$(cd "$(dirname "$0")" && pwd)"
USERDATA="$DIR/configurar-web-publica-fase2.sh"
OUT="$HOME/evidencia-aws"

tag () { aws ec2 create-tags --resources "$1" \
           --tags "Key=Name,Value=$2" "Key=Project,Value=$PROJ" >/dev/null; }

[ -f "$USERDATA" ] || { echo "No se encontro $USERDATA"; exit 1; }

# ---------- 0. Recursos existentes ----------
VPC=$(aws ec2 describe-vpcs --filters "Name=tag:Project,Values=$PROJ" \
      --query "Vpcs[0].VpcId" --output text)
[ "$VPC" != "None" ] || { echo "No existe vpc-startup en $REGION. Ejecuta primero deploy-aws.sh"; exit 1; }
IGW=$(aws ec2 describe-internet-gateways --filters "Name=attachment.vpc-id,Values=$VPC" \
      --query "InternetGateways[0].InternetGatewayId" --output text)
[ "$IGW" != "None" ] || { echo "vpc-startup no tiene Internet Gateway"; exit 1; }
AZ=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC" "Name=tag:Name,Values=snet-ti" \
     --query "Subnets[0].AvailabilityZone" --output text)
[ "$AZ" != "None" ] || { echo "No se encontro snet-ti para ubicar la DMZ en su misma zona"; exit 1; }
aws ec2 describe-key-pairs --key-names "$KEY" >/dev/null 2>&1 || { echo "No existe el key pair $KEY en $REGION"; exit 1; }
echo "==> VPC $VPC | Internet Gateway $IGW | Zona $AZ"

# ---------- 1. Subred DMZ ----------
SN_DMZ=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC" "Name=cidr-block,Values=$CIDR_DMZ" \
         --query "Subnets[0].SubnetId" --output text)
if [ "$SN_DMZ" = "None" ]; then
  echo "==> Creando subred snet-dmz $CIDR_DMZ"
  SN_DMZ=$(aws ec2 create-subnet --vpc-id "$VPC" --cidr-block "$CIDR_DMZ" --availability-zone "$AZ" \
           --query Subnet.SubnetId --output text)
  tag "$SN_DMZ" snet-dmz
else
  NOMBRE=$(aws ec2 describe-subnets --subnet-ids "$SN_DMZ" --query "Subnets[0].Tags[?Key=='Name'].Value | [0]" --output text)
  [ "$NOMBRE" = "snet-dmz" ] || { echo "El bloque $CIDR_DMZ ya lo usa la subred $SN_DMZ ($NOMBRE)"; exit 1; }
fi
# Sin IP publica automatica: la unica IP publica de la DMZ es la Elastic IP del servidor web
aws ec2 modify-subnet-attribute --subnet-id "$SN_DMZ" --no-map-public-ip-on-launch
echo "==> Subred DMZ: $SN_DMZ"

# ---------- 2. Tabla de rutas de la DMZ ----------
RT_DMZ=$(aws ec2 describe-route-tables --filters "Name=vpc-id,Values=$VPC" "Name=tag:Name,Values=rt-dmz" \
         --query "RouteTables[0].RouteTableId" --output text)
if [ "$RT_DMZ" = "None" ]; then
  echo "==> Creando tabla de rutas rt-dmz (local + 0.0.0.0/0 hacia $IGW)"
  RT_DMZ=$(aws ec2 create-route-table --vpc-id "$VPC" --query RouteTable.RouteTableId --output text)
  tag "$RT_DMZ" rt-dmz
  aws ec2 create-route --route-table-id "$RT_DMZ" --destination-cidr-block 0.0.0.0/0 --gateway-id "$IGW" >/dev/null
fi
ASOC_RT=$(aws ec2 describe-route-tables --route-table-ids "$RT_DMZ" \
          --query "RouteTables[0].Associations[?SubnetId=='$SN_DMZ'].RouteTableAssociationId" --output text)
[ -n "$ASOC_RT" ] || aws ec2 associate-route-table --route-table-id "$RT_DMZ" --subnet-id "$SN_DMZ" >/dev/null
echo "==> Tabla de rutas $RT_DMZ asociada a la DMZ"

# ---------- 3. Network ACL de la DMZ ----------
# Sin estado: cada regla de entrada necesita su regla de salida para la respuesta.
# Primero lo que TI puede hacer, luego se niega el resto de la red interna y al final
# se abre lo publico (80/443) y las respuestas a lo que el servidor descarga (443).
NACL=$(aws ec2 describe-network-acls --filters "Name=vpc-id,Values=$VPC" "Name=tag:Name,Values=nacl-dmz" \
       --query "NetworkAcls[0].NetworkAclId" --output text)
if [ "$NACL" = "None" ]; then
  echo "==> Creando Network ACL nacl-dmz"
  NACL=$(aws ec2 create-network-acl --vpc-id "$VPC" --query NetworkAcl.NetworkAclId --output text)
  tag "$NACL" nacl-dmz
  regla () {   # $1 = --ingress/--egress, $2 = numero, $3 = allow/deny, $4 = CIDR, resto = protocolo y puertos
    aws ec2 create-network-acl-entry --network-acl-id "$NACL" "$1" \
      --rule-number "$2" --rule-action "$3" --cidr-block "$4" "${@:5}"
  }
  regla --ingress 100 allow "$CIDR_TI"      --protocol 6  --port-range From=22,To=22        # SSH de TI (incluye eice-ti)
  regla --ingress 110 allow "$CIDR_TI"      --protocol 1  --icmp-type-code Type=-1,Code=-1  # ping desde TI
  regla --ingress 120 allow "$CIDR_TI"      --protocol 6  --port-range From=80,To=80        # HTTP desde TI
  regla --ingress 130 allow "$CIDR_TI"      --protocol 6  --port-range From=443,To=443      # HTTPS desde TI
  regla --ingress 190 deny  "$VPC_CIDR"     --protocol -1                                   # nada mas desde la red interna
  regla --ingress 200 deny  "$CIDR_DNS_VPC" --protocol -1                                   # ni desde la VPC del DNS
  regla --ingress 300 allow 0.0.0.0/0       --protocol 6  --port-range From=80,To=80        # HTTP publico (redireccion y Let's Encrypt)
  regla --ingress 310 allow 0.0.0.0/0       --protocol 6  --port-range From=443,To=443      # HTTPS publico
  regla --ingress 320 allow 0.0.0.0/0       --protocol 6  --port-range From=1024,To=65535   # respuestas a lo que el servidor descarga
  regla --egress  100 allow "$CIDR_TI"      --protocol 6  --port-range From=1024,To=65535   # respuestas hacia TI
  regla --egress  110 allow "$CIDR_TI"      --protocol 1  --icmp-type-code Type=-1,Code=-1  # respuestas de ping hacia TI
  regla --egress  190 deny  "$VPC_CIDR"     --protocol -1                                   # la DMZ no inicia nada hacia la red interna
  regla --egress  200 deny  "$CIDR_DNS_VPC" --protocol -1                                   # ni hacia la VPC del DNS
  regla --egress  300 allow 0.0.0.0/0       --protocol 6  --port-range From=443,To=443      # HTTPS saliente (dnf y Let's Encrypt)
  regla --egress  310 allow 0.0.0.0/0       --protocol 6  --port-range From=1024,To=65535   # respuestas a los clientes web
fi
ASSOC=$(aws ec2 describe-network-acls --filters "Name=association.subnet-id,Values=$SN_DMZ" \
        --query "NetworkAcls[0].Associations[?SubnetId=='$SN_DMZ'].NetworkAclAssociationId" --output text)
aws ec2 replace-network-acl-association --association-id "$ASSOC" --network-acl-id "$NACL" >/dev/null
echo "==> Subred DMZ asociada a nacl-dmz ($NACL)"

# ---------- 4. Security Group del servidor web ----------
SG=$(aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$VPC" "Name=group-name,Values=dmz-web-sg" \
     --query "SecurityGroups[0].GroupId" --output text)
if [ "$SG" = "None" ]; then
  echo "==> Creando Security Group dmz-web-sg"
  SG=$(aws ec2 create-security-group --group-name dmz-web-sg \
        --description "Web publica DMZ: HTTP y HTTPS desde Internet, SSH e ICMP solo desde TI, salida solo HTTPS" \
        --vpc-id "$VPC" --query GroupId --output text)
  tag "$SG" sg-dmz-web
  aws ec2 authorize-security-group-ingress --group-id "$SG" --ip-permissions \
    "IpProtocol=tcp,FromPort=80,ToPort=80,IpRanges=[{CidrIp=0.0.0.0/0,Description=http-publico-redireccion-y-acme}]" \
    "IpProtocol=tcp,FromPort=443,ToPort=443,IpRanges=[{CidrIp=0.0.0.0/0,Description=https-publico}]" \
    "IpProtocol=tcp,FromPort=22,ToPort=22,IpRanges=[{CidrIp=${CIDR_TI},Description=ssh-ti-y-eice}]" \
    "IpProtocol=icmp,FromPort=-1,ToPort=-1,IpRanges=[{CidrIp=${CIDR_TI},Description=icmp-ti}]" >/dev/null
  # Salida: se quita la regla "todo hacia todos" y solo queda HTTPS (dnf y Let's Encrypt).
  # El DNS de AWS (VPC+2), los metadatos y Time Sync no pasan por el Security Group.
  aws ec2 revoke-security-group-egress --group-id "$SG" \
    --ip-permissions 'IpProtocol=-1,IpRanges=[{CidrIp=0.0.0.0/0}]' >/dev/null
  aws ec2 authorize-security-group-egress --group-id "$SG" --ip-permissions \
    "IpProtocol=tcp,FromPort=443,ToPort=443,IpRanges=[{CidrIp=0.0.0.0/0,Description=https-saliente-dnf-y-acme}]" >/dev/null
fi
echo "==> Security Group $SG"

# ---------- 5. Elastic IP ----------
ALLOC=$(aws ec2 describe-addresses --filters "Name=tag:Name,Values=eip-dmz-web" "Name=tag:Project,Values=$PROJ" \
        --query "Addresses[0].AllocationId" --output text)
if [ "$ALLOC" = "None" ]; then
  echo "==> Reservando Elastic IP eip-dmz-web"
  ALLOC=$(aws ec2 allocate-address --domain vpc \
          --tag-specifications "ResourceType=elastic-ip,Tags=[{Key=Name,Value=eip-dmz-web},{Key=Project,Value=$PROJ}]" \
          --query AllocationId --output text)
fi
EIP=$(aws ec2 describe-addresses --allocation-ids "$ALLOC" --query "Addresses[0].PublicIp" --output text)
echo "==> Elastic IP $EIP ($ALLOC)"

# ---------- 6. Servidor web ----------
ID=$(aws ec2 describe-instances --filters "Name=tag:Name,Values=$NAME" "Name=tag:Project,Values=$PROJ" \
     "Name=instance-state-name,Values=pending,running,stopping,stopped" \
     --query "Reservations[0].Instances[0].InstanceId" --output text)
if [ "$ID" = "None" ]; then
  OCUPADA=$(aws ec2 describe-network-interfaces \
            --filters "Name=vpc-id,Values=$VPC" "Name=addresses.private-ip-address,Values=$WEB_IP" \
            --query "NetworkInterfaces[0].NetworkInterfaceId" --output text)
  [ "$OCUPADA" = "None" ] || { echo "La IP $WEB_IP ya esta en uso por la interfaz $OCUPADA"; exit 1; }
  AMI=$(aws ssm get-parameter \
        --name /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 \
        --query Parameter.Value --output text)
  echo "==> Lanzando $NAME ($ITYPE) con IP $WEB_IP"
  # CpuCredits=standard: si la CPU se agota se limita el rendimiento en vez de cobrar creditos extra
  ID=$(aws ec2 run-instances --image-id "$AMI" --instance-type "$ITYPE" --key-name "$KEY" \
        --subnet-id "$SN_DMZ" --private-ip-address "$WEB_IP" --security-group-ids "$SG" \
        --credit-specification CpuCredits=standard \
        --metadata-options "HttpTokens=required,HttpEndpoint=enabled" \
        --user-data "file://$USERDATA" \
        --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$NAME},{Key=Project,Value=$PROJ}]" \
                             "ResourceType=volume,Tags=[{Key=Name,Value=$NAME},{Key=Project,Value=$PROJ}]" \
        --query 'Instances[0].InstanceId' --output text)
else
  ESTADO=$(aws ec2 describe-instances --instance-ids "$ID" --query "Reservations[0].Instances[0].State.Name" --output text)
  if [ "$ESTADO" = "stopped" ] || [ "$ESTADO" = "stopping" ]; then
    aws ec2 wait instance-stopped --instance-ids "$ID"
    aws ec2 start-instances --instance-ids "$ID" >/dev/null
  fi
fi
echo "==> Esperando a que $ID arranque"
aws ec2 wait instance-running --instance-ids "$ID"
# La Elastic IP se asocia apenas la instancia corre; el user data reintenta dnf hasta tener salida
aws ec2 associate-address --allocation-id "$ALLOC" --instance-id "$ID" >/dev/null
aws ec2 wait instance-status-ok --instance-ids "$ID"

echo "==> Esperando a que Nginx responda en http://$EIP (user data, 2-5 min)"
CODE=000
for _ in $(seq 1 40); do
  CODE=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://$EIP/" || true)
  [ "$CODE" = "200" ] || [ "$CODE" = "301" ] && break
  sleep 15
done
echo "==> http://$EIP responde HTTP $CODE desde Internet"

# ---------- 7. Evidencia de configuracion ----------
mkdir -p "$OUT"
aws ec2 describe-subnets --subnet-ids "$SN_DMZ"            > "$OUT/dmz-subred.json"
aws ec2 describe-route-tables --route-table-ids "$RT_DMZ"  > "$OUT/dmz-route-table.json"
aws ec2 describe-network-acls --network-acl-ids "$NACL"    > "$OUT/dmz-nacl.json"
aws ec2 describe-security-groups --group-ids "$SG"         > "$OUT/dmz-security-group.json"
aws ec2 describe-instances --instance-ids "$ID"            > "$OUT/dmz-instancia.json"
aws ec2 describe-addresses --allocation-ids "$ALLOC"       > "$OUT/dmz-elastic-ip.json"

echo
echo "==> Rutas de rt-dmz"
aws ec2 describe-route-tables --route-table-ids "$RT_DMZ" \
  --query "RouteTables[0].Routes[].[DestinationCidrBlock,GatewayId,State]" --output table
echo "==> Entradas de nacl-dmz (Egress False = entrada, True = salida)"
aws ec2 describe-network-acls --network-acl-ids "$NACL" \
  --query "sort_by(NetworkAcls[0].Entries,&RuleNumber)[].[Egress,RuleNumber,RuleAction,Protocol,CidrBlock,PortRange.From,PortRange.To]" --output table
echo "==> Reglas de dmz-web-sg (entrada)"
aws ec2 describe-security-groups --group-ids "$SG" \
  --query "SecurityGroups[0].IpPermissions[].[IpProtocol,FromPort,ToPort,IpRanges[0].CidrIp,IpRanges[0].Description]" --output table
echo "==> Reglas de dmz-web-sg (salida)"
aws ec2 describe-security-groups --group-ids "$SG" \
  --query "SecurityGroups[0].IpPermissionsEgress[].[IpProtocol,FromPort,ToPort,IpRanges[0].CidrIp,IpRanges[0].Description]" --output table
aws ec2 describe-instances --instance-ids "$ID" \
  --query 'Reservations[].Instances[].[Tags[?Key==`Name`]|[0].Value,InstanceId,InstanceType,PrivateIpAddress,PublicIpAddress,State.Name]' \
  --output table
echo "Evidencia guardada en $OUT"
echo
echo "Siguiente paso: en https://www.duckdns.org apunta el subdominio a $EIP y luego ejecuta:"
echo "  bash habilitar-https-fase2.sh mansiondeldisfraz.duckdns.org"
