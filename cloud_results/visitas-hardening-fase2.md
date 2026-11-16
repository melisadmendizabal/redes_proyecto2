# Visitas y hardening — Fase 2

Región `us-east-1`, VPC `vpc-startup` (`10.10.0.0/24`). Esta parte cubre dos requisitos del enunciado:

- La subred de visitantes tiene acceso a Internet, pero no a las subredes internas.
- Hardening básico: cerrar y bloquear los puertos innecesarios en todas las instancias.

## Archivos

| Archivo | Dónde se ejecuta | Para qué sirve |
|---|---|---|
| `reglas-visitas-fase2.sh` | CloudShell | Crea `visitas-sg` y `nacl-visitas`, asocia la NACL a `snet-visitas` y cambia el grupo de `vm-visitas-1`. Exporta `visitas-*.json`. |
| `hardening-fase2.sh` | Dentro de cada VM (root) | Endurece el sistema operativo según el rol: SSH, firewall `nftables`, servicios y `sysctl`. También tiene los modos `--verificar`, `--estado`, `--confirmar` y `--revertir`. |
| `aplicar-hardening-fase2.sh` | CloudShell | Cierra puertos en los Security Groups y aplica `hardening-fase2.sh` a las 8 VM por `eice-ti`. Registra el estado antes y después de cada una. |
| `escanear-puertos-fase2.sh` | CloudShell | Escanea con `nmap` desde Internet, Ventas, Visitas y TI. Se corre con `antes` y con `despues`. |
| `pruebas-visitas-hardening-fase2.sh` | CloudShell | 36 pruebas con resultado esperado; cada una marca `OK` o `FALLO` y al final se imprime el total. |
| `limpiar-dns-fase2.sh` | CloudShell | Borra `vpc-dns-fase2`, la VM del DNS y el peering. Ningún otro script los borraba. |

Orden de ejecución en CloudShell (el repositorio ya clonado en `~/redes_proyecto2`):

```bash
cd ~/redes_proyecto2
bash escanear-puertos-fase2.sh antes                     # nmap ANTES (queda en ~/evidencia-aws/puertos-antes.log)
bash reglas-visitas-fase2.sh
SOLO_VISITAS=1 bash pruebas-visitas-hardening-fase2.sh | tee ~/evidencia-aws/pruebas-visitas-nacl.log
bash aplicar-hardening-fase2.sh | tee ~/evidencia-aws/hardening-fase2.log
bash escanear-puertos-fase2.sh despues                   # nmap DESPUES
bash pruebas-visitas-hardening-fase2.sh | tee ~/evidencia-aws/pruebas-visitas-hardening-fase2.log
# regresion: las partes 2, 3 y 4 siguen funcionando
bash pruebas-reglas-fase2.sh   | tee ~/evidencia-aws/pruebas-reglas-fase2-final.log
bash pruebas-intranet-fase2.sh | tee ~/evidencia-aws/pruebas-intranet-fase2-final.log
bash pruebas-dmz-fase2.sh mansiondeldisfraz.duckdns.org | tee ~/evidencia-aws/pruebas-dmz-fase2-final.log
```

`SOLO_VISITAS=1` corre solo las pruebas de Visitas, antes de que exista el firewall del SO. Así la captura muestra que la nube bloquea por sí sola: los intentos terminan en *timeout* y `100% packet loss`. Después del hardening, la VM rechaza el tráfico antes de que salga de la VM: `ping` muestra `Packet filtered` y la conexión TCP falla al instante. Son dos capas distintas y conviene mostrar las dos.

## 1. Visitas: solo Internet

### Qué había antes

`vm-visitas-1` usaba `startup-sg`, que acepta SSH desde CloudShell y SSH e ICMP de toda la VPC. `snet-visitas` usaba la NACL por defecto, que permite todo. El aislamiento dependía de que cada destino bloqueara a Visitas: la regla 50 de `nacl-internas`, `nacl-ti` y la regla 190 de `nacl-dmz`. Visitas en sí no tenía ninguna restricción de salida.

### Security Group `visitas-sg` (con estado, asignado a `vm-visitas-1`)

| Dirección | Protocolo | Puerto | Origen/destino | Motivo |
|---|---|---|---|---|
| Entrada | TCP | 22 | `10.10.0.32/27` TI | Administración por `eice-ti` |
| Entrada | ICMP | todos | `10.10.0.32/27` TI | Ping desde TI |
| Salida | Todos | todos | `0.0.0.0/0` | Regla por defecto. Lo privado lo corta la NACL |

