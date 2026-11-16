#!/usr/bin/env bash

# Ejecutar despues de reglas-visitas-fase2.sh.
# Uso:   bash aplicar-hardening-fase2.sh | tee ~/evidencia-aws/hardening-fase2.log
#        SOLO_DNS=1 bash aplicar-hardening-fase2.sh | tee ~/evidencia-aws/hardening-dns.log
#        (la segunda forma solo agrega el SSH desde TI al SG del DNS y endurece vm-dns-fase2)
#
#  1. Nube: cierra puertos innecesarios en los Security Groups
#     - startup-sg (Ventas y Data Center): quita el SSH desde CloudShell/Internet y
#       desde toda la VPC; deja SSH solo desde TI (eice-ti). El ICMP interno se conserva.
#     - intranet-rrhh-sg: quita el SSH desde Ventas (era el salto de la Fase 1).
#     - SG de vm-dns-fase2: agrega SSH desde TI, para que TI pueda administrarla.
#  2. Sistema operativo: copia hardening-fase2.sh a cada VM (/usr/local/sbin), lo
#     ejecuta con el rol que corresponde y confirma con una conexion SSH nueva.
#     Para cada VM queda en el registro: ss -tulpn antes, el cambio y la verificacion.
#
# Todas las VM se acceden por el EC2 Instance Connect Endpoint de TI (eice-ti).
# vm-dns-fase2 esta en otra VPC (peering), asi que se llega saltando por vm-ti-1.
# Como se creo sin key pair, para ella se usa EC2 Instance Connect: en cada conexion
# AWS le deposita una llave temporal (60 s) generada aqui mismo.
# =====================================================================
set -uo pipefail
exec 2>&1
export AWS_PAGER=""
export AWS_DEFAULT_REGION="${REGION:-us-east-1}"
PROJ="proyecto-redes"
KEY="proyecto-key"
CIDR_VENTAS="10.10.0.0/27"
CIDR_TI="10.10.0.32/27"
DIR="$(cd "$(dirname "$0")" && pwd)"
HARD="$DIR/hardening-fase2.sh"
KEYFILE="$HOME/proyecto-key.pem"
SSH_OPTS="-i $KEYFILE -o IdentitiesOnly=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=20 -o LogLevel=ERROR"
OUT="$HOME/evidencia-aws"

