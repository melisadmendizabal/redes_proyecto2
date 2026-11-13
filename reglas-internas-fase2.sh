#!/usr/bin/env bash
# =====================================================================
# CC3067 Redes - Proyecto Final Fase 2 - Reglas internas (Firewall/ACLs)
#  - TI tiene conectividad hacia todas las subredes.
#  - Ninguna otra subred (Ventas, Data Center, Visitas, DMZ, VPC del DNS)
#    puede iniciar conexiones hacia TI.
#  - La intranet sigue accesible desde Ventas, TI y Data Center
#    (intranet-rrhh-sg), pero no desde Visitas ni desde Internet.
#
# Crea en vpc-startup:
#  1. eice-ti-sg : Security Group del EC2 Instance Connect Endpoint
#  2. eice-ti    : EC2 Instance Connect Endpoint en la subred TI, para
#                  administrar por SSH las VM privadas sin saltar por Ventas
#  3. ti-sg      : Security Group (firewall con estado) de las VM de TI
#  4. nacl-ti    : Network ACL (sin estado) de la subred TI
#
# Ejecutar en AWS CloudShell.   Uso:  bash reglas-internas-fase2.sh
# =====================================================================
set -euo pipefail
export AWS_PAGER=""

REGION="${REGION:-us-east-1}"
export AWS_DEFAULT_REGION="$REGION"
PROJ="proyecto-redes"
VPC_CIDR="10.10.0.0/24"          # Ventas, TI, Visitas, Data Center y DMZ
CIDR_TI="10.10.0.32/27"
CIDR_DNS_VPC="10.10.1.0/28"      # vpc-dns-fase2 (peering), DNS en 10.10.1.4
OUT="$HOME/evidencia-aws"

tag () { aws ec2 create-tags --resources "$1" \
           --tags "Key=Name,Value=$2" "Key=Project,Value=$PROJ" >/dev/null; }
