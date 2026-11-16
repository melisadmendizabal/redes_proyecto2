#!/usr/bin/env bash

# CC3067 Redes - Proyecto Final Fase 2 - Hardening del sistema operativo
# Se ejecuta como root dentro de cada VM. 
# aplicar-hardening-fase2.sh lo envia por SSH (a traves de eice-ti) a todas las VM.
#
# Uso:  sudo bash hardening-fase2.sh [rol]               aplica el hardening
#       sudo bash hardening-fase2.sh --confirmar         cancela la reversion automatica
#       sudo bash hardening-fase2.sh --verificar [rol]   comprueba que todo quedo aplicado
#       sudo bash hardening-fase2.sh --estado [rol]      muestra puertos, SSH y firewall
#       sudo bash hardening-fase2.sh --revertir          deshace el firewall y la config SSH
#   rol = ventas | ti | datacenter | intranet | visitas | dmz | dns
#         (si se omite, se deduce de la IP privada de la VM)
#
# Que hace:
#  1. Kernel (sysctl): sin redirects ni source routing, SYN cookies, log de martians.
#  2. Servicios: deshabilita servicios de red que no se usan (si estan instalados),
#     apaga LLMNR/mDNS de systemd-resolved y el puerto UDP de control de chronyd.
#  3. SSH: solo llave publica, sin root, sin contraseñas, 3 intentos, solo IPv4,
#     solo ec2-user, sin X11 ni reenvio de puertos (salvo TI, que hace de bastion).
#  4. Firewall del SO (nftables): entrada DROP por defecto. Solo se aceptan los
#     puertos del rol, desde los mismos origenes que permite su Security Group.
#     Visitas y la DMZ ademas no pueden iniciar conexiones hacia redes privadas.
#  Antes de tocar SSH y el firewall se programa una reversion automatica: si no se
#  confirma con una conexion SSH nueva en 5 minutos, se deshace sola
# =====================================================================
set -euo pipefail
export LC_ALL=C

# Direccionamiento 
CIDR_VPC="10.10.0.0/24"          # Ventas, TI, Visitas, Data Center y DMZ
CIDR_VENTAS="10.10.0.0/27"
CIDR_TI="10.10.0.32/27"          # administracion: vm-ti-1 y el endpoint eice-ti
CIDR_DC="10.10.0.96/28"
IP_INTRANET="10.10.0.101"
DNS_AWS="10.10.0.2"              # resolvedor de AWS en vpc-startup (base de la VPC + 2)
ESPERA="${ESPERA:-300}"          # segundos antes de revertir si no se confirma

NFT_FILE=/etc/nftables/redes-hardening.nft
SSHD_FILE=/etc/ssh/sshd_config.d/00-redes-hardening.conf
SYSCTL_FILE=/etc/sysctl.d/90-redes-hardening.conf
RESOLVED_FILE=/etc/systemd/resolved.conf.d/95-redes-hardening.conf
BANNER_FILE=/etc/ssh/redes-banner.txt
REVERTIR=/usr/local/sbin/redes-hardening-revertir.sh
TIMER=redes-hardening-revertir
SERVICIOS_INNECESARIOS="rpcbind.socket rpcbind.service avahi-daemon.socket avahi-daemon.service
  cups.socket cups.service postfix.service sendmail.service telnet.socket vsftpd.service
  nfs-server.service rpc-statd.service cockpit.socket xinetd.service"

con_systemd () { [ -d /run/systemd/system ]; }

ip_privada () {
  { hostname -I 2>/dev/null || ip -4 -o addr show scope global 2>/dev/null | awk '{sub("/.*","",$4); print $4}'; } \
    | tr ' ' '\n' | grep -E '^10\.10\.' | head -1 || true
}

deducir_rol () {   # por la IP privada: 10.10.1.x = VPC del DNS; en 10.10.0.0/24 segun la subred
  local ip o3 o4
  ip=$(ip_privada)
  [ -n "$ip" ] || return 0
  IFS=. read -r _ _ o3 o4 <<<"$ip"
  if   [ "$o3" = 1 ];               then echo dns
  elif [ "$ip" = "$IP_INTRANET" ];  then echo intranet
  elif [ "$o4" -lt 32 ];            then echo ventas
  elif [ "$o4" -lt 64 ];            then echo ti
  elif [ "$o4" -lt 96 ];            then echo visitas
  elif [ "$o4" -lt 112 ];           then echo datacenter
  elif [ "$o4" -lt 128 ];           then echo dmz
  fi
}