Un Security Group solo tiene reglas `allow`. Por eso no puede expresar "todo menos las redes privadas". Esa regla va en la NACL, que sí tiene `deny`.

### Network ACL `nacl-visitas` (sin estado, asociada a `snet-visitas`)

| Regla | Dirección | Acción | Protocolo | Origen/destino | Puertos | Motivo |
|---|---|---|---|---|---|---|
| 100 | Entrada | allow | todos | `10.10.0.32/27` TI | — | TI llega a todas las subredes |
| 190 | Entrada | **deny** | todos | `10.0.0.0/8` | — | Nada de la red interna (VPC, DMZ por IP privada, VPC del DNS) |
| 200 | Entrada | **deny** | todos | `172.16.0.0/12` | — | Resto de RFC 1918 |
| 210 | Entrada | **deny** | todos | `192.168.0.0/16` | — | Resto de RFC 1918 |
| 300 | Entrada | allow | TCP | `0.0.0.0/0` | 1024-65535 | Respuestas TCP de Internet |
| 310 | Entrada | allow | UDP | `0.0.0.0/0` | 1024-65535 | Respuestas UDP (QUIC, NTP públicos) |
| 320 | Entrada | allow | ICMP | `0.0.0.0/0` | tipo 0 | Echo-reply |
| 330 | Entrada | allow | ICMP | `0.0.0.0/0` | tipo 3 | Destination unreachable (Path MTU) |
| 340 | Entrada | allow | ICMP | `0.0.0.0/0` | tipo 11 | Time exceeded (traceroute) |
| 100 | Salida | allow | TCP | `10.10.0.32/27` TI | 1024-65535 | Respuestas a lo que inicia TI |
| 110 | Salida | allow | ICMP | `10.10.0.32/27` TI | todos | Respuesta a los ping de TI |
| 190 | Salida | **deny** | todos | `10.0.0.0/8` | — | Visitas no inicia nada hacia la red interna |
| 200 | Salida | **deny** | todos | `172.16.0.0/12` | — | |
| 210 | Salida | **deny** | todos | `192.168.0.0/16` | — | |
| 300 | Salida | allow | todos | `0.0.0.0/0` | — | Internet |

- **Orden.** La NACL se evalúa de menor a mayor y se detiene en la primera regla que coincide. Por eso TI (100) va antes que la negación de `10.0.0.0/8` (190), e Internet (300) va después.
- **Sin estado.** Cada regla de entrada que se permite necesita una de salida para la respuesta, y al revés. Ejemplo: Visitas abre `https://...` desde un puerto efímero; la respuesta entra por la regla 300.
- **Por qué se niega `10.0.0.0/8` y no solo `10.10.0.0/24`.** Así también queda bloqueada la VPC del DNS (`10.10.1.0/28`), a la que `rt-publica` sí tiene ruta por el peering, y cualquier red privada que se agregue después.
- **DNS público.** Visitas sigue resolviendo nombres porque las NACL no filtran el DNS de AWS (`10.10.0.2`), DHCP ni los metadatos de la instancia.
- **Web pública.** Visitas llega a `https://mansiondeldisfraz.duckdns.org` como cualquier cliente de Internet. Sale por el Internet Gateway con su IP pública y entra a la DMZ por la Elastic IP. Por IP privada (`10.10.0.116`) la bloquean la regla 190 de esta NACL y la 190 de `nacl-dmz`.

## 2. Hardening

### 2.1 Nube: puertos cerrados en los Security Groups

| Security Group | Antes | Después |
|---|---|---|
| `startup-sg` (Ventas y Data Center) | TCP 22 desde la IP de CloudShell (una regla por cada IP que tuvo) y desde `10.10.0.0/24`; ICMP desde la VPC | TCP 22 **solo desde TI** (`10.10.0.32/27`); ICMP desde la VPC |
| `startup-sg` en `vm-visitas-1` | Igual que arriba | Reemplazado por `visitas-sg` |
| `intranet-rrhh-sg` | TCP 80 desde Ventas, TI y Data Center; TCP 22 desde Ventas y TI | TCP 80 igual; TCP 22 **solo desde TI** |
| SG de `vm-dns-fase2` | UDP/TCP 53 desde Ventas y TI | Igual, más TCP 22 desde TI para administrarla |

Desde la Fase 1, SSH desde Internet era la forma de entrar a Ventas y Visitas, y `vm-ventas-1` servía de salto hacia las VM privadas. Con el endpoint `eice-ti` (persona 3) eso ya no hace falta: toda la administración sale de TI.

