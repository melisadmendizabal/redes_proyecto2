#!/usr/bin/env bash

#  - Visitas tiene acceso a Internet, pero no a las subredes internas
#    (Ventas, TI, Data Center, intranet, DMZ por IP privada ni la VPC del DNS).
#  - TI sigue llegando a Visitas (administracion por eice-ti).
#  - Desde Internet nadie entra a Visitas (se quita el SSH desde CloudShell).
#
# Crea en vpc-startup:
#  1. visitas-sg   : Security Group (con estado) de vm-visitas-1
#  2. nacl-visitas : Network ACL (sin estado) de snet-visitas
#
# Ejecutar en AWS CloudShell.   Uso:  bash reglas-visitas-fase2.sh
# =====================================================================
set -euo pipefail
export AWS_PAGER=""

REGION="${REGION:-us-east-1}"
export AWS_DEFAULT_REGION="$REGION"
PROJ="proyecto-redes"
CIDR_TI="10.10.0.32/27"
OUT="$HOME/evidencia-aws"

tag () { aws ec2 create-tags --resources "$1" \
           --tags "Key=Name,Value=$2" "Key=Project,Value=$PROJ" >/dev/null; }

# 0. Recursos existentes 
VPC=$(aws ec2 describe-vpcs --filters "Name=tag:Project,Values=$PROJ" --query "Vpcs[0].VpcId" --output text)
[ "$VPC" != "None" ] || { echo "No existe vpc-startup en $REGION. Ejecuta primero deploy-aws.sh"; exit 1; }
SN_VISITAS=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC" "Name=tag:Name,Values=snet-visitas" \
             --query "Subnets[0].SubnetId" --output text)
[ "$SN_VISITAS" != "None" ] || { echo "No se encontro snet-visitas"; exit 1; }
VV_ID=$(aws ec2 describe-instances --filters "Name=tag:Name,Values=vm-visitas-1" "Name=tag:Project,Values=$PROJ" \
        "Name=instance-state-name,Values=running" --query "Reservations[0].Instances[0].InstanceId" --output text)
EICE=$(aws ec2 describe-instance-connect-endpoints --filters "Name=vpc-id,Values=$VPC" \
       --query "InstanceConnectEndpoints[?State=='create-complete'] | [0].InstanceConnectEndpointId" --output text)
[ "$EICE" != "None" ] || { echo "No existe eice-ti. Ejecuta primero reglas-internas-fase2.sh (sin el endpoint no se podria administrar Visitas)"; exit 1; }
echo "==> VPC $VPC | Subred Visitas $SN_VISITAS | vm-visitas-1 $VV_ID | endpoint $EICE"