#  Reglas por rol 
# ENTRADA      : reglas nft extra de la cadena de entrada (el SSH desde TI es comun a todas)
# SALIDA       : reglas nft de la cadena de salida (vacio = sale todo; lo filtra el SG/NACL)
# PUERTOS_OK   : sockets que pueden escuchar fuera de localhost (se revisa con ss)
# REENVIO_SSH  : AllowTcpForwarding (solo TI, para saltar a la VM del DNS en la otra VPC)
configurar_rol () {
  REENVIO_SSH=no
  SALIDA=""
  PUERTOS_OK="tcp:22 udp:68 udp:546"   # sshd y los clientes DHCP/DHCPv6 de systemd-networkd
  local ping_ti="ip saddr $CIDR_TI icmp type echo-request accept comment \"ping desde TI\""
  local ping_vpc="ip saddr $CIDR_VPC icmp type echo-request accept comment \"ping desde la red interna\""
  # Visitas y DMZ: solo pueden iniciar conexiones hacia Internet (lo que ya esta permitido vuelve por established)
  local solo_internet="ct state established,related accept
oif \"lo\" accept
udp dport 67 accept comment \"DHCP de AWS\"
ip daddr { $DNS_AWS, 169.254.169.253 } meta l4proto { tcp, udp } th dport 53 accept comment \"DNS de AWS\"
ip daddr { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16 } counter reject with icmpx type admin-prohibited comment \"no iniciar nada hacia redes privadas\""

  case "$ROL" in
    ventas|datacenter)
      ENTRADA="$ping_vpc" ;;
    ti)
      ENTRADA="$ping_ti"
      REENVIO_SSH=yes ;;
    intranet)
      ENTRADA="ip saddr { $CIDR_VENTAS, $CIDR_TI, $CIDR_DC } tcp dport 80 accept comment \"intranet RRHH: Ventas, TI y Data Center\"
$ping_ti"
      PUERTOS_OK="$PUERTOS_OK tcp:80" ;;
    visitas)
      ENTRADA="$ping_ti"
      SALIDA="$solo_internet" ;;
    dmz)
      ENTRADA="tcp dport { 80, 443 } accept comment \"web publica: HTTP (redireccion y ACME) y HTTPS\"
$ping_ti"
      SALIDA="$solo_internet"
      PUERTOS_OK="$PUERTOS_OK tcp:80 tcp:443" ;;
    dns)
      ENTRADA="ip saddr { $CIDR_VENTAS, $CIDR_TI } udp dport 53 accept comment \"DNS interno: Ventas y TI\"
ip saddr { $CIDR_VENTAS, $CIDR_TI } tcp dport 53 accept comment \"DNS interno por TCP\"
$ping_ti"
      PUERTOS_OK="$PUERTOS_OK tcp:53 udp:53" ;;
    *)
      echo "Rol desconocido: '${ROL}'. Usa: ventas | ti | datacenter | intranet | visitas | dmz | dns"
      exit 2 ;;
  esac
}

sangrar () { sed 's/^/        /'; }

ruleset () {   # firewall del SO; la primera linea + delete hacen que volver a aplicarlo sea idempotente
  cat <<EOF
# Generado por hardening-fase2.sh (rol: $ROL). Firewall del sistema operativo.
table inet redes_hardening
delete table inet redes_hardening
table inet redes_hardening {
    chain entrada {
        type filter hook input priority filter; policy drop;
        iif "lo" accept comment "trafico local"
        ct state established,related accept comment "respuestas a conexiones permitidas"
        ct state invalid drop
        udp sport 67 udp dport 68 accept comment "DHCP de AWS"
        udp sport 547 udp dport 546 accept comment "DHCPv6"
        meta l4proto ipv6-icmp accept comment "ICMPv6 (descubrimiento de vecinos)"
        icmp type { destination-unreachable, time-exceeded, parameter-problem } accept comment "errores ICMP y Path MTU"
        ip saddr $CIDR_TI tcp dport 22 accept comment "SSH solo desde TI (incluye eice-ti)"
$(printf '%s\n' "$ENTRADA" | sangrar)
        limit rate 10/minute log prefix "redes-hardening-drop: " level info
        counter drop comment "todo lo demas se descarta"
    }
    chain reenvio {
        type filter hook forward priority filter; policy drop;
    }
    chain salida {
        type filter hook output priority filter; policy accept;
$( [ -n "$SALIDA" ] && printf '%s\n' "$SALIDA" | sangrar )
    }
}
EOF
}