### 2.2 Sistema operativo (`hardening-fase2.sh`)

Se aplica a las 8 VM: `vm-ventas-1`, `vm-ventas-2`, `vm-ti-1`, `vm-datacenter-1`, `vm-visitas-1`, `vm-intranet-rrhh`, `vm-dmz-web` y `vm-dns-fase2`. El rol se pasa como argumento o se deduce de la IP privada.

`vm-dns-fase2` se creó sin key pair (`KeyName = None`), así que `proyecto-key` no sirve para entrar. Para ella, los scripts usan **EC2 Instance Connect**: generan en CloudShell una llave temporal y, antes de cada conexión, `aws ec2-instance-connect send-ssh-public-key` la deposita en la VM durante 60 segundos. Amazon Linux 2023 trae el agente de Instance Connect preinstalado. La VM está en otra VPC, así que la conexión salta por `vm-ti-1`: el salto usa `proyecto-key` y el último tramo, la llave temporal. Ninguna llave queda instalada de forma permanente.

**SSH** (`/etc/ssh/sshd_config.d/00-redes-hardening.conf`). El archivo empieza con `00-` para cargarse antes que `50-redhat.conf`, porque en `sshd` gana el primer valor que se lee.

| Directiva | Valor | Motivo |
|---|---|---|
| `PermitRootLogin` | `no` | Nadie entra como root; se usa `sudo` |
| `PasswordAuthentication`, `KbdInteractiveAuthentication` | `no` | Sin contraseñas: no hay fuerza bruta posible |
| `AuthenticationMethods` | `publickey` | Solo llave (`proyecto-key`) |
| `MaxAuthTries` / `LoginGraceTime` | `3` / `30` | Menos intentos por conexión y menos tiempo para autenticarse |
| `AllowUsers` | `ec2-user` | Solo el usuario de administración |
| `X11Forwarding`, `AllowAgentForwarding`, `PermitTunnel` | `no` | Funciones que no se usan |
| `AllowTcpForwarding` | `no`; `yes` solo en TI | Ninguna VM sirve de salto, salvo `vm-ti-1`, que es la entrada a la VPC del DNS |
| `AddressFamily` | `inet` | La VPC no tiene IPv6: `sshd` deja de escuchar en `[::]:22` |
| `ClientAliveInterval` / `CountMax` | `300` / `2` | Cierra sesiones colgadas |
| `Banner` | aviso legal | Aviso de acceso restringido |

**Firewall del SO** (`nftables`, tabla `inet redes_hardening`). Política de entrada `drop`; solo se acepta lo que también permite el Security Group:

| Rol | Entrada permitida (además de SSH desde TI, `established`, DHCP e ICMP de error) | Salida |
|---|---|---|
| `ventas`, `datacenter` | Ping desde la VPC | Libre |
| `ti` | Ping desde TI | Libre |
| `intranet` | TCP 80 desde Ventas, TI y Data Center; ping desde TI | Libre |
| `dns` | UDP/TCP 53 desde Ventas y TI; ping desde TI | Libre |
| `dmz` | TCP 80 y 443 desde cualquier origen; ping desde TI | **Sin redes privadas** (salvo el DNS de AWS y DHCP) |
| `visitas` | Ping desde TI | **Sin redes privadas** (salvo el DNS de AWS y DHCP) |

La cadena de entrada termina con un `log` limitado (`redes-hardening-drop:` en `journalctl -k`) y un contador de paquetes descartados. La configuración queda persistente: `/etc/sysconfig/nftables.conf` incluye `/etc/nftables/redes-hardening.nft` y `nftables.service` queda habilitado.

**Servicios.** Se deshabilitan, si están instalados: `rpcbind`, `avahi-daemon`, `cups`, `postfix`, `sendmail`, `telnet`, `vsftpd`, `nfs-server`, `cockpit` y `xinetd`. En las VM con `systemd-resolved` (Ventas y TI, por el DNS interno) se apagan LLMNR y mDNS, que escuchan en el puerto 5355 de todas las interfaces. `chronyd` deja de escuchar en el puerto UDP 323 (`cmdport 0`); `chronyc` sigue funcionando por el socket local.

**Kernel** (`/etc/sysctl.d/90-redes-hardening.conf`). Sin ICMP redirects ni source routing, sin reenvío de paquetes, SYN cookies, registro de paquetes con direcciones imposibles (*martians*) y sin responder a ping de broadcast.

