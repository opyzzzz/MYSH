自用脚本，不一定能用

`````
wget -O /usr/local/bin/argo https://raw.githubusercontent.com/opyzzzz/argox/refs/heads/main/argo.sh && chmod +x /usr/local/bin/argo && argo install
`````
ufwssh
`````
curl -fsSL -o /tmp/ufwssh.sh https://raw.githubusercontent.com/opyzzzz/argox/refs/heads/main/ufwssh.sh && bash /tmp/ufwssh.sh && rm -f /tmp/ufwssh.sh
`````
ufwssh-jsdelivr-cdn
`````
curl -fsSL https://cdn.jsdelivr.net/gh/opyzzzz/argox@main/ufwssh.sh | bash
`````





docker+komari+sublinkpro+cf隧道
`````
curl -fsSL https://raw.githubusercontent.com/opyzzzz/argox/refs/heads/main/KSC-docker.sh -o /tmp/ksc.sh && bash /tmp/ksc.sh && rm -f /tmp/ksc.sh
`````
DNS-DEL
`````
curl -fsSL https://raw.githubusercontent.com/opyzzzz/argox/refs/heads/main/dns-del.sh | bash
`````
uufw防火墙
`````
curl -fsSL https://raw.githubusercontent.com/opyzzzz/argox/refs/heads/main/uufw.sh -o /usr/local/bin/uufw && chmod +x /usr/local/bin/uufw && uufw
`````

DNS
`````
curl -fsSL https://raw.githubusercontent.com/opyzzzz/argox/refs/heads/main/smart_dns.sh -o /tmp/smart_dns.sh && sh /tmp/smart_dns.sh && rm -f /tmp/smart_dns.sh
`````

dns-detective
`````
wget -qO- https://raw.githubusercontent.com/opyzzzz/argox/refs/heads/main/dns-detective.sh | sh
`````

SDNS
`````
curl -sLo /tmp/sdns.sh https://raw.githubusercontent.com/opyzzzz/argox/refs/heads/main/sdns.sh && bash /tmp/sdns.sh
`````
SmartDNS
`````
curl -sLo /tmp/sdns.sh https://raw.githubusercontent.com/opyzzzz/argox/refs/heads/main/smartdns.sh && bash /tmp/sdns.sh
`````

MOSDNS
`````
wget -qO- https://raw.githubusercontent.com/opyzzzz/argox/refs/heads/main/mosdns.js | bash
`````

check-doh dns
`````
wget -qO- https://raw.githubusercontent.com/opyzzzz/argox/refs/heads/main/doh-check.sh | bash
`````


check-dot dns
`````
wget -qO- https://raw.githubusercontent.com/opyzzzz/argox/refs/heads/main/dns-check.sh | bash
`````

sb-musl安装
`````
wget -qO /tmp/sb-musl.sh https://raw.githubusercontent.com/opyzzzz/argox/refs/heads/main/singbox/1.13.21/sb-musl.sh && chmod +x /tmp/sb-musl.sh && /tmp/sb-musl.sh
`````
