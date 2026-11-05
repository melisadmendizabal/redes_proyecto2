# DNS interno — Fase 2

Región `us-east-1`. El DNS usa la EC2 `vm-dns-fase2` (`i-0b11f554244e540d1`), Amazon Linux 2023 y BIND. Su IP privada es `10.10.1.4`. BIND responde como servidor autoritativo para `mansiondeldisfraz.local` y el registro `rrhh` apunta a `10.10.0.101`.

La VPC nueva `vpc-dns-fase2` (`10.10.1.0/28`) se conecta por peering `pcx-0dc7edc380a09359d` con `vpc-startup` (`10.10.0.0/24`). La VPC original ya estaba desplegada. Se eligió el bloque nuevo para evitar solapamiento y conservar la IP de la intranet. Las rutas del lado de `vpc-startup` apuntan a `10.10.1.4/32`. Las rutas de retorno del DNS apuntan a Ventas y TI. Tanto BIND como el grupo de seguridad permiten consultas de Ventas (`10.10.0.0/27`) y TI (`10.10.0.32/27`). El grupo de seguridad permite UDP y TCP 53 de esos orígenes. La VM instala paquetes mediante el endpoint de S3 de su VPC.

Salida de las pruebas recuperada de la consola de EC2:

```text
REDES DNS OK +notcp rrhh.mansiondeldisfraz.local 10.10.0.101
REDES DNS OK +tcp rrhh.mansiondeldisfraz.local 10.10.0.101
REDES PROBE origen 10.10.0.11 destino 10.10.1.4
REDES PROBE UDP OK rrhh.mansiondeldisfraz.local -> 10.10.0.101
REDES PROBE TCP OK rrhh.mansiondeldisfraz.local -> 10.10.0.101
REDES PROBE origen 10.10.0.69 destino 10.10.1.4
REDES PROBE UDP BLOQUEADO desde 10.10.0.69
REDES PROBE TCP BLOQUEADO desde 10.10.0.69
```

Desde una VM autorizada, la consulta directa se puede repetir con:

```bash
dig @10.10.1.4 rrhh.mansiondeldisfraz.local A +short
dig @10.10.1.4 rrhh.mansiondeldisfraz.local A +tcp +short
```

En `vm-ventas-1`, `vm-ventas-2` y `vm-ti-1`, `/etc/resolv.conf` apunta al resolvedor local de `systemd-resolved`. El archivo `/etc/systemd/resolved.conf.d/90-redes-fase2.conf` dirige `~mansiondeldisfraz.local` a `10.10.1.4`. El archivo `/etc/systemd/network/70-ens5.network.d/90-redes-fase2.conf` define `~.` en `ens5` para que las demás consultas se envíen al DNS que entrega AWS por DHCP.

En cada VM se ejecutó `getent ahostsv4` para RRHH y para `example.com`. Ambas consultas usaron la configuración normal del sistema:

```text
ip-10-10-0-28 RRHH=10.10.0.101 example.com=172.66.147.243
ip-10-10-0-21 RRHH=10.10.0.101 example.com=172.66.147.243
ip-10-10-0-60 RRHH=10.10.0.101 example.com=172.66.147.243
```