**Cómo se evita quedar fuera de la VM.** Antes de tocar SSH y el firewall, el script programa con `systemd-run` una reversión en 5 minutos. `aplicar-hardening-fase2.sh` abre después una conexión SSH **nueva** y ejecuta `--confirmar`, que la cancela. Si esa conexión no se puede abrir, la VM vuelve sola a su configuración anterior. Además, `sshd -t` y `nft -c` validan la configuración antes de aplicarla.

### 2.3 Defensa en profundidad: Visitas → red interna

| Capa | Dónde | Qué hace |
|---|---|---|
| 1 | Firewall del SO de `vm-visitas-1` (`nft`, cadena `salida`) | Rechaza en la propia VM cualquier conexión hacia `10/8`, `172.16/12` y `192.168/16` |
| 2 | `nacl-visitas` (salida 190) | La subred no deja salir tráfico hacia redes privadas |
| 3 | NACL del destino | `nacl-internas` 50, `nacl-ti` 200, `nacl-dmz` 190 |
| 4 | Security Group del destino | `ti-sg`, `intranet-rrhh-sg`, `dmz-web-sg`, `startup-sg` (SSH solo desde TI) |
| 5 | Firewall del SO del destino (`nft`, cadena `entrada`) | Política `drop`; solo los puertos del rol |

## Matriz de conectividad final

| Origen ↓ / Destino → | TI | Ventas | Data Center | Visitas | Intranet (HTTP) | DMZ (IP privada) | Web pública (dominio) | Internet |
|---|---|---|---|---|---|---|---|---|
| **TI** | ✔ | ✔ | ✔ | ✔ | ✔ | ✔ 22, 80, 443 | sin ruta | sin ruta (solo S3) |
| **Ventas** | ✘ | ping ✔, SSH ✘ | ping ✔, SSH ✘ | ✘ | ✔ | ✘ | ✔ | ✔ |
| **Data Center** | ✘ | ping ✔, SSH ✘ | ping ✔, SSH ✘ | ✘ | ✔ | ✘ | sin ruta | sin ruta (solo S3) |
| **Visitas** | ✘ | ✘ | ✘ | — | ✘ | ✘ | ✔ | ✔ |
| **DMZ** | ✘ | ✘ | ✘ | ✘ | ✘ | — | — | solo HTTPS |
| **Internet** | ✘ | ✘ | ✘ | ✘ | ✘ | — | ✔ 80 → 301, 443 | — |

## Pruebas (`pruebas-visitas-hardening-fase2.sh`)

| # | Origen → destino | Esperado |
|---|---|---|
| 1–3 | `vm-visitas-1` → Internet (HTTPS, HTTP y DNS público) | Funciona |
| 4 | `vm-visitas-1` → `https://mansiondeldisfraz.duckdns.org` | `200` |
| 5–7 | `vm-visitas-1` → Ventas, TI y Data Center (ping + 22) | Bloqueado |
| 8 | `vm-visitas-1` → intranet (nombre y TCP 80) | Bloqueado |
| 9 | `vm-visitas-1` → DMZ por IP privada (22, 80, 443) | Bloqueado |
| 10 | `vm-visitas-1` → DNS interno `10.10.1.4` (`dig` y TCP 53) | Bloqueado |
| 11 | `vm-ti-1` → `vm-visitas-1` (ping + 22) | Funciona |
| 12 | `vm-ventas-1` → `vm-visitas-1` | Bloqueado |
| 13 | Internet → `vm-visitas-1` puerto 22 | Bloqueado |
| 14–21 | `--verificar` en cada una de las 8 VM | `CUMPLE` |
| 22–23 | Internet → `vm-ventas-1` y `vm-ventas-2` puerto 22 | Bloqueado (antes estaba abierto para CloudShell) |
| 24 | `vm-ventas-1` → SSH de `vm-ventas-2`, Data Center e intranet | Bloqueado (antes abierto) |
| 25 | `vm-ti-1` → `vm-ventas-1` solo con contraseña | `Permission denied (publickey)` |
| 26 | Salto SSH por `vm-ventas-1` (el bastión de la Fase 1) | Bloqueado |
| 27 | `vm-ti-1` → puerto 22 de todas las VM | Funciona |
| 28–31 | DNS interno, intranet desde Ventas, TI y Data Center | Funciona |
| 32–34 | Web pública: 301 a HTTPS, 200 desde Internet y desde Ventas | Funciona |
| 35 | `vm-dmz-web`: `certbot renew --dry-run` | Funciona (la renovación del certificado no se rompió) |
| 36 | `vm-dmz-web` → TI e intranet | Bloqueado |