sshd_config () {
  cat <<EOF
# Generado por hardening-fase2.sh (rol: $ROL).
# Se llama 00-... para cargarse antes que 50-redhat.conf: en sshd gana el primer valor leido.
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitEmptyPasswords no
PubkeyAuthentication yes
AuthenticationMethods publickey
MaxAuthTries 3
MaxSessions 4
LoginGraceTime 30
ClientAliveInterval 300
ClientAliveCountMax 2
X11Forwarding no
AllowAgentForwarding no
AllowTcpForwarding $REENVIO_SSH
PermitTunnel no
AllowUsers ec2-user
AddressFamily inet
Banner $BANNER_FILE
EOF
}

sysctl_config () {
  cat <<'EOF'
# Generado por hardening-fase2.sh: la VM no enruta ni acepta rutas inyectadas
net.ipv4.ip_forward = 0
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv4.conf.all.log_martians = 1
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
net.ipv4.tcp_syncookies = 1
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
EOF
}

nft_conf_sistema () {   # archivo que nftables.service carga al arrancar
  local f=""
  if con_systemd; then
    f=$(systemctl cat nftables.service 2>/dev/null | sed -n 's/^ExecStart=.* -f *\([^ ;"]*\).*/\1/p' | head -1)
  fi
  echo "${f:-/etc/sysconfig/nftables.conf}"
}

escribir_revertir () {
  local conf; conf=$(nft_conf_sistema)
  mkdir -p "$(dirname "$REVERTIR")"
  cat >"$REVERTIR" <<EOF
#!/bin/bash
# Deshace el firewall del SO y la configuracion SSH de hardening-fase2.sh
nft delete table inet redes_hardening 2>/dev/null || true
sed -i '\#include "$NFT_FILE"#d' "$conf" 2>/dev/null || true
rm -f "$SSHD_FILE"
systemctl reload sshd 2>/dev/null || true
logger -t redes-hardening "hardening revertido: firewall del SO y SSH vuelven a su estado anterior" 2>/dev/null || true
echo "Hardening revertido (firewall del SO y SSH)"
EOF
  chmod 0700 "$REVERTIR"
}

estado () {
  echo "--- $(hostname) | IP $(ip_privada) | rol $ROL"
  echo "--- Puertos en escucha (ss -tulpn)"
  ss -tulpn
  echo "--- SSH efectivo (sshd -T)"
  sshd -T 2>/dev/null | grep -E '^(permitrootlogin|passwordauthentication|kbdinteractiveauthentication|authenticationmethods|maxauthtries|logingracetime|x11forwarding|allowtcpforwarding|allowagentforwarding|addressfamily|allowusers) ' || true
  echo "--- Firewall del sistema operativo (nft list table inet redes_hardening)"
  nft list table inet redes_hardening 2>/dev/null || echo "Sin tabla redes_hardening: el sistema operativo no filtra nada"
}

