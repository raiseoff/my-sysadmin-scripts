#!/bin/bash
N=5
for i in $(seq 1 3); do
    echo "--- $(date '+%Y-%m-%d %H:%M:%S') ---" >> monitor.log

    if ! free -h >> monitor.log 2>&1; then
        echo "ошибка: free -h" >> monitor.log
    fi

    if ! df -h >> monitor.log 2>&1; then
        echo "ошибка: df -h" >> monitor.log
    fi

    if ! uptime >> monitor.log 2>&1; then
        echo "ошибка: uptime" >> monitor.log
    fi

    sleep "$N"
done
