#!/usr/bin/env bash

# Guarda la configuracion del DNS interno en ~/evidencia-aws/ y borra solo
# vpc-dns-fase2 (10.10.1.0/28): vm-dns-fase2, su endpoint de S3, el peering con
# vpc-startup (y las rutas que apuntan a el), subredes, tablas de rutas, Security
# Groups, NACL y la VPC. vpc-startup no se toca.
# Ejecutar en CloudShell despues de la presentacion y ANTES de limpiar-aws.sh
# (asi limpiar-aws.sh no encuentra un peering activo en vpc-startup).
# =====================================================================
export AWS_PAGER=""
export AWS_DEFAULT_REGION="${REGION:-us-east-1}"
PROJ="proyecto-redes"
CIDR_DNS_VPC="10.10.1.0/28"
OUT="$HOME/evidencia-aws"

reintentar () {   # las interfaces de red tardan en liberarse despues de terminar instancias o endpoints
  for _ in $(seq 1 12); do "$@" 2>/dev/null && return 0; sleep 10; done
  "$@"
}

# 0. Ubicar la VPC del DNS (por nombre, por la instancia o por su bloque) 
VPC_STARTUP=$(aws ec2 describe-vpcs --filters "Name=tag:Project,Values=$PROJ" --query "Vpcs[0].VpcId" --output text)
DNS_VPC=$(aws ec2 describe-vpcs --filters "Name=tag:Name,Values=vpc-dns-fase2" --query "Vpcs[0].VpcId" --output text)
if [ "$DNS_VPC" = "None" ]; then
  DNS_VPC=$(aws ec2 describe-instances --filters "Name=tag:Name,Values=vm-dns-fase2" \
            "Name=instance-state-name,Values=pending,running,stopping,stopped" \
            --query "Reservations[0].Instances[0].VpcId" --output text)
fi
if [ "$DNS_VPC" = "None" ]; then
  DNS_VPC=$(aws ec2 describe-vpcs --filters "Name=cidr-block-association.cidr-block,Values=$CIDR_DNS_VPC" \
            --query "Vpcs[0].VpcId" --output text)
fi
if [ "$DNS_VPC" = "None" ]; then
  echo "No se encontro vpc-dns-fase2 en $AWS_DEFAULT_REGION. Nada que borrar."
  exit 0
fi
read -r CIDR ES_DEFAULT < <(aws ec2 describe-vpcs --vpc-ids "$DNS_VPC" --query "Vpcs[0].[CidrBlock,IsDefault]" --output text)
if [ "$DNS_VPC" = "$VPC_STARTUP" ] || [ "$ES_DEFAULT" = "True" ] || [ "$CIDR" != "$CIDR_DNS_VPC" ]; then
  echo "La VPC encontrada ($DNS_VPC, $CIDR) no es la del DNS interno. No se borra nada."
  exit 1
fi
F="Name=vpc-id,Values=$DNS_VPC"

# Peering donde participa la VPC del DNS (puede ser solicitante o aceptante)
PCXS=$( { aws ec2 describe-vpc-peering-connections --filters "Name=requester-vpc-info.vpc-id,Values=$DNS_VPC" \
            --query "VpcPeeringConnections[?Status.Code!='deleted'].VpcPeeringConnectionId" --output text
          aws ec2 describe-vpc-peering-connections --filters "Name=accepter-vpc-info.vpc-id,Values=$DNS_VPC" \
            --query "VpcPeeringConnections[?Status.Code!='deleted'].VpcPeeringConnectionId" --output text; } \
        | tr '\t' '\n' | grep -v '^$' | sort -u | tr '\n' ' ')

echo "==> Guardando configuracion del DNS en $OUT"
mkdir -p "$OUT"
aws ec2 describe-vpcs --vpc-ids "$DNS_VPC"            > "$OUT/dns-vpc.json"
aws ec2 describe-subnets --filters "$F"               > "$OUT/dns-subnets.json"
aws ec2 describe-route-tables --filters "$F"          > "$OUT/dns-route-tables.json"
aws ec2 describe-security-groups --filters "$F"       > "$OUT/dns-security-groups.json"
aws ec2 describe-network-acls --filters "$F"          > "$OUT/dns-network-acls.json"
aws ec2 describe-instances --filters "$F"             > "$OUT/dns-instancias.json"
aws ec2 describe-vpc-endpoints --filters "$F"         > "$OUT/dns-vpc-endpoints.json"
# shellcheck disable=SC2086
[ -z "$PCXS" ] || aws ec2 describe-vpc-peering-connections --vpc-peering-connection-ids $PCXS > "$OUT/dns-peering.json"

