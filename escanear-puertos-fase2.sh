#!/usr/bin/env bash

# Evidencia "antes y despues" del hardening, vista desde la red:
#   - Internet (CloudShell) -> IP publicas de Ventas, Visitas y la web de la DMZ
#   - vm-ventas-1, vm-visitas-1 y vm-ti-1 -> IP privadas de todas las VM y el DNS
# Ejecutar en CloudShell:
#   bash escanear-puertos-fase2.sh antes      (antes de reglas-visitas y del hardening)
#   bash escanear-puertos-fase2.sh despues    (al terminar aplicar-hardening-fase2.sh)
# El registro queda en ~/evidencia-aws/puertos-<etiqueta>.log
# =====================================================================
set -uo pipefail
export AWS_PAGER=""
export AWS_DEFAULT_REGION="${REGION:-us-east-1}"
PROJ="proyecto-redes"
ETQ="${1:-antes}"
PUERTOS="22,53,80,111,443,953,3306,5355,8080"   # SSH, DNS, web, rpcbind, rndc, MySQL, LLMNR, web alterno
DNS_INTERNO="10.10.1.4"
KEYFILE="$HOME/proyecto-key.pem"
SSH_OPTS="-i $KEYFILE -o IdentitiesOnly=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=20 -o LogLevel=ERROR"
OUT="$HOME/evidencia-aws"
mkdir -p "$OUT"
exec > >(tee "$OUT/puertos-$ETQ.log") 2>&1

attr () {
  aws ec2 describe-instances \
    --filters "Name=tag:Name,Values=$1" "Name=tag:Project,Values=$PROJ" "Name=instance-state-name,Values=running" \
    --query "Reservations[0].Instances[0].$2" --output text
}
existe () { [ -n "$1" ] && [ "$1" != "None" ]; }
solo_existentes () { for x in "$@"; do existe "$x" && printf '%s ' "$x"; done; }

# Escaneo TCP connect (-sT, no necesita root). Si no hay nmap ni se puede instalar, prueba con /dev/tcp.
escaneo () {   # imprime el comando que escanea las IP de $@
  cat <<EOF
command -v nmap >/dev/null 2>&1 || sudo dnf install -y -q nmap >/dev/null 2>&1
if command -v nmap >/dev/null 2>&1; then
  nmap -Pn -sT -n -p $PUERTOS --max-retries 1 --host-timeout 120s $*
else
  echo "(nmap no disponible: prueba TCP con /dev/tcp)"
  for ip in $*; do for p in ${PUERTOS//,/ }; do
    timeout 3 bash -c "</dev/tcp/\$ip/\$p" 2>/dev/null && echo "\$ip \$p/tcp open" || echo "\$ip \$p/tcp filtered/closed"
  done; done
fi
EOF
}
desde_vm () {   # $1 = titulo, $2 = instance-id, resto = IP a escanear
  local titulo=$1 id=$2; shift 2
  echo; echo "##### PUERTOS ($ETQ): $titulo"
  ssh $SSH_OPTS -o "ProxyCommand=aws ec2-instance-connect open-tunnel --instance-id $id" ec2-user@"$id" \
    "echo \"origen: \$(hostname) \$(hostname -I)\"; $(escaneo "$@")"
}

[ -f "$KEYFILE" ] || { echo "Falta $KEYFILE en CloudShell"; exit 1; }

V1_ID=$(attr vm-ventas-1 InstanceId);  V1_PRIV=$(attr vm-ventas-1 PrivateIpAddress);  V1_PUB=$(attr vm-ventas-1 PublicIpAddress)
V2_PRIV=$(attr vm-ventas-2 PrivateIpAddress);  V2_PUB=$(attr vm-ventas-2 PublicIpAddress)
TI_ID=$(attr vm-ti-1 InstanceId);      TI_PRIV=$(attr vm-ti-1 PrivateIpAddress)
VV_ID=$(attr vm-visitas-1 InstanceId); VV_PRIV=$(attr vm-visitas-1 PrivateIpAddress); VV_PUB=$(attr vm-visitas-1 PublicIpAddress)
DC_PRIV=$(attr vm-datacenter-1 PrivateIpAddress)
IN_PRIV=$(attr vm-intranet-rrhh PrivateIpAddress)
DMZ_PRIV=$(attr vm-dmz-web PrivateIpAddress); DMZ_PUB=$(attr vm-dmz-web PublicIpAddress)

echo "Escaneo '$ETQ' - $(date -u '+%Y-%m-%d %H:%M UTC') - puertos TCP $PUERTOS"
echo "Publicas: vm-ventas-1 $V1_PUB | vm-ventas-2 $V2_PUB | vm-visitas-1 $VV_PUB | vm-dmz-web $DMZ_PUB"
echo "Privadas: ventas-1 $V1_PRIV | ventas-2 $V2_PRIV | ti-1 $TI_PRIV | visitas-1 $VV_PRIV | datacenter-1 $DC_PRIV | intranet $IN_PRIV | dmz $DMZ_PRIV | dns $DNS_INTERNO"

# Desde Internet 
echo; echo "##### PUERTOS ($ETQ): Internet (CloudShell $(curl -s https://checkip.amazonaws.com)) -> IP publicas"
PUBLICAS=$(solo_existentes "$V1_PUB" "$V2_PUB" "$VV_PUB" "$DMZ_PUB")
# shellcheck disable=SC2086
bash -c "$(escaneo $PUBLICAS)"

# Desde la red interna 
PRIVADAS=$(solo_existentes "$V1_PRIV" "$V2_PRIV" "$TI_PRIV" "$VV_PRIV" "$DC_PRIV" "$IN_PRIV" "$DMZ_PRIV" "$DNS_INTERNO")
# shellcheck disable=SC2086
existe "$V1_ID" && desde_vm "vm-ventas-1 (Ventas) -> red interna" "$V1_ID" $PRIVADAS
# shellcheck disable=SC2086
existe "$VV_ID" && desde_vm "vm-visitas-1 (Visitas) -> red interna" "$VV_ID" $PRIVADAS
# shellcheck disable=SC2086
existe "$TI_ID" && desde_vm "vm-ti-1 (TI, administracion) -> red interna" "$TI_ID" $PRIVADAS
echo; echo "Registro guardado en $OUT/puertos-$ETQ.log"