### Validación local, antes de AWS

Los scripts se probaron en contenedores `amazonlinux:2023`, la misma distribución de las VM, conectados a una red Docker `10.10.0.0/23`. Cada contenedor tenía la IP de una VM real (`10.10.0.28`, `.60`, `.69`, `.101`, `.116`, `10.10.1.4`, etc.), `sshd` y su servicio. El DNS se montó con `configurar-dns-fase2.sh` de la persona 1. Un contenedor con IP de TI (`10.10.0.40`) hizo de `eice-ti`.

- `hardening-fase2.sh`: los 7 roles se aplican, son idempotentes y pasan `--verificar`. En 33 pruebas de conectividad, todas dieron lo esperado: SSH solo desde TI y solo con llave, root y contraseña rechazados, salto permitido solo por TI, Visitas y DMZ sin salida a redes privadas pero con Internet. `--revertir` deja la VM como estaba.
- `aplicar-hardening-fase2.sh`, `escanear-puertos-fase2.sh` y `pruebas-visitas-hardening-fase2.sh` se corrieron completos con un `aws` y un `ssh` simulados. Se aplicó el hardening a las 8 VM, incluido el salto a la VM del DNS por `vm-ti-1` ya endurecida. Resultado: 35 de 36 pruebas. La que falló es la 35, porque el contenedor no tiene `certbot`.
- `pruebas-reglas-fase2.sh` (14 pruebas) y `pruebas-intranet-fase2.sh` (8) dieron lo esperado sobre las VM endurecidas.
- `shellcheck` sin advertencias en los scripts nuevos y modificados.

Lo que la simulación no cubre: los Security Groups, las NACL y el endpoint `eice-ti` reales. Eso solo se comprueba en AWS.

### Resultados de la ejecución en AWS

`reglas-visitas-fase2.sh` creó estos recursos en `vpc-startup` (`vpc-02251b0b1ccc6414f`); la configuración está en los `visitas-*.json`:
- `visitas-sg` (`sg-0731735fddcdb42d8`).
- `nacl-visitas` (`acl-0758ecd6b1128cc19`, 17 entradas), asociada a `snet-visitas` (`subnet-0afbdffb68119a7f9`).
- `vm-visitas-1` (`i-0b1ccae38843e210e`, `10.10.0.84`) pasó de `startup-sg` a `visitas-sg`.

Antes del hardening, `SOLO_VISITAS=1` dio **13 de 13** ([registro](pruebas-visitas-nacl.log)). En esa corrida, los intentos de Visitas hacia la red interna terminan en *timeout* (`100% packet loss`): los bloquea la nube, sin firewall del SO todavía.

Security Groups ([registro](hardening-fase2.log), [JSON](hardening-security-groups.json)):
- `startup-sg` (`sg-0fa80d561eece0d1d`) aceptaba TCP 22 desde tres IP públicas de CloudShell que se habían ido acumulando (`32.192.35.53`, `98.83.135.208` y `3.82.56.79`) y desde toda la VPC. Quedó con TCP 22 solo desde `10.10.0.32/27`.
- `intranet-rrhh-sg` (`sg-0c0d6a1212b7895d2`) dejó de aceptar TCP 22 desde Ventas.
- `dns-fase2` (`sg-0ad5fbc128c9d2489`, en `vpc-07bae1df766c61794`) ahora acepta TCP 22 desde TI ([JSON](hardening-dns-security-group.json)).

Puertos TCP abiertos según nmap ([antes](puertos-antes.log), [después sin el DNS](puertos-despues-sin-dns.log), [después final](puertos-despues.log)):

| Origen | Antes | Después |
|---|---|---|
| Internet | `32.200.48.146` (DMZ): 80, 443 | Igual |
| `vm-ventas-1` | `.21`: 22 · `.109`: 22 · `.101`: 22, 80 · `10.10.1.4`: 53 | `.101`: 80 · `10.10.1.4`: 53 |
| `vm-visitas-1` | Ninguno interno | Ninguno interno |
| `vm-ti-1` | 22 en las 7 VM de `vpc-startup`, más 80/443 de la DMZ, 80 de la intranet y 53 del DNS | Igual, **más el 22 del DNS** |

En el nmap "antes" desde Internet, el 22 de Ventas ya aparecía `filtered`. Las reglas de `startup-sg` eran para IP viejas de CloudShell y la sesión de este día tenía otra (`35.174.62.132`). Lo que demuestra el cierre del SSH público es la tabla ANTES/DESPUÉS de `startup-sg`.