IDS=$(aws ec2 describe-instances --filters "$F" "Name=instance-state-name,Values=pending,running,stopping,stopped" \
      --query "Reservations[].Instances[].InstanceId" --output text)
echo
echo "VPC del DNS: $DNS_VPC ($CIDR)"
echo "Instancias:  ${IDS:-ninguna}"
echo "Peering:     ${PCXS:-ninguno}"
read -r -p "Se borrara SOLO la VPC del DNS interno y su peering. Escribe SI para continuar: " R
[ "$R" = "SI" ] || { echo "Cancelado."; exit 0; }

if [ -n "$IDS" ]; then
  echo "==> Terminando instancias"
  # shellcheck disable=SC2086
  aws ec2 terminate-instances --instance-ids $IDS >/dev/null
  # shellcheck disable=SC2086
  aws ec2 wait instance-terminated --instance-ids $IDS
fi

echo "==> Borrando endpoints de la VPC (S3)"
EPS=$(aws ec2 describe-vpc-endpoints --filters "$F" --query "VpcEndpoints[].VpcEndpointId" --output text)
# shellcheck disable=SC2086
[ -z "$EPS" ] || aws ec2 delete-vpc-endpoints --vpc-endpoint-ids $EPS >/dev/null

for P in $PCXS; do
  echo "==> Quitando las rutas que usan el peering $P (en ambas VPC)"
  for RT in $(aws ec2 describe-route-tables --filters "Name=route.vpc-peering-connection-id,Values=$P" \
              --query "RouteTables[].RouteTableId" --output text); do
    for D in $(aws ec2 describe-route-tables --route-table-ids "$RT" \
               --query "RouteTables[0].Routes[?VpcPeeringConnectionId=='$P'].DestinationCidrBlock" --output text); do
      aws ec2 delete-route --route-table-id "$RT" --destination-cidr-block "$D" && echo "   $RT: ruta $D borrada"
    done
  done
  echo "==> Borrando el peering $P"
  aws ec2 delete-vpc-peering-connection --vpc-peering-connection-id "$P" >/dev/null
done

echo "==> Borrando Internet Gateway (si lo hubiera)"
for IGW in $(aws ec2 describe-internet-gateways --filters "Name=attachment.vpc-id,Values=$DNS_VPC" \
             --query "InternetGateways[].InternetGatewayId" --output text); do
  aws ec2 detach-internet-gateway --internet-gateway-id "$IGW" --vpc-id "$DNS_VPC"
  aws ec2 delete-internet-gateway --internet-gateway-id "$IGW"
done

echo "==> Borrando subredes"
for S in $(aws ec2 describe-subnets --filters "$F" --query "Subnets[].SubnetId" --output text); do
  reintentar aws ec2 delete-subnet --subnet-id "$S"
done

echo "==> Borrando tablas de rutas, Security Groups y NACL propias (las por defecto se van con la VPC)"
for RT in $(aws ec2 describe-route-tables --filters "$F" \
            --query "RouteTables[?!(Associations[?Main==\`true\`])].RouteTableId" --output text); do
  aws ec2 delete-route-table --route-table-id "$RT"
done
for G in $(aws ec2 describe-security-groups --filters "$F" \
           --query "SecurityGroups[?GroupName!='default'].GroupId" --output text); do
  reintentar aws ec2 delete-security-group --group-id "$G"
done
for N in $(aws ec2 describe-network-acls --filters "$F" "Name=default,Values=false" \
           --query "NetworkAcls[].NetworkAclId" --output text); do
  aws ec2 delete-network-acl --network-acl-id "$N"
done

echo "==> Borrando la VPC $DNS_VPC"
reintentar aws ec2 delete-vpc --vpc-id "$DNS_VPC" && echo "==> Listo. La VPC del DNS ya no existe."
echo "Siguiente paso (si tambien se borra todo lo demas): bash limpiar-aws.sh"