# 1. Security Group de Visitas 
# Entrada: solo TI (SSH por eice-ti y ping). Nadie de Internet ni de las demas subredes.
# Salida: la regla por defecto (todo). El SG no puede expresar "todo menos lo privado";
# eso lo hace nacl-visitas, que si tiene reglas deny.
SG=$(aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$VPC" "Name=group-name,Values=visitas-sg" \
     --query "SecurityGroups[0].GroupId" --output text)
if [ "$SG" = "None" ]; then
  echo "==> Creando Security Group visitas-sg"
  SG=$(aws ec2 create-security-group --group-name visitas-sg \
        --description "Visitas: entrada solo desde TI (SSH por eice-ti e ICMP); salida a Internet" \
        --vpc-id "$VPC" --query GroupId --output text)
  tag "$SG" sg-visitas
  aws ec2 authorize-security-group-ingress --group-id "$SG" --ip-permissions \
    "IpProtocol=tcp,FromPort=22,ToPort=22,IpRanges=[{CidrIp=${CIDR_TI},Description=ssh-admin-ti-y-eice}]" \
    "IpProtocol=icmp,FromPort=-1,ToPort=-1,IpRanges=[{CidrIp=${CIDR_TI},Description=icmp-ti}]" >/dev/null
fi
echo "==> Security Group $SG"

# 2. Network ACL de Visitas 
# Sin estado y evaluada de menor a mayor. Primero lo de TI, despues se niegan TODAS las
# redes privadas (RFC 1918: incluye vpc-startup, la DMZ por IP privada y la VPC del DNS)
# y al final se abre Internet. Las respuestas de Internet entran por puertos efimeros.
# Las NACL no filtran el DNS de AWS (10.10.0.2), DHCP ni los metadatos: Visitas sigue
# resolviendo nombres publicos.
NACL=$(aws ec2 describe-network-acls --filters "Name=vpc-id,Values=$VPC" "Name=tag:Name,Values=nacl-visitas" \
       --query "NetworkAcls[0].NetworkAclId" --output text)
if [ "$NACL" = "None" ]; then
  echo "==> Creando Network ACL nacl-visitas"
  NACL=$(aws ec2 create-network-acl --vpc-id "$VPC" --query NetworkAcl.NetworkAclId --output text)
  tag "$NACL" nacl-visitas
  regla () {   # $1 = --ingress/--egress, $2 = numero, $3 = allow/deny, $4 = CIDR, resto = protocolo y puertos
    aws ec2 create-network-acl-entry --network-acl-id "$NACL" "$1" \
      --rule-number "$2" --rule-action "$3" --cidr-block "$4" "${@:5}"
  }
  regla --ingress 100 allow "$CIDR_TI"      --protocol -1                                  # TI llega a Visitas
  regla --ingress 190 deny  10.0.0.0/8      --protocol -1                                  # nada de redes privadas
  regla --ingress 200 deny  172.16.0.0/12   --protocol -1
  regla --ingress 210 deny  192.168.0.0/16  --protocol -1
  regla --ingress 300 allow 0.0.0.0/0       --protocol 6  --port-range From=1024,To=65535  # respuestas TCP de Internet
  regla --ingress 310 allow 0.0.0.0/0       --protocol 17 --port-range From=1024,To=65535  # respuestas UDP (QUIC, NTP publico)
  regla --ingress 320 allow 0.0.0.0/0       --protocol 1  --icmp-type-code Type=0,Code=-1  # echo-reply
  regla --ingress 330 allow 0.0.0.0/0       --protocol 1  --icmp-type-code Type=3,Code=-1  # destination unreachable (Path MTU)
  regla --ingress 340 allow 0.0.0.0/0       --protocol 1  --icmp-type-code Type=11,Code=-1 # time exceeded (traceroute)
  regla --egress  100 allow "$CIDR_TI"      --protocol 6  --port-range From=1024,To=65535  # respuestas TCP hacia TI
  regla --egress  110 allow "$CIDR_TI"      --protocol 1  --icmp-type-code Type=-1,Code=-1 # respuestas de ping hacia TI
  regla --egress  190 deny  10.0.0.0/8      --protocol -1                                  # Visitas no inicia nada hacia la red interna
  regla --egress  200 deny  172.16.0.0/12   --protocol -1
  regla --egress  210 deny  192.168.0.0/16  --protocol -1
  regla --egress  300 allow 0.0.0.0/0       --protocol -1                                  # Internet
fi
ASSOC=$(aws ec2 describe-network-acls --filters "Name=association.subnet-id,Values=$SN_VISITAS" \
        --query "NetworkAcls[0].Associations[?SubnetId=='$SN_VISITAS'].NetworkAclAssociationId" --output text)
aws ec2 replace-network-acl-association --association-id "$ASSOC" --network-acl-id "$NACL" >/dev/null
echo "==> Subred Visitas asociada a nacl-visitas ($NACL)"

# 3. vm-visitas-1 pasa de startup-sg a visitas-sg 
if [ "$VV_ID" != "None" ]; then
  ANTES=$(aws ec2 describe-instances --instance-ids "$VV_ID" \
          --query "Reservations[0].Instances[0].SecurityGroups[].GroupName" --output text)
  aws ec2 modify-instance-attribute --instance-id "$VV_ID" --groups "$SG"
  echo "==> vm-visitas-1: Security Groups antes = $ANTES ; ahora = visitas-sg"
else
  echo "==> Aviso: no hay vm-visitas-1 en ejecucion; las nuevas VM de Visitas deben lanzarse con --security-group-ids $SG"
fi

#  4. Evidencia 
mkdir -p "$OUT"
aws ec2 describe-security-groups --group-ids "$SG"      > "$OUT/visitas-security-group.json"
aws ec2 describe-network-acls --network-acl-ids "$NACL" > "$OUT/visitas-nacl.json"
[ "$VV_ID" = "None" ] || aws ec2 describe-instances --instance-ids "$VV_ID" > "$OUT/visitas-instancia.json"

echo
echo "==> Reglas de visitas-sg (entrada)"
aws ec2 describe-security-groups --group-ids "$SG" \
  --query "SecurityGroups[0].IpPermissions[].[IpProtocol,FromPort,ToPort,IpRanges[0].CidrIp,IpRanges[0].Description]" --output table
echo "==> Entradas de nacl-visitas (Egress False = entrada, True = salida)"
aws ec2 describe-network-acls --network-acl-ids "$NACL" \
  --query "sort_by(NetworkAcls[0].Entries,&RuleNumber)[].[Egress,RuleNumber,RuleAction,Protocol,CidrBlock,PortRange.From,PortRange.To,IcmpTypeCode.Type]" --output table
echo "Evidencia guardada en $OUT"
echo "Siguiente paso: bash aplicar-hardening-fase2.sh | tee $OUT/hardening-fase2.log"
