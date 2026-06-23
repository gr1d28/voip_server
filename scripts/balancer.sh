#!/bin/sh

CURRENT_ACTIVE=""
SIP_PORT=5060
NODE1=172.40.0.2
NODE2=172.40.0.3

echo "Starting SIP Balancer with conntrack cleanup..."

# Функция для проверки доступности узла
check_node() {
    local node=$1
    curl -s --connect-timeout 2 http://${node}:8080/health > /dev/null 2>&1
    return $?
}

# Функция для полной очистки conntrack
cleanup_conntrack() {
    echo "Cleaning up conntrack for SIP..."

    # Удаляем все записи для SIP порта
    conntrack -D -p udp --dport $SIP_PORT 2>/dev/null
    conntrack -D -p udp --sport $SIP_PORT 2>/dev/null
    conntrack -D -p tcp --dport $SIP_PORT 2>/dev/null
    conntrack -D -p tcp --sport $SIP_PORT 2>/dev/null

    # Удаляем записи для обоих узлов
    for node in $NODE1 $NODE2; do
        conntrack -D -d $node 2>/dev/null
        conntrack -D -s $node 2>/dev/null
    done

    # Удаляем записи для RTP портов
    conntrack -D -p udp --dport 10000:20000 2>/dev/null
    conntrack -D -p udp --sport 10000:20000 2>/dev/null
}

# Основной цикл
while true; do
    # Определяем активный узел
    if check_node $NODE1; then
        NEW_ACTIVE=$NODE1
    elif check_node $NODE2; then
        NEW_ACTIVE=$NODE2
    else
        NEW_ACTIVE=""
        echo "WARNING: Both nodes are DOWN!"
    fi

    # Если статус изменился
    if [ "$NEW_ACTIVE" != "$CURRENT_ACTIVE" ]; then
        echo "=== STATUS CHANGE ==="
        echo "Old active: $CURRENT_ACTIVE"
        echo "New active: $NEW_ACTIVE"

        # Очищаем старые правила
        iptables -t nat -F PREROUTING
        iptables -t nat -F POSTROUTING

        # Очищаем conntrack
        cleanup_conntrack

        if [ -n "$NEW_ACTIVE" ]; then
            echo "Setting up routing to: $NEW_ACTIVE"

            # Добавляем новые правила
            iptables -t nat -A PREROUTING -p udp --dport $SIP_PORT -j DNAT --to-destination ${NEW_ACTIVE}:$SIP_PORT
            iptables -t nat -A PREROUTING -p tcp --dport $SIP_PORT -j DNAT --to-destination ${NEW_ACTIVE}:$SIP_PORT
            iptables -t nat -A POSTROUTING -p udp -d ${NEW_ACTIVE} --dport $SIP_PORT -j MASQUERADE
            iptables -t nat -A POSTROUTING -p tcp -d ${NEW_ACTIVE} --dport $SIP_PORT -j MASQUERADE

            # Правила для RTP (если нужно)
            iptables -t nat -A PREROUTING -p udp --dport 10000:20000 -j DNAT --to-destination ${NEW_ACTIVE}
            iptables -t nat -A POSTROUTING -p udp -d ${NEW_ACTIVE} --dport 10000:20000 -j MASQUERADE

            CURRENT_ACTIVE=$NEW_ACTIVE
            echo "Successfully switched to $NEW_ACTIVE"
        else
            echo "No active nodes available"
            CURRENT_ACTIVE=""
        fi

        # Показываем текущие правила
        echo "Current iptables rules:"
        iptables -t nat -L PREROUTING -n -v | head -5
        echo ""
    fi

    sleep 2
done