# ---------------------------------------------------------------------
aplicar () {
  echo "==> Hardening de $(hostname) ($(ip_privada)) con el rol: $ROL"

  echo "==> 1. Kernel (sysctl)"
  mkdir -p "$(dirname "$SYSCTL_FILE")"
  sysctl_config >"$SYSCTL_FILE"
  sysctl -q -p "$SYSCTL_FILE" || echo "   aviso: algunos parametros no se pudieron aplicar en este entorno"

  echo "==> 2. Servicios de red innecesarios"
  if con_systemd; then
    for u in $SERVICIOS_INNECESARIOS; do
      if systemctl list-unit-files --no-legend "$u" 2>/dev/null | grep -q .; then
        systemctl disable --now "$u" >/dev/null 2>&1 && echo "   deshabilitado: $u"
      fi
    done
    if systemctl is-active --quiet systemd-resolved; then
      mkdir -p "$(dirname "$RESOLVED_FILE")"
      printf '# Generado por hardening-fase2.sh: sin resolucion por multicast (puerto 5355)\n[Resolve]\nLLMNR=no\nMulticastDNS=no\n' >"$RESOLVED_FILE"
      systemctl restart systemd-resolved && echo "   systemd-resolved: LLMNR y mDNS apagados (se conserva la config del DNS interno)"
    fi
  fi
  if [ -f /etc/chrony.conf ] && ! grep -qE '^[[:space:]]*cmdport[[:space:]]+0' /etc/chrony.conf; then
    printf '# hardening-fase2.sh: sin puerto UDP 323 de control; chronyc sigue usando el socket local\ncmdport 0\n' >>/etc/chrony.conf
    if con_systemd; then systemctl restart chronyd; fi
    echo "   chronyd: puerto de control 323 cerrado"
  fi

  echo "==> 3. Firewall del SO: paquete nftables"
  command -v nft >/dev/null || dnf install -y -q nftables
  mkdir -p "$(dirname "$NFT_FILE")"
  ruleset >"$NFT_FILE.nuevo"
  nft -c -f "$NFT_FILE.nuevo"            # valida la sintaxis antes de tocar nada
  mv "$NFT_FILE.nuevo" "$NFT_FILE"

  # Red de seguridad: si la nueva config deja la VM inaccesible, se revierte sola
  escribir_revertir
  if con_systemd; then
    systemctl stop "$TIMER.timer" >/dev/null 2>&1 || true
    systemctl reset-failed "$TIMER.service" >/dev/null 2>&1 || true
    systemd-run --quiet --collect --unit="$TIMER" --on-active="${ESPERA}s" /bin/bash "$REVERTIR"
    echo "==> Reversion automatica programada en ${ESPERA}s (se cancela con --confirmar)"
  fi

  echo "==> 4. SSH"
  printf 'Acceso restringido al personal de TI de Mansion del Disfraz. La actividad se registra.\n' >"$BANNER_FILE"
  sshd_config >"$SSHD_FILE"
  chmod 0600 "$SSHD_FILE"
  if ! sshd -t; then
    rm -f "$SSHD_FILE"
    echo "La configuracion de sshd no es valida; se dejo la anterior"
    exit 1
  fi
  # reload no corta las sesiones abiertas; sin systemd (contenedor de prueba) se avisa al proceso principal
  if con_systemd; then systemctl reload sshd
  elif [ -s /run/sshd.pid ]; then kill -HUP "$(cat /run/sshd.pid)"; fi

  echo "==> 5. Firewall del SO: cargar reglas y dejarlas persistentes"
  nft -f "$NFT_FILE"
  local conf; conf=$(nft_conf_sistema)
  mkdir -p "$(dirname "$conf")"
  touch "$conf"
  [ -e "$conf.redes-original" ] || cp -p "$conf" "$conf.redes-original"
  grep -qF "include \"$NFT_FILE\"" "$conf" || echo "include \"$NFT_FILE\"" >>"$conf"
  if con_systemd; then systemctl enable --quiet nftables; fi

  echo
  estado
  echo
  echo "Hardening aplicado. Confirmar desde una conexion SSH NUEVA: sudo bash hardening-fase2.sh --confirmar"
}

confirmar () {
  if con_systemd && systemctl is-active --quiet "$TIMER.timer"; then
    systemctl stop "$TIMER.timer"
    echo "==> Hardening confirmado en $(hostname): la reversion automatica se cancelo"
  else
    echo "==> No habia reversion pendiente en $(hostname)"
  fi
}