sg_id () { aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$VPC" "Name=group-name,Values=$1" \
             --query "SecurityGroups[0].GroupId" --output text; }

# ---------- 0. Recursos existentes ----------
VPC=$(aws ec2 describe-vpcs --filters "Name=tag:Project,Values=$PROJ" \
      --query "Vpcs[0].VpcId" --output text)
[ "$VPC" != "None" ] || { echo "No existe vpc-startup en $REGION. Ejecuta primero deploy-aws.sh"; exit 1; }
SN_TI=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC" "Name=tag:Name,Values=snet-ti" \
        --query "Subnets[0].SubnetId" --output text)
TI_ID=$(aws ec2 describe-instances --filters "Name=tag:Name,Values=vm-ti-1" "Name=tag:Project,Values=$PROJ" \
        "Name=instance-state-name,Values=running" --query "Reservations[0].Instances[0].InstanceId" --output text)
[ "$TI_ID" != "None" ] || { echo "No hay vm-ti-1 en ejecucion"; exit 1; }
echo "==> VPC $VPC | Subred TI $SN_TI | vm-ti-1 $TI_ID"

# ---------- 1. Security Group del Instance Connect Endpoint: solo sale SSH hacia la VPC ----------
SG_EICE=$(sg_id eice-ti-sg)
if [ "$SG_EICE" = "None" ]; then
  echo "==> Creando Security Group eice-ti-sg"
  SG_EICE=$(aws ec2 create-security-group --group-name eice-ti-sg \
             --description "EC2 Instance Connect Endpoint de TI: solo SSH saliente hacia la VPC" \
             --vpc-id "$VPC" --query GroupId --output text)
  tag "$SG_EICE" sg-eice-ti
  aws ec2 revoke-security-group-egress --group-id "$SG_EICE" \
    --ip-permissions 'IpProtocol=-1,IpRanges=[{CidrIp=0.0.0.0/0}]' >/dev/null
  aws ec2 authorize-security-group-egress --group-id "$SG_EICE" --ip-permissions \
    "IpProtocol=tcp,FromPort=22,ToPort=22,IpRanges=[{CidrIp=${VPC_CIDR},Description=ssh-admin-vpc}]" >/dev/null
fi
echo "==> Security Group del endpoint: $SG_EICE"

# ---------- 2. EC2 Instance Connect Endpoint en la subred TI ----------
# Solo se permite uno por VPC. Debe quedar en TI para que el SSH de administracion
# salga con una IP de TI (TI llega a todo; nadie llega a TI).
EICE=$(aws ec2 describe-instance-connect-endpoints \
        --filters "Name=vpc-id,Values=$VPC" \
        --query "InstanceConnectEndpoints[?State=='create-complete' || State=='create-in-progress'] | [0].InstanceConnectEndpointId" \
        --output text)
if [ "$EICE" = "None" ]; then
  echo "==> Creando EC2 Instance Connect Endpoint en la subred TI (tarda 3-5 min)"
  EICE=$(aws ec2 create-instance-connect-endpoint --subnet-id "$SN_TI" --security-group-ids "$SG_EICE" \
          --tag-specifications "ResourceType=instance-connect-endpoint,Tags=[{Key=Name,Value=eice-ti},{Key=Project,Value=$PROJ}]" \
          --query "InstanceConnectEndpoint.InstanceConnectEndpointId" --output text)
else
  SN_EICE=$(aws ec2 describe-instance-connect-endpoints --instance-connect-endpoint-ids "$EICE" \
            --query "InstanceConnectEndpoints[0].SubnetId" --output text)
  if [ "$SN_EICE" != "$SN_TI" ]; then
    echo "Ya existe el endpoint $EICE pero esta en la subred $SN_EICE, no en TI ($SN_TI)."
    echo "Borralo (aws ec2 delete-instance-connect-endpoint --instance-connect-endpoint-id $EICE) y vuelve a ejecutar."
    exit 1
  fi
fi
for _ in $(seq 1 60); do
  ESTADO=$(aws ec2 describe-instance-connect-endpoints --instance-connect-endpoint-ids "$EICE" \
           --query "InstanceConnectEndpoints[0].State" --output text)
  [ "$ESTADO" = "create-complete" ] && break
  sleep 10
done
echo "==> Endpoint $EICE: $ESTADO"
[ "$ESTADO" = "create-complete" ] || { echo "El endpoint no termino de crearse; vuelve a ejecutar el script en unos minutos."; exit 1; }

# ---------- 3. Security Group de TI: solo acepta trafico de la propia subred TI ----------
# Es un firewall con estado: las respuestas a lo que TI inicia entran solas,
# por eso no hace falta ninguna regla de entrada desde Ventas, Data Center, etc.
SG_TI=$(sg_id ti-sg)
if [ "$SG_TI" = "None" ]; then
  echo "==> Creando Security Group ti-sg"
  SG_TI=$(aws ec2 create-security-group --group-name ti-sg \
           --description "TI: entrada solo desde la subred TI (incluye el Instance Connect Endpoint)" \
           --vpc-id "$VPC" --query GroupId --output text)
  tag "$SG_TI" sg-ti
  aws ec2 authorize-security-group-ingress --group-id "$SG_TI" --ip-permissions \
    "IpProtocol=tcp,FromPort=22,ToPort=22,IpRanges=[{CidrIp=${CIDR_TI},Description=ssh-ti-y-eice}]" \
    "IpProtocol=icmp,FromPort=-1,ToPort=-1,IpRanges=[{CidrIp=${CIDR_TI},Description=icmp-ti}]" >/dev/null
  # La salida queda con la regla por defecto (todo hacia 0.0.0.0/0): TI llega a todas las subredes
fi
echo "==> Security Group de TI: $SG_TI"

ANTES=$(aws ec2 describe-instances --instance-ids "$TI_ID" \
        --query "Reservations[0].Instances[0].SecurityGroups[].GroupName" --output text)
echo "==> vm-ti-1: Security Groups antes = $ANTES ; ahora = ti-sg"
aws ec2 modify-instance-attribute --instance-id "$TI_ID" --groups "$SG_TI"

# ---------- 4. Network ACL de la subred TI ----------
# Una NACL no tiene estado: hay que dejar entrar explicitamente las RESPUESTAS
# a lo que TI inicia (puertos efimeros TCP/UDP y ICMP echo-reply) y negar todo
# lo demas que venga de la red interna.
NACL=$(aws ec2 describe-network-acls --filters "Name=vpc-id,Values=$VPC" "Name=tag:Name,Values=nacl-ti" \
       --query "NetworkAcls[0].NetworkAclId" --output text)
if [ "$NACL" = "None" ]; then
  echo "==> Creando Network ACL nacl-ti"
  NACL=$(aws ec2 create-network-acl --vpc-id "$VPC" --query NetworkAcl.NetworkAclId --output text)
  tag "$NACL" nacl-ti
  entrada () {   # $1 = regla, $2 = allow/deny, $3 = CIDR origen, resto = protocolo y puertos
    aws ec2 create-network-acl-entry --network-acl-id "$NACL" --ingress \
      --rule-number "$1" --rule-action "$2" --cidr-block "$3" "${@:4}"
  }
  entrada 100 allow "$VPC_CIDR"     --protocol 6  --port-range From=1024,To=65535   # respuestas TCP desde la VPC
  entrada 110 allow "$CIDR_DNS_VPC" --protocol 6  --port-range From=1024,To=65535   # respuestas TCP del DNS
  entrada 120 allow "$CIDR_DNS_VPC" --protocol 17 --port-range From=1024,To=65535   # respuestas UDP del DNS
  entrada 130 allow "$VPC_CIDR"     --protocol 1  --icmp-type-code Type=0,Code=-1   # echo-reply (respuesta de ping)
  entrada 140 allow "$VPC_CIDR"     --protocol 1  --icmp-type-code Type=3,Code=-1   # destination unreachable
  entrada 150 allow "$VPC_CIDR"     --protocol 1  --icmp-type-code Type=11,Code=-1  # time exceeded (traceroute)
  entrada 200 deny  "$VPC_CIDR"     --protocol -1                                   # nada mas desde la VPC
  entrada 210 deny  "$CIDR_DNS_VPC" --protocol -1                                   # nada mas desde la VPC del DNS
  entrada 300 allow 0.0.0.0/0       --protocol 6  --port-range From=1024,To=65535   # respuestas del endpoint S3 (dnf)
  aws ec2 create-network-acl-entry --network-acl-id "$NACL" --egress \
    --rule-number 100 --rule-action allow --cidr-block 0.0.0.0/0 --protocol -1      # TI puede salir hacia todo
fi
ASSOC=$(aws ec2 describe-network-acls --filters "Name=association.subnet-id,Values=$SN_TI" \
        --query "NetworkAcls[0].Associations[?SubnetId=='$SN_TI'].NetworkAclAssociationId" --output text)
aws ec2 replace-network-acl-association --association-id "$ASSOC" --network-acl-id "$NACL" >/dev/null
echo "==> Subred TI asociada a nacl-ti ($NACL)"

# ---------- 5. Evidencia de configuracion ----------
mkdir -p "$OUT"
aws ec2 describe-security-groups --group-ids "$SG_TI" "$SG_EICE" > "$OUT/reglas-security-groups-ti.json"
aws ec2 describe-network-acls --network-acl-ids "$NACL"         > "$OUT/reglas-nacl-ti.json"
aws ec2 describe-instance-connect-endpoints --instance-connect-endpoint-ids "$EICE" > "$OUT/reglas-eice-ti.json"
aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$VPC" > "$OUT/reglas-security-groups-vpc.json"
aws ec2 describe-network-acls --filters "Name=vpc-id,Values=$VPC"    > "$OUT/reglas-network-acls-vpc.json"

echo
echo "==> Reglas de entrada de ti-sg"
aws ec2 describe-security-groups --group-ids "$SG_TI" \
  --query "SecurityGroups[0].IpPermissions[].[IpProtocol,FromPort,ToPort,IpRanges[0].CidrIp,IpRanges[0].Description]" --output table
echo "==> Entradas de nacl-ti"
aws ec2 describe-network-acls --network-acl-ids "$NACL" \
  --query "sort_by(NetworkAcls[0].Entries,&RuleNumber)[].[Egress,RuleNumber,RuleAction,Protocol,CidrBlock,PortRange.From,PortRange.To,IcmpTypeCode.Type]" --output table
echo "Evidencia guardada en $OUT"
echo "Siguiente paso: bash pruebas-reglas-fase2.sh | tee $OUT/pruebas-reglas-fase2.log"