Primera ejecución (16 de noviembre de 2026, 04:29 UTC):
- `aplicar-hardening-fase2.sh` endureció las 7 VM de `vpc-startup`; todas dieron `CUMPLE`. Omitió `vm-dns-fase2` porque la VM no tiene key pair.
- `escanear-puertos-fase2.sh despues`:
  - Desde Internet solo responden el 80 y el 443 de la Elastic IP de la DMZ. El SSH de Ventas y Visitas aparece `filtered`.
  - Desde `vm-ventas-1` solo están abiertos el 80 de la intranet y el 53 del DNS. El SSH de las demás VM aparece `filtered`.
  - Desde `vm-visitas-1` no hay ningún puerto interno abierto.
  - Desde `vm-ti-1` está abierto el 22 de todas las VM de `vpc-startup`, más los servicios (80 de la intranet, 80/443 de la DMZ y 53 del DNS).
- `pruebas-visitas-hardening-fase2.sh`: **34 de 36**. Fallaron la 21 (verificación de `vm-dns-fase2`) y la 27 (TI → `10.10.1.4:22`), las dos porque la VM del DNS no se había endurecido ni tenía todavía la regla de SSH desde TI. La renovación del certificado (35) salió bien.
- `vm-visitas-1` tiene la IP `10.10.0.84`.

Segunda ejecución, con soporte para Instance Connect: `SOLO_DNS=1 bash aplicar-hardening-fase2.sh` y luego `pruebas-visitas-hardening-fase2.sh`.

Resultado de la segunda ejecución:
- `SOLO_DNS=1 bash aplicar-hardening-fase2.sh` entró a `vm-dns-fase2` por Instance Connect y agregó a su Security Group el TCP 22 desde TI.
- Al aplicar el hardening, deshabilitó `rpcbind`, `nfs-server` y `rpc-statd`. También cerró el puerto 323 de `chronyd` y dejó de escuchar SSH en `[::]:22`. La verificación dio `CUMPLE` ([registro](hardening-dns.log)).
- `pruebas-visitas-hardening-fase2.sh`: **36 de 36 pruebas con el resultado esperado** ([registro](pruebas-visitas-hardening-fase2-final.log)).

En la tabla `nft` del DNS, la regla del puerto 53 aparece como `10.10.0.0/26`. nftables junta automáticamente los dos bloques contiguos de Ventas (`10.10.0.0/27`) y TI (`10.10.0.32/27`) en uno solo; es exactamente el mismo rango.

## Costos

Security Groups, NACL, `nftables` y `nmap` no tienen costo. Esta parte no agrega recursos que cobren.

## Revertir (si hiciera falta para una demo)

```bash
# Dentro de una VM: quita el firewall del SO y la configuracion SSH
sudo bash /usr/local/sbin/hardening-fase2.sh --revertir
# Visitas de vuelta a startup-sg y a la NACL por defecto
aws ec2 modify-instance-attribute --instance-id <id de vm-visitas-1> --groups <id de startup-sg>
aws ec2 replace-network-acl-association --association-id <asociacion actual de snet-visitas> --network-acl-id <id de la NACL por defecto>
```

## Notas para el resto del equipo

- **Acceso a las VM:** desde ahora, solo por `eice-ti`:
  ```bash
  ssh -i ~/proyecto-key.pem -o ProxyCommand='aws ec2-instance-connect open-tunnel --instance-id %h' ec2-user@<instance-id>
  ```
  `pruebas-reglas-fase2.sh` y `pruebas-intranet-fase2.sh` se cambiaron para entrar así, en vez de por la IP pública o saltando por `vm-ventas-1`. Las pruebas son las mismas.
- **`pruebas-aws.sh` (Fase 1):** vuelve a abrir SSH desde CloudShell y desde toda la VPC en `startup-sg`, y espera que Ventas llegue a TI. Ahora se detiene si detecta el hardening, salvo que se ejecute con `FORZAR=1`.
- **VM nuevas:** después de lanzarlas, ejecutar `sudo bash hardening-fase2.sh <rol>` dentro de la VM, o volver a correr `aplicar-hardening-fase2.sh`, que es idempotente.
- **Limpieza al final:** primero `bash limpiar-dns-fase2.sh` (VPC del DNS y peering) y después `bash limpiar-aws.sh`, que ya libera la Elastic IP y borra `visitas-sg` y `nacl-visitas` porque tienen la etiqueta `Project`.