verificar () {
  local fallas=0
  chequear () {   # $1 = descripcion, resto = comando que debe salir con 0
    if "${@:2}" >/dev/null 2>&1; then echo "  OK     $1"; else echo "  FALLA  $1"; fallas=$((fallas + 1)); fi
  }
  sshd_val () { sshd -T 2>/dev/null | awk -v k="$1" '$1 == k {print $2; exit}'; }
  igual () { [ "$1" = "$2" ]; }
  sysctl_es () { igual "$(sysctl -n "$1" 2>/dev/null)" "$2"; }

  echo "--- Verificacion de hardening en $(hostname) ($(ip_privada)), rol $ROL"
  chequear "SSH: sin login de root"                 igual "$(sshd_val permitrootlogin)" no
  chequear "SSH: sin contrasenas"                   igual "$(sshd_val passwordauthentication)" no
  chequear "SSH: sin keyboard-interactive"          igual "$(sshd_val kbdinteractiveauthentication)" no
  chequear "SSH: solo llave publica"                igual "$(sshd_val authenticationmethods)" publickey
  chequear "SSH: maximo 3 intentos"                 igual "$(sshd_val maxauthtries)" 3
  chequear "SSH: sin X11"                           igual "$(sshd_val x11forwarding)" no
  chequear "SSH: reenvio de puertos = $REENVIO_SSH" igual "$(sshd_val allowtcpforwarding)" "$REENVIO_SSH"
  chequear "SSH: solo ec2-user"                     igual "$(sshd_val allowusers)" ec2-user
  chequear "SSH: solo IPv4"                         igual "$(sshd_val addressfamily)" inet
  chequear "nft: tabla redes_hardening cargada"     nft list table inet redes_hardening
  chequear "nft: politica de entrada DROP"          sh -c 'nft list chain inet redes_hardening entrada | grep -q "policy drop"'
  if [ -n "$SALIDA" ]; then
    chequear "nft: salida hacia redes privadas bloqueada" sh -c 'nft list chain inet redes_hardening salida | grep -q "10.0.0.0/8"'
  fi
  chequear "sysctl: sin ICMP redirects"             sysctl_es net.ipv4.conf.all.accept_redirects 0
  chequear "sysctl: sin source routing"             sysctl_es net.ipv4.conf.all.accept_source_route 0
  chequear "sysctl: SYN cookies"                    sysctl_es net.ipv4.tcp_syncookies 1
  if con_systemd; then
    chequear "nftables se carga al arrancar"        systemctl is-enabled --quiet nftables
    chequear "hardening confirmado (sin reversion pendiente)" sh -c "! systemctl is-active --quiet $TIMER.timer"
    local activos=""
    for u in $SERVICIOS_INNECESARIOS; do systemctl is-active --quiet "$u" && activos="$activos $u"; done
    chequear "servicios innecesarios apagados${activos:+ (activos:$activos)}" igual "$activos" ""
  else
    echo "  --     comprobaciones de systemd omitidas (no hay systemd en este entorno)"
  fi

  # Sockets que escuchan fuera de localhost y no son del rol
  local escuchando inesperados
  escuchando=$(ss -Htuln | awk '{print $1, $5}' | while read -r proto local; do
                 addr=${local%:*}; port=${local##*:}
                 case "$addr" in 127.*|"[::1]"|::1|*%lo) continue ;; esac
                 echo "$proto:$port"
               done | sort -u)
  inesperados=$(printf '%s\n' "$escuchando" | grep -vxF -f <(printf '%s\n' $PUERTOS_OK) | grep . | tr '\n' ' ' || true)
  chequear "solo escuchan puertos del rol ($PUERTOS_OK)${inesperados:+ - sobran: $inesperados}" igual "$inesperados" ""
  chequear "sshd no escucha en IPv6" sh -c "! ss -Htln | awk '{print \$4}' | grep -q '^\[::\]:22\$'"

  if [ "$fallas" -eq 0 ]; then
    echo "RESULTADO: hardening completo ESTADO=CUMPLE"
  else
    echo "RESULTADO: $fallas comprobaciones fallaron ESTADO=NO_CUMPLE"
  fi
}

# ---------------------------------------------------------------------
[ "$(id -u)" = 0 ] || { echo "Ejecutar como root: sudo bash $0 $*"; exit 1; }

MODO=aplicar
case "${1:-}" in
  --confirmar) MODO=confirmar; shift ;;
  --verificar) MODO=verificar; shift ;;
  --estado)    MODO=estado;    shift ;;
  --revertir)  MODO=revertir;  shift ;;
esac
ROL="${1:-$(deducir_rol)}"

case "$MODO" in
  confirmar) confirmar ;;
  revertir)  escribir_revertir; bash "$REVERTIR"; systemctl stop "$TIMER.timer" >/dev/null 2>&1 || true ;;
  estado)    estado ;;
  verificar) configurar_rol; verificar ;;
  aplicar)   configurar_rol; aplicar ;;
esac
