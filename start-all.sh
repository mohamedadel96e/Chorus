#!/usr/bin/env bash

echo "Cleaning up existing processes and zombies..."
# Force kill anything holding our application ports
lsof -ti:8081,8082,8083,8084 | xargs kill -9 2>/dev/null || true

# Cleanup stale PID files
rm -f order.pid inventory.pid payment.pid shipping.pid


echo "Starting Order Service on 8081..."
(cd order-service && ./mvnw spring-boot:run -Dspring-boot.run.arguments="--server.port=8081" > ../order-service.log 2>&1 & echo $! > order.pid)

echo "Starting Inventory Service on 8082..."
(cd inventory-service && ./mvnw spring-boot:run -Dspring-boot.run.arguments="--server.port=8082" > ../inventory-service.log 2>&1 & echo $! > inventory.pid)

echo "Starting Payment Service on 8083..."
(cd payment-service && PORT=8083 npm run start > ../payment-service.log 2>&1 & echo $! > payment.pid)

echo "Starting Shipping Service API on 8084..."
(cd shipping-service && php artisan serve --port=8084 > ../shipping-service.log 2>&1 & echo $! > shipping.pid)

echo "Starting Shipping Service Consumer..."
(cd shipping-service && php artisan rabbitmq:consume-payment-events > ../shipping-worker.log 2>&1 & echo $! > shipping-worker.pid)

echo "All services started."
