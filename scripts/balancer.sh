#!/bin/sh

# Первоначальное состояние
CURRENT_ACTIVE=""

echo "Starting UDP IPTABLES Balancer..."

while true; do
    # Проверяем node1
    curl -s --connect-timeout 2 http://172.40.0.2:8080/health > /dev/null
    NODE1_STATUS=$?

    NEW_ACTIVE=""
    if [ $NODE1_STATUS -eq 0 ]; then
        NEW_ACTIVE="172.40.0.2"
    else
        # Если node1 лежит, проверяем node2
        curl -s --connect-timeout 2 http://172.40.0.3:8080/health > /dev/null
        NODE2_STATUS=$?
        if [ $NODE2_STATUS -eq 0 ]; then
            NEW_ACTIVE="172.40.0.3"
        fi
    fi

    # Если статус изменился, перенаправляем IPTABLES
    if [ "$NEW_ACTIVE" != "$CURRENT_ACTIVE" ]; then
        iptables -t nat -F PREROUTING
        iptables -t nat -F POSTROUTING

        if [ -n "$NEW_ACTIVE" ]; then
            echo "Switching SIP UDP traffic to: $NEW_ACTIVE"
            iptables -t nat -A PREROUTING -p udp --dport 5060 -j DNAT --to-destination ${NEW_ACTIVE}:5060
            iptables -t nat -A POSTROUTING -p udp -d ${NEW_ACTIVE} --dport 5060 -j MASQUERADE
            CURRENT_ACTIVE=$NEW_ACTIVE
        else
            echo "WARNING: Both nodes are DOWN! Clearing routing tables."
            CURRENT_ACTIVE=""
        fi
    fi

    sleep 2
done
