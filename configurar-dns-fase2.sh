#!/usr/bin/env bash
# Ejecutar como root en una EC2 dedicada con Amazon Linux 2023.
# Se puede usar como user data en la VPC privada del DNS.
set -euo pipefail

dns_ip=${1:-10.10.1.4}
rrhh_ip=${2:-10.10.0.101}
zone=mansiondeldisfraz.local
zone_file=/var/named/db.mansiondeldisfraz.local

dnf install -y bind bind-utils

if [[ ! -e /etc/named.conf.fase2-original ]]; then
  cp -p /etc/named.conf /etc/named.conf.fase2-original
fi

cat >/etc/named.conf <<EOF
options {
    directory "/var/named";
    listen-on port 53 { 127.0.0.1; ${dns_ip}; };
    listen-on-v6 { none; };
    recursion no;
    allow-query { localhost; 10.10.0.0/27; 10.10.0.32/27; };
    allow-transfer { none; };
};

zone "${zone}" IN {
    type primary;
    file "${zone_file}";
};
EOF

cat >"$zone_file" <<EOF
\$TTL 300
@    IN SOA ns1.${zone}. admin.${zone}. (
             $(date -u +%Y%m%d%H) 3600 600 86400 300 )
@    IN NS  ns1.${zone}.
ns1  IN A   ${dns_ip}
rrhh IN A   ${rrhh_ip}
EOF

chown root:named /etc/named.conf "$zone_file"
chmod 0640 /etc/named.conf "$zone_file"
restorecon /etc/named.conf "$zone_file"
named-checkconf -z
systemctl enable named
systemctl restart named

for protocol in +notcp +tcp; do
  answer=$(dig @"$dns_ip" "rrhh.${zone}" A +short +tries=1 +time=2 "$protocol")
  [[ "$answer" == "$rrhh_ip" ]]
  printf 'REDES DNS OK %s rrhh.%s %s\n' "$protocol" "$zone" "$answer"
done
