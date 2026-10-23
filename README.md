自用脚本，不一定能用

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

uufw防火墙
`````
curl -fsSL https://raw.githubusercontent.com/opyzzzz/argox/refs/heads/main/uufw.sh -o /usr/local/bin/uufw && chmod +x /usr/local/bin/uufw && uufw
`````

DNS
`````
curl -fsSL https://raw.githubusercontent.com/opyzzzz/argox/refs/heads/main/smart_dns.sh -o /tmp/smart_dns.sh && sh /tmp/smart_dns.sh && rm -f /tmp/smart_dns.sh
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