attr () {   # $1 = nombre de la instancia, $2 = atributo
  aws ec2 describe-instances \
    --filters "Name=tag:Name,Values=$1" "Name=tag:Project,Values=$PROJ" "Name=instance-state-name,Values=running" \
    --query "Reservations[0].Instances[0].$2" --output text
}
existe () { [ -n "$1" ] && [ "$1" != "None" ]; }
sg_id () { aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$VPC" "Name=group-name,Values=$1" \
             --query "SecurityGroups[0].GroupId" --output text; }
reglas_sg () {   # $1 = id del Security Group
  aws ec2 describe-security-groups --group-ids "$1" \
    --query "SecurityGroups[0].IpPermissions[].[IpProtocol,FromPort,ToPort,join(', ',IpRanges[].CidrIp)]" --output table
}

# SSH a una VM: por instance-id (eice-ti) o, para la VM del DNS, por IP saltando por vm-ti-1
en_vm () {   # $1 = instance-id o IP privada, resto = comando remoto (stdin se envia a la VM)
  local destino=$1 proxy opts=$SSH_OPTS; shift
  if [[ "$destino" == i-* ]]; then
    proxy="aws ec2-instance-connect open-tunnel --instance-id $destino"
  else
    proxy="ssh $SSH_OPTS -o 'ProxyCommand=aws ec2-instance-connect open-tunnel --instance-id $TI_ID' -W %h:%p ec2-user@$TI_ID"
    if [ "$DNS_EIC" = 1 ]; then   # el salto a vm-ti-1 sigue con proyecto-key; el ultimo tramo, con la llave temporal
      aws ec2-instance-connect send-ssh-public-key --instance-id "$DNS_ID" --instance-os-user ec2-user \
        --ssh-public-key "file://$LLAVE_TMP.pub" </dev/null >/dev/null || return 1   # stdin queda para ssh
      opts=${SSH_OPTS/-i $KEYFILE/-i $LLAVE_TMP}
    fi
  fi
  ssh $opts -o "ProxyCommand=$proxy" "ec2-user@$destino" "$@"
}
script_lf () { tr -d '\r' <"$HARD"; }   # por si el repo se copio desde Windows con CRLF

[ -f "$KEYFILE" ] || { echo "Falta $KEYFILE en CloudShell"; exit 1; }
[ -f "$HARD" ]    || { echo "No se encontro $HARD"; exit 1; }
VPC=$(aws ec2 describe-vpcs --filters "Name=tag:Project,Values=$PROJ" --query "Vpcs[0].VpcId" --output text)
existe "$VPC" || { echo "No existe vpc-startup"; exit 1; }
TI_ID=$(attr vm-ti-1 InstanceId)
existe "$TI_ID" || { echo "No hay vm-ti-1 en ejecucion"; exit 1; }

# VM del DNS interno (persona 1): esta en vpc-dns-fase2, se busca por nombre
DNS_ID=$(aws ec2 describe-instances --filters "Name=tag:Name,Values=vm-dns-fase2" "Name=instance-state-name,Values=running" \
         --query "Reservations[0].Instances[0].InstanceId" --output text)
DNS_IP=""; DNS_SG=""; DNS_EIC=0; LLAVE_TMP=""
if existe "$DNS_ID"; then
  read -r DNS_IP DNS_KEY DNS_SG < <(aws ec2 describe-instances --instance-ids "$DNS_ID" \
    --query "Reservations[0].Instances[0].[PrivateIpAddress,KeyName,SecurityGroups[0].GroupId]" --output text)
  if [ "$DNS_KEY" != "$KEY" ]; then
    echo "vm-dns-fase2 no tiene la llave $KEY (KeyName=$DNS_KEY): se entra con EC2 Instance Connect (llave temporal)"
    DNS_EIC=1
    LLAVE_TMP="$(mktemp -d)/dns-eic"
    ssh-keygen -q -t ed25519 -N '' -f "$LLAVE_TMP"
    trap 'rm -rf "$(dirname "$LLAVE_TMP")"' EXIT
  fi
fi
[ "${SOLO_DNS:-0}" != 1 ] || existe "$DNS_ID" || { echo "SOLO_DNS=1 pero no hay vm-dns-fase2 en ejecucion"; exit 1; }

# Security Groups: cerrar puertos innecesarios
echo "##### HARDENING 1: Security Groups (nube)"
SG_STARTUP=$(sg_id startup-sg)
SG_INTRANET=$(sg_id intranet-rrhh-sg)
if [ "${SOLO_DNS:-0}" = 1 ]; then SG_STARTUP=None; SG_INTRANET=None; fi   # ya quedaron listos en la primera corrida

if existe "$SG_STARTUP"; then
  echo "--- startup-sg (vm-ventas-1, vm-ventas-2, vm-datacenter-1) ANTES"
  reglas_sg "$SG_STARTUP"
  # Primero se abre el SSH de TI (para no perder la administracion) y después se quita el resto
  aws ec2 authorize-security-group-ingress --group-id "$SG_STARTUP" --ip-permissions \
    "IpProtocol=tcp,FromPort=22,ToPort=22,IpRanges=[{CidrIp=${CIDR_TI},Description=ssh-admin-ti-y-eice}]" >/dev/null 2>&1 || true
  for C in $(aws ec2 describe-security-groups --group-ids "$SG_STARTUP" \
             --query "SecurityGroups[0].IpPermissions[?IpProtocol=='tcp' && FromPort==\`22\`].IpRanges[].CidrIp" --output text); do
    [ "$C" = "$CIDR_TI" ] && continue
    aws ec2 revoke-security-group-ingress --group-id "$SG_STARTUP" --protocol tcp --port 22 --cidr "$C" >/dev/null \
      && echo "   cerrado: TCP 22 desde $C"
  done
  echo "--- startup-sg DESPUES"
  reglas_sg "$SG_STARTUP"
fi

if existe "$SG_INTRANET"; then
  echo "--- intranet-rrhh-sg ANTES"
  reglas_sg "$SG_INTRANET"
  aws ec2 revoke-security-group-ingress --group-id "$SG_INTRANET" --protocol tcp --port 22 --cidr "$CIDR_VENTAS" >/dev/null 2>&1 \
    && echo "   cerrado: TCP 22 desde Ventas ($CIDR_VENTAS); la intranet se administra desde TI"
  echo "--- intranet-rrhh-sg DESPUES"
  reglas_sg "$SG_INTRANET"
fi

if [ -n "$DNS_IP" ] && existe "$DNS_SG"; then
  echo "--- SG de vm-dns-fase2 ($DNS_SG): se agrega SSH desde TI"
  aws ec2 authorize-security-group-ingress --group-id "$DNS_SG" --ip-permissions \
    "IpProtocol=tcp,FromPort=22,ToPort=22,IpRanges=[{CidrIp=${CIDR_TI},Description=ssh-admin-ti}]" >/dev/null 2>&1 || true
  reglas_sg "$DNS_SG"
fi

mkdir -p "$OUT"
GRUPOS=$(printf '%s ' "$SG_STARTUP" "$SG_INTRANET" "$DNS_SG" | tr -s ' ' | sed 's/None//g')
# shellcheck disable=SC2086
JSON=hardening-security-groups.json
[ "${SOLO_DNS:-0}" = 1 ] && JSON=hardening-dns-security-group.json   # no sobrescribe la evidencia de la primera corrida
aws ec2 describe-security-groups --group-ids $GRUPOS > "$OUT/$JSON" 2>/dev/null || true

#  2. Hardening del sistema operativo en cada VM 
OK_VMS=""; FALLAS_VMS=""
endurecer () {   # $1 = nombre, $2 = rol, $3 = instance-id o IP
  local nombre=$1 rol=$2 destino=$3
  echo
  echo "##### HARDENING: $nombre (rol $rol)"
  echo "----- ANTES"
  if ! script_lf | en_vm "$destino" "sudo bash -s -- --estado $rol"; then
    echo "No se pudo entrar a $nombre; se omite"
    FALLAS_VMS="$FALLAS_VMS $nombre"; return
  fi
  echo "----- APLICANDO"
  if ! script_lf | en_vm "$destino" "cat >/tmp/hardening-fase2.sh && sudo install -m 0750 /tmp/hardening-fase2.sh /usr/local/sbin/hardening-fase2.sh && sudo bash /usr/local/sbin/hardening-fase2.sh $rol"; then
    echo "El hardening fallo en $nombre (si la conexion se corto, la VM se revierte sola en 5 minutos)"
    FALLAS_VMS="$FALLAS_VMS $nombre"; return
  fi
  echo "----- CONFIRMANDO con una conexion SSH nueva"
  if ! en_vm "$destino" "sudo bash /usr/local/sbin/hardening-fase2.sh --confirmar" </dev/null; then
    echo "No se pudo volver a entrar a $nombre: la reversion automatica la dejara como estaba en 5 minutos"
    FALLAS_VMS="$FALLAS_VMS $nombre"; return
  fi
  echo "----- DESPUES (verificacion)"
  en_vm "$destino" "sudo bash /usr/local/sbin/hardening-fase2.sh --verificar $rol" </dev/null
  OK_VMS="$OK_VMS $nombre"
}

# TI va al final: si algo saliera mal ahi, las demas ya quedaron listas.
# La VM del DNS va antes que TI porque se llega a ella saltando por vm-ti-1.
VMS="vm-dmz-web:dmz vm-intranet-rrhh:intranet vm-datacenter-1:datacenter vm-visitas-1:visitas vm-ventas-2:ventas vm-ventas-1:ventas"
[ "${SOLO_DNS:-0}" = 1 ] && VMS=""
for par in $VMS; do
  nombre=${par%%:*}; rol=${par##*:}
  id=$(attr "$nombre" InstanceId)
  if existe "$id"; then endurecer "$nombre" "$rol" "$id"; else echo; echo "##### $nombre no esta en ejecucion; se omite"; fi
done
if [ -n "$DNS_IP" ]; then
  endurecer vm-dns-fase2 dns "$DNS_IP"
else
  echo; echo "##### vm-dns-fase2 no esta en ejecucion; se omite"
fi
[ "${SOLO_DNS:-0}" = 1 ] || endurecer vm-ti-1 ti "$TI_ID"

echo
echo "==> Hardening aplicado en:${OK_VMS:- ninguna}"
[ -z "$FALLAS_VMS" ] || echo "==> Revisar:$FALLAS_VMS"
echo "Siguiente paso: bash escanear-puertos-fase2.sh despues && bash pruebas-visitas-hardening-fase2.sh | tee $OUT/pruebas-visitas-hardening-fase2.log"
