FROM rabbitmq:3-management

# Spring STOMP Broker Relay 가 접속하려면 STOMP 플러그인이 필요하다.
# --offline: 브로커가 실행 중이 아니어도 이미지 빌드 시점에 플러그인을 켠다.
RUN rabbitmq-plugins enable --offline rabbitmq_stomp

# Observability: RabbitMQ 3.8+ 에 내장된 Prometheus 엔드포인트(15692/metrics)를 켠다.
# 별도 exporter 컨테이너가 필요 없다.
# 큐 적체(rabbitmq_queue_messages_ready)로 "채팅 메시지가 밀리고 있는지"를 본다.
RUN rabbitmq-plugins enable --offline rabbitmq_prometheus
