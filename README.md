自用脚本，不一定能用

ufwssh
`````
curl -fsSL -o /tmp/ufwssh.sh https://raw.githubusercontent.com/opyzzzz/MYSH/refs/heads/main/ufwssh.sh && bash /tmp/ufwssh.sh && rm -f /tmp/ufwssh.sh
`````
ufwssh-jsdelivr-cdn
`````
curl -fsSL https://cdn.jsdelivr.net/gh/opyzzzz/MYSH@main/ufwssh.sh | bash
`````

docker+komari+sublinkpro+cf隧道
`````
curl -fsSL https://raw.githubusercontent.com/opyzzzz/MYSH/refs/heads/main/KSC-docker.sh -o /tmp/ksc.sh && bash /tmp/ksc.sh && rm -f /tmp/ksc.sh
`````

uufw防火墙
`````
curl -fsSL https://raw.githubusercontent.com/opyzzzz/MYSH/refs/heads/main/uufw.sh -o /usr/local/bin/uufw && chmod +x /usr/local/bin/uufw && uufw
`````

DNS
`````
curl -fsSL https://raw.githubusercontent.com/opyzzzz/MYSH/refs/heads/main/smart_dns.sh -o /tmp/smart_dns.sh && sh /tmp/smart_dns.sh && rm -f /tmp/smart_dns.sh
`````

SmartDNS
`````
curl -sLo /tmp/sdns.sh https://raw.githubusercontent.com/opyzzzz/MYSH/refs/heads/main/smartdns.sh && bash /tmp/sdns.sh
`````

MOSDNS
`````
wget -qO- https://raw.githubusercontent.com/opyzzzz/MYSH/refs/heads/main/mosdns.js | bash
`````

check-doh+tls dns
`````
wget -qO- https://raw.githubusercontent.com/opyzzzz/MYSH/refs/heads/main/doh-check.sh | bash
`````
